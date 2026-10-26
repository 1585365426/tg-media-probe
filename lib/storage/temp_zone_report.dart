import 'package:path/path.dart' as p;

import '../util/byte_format.dart';
import 'active_files.dart';
import 'file_ops.dart';
import 'storage_layout.dart';

/// One file found while inventorying a zone.
class InventoryEntry {
  const InventoryEntry({
    required this.path,
    required this.relativePath,
    required this.bytes,
    required this.inUse,
  });

  final String path;

  /// Path relative to the zone root, so the UI shows `tdlib_files/videos/x.mp4`
  /// instead of 90 characters of `/private/var/mobile/Containers/...`.
  final String relativePath;
  final int bytes;
  final bool inUse;

  @override
  String toString() =>
      'InventoryEntry($relativePath, ${formatBytes(bytes)}${inUse ? ', in use' : ''})';
}

/// What one zone actually contains right now.
///
/// Every number here comes from a `stat` that succeeded. A zone that could not
/// be read carries [error] and reports zero files — the caller must render that
/// as "读取失败", never as "0 B", because those two states led to a whole round
/// of wrong conclusions earlier.
class ZoneInventory {
  const ZoneInventory({
    required this.zone,
    required this.root,
    required this.exists,
    required this.fileCount,
    required this.bytes,
    required this.entries,
    this.error,
  });

  final StorageZone zone;
  final String root;
  final bool exists;
  final int fileCount;
  final int bytes;

  /// Largest [keepLargest] files, sorted descending. Enough to answer "what is
  /// eating the space" without shipping thousands of rows to the UI.
  final List<InventoryEntry> entries;
  final String? error;

  static const int keepLargest = 8;

  bool get readable => error == null;

  String get line => exists
      ? '$fileCount 个文件 · ${formatBytes(bytes)}'
      : '目录不存在';
}

class TempCleanReport {
  const TempCleanReport({
    required this.scannedFiles,
    required this.scannedBytes,
    required this.deletedFiles,
    required this.freedBytes,
    required this.skippedInUse,
    required this.refusedByGuard,
    required this.failures,
    required this.protectedZonesBefore,
    required this.protectedZonesAfter,
  });

  final int scannedFiles;
  final int scannedBytes;
  final int deletedFiles;
  final int freedBytes;
  final List<String> skippedInUse;

  /// Paths the zone guard rejected. Non-empty means the scan saw something that
  /// resolves outside the temp zone; those files are left alone by design.
  final List<String> refusedByGuard;
  final List<MapEntry<String, String>> failures;

  final Map<StorageZone, bool> protectedZonesBefore;
  final Map<StorageZone, bool> protectedZonesAfter;

  bool get nothingToDo => scannedFiles == 0;

  /// Protected zones must still be there afterwards. A clear that removes the
  /// login or the index is a failure no matter how many bytes it freed.
  bool get protectedZonesIntact {
    for (final entry in protectedZonesBefore.entries) {
      if (protectedZonesAfter[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool get succeeded =>
      failures.isEmpty && refusedByGuard.isEmpty && protectedZonesIntact;

  String get summary {
    final parts = <String>[
      '扫描 $scannedFiles 个文件（${formatBytes(scannedBytes)}）',
      '删除 $deletedFiles 个',
      '释放 ${formatBytes(freedBytes)}',
      if (skippedInUse.isNotEmpty) '跳过占用中 ${skippedInUse.length} 个',
      if (refusedByGuard.isNotEmpty) '越界拒绝 ${refusedByGuard.length} 个',
      if (failures.isNotEmpty) '失败 ${failures.length} 个',
      if (!protectedZonesIntact) '受保护目录发生变化',
    ];
    return parts.join(' · ');
  }
}

class TempCleanNotConfirmed implements Exception {
  const TempCleanNotConfirmed();

  @override
  String toString() => 'TempCleanNotConfirmed: explicit confirmation required';
}

/// Inventory + cleanup for the four storage zones.
///
/// Deliberately *not* built on `CacheKind`. That classification answers "which
/// of the three directories I know about is this file in", and every time a
/// writer used a fourth directory the byte count silently dropped to zero while
/// the disk filled up. This class walks the whole zone and reports what is
/// physically there; the only categorisation it does is the zone itself, which
/// is enforced by path containment.
class TempZoneReport {
  TempZoneReport({
    required this.layout,
    required this.ops,
    required this.activeFiles,
  });

  final StorageLayout layout;
  final FileOps ops;
  final ActiveFileRegistry activeFiles;

  /// Walks one zone. Never throws: an unreadable zone comes back with [error].
  Future<ZoneInventory> inventory(StorageZone zone) async {
    final root = layout.rootOf(zone);
    try {
      if (!await ops.exists(root)) {
        return ZoneInventory(
          zone: zone,
          root: root,
          exists: false,
          fileCount: 0,
          bytes: 0,
          entries: const <InventoryEntry>[],
        );
      }
      final files = await ops.listFilesRecursive(root);
      var bytes = 0;
      final all = <InventoryEntry>[];
      for (final path in files) {
        var size = 0;
        try {
          size = await ops.sizeOf(path);
        } catch (_) {
          // A file that disappeared between listing and stat is not an error;
          // aborting the whole inventory over it is.
          continue;
        }
        bytes += size;
        all.add(InventoryEntry(
          path: path,
          relativePath: p.isWithin(root, path) ? p.relative(path, from: root) : path,
          bytes: size,
          inUse: activeFiles.isInUse(path),
        ));
      }
      all.sort((a, b) => b.bytes.compareTo(a.bytes));
      return ZoneInventory(
        zone: zone,
        root: root,
        exists: true,
        fileCount: all.length,
        bytes: bytes,
        entries: all.take(ZoneInventory.keepLargest).toList(),
      );
    } catch (e) {
      return ZoneInventory(
        zone: zone,
        root: root,
        exists: true,
        fileCount: 0,
        bytes: 0,
        entries: const <InventoryEntry>[],
        error: e.toString(),
      );
    }
  }

  Future<Map<StorageZone, ZoneInventory>> inventoryAll() async {
    final map = <StorageZone, ZoneInventory>{};
    for (final zone in StorageZone.values) {
      map[zone] = await inventory(zone);
    }
    return map;
  }

  /// Deletes everything under the temp zone that the guard allows.
  ///
  /// Walks `tempRoot` as a whole rather than a list of known sub-directories,
  /// so a new writer adding `tempRoot/tiles/` is covered without touching this
  /// file. The safety property does not come from the directory list — it comes
  /// from [StorageLayout.assertDeletableByCacheClear], which runs per file
  /// immediately before the delete and re-resolves symlinks at that moment.
  Future<TempCleanReport> cleanTempZone({
    required bool userConfirmed,
    void Function(int done, int total, String current)? onProgress,
  }) async {
    if (!userConfirmed) throw const TempCleanNotConfirmed();

    final roots = await layout.resolveRoots();
    final protectedBefore = await _protectedSnapshot(roots);

    final candidates = await ops.listFilesRecursive(layout.tempRoot);
    var scannedBytes = 0;
    for (final path in candidates) {
      try {
        scannedBytes += await ops.sizeOf(path);
      } catch (_) {
        // Vanished between list and stat; it will also fail the delete, which
        // is reported honestly there.
      }
    }

    var deleted = 0;
    var freed = 0;
    final skippedInUse = <String>[];
    final refused = <String>[];
    final failures = <MapEntry<String, String>>[];
    var done = 0;
    onProgress?.call(0, candidates.length, '');

    for (final path in candidates) {
      final name = p.basename(path);
      if (activeFiles.isInUse(path)) {
        skippedInUse.add(path);
      } else {
        try {
          await layout.assertDeletableByCacheClear(path, roots: roots);
          final size = await ops.sizeOf(path);
          await ops.deleteFile(path);
          if (await ops.exists(path)) {
            failures.add(MapEntry(path, '删除后文件仍存在'));
          } else {
            deleted++;
            freed += size;
          }
        } on ZoneViolation catch (e) {
          refused.add('$name: ${e.message}');
        } catch (e) {
          failures.add(MapEntry(path, e.toString()));
        }
      }
      done++;
      onProgress?.call(done, candidates.length, name);
      // The loop is a long run of awaits; without this the progress dialog
      // never gets a frame and the tap looks like it did nothing.
      if (done % 32 == 0) await Future<void>.delayed(Duration.zero);
    }

    await _rebuildTempDirs();
    final protectedAfter = await _protectedSnapshot(roots);

    return TempCleanReport(
      scannedFiles: candidates.length,
      scannedBytes: scannedBytes,
      deletedFiles: deleted,
      freedBytes: freed,
      skippedInUse: skippedInUse,
      refusedByGuard: refused,
      failures: failures,
      protectedZonesBefore: protectedBefore,
      protectedZonesAfter: protectedAfter,
    );
  }

  Future<void> _rebuildTempDirs() async {
    await ops.createDirectory(layout.thumbnailDir);
    await ops.createDirectory(layout.playbackTempDir);
    await ops.createDirectory(layout.partialDownloadDir);
    await ops.createDirectory(layout.tdlibFilesDir);
  }

  Future<Map<StorageZone, bool>> _protectedSnapshot(
    ResolvedZoneRoots roots,
  ) async {
    final map = <StorageZone, bool>{};
    for (final zone in StorageZone.values) {
      if (!zone.isProtected) continue;
      map[zone] = await ops.exists(roots.rootOf(zone));
    }
    return map;
  }
}
