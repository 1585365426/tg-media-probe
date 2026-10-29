/// Playback state machine for one channel: which video is current, whether its
/// local file is ready, and which single player instance is alive.
///
/// The rules it encodes, all of them from the product spec:
///
/// * a video is only opened after `DownloadManager` returned a verified path;
/// * there is never more than one player — the old one is disposed *before* the
///   new one is created, so a hundred swipes leave one instance, not a hundred;
/// * a superseded load is dropped (generation counter) rather than racing the
///   new one to the screen;
/// * a handle that was already released is never touched again, even if its
///   `open()` is still in flight (disposing an AVPlayer twice is a crash).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/media_index.dart';
import '../download/download_state.dart';
import 'local_media_player.dart';

enum PlaybackPhase {
  /// Downloading / verifying, or opening the player.
  preparing,

  /// The player has the file and is playing.
  ready,

  /// Nothing will appear without the user acting.
  failed,
}

/// One player instance plus its "already released" flag.
///
/// Two code paths can want a handle gone at the same time: a new load tearing
/// down the old one, and the old load finishing late. Both call
/// [release]; only the first call reaches the platform, and the live-player
/// counter can therefore not drift below zero.
class _PlayerSlot {
  _PlayerSlot(this.handle) {
    PlaybackController._livePlayers++;
  }

  final MediaPlayerHandle handle;
  bool released = false;

  Future<void> release() async {
    if (released) return;
    released = true;
    PlaybackController._livePlayers--;
    await handle.dispose();
  }
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.items,
    required this.downloads,
    required int initialIndex,
    MediaPlayerFactory? playerFactory,
    this.openTimeout = const Duration(seconds: 20),
    double playbackSpeed = 1.0,
    bool muted = false,
  })  : _index = items.isEmpty ? 0 : initialIndex.clamp(0, items.length - 1),
        _speed = playbackSpeed,
        _factory = playerFactory ?? ((path) => LocalMediaPlayer(path: path)) {
    _muted = muted;
  }

  final List<NumberedMedia> items;
  final MediaPreparer downloads;
  final Duration openTimeout;
  final MediaPlayerFactory _factory;

  /// Every constructed-but-not-released player. A 100-swipe run must end at 0
  /// after `dispose()` and never exceed 1 while running; the stress test reads
  /// this directly instead of guessing from memory graphs.
  static int _livePlayers = 0;
  static int get livePlayerCount => _livePlayers;

  static void resetLivePlayerCountForTest() => _livePlayers = 0;

  int _index;
  PlaybackPhase _phase = PlaybackPhase.preparing;
  String? _errorMessage;
  _PlayerSlot? _slot;
  int _generation = 0;
  bool _disposed = false;
  double _speed;
  late bool _muted;
  bool _listening = false;
  DownloadState _download = DownloadState.idle;

  int get index => _index;
  int get length => items.length;
  bool get hasItems => items.isNotEmpty;
  bool get hasNext => _index + 1 < items.length;
  bool get hasPrevious => _index > 0;
  NumberedMedia? get current => items.isEmpty ? null : items[_index];
  PlaybackPhase get phase => _phase;
  String? get errorMessage => _errorMessage;
  DownloadState get downloadState => _download;

  /// The live handle, or null once it has been released.
  MediaPlayerHandle? get player {
    final slot = _slot;
    return slot == null || slot.released ? null : slot.handle;
  }

  bool get isPlaying => player?.isPlaying ?? false;
  Duration get position => player?.position ?? Duration.zero;
  Duration get duration => player?.duration ?? Duration.zero;
  double get speed => _speed;
  bool get isMuted => _muted;

  /// Opens the current video. Safe to call twice: the second call is ignored
  /// while the first is still preparing.
  Future<void> start() async {
    if (items.isEmpty) {
      _phase = PlaybackPhase.failed;
      _errorMessage = '该频道没有可播放的视频';
      _notify();
      return;
    }
    if (_phase == PlaybackPhase.preparing && _slot != null) return;
    await _load(_index);
  }

  Future<void> goTo(int target) async {
    if (target < 0 || target >= items.length) return;
    if (target == _index && _slot != null && _phase == PlaybackPhase.ready) {
      return;
    }
    _index = target;
    await _load(target);
  }

  Future<void> next() async {
    if (!hasNext) return;
    await goTo(_index + 1);
  }

  Future<void> previous() async {
    if (!hasPrevious) return;
    await goTo(_index - 1);
  }

  /// Re-runs the whole prepare step for the current video (download failure or
  /// player initialisation failure).
  Future<void> retry() => _load(_index);

  Future<void> _load(int target) async {
    final generation = ++_generation;
    await _teardownPlayer();
    if (_disposed) return;

    _phase = PlaybackPhase.preparing;
    _errorMessage = null;
    _download = DownloadState(
      phase: DownloadPhase.checking,
      totalBytes: current?.record.sizeBytes ?? 0,
    );
    _attachDownloadListener();
    _notify();

    final item = current;
    if (item == null) {
      _phase = PlaybackPhase.failed;
      _errorMessage = '该频道没有可播放的视频';
      _notify();
      return;
    }

    final outcome = await downloads.ensureLocal(item.record);
    if (_disposed || generation != _generation) return;

    if (!outcome.isReady) {
      _detachDownloadListener();
      _phase = PlaybackPhase.failed;
      _errorMessage = outcome.message;
      _notify();
      return;
    }

    final slot = _PlayerSlot(_factory(outcome.path!));
    _slot = slot;
    try {
      await slot.handle.open().timeout(openTimeout);
      // The page may have moved on while this file was opening; the slot is
      // then already released and every further call would be a use-after-free.
      if (_isStale(slot, generation)) {
        _detachDownloadListenerIfStale(generation);
        return;
      }
      await slot.handle.setSpeed(_speed);
      await slot.handle.setVolume(_muted ? 0 : 1);
      await slot.handle.play();
    } on Object catch (e) {
      final stale = _isStale(slot, generation);
      await slot.release();
      if (_slot == slot) _slot = null;
      if (stale || _disposed) return;
      _detachDownloadListener();
      _phase = PlaybackPhase.failed;
      _errorMessage = '视频无法播放，请重试';
      debugPrint('playback open failed: $e');
      _notify();
      return;
    }

    if (_isStale(slot, generation)) {
      _detachDownloadListenerIfStale(generation);
      return;
    }

    _detachDownloadListener();
    _phase = PlaybackPhase.ready;
    _notify();
  }

  /// True when this load no longer owns the screen: a newer load started, the
  /// controller was disposed, or the handle was already released.
  bool _isStale(_PlayerSlot slot, int generation) =>
      _disposed || generation != _generation || slot.released || _slot != slot;

  /// A superseded load must not unhook the listener the new load just attached.
  void _detachDownloadListenerIfStale(int generation) {
    if (generation != _generation) return;
    _detachDownloadListener();
  }

  void _attachDownloadListener() {
    if (_listening) return;
    downloads.addListener(_onDownloadChanged);
    _listening = true;
  }

  void _detachDownloadListener() {
    if (!_listening) return;
    downloads.removeListener(_onDownloadChanged);
    _listening = false;
  }

  void _onDownloadChanged() {
    if (_disposed) return;
    _download = downloads.state;
    _notify();
  }

  Future<void> togglePlay() async {
    final handle = player;
    if (handle == null || _phase != PlaybackPhase.ready) return;
    if (handle.isPlaying) {
      await handle.pause();
    } else {
      await handle.play();
    }
    _notify();
  }

  Future<void> seekTo(Duration position) async {
    await player?.seekTo(position);
    _notify();
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await player?.setSpeed(speed);
    _notify();
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    await player?.setVolume(muted ? 0 : 1);
    _notify();
  }

  Future<void> _teardownPlayer() async {
    final slot = _slot;
    _slot = null;
    if (slot == null) return;
    await slot.release();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _detachDownloadListener();
    // Disposal is fire-and-forget here: the widget is going away and awaiting
    // would keep the controller alive past the frame. The slot decrements the
    // live counter synchronously, before the platform call is awaited.
    unawaited(_teardownPlayer());
    super.dispose();
  }
}
