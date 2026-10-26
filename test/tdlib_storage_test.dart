
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

/// Ties the TDLib on-disk layout to the four storage zones.
///
/// Two directories matter and they are deliberately in different zones:
/// * the database (`authRoot/tdlib/db`) is the local session — losing it means
///   signing in again, so cache clearing must never reach it;
/// * the file pool (`tempRoot/tdlib_files`) is rebuildable — clearing it costs
///   bandwidth, not data.
/// Nothing wrote this down in a test until now; the two paths were only kept
/// apart by convention inside `storage_layout.dart`.
void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  group('TDLib paths and the storage zones', () {
    test('the database sits in the protected auth zone', () async {
      final layout = sandbox.layout;
      expect(await layout.zoneOf(layout.tdlibDatabaseDir), StorageZone.authMeta);
      expect(p.isWithin(layout.authRoot, layout.tdlibDatabaseDir), isTrue);
      await expectLater(
        layout.assertDeletableByCacheClear(layout.tdlibDatabaseDir),
        throwsA(isA<ZoneViolation>()),
        reason: 'deleting the TDLib database logs the user out',
      );
    });

    test('the file pool sits in the rebuildable temp zone', () async {
      final layout = sandbox.layout;
      expect(await layout.zoneOf(layout.tdlibFilesDir), StorageZone.tempCache);
      expect(p.isWithin(layout.tempRoot, layout.tdlibFilesDir), isTrue);
      await expectLater(
        layout.assertDeletableByCacheClear(
            p.join(layout.tdlibFilesDir, 'abc123.MP4')),
        completes,
        reason: 'the pool only costs bandwidth to rebuild',
      );
    });

    test('the two directories are not inside each other', () {
      final layout = sandbox.layout;
      expect(p.isWithin(layout.tdlibDatabaseDir, layout.tdlibFilesDir), isFalse);
      expect(p.isWithin(layout.tdlibFilesDir, layout.tdlibDatabaseDir), isFalse);
      expect(p.equals(layout.tdlibDatabaseDir, layout.tdlibFilesDir), isFalse);
    });
  });

  group('clearing the cache with a real TDLib layout', () {
    late String binlog;
    late String dbFile;
    late String poolFile;

    setUp(() async {
      final layout = sandbox.layout;
      binlog = p.join(layout.tdlibDatabaseDir, 'td.binlog');
      dbFile = p.join(layout.tdlibDatabaseDir, 'db.sqlite');
      poolFile = p.join(layout.tdlibFilesDir, '4357.MP4');
      await sandbox.write(binlog, 'binlog-bytes');
      await sandbox.write(dbFile, 'sqlite-bytes');
      await sandbox.writeBytes(poolFile, 4096);
      await sandbox.writeBytes(sandbox.tempFile('thumb.jpg'), 512);
    });

    test('clearing the cache never touches the TDLib pool', () async {
      final manager = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: ActiveFileRegistry(),
      );

      final report = await manager.clear(userConfirmed: true);

      // Database and session metadata untouched, byte for byte.
      expect(await sandbox.ops.exists(binlog), isTrue);
      expect(await sandbox.ops.exists(dbFile), isTrue);
      expect(await sandbox.ops.readAsString(binlog), 'binlog-bytes');
      expect(await sandbox.ops.readAsString(dbFile), 'sqlite-bytes');

      // The pool file survives too — on purpose. This layer may not call
      // TDLib's deleteFile (a source-scan test forbids the storage layer from
      // reaching TDLib at all), and deleting behind TDLib's back leaves its
      // file database claiming a file that is no longer there. Reclaiming the
      // pool needs a TDLib-aware step; tracked in STEP4-ACCEPTANCE-GAP-REPORT.
      expect(await sandbox.ops.exists(poolFile), isTrue);

      // Only the thumbnail was actually removed: 512 bytes, nothing else.
      expect(await sandbox.ops.exists(sandbox.tempFile('thumb.jpg')), isFalse);
      expect(report.freedBytes, 512);
      expect(report.protectedZonesIntact, isTrue);
      expect(report.succeeded, isTrue);
    });

    test('the pool is outside the scan, so its size is never advertised '
        'as reclaimable', () async {
      final manager = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: ActiveFileRegistry(),
      );

      final scan = await manager.scan();

      expect(
        scan.entries.any((e) => e.path.contains('tdlib_files')),
        isFalse,
        reason: 'scanning the pool would promise a reclaim the clear step '
            'does not perform',
      );
      expect(scan.entries, isNotEmpty);
    });

    test('an in-use thumbnail is skipped and its bytes not counted', () async {
      final thumb = sandbox.tempFile('thumb.jpg');
      final active = ActiveFileRegistry();
      active.markInUse(thumb, reason: 'player');
      final manager = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: active,
      );

      final report = await manager.clear(userConfirmed: true);

      expect(await sandbox.ops.exists(thumb), isTrue);
      expect(report.skippedInUse, isNotEmpty);
      expect(report.freedBytes, 0);

      active.release(thumb);
    });

    test('clearing twice does not double-count bytes', () async {
      final manager = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: ActiveFileRegistry(),
      );

      final first = await manager.clear(userConfirmed: true);
      final second = await manager.clear(userConfirmed: true);

      expect(first.freedBytes, greaterThan(0));
      expect(second.freedBytes, 0);
      expect(second.deletedFiles, 0);
    });
  });

  group('the session survives a cache clear', () {
    test('the binlog path is derived from the auth zone, not temp', () async {
      final path = p.join(sandbox.layout.tdlibDatabaseDir, 'td.binlog');
      expect(await sandbox.layout.zoneOf(path), StorageZone.authMeta);
      await expectLater(sandbox.layout.assertDeletableByCacheClear(path),
          throwsA(isA<ZoneViolation>()));
    });

    test('a traverse from temp into the database is refused', () async {
      final escape = p.join(
        sandbox.layout.tempRoot,
        '..',
        '..',
        '..',
        'Application Support',
        'tgmedia',
        'secure',
        'tdlib',
        'db',
        'td.binlog',
      );
      await expectLater(sandbox.layout.assertDeletableByCacheClear(escape),
          throwsA(isA<ZoneViolation>()));
    });
  });
}
