import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/download_mover.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

void main() {
  late TestSandbox box;
  late DownloadMover mover;

  setUp(() async {
    box = await TestSandbox.create();
    mover = DownloadMover(layout: box.layout, ops: box.ops);
  });

  tearDown(() async {
    await box.dispose();
  });

  Future<String> seedPool(int bytes, {String name = 'blob.bin'}) async {
    final path = p.join(box.layout.tdlibFilesDir, name);
    await box.writeBytes(path, bytes);
    return path;
  }

  group('promote', () {
    test('copies the blob into the user download zone', () async {
      final source = await seedPool(128);
      final result = await mover.promote(
        sourcePath: source,
        chatId: 42,
        fileId: 7,
        expectedBytes: 128,
        fileName: 'clip.mp4',
      );

      expect(result.bytes, 128);
      expect(result.reused, isFalse);
      expect(p.isWithin(box.layout.downloadsDir, result.path), isTrue);
      expect(p.basename(result.path), 'clip_7.mp4');
      expect(await box.exists(result.path), isTrue);
      expect(await box.ops.sizeOf(result.path), 128);
    });

    test('leaves the TDLib pool copy untouched', () async {
      final source = await seedPool(64);
      await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 64,
        fileName: 'a.mp4',
      );

      expect(await box.exists(source), isTrue,
          reason: "TDLib tracks the file by path; removing it would make "
              "TDLib re-download and lose its own bookkeeping");
      expect(await box.ops.sizeOf(source), 64);
    });

    test('is idempotent: a second run reuses the existing file', () async {
      final source = await seedPool(32);
      final first = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 32,
        fileName: 'a.mp4',
      );
      final second = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 32,
        fileName: 'a.mp4',
      );

      expect(second.path, first.path);
      expect(second.reused, isTrue);
      expect(second.bytes, 32);
    });

    test('replaces a truncated leftover instead of trusting it', () async {
      final source = await seedPool(200);
      final target = p.join(box.layout.downloadsDir, 'c1', 'a_2.mp4');
      await box.writeBytes(target, 10); // half a file from an earlier crash

      final result = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 200,
        fileName: 'a.mp4',
      );

      expect(result.reused, isFalse);
      expect(await box.ops.sizeOf(result.path), 200);
    });

    test('refuses a pool file whose size disagrees with TDLib', () async {
      final source = await seedPool(100);

      await expectLater(
        mover.promote(
          sourcePath: source,
          chatId: 1,
          fileId: 2,
          expectedBytes: 999,
          fileName: 'a.mp4',
        ),
        throwsA(isA<DownloadPromoteException>()
            .having((e) => e.stage, 'stage', 'source')),
      );
      // Nothing was written under the final name.
      expect(
        await box.exists(p.join(box.layout.downloadsDir, 'c1', 'a_2.mp4')),
        isFalse,
      );
    });

    test('fails when TDLib claims completion but the file is gone', () async {
      await expectLater(
        mover.promote(
          sourcePath: p.join(box.layout.tdlibFilesDir, 'missing.bin'),
          chatId: 1,
          fileId: 2,
          expectedBytes: 10,
          fileName: 'a.mp4',
        ),
        throwsA(isA<DownloadPromoteException>()
            .having((e) => e.stage, 'stage', 'source')),
      );
    });

    test('a hostile file name cannot escape the download zone', () async {
      final source = await seedPool(16);
      final result = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 16,
        fileName: '../../../../Library/Preferences/evil.plist',
      );

      expect(p.isWithin(box.layout.downloadsDir, result.path), isTrue);
      expect(await box.layout.zoneOf(result.path), StorageZone.userDownloads);
    });

    test('leaves no .part file behind', () async {
      final source = await seedPool(48);
      final result = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 48,
        fileName: 'a.mp4',
      );

      expect(await box.exists('${result.path}.part'), isFalse);
    });

    test('expectedBytes 0 skips the precondition but still copies', () async {
      final source = await seedPool(24);
      final result = await mover.promote(
        sourcePath: source,
        chatId: 1,
        fileId: 2,
        expectedBytes: 0,
        fileName: 'a.mp4',
      );

      expect(result.bytes, 24);
      expect(await box.ops.sizeOf(result.path), 24);
    });

    test('two different file ids with the same name both survive', () async {
      final s1 = await seedPool(10, name: 'one.bin');
      final s2 = await seedPool(20, name: 'two.bin');

      final r1 = await mover.promote(
        sourcePath: s1,
        chatId: 1,
        fileId: 1,
        expectedBytes: 10,
        fileName: 'video.mp4',
      );
      final r2 = await mover.promote(
        sourcePath: s2,
        chatId: 1,
        fileId: 2,
        expectedBytes: 20,
        fileName: 'video.mp4',
      );

      expect(r1.path, isNot(r2.path));
      expect(await box.ops.sizeOf(r1.path), 10);
      expect(await box.ops.sizeOf(r2.path), 20);
    });
  });

  group('zone placement', () {
    test('the TDLib pool sits in the purgeable temp zone', () async {
      expect(await box.layout.zoneOf(box.layout.tdlibFilesDir),
          StorageZone.tempCache);
    });

    test('the TDLib database sits in the protected auth zone', () async {
      expect(await box.layout.zoneOf(box.layout.tdlibDatabaseDir),
          StorageZone.authMeta);
    });

    test('cache clearing can never touch the database', () async {
      await expectLater(
        box.layout.assertDeletableByCacheClear(
            p.join(box.layout.tdlibDatabaseDir, 'db.sqlite')),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('the database is not inside any other zone root', () async {
      expect(p.isWithin(box.layout.tempRoot, box.layout.tdlibDatabaseDir),
          isFalse);
      expect(p.isWithin(box.layout.downloadsRoot, box.layout.tdlibDatabaseDir),
          isFalse);
      expect(p.isWithin(box.layout.indexRoot, box.layout.tdlibDatabaseDir),
          isFalse);
    });
  });
}
