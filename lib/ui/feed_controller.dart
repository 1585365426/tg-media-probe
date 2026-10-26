/// State machine for the full-screen vertical feed.
///
/// Everything that can go wrong with a video feed is a sequencing problem, so
/// the sequencing is here and the widgets stay dumb:
///
/// * switch away -> cancel the old transfer, release the old player, **then**
///   resolve and start the new one (`SinglePlayerController` enforces the
///   order, this file enforces the intent);
/// * a slow resolution that finishes after the user moved on must not install
///   itself (`LatestOnlySlot`);
/// * backgrounding releases the decoder, foregrounding re-activates the same
///   item from where the list already is;
/// * "preload" means one adjacent *transfer*, never a second player — the
///   product spec caps live players at one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, Orientation;

import '../data/channel_sync.dart' show MediaPager;
import '../data/index_store.dart';
import '../data/media_record.dart';
import '../playback/player_slot.dart';
import '../playback/video_source.dart';
import '../util/latest_only.dart';

enum FeedPhase {  /// Nothing requested yet.
  idle,

  /// First page in flight.
  loading,

  /// Playing (or paused by the user) with a live player.
  ready,

  /// Resolving the source or starting the player.
  buffering,

  /// The current item failed. [FeedController.error] says why.
  error,

  /// The index holds no video at all.
  empty,
}

/// Where feed items come from. Abstracted so the controller can be tested with
/// a fixed list and the app can page the local index.
abstract class FeedPageSource {
  bool get hasMore;
  Future<List<MediaRecord>> nextPage();
  void reset();
}

/// Pages the local mirror, newest first. No network: the feed never asks
/// Telegram for a list, it plays what the index already knows about.
class IndexFeedSource implements FeedPageSource {
  IndexFeedSource({
    required this.store,
    this.chatId,
    int pageSize = 40,
  }) : _pager = MediaPager(store: store, chatId: chatId, pageSize: pageSize);

  final IndexStore store;
  final int? chatId;
  final MediaPager _pager;

  @override
  bool get hasMore => _pager.hasMore;

  @override
  Future<List<MediaRecord>> nextPage() async {
    final page = await _pager.next();
    return page.items.where((r) => r.kind == MediaKind.video).toList();
  }

  @override
  void reset() => _pager.reset();
}

class FeedController extends ChangeNotifier {
  FeedController({
    required this.source,
    required this.player,
    required this.sources,
    this.chatTitles = const <int, String>{},
    bool defaultMuted = false,
    this.preloadAdjacent = true,
    this.pollInterval = const Duration(milliseconds: 250),
  })  : _muted = defaultMuted;

  final FeedPageSource source;
  final SinglePlayerController player;
  final VideoSourceResolver sources;

  /// `chatId -> channel title`, filled from the channel directory. Used for the
  /// bottom info line; a missing entry renders as "未知频道" rather than a blank.
  final Map<int, String> chatTitles;

  final bool preloadAdjacent;

  /// Playhead polling. Null in tests, where time does not pass.
  final Duration? pollInterval;

  final List<MediaRecord> _items = <MediaRecord>[];
  final LatestOnlySlot<String> _gate = LatestOnlySlot<String>();

  /// Paths resolved ahead of time, keyed by fileId. Bounded: three entries is
  /// the current item plus its two neighbours.
  final Map<int, String> _pathCache = <int, String>{};
  static const int _pathCacheLimit = 3;

  int _index = -1;
  FeedPhase _phase = FeedPhase.idle;
  String? _error;
  bool _controlVisible = false;
  bool _muted;
  bool _loadingMore = false;
  bool _releasedForBackground = false;
  bool _disposed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _bufferFraction = 0;
  Timer? _poll;

  List<MediaRecord> get items => List<MediaRecord>.unmodifiable(_items);
  int get index => _index;
  int get length => _items.length;
  FeedPhase get phase => _phase;
  String? get error => _error;
  bool get controlVisible => _controlVisible;
  bool get muted => _muted;
  bool get isLoadingMore => _loadingMore;
  Duration get position => _position;
  Duration get duration => _duration;
  double get bufferFraction => _bufferFraction;
  bool get isPlaying => player.active?.isPlaying ?? false;

  MediaRecord? get current {
    if (_index < 0 || _index >= _items.length) return null;
    return _items[_index];
  }

  bool get hasPrevious => _index > 0;

  bool get hasNext => _index + 1 < _items.length || source.hasMore;

  /// "3 / 40" for the info line; "0 / 0" is never shown because the empty state
  /// replaces the page.
  String get positionLabel => '${_index + 1} / ${_items.length}';

  String titleOf(MediaRecord record) {
    final channel = chatTitles[record.chatId];
    final name = record.fileName;
    if (name != null && name.isNotEmpty) return name;
    if (channel != null && channel.isNotEmpty) return channel;
    return '视频';
  }

  String get currentChannelTitle {
    final record = current;
    if (record == null) return '';
    return chatTitles[record.chatId] ?? '未知频道';
  }

  /// §4.2: a swipe counts as a page turn above 12% of the viewport height, or
  /// above 300 px/s regardless of distance.
  static bool shouldSwitchPage({
    required double dy,
    required double velocity,
    required double height,
  }) {
    if (height <= 0) return velocity.abs() > 300;
    return dy.abs() > height * 0.12 || velocity.abs() > 300;
  }

  /// Loads the first page and starts the first item.
  Future<void> load() async {
    _gate.cancelAll();
    _items.clear();
    _index = -1;
    _pathCache.clear();
    _error = null;
    _phase = FeedPhase.loading;
    _bufferFraction = 0;
    _notify();

    try {
      source.reset();
      await _appendUntilNonEmpty();
    } on Object catch (e) {
      _fail('读取媒体索引失败：$e');
      return;
    }

    if (_items.isEmpty) {
      _phase = FeedPhase.empty;
      _notify();
      return;
    }
    _index = 0;
    await _activateCurrent();
  }

  Future<void> retry() => load();

  /// Pulls pages until one contains a video or the source is exhausted.
  ///
  /// The index also holds photos and documents; a page made only of those must
  /// not be mistaken for "this channel has no videos".
  Future<void> _appendUntilNonEmpty({int maxPages = 5}) async {
    var pages = 0;
    while (pages < maxPages) {
      if (!source.hasMore) break;
      final page = await source.nextPage();
      pages++;
      // Filtered here as well as in the source: an item without a file id has
      // nothing to resolve, and a non-video item has nothing to play. Either
      // one reaching the feed would be a spinner that never ends.
      final playable = page
          .where((r) => r.kind == MediaKind.video && r.fileId != 0)
          .toList(growable: false);
      if (playable.isEmpty) continue;
      _items.addAll(playable);
      _notify();
      return;
    }
  }

  Future<void> goNext() async {
    if (_phase == FeedPhase.loading) return;
    if (_index + 1 >= _items.length) {
      if (!source.hasMore || _loadingMore) return;
      _loadingMore = true;
      _notify();
      try {
        await _appendUntilNonEmpty();
      } finally {
        _loadingMore = false;
        _notify();
      }
      if (_index + 1 >= _items.length) return;
    }
    await _moveTo(_index + 1);
  }

  Future<void> goPrevious() async {
    if (_index <= 0) return;
    await _moveTo(_index - 1);
  }

  /// Jumps to an absolute index. Used by the pager when it settles on a page
  /// the controller did not choose itself.
  Future<void> goToIndex(int target) async {
    if (target == _index) return;
    if (target < 0 || target >= _items.length) return;
    await _moveTo(target);
  }

  Future<void> _moveTo(int target) async {
    if (target < 0 || target >= _items.length) return;
    final leaving = current;

    // Invalidate any resolution in flight before touching the player: its
    // result belongs to the item the user just left.
    _gate.cancelAll();
    await player.release();
    if (leaving != null && leaving.fileId != 0) {
      // Only the current item's transfer is allowed to run (§4.5).
      unawaited(sources.cancel(leaving.fileId));
    }

    _index = target;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferFraction = 0;
    _controlVisible = false;
    _error = null;
    await _activateCurrent();
  }

  Future<void> _activateCurrent() async {
    final record = current;
    if (record == null) return;

    _phase = FeedPhase.buffering;
    _notify();

    String? path;
    try {
      path = await _gate.run(() async {
        final cached = _pathCache.remove(record.fileId);
        if (cached != null) return cached;
        return sources.resolve(
          record.fileId,
          onProgress: (update) {
            if (update.stage == SourceStage.fetching) {
              _bufferFraction = update.fraction;
              _notify();
            }
          },
        );
      });
    } on VideoSourceTimeout catch (e) {
      _fail(e.message);
      return;
    } on VideoSourceException catch (e) {
      _fail(e.message);
      return;
    } on Object catch (e) {
      _fail('$e');
      return;
    }

    // Null means a newer navigation already started. Do not touch the player.
    if (path == null || _disposed) return;

    try {
      await player.activate(path);
    } on Object {
      _fail('此视频无法解码');
      return;
    }
    if (_disposed) return;

    await _applyVolume();
    _phase = FeedPhase.ready;
    _bufferFraction = 0;
    _startPolling();
    _notify();
    await _prefetchNext();
  }

  Future<void> _prefetchNext() async {
    if (!preloadAdjacent) return;
    final next = _index + 1;
    if (next >= _items.length) return;
    final record = _items[next];
    if (record.fileId == 0 || _pathCache.containsKey(record.fileId)) return;
    try {
      final path = await sources.resolve(record.fileId);
      if (_disposed) return;
      _pathCache[record.fileId] = path;
      while (_pathCache.length > _pathCacheLimit) {
        _pathCache.remove(_pathCache.keys.first);
      }
    } on Object {
      // A failed prefetch is invisible by design: the item will be resolved
      // again (with a visible error) when the user actually reaches it.
    }
  }

  Future<void> togglePlayPause() async {
    final active = player.active;
    if (active == null) return;
    if (active.isPlaying) {
      await player.pauseActive();
    } else {
      await active.play();
    }
    refreshProgress();
    _notify();
  }

  Future<void> pause() async {
    await player.pauseActive();
    refreshProgress();
    _notify();
  }

  Future<void> seekTo(Duration target) async {
    final active = player.active;
    if (active is PlayerSeek) {
      await (active as PlayerSeek).seekTo(target);
    }
    _position = target;
    _notify();
  }

  Future<void> setMuted(bool muted) async {
    if (_muted == muted) return;
    _muted = muted;
    await _applyVolume();
    _notify();
  }

  Future<void> _applyVolume() async {
    final active = player.active;
    if (active is PlayerVolume) {
      await (active as PlayerVolume).setVolume(_muted ? 0 : 1);
    }
  }

  void toggleControls() {
    _controlVisible = !_controlVisible;
    _notify();
  }

  void setControlsVisible(bool visible) {
    if (_controlVisible == visible) return;
    _controlVisible = visible;
    _notify();
  }

  /// Reads the playhead from the live handle. Called by a UI timer, and
  /// directly by tests.
  void refreshProgress() {
    final active = player.active;
    if (active is PlayerProgress) {
      _position = (active as PlayerProgress).position;
      _duration = (active as PlayerProgress).duration;
    }
    _notify();
  }

  /// §4.5: releasing on background keeps audio from continuing and frees the
  /// decoder. Coming back re-activates the same item, not the first one.
  Future<void> handleLifecycle(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (!_releasedForBackground) return;
      _releasedForBackground = false;
      await _activateCurrent();
      return;
    }
    _releasedForBackground = true;
    _stopPolling();
    await player.release();
  }

  void _startPolling() {
    final interval = pollInterval;
    if (interval == null || _poll != null) return;
    _poll = Timer.periodic(interval, (_) => refreshProgress());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _fail(String message) {
    _phase = FeedPhase.error;
    _error = message;
    _bufferFraction = 0;
    _stopPolling();
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Releases the player, stops the transfer and the poll timer. Must be called
  /// before [dispose] from a widget that can await.
  Future<void> shutdown() async {
    _gate.cancelAll();
    _stopPolling();
    final record = current;
    if (record != null && record.fileId != 0) {
      unawaited(sources.cancel(record.fileId));
    }
    await player.release();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _gate.cancelAll();
    super.dispose();
  }
}

/// Which overlay layers the feed shows for a given screen orientation.
///
/// Confirmed design decision #4: in landscape the bottom info block is hidden so
/// the video gets the whole screen. The controls stay: a landscape video with no
/// way to pause or rotate back is a trap.
@immutable
class FeedOverlayPlan {
  const FeedOverlayPlan({
    required this.showInfo,
    required this.showTopBar,
    required this.showControls,
  });

  factory FeedOverlayPlan.forOrientation(Orientation orientation) {
    final portrait = orientation == Orientation.portrait;
    return FeedOverlayPlan(
      showInfo: portrait,
      showTopBar: true,
      // Controls are only rendered when the user asked for them AND there is
      // room; hiding them in landscape would remove the rotate-back button.
      showControls: true,
    );
  }

  final bool showInfo;
  final bool showTopBar;
  final bool showControls;

  @override
  bool operator ==(Object other) =>
      other is FeedOverlayPlan &&
      other.showInfo == showInfo &&
      other.showTopBar == showTopBar &&
      other.showControls == showControls;

  @override
  int get hashCode => Object.hash(showInfo, showTopBar, showControls);

  @override
  String toString() =>
      'FeedOverlayPlan(info=$showInfo, top=$showTopBar, controls=$showControls)';
}
