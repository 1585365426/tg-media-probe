/// Local streaming proxy: serves a TDLib file that is still downloading over
/// HTTP Range, so AVPlayer can start on the bytes that already exist.
///
/// Why an HTTP proxy and not a file:// path: a growing file handed to AVPlayer
/// directly is read through a size snapshot — the player hits EOF the moment
/// playback crosses the bytes that existed when it opened the file. A proxy
/// controls the response boundary itself: it answers Range requests from the
/// bytes TDLib has already written, and fetches (bounded) the bytes that have
/// not arrived yet while the download keeps running behind it.
///
/// Two rules came out of device evidence and are not negotiable:
///
/// 1. **The declared range is the served range.** If the player asks for
///    `bytes=0-3707092490`, the 206 must carry
///    `Content-Range: bytes 0-3707092490/3707092491` and a body that keeps
///    flowing until that range is complete. The earlier build closed the
///    response at the current download head while advertising the same
///    Content-Range — AVPlayer read that as a broken resource, dropped the
///    bytes it had, asked again with the identical range, and never reached
///    readyToPlay. Truncating a range is never an optimisation.
/// 2. **Bytes are written as they land.** The body loop writes every readable
///    chunk immediately and waits between chunks; it never waits for the whole
///    range before the first byte leaves. That is what makes "play while
///    downloading" real instead of rhetorical.
///
/// The listener binds 127.0.0.1 only, the URL carries a per-play random token,
/// and unknown paths are refused. Nothing is exposed to the network and the
/// Telegram cloud URL is never revealed to the player.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

/// How the proxy sees and steers the TDLib download.
///
/// TDLib keeps ONE active download per file; `downloaded_size` is the prefix
/// already on disk counted from `download_offset` (td_api.tl, localFile). The
/// watcher exposes that window model and lets the proxy move the window.
abstract class FileProgressWatch {
  /// Absolute prefix from byte 0 readable right now. 0 while the window sits
  /// elsewhere; grows again once the sequential download is restored (TDLib
  /// resumes over the bytes already in the local file).
  int get headBytes;

  /// The last byte (inclusive) readable in one contiguous run starting at
  /// [from], or -1 when [from] itself is not on disk. Honours the current
  /// TDLib window, not just the head prefix.
  int readableEndFrom(int from);

  /// True when every byte of [from]..[end] (inclusive) is on disk right now,
  /// or when the whole file is complete.
  bool covers(int from, int end);

  /// Total size once known, 0 while unknown.
  int get expectedBytes;

  /// True once TDLib reports the whole file is on disk.
  bool get isComplete;

  /// The local file backing the play. The proxy reads it directly.
  String get localPath;

  /// Moves the TDLib download window to cover [from]..[end]. Replaces the
  /// running sequential download — that is the point: serve what the player
  /// asked for *now* instead of waiting for the crawl.
  Future<void> requestWindow(int from, int end);

  /// Restores the sequential head download (offset 0, no limit) after a
  /// targeted window was served.
  Future<void> resumeSequential();

  /// Fires on every TDLib state change for this file — growth, window moves,
  /// completion. Never fires for nothing, so "no events" is a real stall.
  Stream<void> get progress;
}

/// One HTTP exchange, recorded so a device report can show what the player
/// actually asked for and what it actually got.
///
/// Nothing here is inferred: every field is copied from the request headers or
/// from the response the proxy really wrote.
class ProxyExchange {
  ProxyExchange({
    required this.index,
    required this.method,
    required this.rangeHeader,
    required this.requestedFrom,
    required this.requestedTo,
    required this.status,
    required this.servedFrom,
    required this.servedTo,
    required this.total,
    required this.declaredLength,
    required this.writtenBytes,
    required this.contentRange,
    required this.contentType,
    required this.contentEncoding,
    required this.millis,
    this.note,
  });

  /// 1-based request number on this proxy.
  final int index;
  final String method;

  /// The raw `Range` header, `-` when the client sent none.
  final String rangeHeader;

  /// Parsed from the header: first byte asked for.
  final int? requestedFrom;

  /// Parsed from the header: last byte asked for (inclusive), null when the
  /// request was open-ended.
  final int? requestedTo;

  /// HTTP status actually written.
  final int status;

  /// Bytes the proxy really served.
  final int servedFrom;
  final int servedTo;

  /// Declared resource size.
  final int total;

  /// `Content-Length` written on the response.
  final int declaredLength;

  /// Bytes actually pushed into the socket before the exchange ended.
  final int writtenBytes;

  final String contentRange;
  final String contentType;
  final String contentEncoding;

  /// Milliseconds since the proxy started.
  final int millis;

  /// `stall`, `client closed`, … — only set when something ended early.
  final String? note;

  /// The client asked for a wider byte span than the proxy served.
  bool get truncated =>
      requestedTo != null &&
      status == HttpStatus.partialContent &&
      writtenBytes < (requestedTo! - (requestedFrom ?? 0) + 1);

  /// The player asked for bytes away from 0 — a moov probe or a seek.
  bool get isForwardRange => (requestedFrom ?? 0) > 0;

  /// `req=0-3707092490 → 206 0-3707092490/3707092491 len=3707092491 w=505MB`
  String describe() {
    final asked = rangeHeader == '-' ? 'no range' : 'req=$rangeHeader';
    final noteText = note == null ? '' : ' note=$note';
    return '#$index $asked → $status '
        'served=$servedFrom-$servedTo/$total '
        'len=$declaredLength wrote=$writtenBytes '
        'type=$contentType enc=$contentEncoding$noteText';
  }
}

/// One served play. Owns the listener for a single file id.
class StreamProxyServer {
  StreamProxyServer({
    required this.watch,
    this.startupBufferBytes = defaultStartupBufferBytes,
    this.maxWait = const Duration(seconds: 90),
    this.stallTimeout = const Duration(seconds: 20),
    this.chunkBytes = defaultChunkBytes,
    this.windowBytes = defaultWindowBytes,
    this.contentType = 'video/mp4',
    this.onEvent,
    this.onRangeRequest,
    this.onResponse,
    this.onExchange,
    this.onWindowMove,
    this.onStall,
    HttpServer? injectedServer,
    Random? random,
  })  : _server = injectedServer,
        _random = random ?? Random.secure();

  /// Bytes that must sit at the head of the file before the first response
  /// byte leaves. Clamped to the requested range, so a 2-byte probe is never
  /// held hostage by a 2 MB gate.
  static const int defaultStartupBufferBytes = 2 * 1024 * 1024;

  /// One socket write. Small enough that the player sees progress while the
  /// download crawls, large enough that a fast disk is not syscall-bound.
  static const int defaultChunkBytes = 4 * 1024 * 1024;

  /// How far ahead of the player's cursor the TDLib window is pointed when the
  /// request is not covered by the sequential head download.
  static const int defaultWindowBytes = 16 * 1024 * 1024;

  /// Distance from the head that makes a cursor a *seek* rather than the
  /// natural edge of the sequential download. Inside this gap the proxy waits
  /// for the download to grow — steering there would throw the head away and
  /// turn linear playback into a chase.
  static const int seekGapBytes = 1024 * 1024;

  /// Ceiling for one blocked wait *before* the response starts. Once the body
  /// is flowing there is no absolute ceiling — a 3.7 GB play legitimately
  /// takes minutes, and cutting it would be a self-inflicted stall.
  final Duration maxWait;

  /// No TDLib event at all for this long ends a wait: the only network
  /// verdict in this file. Steady growth keeps resetting it — a slow download
  /// is not a failure.
  final Duration stallTimeout;

  /// Bytes per socket write in the body loop.
  final int chunkBytes;

  /// Size of the TDLib window steered ahead of a seek / tail probe.
  final int windowBytes;

  /// `Content-Type` of the served bytes. Taken from the message's own
  /// mime type when the record has one; mp4 is the fallback the player
  /// understands.
  final String contentType;

  /// Diagnostics feed, already free of paths and secrets: method, range,
  /// status, byte counts. Wired into [PlaybackTrace] by the resolver.
  final void Function(String event)? onEvent;

  /// A Range request arrived. Carries what the player actually asked for —
  /// the input to the streaming verdict.
  final void Function({required int from, required int? to})? onRangeRequest;

  /// A 206 was committed, with the numbers the client was promised.
  final void Function({
    required int status,
    required int from,
    required int end,
    required int total,
    required int length,
  })? onResponse;

  /// The full exchange: request header, status, headers written, bytes
  /// actually pushed. Recorded for the device report.
  final void Function(ProxyExchange exchange)? onExchange;

  /// The TDLib download window was moved to serve [start]..[end].
  final void Function({required int start, required int end})? onWindowMove;

  /// A wait ended because TDLib went silent for a whole [stallTimeout].
  final void Function(String reason)? onStall;

  final FileProgressWatch watch;

  /// Minimum readable head bytes before the first response byte is written.
  final int startupBufferBytes;

  final HttpServer? _server;
  final Random _random;

  final Stopwatch _clock = Stopwatch()..start();

  HttpServer? _bound;
  String? _token;
  bool _started = false;
  int _requests = 0;
  int _served = 0;
  int _windowSwitches = 0;
  int _stalls = 0;

  /// Serialises window moves: two sockets must not fight over TDLib's single
  /// active download for the same file.
  Future<void> _windowChain = Future<void>.value();

  /// Bind result: the URL the player should open.
  Uri? _url;
  Uri? get url => _url;

  bool get isRunning => _started;
  int get requestCount => _requests;
  int get servedCount => _served;
  int get windowSwitches => _windowSwitches;
  int get stallCount => _stalls;

  final List<void Function()> _onClose = <void Function()>[];

  /// Registers a callback for when the proxy stops serving (used to release
  /// the active-file mark and dispose the watcher).
  void onClose(void Function() callback) => _onClose.add(callback);

  /// Binds the listener. Returns the playback URL.
  ///
  /// Throws [StreamProxyException] when the port cannot be bound — the caller
  /// treats that as "streaming unavailable" and falls back.
  Future<Uri> start() async {
    if (_started) return _url!;
    try {
      final server = _server ??
          await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0, // random port: two plays never collide
            v6Only: false,
          );
      _bound = server;
      _token = _randomToken();
      _url = Uri.parse('http://127.0.0.1:${server.port}/v/$_token');
      server.listen(
        _handleRequest,
        onError: (Object _) {
          // A crashed socket must not kill the proxy; the next request opens a
          // new connection against the same server.
        },
        cancelOnError: false,
      );
      _started = true;
      onEvent?.call('proxy started port=${server.port}');
      return _url!;
    } on Object catch (e) {
      throw StreamProxyException('本地播放代理启动失败: $e');
    }
  }

  String _randomToken() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List<String>.generate(
      32,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _requests++;
    // Unknown path = wrong port scan or a stale player URL. Close, don't 404:
    // a 404 body is still a response to something that should never have asked.
    if (request.uri.path != '/v/$_token') {
      onEvent?.call('req forbidden path');
      await _reject(request, HttpStatus.forbidden);
      return;
    }
    try {
      await _serveRange(request);
    } on Object catch (e) {
      _stalls++;
      final reason = 'req fail: ${_brief(e)}';
      onEvent?.call(reason);
      onStall?.call(reason);
      // Either nothing has been written yet (a 503 still helps the player
      // retry) or the body is already in flight (close and let it retry).
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      } on Object {
        // Headers already committed or the socket is gone: closing is all
        // that is left, and the player retries with its own range.
      }
    }
  }

  Future<void> _reject(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  int _totalSize() {
    if (watch.isComplete) {
      try {
        return File(watch.localPath).lengthSync();
      } on Object {
        return watch.expectedBytes;
      }
    }
    return watch.expectedBytes > 0 ? watch.expectedBytes : 0;
  }

  Future<void> _serveRange(HttpRequest request) async {
    final total = _totalSize();
    final rangeHeader =
        request.headers.value(HttpHeaders.rangeHeader) ?? '-';
    final index = _requests;

    if (request.method == 'HEAD') {
      final response = request.response;
      response.statusCode = HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, contentType);
      if (total > 0) {
        response.headers.contentLength = total;
      }
      onEvent?.call('head total=$total');
      onExchange?.call(ProxyExchange(
        index: index,
        method: 'HEAD',
        rangeHeader: rangeHeader,
        requestedFrom: null,
        requestedTo: null,
        status: HttpStatus.ok,
        servedFrom: 0,
        servedTo: total > 0 ? total - 1 : 0,
        total: total,
        declaredLength: total,
        writtenBytes: 0,
        contentRange: '-',
        contentType: contentType,
        contentEncoding: 'identity',
        millis: _clock.elapsedMilliseconds,
      ));
      await response.close();
      return;
    }

    if (total <= 0) {
      // Without a total there is no honest Content-Range, and a wrong one is
      // exactly what makes the player drop the resource.
      throw StreamProxyException('文件大小未知，无法给出 Content-Range');
    }

    var from = 0;
    int? to; // inclusive; null = open-ended
    var malformed = false;
    if (rangeHeader != '-') {
      final parsed = _parseRange(rangeHeader, total);
      if (parsed == null) {
        malformed = true;
      } else {
        from = parsed.$1;
        to = parsed.$2;
      }
    }
    // Anything outside the resource is a 416 with the real size, not a 200
    // that silently changes what the player asked for.
    if (!malformed && (from < 0 || from >= total)) {
      final response = request.response;
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      onEvent?.call('416 $rangeHeader total=$total');
      onExchange?.call(ProxyExchange(
        index: index,
        method: request.method,
        rangeHeader: rangeHeader,
        requestedFrom: from,
        requestedTo: to,
        status: HttpStatus.requestedRangeNotSatisfiable,
        servedFrom: 0,
        servedTo: 0,
        total: total,
        declaredLength: 0,
        writtenBytes: 0,
        contentRange: 'bytes */$total',
        contentType: contentType,
        contentEncoding: 'identity',
        millis: _clock.elapsedMilliseconds,
        note: 'out of range',
      ));
      await response.close();
      return;
    }
    if (malformed) {
      // A range we cannot parse is served as the whole resource from 0: the
      // spec's degrade, and the only variant a player can still use.
      onEvent?.call('range malformed ($rangeHeader), serving from 0');
      from = 0;
      to = null;
    }

    final hasRange = rangeHeader != '-';
    final requestedTo = to ?? (total - 1);
    onEvent?.call('req ${request.method} range=$rangeHeader '
        'head=${watch.headBytes} total=$total');
    if (hasRange) onRangeRequest?.call(from: from, to: to);

    // Make the first byte servable: startup gate for a fresh play, window
    // steering for a range the sequential download has not reached yet.
    await _prepare(from, requestedTo, total);

    // Checked before the response is committed: a vanished file must produce
    // a clean 503 the caller can fall back on, not a 206 with an empty body.
    final file = File(watch.localPath);
    if (!await file.exists()) {
      throw StreamProxyException('本地文件在播放中途消失');
    }

    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    // `identity` matters: a compressed body would change what a byte offset
    // means and every Content-Range after it would be a lie.
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.contentRangeHeader, 'bytes $from-$requestedTo/$total')
      ..set(HttpHeaders.contentEncodingHeader, 'identity')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    final declared = requestedTo - from + 1;
    response.contentLength = declared;
    response.bufferOutput = false;

    _served++;
    onResponse?.call(
      status: HttpStatus.partialContent,
      from: from,
      end: requestedTo,
      total: total,
      length: declared,
    );
    onEvent?.call('serve 206 $from-$requestedTo/$total ${declared}B');

    var cursor = from;
    var written = 0;
    String? note;
    try {
      while (cursor <= requestedTo) {
        final available = watch.isComplete
            ? requestedTo
            : min(requestedTo, watch.readableEndFrom(cursor));
        if (available < cursor) {
          // Not on disk here. A cursor sitting at the edge of the sequential
          // download is the normal case — wait for it to grow. A cursor far
          // beyond it is a seek or a moov probe: waiting would never end, so
          // steer TDLib to the cursor instead.
          if (!watch.isComplete &&
              cursor > watch.headBytes + seekGapBytes) {
            _steer(cursor, requestedTo, total);
          }
          await _waitForGrowth(cursor);
          continue;
        }
        final chunkEnd = min(available, cursor + chunkBytes - 1);
        await response.addStream(file.openRead(cursor, chunkEnd + 1));
        written += chunkEnd - cursor + 1;
        cursor = chunkEnd + 1;
      }
    } on Object catch (e) {
      // Body already committed: a stall or a dead socket ends the exchange.
      // The player retries with its own range — that is not our decision.
      note = _brief(e);
      onEvent?.call('body ended at $cursor/$requestedTo: $note');
    }

    final servedTo = written == 0 ? from - 1 : from + written - 1;
    onExchange?.call(ProxyExchange(
      index: index,
      method: request.method,
      rangeHeader: rangeHeader,
      requestedFrom: hasRange ? from : null,
      requestedTo: hasRange ? to : null,
      status: HttpStatus.partialContent,
      servedFrom: from,
      servedTo: servedTo,
      total: total,
      declaredLength: declared,
      writtenBytes: written,
      contentRange: 'bytes $from-$requestedTo/$total',
      contentType: contentType,
      contentEncoding: 'identity',
      millis: _clock.elapsedMilliseconds,
      note: note,
    ));

    try {
      await response.close();
    } on Object {
      // Client vanished mid-body; nothing left to say to it.
    }

    // A targeted window is a detour, not the destination: put the sequential
    // download back so the play keeps building toward a complete cache.
    if (from >= watch.headBytes && !watch.isComplete) {
      unawaited(watch.resumeSequential());
    }
  }

  /// Makes the first byte of [from] servable, or throws with the real numbers.
  ///
  /// Three cases, deliberately distinct:
  /// 1. first paint (`from == 0`, nothing served yet) → startup gate;
  /// 2. inside the head prefix → nothing to do, serve progressively;
  /// 3. beyond the head (tail probe, arbitrary seek) → steer the TDLib window
  ///    to exactly that range and wait for its first byte.
  Future<void> _prepare(int from, int to, int total) async {
    final requestLength = to - from + 1;
    final gate = max(1, min(min(total, startupBufferBytes), requestLength));
    if (from == 0 && _served == 0 && watch.headBytes < gate) {
      onEvent?.call('gate wait ${gate}B (head=${watch.headBytes})');
      await _waitFor(() => watch.headBytes >= gate || watch.isComplete,
          label: 'startup');
      onEvent?.call('gate ok ${watch.headBytes}B');
    }

    if (watch.isComplete) return;
    if (from < watch.headBytes) return;
    if (watch.readableEndFrom(from) >= from) return;

    // Just past the head: the sequential download will reach it, and steering
    // would restart the window elsewhere for no gain.
    if (from <= watch.headBytes + seekGapBytes) {
      await _waitFor(
        () => watch.isComplete || watch.readableEndFrom(from) >= from,
        label: 'head grow to $from',
      );
      return;
    }

    await _steerAwait(from, to, total);
  }

  /// Fire-and-forget window move for the body loop: the loop re-checks
  /// readability after every TDLib event, so it does not need to await.
  void _steer(int from, int to, int total) {
    unawaited(_steerAwait(from, to, total));
  }

  Future<void> _steerAwait(int from, int to, int total) {
    final end = min(to, total - 1);
    final windowEnd = min(end, from + windowBytes - 1);
    _windowSwitches++;
    onEvent?.call('window→$from-$windowEnd (head=${watch.headBytes})');
    onWindowMove?.call(start: from, end: windowEnd);
    final next = _windowChain.then((_) => watch.requestWindow(from, windowEnd));
    _windowChain = next.catchError((Object _) {});
    return next;
  }

  /// Waits until byte [cursor] is readable, or throws after a real silence.
  ///
  /// No absolute ceiling here on purpose: the body of a legitimate 3.7 GB
  /// response takes minutes, and a wall-clock cap would cut playback mid
  /// film. Silence — no TDLib event at all — is the only failure signal.
  Future<void> _waitForGrowth(int cursor) async {
    final done = Completer<void>();
    final stall = Completer<void>();
    Timer? stallTimer;
    void arm() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        if (!stall.isCompleted) stall.complete();
      });
    }

    bool ready() => watch.isComplete || watch.readableEndFrom(cursor) >= cursor;

    arm();
    late final StreamSubscription<void> sub;
    sub = watch.progress.listen((_) {
      if (ready()) {
        if (!done.isCompleted) done.complete();
      } else {
        arm(); // 有动静：慢，但不是失败
      }
    });
    try {
      await Future.any(<Future<void>>[done.future, stall.future]);
    } finally {
      stallTimer?.cancel();
      await sub.cancel();
    }
    if (!ready()) {
      onEvent?.call('body stall at $cursor');
      onStall?.call('body stall at $cursor');
      throw StreamProxyException(
          '播放数据停止增长（$cursor，可读 ${watch.headBytes}B）');
    }
  }

  /// Waits until [ready] is true. **Every TDLib event resets the stall
  /// timer** — a slow but moving download never trips it; only real silence
  /// (no updateFile at all for [stallTimeout]) does. Bounded by [maxWait]
  /// because this runs before the response is committed: the caller can still
  /// answer 503 and fall back.
  Future<void> _waitFor(bool Function() ready, {required String label}) async {
    final stall = Completer<void>();
    final ceiling = Completer<void>();
    Timer? stallTimer;
    void arm() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        if (!ready() && !stall.isCompleted) stall.complete();
      });
    }

    arm();
    late final StreamSubscription<void> sub;
    sub = watch.progress.listen((_) {
      if (ready()) {
        if (!stall.isCompleted) stall.complete();
      } else {
        arm(); // 有动静：慢，但不是失败
      }
    });
    final ceilingTimer = Timer(maxWait, () {
      if (!ceiling.isCompleted) ceiling.complete();
    });
    try {
      await Future.any(<Future<void>>[stall.future, ceiling.future]);
    } finally {
      stallTimer?.cancel();
      ceilingTimer.cancel();
      await sub.cancel();
    }
    if (!ready()) {
      onEvent?.call('wait fail $label');
      onStall?.call('wait fail $label');
      throw StreamProxyException(
          '等待播放数据超时（$label，可读 ${watch.headBytes}B）');
    }
  }

  (int, int?)? _parseRange(String header, int total) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)').firstMatch(header.trim());
    if (match == null) return null;
    final a = match.group(1)!;
    final b = match.group(2)!;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      // suffix range: last N bytes — the moov-at-the-end probe.
      final suffix = int.parse(b);
      if (suffix <= 0) return null;
      if (total <= 0) return null;
      return (max(0, total - suffix), null);
    }
    final from = int.parse(a);
    if (b.isEmpty) return (from, null);
    final to = int.parse(b);
    if (to < from) return null;
    return (from, to);
  }

  /// Stops serving and frees the port. Idempotent; safe to call from a
  /// fallback path that never served a request.
  Future<void> stop() async {
    _started = false;
    for (final callback in _onClose) {
      try {
        callback();
      } on Object {
        // A close hook must never block the shutdown of the listener itself.
      }
    }
    _onClose.clear();
    final server = _bound;
    _bound = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } on Object {
        // The port is owned by the OS; a failed close leaks a socket at worst.
      }
    }
  }

  static String _brief(Object e) {
    final text = '$e';
    return text.length > 80 ? text.substring(0, 80) : text;
  }
}

class StreamProxyException implements Exception {
  StreamProxyException(this.message);

  final String message;

  @override
  String toString() => 'StreamProxyException: $message';
}
