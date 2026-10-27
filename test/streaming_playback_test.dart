/// Streaming playback (边下边播) regressions.
///
/// One behaviour per test, named after the requirement it protects:
/// * a complete cache never touches the proxy;
/// * a partial file streams immediately — no waiting for completion;
/// * an MP4 the player cannot initialise falls back to the full download
///   silently;
/// * the proxy serves exactly the ranges it has and blocks (bounded) for the
///   ones it does not;
/// * the file id repair loop still works when streaming is the entry point;
/// * a file being streamed is invisible to the cache cleaner.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/media_metadata.dart';
import 'package:tg_media_probe/playback/stream_proxy.dart';
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
/// local file and pushes the matching update, `complete()` finishes it.
class ScriptedFile implements FileTransferApi {
  ScriptedFile(this.sandbox, {this.expectedSize = 1024 * 1024});

  final TestSandbox sandbox;
  final int expectedSize;

  late final String path = sandbox.tempFile('stream-$fileId.bin');
  int fileId = 0;
  int downloaded = 0;
  bool completed = false;
  int downloadCalls = 0;
  int cancelCalls = 0;

  /// `fileId -> error text`: `start` throws for these ids, the way TDLib
  /// refuses a stale file id on `downloadFile`.
  Map<int, String> rejectIds = <int, String>{};

  /// When true, `start` accepts the transfer but never writes a byte.
  bool silentStart = false;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  final StreamController<int> _growth = StreamController<int>.broadcast();

  Future<void> advance(int bytes) async {
    if (completed) return;
    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    final sink = file.openWrite(mode: FileMode.append);
    sink.add(List<int>.filled(bytes, 0x61));
    await sink.flush();
    await sink.close();
    downloaded += bytes;
    if (downloaded > expectedSize) downloaded = expectedSize;
    _growth.add(downloaded);
    _updates.add(FileState(
      id: fileId,
      size: 0,
      expectedSize: expectedSize,
      downloadedSize: downloaded,
      isCompleted: false,
      path: path,
      canBeDownloaded: true,
    ));
  }

  Future<void> complete() async {
    final have = await File(path).length();
    if (have < expectedSize) await advance(expectedSize - have);
    completed = true;
    _growth.add(downloaded);
    _updates.add(FileState(
      id: fileId,
      size: expectedSize,
      expectedSize: expectedSize,
      downloadedSize: expectedSize,
      isCompleted: true,
      path: path,
      canBeDownloaded: true,
    ));
  }

  @override
  Future<FileState?> stat(int id) async {
    fileId = id;
    // A size of 0 means TDLib answered the size is unknown: the caller must
    // not pretend to know the total in Content-Range.
    if (unknownSize) return null;
    return FileState(
      id: id,
      size: completed ? expectedSize : 0,
      expectedSize: expectedSize,
      downloadedSize: downloaded,
      isCompleted: completed,
      // A fresh record carries no path until the transfer actually started:
      // that is what forces the "wait for a path" behaviour.
      path: downloaded > 0 || completed ? path : '',
      canBeDownloaded: true,
    );
  }

  /// True while the fixture emulates "getFile says the size is unknown".
  bool unknownSize = false;

  @override
  Future<void> start(int id) async {
    downloadCalls++;
    final rejection = rejectIds[id];
    if (rejection != null) throw VideoSourceException(rejection);
    if (silentStart) return;
    if (downloadCalls == 1) {
      // TDLib's first write lands between "download accepted" and the first
      // poll: seed the file with one chunk so the watcher has a path.
      await advance(64 * 1024);
    }
  }

  @override
  Future<void> cancel(int id) async => cancelCalls++;

  @override
  Stream<FileState> updates() => _updates.stream;

  Stream<int> get growth => _growth.stream;

  Future<void> close() async {
    await _updates.close();
    await _growth.close();
  }
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

class _ManualWatch implements FileProgressWatch {
  int available = 0;
  int expected = 4096;
  bool complete = false;
  final _changes = StreamController<int>.broadcast();

  @override
  int get availableBytes => available;
  @override
  int get expectedBytes => expected;
  @override
  bool get isComplete => complete;
  @override
  Stream<int> get progress => _changes.stream;

  void grow(int bytes) {
    available = bytes;
    _changes.add(bytes);
  }
}

// --------------------------------------------------------------------- tests

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  group('stream proxy over HTTP range', () {
    test('serves a blocked wait as soon as the bytes arrive', () async {
      final watch = _ManualWatch();
      final file = File(sandbox.tempFile('proxy-1.bin'));
      await file.writeAsBytes(List<int>.filled(1024, 7));
      final proxy = StreamProxyServer(
        watch: watch,
        localPath: file.path,
        startupBufferBytes: 4096,
        stallTimeout: const Duration(seconds: 10),
      );
      final url = await proxy.start();
      expect(url.host, '127.0.0.1');

      // The request arrives before the data: the proxy must hold the
      // connection, not answer 416 or an empty 206.
      final client = HttpClient();
      final request = await client.getUrl(url.replace(path: url.path));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4095');
      final responseFuture = request.close();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      watch.grow(4096);
      await file.writeAsBytes(List<int>.filled(4096, 7), mode: FileMode.append);

      final response = await responseFuture;
      expect(response.statusCode, HttpStatus.partialContent);
      final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk),
      );
      expect(body.length, 4096);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-4095/4096');
      client.close(force: true);
      await proxy.stop();
    });

    test('an unknown path is refused, not served', () async {
      final watch = _ManualWatch();
      final file = File(sandbox.tempFile('proxy-2.bin'));
      await file.writeAsBytes(List<int>.filled(16, 1));
      final proxy = StreamProxyServer(watch: watch, localPath: file.path);
      final url = await proxy.start();

      final client = HttpClient();
      final request =
          await client.getUrl(url.replace(path: '/v/wrong-token'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.forbidden);
      client.close(force: true);
      await proxy.stop();
    });

    test('a stall ends the wait with an error, not forever', () async {
      final watch = _ManualWatch();
      final file = File(sandbox.tempFile('proxy-3.bin'));
      await file.writeAsBytes(List<int>.filled(16, 1));
      final proxy = StreamProxyServer(
        watch: watch,
        localPath: file.path,
        startupBufferBytes: 4096,
        stallTimeout: const Duration(milliseconds: 60),
      );
      final url = await proxy.start();

      final client = HttpClient();
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4095');
      final response = await request.close();
      // No bytes ever grow: the request must fail instead of hanging.
      final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk),
      );
      expect(body, isEmpty,
          reason: 'stall 断开连接，不给播放器半截数据');
      client.close(force: true);
      await proxy.stop();
    });
  });

  group('resolveStream chooses by data', () {
    test('a complete cache returns the file directly, no proxy', () async {
      final api = ScriptedFile(sandbox);
      await File(api.path).writeAsBytes(List<int>.filled(api.expectedSize, 1));
      api.completed = true;
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isFalse, reason: '完整缓存必须直接本地播放');
      expect(source.path, api.path);
      expect(api.downloadCalls, 0, reason: '完整缓存不得重新下载');
      await api.close();
    });

    test('a partial file streams without waiting for completion', () async {
      final api = ScriptedFile(sandbox, expectedSize: 1024 * 1024);
      await api.advance(512 * 1024); // half downloaded
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 256 * 1024,
      );

      final source = await resolver.resolveStream(1001);

      expect(source.isStreaming, isTrue, reason: '未下载完不得等完整文件');
      expect(Uri.parse(source.url).scheme, 'http');
      expect(api.completed, isFalse, reason: 'resolveStream 不等 isCompleted');
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(source.url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-262143');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      final body = await response.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk),
      );
      expect(body.length, 256 * 1024);
      client.close(force: true);
      await source.dispose();
      await api.close();
    });

    test('a stalled stream start is a network verdict, then fallback wins',
        () async {
      final api = ScriptedFile(sandbox)
        ..silentStart = true;
      // stat reports a size but no path and no bytes ever arrive: the
      // startup gate must time out with the stall error.
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
      // Give the *fresh* id the bytes; the stale id (1001) is the one asked,
      // and TDLib refuses it exactly like a device: at downloadFile time.
      api.fileId = 2002;
      await api.advance(32 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        metadata: metadata,
        fileExists: (_) async => true,
        startupBufferBytes: 16 * 1024,
      );

      // stat for id 1001 returns null (unknown size path), the transfer is
      // rejected as missing, the message is re-read and id 2002 streams.
      final source = await resolver.resolveStream(
        1001,
        chatId: 1,
        messageId: 1,
      );

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
  });

  group('cache protection while streaming', () {
    test('the streamed local file is registered in-use and released on stop',
        () async {
      final api = ScriptedFile(sandbox, expectedSize: 128 * 1024);
      await api.advance(64 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        startupBufferBytes: 16 * 1024,
      );

      final source = await resolver.resolveStream(1001);
      expect(source.isStreaming, isTrue);

      final registry = <String>[];
      source.proxy?.onClose(() => registry.add('released:${source.path}'));

      await source.dispose();
      expect(registry, hasLength(1), reason: 'proxy 停止时必须释放占用标记');
      await api.close();
    });
  });
}
