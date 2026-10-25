import 'dart:io';

import 'package:video_player/video_player.dart';

import 'player_slot.dart';

class VideoPlayerFactory implements PlayerFactory {
  const VideoPlayerFactory();

  @override
  PlayerHandle create(String path) => VideoPlayerHandle(path: path);
}

/// `video_player`-backed player.
///
/// [disposePlayer] is the only place a controller is torn down, and it does all
/// four things the task book asks for: pause, detach the listener, null out the
/// Dart-held reference (so nothing can reach the AVPlayer afterwards) and call
/// the plugin's dispose, which releases the underlying `AVPlayerItem`.
class VideoPlayerHandle implements PlayerHandle {
  VideoPlayerHandle({required this.path})
      : _controller = VideoPlayerController.file(File(path));

  @override
  final String path;

  VideoPlayerController? _controller;
  bool _listenerAttached = false;
  bool _disposed = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  Duration get position => _position;
  Duration get duration => _duration;
  String? get error => _error;

  VideoPlayerController? get controller => _controller;

  @override
  bool get isDisposed => _disposed;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Future<void> load() async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('VideoPlayerHandle used after dispose: $path');
    }
    await controller.initialize();
    controller.addListener(_onValueChanged);
    _listenerAttached = true;
  }

  @override
  Future<void> play() async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    if (!controller.value.isInitialized) {
      throw StateError('play() before load() completed: $path');
    }
    await controller.play();
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    if (!controller.value.isInitialized) return;
    await controller.pause();
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    _controller = null; // nothing can touch the AVPlayer through this handle now
    if (controller == null) return;
    if (_listenerAttached) {
      controller.removeListener(_onValueChanged);
      _listenerAttached = false;
    }
    try {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {
      // Ignore: disposal must not fail because a player already died.
    }
    await controller.dispose();
  }

  void _onValueChanged() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    _position = value.position;
    _duration = value.duration;
    if (value.hasError) _error = value.errorDescription;
  }
}
