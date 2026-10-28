/// First-play timing: what the stages are, and that a complete local file is
/// reused without touching TDLib again.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/playback_trace.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

class _Api implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  _Api({
    this.completedSize,
    this.expectedSize = 1000,
    this.startCompletes = true,
    this.failStart = false,
    this.partialBytes,
  });

  /// When set, `stat` reports a completed file of this size.
  final int? completedSize;
  final int expectedSize;
  final bool startCompletes;
  final bool failStart;

  /// When set, `start` emits one non-final update with this many bytes and then
  /// goes quiet — a transfer that is running but making no progress.
  final int? partialBytes;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  int statCalls = 0;
  int startCalls = 0;
  final List<int> startedIds = <int>[];

  @override
  Future<FileState?> stat(int fileId) async {
    statCalls++;
    final size = completedSize;
    return FileState(
      id: fileId,
      size: size ?? 0,
      expectedSize: expectedSize,
      downloadedSize: size ?? 0,
      isCompleted: size != null,
      path: size != null ? '/pool/$fileId' : '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    startCalls++;
    startedIds.add(fileId);
    if (failStart) throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    final partial = partialBytes;
    if (partial != null) {
      _updates.add(FileState(
        id: fileId,
        size: 0,
        expectedSize: expectedSize,
        downloadedSize: partial,
        isCompleted: false,
        path: '',
        canBeDownloaded: true,
      ));
    }
    if (!startCompletes) return;
    _updates.add(FileState(
      id: fileId,
      size: expectedSize,
      expectedSize: expectedSize,
      downloadedSize: expectedSize,
      isCompleted: true,
      path: '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  int cancelCalls = 0;

  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {}
  @override
  Future<void> cancel(int fileId) async => cancelCalls++;

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

void main() {
  group('trace', () {
    test('measures each stage and the total', () {
      var now = DateTime.utc(2026, 10, 27, 0, 0, 0);
      final trace = PlaybackTrace(fileId: 7, chatId: 1, messageId: 99,
          clock: () => now);

      trace.mark(PlaybackStage.selected);
      now = now.add(const Duration(milliseconds: 120));
      trace.mark(PlaybackStage.resolveStarted);
      now = now.add(const Duration(milliseconds: 80));
      trace.mark(PlaybackStage.fileReady, bytes: 1000);
      now = now.add(const Duration(milliseconds: 300));
      trace.mark(PlaybackStage.playerInitialized);

      expect(trace.between(PlaybackStage.selected, PlaybackStage.resolveStarted),
          120);
      expect(trace.between(PlaybackStage.resolveStarted, PlaybackStage.fileReady),
          80);
      expect(
          trace.between(PlaybackStage.fileReady, PlaybackStage.playerInitialized),
          300);
      expect(trace.between(PlaybackStage.selected, PlaybackStage.firstFrame),
          isNull, reason: 'first frame was never reached');
    });

    test('a repeated mark keeps the first arrival time', () {
      var now = DateTime.utc(2026, 10, 27);
      final trace = PlaybackTrace(fileId: 1, clock: () => now);
      trace.mark(PlaybackStage.fileReady);
      final first = trace.marks[PlaybackStage.fileReady];
      now = now.add(const Duration(seconds: 5));

      trace.mark(PlaybackStage.fileReady);

      expect(trace.marks[PlaybackStage.fileReady], first);
    });

    test('the summary carries ids and durations, never a path or a secret', () {
      final trace = PlaybackTrace(fileId: 42, chatId: 5, messageId: 600);
      trace.mark(PlaybackStage.selected);
      trace.mark(PlaybackStage.fileReady);
      trace.expectedBytes = 5809108;
      trace.errorCategory = 'timeout';

      final line = trace.summary();

      expect(line, contains('file=42'));
      expect(line, contains('chat=5'));
      expect(line, contains('total='));
      expect(line, contains('expected=5809108B'));
      expect(line, contains('error=timeout'));
      // No container paths, no credentials, no message text.
      expect(line.contains('/private/var'), isFalse);
      expect(line.contains('api_hash'), isFalse);
      expect(line.toLowerCase().contains('token'), isFalse);
      expect(RegExp(r'\+?\d{11,}').hasMatch(line), isFalse);
    });

    test('the log is bounded', () {
      final log = PlaybackTraceLog(capacity: 3);
      for (var i = 0; i < 5; i++) {
        log.add(PlaybackTrace(fileId: i));
      }

      expect(log.entries, hasLength(3));
      expect(log.entries.first.fileId, 2);
      expect(log.diagnosticLines().first, contains('3 max'));
    });
  });

  group('a complete local file is reused', () {
    test('no downloadFile is sent and the trace shows a cache hit', () async {
      final api = _Api(completedSize: 1000);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);
      final trace = PlaybackTrace(fileId: 1);

      final path = await resolver.resolve(1, trace: trace);

      expect(path, '/pool/1');
      expect(api.startCalls, 0, reason: '完整文件不得再请求一次媒体');
      expect(api.statCalls, 1);
      expect(trace.has(PlaybackStage.downloadRequested), isFalse);
      expect(trace.has(PlaybackStage.fileReady), isTrue);
      await api.close();
    });

    test('a record marked complete but truncated is not a cache hit', () async {
      // TDLib can report completion for a record whose bytes are gone or short.
      final api = _Api(completedSize: 400, expectedSize: 1000);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      await resolver.resolve(1);

      expect(api.startCalls, 1,
          reason: 'a short file must be fetched again, not trusted');
      await api.close();
    });
  });

  group('one transfer per file, even with two callers', () {
    test('concurrent resolves share a single downloadFile', () async {
      final api = _Api();
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      final results = await Future.wait(<Future<String>>[
        resolver.resolve(9),
        resolver.resolve(9),
        resolver.resolve(9),
      ]);

      expect(results, everyElement('/pool/9'));
      expect(api.startCalls, 1);
      await api.close();
    });

    test(
        'a second resolve after completion starts a new transfer only when '
        'the file is gone', () async {
      final api = _Api(completedSize: 1000);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => false);

      await expectLater(
        resolver.resolve(3),
        throwsA(isA<VideoSourceException>().having(
          (e) => e.message,
          'message',
          contains('已不存在'),
        )),
      );

      expect(api.startCalls, 1,
          reason: 'stat says done, disk says gone: refetch, then report');
      await api.close();
    });
  });

  group('waiting ends with a specific reason', () {
    test('a quiet transfer says nothing arrived instead of a generic timeout',
        () async {
      final api = _Api(startCompletes: false);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        stallTimeout: const Duration(milliseconds: 30),
      );
      final trace = PlaybackTrace(fileId: 4)..expectedBytes = 1000;

      await expectLater(
        resolver.resolve(4, trace: trace),
        throwsA(isA<VideoSourceStalled>().having(
          (e) => e.message,
          'message',
          contains('仍未收到任何数据'),
        )),
      );
      // "stalled" and "taskTimeout" must stay distinguishable: only the first
      // one is a network verdict, and the feed maps them to different screens.
      expect(trace.errorCategory, 'stalled');
      expect(api.cancelCalls, 1, reason: '超时后必须停掉不再需要的传输');
      await api.close();
    });

    test('a stall after partial progress reports the bytes, not just the limit',
        () async {
      final api = _Api(startCompletes: false, partialBytes: 400);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        stallTimeout: const Duration(milliseconds: 40),
      );
      final trace = PlaybackTrace(fileId: 4)..expectedBytes = 1000;

      await expectLater(
        resolver.resolve(4, trace: trace),
        throwsA(isA<VideoSourceStalled>().having(
          (e) => e.message,
          'message',
          allOf(contains('已下载'), contains('40%')),
        )),
      );
      expect(trace.errorCategory, 'stalled');
      await api.close();
    });

    test('a TDLib error carries its category', () async {
      final api = _Api(failStart: true);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);
      final trace = PlaybackTrace(fileId: 5);

      await expectLater(
        resolver.resolve(5, trace: trace),
        throwsA(isA<VideoSourceException>()),
      );
      expect(trace.errorCategory, isNotNull);
      await api.close();
    });
  });
}
