/// Local streaming proxy: serves a TDLib file that is still downloading over
/// HTTP Range, so AVPlayer can start on the bytes that already exist.
///
/// Why an HTTP proxy and not a file:// path: a growing file handed to AVPlayer
/// directly is read through a size snapshot — the player hits EOF the moment
/// playback crosses the bytes that existed when it opened the file. A proxy
/// controls the response boundary itself: it answers Range requests from the
/// bytes TDLib has already written, and blocks on the bytes that have not
/// arrived yet while the download keeps running behind it.
///
/// Threat model for the listener: it binds 127.0.0.1 only, the URL carries a
/// per-play random token, and unknown paths are closed immediately. Nothing is
/// exposed to the network and the Telegram cloud URL is never revealed to the
/// player.
///
/// Data source: the proxy never talks to TDLib itself. It reads the local file
/// and watches a progress feed ([FileProgressWatch]) that the resolver owns —
/// the same `updateFile` stream the wait loop already consumes. Keeping the
/// proxy TDLib-free is what makes it testable with a plain temp file.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

/// How the proxy learns that more bytes arrived.
///
/// Implemented by the resolver over its existing `updateFile` subscription;
/// abstracted here so tests drive byte arrival directly.
abstract class FileProgressWatch {
  /// Current absolute byte offset that is safe to read from the file.
  int get availableBytes;

  /// Fires whenever [availableBytes] grows. Never fires for a shrink.
  Stream<int> get progress;

  /// Total size once known, 0 while unknown.
  int get expectedBytes;

  /// True once TDLib reports the whole file is on disk.
  bool get isComplete;
}

/// One served play. Owns the listener for a single file id.
class StreamProxyServer {
  StreamProxyServer({
    required this.watch,
    required this.localPath,
    this.startupBufferBytes = defaultStartupBufferBytes,
    this.maxWait = const Duration(seconds: 90),
    this.stallTimeout = const Duration(seconds: 20),
    HttpServer? injectedServer,
    Random? random,
  })  : _server = injectedServer,
        _random = random ?? Random.secure();


  /// Bytes that must be readable before the first response byte leaves.
  ///
  /// Two megabytes covers a typical moov plus a couple of seconds of video at
  /// any sane bitrate. A value larger than the file means "wait for the whole
  /// file" — the resolver clamps it, so small videos never over-buffer.
  static const int defaultStartupBufferBytes = 2 * 1024 * 1024;

  final FileProgressWatch watch;
  final String localPath;

  /// Minimum readable bytes before the first response byte is written.
  final int startupBufferBytes;

  /// Ceiling for one blocked wait. Bounded on purpose: "waiting forever for a
  /// byte that will never come" must end in an error the caller can fall back
  /// on, not a spinner.
  final Duration maxWait;

  /// No byte growth for this long ends the wait: same semantics as the
  /// resolver's stall watchdog, and it is the only wait that maps to a network
  /// verdict.
  final Duration stallTimeout;

  final HttpServer? _server;
  final Random _random;

  HttpServer? _bound;
  String? _token;
  bool _started = false;
  int _requests = 0;
  int _rangeRequests = 0;
  int _waits = 0;
  int _fallbacks = 0;

  /// Bind result: the URL the player should open, or null when the listener
  /// could not be started (caller falls back to a full download).
  Uri? _url;
  Uri? get url => _url;

  bool get isRunning => _started;
  int get requestCount => _requests;
  int get rangeRequestCount => _rangeRequests;
  int get waitCount => _waits;
  int get fallbackCount => _fallbacks;

  final List<void Function()> _onClose = <void Function()>[];

  /// Registers a callback for when the proxy stops serving (used to release
  /// the active-file mark).
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
      _fallbacks++;
      await _reject(request, HttpStatus.forbidden);
      return;
    }
    try {
      await _serveRange(request);
    } on Object {
      // The client socket is dead (user skipped the video mid-transfer) or the
      // file vanished. Nothing useful can be written; just end the response.
      try {
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

  Future<void> _serveRange(HttpRequest request) async {
    final total = _totalSize();
    // A HEAD (AVPlayer probes format support first) answers without a body.
    if (request.method == 'HEAD') {
      request.response.statusCode = HttpStatus.ok;
      if (total > 0) {
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentLengthHeader, total);
      }
      await request.response.close();
      return;
    }

    var from = 0;
    int? to;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      _rangeRequests++;
      final parsed = _parseRange(rangeHeader, total);
      if (parsed == null) {
        // Malformed range: AVPlayer never sends one, but answering 200 with the
        // whole stream is the spec-correct degrade and keeps the player alive.
        from = 0;
        to = null;
      } else {
        from = parsed.$1;
        to = parsed.$2;
      }
    }

    // Wait until the requested range is servable. The first request always
    // starts at 0, so this is where the startup buffer gate lives.
    await _waitUntilReadable(from, to);

    final available = watch.availableBytes;
    if (available <= from) {
      // The wait returned but the range start is still beyond the data. This
      // happens when the stall watchdog fired: report the gap instead of an
      // empty 206, which AVPlayer would read as a truncated file.
      throw StreamProxyException(
          '本地还没有播放器请求的数据（需要 $from，已有 $available）');
    }

    final end = (to != null && to < available - 1) ? to : available - 1;
    final length = end - from + 1;

    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.contentRangeHeader, 'bytes $from-$end/$total');
    response.contentLength = length;

    // Stream exactly the requested window from the file. `openRead` skips the
    // OS copy: bytes flow disk → socket without buffering the range in memory.
    final file = File(localPath);
    if (!await file.exists()) {
      throw StreamProxyException('本地文件在播放中途消失');
    }
    await response.addStream(file.openRead(from, end + 1));
    await response.close();
  }

  int _totalSize() {
    final complete = watch.isComplete;
    if (complete) {
      final actual = File(localPath).lengthSync();
      return actual;
    }
    final expected = watch.expectedBytes;
    return expected > 0 ? expected : 0;
  }

  /// Blocks until [from] (and the tail of a closed range, when cheap) is
  /// readable, or throws when the wait dies.
  ///
  /// The gate: startup requests wait for the startup buffer, mid-play requests
  /// wait only for their own range start. Progress growth keeps the wait alive
  /// — that is the whole "still downloading is not a failure" rule.
  Future<void> _waitUntilReadable(int from, int? to) async {
    // Small videos must not wait for an artificial buffer: the gate is
    // min(startupBuffer, whole file).
    final expected = watch.expectedBytes;
    var target = from;
    if (from == 0 && expected > 0) {
      target = _min(startupBufferBytes, expected);
    } else if (from == 0) {
      target = startupBufferBytes;
    }
    // A closed range whose end is inside the startup window is gated by the
    // range end, not the buffer: the player asked for exactly that metadata.
    if (to != null && to >= from && to - from < startupBufferBytes) {
      target = to;
    }

    var waited = false;
    while (watch.availableBytes <= target && !watch.isComplete) {
      waited = true;
      _waits++;
      await _waitForGrowth();
    }
    // A complete file can serve any range regardless of the gate.
    if (waited && !watch.isComplete && watch.availableBytes <= target) {
      throw StreamProxyException('等待播放数据超时');
    }
  }

  /// One wait: until new bytes arrive, the transfer stalls, or the ceiling is
  /// hit. Growth resets the stall timer; silence for [stallTimeout] is the only
  /// network verdict in this file.
  Future<void> _waitForGrowth() async {
    final start = watch.availableBytes;
    final growth = watch.progress;
    final stall = Completer<void>();
    final ceiling = Completer<void>();
    final stallTimer = Timer(stallTimeout, () {
      if (watch.availableBytes > start) return;
      stall.complete();
    });
    final ceilingTimer = Timer(maxWait, ceiling.complete);
    late final StreamSubscription<int> sub;
    sub = growth.listen((_) {
      if (watch.availableBytes > start) {
        if (!stall.isCompleted) stall.complete();
      }
    });
    try {
      await Future.any(<Future<void>>[stall.future, ceiling.future]);
    } finally {
      stallTimer.cancel();
      ceilingTimer.cancel();
      await sub.cancel();
    }
    if (ceiling.isCompleted && !stall.isCompleted) {
      throw StreamProxyException('等待播放数据超时（任务上限）');
    }
    if (stall.isCompleted && watch.availableBytes <= start) {
      throw StreamProxyException('等待播放数据超时（无新数据）');
    }
  }

  /// `bytes=a-b`, `bytes=a-`, `bytes=-suffix`. Returns (from, to) with `to`
  /// inclusive, or null when the header cannot be honoured.
  (int, int?)? _parseRange(String header, int total) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)').firstMatch(header.trim());
    if (match == null) return null;
    final a = match.group(1)!;
    final b = match.group(2)!;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      // suffix range: last N bytes. TDLib growth makes these awkward; the
      // player uses them for moov-at-end probes. Serving from max(0, total-N)
      // keeps the probe alive and the fallback path covers the rest.
      final suffix = int.parse(b);
      if (total <= 0) return null;
      final from = max(0, total - suffix);
      return (from, null);
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
}

class StreamProxyException implements Exception {
  StreamProxyException(this.message);

  final String message;

  @override
  String toString() => 'StreamProxyException: $message';
}

int _min(int a, int b) => a < b ? a : b;
