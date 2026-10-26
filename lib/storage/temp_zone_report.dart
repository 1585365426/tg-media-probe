import 'package:path/path.dart' as p;

import '../util/byte_format.dart';
import 'active_files.dart';
import 'cache_ownership.dart';
import 'file_ops.dart';
import 'storage_layout.dart';

/// One file found while inventorying a zone.
class InventoryEntry {
  const InventoryEntry({
    required this.path,
    required this.relativePath,
    required this.bytes,
    required this.inUse,
    this.known = false,
    this.writerLabel,
  });

  final String path;

  /// Path relative to the zone root, so the UI shows `tdlib_files/videos/x.mp4`
  /// instead of 90 characters of `/private/var/mobile/Containers/...`.
  final String relativePath;
  final int bytes;
  final bool inUse;

  /// True when a registered [CacheWriter] claims this file, i.e. when "clear
  /// cache" would actually delete it.
  final bool known;

  /// Human name of the owning writer, for the storage screen.
  final String? writerLabel;

  @override
  String toString() =>
      'InventoryEntry($relativePath, ${formatBytes(bytes)}'
      '${inUse ? ', in use' : ''}${known ? '' : ', unknown'})';
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
    this.unknownCount = 0,
    this.unknownBytes = 0,
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

  /// Files that no registered writer claims. Counted in [fileCount] and
  /// [bytes] — they occupy space — but excluded from every "can be freed"
  /// number, because a clear will skip them.
  final int unknownCount;
  final int unknownBytes;

  static const int keepLargest = 8;

  bool get readable => error == null;

  /// Space the storage screen may promise to reclaim.
  int get reclaimableBytes => bytes - unknownBytes;

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
    this.skippedUnknown = const <MapEntry<String, String>>[],
    this.unknownBytes = 0,
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

  /// `relative path -> reason` for files no registered writer claims. Left on
  /// disk on purpose: an unrecognised file is not a delete candidate.
  final List<MapEntry<String, String>> skippedUnknown;
  final int unknownBytes;

  final Map<StorageZone, bool> protectedZonesBefore;
  final Map<StorageZone, bool> protectedZonesAfter;

  bool get nothingToDo => scannedFiles == 0;

  /// True when the clear ran but left unknown files behind. Not a failure —
  /// the UI should say so instead of implying the disk is now clean.
  bool get hasUnknownLeftovers => skippedUnknown.isNotEmpty;

  /// Protected zones must still be there afterwards. A clear that removes the
  /// login or the index is a failure no matter how many bytes it freed.
  bool get protectedZonesIntact {
    for (final entry in protectedZonesBefore.entries) {
      if (protectedZonesAfter[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Unknown files are skipped by design and are not a failure. They are
  /// reported, which is the opposite of silently guessing.
  bool get succeeded =>
      failures.isEmpty && refusedByGuard.isEmpty && protectedZonesIntact;

  String get summary {
    final parts = <String>[
      '扫描 $scannedFiles 个文件（${formatBytes(scannedBytes)}）',
      '删除 $deletedFiles 个',
      '释放 ${formatBytes(freedBytes)}',
      if (skippedInUse.isNotEmpty) '跳过占用中 ${skippedInUse.length} 个',
      if (skippedUnknown.isNotEmpty)
        '跳过未识别 ${skippedUnknown.length} 个（${formatBytes(unknownBytes)}）',
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
/// Two independent rules decide what may be deleted:
///
/// 1. **Zone** — the file must resolve inside [StorageZone.tempCache]. Enforced
///    per file by [StorageLayout.assertDeletableByCacheClear], immediately
///    before the delete, so a symlink that appeared after the scan is caught.
/// 2. **Ownership** — a registered [CacheWriter] must claim the file. See
///    [CacheOwnership]: anything else is reported and left alone.
///
/// The inventory still walks the whole zone, because "how much space is this
/// app using" and "how much of it can I reclaim" are different questions.
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
      var unknownBytes = 0;
      var unknownCount = 0;
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
        final classification = CacheOwnership.classify(layout, path);
        if (!classification.known) {
          unknownCount++;
          unknownBytes += size;
        }
        all.add(InventoryEntry(
          path: path,
          relativePath: p.isWithin(root, path) ? p.relative(path, from: root) : path,
          bytes: size,
          inUse: activeFiles.isInUse(path),
          known: classification.known,
          writerLabel: classification.writer?.label,
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
        unknownCount: unknownCount,
        unknownBytes: unknownBytes,
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

  /// Deletes every temp-zone file that both guards allow.
  ///
  /// Walks `tempRoot` as a whole rather than a list of known sub-directories, so
  /// the report can name what it skipped. Walking only known directories would
  /// hide exactly the files the user needs to know about.
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
    var unknownBytes = 0;
    final skippedInUse = <String>[];
    final skippedUnknown = <MapEntry<String, String>>[];
    final refused = <String>[];
    final failures = <MapEntry<String, String>>[];
    var done = 0;
    onProgress?.call(0, candidates.length, '');

    for (final path in candidates) {
      final name = p.basename(path);
      final relative = p.isWithin(layout.tempRoot, path)
          ? p.relative(path, from: layout.tempRoot)
          : path;
      final classification = CacheOwnership.classify(layout, path);

      if (!classification.known) {
        // Ownership is checked before the zone guard: an unclaimed file is
        // never a delete candidate, so there is nothing for the guard to do.
        skippedUnknown.add(
          MapEntry(relative, classification.reason ?? '未识别的文件'),
        );
        try {
          unknownBytes += await ops.sizeOf(path);
        } catch (_) {
          // Already counted in scannedBytes; nothing to add.
        }
      } else if (activeFiles.isInUse(path)) {
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
      skippedUnknown: skippedUnknown,
      unknownBytes: unknownBytes,
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

/// Human-readable detail lines for the storage screen.
///
/// Returns at most [limit] lines per category: a pool with thousands of unknown
/// blobs must not turn the dialog into a wall of text.
List<String> describeUnknownFiles(TempCleanReport report, {int limit = 10}) {
  if (report.skippedUnknown.isEmpty) return const <String>[];
  final lines = <String>[
    '以下 ${report.skippedUnknown.length} 个文件未登记归属，已跳过未删除：',
  ];
  for (final entry in report.skippedUnknown.take(limit)) {
    lines.add('  ${entry.key} — ${entry.value}');
  }
  if (report.skippedUnknown.length > limit) {
    lines.add('  …另有 ${report.skippedUnknown.length - limit} 个');
  }
  return lines;
}
