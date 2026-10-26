import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/byte_window.dart';
import 'package:tg_media_probe/playback/range_server.dart';

/// A source backed by a real file, with a controllable readable prefix.
///
/// This is the exact shape of the TDLib problem: the bytes exist on disk (TDLib
/// writes them as they arrive) but only a prefix is guaranteed contiguous, so
/// the server must wait for the rest instead of reading garbage.
class _GrowingSource implements StreamByteSource {
  _GrowingSource({
    required this.path,
    required this.totalBytes,
    required this.available,
    this.growPerPoll = 0,
  });

  final String path;

  @override
  final int totalBytes;

  int available;

  /// How many extra bytes become readable on each `ensureReadable` call, which
  /// is how a real download behaves while the player is reading.
  final int growPerPoll;

  int polls = 0;
  bool released = false;

  @override
  String get contentType => 'video/mp4';

  @override
  Future<FileWindow?> ensureReadable(
    int position, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    polls++;
    if (position >= available) {
      if (growPerPoll <= 0 || available >= totalBytes) return null;
      available = (available + growPerPoll).clamp(0, totalBytes);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (position >= available) return null;
    }
    return FileWindow(path: path, offset: 0, prefixSize: available);
  }

  @override
  Future<void> release() async {
    released = true;
  }
}

void main() {
  late Directory dir;
  late RangeServer server;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgmedia_range_');
    server = RangeServer(chunkBytes: 64);
  });

  tearDown(() async {
    await server.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<_GrowingSource> publish(int total, int available,
      {int growPerPoll = 0}) async {
    final file = File('${dir.path}/blob_$total');
    final bytes = Uint8List.fromList(
      List<int>.generate(total, (i) => i % 251),
    );
    await file.writeAsBytes(bytes, flush: true);
    final source = _GrowingSource(
      path: file.path,
      totalBytes: total,
      available: available,
      growPerPoll: growPerPoll,
    );
    await server.register(source);
    return source;
  }

  Future<HttpClientResponse> get(Uri url, {String? range, String method = 'GET'}) async {
    final client = HttpClient();
    final request = await client.openUrl(method, url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    return response;
  }

  test('serves an exact 206 with the right Content-Range and bytes', () async {
    final source = await publish(500, 500);
    final url = await server.register(source);
    final response = await get(url, range: 'bytes=10-19');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 10-19/500');
    expect(response.headers.contentLength, 10);
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
    expect(body.length, 10);
    expect(body.first, 10);
  });

  test('waits for the prefix to grow instead of reading past it', () async {
    // 200 KB total, only the first 8 KB readable, growing 8 KB per poll.
    final source = await publish(200 * 1024, 8 * 1024, growPerPoll: 8 * 1024);
    final url = await server.register(source);
    final response = await get(url, range: 'bytes=0-');
    expect(response.statusCode, HttpStatus.partialContent);
    final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));

    // Every byte arrives, in order, and it took more than one poll — i.e. the
    // server really waited for the download instead of truncating.
    expect(body.length, 200 * 1024);
    for (var i = 0; i < body.length; i++) {
      expect(body[i], i % 251, reason: 'byte $i is out of order');
    }
    expect(source.polls, greaterThan(1));
  });

  test('no Range header means 200 with the whole body', () async {
    final source = await publish(300, 300);
    final url = await server.register(source);
    final response = await get(url);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentLength, 300);
    final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
    expect(body.length, 300);
  });

  test('a start past EOF is 416 with Content-Range: bytes */total', () async {
    final source = await publish(1000, 1000);
    final url = await server.register(source);
    final response = await get(url, range: 'bytes=4000-');
    expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
  });

  test('an unknown token is 404 and never reaches a source', () async {
    await server.start();
    final url = Uri.parse('http://127.0.0.1:${server.port}/v/deadbeef');
    final response = await get(url);
    expect(response.statusCode, HttpStatus.notFound);
  });

  test('HEAD returns headers without a body', () async {
    final source = await publish(500, 500);
    final url = await server.register(source);
    final response = await get(url, range: 'bytes=0-99', method: 'HEAD');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.contentLength, 100);
    final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
    expect(body, isEmpty);
  });

  test('a source that never delivers aborts the connection instead of hanging',
      () async {
    final source = await publish(4096, 0);
    final url = await server.register(source);

    // Content-Length promised 4096 and nothing is readable. HTTP has no way to
    // "kindly deliver nothing" after that promise, so the server drops the
    // connection: AVPlayer sees a failed request and retries the range. What
    // must not happen is a socket that stays open forever, so this asserts the
    // whole exchange finishes fast and yields no bytes.
    Future<int> attempt() async {
      try {
        final response = await get(url, range: 'bytes=0-');
        var received = 0;
        await for (final chunk in response) {
          received += chunk.length;
        }
        return received;
      } on HttpException {
        return 0;
      } on SocketException {
        return 0;
      }
    }

    expect(await attempt().timeout(const Duration(seconds: 3)), 0);
  });

  test('unregister releases the source', () async {
    final source = await publish(10, 10);
    final url = await server.register(source);
    await server.unregister(url);
    expect(source.released, isTrue);
    final response = await get(url, range: 'bytes=0-1');
    expect(response.statusCode, HttpStatus.notFound);
  });

  test('tokens are random, not sequential', () async {
    final a = await server.register(await publish(10, 10));
    final b = await server.register(await publish(10, 10));
    expect(a.pathSegments.last, isNot(b.pathSegments.last));
    expect(a.pathSegments.last.length, 32);
    expect(Uri.parse(a.toString()).host, '127.0.0.1');
  });
}
