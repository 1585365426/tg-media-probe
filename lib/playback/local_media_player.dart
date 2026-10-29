/// The only player in the app: a local file opened by `video_player` (AVPlayer
/// underneath), plus a lifecycle that cannot leak.
///
/// Everything the old architecture needed — resource loaders, range proxies,
/// growing files, chunk stores — exists to feed a player that is reading bytes
/// from somewhere other than a complete file. Since playback now starts only
/// after the file is complete, none of that is needed: AVPlayer gets a file URL
/// and streams it from disk itself, which is both simpler and lighter on RAM.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// What [PlaybackController] needs from a player, so tests can drive the state
/// machine without an AVPlayer.
abstract class MediaPlayerHandle {
  Future<void> open();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> dispose();

  bool get isInitialized;
  bool get isPlaying;
  Duration get position;
  Duration get duration;
  double get aspectRatio;
  String? get error;
  Listenable get notifier;
}

typedef MediaPlayerFactory = MediaPlayerHandle Function(String path);

class LocalMediaPlayer implements MediaPlayerHandle {
  LocalMediaPlayer({
    required this.path,
    this.looping = false,
  });

  final String path;
  final bool looping;

  VideoPlayerController? _controller;
  bool _disposed = false;

  /// Exposed so the page can put `VideoPlayer` on screen. Null after dispose,
  /// which is what makes "the old player is really gone" testable.
  VideoPlayerController? get controller => _controller;

  @override
  Listenable get notifier => _controller ?? _nullListenable;

  static final ChangeNotifier _nullListenable = ChangeNotifier();

  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  Duration get duration => _controller?.value.duration ?? Duration.zero;

  @override
  double get aspectRatio {
    final ratio = _controller?.value.aspectRatio ?? 0;
    return ratio > 0 ? ratio : 16 / 9;
  }

  @override
  String? get error {
    final value = _controller?.value;
    if (value == null || !value.hasError) return null;
    return value.errorDescription;
  }

  @override
  Future<void> open() async {
    if (_disposed) throw StateError('player used after dispose');
    if (!File(path).existsSync()) {
      throw StateError('local file is missing: $path');
    }
    // `file` and not `networkUrl`: the whole point of the LOCAL_FILE chain is
    // that AVPlayer reads a complete file from disk and never touches the
    // network while playing.
    final controller = VideoPlayerController.file(File(path));
    _controller = controller;
    await controller.initialize();
    if (looping) await controller.setLooping(true);
  }

  @override
  Future<void> play() async {
    final controller = _controller;
    if (controller == null || _disposed || !controller.value.isInitialized) {
      return;
    }
    await controller.play();
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller == null || _disposed || !controller.value.isInitialized) {
      return;
    }
    await controller.pause();
  }

  @override
  Future<void> seekTo(Duration position) async {
    final controller = _controller;
    if (controller == null || _disposed || !controller.value.isInitialized) {
      return;
    }
    await controller.seekTo(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    final controller = _controller;
    if (controller == null || _disposed || !controller.value.isInitialized) {
      return;
    }
    await controller.setPlaybackSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    final controller = _controller;
    if (controller == null || _disposed || !controller.value.isInitialized) {
      return;
    }
    await controller.setVolume(volume.clamp(0, 1).toDouble());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    // Drop the reference first: nothing in this app can reach the AVPlayer
    // through a stale field while the plugin tears it down.
    _controller = null;
    if (controller == null) return;
    try {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        await controller.pause();
      }
    } on Object {
      // A player that already died does not need to be paused.
    }
    await controller.dispose();
  }
}
