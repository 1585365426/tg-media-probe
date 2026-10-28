/// The Downloader's two jobs that a device report caught it doing wrong:
///
/// 1. sending `downloadFile` for a file that is already whole on disk (which
///    also flips TDLib's `is_downloading_completed` back to false), and
/// 2. leaving a job `running` after TDLib refused it.
///
/// Both are invisible on screen and both change what the panel says, so they
/// are tested here rather than through a play.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/downloader.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

class _Recorder implements FileTransferApi {
  _Recorder({this.statState});

  FileState? statState;

  /// Pushes one `updateFile` into the watchdog's observer.
  void emit(FileState state) => _updates.add(state);

  final List<int> started = <int>[];
  final List<DownloadCaller> callers = <DownloadCaller>[];
  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  bool throwOnStart = false;

  @override
  Future<FileState?> stat(int fileId) async => statState;

  @override
  Future<void> start(
    int fileId, {
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  }) async {
    started.add(fileId);
    callers.add(caller);
    if (throwOnStart) throw StateError('FILE_ID_INVALID');
  }

  @override
  Future<void> cancel(int fileId) async {}

  @override
  Stream<FileState> updates() => _updates.stream;

  @override
  Future<void> startRange(
    int fileId, {
    required int offset,
    required int limit,
    int priority = 16,
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  }) async {
    throw StateError('the downloader must never send a window');
  }

  // `implements` does not inherit the interface's default body, so this has to
  // be spelled out even though nothing here prefetches.
  @override
  Future<void> prefetch(int fileId) async {
    throw StateError('the downloader must never prefetch');
  }

  Future<void> close() => _updates.close();
}

/// A transfer still in progress: not complete, and reporting a reach.
FileState _live({
  int id = 5626,
  int downloaded = 0,
  int offset = 0,
  int expected = 0,
}) =>
    FileState(
      id: id,
      size: downloaded,
      expectedSize: expected,
      downloadedSize: downloaded,
      downloadOffset: offset,
      path: '/pool/$id.mp4',
      isCompleted: false,
      canBeDownloaded: true,
    );

FileState _state({required int size, required String path}) => FileState(
      id: 5626,
      size: size,
      expectedSize: size,
      downloadedSize: size,
      downloadOffset: 0,
      path: path,
      isCompleted: true,
      canBeDownloaded: false,
    );

void main() {
  test('a file already whole on disk needs no downloadFile at all', () async {
    final api = _Recorder(statState: _state(size: 162308586, path: '/pool/5626.mp4'));
    final audit = DownloadAudit();
    final downloader = TelegramMediaDownloader(api: api, audit: audit);
    downloader.diskSizeOf = (_) async => 162308586;

    final job = await downloader.ensureFullDownload(
      chatId: -1002273572608,
      messageId: 9435086848,
      fileId: 5626,
      expectedSize: 162308586,
    );

    expect(job.state, FullDownloadState.completed);
    expect(job.shortcut, 'already_on_disk');
    expect(job.isRunning, isFalse);
    // The point: nothing was asked of TDLib, so nothing re-opened the file.
    expect(api.started, isEmpty);
    expect(audit.count, 0);
    expect(downloader.isRunning(5626), isFalse);
    await api.close();
  });

  test('a short file still gets the whole-file request, from the Downloader',
      () async {
    final api = _Recorder(statState: _state(size: 162308586, path: '/pool/5626.mp4'));
    final audit = DownloadAudit();
    final downloader = TelegramMediaDownloader(
      api: api,
      audit: audit,
      freeBytes: () async => 1024 * 1024 * 1024,
    );
    downloader.diskSizeOf = (_) async => 1000;

    final job = await downloader.ensureFullDownload(
      chatId: -100,
      messageId: 9,
      fileId: 5626,
      expectedSize: 162308586,
    );

    expect(job.state, FullDownloadState.running);
    expect(job.shortcut, isNull);
    expect(api.started, <int>[5626]);
    // The one legal whole-file caller, named at the call site.
    expect(api.callers.single, DownloadCaller.downloader);
    expect(audit.wholeFileRevokedBy, isNull);
    await api.close();
  });

  test('an unknown expected size cannot prove the file is whole', () async {
    final api = _Recorder(statState: _state(size: 0, path: '/pool/5626.mp4'));
    final downloader = TelegramMediaDownloader(api: api, audit: DownloadAudit());
    downloader.diskSizeOf = (_) async => 4096;

    final job = await downloader.ensureFullDownload(
      chatId: -100,
      messageId: 9,
      fileId: 5626,
      expectedSize: 0,
    );

    expect(job.state, FullDownloadState.running);
    expect(api.started, <int>[5626]);
    await api.close();
  });

  test('disk refusal never reaches TDLib, and says why', () async {
    final api = _Recorder(statState: _state(size: 162308586, path: '/pool/5626.mp4'));
    final audit = DownloadAudit();
    final downloader = TelegramMediaDownloader(
      api: api,
      audit: audit,
      freeBytes: () async => 1024,
    );
    downloader.diskSizeOf = (_) async => 0;

    final job = await downloader.ensureFullDownload(
      chatId: -100,
      messageId: 9,
      fileId: 5626,
      expectedSize: 162308586,
    );

    expect(job.state, FullDownloadState.diskFull);
    expect(api.started, isEmpty);
    expect(audit.violations.single, contains('DISK_FULL'));
    await api.close();
  });

  test('a refused start leaves no job running', () async {
    final api = _Recorder(statState: _state(size: 4096, path: '/pool/1.mp4'))
      ..throwOnStart = true;
    final downloader = TelegramMediaDownloader(api: api, audit: DownloadAudit());
    downloader.diskSizeOf = (_) async => 0;

    await expectLater(
      downloader.ensureFullDownload(
        chatId: -100,
        messageId: 9,
        fileId: 5626,
        expectedSize: 4096,
      ),
      throwsA(isA<StateError>()),
    );

    expect(downloader.isRunning(5626), isFalse);
    expect(downloader.jobFor(5626)!.state, FullDownloadState.failed);
    await api.close();
  });

  group('stall watchdog', () {
    TelegramMediaDownloader build(
      _Recorder api,
      DownloadAudit audit, {
      int maxRestarts = 3,
    }) =>
        TelegramMediaDownloader(
          api: api,
          audit: audit,
          freeBytes: () async => 2 * 1024 * 1024 * 1024,
          // Short enough for a test, same shape as the device values.
          stallWindow: const Duration(milliseconds: 40),
          stallPoll: const Duration(milliseconds: 10),
          maxStallRestarts: maxRestarts,
        );

    test('a transfer that stops writing is cancelled and re-issued', () async {
      // The device shape: `downloaded=524288 / 638 MB`, 0.1 %, and TDLib never
      // writes another byte. The job said `running` forever, so every layer
      // above it waited forever and the report had nothing to print.
      final api = _Recorder(
        statState: _live(downloaded: 524288, expected: 638582784),
      );
      final audit = DownloadAudit();
      final downloader = build(api, audit);
      downloader.diskSizeOf = (_) async => 524288;

      final job = await downloader.ensureFullDownload(
        chatId: -100,
        messageId: 9,
        fileId: 5626,
        expectedSize: 638582784,
      );
      expect(job.state, FullDownloadState.running);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(api.started.length, greaterThan(1),
          reason: '停滞的传输必须被重新发起，否则永远不会有新字节');
      expect(audit.notes.where((n) => n.startsWith('DOWNLOAD_STALL ')),
          isNotEmpty);
      expect(downloader.jobFor(5626)!.state, FullDownloadState.running);
      downloader.dispose();
      await api.close();
    });

    test('after the restart budget the job fails and says why', () async {
      final api = _Recorder(
        statState: _live(downloaded: 524288, expected: 638582784),
      );
      final audit = DownloadAudit();
      final downloader = build(api, audit, maxRestarts: 1);
      downloader.diskSizeOf = (_) async => 524288;

      await downloader.ensureFullDownload(
        chatId: -100,
        messageId: 9,
        fileId: 5626,
        expectedSize: 638582784,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final job = downloader.jobFor(5626)!;
      expect(job.state, FullDownloadState.failed);
      expect(job.failureReason, contains('停滞'));
      expect(downloader.isRunning(5626), isFalse,
          reason: '放弃之后不能再报 running，否则上层会继续等');
      expect(audit.notes.where((n) => n.startsWith('DOWNLOAD_STALLED ')),
          isNotEmpty);
      downloader.dispose();
      await api.close();
    });

    test('a transfer that keeps writing is never restarted', () async {
      final api = _Recorder(
        statState: _live(downloaded: 0, expected: 638582784),
      );
      final audit = DownloadAudit();
      final downloader = build(api, audit);
      downloader.diskSizeOf = (_) async => 0;

      await downloader.ensureFullDownload(
        chatId: -100,
        messageId: 9,
        fileId: 5626,
        expectedSize: 638582784,
      );

      var bytes = 0;
      for (var i = 0; i < 20; i++) {
        bytes += 262144;
        api.emit(_live(downloaded: bytes, expected: 638582784));
        api.statState = _live(downloaded: bytes, expected: 638582784);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(api.started.length, 1, reason: '有进展的传输不能被重启');
      expect(audit.notes, isEmpty);
      downloader.dispose();
      await api.close();
    });
  });
}
