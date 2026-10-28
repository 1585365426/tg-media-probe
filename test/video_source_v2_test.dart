/// Streaming V2 resolve-layer tests.
///
/// What this file pins down is the *hand-off*, not the bytes: the resolver must
/// produce a `tgmedia://` source backed by a live [ResourceLoaderSession], it
/// must not share an inflight future with V1, it must not wait for the startup
/// buffer V1 needs, and a platform without the bridge must fail in a way the
/// feed controller can read as "drop to V1".
///
/// The byte-level behaviour of the loader lives in
/// `test/resource_loader_test.dart`; the HTTP behaviour of V1 stays in
/// `test/streaming_playback_test.dart`.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/native_streaming.dart'
    show StreamingV2Unavailable;
import 'package:tg_media_probe/playback/resource_loader.dart';
import 'package:tg_media_probe/playback/source_decision.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

// ------------------------------------------------------------------ fixtures

/// A TDLib file whose download the test drives: `advance` grows the current
/// window, `complete` finishes it. Same shape as the V1 fixture, trimmed to
/// what the V2 hand-off needs to observe.
class V2File implements FileTransferApi {
  V2File(this.sandbox, {this.expectedSize = 8 * 1024 * 1024});

  final TestSandbox sandbox;
  final int expectedSize;

  late final String path = sandbox.tempFile('v2-$fileId.bin');
  int fileId = 0;
  int downloaded = 0;
  int windowOffset = 0;
  bool completed = false;
  int downloadCalls = 0;
  int prefetchCalls = 0;
  int rangeCalls = 0;
  (int, int)? lastRange;
  DownloadCaller lastCaller = DownloadCaller.unknown;
  bool rejectStart = false;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  FileState _state() => FileState(
        id: fileId,
        size: completed ? expectedSize : 0,
        expectedSize: expectedSize,
        downloadedSize: downloaded,
        isCompleted: completed,
        // An incomplete transfer that has already named its file: exactly the
        // state V2 needs before the first data request can be answered.
        path: downloaded > 0 || completed ? path : '',
        canBeDownloaded: true,
        downloadOffset: windowOffset,
      );

  void _push() {
    if (!_updates.isClosed) _updates.add(_state());
  }

  Future<void> advance(int bytes) async {
    if (completed) return;
    final file = io.File(path);
    if (!await file.exists()) await file.create(recursive: true);
    final sink = file.openWrite(mode: io.FileMode.append);
    sink.add(List<int>.filled(bytes, 0x61));
    await sink.flush();
    await sink.close();
    downloaded += bytes;
    _push();
  }

  Future<void> complete() async {
    final file = io.File(path);
    final current = await file.exists() ? await file.length() : 0;
    if (current < expectedSize) {
      final sink = file.openWrite(mode: io.FileMode.append);
      sink.add(List<int>.filled(expectedSize - current, 0x61));
      await sink.flush();
      await sink.close();
    }
    completed = true;
    downloaded = expectedSize;
    windowOffset = 0;
    _push();
  }

  @override
  Future<FileState?> stat(int id) async {
    fileId = id;
    return _state();
  }

  @override
  Future<void> start(int id, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    downloadCalls++;
    if (rejectStart) throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    // TDLib's first write lands right after acceptance; V1 gates on it and V2
    // only needs the path it carries.
    if (downloaded == 0) await advance(64 * 1024);
  }

  @override
  Future<void> startRange(int id, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    // The window move itself is the bridge's business; what matters here is
    // that TDLib accepted it and started writing — the first window produces
    // the same first update a full start does.
    rangeCalls++;
    lastRange = (offset, limit);
    lastCaller = caller;
    if (caller == DownloadCaller.preload) return;
    if (downloaded == 0) await advance(64 * 1024);
  }

  @override
  Future<void> prefetch(int id) async {
    prefetchCalls++;
    await startRange(
      id,
      offset: 0,
      limit: StreamWindow.preloadBytes,
      caller: DownloadCaller.preload,
    );
  }

  final List<int> cancelled = <int>[];

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

/// The platform bridge, faked at the method-channel boundary: it records the
/// session lifecycle and can refuse the way a build without the Swift plugin
/// does.
class V2Transport implements NativeStreamingTransport {
  V2Transport({this.refuse = false});

  bool refuse;
  final List<String> opened = <String>[];
  final List<String> closed = <String>[];
  final List<int> openedGenerations = <int>[];
  final List<int> openedTotals = <int>[];
  final List<bool> openedCompleted = <bool>[];
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  @override
  bool get supported => !refuse;

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
    if (refuse) throw StreamingV2Unavailable('no bridge');
    opened.add(sessionId);
    openedGenerations.add(generation);
    openedTotals.add(totalBytes);
    openedCompleted.add(completed);
    return <String, Object?>{
      'totalBytes': totalBytes,
      'contentType': 'public.mpeg-4',
      'byteRangeAccessSupported': true,
      'entireLengthAvailableOnDemand': completed,
    };
  }

  @override
  Future<void> closeSession(String sessionId) async => closed.add(sessionId);
  @override
  Future<void> createPlayer(String sessionId) async {}
  @override
  Future<void> play(String sessionId) async {}
  @override
  Future<void> pause(String sessionId) async {}
  @override
  Future<void> seek(String sessionId, Duration position) async {}
  @override
  Future<void> setVolume(String sessionId, double volume) async {}
  @override
  Future<void> disposePlayer(String sessionId) async {}
  @override
  Stream<Map<String, Object?>> events() => _events.stream;

  Future<void> dispose() => _events.close();
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

  StreamingDiagnostics freshDiagnostics() {
    final diagnostics = StreamingDiagnostics();
    // A play resolve only takes the streaming branch while the preference is
    // on; the app default is on, and the tests state it so a future default
    // flip cannot silently turn every assertion into a full download.
    diagnostics.setStreamingPreference(true);
    return diagnostics;
  }

  group('resolveStreamV2 hand-off', () {
    test('the player is handed a tgmedia URL, not a loopback address',
        () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);

      expect(source.isResourceLoader, isTrue);
      expect(source.isStreaming, isTrue);
      expect(Uri.parse(source.url).scheme, kResourceLoaderScheme);
      expect(source.url, startsWith('tgmedia://video/'));
      expect(source.session, isNotNull);
      expect(source.proxy, isNull, reason: 'V2 不得同时开 loopback 代理');
      expect(transport.opened, <String>[source.session!.sessionId]);

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('the first window is 16 MB, not the 1.33 GB file', () async {
      // The report this replaces: a 1.33 GB video had ~152 MB on disk two
      // seconds after the tap, before AVPlayer had asked for a byte, because
      // the play opened with `downloadFile(offset: 0, limit: 0)`.
      const total = 1429876103;
      final api = V2File(sandbox, expectedSize: total);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);

      expect(api.lastCaller, DownloadCaller.player);
      expect(api.lastRange, isNotNull);
      expect(api.lastRange!.$1, 0);
      expect(api.lastRange!.$2, StreamWindow.firstBytes);
      expect(api.lastRange!.$2 / total, lessThan(0.02),
          reason: '首窗口必须是文件的一小片，不是整文件');

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('a preload asks for the head window at the lowest priority', () async {
      final api = V2File(sandbox, expectedSize: 512 * 1024 * 1024);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: V2Transport(),
        diagnostics: freshDiagnostics(),
      );

      final ok = await resolver.prefetch(11);

      expect(ok, isTrue);
      expect(api.prefetchCalls, 1);
      expect(api.lastCaller, DownloadCaller.preload);
      expect(api.lastRange, (0, StreamWindow.preloadBytes));
      // A neighbour the user may never open has no claim on a whole film.
      expect(StreamWindow.preloadBytes, lessThan(StreamWindow.firstBytes));
      await api.close();
    });

    test('V2 does not wait for the startup buffer V1 needs', () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        // V1 would sit on this gate for 2 MB; the file only ever has 64 KB.
        startupBufferBytes: 2 * 1024 * 1024,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver
          .resolveStreamV2(9)
          .timeout(const Duration(seconds: 5));

      expect(source.isResourceLoader, isTrue);
      expect(api.downloaded, lessThan(2 * 1024 * 1024),
          reason: 'V2 不得等 2 MB 才开始');
      expect(source.session!.watch.headBytes, greaterThan(0));

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('the session is opened with TDLib total, not the bytes on disk',
        () async {
      final api = V2File(sandbox, expectedSize: 700 * 1024 * 1024);
      await api.advance(20 * 1024 * 1024);
      final transport = V2Transport();
      final diagnostics = freshDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: diagnostics,
      );

      final source = await resolver.resolveStreamV2(9, mimeType: 'video/mp4');

      expect(transport.openedTotals.single, 700 * 1024 * 1024,
          reason: 'contentLength 必须是 TDLib 的 total');
      expect(transport.openedCompleted.single, isFalse,
          reason: '未下载完不得声明整段按需可用');
      expect(transport.openedGenerations.single, diagnostics.generation);

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('a platform without the bridge surfaces as V2 unavailable', () async {
      final api = V2File(sandbox);
      final transport = V2Transport(refuse: true);
      final diagnostics = freshDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: diagnostics,
      );

      await expectLater(
        resolver.resolveStreamV2(9),
        throwsA(isA<StreamingV2Unavailable>()),
      );
      expect(resolver.inflightCount, 0, reason: '失败不得留在在飞表里');
      expect(diagnostics.decisionReason, 'resource_loader_unavailable',
          reason: '落回 V1 的原因必须写清，不能显示成通用网络错误');

      await api.close();
      await transport.dispose();
    });

    test('disposing the source closes the native session', () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);
      final id = source.session!.sessionId;
      await source.dispose();

      expect(source.session!.isClosed, isTrue);
      expect(transport.closed, <String>[id]);
      expect(ResourceLoaderHost.instance.active, isNull,
          reason: '关闭后不得还能被 native 回调命中');

      await api.close();
      await transport.dispose();
    });
  });

  group('V2 and V1 isolation', () {
    test('the same file resolved on both transports keeps two futures',
        () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final diagnostics = freshDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        startupBufferBytes: 32 * 1024,
        diagnostics: diagnostics,
      );

      final v2 = resolver.resolveStreamV2(9);
      final v1 = resolver.resolveStream(9);
      final sources = await Future.wait(<Future<PlaySource>>[v2, v1]);

      expect(sources[0].isResourceLoader, isTrue);
      expect(sources[1].isResourceLoader, isFalse,
          reason: 'V1 必须仍然是 loopback HTTP');
      expect(Uri.parse(sources[0].url).scheme, kResourceLoaderScheme);
      expect(Uri.parse(sources[1].url).scheme, 'http');
      expect(sources[0].url, isNot(sources[1].url));

      await sources[0].dispose();
      await sources[1].dispose();
      await api.close();
      await transport.dispose();
    });

    test('preloading the file being watched does not touch its transfer',
        () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);
      final accepted = await resolver.prefetch(9);

      expect(accepted, isTrue, reason: '正在播放的文件不需要再预热');
      expect(api.prefetchCalls, 0,
          reason: '预加载不得给当前播放的文件发 downloadFile');

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('a prefetch for a neighbour never yields a playable source', () async {
      final api = V2File(sandbox);
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final accepted = await resolver.prefetch(31);

      expect(accepted, isTrue);
      expect(api.prefetchCalls, 1);
      expect(transport.opened, isEmpty,
          reason: '预加载不得创建 session，更不得创建播放器');

      await api.close();
      await transport.dispose();
    });
  });

  group('cache policy', () {
    test('a complete file is served from the local path, no loader', () async {
      final api = V2File(sandbox);
      await api.complete();
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);

      expect(source.kind, PlaySourceKind.file,
          reason: '完整缓存必须走本地文件这条最快路径');
      expect(source.path, api.path);
      expect(transport.opened, isEmpty);
      expect(api.downloadCalls, 0);

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('a complete file is still loadable when the run forces streaming',
        () async {
      final api = V2File(sandbox);
      await api.complete();
      final transport = V2Transport();
      final diagnostics = freshDiagnostics()..setForceStreamingTest(true);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: diagnostics,
      );

      final source = await resolver.resolveStreamV2(9);

      expect(source.isResourceLoader, isTrue,
          reason: 'FORCE_STREAMING_TEST 必须真的走 loader，否则验收测不到 V2');
      expect(diagnostics.decisionReason, 'complete_file_served_by_resource_loader');
      expect(transport.openedCompleted.single, isTrue,
          reason: '完整文件可以声明整段按需可用');

      await source.dispose();
      await api.close();
      await transport.dispose();
    });
  });

  // The 720 MB device report, reproduced at the resolver layer: TDLib says
  // 100%, the disk holds 64 KB. Streaming that would wait forever (nothing
  // more will ever be sent) and playing it would read holes. The only correct
  // action is a re-download, and the watch must not believe the claim either.
  group('a short file behind a complete record', () {
    test('is re-downloaded instead of being streamed as-is', () async {
      final api = V2File(sandbox, expectedSize: 8 * 1024 * 1024);
      await api.advance(64 * 1024);
      api.completed = true;              // TDLib: 100%
      api.downloaded = api.expectedSize; // and it says every byte is there
      final transport = V2Transport();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        nativeTransport: transport,
        diagnostics: freshDiagnostics(),
      );

      final source = await resolver.resolveStreamV2(9);

      expect(source.kind, PlaySourceKind.resourceLoader,
          reason: '短文件不是本地文件，但不完整也不是不可播');
      expect(api.cancelled, contains(9),
          reason: '声称完成却字节不足，必须取消并重下');
      expect(source.session!.watch.isComplete, isFalse,
          reason: '声明不能代替测量');

      await source.dispose();
      await api.close();
      await transport.dispose();
    });

    test('inspect measures the disk and calls the record short', () async {
      final api = V2File(sandbox, expectedSize: 8 * 1024 * 1024);
      await api.advance(64 * 1024);
      api.completed = true;
      api.downloaded = api.expectedSize;
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        diagnostics: freshDiagnostics(),
      );

      final facts = await resolver.inspect(9);

      expect(facts.claimedComplete, isTrue);
      expect(facts.diskSize, 64 * 1024);
      expect(facts.expectedBytes, 8 * 1024 * 1024);
      expect(facts.isPlayableFromDisk, isFalse);
      expect(facts.isShorterThanClaimed, isTrue);

      final decision = decideAfterTransportFailure(
        facts,
        failed: PlaybackSourceKind.resourceLoader,
        v2Supported: true,
      );
      expect(decision.source, PlaybackSourceKind.httpProxy,
          reason: '还没下载完，V2 失败后可以用 V1 再试一次');
      expect(decision.needsRedownload, isTrue);

      await api.close();
    });
  });
}
