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
/// Four rules came out of device evidence and are not negotiable:
///
/// 1. **The declared range is the served range.** If the player asks for
///    `bytes=0-659667829`, the 206 must carry
///    `Content-Range: bytes 0-659667829/659667830`, a matching Content-Length,
///    and a body that keeps flowing until that range is complete. Closing the
///    response at the current download head while advertising the full range
///    is what made AVPlayer answer `-1005 网络连接已中断` on device.
/// 2. **Bytes are written as they land.** The body loop writes every readable
///    chunk immediately and waits between chunks; it never waits for the whole
///    range before the first byte leaves.
/// 3. **"Not downloaded yet" is not a failure.** The body loop treats a gap as
///    a wait, never as an error, and the stall timer only measures *silence
///    from TDLib* — never "this byte is not here yet".
/// 4. **The window is a shared resource with an owner.** TDLib can only run
///    one download per file, so a tail probe (moov at the end) and the main
///    `bytes=0-` response cannot both pull data at the same time. A diversion
///    is serialised, deduplicated by range, released when its consumer is
///    gone, and always followed by a restore of the sequential download. While
///    a diversion owns the window, the other responses wait instead of
///    declaring a network stall — that self-inflicted stall (`播放数据停止增长`)
///    was the second device failure.
///
/// The listener binds 127.0.0.1 only, the URL carries a per-play random token,
/// and unknown paths are refused. Nothing is exposed to the network and the
/// Telegram cloud URL is never revealed to the player.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Which byte ranges of a file are physically on disk right now.
///
/// TDLib downloads a *window* (`download_offset` + `downloaded_size`) and
/// keeps everything it already wrote when the window moves — the bytes stay in
/// the local file. Tracking only the live window therefore reports
/// `readable = nothing` the moment a tail probe moves the window away, and the
/// main response then waits for bytes that are already sitting on disk. This
/// map is what makes the proxy's answer match the file.
///
/// Intervals are merged and inclusive; the count stays small (one entry per
/// download window, merged when contiguous), so lookups are linear over a
/// handful of elements — no index to keep in sync.
class ByteCoverage {
  final List<int> _starts = <int>[];
  final List<int> _ends = <int>[];

  /// Number of merged intervals; diagnostics only.
  int get segmentCount => _starts.length;

  /// Marks `from`..`to` (inclusive) as present.
  void add(int from, int to) {
    if (to < from) return;
    var start = from;
    var end = to;
    var i = 0;
    while (i < _starts.length && _ends[i] + 1 < start) {
      i++;
    }
    // Absorb every interval that touches or overlaps the new one.
    while (i < _starts.length && _starts[i] <= end + 1) {
      start = min(start, _starts[i]);
      end = max(end, _ends[i]);
      _starts.removeAt(i);
      _ends.removeAt(i);
    }
    _starts.insert(i, start);
    _ends.insert(i, end);
  }

  /// Last byte of the contiguous run that starts at [from], or -1.
  int endFrom(int from) {
    for (var i = 0; i < _starts.length; i++) {
      if (from >= _starts[i] && from <= _ends[i]) return _ends[i];
      if (_starts[i] > from) return -1;
    }
    return -1;
  }

  /// Length of the contiguous run starting at byte 0.
  int get prefixLength {
    if (_starts.isEmpty || _starts.first > 0) return 0;
    return _ends.first + 1;
  }

  /// True when every byte of `from`..`to` is present.
  bool covers(int from, int to) {
    if (to < from) return true;
    return endFrom(from) >= to;
  }

  void reset() {
    _starts.clear();
    _ends.clear();
  }
}

/// How the proxy sees and steers the TDLib download.
///
/// TDLib keeps ONE active download per file; `downloaded_size` is the prefix
/// already on disk counted from `download_offset` (td_api.tl, localFile). The
/// watcher exposes that window model and lets the proxy move the window.
abstract class FileProgressWatch {
  /// Absolute prefix from byte 0 readable right now. Must not shrink when the
  /// window moves: bytes already written stay on disk.
  int get headBytes;

  /// The last byte (inclusive) readable in one contiguous run starting at
  /// [from], or -1 when [from] itself is not on disk.
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

  /// `RANGE_TRUNCATED …`, `client closed`, … — only set when something ended
  /// early.
  final String? note;

  /// Bytes the request asked for, resolved against the real total.
  int get requestedLength {
    if (status != HttpStatus.partialContent) return 0;
    final from = requestedFrom ?? 0;
    final to = requestedTo ?? (total - 1);
    return to - from + 1;
  }

  /// The client asked for a wider byte span than the proxy served.
  bool get truncated =>
      status == HttpStatus.partialContent && writtenBytes < requestedLength;

  /// The player asked for bytes away from 0 — a moov probe or a seek.
  bool get isForwardRange => (requestedFrom ?? 0) > 0;

  /// `#2 req=bytes=0- → 206 want=659667830 served=0-… len=… wrote=…`
  ///
  /// `want` is the requested length resolved against the real total, `len` the
  /// Content-Length actually written, `wrote` the bytes that really left. The
  /// three being equal is the contract; `TRUNCATED` marks the case that broke
  /// the device build.
  String describe() {
    final asked = rangeHeader == '-' ? 'no range' : 'req=$rangeHeader';
    final noteText = note == null ? '' : ' note=$note';
    final truncatedText = truncated ? ' TRUNCATED' : '';
    return '#$index $asked → $status '
        'want=$requestedLength '
        'served=$servedFrom-$servedTo/$total '
        'len=$declaredLength wrote=$writtenBytes$truncatedText '
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
    this.detourBudget = const Duration(seconds: 40),
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
  /// natural edge of the sequential download. Exactly at the head the proxy
  /// waits — steering there would restart the download that is already
  /// producing those bytes. A quarter megabyte beyond it is a seek (the player
  /// jumped), and waiting for the crawl is the original bug.
  static const int seekGapBytes = 256 * 1024;

  /// Ceiling for one blocked wait *before* the response starts. Once the body
  /// is flowing there is no absolute ceiling — a 3.7 GB play legitimately
  /// takes minutes, and cutting it would be a self-inflicted stall.
  final Duration maxWait;

  /// No TDLib event at all for this long ends a wait: the only network
  /// verdict in this file. Steady growth keeps resetting it — a slow download
  /// is not a failure.
  final Duration stallTimeout;

  /// How long one diversion may hold the download window. A diversion exists
  /// to feed a specific response; when that response is gone or the range is
  /// filled, the window goes back to the sequential download. The budget is
  /// the upper bound on how long the main stream can be paused by one tail
  /// probe, so it must stay in the same order of magnitude as a play start.
  final Duration detourBudget;

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
  int _diversions = 0;
  int _dedupeHits = 0;
  int _truncations = 0;
  int _forwardResponses = 0;

  /// Serialises window moves: two sockets must not fight over TDLib's single
  /// active download for the same file.
  Future<void> _windowChain = Future<void>.value();

  // --- current diversion (one at a time, by construction) ------------------

  bool _detourActive = false;
  int _detourFrom = -1;
  int _detourTo = -1;
  String _detourKey = '';
  Completer<void>? _detourFirstByte;
  Completer<void>? _detourFinished;

  /// Bind result: the URL the player should open.
  Uri? _url;
  Uri? get url => _url;

  bool get isRunning => _started;
  int get requestCount => _requests;
  int get servedCount => _served;
  int get windowSwitches => _windowSwitches;
  int get stallCount => _stalls;

  /// Targeted windows opened for forward ranges.
  int get diversionCount => _diversions;

  /// Repeat requests answered by the diversion already in flight / by the
  /// bytes it left on disk. AVPlayer asks for the same tail six times; without
  /// this the head download is restarted six times.
  int get dedupeCount => _dedupeHits;

  /// Responses that ended before their declared Content-Length.
  int get truncationCount => _truncations;

  /// True while a target window owns the TDLib download. Other responses must
  /// wait for it instead of reading that silence as a dead network.
  bool get diversionActive => _detourActive;

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
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader) ?? '-';
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
    // A player may ask for more than the resource holds (it guesses a size
    // from a manifest). Clamping keeps Content-Range truthful; the unsaid
    // bytes were never ours to promise.
    final requestedTo = min(to ?? (total - 1), total - 1);
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

    // Only responses past byte 0 ever justify a diversion. Counting them keeps
    // a completed duplicate (AVPlayer asks for the same tail six times) from
    // releasing the window while its twins are still reading.
    final isForward = from > 0;
    if (isForward) _forwardResponses++;

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
    // Declared length is the *requested* length, not the downloaded prefix.
    // If the body cannot reach it, the exchange is recorded as truncated —
    // that is a bug report, never a shortcut.
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
    var selfTruncated = false;
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      while (cursor <= requestedTo) {
        final available = watch.isComplete
            ? requestedTo
            : min(requestedTo, watch.readableEndFrom(cursor));
        if (available < cursor) {
          // A gap is a wait, never a failure: point the download at the gap if
          // it is far away, then wait for it to be filled.
          await _ensureReadable(cursor, total);
          await _waitForGrowth(cursor);
          continue;
        }
        final chunkEnd = min(available, cursor + chunkBytes - 1);
        final want = chunkEnd - cursor + 1;
        await reader.setPosition(cursor);
        final bytes = await reader.read(want);
        if (bytes.isEmpty) {
          // The file is shorter than TDLib reported: wait for the next update
          // instead of spinning on empty reads.
          await _waitForGrowth(cursor);
          continue;
        }
        // Awaiting the write is the backpressure: a player that stops reading
        // slows the loop instead of buffering the whole file in the process.
        await response.addStream(Stream<List<int>>.value(bytes));
        written += bytes.length;
        cursor += bytes.length;
      }
    } on StreamProxyException catch (e) {
      // The proxy itself gave up (a real stall, a vanished file). This is the
      // only case that counts as a truncation in the report: the player must
      // never see a short body because of a decision taken here.
      selfTruncated = true;
      note = 'PROXY_STALL ${_brief(e)}';
      onEvent?.call('body ended at $cursor/$requestedTo: $note');
    } on Object catch (e) {
      // The client closed the connection (AVPlayer cancels ranges all the
      // time). Recorded, not blamed on the proxy.
      note = 'client closed ${_brief(e)}';
      onEvent?.call('body ended at $cursor/$requestedTo: $note');
    } finally {
      await reader?.close();
      if (isForward) _forwardResponses--;
    }

    if (selfTruncated) {
      _truncations++;
      onEvent?.call('RANGE_TRUNCATED #$index $written/$declared');
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

    // The response that justified this diversion is over — finished or
    // cancelled. Release the window only when no sibling response is still
    // reading the same range; otherwise the tail would re-steal the download
    // from the head for every duplicate the player opens.
    if (_detourActive &&
        _forwardResponses == 0 &&
        from >= _detourFrom &&
        from <= _detourTo) {
      _abortDiversion('no forward consumer left');
    }
  }

  // --- window arbitration -------------------------------------------------

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _windowChain.then((_) => op());
    _windowChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Makes [cursor] readable, by waiting on the sequential download or by
  /// pointing the window at it.
  ///
  /// The three cases are deliberately distinct and must stay that way:
  /// 1. inside the head prefix (or just past it) → let the sequential download
  ///    do its job: never steal the window for a cursor that is about to
  ///    arrive on its own;
  /// 2. far ahead (a tail probe, a seek) → open a diversion;
  /// 3. a diversion already owns the window → wait for it, do not fight it.
  Future<void> _ensureReadable(int cursor, int total) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (watch.isComplete) return;
      if (watch.readableEndFrom(cursor) >= cursor) return;
      if (_detourActive) {
        // This diversion exists for this very range: the bytes are on their
        // way, so just wait for them. Blocking on the diversion's completion
        // here would freeze a consumer that could still be writing.
        if (cursor >= _detourFrom && cursor <= _detourTo) return;
        final finished = _detourFinished;
        if (finished != null && !finished.isCompleted) {
          onEvent?.call('wait diversion cursor=$cursor');
          await finished.future;
        }
        continue;
      }
      if (cursor <= watch.headBytes + seekGapBytes) {
        await _restoreSequential();
        return;
      }
      await _openDiversion(cursor, total);
      return;
    }
  }

  String _keyFor(int from, int to) => '$from-$to';

  /// Opens (or joins) a target window for [cursor]..end-of-window.
  Future<void> _openDiversion(int cursor, int total) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final from = cursor & ~1023; // TDLib chunks on 1 KB boundaries
      final end = min(total - 1, from + windowBytes - 1);
      final key = _keyFor(from, end);

      if (_detourActive) {
        if (_detourKey == key) {
          // Same tail, asked six times by the player: join the diversion that
          // is already filling this range instead of restarting the download.
          _dedupeHits++;
          onEvent?.call('diversion dedupe $key');
          final first = _detourFirstByte;
          if (first != null && !first.isCompleted) await first.future;
          return;
        }
        // A different range owns the window; queue behind it and re-apply.
        final finished = _detourFinished;
        if (finished != null) await finished.future;
        continue;
      }

      _diversions++;
      _detourActive = true;
      _detourFrom = from;
      _detourTo = end;
      _detourKey = key;
      _detourFirstByte = Completer<void>();
      _detourFinished = Completer<void>();
      _windowSwitches++;
      onEvent?.call('window→$from-$end (head=${watch.headBytes})');
      onWindowMove?.call(start: from, end: end);

      final first = _detourFirstByte!;
      unawaited(_runDiversion(from, end));
      await first.future;
      return;
    }
  }

  /// Steers the window, hands the first byte to the waiting response as soon
  /// as it exists, and keeps filling in the background.
  Future<void> _runDiversion(int from, int end) async {
    bool cancelled() => !_detourActive;
    try {
      await _serial(() => watch.requestWindow(from, end));
      // Only the first byte is awaited before headers go out: a 10 MB tail
      // must not delay the 206 that tells the player where the moov is.
      final firstByte = await _awaitSignal(
        () => watch.isComplete || watch.readableEndFrom(from) >= from,
        label: 'diversion first byte $from',
        ownDiversion: true,
        budget: detourBudget,
        cancelled: cancelled,
      );
      final first = _detourFirstByte;
      if (first != null && !first.isCompleted) first.complete();
      if (!firstByte) {
        onEvent?.call('diversion no first byte $from');
        return;
      }
      // Hold the window while this range is being consumed. Released by the
      // response loop (abort), by coverage completing, or by the budget.
      final filled = await _awaitSignal(
        () => watch.isComplete || watch.covers(from, end),
        label: 'diversion fill $from-$end',
        ownDiversion: true,
        budget: detourBudget,
        cancelled: cancelled,
      );
      onEvent?.call(
          'diversion ${cancelled() ? "aborted" : (filled ? "filled" : "budget")} '
          '$from-$end');
    } on Object catch (e) {
      onEvent?.call('diversion end ${_brief(e)}');
    } finally {
      _finishDiversion();
    }
  }

  void _abortDiversion(String why) {
    if (!_detourActive) return;
    onEvent?.call('diversion abort ($why)');
    _finishDiversion();
  }

  void _finishDiversion() {
    if (!_detourActive) return;
    // A diversion that cannot even deliver its first byte must not leave the
    // waiting response blocked on a completer nobody will complete.
    if (!(_detourFirstByte?.isCompleted ?? true)) _detourFirstByte!.complete();
    if (!(_detourFinished?.isCompleted ?? true)) _detourFinished!.complete();
    _detourActive = false;
    _detourKey = '';
    _detourFrom = -1;
    _detourTo = -1;
    _detourFirstByte = null;
    _detourFinished = null;
    // A targeted window is a detour, not the destination: put the sequential
    // download back so the play keeps building toward a complete cache.
    unawaited(_restoreSequential());
  }

  Future<void> _restoreSequential() {
    if (watch.isComplete) return Future<void>.value();
    return _serial(() async {
      if (_detourActive) return; // a newer diversion already owns the window
      try {
        await watch.resumeSequential();
      } on Object {
        // The watch may already be disposed (play stopped, player closed):
        // a failed restore must not surface as an unhandled async error.
      }
    });
  }

  /// Makes the first byte of `from` servable, or throws with the real numbers.
  Future<void> _prepare(int from, int to, int total) async {
    final requestLength = to - from + 1;
    final gate = max(1, min(min(total, startupBufferBytes), requestLength));
    if (from == 0 && _served == 0 && watch.headBytes < gate) {
      onEvent?.call('gate wait ${gate}B (head=${watch.headBytes})');
      final ok = await _awaitSignal(
        () => watch.headBytes >= gate || watch.isComplete,
        label: 'startup',
      );
      onEvent?.call('gate ${ok ? "ok" : "fail"} ${watch.headBytes}B');
      if (!ok) {
        throw StreamProxyException('缓冲区等待超时（startup，可读 ${watch.headBytes}B）');
      }
    }

    if (watch.isComplete) return;
    if (watch.readableEndFrom(from) >= from) return;

    await _ensureReadable(from, total);
    final ok = await _awaitSignal(
      () => watch.isComplete || watch.readableEndFrom(from) >= from,
      label: 'first byte $from',
    );
    if (!ok) {
      throw StreamProxyException(
          '首字节等待超时（$from，可读 ${watch.headBytes}B，$_windowLabel）');
    }
  }

  String get _windowLabel =>
      _detourActive ? 'diversion $_detourFrom-$_detourTo' : 'head';

  /// Waits until byte [cursor] is readable.
  ///
  /// No absolute ceiling on purpose: the body of a legitimate 3.7 GB response
  /// takes minutes, and a wall-clock cap would cut playback mid film. Silence
  /// from TDLib is the only failure signal — and silence we caused ourselves
  /// (a diversion holding the window) is not silence.
  Future<void> _waitForGrowth(int cursor) async {
    final ok = await _awaitSignal(
      () => watch.isComplete || watch.readableEndFrom(cursor) >= cursor,
      label: 'body $cursor',
    );
    if (!ok) {
      throw StreamProxyException(
          '播放数据停止增长（$cursor，可读 ${watch.headBytes}B，$_windowLabel）');
    }
  }

  /// Waits until [ready] is true. Three ways out, and nothing else:
  ///
  /// * ready — the bytes are there;
  /// * stall — no TDLib event at all for [stallTimeout];
  /// * budget — [ceiling] and [budget] elapsed (pre-response waits only).
  ///
  /// While a diversion owns the TDLib window the data legitimately does not
  /// grow for this response: the timer is held off instead of firing, unless
  /// this wait *is* the diversion (`ownDiversion`), which is bounded by its
  /// own budget.
  Future<bool> _awaitSignal(
    bool Function() ready, {
    required String label,
    bool ownDiversion = false,
    bool ceiling = true,
    Duration? budget,
    bool Function()? cancelled,
  }) async {
    if (ready()) return true;
    final limit = budget ?? maxWait;
    final started = DateTime.now();
    var lastSignal = started;
    final done = Completer<bool>();
    late final StreamSubscription<void> sub;
    sub = watch.progress.listen((_) {
      lastSignal = DateTime.now();
      if (ready() && !done.isCompleted) done.complete(true);
    });
    final ticker = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (done.isCompleted) return;
      if (ready()) {
        done.complete(true);
        return;
      }
      if (cancelled != null && cancelled()) {
        done.complete(false);
        return;
      }
      final now = DateTime.now();
      if (!ownDiversion && _detourActive) {
        lastSignal = now; // 我们自己的绕行把窗口挪走了，不是网络静默
        return;
      }
      if (now.difference(lastSignal) >= stallTimeout) {
        done.complete(false);
        return;
      }
      if (ceiling && now.difference(started) >= limit) done.complete(false);
    });
    final ok = await done.future;
    ticker.cancel();
    await sub.cancel();
    if (!ok) {
      onEvent?.call('wait fail $label');
      onStall?.call('wait fail $label ($_windowLabel)');
    }
    return ok;
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
