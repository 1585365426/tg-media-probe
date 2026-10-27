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
        contains('completion=8.5s'),
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
      expect(lines.join('\n'), contains('downloaded=146 MB / 1.00 GB'));
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
