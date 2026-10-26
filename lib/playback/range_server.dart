import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'byte_window.dart';

/// Where the bytes behind one published URL come from.
///
/// The server knows nothing about TDLib; it only asks the source to wait until a
/// position is readable and then reads the pool file itself.
abstract class StreamByteSource {
  /// Logical size of the media file. Must be positive: `Content-Length` and
  /// `Content-Range` are meaningless without it.
  int get totalBytes;

  /// Value for the `Content-Type` header, e.g. `video/mp4`.
  String get contentType;

  /// Waits until the byte at [position] can be read, then reports the window it
  /// lives in. Returns null if it never becomes readable within [timeout].
  Future<FileWindow?> ensureReadable(
    int position, {
    Duration timeout = const Duration(seconds: 25),
  });

  /// Stops whatever background download this source started.
  Future<void> release();
}

/// Loopback HTTP server that turns TDLib's byte prefix into a range-servable
/// media URL, so AVPlayer can start on the first megabyte instead of the last.
///
/// Why a real HTTP server instead of `file:` or a blob:
/// * AVPlayer can only play progressively from a URL it can range-request;
/// * a `file:` URL is mapped and read to EOF by the media stack, which is the
///   whole-file wait this is meant to remove;
/// * range requests also let a seek work for a file that is not fully local —
///   including the `moov` atom at the end of a non-faststart mp4.
///
/// Containment: bound to [InternetAddress.loopbackIPv4] on an ephemeral port,
/// every path carries a 128-bit random token, and an unknown token is a 404.
/// Nothing outside the app can guess a URL; nothing outside the device can reach
/// the socket.
class RangeServer {
  RangeServer({
    this.onUnknownToken,
    this.chunkBytes = 256 * 1024,
    this.pollHint = const Duration(seconds: 25),
  });


  /// Chunk size for socket writes. 256 KB is small enough that the first frames
  /// arrive with the first request and large enough not to syscall per packet.
  final int chunkBytes;

  /// How long a single read may wait for TDLib before the response is cut
  /// short. The player then sees a truncated stream and retries the range.
  final Duration pollHint;

  /// Called for a token this server did not publish. Kept for diagnostics; a
  /// real 404 is the normal answer.
  final StreamByteSource Function(String token)? onUnknownToken;

  HttpServer? _server;
  final Map<String, StreamByteSource> _routes = <String, StreamByteSource>{};
  final Map<String, Uri> _urls = <String, Uri>{};
  final Random _random = Random.secure();
  Future<void>? _starting;

  bool get isRunning => _server != null;

  int? get port => _server?.port;

  /// Starts listening once. Concurrent callers share the same future, so two
  /// videos racing to load cannot bind two sockets.
  Future<void> start() {
    final running = _server;
    if (running != null) return Future<void>.value();
    final pending = _starting;
    if (pending != null) return pending;
    final future = _bind();
    _starting = future;
    return future;
  }

  Future<void> _bind() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      // One request per connection is the norm for players; keep-alive is fine
      // but must not delay shutdown.
      _server = server;
      server.listen(
        (request) {
          unawaited(_serve(request));
        },
        onError: (Object _) {
          // A dead socket is not an app-level error: the player reconnects.
        },
        cancelOnError: false,
      );
    } finally {
      _starting = null;
    }
  }

  /// Publishes [source] under a fresh token and returns its URL.
  Future<Uri> register(StreamByteSource source) async {
    await start();
    final token = _newToken();
    _routes[token] = source;
    final url = Uri.parse('http://127.0.0.1:${_server!.port}/v/$token');
    _urls[token] = url;
    return url;
  }

  /// Forgets a token. Any in-flight request keeps its own reference and ends by
  /// itself; the source is asked to stop its download.
  Future<void> unregister(Uri url) async {
    final segments = url.pathSegments;
    if (segments.length < 2) return;
    final token = segments.last;
    _urls.remove(token);
    final source = _routes.remove(token);
    if (source != null) await source.release();
  }

  Future<void> unregisterAll() async {
    final sources = _routes.values.toList();
    _routes.clear();
    _urls.clear();
    for (final source in sources) {
      await source.release();
    }
  }

  Future<void> close() async {
    await unregisterAll();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    // A player that hangs up mid-stream must not leave a pending future behind.
    unawaited(response.done.catchError((Object _) {}));

    final segments = request.uri.pathSegments;
    if (segments.length != 2 || segments.first != 'v') {
      _plain(response, HttpStatus.notFound, 'unknown path');
      return;
    }
    final token = segments[1];
    final source = _routes[token] ?? onUnknownToken?.call(token);
    if (source == null) {
      _plain(response, HttpStatus.notFound, 'unknown token');
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      _plain(response, HttpStatus.methodNotAllowed, 'method not allowed');
      return;
    }

    final total = source.totalBytes;
    final parsed = parseRangeHeader(request.headers.value('range'), total);
    final headers = response.headers;
    headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    headers.set(HttpHeaders.contentTypeHeader, source.contentType);

    switch (parsed) {
      case RangeUnsatisfiable(:final totalBytes):
        headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalBytes');
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      case RangeNone():
        // No range: send everything. Length is known, so the player can still
        // show progress.
        if (total > 0) headers.contentLength = total;
        response.statusCode = HttpStatus.ok;
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        await _write(response, source, 0, total - 1);
      case RangeOk(:final range):
        headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.endInclusive}/$total',
        );
        headers.contentLength = range.length;
        response.statusCode = HttpStatus.partialContent;
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        await _write(response, source, range.start, range.endInclusive);
    }
  }

  /// Streams `[start, endInclusive]`, waiting for TDLib whenever the requested
  /// byte is not there yet.
  ///
  /// The loop is chunked rather than "wait for the whole range": a 40 MB range
  /// request from AVPlayer would otherwise block until the entire file arrived,
  /// which is the problem this server exists to fix.
  Future<void> _write(
    HttpResponse response,
    StreamByteSource source,
    int start,
    int endInclusive,
  ) async {
    var position = start;
    var aborted = false;
    unawaited(response.done.then((_) {}, onError: (Object _) {
      aborted = true;
    }));

    try {
      while (position <= endInclusive) {
        if (aborted) return;
        final window = await source.ensureReadable(position, timeout: pollHint);
        if (window == null) {
          // Nothing arrived in time. Closing here makes the player see a short
          // body and retry; inventing bytes would corrupt its cache.
          return;
        }
        final take = min(window.availableFrom(position), endInclusive - position + 1);
        if (take <= 0) return;
        await _copy(response, window, position, take);
        position += take;
      }
      await response.flush();
    } catch (_) {
      // Client hung up, socket closed, file went away. Never rethrow: an
      // unhandled error on a request future is invisible and noisy.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _copy(
    HttpResponse response,
    FileWindow window,
    int position,
    int length,
  ) async {
    final file = await File(window.path).open();
    try {
      await file.setPosition(window.physicalOffset(position));
      var remaining = length;
      while (remaining > 0) {
        final chunk = await file.read(min(remaining, chunkBytes));
        if (chunk.isEmpty) return;
        response.add(chunk);
        remaining -= chunk.length;
      }
      // Flush per chunk group so the player receives data as it lands instead
      // of at the end of a 40 MB range.
      await response.flush();
    } finally {
      await file.close();
    }
  }

  void _plain(HttpResponse response, int status, String body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
    unawaited(response.close());
  }
}
