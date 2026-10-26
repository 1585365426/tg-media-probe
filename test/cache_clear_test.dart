import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
import 'package:tg_media_probe/storage/file_ops.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

/// Stands in for a file the OS refuses to delete (open handle, permission).
class _FailingDeleteOps extends IoFileOps {
  _FailingDeleteOps(this.failingPath);

  final String failingPath;

  @override
  Future<void> deleteFile(String path) async {
    if (p.equals(path, failingPath)) {
      throw const FileSystemException('simulated permission denied');
    }
    return super.deleteFile(path);
  }
}

/// Simulates the worst-case bug: something in the clear path touches the
/// download directory. The manager must detect it and refuse to report success.
class _SabotageOps extends IoFileOps {
  _SabotageOps(this.downloadsRoot);

  final String downloadsRoot;

  @override
  Future<void> deleteFile(String path) async {
    await super.deleteFile(path);
    final dir = Directory(downloadsRoot);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

void main() {
  late TestSandbox sandbox;
  late ActiveFileRegistry active;

  setUp(() async {
    sandbox = await TestSandbox.create();
    active = ActiveFileRegistry();
    // Protected data that must survive every cache operation.
    await sandbox.writeBytes(sandbox.downloadFile('keep.mp4'), 300);
    await sandbox.write(sandbox.indexFile('media_journal.jsonl'), '{"op":"m"}');
    await sandbox.write(sandbox.authFile('session.json'), '{"session":"x"}');
    // Rebuildable cache.
    await sandbox.writeBytes(sandbox.tempFile('a.jpg'), 100);
    await sandbox.writeBytes(
        sandbox.tempFile('b.mp4', kind: CacheKindName.player), 200);
    await sandbox.writeBytes(
        sandbox.tempFile('c.part', kind: CacheKindName.partial), 50);
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  CacheManager manager({FileOps? ops, Future<Map<String, int>> Function()? probe}) =>
      CacheManager(
        layout: sandbox.layout,
        ops: ops ?? sandbox.ops,
        activeFiles: active,
        integrityProbe: probe,
      );

  group('scan', () {
    test('counts the three cache kinds and nothing else', () async {
      final scan = await manager().scan();
      expect(scan.fileCount, 3);
      expect(scan.totalBytes, 350);
      expect(scan.bytesOf(CacheKind.thumbnail), 100);
      expect(scan.bytesOf(CacheKind.playbackTemp), 200);
      expect(scan.bytesOf(CacheKind.partialDownload), 50);
    });

    test('never walks the download, index or auth zones', () async {
      final scan = await manager().scan();
      for (final entry in scan.entries) {
        expect(p.isWithin(sandbox.layout.tempRoot, entry.path), isTrue,
            reason: 'scan reached ${entry.path}');
      }
    });

    test('reports in-use files as not reclaimable', () async {
      active.markInUse(sandbox.tempFile('b.mp4', kind: CacheKindName.player));
      final scan = await manager().scan();
      expect(scan.inUseCount, 1);
      expect(scan.inUseBytes, 200);
      expect(scan.reclaimableBytes, 150);
    });
  });

  group('tdlib blob pool', () {
    // The settings screen used to read 0 B forever: every video the app had
    // ever played sat in `Library/Caches/tgmedia/tdlib_files`, which the scan
    // did not walk. These two tests pin that directory down.
    setUp(() async {
      await sandbox.ops.createDirectory(sandbox.layout.tdlibFilesDir);
      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, 'aa', 'bb', 'blob_1'), 4096);
      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, 'blob_2'), 1024);
    });

    test('is scanned, so the total is not a permanent zero', () async {
      final scan = await manager().scan();
      expect(scan.bytesOf(CacheKind.tdlibBlobPool), 5120);
      expect(scan.totalBytes, 350 + 5120);
      expect(scan.fileCount, 5);
    });

    test('is cleared, and the TDLib database in the auth zone survives',
        () async {
      final dbFile = p.join(sandbox.layout.tdlibDatabaseDir, 'td.binlog');
      await sandbox.ops.createDirectory(sandbox.layout.tdlibDatabaseDir);
      await sandbox.write(dbFile, 'binlog');

      final report = await manager().clear(userConfirmed: true);
      expect(report.freedByKind[CacheKind.tdlibBlobPool], 5120);
      expect(
        await sandbox.exists(p.join(sandbox.layout.tdlibFilesDir, 'blob_2')),
        isFalse,
      );
      // The log-in session and the message mirror must not be touched.
      expect(await sandbox.exists(dbFile), isTrue);
      expect(await sandbox.exists(sandbox.authFile('session.json')), isTrue);
      expect(await sandbox.exists(sandbox.downloadFile('keep.mp4')), isTrue);
      // The directory is recreated empty so the next run has the same layout.
      expect(await sandbox.ops.exists(sandbox.layout.tdlibFilesDir), isTrue);
    });
  });

  group('clear', () {
    test('refuses to run without explicit confirmation', () async {
      await expectLater(
        manager().clear(userConfirmed: false),
        throwsA(isA<CacheClearNotConfirmed>()),
      );
      expect(await sandbox.exists(sandbox.tempFile('a.jpg')), isTrue);
      expect(await sandbox.exists(sandbox.downloadFile('keep.mp4')), isTrue);
    });

    test('deletes temp cache only and keeps every protected file', () async {
      final report = await manager().clear(userConfirmed: true);
      expect(report.deletedFiles, 3);
      expect(report.freedBytes, 350);
      expect(report.failures, isEmpty);
      expect(report.succeeded, isTrue);
      expect(report.summary, contains('删除 3 个文件'));

      expect(await sandbox.exists(sandbox.tempFile('a.jpg')), isFalse);
      expect(
          await sandbox.exists(sandbox.tempFile('b.mp4', kind: CacheKindName.player)),
          isFalse);
      expect(
          await sandbox.exists(sandbox.tempFile('c.part', kind: CacheKindName.partial)),
          isFalse);

      // Protected data untouched.
      expect(await sandbox.exists(sandbox.downloadFile('keep.mp4')), isTrue);
      expect(await sandbox.exists(sandbox.indexFile('media_journal.jsonl')), isTrue);
      expect(await sandbox.exists(sandbox.authFile('session.json')), isTrue);
    });

    test('keeps a second cache run a no-op', () async {
      await manager().clear(userConfirmed: true);
      final second = await manager().clear(userConfirmed: true);
      expect(second.deletedFiles, 0);
      expect(second.freedBytes, 0);
      expect(second.succeeded, isTrue);
    });

    test('skips a file that is being played', () async {
      final playing = sandbox.tempFile('b.mp4', kind: CacheKindName.player);
      active.markInUse(playing, reason: 'player');
      final report = await manager().clear(userConfirmed: true);
      expect(report.deletedFiles, 2);
      expect(report.freedBytes, 150);
      expect(report.skippedInUse, contains(playing));
      expect(await sandbox.exists(playing), isTrue);
      expect(report.succeeded, isTrue);
    });

    test('reports a real delete failure instead of counting it as freed', () async {
      final failing = sandbox.tempFile('a.jpg');
      final report = await manager(ops: _FailingDeleteOps(failing))
          .clear(userConfirmed: true);

      expect(report.failures, hasLength(1));
      expect(report.failures.first.path, failing);
      expect(report.freedBytes, 250);
      expect(report.deletedFiles, 2);
      expect(report.succeeded, isFalse);
      expect(report.summary, contains('失败 1 个'));
    });

    test('detects protected-zone damage and fails the run', () async {
      final report = await manager(ops: _SabotageOps(sandbox.layout.downloadsRoot))
          .clear(userConfirmed: true);
      expect(report.protectedZonesIntact, isFalse);
      expect(report.succeeded, isFalse);
      expect(report.summary, contains('受保护目录异常'));
    });

    test('detects an integrity regression', () async {
      var rows = 10;
      final report = await manager(probe: () async => {'index': rows})
          .clear(userConfirmed: true);
      expect(report.integrityPreserved, isTrue);
      expect(report.succeeded, isTrue);

      // Now pretend the index lost rows during a clear.
      final broken = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: active,
        integrityProbe: () async {
          final snapshot = {'index': rows};
          rows--;
          return snapshot;
        },
      );
      final second = await broken.clear(userConfirmed: true);
      expect(second.integrityPreserved, isFalse);
      expect(second.succeeded, isFalse);
    });
  });

  group('usage', () {
    test('measures temp and leaves protected zones unmeasured by default', () async {
      final usage = await manager().usage();
      expect(usage[StorageZone.tempCache], 350);
      expect(usage[StorageZone.userDownloads], -1);
      expect(usage[StorageZone.indexDb], -1);
      expect(usage[StorageZone.authMeta], -1);
    });

    test('can report protected sizes when explicitly asked', () async {
      final usage = await manager().usage(includeProtected: true);
      expect(usage[StorageZone.userDownloads], 300);
      expect(usage[StorageZone.indexDb], greaterThan(0));
    });
  });

  test('confirmation copy matches the implemented behaviour', () {
    expect(cacheClearConfirmationText, contains('不会删除'));
    expect(cacheClearConfirmationText, contains('收藏'));
    expect(cacheClearConfirmationText, contains('媒体索引'));
    expect(cacheClearConfirmationText, contains('下载文件'));
    expect(cacheClearConfirmationText, contains('云端媒体'));
  });
}
