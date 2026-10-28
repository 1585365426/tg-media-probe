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

  final FileState? statState;

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
}
