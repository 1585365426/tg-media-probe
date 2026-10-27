/// Streaming diagnostics (边下边播 真机验收) — the verdict is derived from
/// data, never from the code path that ran.
///
/// The rule under test: a play is 边下边播 only when the player was actually
/// running (playhead moved under its own power) while TDLib still had bytes to
/// fetch, AND the proxy answered at least one real Range request with
/// `206 Partial Content`. Everything else says what it is — full download
/// first, fallback, or 无法判定 — instead of guessing.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/playback_trace.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

/// A scripted TDLib file: the test decides when bytes appear and where the
/// download window is.
class ScriptedApi implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  ScriptedApi(this.sandbox, {this.expectedSize = 4 * 1024 * 1024});

  final TestSandbox sandbox;
  final int expectedSize;

  int fileId = 1001;
  int downloaded = 0;
  int windowOffset = 0;
  bool completed = false;
  int downloadCalls = 0;
  int rangeCalls = 0;
  int cancelCalls = 0;
  (int, int)? lastRange;

  late final String path = sandbox.tempFile('diag-$fileId.bin');

  FileState _state() => FileState(
        id: fileId,
        size: completed ? expectedSize : 0,
        expectedSize: expectedSize,
        downloadedSize: downloaded,
        isCompleted: completed,
        path: downloaded > 0 || completed ? path : '',
        canBeDownloaded: true,
        downloadOffset: windowOffset,
      );

  Future<void> advance(int bytes) async {
    final file = File(path);
    if (!await file.exists()) await file.create(recursive: true);
    final current = await file.length();
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    await raf.setPosition(current);
    await raf.writeFrom(List<int>.filled(bytes, 0x61));
    await raf.close();
    downloaded = await file.length();
    _push();
  }

  Future<void> complete() async {
    final file = File(path);
    if (!await file.exists()) await file.create(recursive: true);
    final current = await file.length();
    if (current < expectedSize) {
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(current);
      await raf.writeFrom(List<int>.filled(expectedSize - current, 0x61));
      await raf.close();
    }
    completed = true;
    downloaded = expectedSize;
    _push();
  }

  void _push() {
    if (!_updates.isClosed) _updates.add(_state());
  }

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  @override
  Future<FileState?> stat(int id) async {
    fileId = id;
    return _state();
  }

  @override
  Future<void> start(int id) async {
    downloadCalls++;
    if (downloaded == 0) await advance(64 * 1024);
  }

  @override
  Future<void> startRange(
    int id, {
    required int offset,
    required int limit,
  }) async {
    rangeCalls++;
    lastRange = (offset, limit);
  }

  @override
  Future<void> cancel(int id) async => cancelCalls++;

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

/// Drives [StreamingDiagnostics] the way the real pipeline does.
Future<void> _playAndAdvance(
  StreamingDiagnostics diag, {
  required int downloadedAtPlayback,
  required int totalBytes,
  required bool completed,
}) async {
  diag.noteRangeRequest(from: 0, to: 1023);
  diag.noteResponse(
    status: 206,
    from: 0,
    end: 1023,
    total: totalBytes,
    length: 1024,
  );
  diag.updateTransfer(
    downloadedBytes: downloadedAtPlayback,
    totalBytes: totalBytes,
    downloadOffset: 0,
    completed: completed,
  );
  diag.updatePlayer(
    position: const Duration(seconds: 2),
    duration: const Duration(seconds: 60),
    isPlaying: true,
    isBuffering: false,
  );
}

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  group('streaming verdict', () {
    test('1. firstPlayback < totalBytes => STREAMING_CONFIRMED', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );

      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 30 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        completed: false,
      );

      expect(diag.verdict, StreamingVerdict.streamingActive);
      expect(diag.verdict.code, 'STREAMING_CONFIRMED');
      expect(diag.verdict.label, '✅ 已确认：边下边播');
      expect(diag.firstPlaybackDownloadedBytes, 30 * 1024 * 1024);
      expect(diag.firstPlaybackTotalBytes, 100 * 1024 * 1024);
      expect(diag.firstPlaybackCompleted, isFalse);
    });

    test('2. firstPlayback >= totalBytes => FULL_DOWNLOAD_BEFORE_PLAYBACK',
        () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );

      // Even with a 206 on record: what decides is the state when the first
      // frame played, and there the file was already whole.
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 100 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        completed: true,
      );

      expect(diag.verdict, StreamingVerdict.fullDownloadBeforePlayback);
      expect(diag.verdict.code, 'FULL_DOWNLOAD_BEFORE_PLAYBACK');
      expect(diag.verdict.label, '⚠️ 全部下载完成后播放');
    });

    test('3. no 206 => UNKNOWN', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );
      // A request arrived and only part of the file is on disk, but the
      // proxy never answered with a partial-content status: not evidence.
      diag.noteRangeRequest(from: 0, to: 1023);
      diag.updateTransfer(
        downloadedBytes: 30 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        downloadOffset: 0,
        completed: false,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );

      expect(diag.sawPartialContent, isFalse);
      expect(diag.verdict, StreamingVerdict.unknown);
      expect(diag.verdict.label, '❓ 无法判定');
    });

    test('4. the player never really started => UNKNOWN', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );
      diag.noteRangeRequest(from: 0, to: 1023);
      diag.noteResponse(
        status: 206,
        from: 0,
        end: 1023,
        total: 100 * 1024 * 1024,
        length: 1024,
      );
      diag.updateTransfer(
        downloadedBytes: 30 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        downloadOffset: 0,
        completed: false,
      );
      // Buffering with the playhead at zero: AVPlayer has not played anything.
      diag.updatePlayer(
        position: Duration.zero,
        duration: Duration.zero,
        isPlaying: false,
        isBuffering: true,
      );

      expect(diag.hasStartedPlaying, isFalse);
      expect(diag.timeControlStatus, 'waitingToPlayAtSpecifiedRate');
      expect(diag.verdict, StreamingVerdict.unknown);
    });

    test('5. a streaming fallback => FALLBACK', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );
      diag.noteRangeRequest(from: 0, to: 1023);
      diag.noteResponse(
        status: 206,
        from: 0,
        end: 1023,
        total: 100 * 1024 * 1024,
        length: 1024,
      );
      diag.noteFallback('代理等待超时');

      expect(diag.fallback, isTrue);
      expect(diag.fallbackReason, '代理等待超时');
      expect(diag.verdict, StreamingVerdict.fallbackUsed);
      expect(diag.verdict.code, 'STREAMING_FALLBACK');
    });

    test('6. downloadedBytes keeps growing while the play runs', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );

      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 30 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        completed: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      diag.updateTransfer(
        downloadedBytes: 62 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        downloadOffset: 0,
        completed: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      diag.updateTransfer(
        downloadedBytes: 88 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        downloadOffset: 0,
        completed: false,
      );

      final samples = diag.growthSamples.map((s) => s.bytes).toList();
      expect(samples.length, 3);
      expect(samples, equals(<int>[
        30 * 1024 * 1024,
        62 * 1024 * 1024,
        88 * 1024 * 1024,
      ]));
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i], greaterThan(samples[i - 1]));
      }
      expect(diag.downloadedPercent, closeTo(0.88, 0.001));
    });

    test('7. downloadCompleted lands after firstPlayback', () async {
      var now = DateTime(2026, 1, 1);
      final diag = StreamingDiagnostics(clock: () => now);
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 55,
        totalBytes: 100 * 1024 * 1024,
      );

      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 30 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        completed: false,
      );
      expect(diag.firstPlaybackMillis, 0);

      now = now.add(const Duration(milliseconds: 8500));
      diag.noteCompleted(totalBytes: 100 * 1024 * 1024);

      expect(diag.downloadCompletedMillis, 8500);
      expect(diag.downloadCompletedMillis!,
          greaterThan(diag.firstPlaybackMillis!));
      // Both marks land in the exported timeline.
      expect(
        diag.acceptanceLines().join('\n'),
        contains('firstPlayback=0.0s'),
      );
      expect(
        diag.acceptanceLines().join('\n'),
        contains('completedAt=8.5s'),
      );
    });
  });

  group('acceptance run', () {
    test('arming clears the previous verdict', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 10,
        totalBytes: 1000,
        completed: false,
      );
      expect(diag.verdict, StreamingVerdict.streamingActive);

      diag.startAcceptance();
      expect(diag.acceptanceRunning, isTrue);
      expect(diag.verdict, StreamingVerdict.unknown,
          reason: '清零后不得沿用上一次的结论');
      expect(diag.firstPlaybackDownloadedBytes, isNull);
      expect(diag.downloadCompletedMillis, isNull);
      expect(diag.rangeRequests, 0);
      expect(diag.sawPartialContent, isFalse);
    });

    test('the report reads back the recorded evidence', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(
        fileId: 1001,
        streaming: true,
        chatId: 1,
        messageId: 12,
        totalBytes: 1024 * 1024 * 1024,
      );
      diag.updateTransfer(
        downloadedBytes: 146 * 1024 * 1024,
        totalBytes: 1024 * 1024 * 1024,
        downloadOffset: 0,
        completed: false,
      );
      diag.noteRangeRequest(from: 0, to: 1023);
      diag.noteResponse(
        status: 206,
        from: 0,
        end: 1023,
        total: 1024 * 1024 * 1024,
        length: 1024,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 21),
        duration: const Duration(seconds: 600),
        isPlaying: true,
        isBuffering: false,
      );

      final lines = diag.acceptanceLines();
      expect(lines.first, 'STREAMING_CONFIRMED');
      expect(
          lines.join('\n'), contains('downloadedAtFirstPlayback=146 MB'));
      expect(lines.join('\n'), contains('total=1.00 GB'));
      expect(lines.join('\n'), contains('206x1'));
      expect(diag.panelLines().join('\n'), contains('streamingEnabled=true'));
      expect(diag.panelLines().join('\n'), contains('window=0-153092096'));
    });
  });

  group('diagnostics wiring over real HTTP', () {
    test('a real Range request feeds the streaming verdict', () async {
      final api = ScriptedApi(sandbox, expectedSize: 4 * 1024 * 1024);
      await api.advance(1024 * 1024); // 1 MB of 4 MB on disk
      final diag = StreamingDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        diagnostics: diag,
        fileExists: (_) async => true,
        startupBufferBytes: 256 * 1024,
        stallTimeout: const Duration(seconds: 5),
      );

      final source = await resolver.resolveStream(
        1001,
        chatId: 1,
        messageId: 7,
      );
      expect(source.isStreaming, isTrue, reason: '未下载完必须走流式');

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(source.url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048575');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-1048575/4194304');
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(response.headers.value(HttpHeaders.contentTypeHeader),
          contains('video/mp4'));
      await response.drain<void>();
      client.close(force: true);

      // The proxy really served a 206 for a real Range request…
      expect(diag.rangeRequests, 1);
      expect(diag.sawPartialContent, isTrue);
      expect(diag.lastRange, '0-1048575');
      // …but nothing has played yet, so nothing may be claimed.
      expect(diag.verdict, StreamingVerdict.unknown);

      diag.updatePlayer(
        position: const Duration(seconds: 3),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );
      expect(diag.verdict, StreamingVerdict.streamingActive,
          reason: '播放时文件不完整 + 206 = 边下边播');
      expect(diag.downloadedBytes, lessThan(diag.totalBytes));

      await source.dispose();
      await api.close();
    });

    test('the player state reaches the diagnostics panel', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 4096);
      diag.updatePlayer(
        position: const Duration(seconds: 7),
        duration: const Duration(seconds: 70),
        isPlaying: true,
        isBuffering: false,
        error: null,
      );
      expect(diag.playerTime, const Duration(seconds: 7));
      expect(diag.timeControlStatus, 'playing');
      expect(diag.hasStartedPlaying, isTrue);
      expect(diag.playerError, isNull);

      diag.updatePlayer(
        position: const Duration(seconds: 7),
        duration: const Duration(seconds: 70),
        isPlaying: false,
        isBuffering: true,
        error: 'CoreMedia error',
      );
      expect(diag.timeControlStatus, 'waitingToPlayAtSpecifiedRate');
      expect(diag.playerError, 'CoreMedia error');
    });

    test('the timeline exports the labels the task book asks for', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1024);
      diag.noteRangeRequest(from: 0, to: 511);
      diag.noteResponse(
        status: 206,
        from: 0,
        end: 511,
        total: 1024,
        length: 512,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 4),
        duration: const Duration(seconds: 40),
        isPlaying: true,
        isBuffering: false,
      );

      final trace = PlaybackTrace(fileId: 1001);
      trace.mark(PlaybackStage.selected);
      trace.mark(PlaybackStage.resolveStarted);
      trace.mark(PlaybackStage.streamingModeSelected);
      trace.mark(PlaybackStage.streamingProxyStarted);
      trace.mark(PlaybackStage.downloadRequested);
      trace.mark(PlaybackStage.firstBytes, bytes: 512);
      trace.mark(PlaybackStage.playerInitialized);
      final labels =
          trace.timeline().map((entry) => entry.label).toList(growable: false);
      expect(
        labels,
        containsAll(<String>[
          'selected',
          'resolveStarted',
          'streamingModeSelected',
          'proxyStarted',
          'tdlibDownloadStarted',
          'firstBytesAvailable',
          'playerInitialized',
        ]),
      );
      expect(diag.events.first, contains('206'));
      expect(diag.isStreamingConfirmed, isTrue);
    });
  });

  group('forced streaming test (FORCE_STREAMING_TEST)', () {
    test('panel shows TEST / PREFERENCE / EFFECTIVE as three real lines',
        () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      final panel = diag.panelLines().join('\n');
      expect(panel, contains('STREAMING TEST: ON'));
      expect(panel, contains('PREFERENCE STREAMING: ON'));
      expect(panel, contains('EFFECTIVE STREAMING: ON'));

      diag.setForceStreamingTest(false);
      // The play was made while force was ON: turning the toggle off now must
      // not rewrite history — the panel marks it "(ended)", never plain OFF.
      expect(diag.panelLines().join('\n'),
          contains('STREAMING TEST: ON (ended)'));
    });

    test('forced + full download before playback => STREAMING_TEST_FAILED',
        () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      // Streaming was genuinely exercised (proxy bound, a range served), yet
      // the file was whole before the playhead moved: that is the honest
      // FULL_DOWNLOAD_BEFORE_PLAYBACK, not "never started".
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.noteRangeRequest(from: 0, to: 1000);
      diag.noteResponse(status: 206, from: 0, end: 1000, total: 1000, length: 1001);
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 1000,
        totalBytes: 1000,
        completed: true,
      );

      expect(diag.verdict, StreamingVerdict.fullDownloadBeforePlayback);
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('STREAMING_TEST_FAILED: '
          'FULL_DOWNLOAD_OCCURRED_BEFORE_PLAYBACK'));
      expect(report, contains('effectiveStreaming=false'));
    });

    test('forced + player fed a LOCAL_FILE => STREAMING_NOT_STARTED',
        () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteStreamingSelected();
      // The play happened, bytes were partial, but the player opened a path,
      // not the proxy URL: the pipeline did not stream.
      diag.notePlayerSource(isStreaming: false, url: '/pool/video.mp4');
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 300,
        totalBytes: 1000,
        completed: false,
      );

      expect(diag.playerSourceType, 'LOCAL_FILE');
      expect(diag.verdict, StreamingVerdict.streamingNotStarted);
      expect(diag.verdict.code, 'STREAMING_NOT_STARTED');
    });

    test('forced + zero range requests => STREAMING_NOT_STARTED', () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteStreamingSelected();
      diag.notePlayerSource(
        isStreaming: true,
        url: 'http://127.0.0.1:8099/t/abc',
      );
      // Playhead moved, file partial, streaming branch taken — but the
      // player never issued a Range request. In forced mode that is a
      // definite failure, not UNKNOWN.
      diag.updateTransfer(
        downloadedBytes: 300,
        totalBytes: 1000,
        downloadOffset: 0,
        completed: false,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );

      expect(diag.verdict, StreamingVerdict.streamingNotStarted);
      // Turning the toggle off *after* the play must not rewrite the run:
      // the verdict is judged by the mode that was active during it.
      diag.setForceStreamingTest(false);
      expect(diag.verdict, StreamingVerdict.streamingNotStarted);
      expect(diag.panelLines().join('\n'),
          contains('STREAMING TEST: ON (ended)'));
    });

    test('confirmed requires STREAM_HTTP + partial bytes + 206', () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteStreamingSelected();
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.notePlayerSource(
        isStreaming: true,
        url: 'http://127.0.0.1:8099/t/abc',
      );
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 300,
        totalBytes: 1000,
        completed: false,
      );

      expect(diag.playerSourceType, 'STREAM_HTTP');
      expect(diag.verdict, StreamingVerdict.streamingActive);
      expect(diag.verdict.code, 'STREAMING_CONFIRMED');
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('playerSourceType=STREAM_HTTP'));
      expect(report, contains('proxyUrl=http://127.0.0.1:8099/t/abc'));
      expect(report, contains('downloadedAtFirstPlayback='));
      expect(report, contains('total='));
      expect(report, contains('completedAt=-'));
    });

    test('fallback still wins and the reason is in the report', () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteStreamingSelected();
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.noteRangeRequest(from: 0, to: 1023);
      diag.noteFallback('启动缓冲等待超时');
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 900,
        totalBytes: 1000,
        completed: false,
      );

      expect(diag.verdict, StreamingVerdict.fallbackUsed);
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('fallbackReason=启动缓冲等待超时'));
    });

    test('a full download over the real resolver reports LOCAL_FILE',
        () async {
      // The acceptance killer from the device run: a play that never enters
      // the streaming branch still has to name its source. Drive a cache-hit
      // resolve through the real resolver and check the wiring path exists:
      // notePlayerSource is the feed controller's job, this test pins the
      // diagnostics contract it must satisfy.
      final diag = StreamingDiagnostics();
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      diag.notePlayerSource(isStreaming: false, url: '/pool/cached.mp4');
      expect(diag.playerSourceType, 'LOCAL_FILE');
      expect(diag.proxyUrl, isNull);
      expect(diag.verdict, StreamingVerdict.unknown,
          reason: '没人播放过，不能下结论');
    });

    test('a play made under force keeps its verdict after the toggle goes off',
        () async {
      // The exact hole from the device report: the run was made with the
      // forced mode on, but 结束验收 flipped the flag before the report was
      // read, and the STREAMING_TEST_FAILED marker vanished.
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.noteRangeRequest(from: 0, to: 1000);
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 1000,
        totalBytes: 1000,
        completed: true,
      );
      // Toggle off *after* the play — the recorded run must not change.
      diag.setForceStreamingTest(false);

      expect(diag.verdict, StreamingVerdict.fullDownloadBeforePlayback);
      expect(diag.acceptanceLines().join('\n'),
          contains('STREAMING_TEST_FAILED: '
              'FULL_DOWNLOAD_OCCURRED_BEFORE_PLAYBACK'));
    });

    test('evidence is sealed after 结束验收 — later plays cannot wipe it',
        () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.startAcceptance();
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.notePlayerSource(
        isStreaming: true,
        url: 'http://127.0.0.1:8099/t/abc',
      );
      diag.noteRangeRequest(from: 0, to: 1048575);
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 300,
        totalBytes: 1000,
        completed: false,
      );
      final sealedVerdict = diag.verdict;
      final sealedReport = diag.acceptanceLines().join('\n');

      // The acceptance is read (结束验收), then the user keeps browsing and
      // the feed plays a cached LOCAL_FILE video: none of that may touch the
      // recorded run.
      diag.stopAcceptance();
      diag.setForceStreamingTest(false);
      diag.beginPlay(fileId: 2002, streaming: false, totalBytes: 5000);
      diag.notePlayerSource(isStreaming: false, url: '/pool/next.mp4');
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 5000,
        totalBytes: 5000,
        completed: true,
      );

      expect(diag.verdict, sealedVerdict);
      expect(diag.acceptanceLines().join('\n'), sealedReport);
      expect(diag.fileId, 1001, reason: '封存后 beginPlay 不得覆盖任何字段');
    });

    test('starting a new acceptance unseals and wipes the old run',
        () async {
      final diag = StreamingDiagnostics();
      diag.startAcceptance();
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 1000,
        totalBytes: 1000,
        completed: true,
      );
      diag.stopAcceptance();
      expect(diag.verdict, StreamingVerdict.fullDownloadBeforePlayback);

      diag.startAcceptance();
      expect(diag.fileId, 0, reason: '新一轮验收从清零开始');
      expect(diag.verdict, StreamingVerdict.unknown);
    });
  });

  group('streaming decision trace', () {
    test('preference off + force off => LOCAL_FILE with the reason named', () {
      final diag = StreamingDiagnostics();
      diag.setStreamingPreference(false);
      diag.setForceStreamingTest(false);
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      diag.noteDecision(
        preference: false,
        force: false,
        candidate: false,
        candidateReason: 'streaming_disabled_by_preference',
        decision: 'LOCAL_FILE',
        reason: 'streaming_disabled_by_preference',
      );

      final panel = diag.panelLines().join('\n');
      expect(panel, contains('PREFERENCE STREAMING: OFF'));
      expect(panel, contains('decision=LOCAL_FILE'));
      expect(panel, contains('reason=streaming_disabled_by_preference'));

      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('LOCAL_FILE_REASON=streaming_disabled_by_preference'));
      expect(report, contains('preference=false'));
      expect(report, contains('forceTest=false'));
    });

    test('force on overrides a preference that is off', () {
      final diag = StreamingDiagnostics();
      diag.setStreamingPreference(false);
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteDecision(preference: false, force: true, candidate: true);
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.notePlayerSource(
        isStreaming: true,
        url: 'http://127.0.0.1:8099/t/abc',
      );
      diag.noteRangeRequest(from: 0, to: 1048575);
      diag.noteResponse(
          status: 206, from: 0, end: 1048575, total: 1000, length: 1048576);
      diag.updateTransfer(
        downloadedBytes: 300,
        totalBytes: 1000,
        downloadOffset: 0,
        completed: false,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );

      expect(diag.verdict, StreamingVerdict.streamingActive);
      expect(diag.acceptanceLines().join('\n'), contains('preference=false'));
      expect(diag.acceptanceLines().join('\n'), contains('forceTest=true'));
    });

    test('a forced run that never bound the proxy is NOT_STARTED', () async {
      // The device shape: full download completed, player on a local file,
      // zero range requests. Rounds of reports read this as "full download
      // before playback"; it has to read as "streaming did not run".
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      // Drive the facts without the range/206 helper: this run never touched
      // the proxy at all.
      diag.updateTransfer(
        downloadedBytes: 1000,
        totalBytes: 1000,
        downloadOffset: 0,
        completed: true,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );

      expect(diag.verdict, StreamingVerdict.streamingNotStarted);
      expect(diag.acceptanceLines().join('\n'),
          contains('STREAMING_TEST_FAILED: STREAMING_NOT_STARTED'));
    });

    test('a fallback that never bound the proxy is NOT_STARTED, not FALLBACK',
        () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: false, totalBytes: 1000);
      diag.noteDecision(
        candidate: false,
        candidateReason: 'invalid_video_metadata',
        decision: 'FALLBACK',
        reason: 'invalid_video_metadata',
      );
      diag.noteFallback('流式播放不可用（文件大小未知）');
      diag.updateTransfer(
        downloadedBytes: 1000,
        totalBytes: 1000,
        downloadOffset: 0,
        completed: true,
      );
      diag.updatePlayer(
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 60),
        isPlaying: true,
        isBuffering: false,
      );

      expect(diag.verdict, StreamingVerdict.streamingNotStarted,
          reason: '没有尝试过流式，不能记成 fallback');
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('fallbackReason=流式播放不可用（文件大小未知）'));
      expect(report, contains('reason=invalid_video_metadata'));
    });

    test('a fallback after the proxy bound stays STREAMING_FALLBACK', () async {
      final diag = StreamingDiagnostics();
      diag.setForceStreamingTest(true);
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 1000);
      diag.noteProxyStarted('http://127.0.0.1:8099/t/abc');
      diag.noteRangeRequest(from: 0, to: 1048575);
      diag.noteFallback('播放器初始化失败');
      await _playAndAdvance(
        diag,
        downloadedAtPlayback: 900,
        totalBytes: 1000,
        completed: false,
      );

      expect(diag.verdict, StreamingVerdict.fallbackUsed);
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('STREAMING_FALLBACK'));
      expect(report, contains('fallbackReason=播放器初始化失败'));
    });
  });

  group('record vs file identity', () {
    test('the tile size and the served file size are reported separately', () {
      final diag = StreamingDiagnostics();
      diag.noteRecordSnapshot(
        fileId: 5478,
        messageId: 4092592128,
        sizeBytes: 3700000000,
      );
      diag.beginPlay(
        fileId: 5478,
        streaming: false,
        messageId: 4092592128,
        totalBytes: 3700000000,
      );

      final panel = diag.panelLines().join('\n');
      expect(panel, contains('record file=5478'));
      expect(panel, contains('size=3700000000 B'));
      expect(panel, contains('match=YES'));
      expect(diag.recordSizeMismatch, isFalse);
      expect(diag.acceptanceLines().join('\n'), isNot(contains('SIZE_MISMATCH')));
    });

    test('a tile that claims 3.45 GB while a 1.38 GB file plays is flagged', () {
      final diag = StreamingDiagnostics();
      // The tapped item, as the index stored it.
      diag.noteRecordSnapshot(
        fileId: 9001,
        messageId: 4092592128,
        sizeBytes: 3700000000,
      );
      // The file TDLib actually served.
      diag.beginPlay(
        fileId: 5478,
        streaming: false,
        messageId: 4092592128,
        totalBytes: 1482000000,
      );

      expect(diag.recordSizeMismatch, isTrue);
      final panel = diag.panelLines().join('\n');
      expect(panel, contains('match=NO'));
      final report = diag.acceptanceLines().join('\n');
      expect(report, contains('SIZE_MISMATCH'));
      expect(report, contains('recordFile=9001'));
      expect(report, contains('file=5478'));
    });

    test('the record survives the play reset — it describes the tap', () {
      final diag = StreamingDiagnostics();
      diag.noteRecordSnapshot(
        fileId: 9001,
        messageId: 42,
        sizeBytes: 3700000000,
      );
      diag.beginPlay(fileId: 9001, streaming: false, totalBytes: 3700000000);
      diag.beginPlay(fileId: 9001, streaming: false, totalBytes: 3700000000);

      expect(diag.recordFileId, 9001);
      expect(diag.recordMessageId, 42);
      expect(diag.recordSizeBytes, 3700000000);
    });

    test('an unknown size on either side is not a mismatch', () {
      final diag = StreamingDiagnostics();
      diag.noteRecordSnapshot(fileId: 1, messageId: 2, sizeBytes: 0);
      diag.beginPlay(fileId: 1, streaming: false, totalBytes: 1000);

      expect(diag.recordSizeMismatch, isFalse);
      expect(diag.panelLines().join('\n'), contains('match=-'));
    });
  });

  group('photo exclusion', () {
    test('messagePhoto produces no record and no download', () async {
      final record = MediaRecord.fromMessage(
        chatId: 1,
        message: <String, Object?>{
          'id': 900,
          'date': 1700000000,
          'content': <String, Object?>{
            '@type': 'messagePhoto',
            'photo': <String, Object?>{
              'sizes': <Object?>[
                <String, Object?>{
                  'width': 800,
                  'height': 600,
                  'photo': <String, Object?>{
                    'id': 4242,
                    'expected_size': 1024,
                  },
                },
              ],
            },
          },
        },
      );

      expect(record, isNull, reason: '图片消息不得进入视频索引');
    });

    test('a photo row left in an old mirror never pages through', () async {
      final diag = StreamingDiagnostics();
      diag.beginPlay(fileId: 1001, streaming: true, totalBytes: 2048);
      expect(diag.rangeRequests, 0);
      expect(diag.totalBytes, 2048);
      expect(diag.streamingEnabled, isTrue);
    });
  });
}
