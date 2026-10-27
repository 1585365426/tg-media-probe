/// Streaming playback (边下边播) regressions.
///
/// The device failure this file guards against: AVPlayer does not request
/// byte 0 first — it probes the tail and arbitrary offsets, while TDLib
/// downloads from 0 upward. The proxy must *steer the TDLib window* to the
/// range the player asked for, serve it, and restore the sequential download.
/// Waiting for the crawl is the "缓冲 → 读取失败" bug.
///
/// Every proxy assertion here goes over real HTTP against a real loopback
/// listener — no fakes between HttpClient and HttpServer.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/media_metadata.dart';
import 'package:tg_media_probe/playback/playback_trace.dart';
import 'package:tg_media_probe/playback/stream_proxy.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

// ------------------------------------------------------------------ fixtures

MediaRecord video(int messageId, {String? name}) => MediaRecord(
      chatId: 1,
      messageId: messageId,
      fileId: 1000 + messageId,
      kind: MediaKind.video,
      sizeBytes: 4096,
      fileName: name ?? 'v$messageId.mp4',
      messageDateUnix: 1700000000 + messageId,
    );

/// A file whose "download" is scripted by the test: `advance(bytes)` grows the
/// local file at the current window offset and pushes the matching update;
/// `deliverRange` emulates TDLib moving its download window after a targeted
/// request.
class ScriptedFile implements FileTransferApi {
  ScriptedFile(this.sandbox, {this.expectedSize = 1024 * 1024});

  final TestSandbox sandbox;
  final int expectedSize;

  late final String path = sandbox.tempFile('stream-$fileId.bin');
  int fileId = 0;
  int downloaded = 0;

  /// The TDLib download window: `downloaded` counts from this offset.
  int windowOffset = 0;
  bool completed = false;
  int downloadCalls = 0;
  int rangeCalls = 0;
  int cancelCalls = 0;
  (int, int)? lastRange;

  /// `start` throws for these ids, the way TDLib refuses a stale file id.
  Map<int, String> rejectIds = <int, String>{};

  /// When true, `start` accepts the transfer but never writes a byte.
  bool silentStart = false;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  Future<void> _writeAt(int absoluteOffset, List<int> bytes) async {
    final file = File(path);
    if (!await file.exists()) await file.create(recursive: true);
    final current = await file.length();
    final sink = file.openWrite(mode: FileMode.append);
    if (absoluteOffset > current) {
      // A window past the current end: pad the gap so offsets stay honest.
      sink.add(List<int>.filled(absoluteOffset - current, 0));
    }
    if (absoluteOffset + bytes.length > current) {
      sink.add(bytes.sublist(
          absoluteOffset > current ? 0 : current - absoluteOffset));
    }
    await sink.flush();
    await sink.close();
  }

  /// Grows the current window prefix by [bytes] (sequential download step).
  Future<void> advance(int bytes) async {
    if (completed) return;
    final writtenAt = windowOffset + downloaded;
    await _writeAt(writtenAt, List<int>.filled(bytes, 0x61));
    downloaded += bytes;
    _push();
  }

  void _push() {
    _updates.add(FileState(
      id: fileId,
      size: completed ? expectedSize : 0,
      expectedSize: expectedSize,
      downloadedSize: downloaded,
      isCompleted: completed,
      path: downloaded > 0 || completed ? path : '',
      canBeDownloaded: true,
      downloadOffset: windowOffset,
    ));
  }

  /// Emulates a TDLib window move: the targeted range arrives.
  Future<void> deliverRange(int offset, int bytes) async {
    windowOffset = offset;
    downloaded = 0;
    await advance(bytes);
  }

  Future<void> complete() async {
    windowOffset = 0;
    final file = File(path);
    final current = await file.exists() ? await file.length() : 0;
    if (current < expectedSize) {
      final sink = file.openWrite(mode: FileMode.append);
      sink.add(List<int>.filled(expectedSize - current, 0x61));
      await sink.flush();
      await sink.close();
    }
    completed = true;
    downloaded = expectedSize;
    _push();
  }

  @override
  Future<FileState?> stat(int id) async {
    fileId = id;
    return FileState(
      id: id,
      size: completed ? expectedSize : 0,
      expectedSize: expectedSize,
      downloadedSize: downloaded,
      isCompleted: completed,
      path: downloaded > 0 || completed ? path : '',
      canBeDownloaded: true,
      downloadOffset: windowOffset,
    );
  }

  @override
  Future<void> start(int id) async {
    downloadCalls++;
    final rejection = rejectIds[id];
    if (rejection != null) throw VideoSourceException(rejection);
    if (silentStart) return;
    if (downloadCalls == 1 && downloaded == 0) {
      // TDLib's first write lands right after the transfer is accepted.
      await advance(64 * 1024);
    }
  }

  @override
  Future<void> startRange(
    int id, {
    required int offset,
    required int limit,
  }) async {
    rangeCalls++;
    lastRange = (offset, limit);
    // The real TDLib *replaces* the download window; the test decides when
    // (and whether) the bytes actually arrive via deliverRange.
  }

  @override
  Future<void> cancel(int id) async => cancelCalls++;

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

/// A metadata lookup that hands back a working record for a stale id — the
/// File-not-found repair, exercised through the streaming entry point.
class RepairingMetadata implements MediaMetadataLookup {
  RepairingMetadata(this.freshId);

  final int freshId;
  int calls = 0;

  @override
  Future<MediaRecord?> fetch(int chatId, int messageId) async {
    calls++;
    return MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: freshId,
      kind: MediaKind.video,
      sizeBytes: 4096,
      fileName: 'fresh.mp4',
      messageDateUnix: 1700000000 + messageId,
    );
  }
}

/// Watch over a [ScriptedFile], mirroring the resolver's `_LiveFileWatch`
/// exactly — same interface, same window semantics including the coverage map
/// (bytes stay readable after the window moves away).
class FixtureWatch implements FileProgressWatch {
  FixtureWatch(this.api, this.fileId, {FileState? initial}) {
    // A broadcast stream never replays: a fixture built after `advance` or
    // `complete` needs the state pushed as if it had been listening.
    if (initial != null) _apply(initial);
    sub = api.updates().listen((state) {
      if (state.id != fileId) return;
      _apply(state);
      if (!_changes.isClosed) _changes.add(null);
    });
  }

  final ScriptedFile api;
  final int fileId;
  String path = '';
  int expected = 0;
  int prefix = 0;
  int windowOffset = 0;
  bool complete = false;
  int windowRequests = 0;
  int resumeRequests = 0;
  final ByteCoverage present = ByteCoverage();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final StreamSubscription<FileState> sub;

  void _apply(FileState state) {
    if (state.id != fileId) return;
    if (state.path.isNotEmpty) path = state.path;
    if (state.expectedSize > expected) expected = state.expectedSize;
    if (state.isCompleted) {
      complete = true;
      windowOffset = 0;
      prefix = state.downloadedSize;
      if (expected > 0) present.add(0, expected - 1);
    } else {
      windowOffset = state.downloadOffset;
      prefix = state.downloadedSize;
      if (path.isNotEmpty && prefix > 0) {
        present.add(windowOffset, windowOffset + prefix - 1);
      }
    }
  }

  /// When true, `requestWindow` asks the fixture to deliver the bytes at once.
  bool autoDeliver = true;

  @override
  int get headBytes => complete ? expected : present.prefixLength;

  @override
  int readableEndFrom(int from) {
    if (complete) return expected - 1;
    return present.endFrom(from);
  }

  @override
  bool covers(int from, int end) {
    if (complete) return true;
    return present.covers(from, end);
  }

  @override
  int get expectedBytes => expected;
  @override
  bool get isComplete => complete;
  @override
  String get localPath => path;
  @override
  Stream<void> get progress => _changes.stream;

  @override
  Future<void> requestWindow(int from, int end) async {
    windowRequests++;
    if (autoDeliver) {
      await api.deliverRange(from, end - from + 1);
      // Mirror the resolver's watcher: the update pushed by deliverRange is
      // what moves this window; nothing more to do here.
    }
  }

  @override
  Future<void> resumeSequential() async {
    resumeRequests++;
    if (complete) return;
    windowOffset = 0;
    // TDLib resume keeps previously downloaded bytes; the head prefix is the
    // contiguous run that was really written, not the sparse file's length.
    prefix = present.prefixLength;
    // The scripted download must resume writing at the head as well, otherwise
    // the next `advance` appends at the tail offset and never fills the gap.
    api.windowOffset = 0;
    api.downloaded = prefix;
    // A proxy may ask for the resume right as the test tears the watch down;
    // a closed broadcast controller would throw from a background task.
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await sub.cancel();
    await _changes.close();
  }
}

HttpClient _client() => HttpClient();

Future<List<int>> _drain(HttpClientResponse response) =>
    response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));

// --------------------------------------------------------------------- tests

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  group('proxy over real HTTP', () {
    test('an explicit range is served in full; the tail is window-steered',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 4 * 1024 * 1024);
      await api.advance(1024 * 1024); // head prefix: 1 MB of 4 MB
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 256 * 1024,
        stallTimeout: const Duration(seconds: 5),
      );
      final url = await proxy.start();
      expect(url.host, '127.0.0.1');

      final client = _client();

      // 1. an explicit range: the declared range is the *requested* range and
      //    the body is exactly that many bytes. Truncating it at the download
      //    head is what made AVPlayer drop the resource on device.
      var request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048575');
      var response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-1048575/4194304');
      expect(response.headers.contentLength, 1048576);
      var head = await _drain(response);
      expect(head.length, 1048576, reason: '请求多少就必须给多少，不能截断');

      // 2. a tail probe (moov at the end) → the window moves to the tail.
      request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=-65536');
      response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(watch.windowRequests, 1, reason: '尾部 range 必须切窗口，不能傻等顺序下载');
      final tail = await _drain(response);
      expect(tail.length, 65536);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes ${4 * 1024 * 1024 - 65536}-${4 * 1024 * 1024 - 1}/4194304');

      // 3. after serving a steered window the sequential download is restored.
      // The restore fires after the response is written; give it a beat.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watch.resumeRequests, greaterThanOrEqualTo(1),
          reason: '窗口是绕行，不是目的地');

      // 4. an arbitrary mid-file range → window steering again.
      request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2000000-2100000');
      response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final mid = await _drain(response);
      expect(mid.length, 100001);

      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('an unknown path is refused, not served', () async {
      final api = ScriptedFile(sandbox);
      await api.advance(16);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(watch: watch);
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url.replace(path: '/v/wrong-token'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.forbidden);
      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('real silence ends a blocked wait instead of hanging the player',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 8 * 1024 * 1024)
        ..silentStart = true;
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 1024 * 1024,
        stallTimeout: const Duration(milliseconds: 80),
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      final body = await _drain(response);
      expect(body, isEmpty, reason: 'stall 断开连接，不给播放器半截数据');
      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('slow but steady growth finishes the declared range', () async {
      final api = ScriptedFile(sandbox, expectedSize: 2 * 1024 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 512 * 1024,
        stallTimeout: const Duration(milliseconds: 200),
        maxWait: const Duration(seconds: 5),
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final responseFuture = request.close();

      // 512 KB in 8 chunks of 64 KB, one every 60 ms: each gap is well under
      // the stall window, and every chunk resets it.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await api.advance(64 * 1024);
      }

      final response = await responseFuture;
      expect(response.statusCode, HttpStatus.partialContent);
      final drain = _drain(response);
      // Keep feeding: a slow origin must still deliver the whole range rather
      // than leave the player with a short body.
      for (var i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await api.advance(64 * 1024);
      }
      final body = await drain;
      expect(body.length, 2 * 1024 * 1024, reason: '慢速增长不是失败');
      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('bytes leave the proxy while the file is still downloading',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 4 * 1024 * 1024);
      await api.advance(256 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 64 * 1024,
        stallTimeout: const Duration(milliseconds: 500),
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      // 3 MB of a 4 MB file: the response cannot be finished without waiting.
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-3145727');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-3145727/4194304');

      var received = 0;
      final done = Completer<void>();
      response.listen((chunk) => received += chunk.length,
          onDone: () => done.complete());

      // Wait until the first bytes have crossed the socket, with the file
      // still incomplete — that is the whole claim under test.
      while (received == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.completed, isFalse, reason: '播放时文件必须还没下完');
      expect(received, lessThan(4 * 1024 * 1024));

      // The rest of the file arrives; the same response completes.
      await api.complete();
      await done.future;
      expect(received, 3145728, reason: '声明多少字节就要发多少字节');

      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('completion mid-play serves the exact requested window', () async {
      final api = ScriptedFile(sandbox, expectedSize: 512 * 1024);
      await api.advance(512 * 1024);
      await api.complete();
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 64 * 1024,
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=100000-199999');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final body = await _drain(response);
      expect(body.length, 100000, reason: '完整文件按请求的精确窗口服务');
      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });
  });

  group('resolveStream chooses by data', () {
    test('a complete cache returns the file directly, no proxy', () async {
      final api = ScriptedFile(sandbox);
      await File(api.path).writeAsBytes(List<int>.filled(api.expectedSize, 1));
      api.completed = true;
      final resolver =
          VideoSourceResolver(api: api, fileExists: (_) async => true);

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isFalse, reason: '完整缓存必须直接本地播放');
      expect(source.path, api.path);
      expect(api.downloadCalls, 0, reason: '完整缓存不得重新下载');
      await api.close();
    });

    test('a partial file streams without waiting for completion', () async {
      final api = ScriptedFile(sandbox, expectedSize: 1024 * 1024);
      await api.advance(512 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 256 * 1024,
      );

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isTrue, reason: '未下载完不得等完整文件');
      expect(Uri.parse(source.url).scheme, 'http');
      expect(api.completed, isFalse, reason: 'resolveStream 不等 isCompleted');
      final client = _client();
      final request = await client.getUrl(Uri.parse(source.url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-262143');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final body = await _drain(response);
      expect(body.length, 256 * 1024);
      client.close(force: true);
      await source.dispose();
      await api.close();
    });

    test('a stalled stream start is a network verdict', () async {
      final api = ScriptedFile(sandbox)..silentStart = true;
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 512 * 1024,
        stallTimeout: const Duration(milliseconds: 80),
      );

      await expectLater(
        resolver.resolveStream(1001),
        throwsA(isA<VideoSourceStalled>()),
      );
      expect(resolver.inflightCount, 0, reason: '失败不得留在在飞表里');
      await api.close();
    });

    test('a file id TDLib rejects is repaired through the streaming entry',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 64 * 1024)
        ..rejectIds = <int, String>{
          1001: 'TDLib error 400: File not found',
        };
      final metadata = RepairingMetadata(2002);
      api.fileId = 2002;
      await api.advance(32 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        metadata: metadata,
        fileExists: (_) async => true,
        startupBufferBytes: 16 * 1024,
      );

      final source =
          await resolver.resolveStream(1001, chatId: 1, messageId: 1);

      expect(metadata.calls, 1, reason: '必须从消息重新获取 file_id');
      expect(source.isStreaming, isTrue);
      await source.dispose();
      await api.close();
    });

    test('the same id resolved twice shares one download', () async {
      final api = ScriptedFile(sandbox, expectedSize: 256 * 1024);
      await api.advance(128 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 32 * 1024,
      );

      final first = resolver.resolveStream(1001);
      final second = resolver.resolveStream(1001);
      final results = await Future.wait([first, second]);

      expect(results[0].url, results[1].url, reason: '同一 fileId 共享同一次 resolve');
      expect(api.downloadCalls, 1, reason: '不得重复 downloadFile');
      await results[0].dispose();
      await api.close();
    });

    test('the proxy log reaches the trace', () async {
      final api = ScriptedFile(sandbox, expectedSize: 256 * 1024);
      await api.advance(128 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 32 * 1024,
      );
      final trace = PlaybackTrace(fileId: 1001);

      final source = await resolver.resolveStream(1001, trace: trace);
      final client = _client();
      final request = await client.getUrl(Uri.parse(source.url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      await request.close();
      client.close(force: true);

      expect(trace.proxyEvents, isNotEmpty, reason: '代理行为必须进诊断');
      expect(trace.proxyEvents.join(' '), contains('206'));
      await source.dispose();
      await api.close();
    });

    test('FORCE_STREAMING_TEST streams a complete file so the proxy runs',
        () async {
      // Every acceptance attempt kept landing on a prefetched video: a
      // complete file short-circuited to PlaySource.file and the proxy was
      // never exercised. Under the forced test the complete file must still
      // go through the range proxy.
      final api = ScriptedFile(sandbox);
      await api.complete();
      final diag = StreamingDiagnostics()..setForceStreamingTest(true);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        diagnostics: diag,
      );

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isTrue,
          reason: '强制模式不得因为文件已完整就绕过代理');
      expect(Uri.parse(source.url).scheme, 'http');
      expect(diag.decision, 'STREAM');
      expect(diag.decisionReason, 'complete_file_served_over_http');
      await source.dispose();
      await api.close();
    });

    test('streaming off by preference returns the path and says why', () async {
      final api = ScriptedFile(sandbox);
      await api.complete();
      final diag = StreamingDiagnostics()..setStreamingPreference(false);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        diagnostics: diag,
      );

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isFalse);
      expect(source.path, api.path);
      expect(diag.decision, 'LOCAL_FILE');
      expect(diag.decisionReason, 'streaming_disabled_by_preference',
          reason: '每个 LOCAL_FILE 都必须回答为什么不是流式');
      expect(diag.panelLines().join('\n'), contains('PREFERENCE STREAMING: OFF'));
      await api.close();
    });
  });

  /// The proxy has to be correct on its own, with no player in the loop: if it
  /// cannot answer a byte range exactly, no amount of AVPlayer debugging will
  /// help. Every case here asserts status, Content-Range, Content-Length and
  /// the number of bytes that actually arrived.
  group('range proxy self-test', () {
    Future<void> expectRange(
      Uri url, {
      required String range,
      required int expectedStatus,
      required int expectedLength,
      String? expectedContentRange,
    }) async {
      final client = _client();
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      expect(response.statusCode, expectedStatus, reason: range);
      if (expectedContentRange != null) {
        expect(response.headers.value(HttpHeaders.contentRangeHeader),
            expectedContentRange,
            reason: range);
      }
      final body = await _drain(response);
      expect(body.length, expectedLength, reason: '$range 实际字节数');
      client.close(force: true);
    }

    test('serves head, large head, mid-file and tail ranges exactly', () async {
      final api = ScriptedFile(sandbox, expectedSize: 8 * 1024 * 1024);
      await api.advance(8 * 1024 * 1024);
      await api.complete();
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(watch: watch, contentType: 'video/mp4');
      final url = await proxy.start();

      // 0-1023: the 1 KB probe AVPlayer opens with.
      await expectRange(url,
          range: 'bytes=0-1023',
          expectedStatus: 206,
          expectedLength: 1024,
          expectedContentRange: 'bytes 0-1023/8388608');
      // 0-2 MB: the moov-at-the-head window.
      await expectRange(url,
          range: 'bytes=0-2097151',
          expectedStatus: 206,
          expectedLength: 2097152,
          expectedContentRange: 'bytes 0-2097151/8388608');
      // an arbitrary mid-file seek.
      await expectRange(url,
          range: 'bytes=5000000-6000000',
          expectedStatus: 206,
          expectedLength: 1000001,
          expectedContentRange: 'bytes 5000000-6000000/8388608');
      // the last 1000 bytes — the moov-at-the-tail read.
      await expectRange(url,
          range: 'bytes=8387608-8388607',
          expectedStatus: 206,
          expectedLength: 1000,
          expectedContentRange: 'bytes 8387608-8388607/8388608');
      // a suffix range must be answered as the same tail window.
      await expectRange(url,
          range: 'bytes=-1000',
          expectedStatus: 206,
          expectedLength: 1000,
          expectedContentRange: 'bytes 8387608-8388607/8388608');
      // beyond EOF: 416 with the real size, not a silent 200.
      await expectRange(url,
          range: 'bytes=9000000-9000100',
          expectedStatus: 416,
          expectedLength: 0);

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('a tail range on an unfinished file is window-steered and exact',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 8 * 1024 * 1024);
      await api.advance(256 * 1024); // only the head exists
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(watch: watch);
      final url = await proxy.start();

      await expectRange(url,
          range: 'bytes=8387608-8388607',
          expectedStatus: 206,
          expectedLength: 1000,
          expectedContentRange: 'bytes 8387608-8388607/8388608');
      expect(watch.windowRequests, 1, reason: '尾部必须切窗口，不能等顺序下载');

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('every exchange is recorded with request and response numbers',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 1024 * 1024);
      await api.advance(1024 * 1024);
      await api.complete();
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final exchanges = <ProxyExchange>[];
      final proxy = StreamProxyServer(
        watch: watch,
        contentType: 'video/mp4',
        onExchange: exchanges.add,
      );
      final url = await proxy.start();

      await expectRange(url,
          range: 'bytes=0-1023',
          expectedStatus: 206,
          expectedLength: 1024);

      // The client sees its Content-Length satisfied before the server records
      // the exchange; give the handler its turn.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(exchanges, hasLength(1));
      final exchange = exchanges.single;
      expect(exchange.rangeHeader, 'bytes=0-1023');
      expect(exchange.requestedFrom, 0);
      expect(exchange.requestedTo, 1023);
      expect(exchange.status, 206);
      expect(exchange.declaredLength, 1024);
      expect(exchange.writtenBytes, 1024);
      expect(exchange.contentRange, 'bytes 0-1023/1048576');
      expect(exchange.contentType, 'video/mp4');
      expect(exchange.contentEncoding, 'identity');
      expect(exchange.truncated, isFalse);

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    // ---------------------------------------------------------------------
    // A–F: 真机故障回归。设备上 AVPlayer 发的是 bytes=0-659667829，而 TDLib
    // 只有 2 MB；旧实现把那 2 MB 当成本次响应的全部并关掉连接，播放器随即
    // 报 “网络连接已中断”。这几条按同一形状缩小比例复现。
    // ---------------------------------------------------------------------

    test('A: an open-ended request is not finished at the downloaded prefix',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 4 * 1024 * 1024);
      await api.advance(512 * 1024); // 只有前 512 KB
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 512 * 1024,
        stallTimeout: const Duration(seconds: 5),
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      // 与设备同形状：请求整个资源，而已下载的部分远小于它。
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4194303');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-4194303/4194304',
          reason: '声明范围必须等于请求范围，不是已下载前缀');
      expect(response.headers.contentLength, 4194304);

      var received = 0;
      final done = Completer<void>();
      response.listen((chunk) => received += chunk.length,
          onDone: () => done.complete());
      while (received == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 关键：前缀到齐之后响应必须还在，不能 close。
      expect(done.isCompleted, isFalse, reason: '前缀到了不等于请求结束');
      expect(watch.complete, isFalse);

      for (var i = 0; i < 14; i++) {
        await api.advance(256 * 1024);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await done.future;
      expect(received, 4194304, reason: '声明 4 MB 就要发 4 MB');

      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('B: the tail range arrives complete, byte for byte', () async {
      const total = 32 * 1024 * 1024;
      const from = total - 1024 * 1024;
      final api = ScriptedFile(sandbox, expectedSize: total);
      await api.advance(1024 * 1024); // moov 在尾部，正文还没下
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(watch: watch);
      final url = await proxy.start();

      await expectRange(url,
          range: 'bytes=$from-33554431',
          expectedStatus: 206,
          expectedLength: 1024 * 1024,
          expectedContentRange: 'bytes $from-33554431/33554432');
      expect(watch.windowRequests, 1, reason: '尾部 range 必须切窗口');

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('C: a range that is not downloaded yet waits for the window',
        () async {
      const total = 16 * 1024 * 1024;
      const from = 8 * 1024 * 1024;
      final api = ScriptedFile(sandbox, expectedSize: total);
      await api.advance(256 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        stallTimeout: const Duration(seconds: 5),
      );
      final url = await proxy.start();

      await expectRange(url,
          range: 'bytes=$from-${from + 512 * 1024 - 1}',
          expectedStatus: 206,
          expectedLength: 512 * 1024,
          expectedContentRange:
              'bytes $from-${from + 512 * 1024 - 1}/$total');
      expect(watch.windowRequests, 1, reason: '未下载的中段必须切窗口，不是报错');

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('D: a cancelled response releases the window instead of holding it',
        () async {
      const total = 32 * 1024 * 1024;
      const from = total - 1024 * 1024;
      final api = ScriptedFile(sandbox, expectedSize: total);
      await api.advance(1024 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      // 窗口不会自己送数据：由测试决定什么时候到多少。
      watch.autoDeliver = false;
      final proxy = StreamProxyServer(
        watch: watch,
        stallTimeout: const Duration(seconds: 5),
      );
      final url = await proxy.start();

      final client = _client();
      final request = await client.getUrl(url);
      request.headers
          .set(HttpHeaders.rangeHeader, 'bytes=$from-${total - 1}');
      final responseFuture = request.close();
      while (watch.windowRequests == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(proxy.diversionActive, isTrue, reason: '尾部应当持有窗口');
      await api.deliverRange(from, 4096);

      final response = await responseFuture;
      expect(response.statusCode, HttpStatus.partialContent);
      var received = 0;
      final subscription = response.listen((chunk) => received += chunk.length);
      while (received < 4096) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // 播放器放弃这条请求：Socket 直接断。下载继续产出，写失败即释放窗口。
      client.close(force: true);
      await subscription.cancel();
      // 4 MB 足以把已经死掉的 socket 写穿 —— 这一步就是在等写错误。
      await api.deliverRange(from, 4 * 1024 * 1024);

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (proxy.diversionActive && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(proxy.diversionActive, isFalse, reason: '请求取消后必须停掉对应等待');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(watch.resumeRequests, greaterThanOrEqualTo(1),
          reason: '窗口必须还给顺序下载');

      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('E: the same tail asked six times moves the window once', () async {
      const total = 32 * 1024 * 1024;
      const from = total - 1024 * 1024;
      final api = ScriptedFile(sandbox, expectedSize: total);
      await api.advance(1024 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(watch: watch);
      final url = await proxy.start();

      final futures = <Future<List<int>>>[];
      final client = _client();
      for (var i = 0; i < 6; i++) {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-33554431');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.partialContent);
        futures.add(_drain(response));
      }
      final bodies = await Future.wait(futures);
      for (final body in bodies) {
        expect(body.length, 1024 * 1024, reason: '重复请求也必须完整');
      }
      expect(watch.windowRequests, 1,
          reason: '同一个 range 重复 6 次，窗口只能切一次');
      expect(proxy.diversionCount, lessThanOrEqualTo(1));

      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });

    test('F: the head response keeps flowing across a tail diversion', () async {
      const total = 8 * 1024 * 1024;
      final api = ScriptedFile(sandbox, expectedSize: total);
      await api.advance(1024 * 1024);
      final watch = FixtureWatch(api, 1001, initial: await api.stat(1001));
      final proxy = StreamProxyServer(
        watch: watch,
        startupBufferBytes: 256 * 1024,
        stallTimeout: const Duration(seconds: 5),
      );
      final url = await proxy.start();
      final client = _client();

      // 主响应：整段打开。
      final headRequest = await client.getUrl(url);
      headRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final headResponse = await headRequest.close();
      expect(headResponse.statusCode, HttpStatus.partialContent);
      expect(headResponse.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-8388607/8388608');

      var headBytes = 0;
      final headDone = Completer<void>();
      headResponse.listen((chunk) => headBytes += chunk.length,
          onDone: () => headDone.complete());
      while (headBytes == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // 尾部探测：AVPlayer 解析 moov 的第二个请求。
      const tailFrom = total - 65536;
      final tailRequest = await client.getUrl(url);
      tailRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=$tailFrom-8388607');
      final tailResponse = await tailRequest.close();
      expect(tailResponse.statusCode, HttpStatus.partialContent);
      final tail = await _drain(tailResponse);
      expect(tail.length, 65536);

      // 主响应不能被这次绕行中断：继续下载，必须收满 8 MB。
      for (var i = 0; i < 8; i++) {
        await api.advance(1024 * 1024);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await headDone.future;
      expect(headBytes, 8388608, reason: '尾部探测不得截断主响应');

      client.close(force: true);
      await proxy.stop();
      await watch.dispose();
      await api.close();
    });
  });
}
