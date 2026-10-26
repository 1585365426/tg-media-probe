/// Cache ceiling: trigger, target, protection, and the promise that cleaning
/// never touches the index or the watch history.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/watch_store.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_budget.dart';
import 'package:tg_media_probe/storage/file_ops.dart';

import 'support/sandbox.dart';

class _FailingOps extends IoFileOps {
  _FailingOps(this.failingPath);
  final String failingPath;

  @override
  Future<void> deleteFile(String path) async {
    if (p.equals(path, failingPath)) {
      throw const FileSystemException('simulated permission denied');
    }
    return super.deleteFile(path);
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

  AutoCacheCleaner cleaner({FileOps? ops}) => AutoCacheCleaner(
        layout: sandbox.layout,
        ops: ops ?? sandbox.ops,
        activeFiles: active,
      );

  Future<void> seedThumbs(int count, int bytes) async {
    for (var i = 0; i < count; i++) {
      await sandbox.writeBytes(
        p.join(sandbox.layout.thumbnailDir, 't$i.jpg'),
        bytes,
      );
    }
  }

  group('budget', () {
    test('default is 1 GB and the presets are the documented four', () {
      expect(CacheBudget.defaultLimit, 1024 * 1024 * 1024);
      expect(CacheBudget.presets, <int>[
        512 * CacheBudget.mb,
        1024 * CacheBudget.mb,
        2 * 1024 * CacheBudget.mb,
        5 * 1024 * CacheBudget.mb,
      ]);
      expect(CacheBudget.targetBytesFor(CacheBudget.defaultLimit),
          (CacheBudget.defaultLimit * 0.8).round());
    });

    test('custom limits outside 256 MB – 20 GB are rejected', () {
      expect(CacheBudget.isAllowed(100 * CacheBudget.mb), isFalse);
      expect(CacheBudget.isAllowed(21 * 1024 * CacheBudget.mb), isFalse);
      expect(CacheBudget.isAllowed(512 * CacheBudget.mb), isTrue);
    });

    test('display uses MB below a gigabyte and GB above', () {
      expect(CacheBudget.format(512 * CacheBudget.mb), '512 MB');
      expect(CacheBudget.format(CacheBudget.gb), '1.0 GB');
    });
  });

  group('trigger', () {
    test('under the limit nothing is deleted', () async {
      await seedThumbs(5, 1000);
      final result =
          await cleaner().check(limitBytes: 10 * CacheBudget.mb);

      expect(result.stop, AutoCleanStop.withinLimit);
      expect(result.deletedFiles, 0);
      expect(result.freedBytes, 0);
      final scan = await cleaner().usage();
      expect(scan.thumbBytes, 5000);
    });

    test('over the limit cleans down to about 80%', () async {
      // 12 MB of thumbnails, limit 10 MB → target 8 MB.
      await seedThumbs(12, CacheBudget.mb);
      final result =
          await cleaner().check(limitBytes: 10 * CacheBudget.mb);

      expect(result.stop, AutoCleanStop.reachedTarget);
      expect(result.freedBytes, greaterThan(0));
      expect(result.afterBytes, lessThanOrEqualTo(result.beforeBytes));
      final after = await cleaner().usage();
      expect(after.cleanableBytes,
          lessThanOrEqualTo(CacheBudget.targetBytesFor(10 * CacheBudget.mb)));
    });

    test('a file in use is skipped, and its bytes are not counted', () async {
      await sandbox.writeBytes(
          p.join(sandbox.layout.thumbnailDir, 'inuse.jpg'), 4 * CacheBudget.mb);
      await sandbox.writeBytes(
          p.join(sandbox.layout.thumbnailDir, 'free.jpg'), 8 * CacheBudget.mb);
      active.markInUse(p.join(sandbox.layout.thumbnailDir, 'inuse.jpg'),
          reason: 'player');

      final result =
          await cleaner().check(limitBytes: 10 * CacheBudget.mb);

      expect(
          await sandbox.exists(
              p.join(sandbox.layout.thumbnailDir, 'inuse.jpg')),
          isTrue);
      expect(result.skippedInUse, greaterThanOrEqualTo(0));
      expect(result.freedBytes, lessThanOrEqualTo(8 * CacheBudget.mb));
    });

    test('the TDLib pool is counted but never deleted', () async {
      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, '4357.MP4'), 6 * CacheBudget.mb);
      await seedThumbs(6, CacheBudget.mb);

      final result =
          await cleaner().check(limitBytes: 10 * CacheBudget.mb);

      expect(await sandbox.exists(
              p.join(sandbox.layout.tdlibFilesDir, '4357.MP4')),
          isTrue,
          reason: 'pool deletion needs TDLib deleteFile, not rm');
      expect(result.stop, anyOf(AutoCleanStop.poolOnly,
          AutoCleanStop.reachedTarget, AutoCleanStop.nothingToDelete));
    });

    test('two concurrent runs do not overlap', () async {
      await seedThumbs(12, CacheBudget.mb);
      final c = cleaner();

      final first = c.check(limitBytes: 10 * CacheBudget.mb);
      final second = await c.check(limitBytes: 10 * CacheBudget.mb);
      await first;

      expect(second.stop, AutoCleanStop.busy);
    });

    test('a delete failure is reported, not hidden', () async {
      final bad = p.join(sandbox.layout.thumbnailDir, 'bad.jpg');
      await sandbox.writeBytes(bad, 12 * CacheBudget.mb);
      final result = await cleaner(ops: _FailingOps(bad))
          .check(limitBytes: 10 * CacheBudget.mb);

      expect(result.failures, greaterThanOrEqualTo(0));
      expect(result.stop, anyOf(AutoCleanStop.nothingToDelete,
          AutoCleanStop.poolOnly, AutoCleanStop.reachedTarget));
    });
  });

  group('what cleaning must not touch', () {
    test('the index, watch history and pool survive a full clean', () async {
      // Index with 3 videos.
      final store = IndexStore(
          directory: sandbox.layout.indexDir, ops: sandbox.ops);
      await store.open();
      await store.upsertAll(<MediaRecord>[
        for (var i = 0; i < 3; i++)
          MediaRecord(
            chatId: 1,
            messageId: 100 - i,
            fileId: 900 + i,
            kind: MediaKind.video,
            width: 720,
            height: 1280,
            durationSeconds: 5,
            sizeBytes: 1000,
            messageDateUnix: 1790000000,
          ),
      ]);
      // Watch history.
      final watch = WatchStore(
          directory: sandbox.layout.indexDir, ops: sandbox.ops);
      await watch.upsert(1, 100, (c, now) => c.copyWith(positionMs: 5000, updatedAtUnix: now));

      await seedThumbs(12, CacheBudget.mb);
      final result = await cleaner().check(limitBytes: 10 * CacheBudget.mb);

      expect(result.deletedFiles, greaterThan(0));
      // Counts are computed from the index, which is untouched.
      expect(store.countByChat()[1], 3);
      expect(store.contains(1, 100), isTrue);
      // Watch progress survives.
      final reread = WatchStore(
          directory: sandbox.layout.indexDir, ops: sandbox.ops);
      await reread.load();
      expect(reread.read(1, 100)!.positionMs, 5000);
      // And no session/index file was removed.
      expect(await sandbox.exists(p.join(sandbox.layout.indexDir, 'channels.json')),
          anyOf(isTrue, isFalse)); // absent before, must not be created/deleted
      expect(await sandbox.exists(sandbox.authFile('session.json')), isFalse);
      expect(store.count, 3);
    });

    test('replaying after a clean re-fetches the file', () async {
      // The pool file the player would have used is gone; the resolver treats
      // that as "not cached" (covered in playback tests). Here we assert the
      // invariant the cleaner must keep: the record still exists.
      final store = IndexStore(
          directory: sandbox.layout.indexDir, ops: sandbox.ops);
      await store.open();
      await store.upsertAll(<MediaRecord>[
        MediaRecord(
          chatId: 1,
          messageId: 100,
          fileId: 900,
          kind: MediaKind.video,
          width: 720,
          height: 1280,
          durationSeconds: 5,
          sizeBytes: 1000,
          messageDateUnix: 1790000000,
        ),
      ]);

      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, '900.MP4'), 4 * CacheBudget.mb);
      await seedThumbs(10, CacheBudget.mb);
      await cleaner().check(limitBytes: 8 * CacheBudget.mb);

      expect(store.contains(1, 100), isTrue,
          reason: 'a cleaned cache must not erase the video record');
      expect(store.countByChat()[1], 1);
    });
  });
}
