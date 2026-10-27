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
/// The device failure this file was rebuilt around: AVPlayer does not just
/// request byte 0. Its first requests are frequently at the *tail* of the
/// file (moov probing) or at arbitrary offsets, while TDLib downloads from 0
/// upward. Waiting for the sequential download to reach a tail range is what
/// produced "缓冲 → 读取失败" on the phone. The proxy therefore *steers* the
/// TDLib download window ([FileProgressWatch.requestWindow]) to the range the
/// player actually asked for, serves it, and then restores the sequential
/// download so the full-cache goal keeps advancing.
///
/// Threat model for the listener: it binds 127.0.0.1 only, the URL carries a
/// per-play random token, and unknown paths are closed immediately. Nothing is
/// exposed to the network and the Telegram cloud URL is never revealed to the
/// player.
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

/// One served play. Owns the listener for a single file id.
class StreamProxyServer {
  StreamProxyServer({
    required this.watch,
    this.startupBufferBytes = defaultStartupBufferBytes,
    this.maxWait = const Duration(seconds: 90),
    this.stallTimeout = const Duration(seconds: 20),
    this.onEvent,
    this.onRangeRequest,
    this.onResponse,
    this.onWindowMove,
    this.onStall,
    HttpServer? injectedServer,
    Random? random,
  })  : _server = injectedServer,
        _random = random ?? Random.secure();

  /// Bytes that must sit at the head of the file before the first response
  /// byte leaves. Two megabytes covers a typical moov plus a couple of
  /// seconds of video at any sane bitrate. A value larger than the file means
  /// "wait for the whole file" — the proxy clamps, so small videos never
  /// over-buffer.
  static const int defaultStartupBufferBytes = 2 * 1024 * 1024;

  /// Ceiling for one blocked wait. Bounded on purpose: "waiting forever for a
  /// byte that will never come" must end in an error the caller can fall back
  /// on, not a spinner.
  final Duration maxWait;

  /// No TDLib event at all for this long ends a wait: the only network
  /// verdict in this file. Steady growth keeps resetting it — a slow download
  /// is not a failure.
  final Duration stallTimeout;

  /// Diagnostics feed, already free of paths and secrets: method, range,
  /// status, byte counts. Wired into [PlaybackTrace] by the resolver.
  final void Function(String event)? onEvent;

  /// A Range request arrived. Carries what the player actually asked for —
  /// the input to the streaming verdict.
  final void Function({required int from, required int? to})? onRangeRequest;

  /// A response was written, with the status code the client really got.
  final void Function({
    required int status,
    required int from,
    required int end,
    required int total,
    required int length,
  })? onResponse;

  /// The TDLib download window was moved to serve [start]..[end].
  final void Function({required int start, required int end})? onWindowMove;

  /// A wait ended because TDLib went silent for a whole [stallTimeout].
  final void Function(String reason)? onStall;

  final FileProgressWatch watch;

  /// Minimum readable head bytes before the first response byte is written.
  final int startupBufferBytes;

  final HttpServer? _server;
  final Random _random;

  HttpServer? _bound;
  String? _token;
  bool _started = false;
  int _requests = 0;
  int _served = 0;
  int _windowSwitches = 0;
  int _stalls = 0;

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
      onResponse?.call(
        status: HttpStatus.forbidden,
        from: 0,
        end: 0,
        total: 0,
        length: 0,
      );
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
      // The client socket is dead (user skipped the video mid-transfer) or
      // the wait died. Nothing useful can be written; end the response.
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      } on Object {
        // ignored: the socket is already gone
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

    if (request.method == 'HEAD') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4');
      if (total > 0) {
        request.response.headers.contentLength = total;
      }
      onEvent?.call('head total=$total');
      onResponse?.call(
        status: HttpStatus.ok,
        from: 0,
        end: total > 0 ? total - 1 : 0,
        total: total,
        length: 0,
      );
      await request.response.close();
      return;
    }

    var from = 0;
    int? to; // inclusive; null = open-ended
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final parsed = _parseRange(rangeHeader, total);
      if (parsed == null) {
        // Malformed range: answer 200 with the whole stream — the spec-correct
        // degrade — rather than a 416 the player may not recover from.
        onEvent?.call('range malformed, serving 200');
      } else {
        from = parsed.$1;
        to = parsed.$2;
      }
    }
    final hasRange = rangeHeader != null;
    onEvent?.call(
        'req ${request.method} range=${hasRange ? '$from-${to ?? 'end'}' : '-'} '
        'head=${watch.headBytes}');
    if (hasRange) onRangeRequest?.call(from: from, to: to);

    // Prepare: startup gate for the first bytes, window steering for a range
    // the sequential download has not reached yet.
    await _prepare(from, to, total);

    // What can be served *right now*:
    // * complete file → the exact requested window;
    // * range inside the current head/window → that window;
    // * open-ended sequential request (bytes=0- / bytes=n-) → everything from
    //   `from` to the current readable end. AVPlayer accepts a partial 206 and
    //   asks for the next range when it needs it — that is the progressive
    //   contract this proxy plays into, and waiting for the FULL open-ended
    //   range here is exactly the "缓冲到 100% 才播" failure.
    final complete = watch.isComplete;
    final readableEnd = complete
        ? (total > 0 ? total - 1 : watch.expectedBytes - 1)
        : watch.readableEndFrom(from);
    if (readableEnd < from) {
      // The window move did not deliver: refuse with the real numbers instead
      // of an empty 206 the player would read as a truncated file.
      throw StreamProxyException(
          '请求的数据未就绪（需要 $from，可读 ${readableEnd + 1}）');
    }
    final end = (to != null) ? min(to, readableEnd) : readableEnd;
    final length = end - from + 1;

    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.contentRangeHeader, 'bytes $from-$end/$total');
    response.contentLength = length;

    final file = File(watch.localPath);
    if (!await file.exists()) {
      throw StreamProxyException('本地文件在播放中途消失');
    }
    _served++;
    onEvent?.call('serve 206 $from-$end/$total ${length}B');
    onResponse?.call(
      status: HttpStatus.partialContent,
      from: from,
      end: end,
      total: total,
      length: length,
    );
    await response.addStream(file.openRead(from, end + 1));
    await response.close();

    // A targeted window is a detour, not the destination: put the sequential
    // download back so the play keeps building toward a complete cache.
    if (from >= watch.headBytes && !complete) {
      unawaited(watch.resumeSequential());
    }
  }

  /// Makes the requested range servable, or throws with the real numbers.
  ///
  /// Three cases, deliberately distinct:
  /// 1. first paint (`from == 0`, nothing served yet) → startup gate;
  /// 2. inside the head prefix → nothing to do, serve progressively;
  /// 3. beyond the head (tail probe, arbitrary seek) → steer the TDLib window
  ///    to exactly that range and wait for it. **This is the fix for the
  ///    device failure** — the old proxy just waited for the sequential
  ///    download to crawl to a tail range, which it never does in time.
  Future<void> _prepare(int from, int? to, int total) async {
    final gate = total > 0 ? min(total, startupBufferBytes) : startupBufferBytes;
    if (from == 0 && _served == 0 && watch.headBytes < gate) {
      onEvent?.call('gate wait ${gate}B (head=${watch.headBytes})');
      await _waitFor(() => watch.headBytes >= gate || watch.isComplete,
          label: 'startup');
      onEvent?.call('gate ok ${watch.headBytes}B');
    }

    if (watch.isComplete) return;
    // Anything the head prefix already covers is servable right away.
    if (from < watch.headBytes) return;

    final needEnd = to ?? (total > 0 ? total - 1 : from);
    if (watch.covers(from, min(needEnd, _readableCeiling(total)))) return;

    // Steer the download to the range the player actually wants.
    final end = min(needEnd, max(0, total - 1));
    _windowSwitches++;
    onEvent?.call('window→$from-$end (head=${watch.headBytes})');
    onWindowMove?.call(start: from, end: end);
    await watch.requestWindow(from, end);
    await _waitFor(
      () => watch.covers(from, min(end, _readableCeiling(total))) ||
          watch.isComplete,
      label: 'window $from-$end',
    );
  }

  int _readableCeiling(int total) => total > 0 ? total - 1 : 1 << 40;

  /// Waits until [ready] is true. **Every TDLib event resets the stall
  /// timer** — a slow but moving download never trips it; only real silence
  /// (no updateFile at all for [stallTimeout]) does.
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
      // suffix range: last N bytes — the moov-at-the-end probe. The window
      // steering above is what serves it in time.
      final suffix = int.parse(b);
      if (total <= 0) return null;
      return (max(0, total - suffix), null);
    }
    final from = int.parse(a);
    final to = b.isEmpty ? null : int.parse(b);
    if (total > 0 && from >= total) return null;
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
