/// Download manager: one task at a time, a cache hit that costs no request, a
/// completion that is verified before it is announced, and failures that are
/// reported instead of hanging.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/download/cache_validator.dart';
import 'package:tg_media_probe/download/download_manager.dart';
import 'package:tg_media_probe/download/download_state.dart';
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/platform/disk_space.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/fake_transport.dart';

void main() {
  late Directory dir;
  late StorageLayout layout;
  late FakeTdTransport transport;

  const int fileId = 4242;
  const int size = 4096;

  MediaRecord record({int id = fileId, int bytes = size}) => MediaRecord(
        chatId: 1,
        messageId: 7,
        fileId: id,
        kind: MediaKind.video,
        sizeBytes: bytes,
        messageDateUnix: 1790000000,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgmedia_dl_');
    layout = StorageLayout.forSandbox(dir.path);
    await layout.ensureCreated();
    transport = FakeTdTransport();
  });

  tearDown(() async {
    await transport.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  DownloadManager manager({
    int free = 10 * 1024 * 1024 * 1024,
    int maxStallRetries = 0,
    Duration stallTimeout = const Duration(seconds: 5),
    Duration poll = const Duration(milliseconds: 20),
  }) =>
      DownloadManager(
        transport: transport,
        validator: const CacheValidator(),
        cache: MediaCache(
          layout: layout,
          diskSpace: FixedDiskSpace(free),
        ),
        stallTimeout: stallTimeout,
        maxStallRetries: maxStallRetries,
        pollInterval: poll,
      );

  Future<String> realFile(int bytes) async {
    final file = File('${layout.tdlibFilesDir}/real.mp4');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 1));
    return file.path;
  }

  void answerGetFile({
    required int downloadedSize,
    required bool completed,
    required String path,
  }) {
    transport.handlers['getFile'] = (_) => FakeTdTransport.fileJson(
          fileId: fileId,
          downloadedSize: downloadedSize,
          size: size,
          completed: completed,
          path: path,
          downloadedPrefixSize: downloadedSize,
        );
  }

  /// Polls until [condition] holds, or fails the test after [timeout]. A test
  /// about a state transition must wait for the transition, not for a guessed
  /// number of milliseconds.
  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition was not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a verified local file needs no transfer at all', () async {
    final path = await realFile(size);
    answerGetFile(downloadedSize: size, completed: true, path: path);

    final outcome = await manager().ensureLocal(record());
    expect(outcome.isReady, isTrue);
    expect(outcome.path, path);
    expect(transport.countOf('downloadFile'), 0);
  });

  test('a completed download is verified before it is announced', () async {
    final path = await realFile(size);
    answerGetFile(downloadedSize: 0, completed: false, path: '');

    final dl = manager();
    final future = dl.ensureLocal(record());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(dl.state.phase, DownloadPhase.downloading);
    transport.emitUpdateFile(
      fileId: fileId,
      downloadedSize: size,
      size: size,
      completed: true,
      path: path,
    );

    final outcome = await future;
    expect(outcome.isReady, isTrue);
    expect(dl.state.phase, DownloadPhase.ready);
    expect(transport.countOf('downloadFile'), 1);
    expect(transport.requests.firstWhere((r) => r['@type'] == 'downloadFile')[
        'offset'], 0);
    expect(transport.countOf('deleteFile'), 0);
  });

  test('progress and measured speed are published while bytes move', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    final dl = manager();

    final future = dl.ensureLocal(record());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    transport.emitUpdateFile(
      fileId: fileId,
      downloadedSize: size ~/ 2,
      size: size,
      completed: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(dl.state.receivedBytes, size ~/ 2);
    expect(dl.state.progress, closeTo(0.5, 0.01));
    expect(dl.state.phase, DownloadPhase.downloading);

    await dl.cancel();
    await future;
  });

  test('a completed transfer with the wrong file size fails and is deleted',
      () async {
    final path = await realFile(size ~/ 2); // half the promised bytes
    answerGetFile(downloadedSize: 0, completed: false, path: '');

    final dl = manager();
    final future = dl.ensureLocal(record());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    transport.emitUpdateFile(
      fileId: fileId,
      downloadedSize: size,
      size: size,
      completed: true,
      path: path,
    );

    final outcome = await future;
    expect(outcome.isReady, isFalse);
    expect(outcome.failure, DownloadFailure.storage);
    expect(transport.countOf('deleteFile'), 1);
  });

  test('not enough disk space refuses before any transfer', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    final dl = manager(free: 1024);
    final outcome = await dl.ensureLocal(record());
    expect(outcome.failure, DownloadFailure.insufficientSpace);
    expect(transport.countOf('downloadFile'), 0);
    expect(dl.state.phase, DownloadPhase.checking);
  });

  test('a cancelled transfer never ends up ready', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    final dl = manager();
    final future = dl.ensureLocal(record());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await dl.cancel();

    final outcome = await future;
    expect(outcome.isReady, isFalse);
    expect(outcome.failure, DownloadFailure.cancelled);
    expect(transport.countOf('cancelDownloadFile'), 1);
  });

  test('a stalled transfer is reported, not awaited forever', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    final dl = manager(
      stallTimeout: const Duration(milliseconds: 40),
      poll: const Duration(milliseconds: 10),
    );
    final outcome = await dl.ensureLocal(record()).timeout(
          const Duration(seconds: 3),
        );
    expect(outcome.failure, DownloadFailure.network);
    expect(dl.state.phase, DownloadPhase.failed);
  });

  test('one stall is retried once, then the transfer restarts', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    // maxStallRetries is higher than the 1 stall this test provokes: the margin
    // keeps the assertion about "the first stall recovered" independent of how
    // long the machine takes, while the give-up path has its own test.
    final dl = manager(
      maxStallRetries: 3,
      stallTimeout: const Duration(milliseconds: 40),
      poll: const Duration(milliseconds: 10),
    );
    final future = dl.ensureLocal(record());
    await waitFor(() => transport.countOf('downloadFile') >= 2);
    expect(transport.countOf('cancelDownloadFile'), greaterThanOrEqualTo(1));

    final path = await realFile(size);
    transport.emitUpdateFile(
      fileId: fileId,
      downloadedSize: size,
      size: size,
      completed: true,
      path: path,
    );
    final outcome = await future;
    expect(outcome.isReady, isTrue);
  });

  test('a second video cancels the first: one transfer at a time', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    final dl = manager();

    final first = dl.ensureLocal(record(id: 1));
    await waitFor(() => dl.activeFileId == 1);

    final beforeSecond = transport.countOf('downloadFile');
    final second = dl.ensureLocal(record(id: 2));
    await waitFor(() => dl.activeFileId == 2);
    expect((await first).failure, DownloadFailure.cancelled);
    expect(transport.countOf('cancelDownloadFile'), greaterThanOrEqualTo(1));

    // Only the current video may be transferred: every downloadFile issued
    // after #2 took over targets #2, and there is exactly one of them.
    await waitFor(() => transport.countOf('downloadFile') > beforeSecond);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final issued = transport.requests
        .where((r) => r['@type'] == 'downloadFile')
        .map((r) => r['file_id'])
        .toList();
    expect(issued.sublist(beforeSecond), <Object?>[2]);

    await dl.cancel();
    expect((await second).failure, DownloadFailure.cancelled);
    // A cancelled run must not have queued anything behind it.
    expect(transport.requests.where((r) => r['@type'] == 'downloadFile').length,
        beforeSecond + 1);
  });

  test('a TDLib error on downloadFile is surfaced as a failure', () async {
    answerGetFile(downloadedSize: 0, completed: false, path: '');
    transport.failWith = 'FILE_REFERENCE_EXPIRED';
    final outcome = await manager().ensureLocal(record());
    expect(outcome.isReady, isFalse);
    expect(outcome.failure, DownloadFailure.network);
  });

  test('a record without a file id cannot be downloaded', () async {
    final outcome = await manager().ensureLocal(record(id: 0));
    expect(outcome.failure, DownloadFailure.notDownloadable);
    expect(transport.requests, isEmpty);
  });
}
