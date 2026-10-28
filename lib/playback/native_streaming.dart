import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'player_slot.dart';
import 'resource_loader.dart';
import 'streaming_diagnostics.dart';

/// Streaming V2 switch.
///
/// V2 is the default transport on iOS and the only place it can run: the
/// transport is `AVAssetResourceLoader`, which does not exist anywhere else.
/// Everything else keeps the V1 loopback proxy, which still works and is what
/// a V2 failure falls back to.
class StreamingV2 {
  StreamingV2._();

  static bool? _override;

  /// Tests and the settings panel can force V2 off without touching the code.
  static set enabledOverride(bool? value) => _override = value;

  static bool get supported {
    final forced = _override;
    if (forced != null) return forced;
    if (kIsWeb) return false;
    return Platform.isIOS;
  }

  /// The player source label the diagnostics report for a V2 play.
  static const String sourceLabel = 'RESOURCE_LOADER';

  /// V2 is the only automatic streaming path, and there is no flag for it.
  ///
  /// There used to be a `v2Only` const here that the feed controller read to
  /// decide whether a V2 failure could fall back to the loopback proxy. A
  /// constant is one edit away from being flipped, and the fallback it guarded
  /// is exactly the transport the device reports indicted. The controller no
  /// longer names the proxy at all: `test/architecture_scan_test.dart` fails if
  /// `_tryV1` or `allowProxy: true` ever comes back.
}

/// `MethodChannel` implementation of the native transport.
///
/// Three channels, one purpose each:
/// * `tgmedia/streaming` — Dart → native commands (session, player, seek);
/// * `tgmedia/streaming/supply` — native → Dart byte requests;
/// * `tgmedia/streaming/events` — native → Dart player status.
class MethodChannelStreamingTransport implements NativeStreamingTransport {
  MethodChannelStreamingTransport({
    MethodChannel? control,
    EventChannel? events,
  })  : _control = control ?? const MethodChannel(kStreamingControlChannel),
        _events = events ?? const EventChannel(kStreamingEventChannel);

  final MethodChannel _control;
  final EventChannel _events;
  Stream<Map<String, Object?>>? _eventStream;

  @override
  bool get supported => StreamingV2.supported;

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _control.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (e) {
      throw StreamingV2Unavailable('native bridge missing: $method', e);
    } on PlatformException catch (e) {
      throw StreamingV2Unavailable('${e.code}: ${e.message}', e);
    }
  }

  @override
  Future<Map<String, Object?>?> openSession({
    required String sessionId,
    required int fileId,
    required int chatId,
    required int messageId,
    required int generation,
    required int totalBytes,
    required bool completed,
    required String mimeType,
  }) async {
    final reply = await _call<Map<Object?, Object?>>('openSession', <String, Object?>{
      'sessionId': sessionId,
      'fileId': fileId,
      'chatId': chatId,
      'messageId': messageId,
      'generation': generation,
      'totalBytes': totalBytes,
      'completed': completed,
      'mimeType': mimeType,
    });
    if (reply == null) return null;
    return reply.cast<String, Object?>();
  }

  @override
  Future<void> closeSession(String sessionId) =>
      _call<void>('closeSession', <String, Object?>{'sessionId': sessionId});

  @override
  Future<void> createPlayer(String sessionId) =>
      _call<void>('createPlayer', <String, Object?>{'sessionId': sessionId});

  @override
  Future<void> play(String sessionId) =>
      _call<void>('play', <String, Object?>{'sessionId': sessionId});

  @override
  Future<void> pause(String sessionId) =>
      _call<void>('pause', <String, Object?>{'sessionId': sessionId});

  @override
  Future<void> seek(String sessionId, Duration position) =>
      _call<void>('seek', <String, Object?>{
        'sessionId': sessionId,
        'positionMs': position.inMilliseconds,
      });

  @override
  Future<void> setVolume(String sessionId, double volume) =>
      _call<void>('setVolume', <String, Object?>{
        'sessionId': sessionId,
        'volume': volume,
      });

  @override
  Future<void> disposePlayer(String sessionId) =>
      _call<void>('disposePlayer', <String, Object?>{'sessionId': sessionId});

  @override
  Stream<Map<String, Object?>> events() {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map<Map<String, Object?>>((event) => event is Map
            ? event.cast<String, Object?>()
            : const <String, Object?>{})
        .asBroadcastStream();
  }
}

/// Thrown when the platform has no V2 bridge, or it refused the session.
class StreamingV2Unavailable implements Exception {
  StreamingV2Unavailable(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'StreamingV2Unavailable: $message';
}

/// `AVPlayer` behind `AVAssetResourceLoader`, driven from Dart.
///
/// Same [PlayerHandle] contract as the `video_player` handle, so the feed does
/// not know which transport is in use: `load()` waits for the native item to
/// become ready, `play`/`pause`/`seek` forward, `disposePlayer` releases the
/// item and the session.
class NativeStreamPlayerHandle
    implements
        PlayerHandle,
        PlayerProgress,
        PlayerVolume,
        PlayerSeek,
        PlayerErrorReporter {
  NativeStreamPlayerHandle({
    required this.sessionId,
    required this.transport,
    this.initializeTimeout = const Duration(seconds: 20),
    this.onEvent,
  }) : path = '$kResourceLoaderScheme://video/$sessionId';

  /// The session id doubles as the player id: one play, one session, one item.
  final String sessionId;
  final NativeStreamingTransport transport;

  /// Bound only until `ready`. The data requests themselves are never bounded:
  /// waiting for a tail range is normal and must not be mistaken for failure.
  /// What this bounds is "the item never became ready at all", which is the
  /// decision point for falling back to V1.
  final Duration initializeTimeout;

  final void Function(String event)? onEvent;

  @override
  final String path;

  final Completer<bool> _ready = Completer<bool>();
  StreamSubscription<Map<String, Object?>>? _events;

  bool _disposed = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  bool _buffering = true;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isDisposed => _disposed;
  @override
  String? get lastError => _error;

  /// True while the native item is still waiting for its first playable frame.
  bool get isBuffering => _buffering;

  @override
  Future<void> load() async {
    if (_disposed) throw StateError('NativeStreamPlayerHandle used after dispose');
    _events = transport.events().listen(
          _onEvent,
          onError: (Object _) {
            // A dead event channel means the player is gone; the initialize
            // bound below is what turns that into a fallback.
          },
        );
    await transport.createPlayer(sessionId);
    try {
      final ok = await _ready.future.timeout(initializeTimeout);
      if (!ok) {
        throw StateError(_error ?? '播放器初始化失败');
      }
    } on TimeoutException {
      throw StateError(
          'AVPlayer ${initializeTimeout.inSeconds}s 内未就绪（${_error ?? "无错误信息"}）');
    }
  }

  void _onEvent(Map<String, Object?> event) {
    final id = event['playerId'];
    if (id != null && id != sessionId) return;
    final type = event['type'] as String? ?? '';
    // The native side speaks in short type names; the diagnostics log speaks
    // in the names the acceptance report asked for. One translation table, so
    // a report line and a native event can always be matched up.
    final logged = _nativeEventNames[type];
    if (logged != null) {
      StreamingDiagnostics.instance.noteResourceLoaderEvent(
        logged,
        fields: <String, Object?>{
          for (final entry in event.entries)
            if (entry.key != 'type' && entry.key != 'playerId')
              entry.key: entry.value,
        },
      );
    }
    switch (type) {
      case 'ready':
        _buffering = false;
        _duration = _ms(event['durationMs']);
        _complete(true);
      case 'failed':
        _error = (event['message'] as String?) ?? 'AVPlayer 失败';
        _buffering = false;
        _complete(false);
      case 'tick':
        _position = _ms(event['positionMs']);
        final duration = _ms(event['durationMs']);
        if (duration > Duration.zero) _duration = duration;
        final playing = event['isPlaying'];
        if (playing is bool) _playing = playing;
      case 'buffering':
        final buffering = event['buffering'];
        if (buffering is bool) _buffering = buffering;
      case 'firstFrame':
        // The player really started showing frames: the only moment that
        // counts as "first playback" for the acceptance report.
        onEvent?.call('firstFrame');
      case 'ended':
        _playing = false;
      default:
        break;
    }
    StreamingDiagnostics.instance.updatePlayer(
      position: _position,
      duration: _duration,
      isPlaying: _playing,
      isBuffering: _buffering,
      error: _error,
    );
  }

  void _complete(bool ok) {
    if (!_ready.isCompleted) _ready.complete(ok);
  }

  /// Native event type → the name the diagnostics log records.
  static const Map<String, String> _nativeEventNames = <String, String>{
    'sessionOpen': 'sessionOpen',
    'contentInfo': 'contentInfoReady',
    'dataRequest': 'dataRequestCreated',
    'waiting': 'waitingForGrowth',
    'requestFinished': 'dataRequestFinished',
    'requestCancelled': 'dataRequestCancelled',
    'supplyError': 'supplyError',
    'playerCreated': 'playerItemCreated',
    'ready': 'playerReady',
    'failed': 'playerFailed',
    'firstFrame': 'firstFrame',
  };

  static Duration _ms(Object? value) {
    final ms = value is int ? value : (value is num ? value.toInt() : 0);
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    await transport.play(sessionId);
    _playing = true;
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await transport.pause(sessionId);
    _playing = false;
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_disposed) return;
    await transport.seek(sessionId, position);
    _position = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    await transport.setVolume(sessionId, volume.clamp(0, 1).toDouble());
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;
    await _events?.cancel();
    _events = null;
    try {
      await transport.disposePlayer(sessionId);
    } on Object {
      // Disposal must not fail because the item already died.
    }
    _complete(false);
  }
}

/// Renders the native `AVPlayerLayer` of [sessionId].
///
/// Only the rendering is native. Every overlay, gesture and page transition
/// stays in Flutter, so the immersive feed looks exactly as before.
class NativePlayerView extends StatelessWidget {
  const NativePlayerView({
    required this.sessionId,
    super.key,
  });

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    if (!StreamingV2.supported) {
      return const SizedBox.shrink();
    }
    return UiKitView(
      viewType: 'tgmedia/player_view',
      creationParams: <String, Object?>{'playerId': sessionId},
      creationParamsCodec: const StandardMessageCodec(),
      // The feed's own gesture detector must keep receiving taps; without this
      // the platform view swallows them and the controls never appear.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }
}
