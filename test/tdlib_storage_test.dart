import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

/// Ties the TDLib on-disk layout to the storage zones.
///
/// Two directories matter and they are deliberately kept apart:
/// * the database (`authRoot/tdlib/db`) is the local session — losing it means
///   signing in again, so no cache operation may reach it;
/// * the file pool (`mediaRoot/tdlib`) is the player's source of bytes. It sits
///   beside the index under Application Support, **not** in `Library/Caches`,
///   because iOS may purge Caches at any time and "downloaded once, plays
///   offline" is the product promise.
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

    test('the file pool lives beside the index, outside the purgeable cache',
        () async {
      final layout = sandbox.layout;
      expect(p.isWithin(layout.mediaRoot, layout.tdlibFilesDir), isTrue);
      expect(p.isWithin(layout.tempRoot, layout.tdlibFilesDir), isFalse,
          reason: 'Library/Caches is purgeable; the pool must survive it');
      // Outside every managed zone means no cache path can reach it by zone.
      expect(await layout.zoneOf(layout.tdlibFilesDir), isNull);
    });

    test('the two directories are not inside each other', () {
      final layout = sandbox.layout;
      expect(p.isWithin(layout.tdlibDatabaseDir, layout.tdlibFilesDir), isFalse);
      expect(p.isWithin(layout.tdlibFilesDir, layout.tdlibDatabaseDir), isFalse);
      expect(p.equals(layout.tdlibDatabaseDir, layout.tdlibFilesDir), isFalse);
    });
  });

  group('clearing local media with a real TDLib layout', () {
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
      await sandbox.writeBytes(p.join(layout.mediaRoot, 'tdlib', 'x.mp4'), 512);
    });

    MediaCache cache() =>
        MediaCache(layout: sandbox.layout, ops: sandbox.ops);

    test('clearing local media never touches the TDLib database', () async {
      final wipe = await cache().clearLocal();

      // Session metadata untouched, byte for byte.
      expect(await sandbox.ops.exists(binlog), isTrue);
      expect(await sandbox.ops.exists(dbFile), isTrue);
      expect(await sandbox.ops.readAsString(binlog), 'binlog-bytes');
      expect(await sandbox.ops.readAsString(dbFile), 'sqlite-bytes');
      expect(wipe.errors, isEmpty);
    });

    test('the pool is the local media cache, so it is cleared', () async {
      final used = await cache().usedBytes();
      expect(used, 4096 + 512);

      final wipe = await cache().clearLocal();

      expect(await sandbox.ops.exists(poolFile), isFalse);
      expect(wipe.deletedFiles, 2);
      expect(wipe.freedBytes, 4096 + 512);
      expect(await cache().usedBytes(), 0);
    });

    test('the file the player has open survives its own cache clear', () async {
      final wipe = await cache().clearLocal(keep: <String>{poolFile});

      expect(await sandbox.ops.exists(poolFile), isTrue);
      expect(wipe.skipped, <String>[poolFile]);
      expect(wipe.deletedFiles, 1);
      expect(wipe.freedBytes, 512);
    });

    test('clearing twice does not double-count bytes', () async {
      final first = await cache().clearLocal();
      final second = await cache().clearLocal();

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
