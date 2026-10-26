import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
import 'package:tg_media_probe/storage/file_ops.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

/// Counts `realPath` calls.
///
/// This is the measurable form of the "清理缓存没反应" report: the old clear loop
/// resolved four zone roots (each a `realpath` walk) for *every* file, so a pool
/// with thousands of blobs spent tens of thousands of filesystem calls before
/// deleting anything, and the UI sat there looking dead.
class _CountingOps extends IoFileOps {
  int realPathCalls = 0;

  @override
  Future<String> realPath(String path) {
    realPathCalls++;
    return super.realPath(path);
  }
}

/// A file that cannot be stat'ed (vanished between list and stat, broken link).
class _BadStatOps extends IoFileOps {
  _BadStatOps(this.badName);

  final String badName;
  int skipped = 0;

  @override
  Future<int> sizeOf(String path) async {
    if (p.basename(path) == badName) {
      skipped++;
      throw const FileSystemException('simulated stat failure');
    }
    return super.sizeOf(path);
  }
}

void main() {
  late TestSandbox sandbox;
  late ActiveFileRegistry active;

  setUp(() async {
    sandbox = await TestSandbox.create();
    active = ActiveFileRegistry();
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

  group('scan survives a single bad file', () {
    test('a stat failure does not abort the whole scan', () async {
      await sandbox.writeBytes(sandbox.tempFile('ok1.jpg'), 10);
      await sandbox.writeBytes(sandbox.tempFile('bad.jpg'), 20);
      await sandbox.writeBytes(sandbox.tempFile('ok2.jpg'), 30);

      final ops = _BadStatOps('bad.jpg');
      final scan = await manager(ops: ops).scan();

      expect(ops.skipped, 1);
      // The two healthy files are still reported; the old code threw out of
      // scan() here and left the settings tile on "正在统计…" forever.
      expect(scan.fileCount, 2);
      expect(scan.totalBytes, 40);
    });
  });

  group('containment checks stay cheap', () {
    test('roots are resolved once, not once per zone per file', () async {
      const fileCount = 20;
      for (var i = 0; i < fileCount; i++) {
        await sandbox.writeBytes(sandbox.tempFile('f$i.jpg'), 64);
      }
      // The layout must own the counting ops as well: `canonical()` goes
      // through `layout.ops`, so a counting wrapper on the manager alone would
      // miss every `realpath` the containment checks make.
      final ops = _CountingOps();
      final layout = StorageLayout.forSandbox(sandbox.root.path, ops: ops);
      final report = await CacheManager(
        layout: layout,
        ops: ops,
        activeFiles: active,
      ).clear(userConfirmed: true);

      expect(report.deletedFiles, fileCount);
      // Four roots once, four scan directories once, one per file at delete
      // time. Anything close to fileCount * 5 means the regression is back.
      expect(
        ops.realPathCalls,
        lessThanOrEqualTo(fileCount + 12),
        reason: 'clear() resolved zone roots per file '
            '(${ops.realPathCalls} realpath calls for $fileCount files)',
      );
    });

    test('the temp zone root itself is never a delete candidate', () async {
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(sandbox.layout.tempRoot),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('a protected zone path is refused with the pre-resolved roots',
        () async {
      final roots = await sandbox.layout.resolveRoots();
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(
          sandbox.downloadFile('keep.mp4'),
          roots: roots,
        ),
        throwsA(isA<ZoneViolation>()),
      );
    });
  });

  group('progress', () {
    test('reports monotonic counters from 0 to total', () async {
      for (var i = 0; i < 5; i++) {
        await sandbox.writeBytes(sandbox.tempFile('p$i.jpg'), 100);
      }
      final seen = <CacheClearProgress>[];
      final report = await manager().clear(
        userConfirmed: true,
        onProgress: seen.add,
      );

      expect(report.deletedFiles, 5);
      expect(seen, isNotEmpty);
      expect(seen.first.done, 0);
      expect(seen.last.done, 5);
      expect(seen.last.total, 5);
      expect(seen.last.freedBytes, 500);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].done, greaterThanOrEqualTo(seen[i - 1].done));
        expect(seen[i].freedBytes,
            greaterThanOrEqualTo(seen[i - 1].freedBytes));
      }
    });

    test('counts in-use files as handled so the bar can reach 100%', () async {
      final busy = sandbox.tempFile('busy.mp4', kind: CacheKindName.player);
      await sandbox.writeBytes(busy, 50);
      await sandbox.writeBytes(sandbox.tempFile('free.jpg'), 50);
      active.markInUse(busy);

      final seen = <CacheClearProgress>[];
      final report = await manager().clear(
        userConfirmed: true,
        onProgress: seen.add,
      );
      expect(report.deletedFiles, 1);
      expect(seen.last.done, 2);
      expect(seen.last.total, 2);
    });
  });

  group('integrity probe failures', () {
    test('a throwing probe is reported but does not abort the clear', () async {
      await sandbox.writeBytes(sandbox.tempFile('x.jpg'), 128);
      final report = await manager(
        probe: () async => throw StateError('journal unreadable'),
      ).clear(userConfirmed: true);

      // The delete still happened ...
      expect(report.deletedFiles, 1);
      expect(report.freedBytes, 128);
      // ... and the unverifiable integrity check is surfaced, not hidden.
      expect(report.integrityProbeError, isTrue);
      expect(report.summary, contains('完整性校验未执行'));
      expect(await sandbox.exists(sandbox.tempFile('x.jpg')), isFalse);
    });

    test('a healthy probe still reports preserved', () async {
      await sandbox.writeBytes(sandbox.tempFile('y.jpg'), 8);
      final report =
          await manager(probe: () async => {'index': 3}).clear(userConfirmed: true);
      expect(report.integrityProbeError, isFalse);
      expect(report.integrityPreserved, isTrue);
      expect(report.succeeded, isTrue);
    });
  });

  group('report bookkeeping', () {
    test('records what the scan saw, so the UI can show before and after',
        () async {
      await sandbox.writeBytes(sandbox.tempFile('a.jpg'), 10);
      await sandbox.writeBytes(sandbox.tempFile('b.jpg'), 20);
      final report = await manager().clear(userConfirmed: true);
      expect(report.scannedFiles, 2);
      expect(report.scannedBytes, 30);
      expect(report.nothingToDo, isFalse);
    });

    test('an empty cache reports nothingToDo instead of a fake success',
        () async {
      final report = await manager().clear(userConfirmed: true);
      expect(report.scannedFiles, 0);
      expect(report.nothingToDo, isTrue);
      expect(report.deletedFiles, 0);
    });
  });
}
