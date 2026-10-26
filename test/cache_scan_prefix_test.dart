import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';

import 'support/sandbox.dart';

/// End-to-end coverage for the TDLib blob pool: the only cache kind that
/// actually holds bytes.
///
/// The "0 B forever" bug had two independent halves, and this file pins the
/// second one. The first half — containment compared against `layout.tempRoot`
/// as raw strings — cannot be reproduced on Windows, because `package:path`
/// runs in Windows mode there and `/var` vs `/private/var` never appears. That
/// half is covered by the comment in `CacheManager.scan` and was verified on
/// device; pretending a passing Windows test proves it would be worse than
/// having no test.
void main() {
  late TestSandbox sandbox;

  setUp(() async => sandbox = await TestSandbox.create());
  tearDown(() async => sandbox.dispose());

  CacheManager manager() => CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: ActiveFileRegistry(),
      );

  group('TDLib blob pool', () {
    test('files under tdlib_files are counted, not skipped', () async {
      // TDLib names pool files after the file id, with no extension.
      final blob = p.join(sandbox.layout.tdlibFilesDir, '123456789');
      await sandbox.writeBytes(blob, 512);

      final scan = await manager().scan();

      expect(scan.countOf(CacheKind.tdlibBlobPool), 1);
      expect(scan.bytesOf(CacheKind.tdlibBlobPool), 512);
      expect(scan.totalBytes, 512);
      expect(scan.reclaimableBytes, 512);
      expect(scan.unsafePaths, isEmpty);
    });

    test('nested entries are walked recursively', () async {
      // Newer TDLib builds shard the pool into sub-directories.
      final nested = p.join(sandbox.layout.tdlibFilesDir, 'ab', 'cd', '99');
      await sandbox.writeBytes(nested, 128);

      final scan = await manager().scan();

      expect(scan.countOf(CacheKind.tdlibBlobPool), 1);
      expect(scan.totalBytes, 128);
    });

    test('an empty pool reports zero instead of failing', () async {
      final scan = await manager().scan();
      expect(scan.fileCount, 0);
      expect(scan.totalBytes, 0);
      expect(scan.unsafePaths, isEmpty);
    });

    test('clearing removes pool blobs and reports the freed bytes', () async {
      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, '1'), 256);
      await sandbox.writeBytes(
          p.join(sandbox.layout.tdlibFilesDir, '2'), 256);

      final report = await manager().clear(userConfirmed: true);

      expect(report.deletedFiles, 2);
      expect(report.freedBytes, 512);
      expect(report.freedByKind[CacheKind.tdlibBlobPool], 512);
      expect(report.failures, isEmpty);
      expect((await manager().scan()).totalBytes, 0);
    });

    test('a playing blob is skipped, not deleted', () async {
      final blob = p.join(sandbox.layout.tdlibFilesDir, '777');
      await sandbox.writeBytes(blob, 300);
      final registry = ActiveFileRegistry()..markInUse(blob, reason: 'player');

      final managerWithRegistry = CacheManager(
        layout: sandbox.layout,
        ops: sandbox.ops,
        activeFiles: registry,
      );
      final scan = await managerWithRegistry.scan();
      expect(scan.inUseCount, 1);

      final report = await managerWithRegistry.clear(userConfirmed: true);
      expect(report.deletedFiles, 0);
      expect(report.skippedInUse, contains(blob));
      expect(await sandbox.exists(blob), isTrue);
    });
  });

  group('directory reporting', () {
    test('each scanned kind reports its own directory', () {
      final cache = manager();
      // The settings screen prints these next to the numbers: "0 B" on its own
      // cannot tell "empty" apart from "looked in the wrong place".
      expect(cache.dirFor(CacheKind.thumbnail), sandbox.layout.thumbnailDir);
      expect(cache.dirFor(CacheKind.playbackTemp),
          sandbox.layout.playbackTempDir);
      expect(cache.dirFor(CacheKind.partialDownload),
          sandbox.layout.partialDownloadDir);
      expect(cache.dirFor(CacheKind.tdlibBlobPool),
          sandbox.layout.tdlibFilesDir);
    });

    test('scannedKinds covers every real cache kind exactly once', () {
      expect(
        CacheManager.scannedKinds.toSet().length,
        CacheManager.scannedKinds.length,
      );
      expect(
        CacheManager.scannedKinds,
        isNot(contains(CacheKind.unknownFromDirectory)),
      );
      for (final kind in CacheKind.values) {
        if (kind == CacheKind.unknownFromDirectory) continue;
        expect(CacheManager.scannedKinds, contains(kind),
            reason: '$kind is a real cache kind and must be swept');
      }
    });
  });
}
