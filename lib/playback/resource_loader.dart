import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'stream_proxy.dart' show FileProgressWatch;
import 'streaming_diagnostics.dart';

/// Streaming V2: the byte supply behind `AVAssetResourceLoader`.
///
/// V1 answered the player over loopback HTTP, which meant every AVPlayer range
/// had to be translated into an HTTP status line, a Content-Range header and a
/// connection lifetime. Three of the device failures came from exactly that
/// translation (a 206 that declared 659 MB and carried 2 MB, a tail probe that
/// closed the head response, a duplicate tail that stole the download window).
///
/// V2 removes the HTTP layer: AVFoundation asks for a byte range, this session
/// answers with the bytes that exist and keeps answering as the file grows.
/// The transport no longer has a status line to get wrong.
///
/// What stays here, on the Dart side:
/// * the TDLib download window (it must follow what the player is asking for);
/// * "which bytes are readable right now" (the growing-file model);
/// * the generation guard, so a superseded play cannot serve a byte.
///
/// What moves to Swift: `AVAssetResourceLoaderDelegate`, the content
/// information block, and the repeated `respond(with:)` calls.

/// Method channel the native player calls to obtain bytes.
const String kStreamingSupplyChannel = 'tgmedia/streaming/supply';

/// Method channel the Dart side drives the native player with.
const String kStreamingControlChannel = 'tgmedia/streaming';

/// Event channel the native player reports status on.
const String kStreamingEventChannel = 'tgmedia/streaming/events';

/// URL scheme of a resource-loader play. No host, no port, no socket.
const String kResourceLoaderScheme = 'tgmedia';

/// One answer to "give me bytes at [from]".
///
/// [from]/[to] are absolute file offsets that are readable *now*, derived from
/// the growing file and the current TDLib window — never from the requested
/// length. `to < 0` means "nothing readable at that offset yet", which is a
/// wait, not a failure.
class SupplyReading {
  const SupplyReading({
    required this.from,
    required this.to,
    required this.total,
    required this.completed,
    required this.downloading,
    this.path = '',
    this.waitingMillis = 0,
    this.errorCode,
    this.errorMessage,
  });

  /// First readable offset for the request (`-1` when none).
  final int from;

  /// Last readable offset of that run (`-1` when none).
  final int to;

  /// TDLib's total size for the file, 0 while unknown.
  final int total;

  /// The whole file is on disk.
  final bool completed;

  /// The transfer is still advancing (false once it is stalled).
  final bool downloading;

  /// The local file the reader must open.
  final String path;

  /// How long this offset has been unreadable.
  final int waitingMillis;

  /// Set only for a terminal condition, never for "not yet".
  final String? errorCode;
  final String? errorMessage;

  bool get hasData => from >= 0 && to >= from;

  int get length => hasData ? to - from + 1 : 0;

  Map<String, Object?> toMap() => <String, Object?>{
        'path': path,
        'from': from,
        'to': to,
        'total': total,
        'completed': completed,
        'downloading': downloading,
        'waitingMillis': waitingMillis,
        if (errorCode != null) 'errorCode': errorCode,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  static SupplyReading fromMap(Map<Object?, Object?> map) {
    int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
    bool asBool(Object? v) => v == true;
    return SupplyReading(
      path: map['path'] as String? ?? '',
      from: asInt(map['from']),
      to: asInt(map['to']),
      total: asInt(map['total']),
      completed: asBool(map['completed']),
      downloading: asBool(map['downloading']),
      waitingMillis: asInt(map['waitingMillis']),
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  static const SupplyReading none = SupplyReading(
    from: -1,
    to: -1,
    total: 0,
    completed: false,
    downloading: true,
  );

  @override
  String toString() =>
      'supply[$from..$to/$total${completed ? ' complete' : ''}]';
}

/// The growing file, as the resource loader sees it.
///
/// Deliberately stateless about the *player*: [read] is called once per
/// chunk request and answers from the file state that exists at that instant.
/// Waiting is the caller's job (native polls), which keeps a long
/// `AVAssetResourceLoadingDataRequest` from blocking a Dart future for the
/// length of a film.
class ResourceSupply {
  ResourceSupply({
    required this.fileId,
    required this.watch,
    this.onEvent,
    this.onTypedEvent,
    this.steerGapBytes = 256 * 1024,
    this.resumeGapBytes = 4 * 1024 * 1024,
    this.windowBytes = 16 * 1024 * 1024,
    this.stallGrace = const Duration(seconds: 20),
    this.steerCooldown = const Duration(seconds: 2),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _lastAdvance = (clock ?? DateTime.now)();

  final int fileId;
  final FileProgressWatch watch;
  final void Function(String event)? onEvent;

  /// Structured version of [onEvent]: the named events the diagnostics panel
  /// and the acceptance report read (`growthDetected`, `waitingForGrowth`,
  /// `targetedDownloadRequested`, `resumeSequential`). Free text cannot be
  /// counted, and "how many targets did the loader pull" is a counted
  /// question.
  final void Function(String name, Map<String, Object?> fields)? onTypedEvent;

  /// Inside this gap the sequential download is about to arrive on its own, so
  /// the window is left alone.
  final int steerGapBytes;

  /// Nothing at the head yet and the request is close to it: restart the
  /// sequential download instead of opening a window somewhere else.
  final int resumeGapBytes;

  /// Size of a targeted window. TDLib replaces the running download with it,
  /// so a small window is what keeps this from degenerating into a full
  /// download: 16 MB is several seconds of video and one moov probe.
  final int windowBytes;

  /// No growth for this long, while the file is still incomplete, is the only
  /// condition reported as a stall. A paused player, a slow link and a TDLib
  /// chunk boundary all stay below it, and the request keeps waiting.
  final Duration stallGrace;

  /// Minimum time between two window moves. AVPlayer polls a data request in a
  /// tight loop; without this every poll would restart the TDLib transfer.
  final Duration steerCooldown;

  final DateTime Function() _clock;

  DateTime _lastAdvance;
  int _seenHead = -1;
  int _seenReach = -1;
  bool _seenComplete = false;
  String _steerKey = '';
  DateTime? _steerAt;
  int _steerFrom = -1;
  int _steerTo = -1;
  bool _windowed = false;
  int _steers = 0;
  int _waits = 0;
  int _stalls = 0;

  int get steerCount => _steers;
  int get waitCount => _waits;
  int get stallCount => _stalls;

  /// Reads the state for [offset]. Never throws: every outcome is a reading,
  /// because "the bytes are not there yet" is the normal case for a growing
  /// file and must not look like an exception to the transport.
  Future<SupplyReading> read(int offset) async {
    final now = _clock();
    final total = watch.expectedBytes;
    final path = watch.localPath;

    // Disk first: `updateFile` stops once TDLib considers the file finished,
    // so a supply that begins after that point would otherwise wait on
    // silence forever. The stat is only paid when there is nothing to serve.
    var reach = watch.readableEndFrom(offset);
    if (!watch.isComplete && reach < offset) {
      await watch.refresh();
      reach = watch.readableEndFrom(offset);
    }

    if (watch.isComplete) {
      return SupplyReading(
        path: path,
        from: offset,
        to: math.max(offset, total - 1),
        total: total,
        completed: true,
        downloading: false,
      );
    }

    // Progress is measured against what this loader can see: the head prefix
    // and the reach at the offset it is serving. A window move that lands new
    // bytes is progress too — the request may be waiting on a region the
    // sequential download will never reach.
    final head = watch.headBytes;
    if (head != _seenHead || reach != _seenReach || watch.isComplete != _seenComplete) {
      _seenHead = head;
      _seenReach = reach;
      _seenComplete = watch.isComplete;
      _lastAdvance = now;
      onTypedEvent?.call('growthDetected', <String, Object?>{
        'head': head,
        'reach': reach,
        'total': total,
      });
    }

    if (reach >= offset) {
      return SupplyReading(
        path: path,
        from: offset,
        to: reach,
        total: total,
        completed: false,
        downloading: true,
      );
    }

    // Not on disk yet. Move the window only when waiting cannot help.
    await _steerIfNeeded(offset, head, total);

    final waited = _clock().difference(_lastAdvance);
    final stalled = waited >= stallGrace;
    if (stalled) _stalls++;
    _waits++;
    onTypedEvent?.call('waitingForGrowth', <String, Object?>{
      'offset': offset,
      'waitedMs': waited.inMilliseconds,
      'head': head,
      'total': total,
      'stalled': stalled,
    });
    return SupplyReading(
      path: path,
      from: -1,
      to: -1,
      total: total,
      completed: false,
      downloading: !stalled,
      waitingMillis: waited.inMilliseconds,
      errorCode: stalled ? 'DOWNLOAD_STALLED' : null,
      errorMessage: stalled
          ? 'TDLib 已 ${stallGrace.inSeconds} 秒没有写入新数据（offset=$offset，'
              '已下载到 ${head > 0 ? head : "窗口外"}，total=$total）'
          : null,
    );
  }

  Future<void> _steerIfNeeded(int offset, int head, int total) async {
    if (total <= 0) return;
    final now = _clock();

    // The request sits at the head the sequential download is already filling.
    if (offset <= head + steerGapBytes) {
      if (_windowed && offset <= resumeGapBytes) {
        // The window is parked somewhere else and nothing has reached the
        // head; waiting here would wait forever.
        _windowed = false;
        _steerFrom = -1;
        _steerTo = -1;
        try {
          await watch.resumeSequential();
          onEvent?.call('resume sequential (offset=$offset head=$head)');
          onTypedEvent?.call('resumeSequential', <String, Object?>{
            'offset': offset,
            'head': head,
          });
        } on Object catch (e) {
          onEvent?.call('resume failed: $e');
        }
      }
      return;
    }

    // The range is already being downloaded for this player: AVPlayer asks for
    // the same tail many times (once per probe, once per repeat) and every
    // repeat must not restart the TDLib transfer.
    if (_windowed && offset >= _steerFrom && offset <= _steerTo) return;

    final from = offset & ~1023; // TDLib chunks on 1 KB boundaries
    final end = math.min(total - 1, from + windowBytes - 1);
    final key = '$from-$end';
    if (key == _steerKey) {
      final at = _steerAt;
      if (at != null && now.difference(at) < steerCooldown) return;
    }

    _steerFrom = from;
    _steerTo = end;
    _steerKey = key;
    _steerAt = now;
    _steers++;
    _windowed = true;
    onEvent?.call('window $key (offset=$offset head=$head)');
    onTypedEvent?.call('targetedDownloadRequested', <String, Object?>{
      'from': from,
      'to': end,
      'offset': offset,
    });
    try {
      await watch.requestWindow(from, end);
    } on Object catch (e) {
      onEvent?.call('window failed $key: $e');
    }
  }
}

/// Everything the native loader needs to know about one play.
///
/// One session per play attempt. Closing it is what makes every later native
/// callback fail with `SESSION_CLOSED` instead of serving a byte of a video the
/// user has already swiped past.
class ResourceLoaderSession {
  ResourceLoaderSession({
    required this.sessionId,
    required this.fileId,
    required this.chatId,
    required this.messageId,
    required this.generation,
    required this.watch,
    required this.mimeType,
    required this.transport,
    this.activeGeneration,
    this.diagnostics,
    this.clock,
  }) : supply = ResourceSupply(
          fileId: fileId,
          watch: watch,
          clock: clock,
          onEvent: (event) => diagnostics?.noteResourceLoader('supply: $event',
              generation: generation),
          onTypedEvent: (name, fields) => diagnostics?.noteResourceLoaderEvent(
            name,
            fields: fields,
            generation: generation,
          ),
        );

  final String sessionId;
  final int fileId;
  final int chatId;
  final int messageId;

  /// The play generation this session belongs to.
  final int generation;

  final FileProgressWatch watch;
  final String mimeType;
  final NativeStreamingTransport transport;
  final ResourceSupply supply;
  final StreamingDiagnostics? diagnostics;

  /// Everything older than this is stale. Supplied by the feed controller, so
  /// the transport sees the same number the UI uses.
  final int Function()? activeGeneration;

  final DateTime Function()? clock;

  /// Called when the session closes. The host uses it to drop the entry, so a
  /// native callback from a finished play finds nothing to serve.
  void Function()? onClosed;

  bool _opened = false;
  bool _closed = false;
  int _dataRequests = 0;
  int _responds = 0;
  int _bytesServed = 0;

  int get bytesServed => _bytesServed;
  int get dataRequests => _dataRequests;
  int get responds => _responds;

  /// What the native asset should open. A scheme AVFoundation does not
  /// recognise, so the request must come back through the delegate.
  String get url => '$kResourceLoaderScheme://video/$sessionId';

  bool get isClosed => _closed;

  /// Registers the session with the native side and hands over the facts
  /// AVFoundation needs before it can make any request: total length,
  /// completeness and MIME type. Throws when the platform bridge is missing or
  /// refuses the session — the caller then falls back to V1.
  Future<void> open() async {
    if (_opened) return;
    diagnostics?.noteResourceLoaderEvent(
      'resourceLoaderCreated',
      fields: <String, Object?>{
        'sessionId': sessionId,
        'totalBytes': watch.expectedBytes,
        'completed': watch.isComplete,
        'mimeType': mimeType,
      },
      generation: generation,
    );
    diagnostics?.noteResourceLoaderEvent(
      'contentInfoRequested',
      fields: <String, Object?>{'totalBytes': watch.expectedBytes},
      generation: generation,
    );
    final reply = await transport.openSession(
      sessionId: sessionId,
      fileId: fileId,
      chatId: chatId,
      messageId: messageId,
      generation: generation,
      totalBytes: watch.expectedBytes,
      completed: watch.isComplete,
      mimeType: mimeType,
    );
    if (reply == null) {
      throw StateError('resource loader session rejected by the platform');
    }
    _opened = true;
    diagnostics?.noteResourceLoader(
      'contentInfo total=${reply['totalBytes']} '
      'type=${reply['contentType']} byteRange=${reply['byteRangeAccessSupported']}',
      generation: generation,
    );
    diagnostics?.noteResourceLoaderEvent(
      'contentInfoReady',
      fields: <String, Object?>{
        'totalBytes': reply['totalBytes'],
        'contentType': reply['contentType'],
        'byteRangeAccessSupported': reply['byteRangeAccessSupported'],
        'entireLengthAvailableOnDemand': reply['entireLengthAvailableOnDemand'],
      },
      generation: generation,
    );
  }

  /// Answers one native chunk request.
  Future<SupplyReading> serve(int offset, int length) async {
    _dataRequests++;
    diagnostics?.noteResourceLoader('dataRequest offset=$offset len=$length',
        generation: generation);
    diagnostics?.noteResourceLoaderEvent(
      'dataRequestCreated',
      fields: <String, Object?>{
        'requestedOffset': offset,
        'requestedLength': length,
        'currentOffset': offset,
        'availableBytes': watch.headBytes,
        'totalBytes': watch.expectedBytes,
      },
      generation: generation,
    );
    if (_closed) {
      return const SupplyReading(
        from: -1,
        to: -1,
        total: 0,
        completed: false,
        downloading: false,
        errorCode: 'SESSION_CLOSED',
        errorMessage: '播放已切换（session 已关闭）',
      );
    }
    final active = activeGeneration?.call();
    if (active != null && active != generation) {
      return const SupplyReading(
        from: -1,
        to: -1,
        total: 0,
        completed: false,
        downloading: false,
        errorCode: 'STALE_GENERATION',
        errorMessage: '该请求属于已结束的播放',
      );
    }
    final reading = await supply.read(offset);
    if (reading.hasData) {
      _responds++;
      final served = math.min(length, reading.length);
      _bytesServed += served;
      diagnostics?.noteResourceLoaderEvent(
        'respond',
        fields: <String, Object?>{
          'respondCount': _responds,
          'respondBytes': served,
          'currentOffset': reading.from,
          'availableTo': reading.to,
          'downloaded': watch.headBytes,
        },
        generation: generation,
      );
    } else if (reading.errorCode != null) {
      diagnostics?.noteResourceLoader(
        'stall ${reading.errorCode} offset=$offset waited=${reading.waitingMillis}ms',
        generation: generation,
      );
    }
    return reading;
  }

  /// Ends the session. Idempotent, never throws — closing is the one thing
  /// that must always succeed when the user swipes away.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    diagnostics?.noteResourceLoader(
      'sessionClosed requests=$_dataRequests responds=$_responds bytes=$_bytesServed',
      generation: generation,
    );
    try {
      await transport.closeSession(sessionId);
    } on Object {
      // The player may already be gone; the session map is the authority.
    }
    onClosed?.call();
  }

  Map<String, Object?> describe() => <String, Object?>{
        'sessionId': sessionId,
        'fileId': fileId,
        'requests': _dataRequests,
        'responds': _responds,
        'bytes': _bytesServed,
      };
}

/// Routes native `supply` calls to the live session.
///
/// Exactly one session is registered at a time — the playing one. A native
/// callback for any other id is answered with `SESSION_CLOSED`, which is how a
/// late `AVAssetResourceLoadingRequest` from a previous video is refused
/// instead of being fed from the new video's file.
class ResourceLoaderHost {
  ResourceLoaderHost({this.diagnostics});

  static ResourceLoaderHost instance = ResourceLoaderHost(
    diagnostics: StreamingDiagnostics.instance,
  );

  final StreamingDiagnostics? diagnostics;
  final Map<String, ResourceLoaderSession> _sessions =
      <String, ResourceLoaderSession>{};

  int Function()? activeGeneration;

  ResourceLoaderSession? get active =>
      _sessions.isEmpty ? null : _sessions.values.last;

  void register(ResourceLoaderSession session) {
    // One live session: registering a new play drops the previous one instead
    // of letting two sessions answer for two different videos.
    _sessions.clear();
    _sessions[session.sessionId] = session;
    session.onClosed = () => _sessions.remove(session.sessionId);
    diagnostics?.noteResourceLoader('sessionOpen ${session.sessionId}',
        generation: session.generation);
  }

  void unregister(ResourceLoaderSession session) {
    _sessions.remove(session.sessionId);
  }

  /// Entry point for the platform channel. Returns a map, never throws: an
  /// error must reach the native reader as data it can act on.
  Future<Map<String, Object?>> handleSupply(Map<Object?, Object?> arguments) async {
    final id = arguments['sessionId'] as String?;
    final offset = _asInt(arguments['offset']);
    final length = _asInt(arguments['length']);
    final session = id == null ? null : _sessions[id];
    if (session == null) {
      return const SupplyReading(
        from: -1,
        to: -1,
        total: 0,
        completed: false,
        downloading: false,
        errorCode: 'SESSION_CLOSED',
        errorMessage: '没有对应的播放会话',
      ).toMap();
    }
    final reading = await session.serve(offset, length);
    return reading.toMap();
  }

  /// Installs the native → Dart byte channel.
  ///
  /// Called once at startup on the platforms that can have the transport. In
  /// tests the same method is given a `MethodChannel` wired to a fake binary
  /// messenger, so the exact channel contract is exercised without a device.
  void install({MethodChannel? channel}) {
    final target = channel ?? const MethodChannel(kStreamingSupplyChannel);
    target.setMethodCallHandler(handleMethodCall);
  }

  /// Handles the whole native channel (used by the platform binding).
  Future<Object?> handleMethodCall(MethodCall call) async {
    if (call.method == 'supply') {
      final arguments = call.arguments;
      final map = arguments is Map
          ? arguments.cast<Object?, Object?>()
          : const <Object?, Object?>{};
      return handleSupply(map);
    }
    throw MissingPluginException('${call.method} is not handled by the host');
  }

  static int _asInt(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : 0);

  void clear() {
    _sessions.clear();
  }
}

/// The Dart half of the native player, injected so tests never need a device.
abstract class NativeStreamingTransport {
  /// False on platforms without the bridge (everything except iOS).
  bool get supported;

  Future<Map<String, Object?>?> openSession({
    required String sessionId,
    required int fileId,
    required int chatId,
    required int messageId,
    required int generation,
    required int totalBytes,
    required bool completed,
    required String mimeType,
  });

  Future<void> closeSession(String sessionId);

  Future<void> createPlayer(String sessionId);

  Future<void> play(String sessionId);

  Future<void> pause(String sessionId);

  Future<void> seek(String sessionId, Duration position);

  Future<void> setVolume(String sessionId, double volume);

  Future<void> disposePlayer(String sessionId);

  /// Player status events: `ready`, `failed`, `tick`, `buffering`, `firstFrame`.
  Stream<Map<String, Object?>> events();
}
