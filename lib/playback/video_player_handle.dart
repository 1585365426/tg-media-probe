import 'dart:async';
import 'dart:io';

import 'package:video_player/video_player.dart';

import 'native_streaming.dart';
import 'player_slot.dart';
import 'resource_loader.dart';
import 'streaming_diagnostics.dart';

class VideoPlayerFactory implements PlayerFactory {
  const VideoPlayerFactory({
    this.streamingInitTimeout = const Duration(seconds: 12),
    this.onValueChanged,
    this.nativeTransport,
    this.nativeInitTimeout = const Duration(seconds: 20),
  });

  /// V2 bridge. Injected in tests; `MethodChannel` on a device.
  final NativeStreamingTransport? nativeTransport;

  /// Bound on "the native item never became ready". Data requests are not
  /// bounded — waiting for a tail range is normal.
  final Duration nativeInitTimeout;

  /// Forwards every player value change to the diagnostics panel, so the
  /// playhead / status / decoder error shown there are the player's own
  /// numbers and not a second, separate observation.
  final void Function(VideoPlayerValue value)? onValueChanged;

  /// Bound only for stream sources: an MP4 whose moov sits at the end makes
  /// AVPlayer request ranges far ahead of the download, and without a bound
  /// the initialize would hang instead of triggering the full-download
  /// fallback. Local files keep the unbounded (and fast) behaviour.
  final Duration streamingInitTimeout;

  @override
  PlayerHandle create(String path) {
    // A `tgmedia://` URL is the V2 transport: the bytes come from
    // AVAssetResourceLoader, so `video_player` (which only understands file and
    // http URLs) must not see it.
    if (path.startsWith('$kResourceLoaderScheme://')) {
      return NativeStreamPlayerHandle(
        sessionId: Uri.parse(path).pathSegments.last,
        transport: nativeTransport ?? MethodChannelStreamingTransport(),
        initializeTimeout: nativeInitTimeout,
      );
    }
    return VideoPlayerHandle(
      path: path,
      // Only a loopback stream URL gets the bound initialize; the check lives
      // here so the handle itself stays a dumb lifecycle wrapper.
      initializeTimeout: path.startsWith('http') ? streamingInitTimeout : null,
      onValueChanged: onValueChanged,
    );
  }
}

/// `video_player`-backed player.
///
/// [disposePlayer] is the only place a controller is torn down, and it does all
/// four things the task book asks for: pause, detach the listener, null out the
/// Dart-held reference (so nothing can reach the AVPlayer afterwards) and call
/// the plugin's dispose, which releases the underlying `AVPlayerItem`.
class VideoPlayerHandle
    implements PlayerHandle, PlayerProgress, PlayerVolume, PlayerSeek, PlayerErrorReporter {
  /// [path] is either a local file path (complete cache) or a loopback
  /// `http://127.0.0.1/...` URL (streaming through the local range proxy).
  /// Same player, same lifecycle — only the source the AVURLAsset opens
  /// differs, so no third-party player and no factory split is needed.
  VideoPlayerHandle({
    required this.path,
    this.initializeTimeout,
    this.onValueChanged,
  }) : _controller = path.startsWith('http')
            ? VideoPlayerController.networkUrl(Uri.parse(path))
            : VideoPlayerController.file(File(path));

  /// Bound while the source is a stream: an MP4 with its moov at the end makes
  /// AVPlayer request ranges far ahead of the download, and the proxy answer
  /// is "keep waiting" — an unbounded initialize would hang the page instead
  /// of triggering the full-download fallback. Local files initialise fast
  /// (AVAsset does not read the whole file), so they keep the no-timeout
  /// behaviour the current fast path relies on.
  final Duration? initializeTimeout;

  /// Set by the factory; publishes each value change to the diagnostics panel.
  final void Function(VideoPlayerValue value)? onValueChanged;

  @override
  final String path;

  VideoPlayerController? _controller;
  bool _listenerAttached = false;
  bool _disposed = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  String? get error => _error;

  VideoPlayerController? get controller => _controller;

  @override
  Future<void> setVolume(double volume) async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    if (!controller.value.isInitialized) return;
    await controller.setVolume(volume.clamp(0, 1).toDouble());
  }

  @override
  Future<void> seekTo(Duration position) async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    if (!controller.value.isInitialized) return;
    await controller.seekTo(position);
  }

  @override
  bool get isDisposed => _disposed;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  String? get lastError => _error;

  @override
  Future<void> load() async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('VideoPlayerHandle used after dispose: $path');
    }
    final timeout = initializeTimeout;
    if (timeout == null) {
      await controller.initialize();
    } else {
      // A stream that cannot initialise in time is the moov-at-the-end case;
      // the timeout is what converts a silent hang into a fallback decision.
      await controller.initialize().timeout(timeout);
    }
    controller.addListener(_onValueChanged);
    _listenerAttached = true;
    _onValueChanged(); // publish the initial state, not just later changes
  }

  /// Feeds one player value into the shared streaming diagnostics.
  ///
  /// Every field is the player's own view of itself — rate, buffering,
  /// playhead and decoder error — so the verdict in the diagnostics panel is
  /// built from what AVPlayer actually did.
  static void reportValue(VideoPlayerValue value) {
    StreamingDiagnostics.instance.updatePlayer(
      position: value.position,
      duration: value.duration,
      isPlaying: value.isPlaying,
      isBuffering: value.isBuffering,
      error: value.hasError ? value.errorDescription : null,
    );
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
    // Straight to the diagnostics panel: what AVPlayer just reported.
    final sink = onValueChanged;
    if (sink != null) sink(value);
  }
}
