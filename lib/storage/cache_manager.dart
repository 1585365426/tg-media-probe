import 'package:path/path.dart' as p;

import 'active_files.dart';
import 'file_ops.dart';
import 'storage_layout.dart';

/// What a temp file is, derived from the sub-directory it lives in. Nothing is
/// guessed from the file name.
enum CacheKind { thumbnail, playbackTemp, partialDownload, unknownFromDirectory }

extension CacheKindLabel on CacheKind {
  String get label => switch (this) {
        CacheKind.thumbnail => '缩略图缓存',
        CacheKind.playbackTemp => '临时播放文件',
        CacheKind.partialDownload => '未完成的分片',
        CacheKind.unknownFromDirectory => '无法归类',
      };
}

class CacheEntry {
  const CacheEntry({
    required this.path,
    required this.bytes,
    required this.kind,
    required this.inUse,
  });

  final String path;
  final int bytes;
  final CacheKind kind;
  final bool inUse;

  @override
  String toString() => 'CacheEntry(${kind.name}, $bytes B, inUse=$inUse, $path)';
}

class CacheScan {
  const CacheScan({required this.entries, required this.unsafePaths});

  final List<CacheEntry> entries;

  /// Paths that failed the zone check while scanning (symlink escape, or a
  /// file that resolves outside the temp zone). These are never deleted.
  final List<String> unsafePaths;

  int get fileCount => entries.length;

  int get totalBytes => entries.fold(0, (sum, e) => sum + e.bytes);

  int get inUseCount => entries.where((e) => e.inUse).length;

  int get inUseBytes =>
      entries.where((e) => e.inUse).fold(0, (sum, e) => sum + e.bytes);

  /// What the UI is allowed to promise: total minus files that are busy.
  int get reclaimableBytes => totalBytes - inUseBytes;

  int get reclaimableCount => entries.where((e) => !e.inUse).length;

  int bytesOf(CacheKind kind) =>
      entries.where((e) => e.kind == kind).fold(0, (sum, e) => sum + e.bytes);

  Map<CacheKind, int> get bytesByKind => <CacheKind, int>{
        for (final kind in CacheKind.values)
          if (bytesOf(kind) > 0) kind: bytesOf(kind),
      };
}

class CacheClearFailure {
  const CacheClearFailure(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => '$path: $reason';
}

/// Result of a clear run. Numbers are taken from real delete operations —
/// a file only counts as freed after it is confirmed gone from disk.
class CacheClearReport {
  const CacheClearReport({
    required this.deletedFiles,
    required this.freedBytes,
    required this.skippedInUse,
    required this.skippedUnsafe,
    required this.failures,
    required this.protectedZonesIntact,
    required this.integrityPreserved,
    required this.freedByKind,
  });

  final int deletedFiles;
  final int freedBytes;
  final List<String> skippedInUse;
  final List<String> skippedUnsafe;
  final List<CacheClearFailure> failures;

  /// False when a protected zone (downloads / index / auth) disappeared or
  /// became unreadable during the run. Callers must surface this as a failure.
  final bool protectedZonesIntact;

  /// False when the injected integrity probe reported different counts before
  /// and after clearing (index rows, favourites, download records).
  final bool integrityPreserved;

  final Map<CacheKind, int> freedByKind;

  /// Honest success: nothing failed and nothing protected changed.
  bool get succeeded =>
      failures.isEmpty && protectedZonesIntact && integrityPreserved;

  /// Partial success is still reported as not-succeeded so the UI cannot claim
  /// a clean wipe when some files survived.
  String get summary {
    final parts = <String>[
      '删除 $deletedFiles 个文件',
      '释放 $freedBytes 字节',
      if (skippedInUse.isNotEmpty) '跳过占用中 ${skippedInUse.length} 个',
      if (skippedUnsafe.isNotEmpty) '跳过越界 ${skippedUnsafe.length} 个',
      if (failures.isNotEmpty) '失败 ${failures.length} 个',
      if (!protectedZonesIntact) '受保护目录异常',
      if (!integrityPreserved) '索引完整性校验失败',
    ];
    return parts.join(' · ');
  }
}

class CacheClearNotConfirmed implements Exception {
  const CacheClearNotConfirmed();

  @override
  String toString() => 'CacheClearNotConfirmed: user confirmation is required';
}

/// Clears **only** [StorageZone.tempCache].
///
/// Safety contract, in order of enforcement:
/// 1. `scan()` walks the three temp sub-directories and nothing else. The
///    downloads / index / auth roots are only ever `exists()`-checked.
/// 2. Every candidate goes through
///    [StorageLayout.assertDeletableByCacheClear] immediately before deletion,
///    so a path that moved (or a symlink that appeared) after the scan is
///    rejected rather than deleted.
/// 3. Files registered as in-use are skipped, never deleted.
/// 4. Bytes are added to the report only after the file is confirmed gone.
/// 5. A delete that throws is reported as a failure; no fake success.
/// 6. Before/after integrity probes must match, otherwise the run is reported
///    as failed even though some files were removed.
class CacheManager {
  CacheManager({
    required this.layout,
    required this.ops,
    required this.activeFiles,
    this.integrityProbe,
  });

  final StorageLayout layout;
  final FileOps ops;
  final ActiveFileRegistry activeFiles;

  /// Optional callback returning counters (index rows, favourites, download
  /// records) that must be identical before and after a clear.
  final Future<Map<String, int>> Function()? integrityProbe;

  Future<CacheScan> scan() async {
    final entries = <CacheEntry>[];
    final unsafe = <String>[];
    for (final kind in <CacheKind>[
      CacheKind.thumbnail,
      CacheKind.playbackTemp,
      CacheKind.partialDownload,
    ]) {
      final dir = _dirFor(kind);
      final files = await ops.listFilesRecursive(dir);
      for (final path in files) {
        final ok = await _isSafelyInsideTemp(path);
        if (!ok) {
          unsafe.add(path);
          continue;
        }
        entries.add(CacheEntry(
          path: path,
          bytes: await ops.sizeOf(path),
          kind: kind,
          inUse: activeFiles.isInUse(path),
        ));
      }
    }
    return CacheScan(entries: entries, unsafePaths: unsafe);
  }

  /// Deletes temp cache files. Refuses to run without explicit confirmation —
  /// there is no "clean up quietly on launch" path.
  Future<CacheClearReport> clear({required bool userConfirmed}) async {
    if (!userConfirmed) throw const CacheClearNotConfirmed();

    final protectedBefore = await _protectedSnapshot();
    final integrityBefore = await integrityProbe?.call();

    final scanResult = await scan();
    var deleted = 0;
    var freed = 0;
    final skippedInUse = <String>[];
    final skippedUnsafe = <String>[...scanResult.unsafePaths];
    final failures = <CacheClearFailure>[];
    final freedByKind = <CacheKind, int>{};

    for (final entry in scanResult.entries) {
      if (activeFiles.isInUse(entry.path)) {
        skippedInUse.add(entry.path);
        continue;
      }
      try {
        // Re-validate right before the delete: the scan may be seconds old.
        await layout.assertDeletableByCacheClear(entry.path);
        await ops.deleteFile(entry.path);
        if (await ops.exists(entry.path)) {
          failures.add(CacheClearFailure(entry.path, 'file still present after delete'));
          continue;
        }
        deleted++;
        freed += entry.bytes;
        freedByKind[entry.kind] = (freedByKind[entry.kind] ?? 0) + entry.bytes;
      } on ZoneViolation catch (e) {
        skippedUnsafe.add(entry.path);
        failures.add(CacheClearFailure(entry.path, e.message));
      } catch (e) {
        failures.add(CacheClearFailure(entry.path, e.toString()));
      }
    }

    // Only empty temp sub-directories are removed, and they are recreated so
    // the next run has a stable layout.
    for (final kind in CacheKind.values) {
      if (kind == CacheKind.unknownFromDirectory) continue;
      try {
        await ops.deleteEmptyDirectory(_dirFor(kind));
      } catch (_) {
        // A non-empty or busy directory is simply left in place.
      }
    }
    await ops.createDirectory(layout.thumbnailDir);
    await ops.createDirectory(layout.playbackTempDir);
    await ops.createDirectory(layout.partialDownloadDir);

    final protectedAfter = await _protectedSnapshot();
    final integrityAfter = await integrityProbe?.call();

    return CacheClearReport(
      deletedFiles: deleted,
      freedBytes: freed,
      skippedInUse: skippedInUse,
      skippedUnsafe: skippedUnsafe,
      failures: failures,
      protectedZonesIntact: _protectedUnchanged(protectedBefore, protectedAfter),
      integrityPreserved: integrityBefore == null
          ? true
          : _sameCounters(integrityBefore, integrityAfter),
      freedByKind: freedByKind,
    );
  }

  /// Counters come back as fresh maps, so `==` would compare identity and always
  /// report a regression. Compare field by field instead.
  static bool _sameCounters(Map<String, int>? before, Map<String, int>? after) {
    if (before == null || after == null) return false;
    if (before.length != after.length) return false;
    for (final entry in before.entries) {
      if (after[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Per-zone usage for the settings screen.
  ///
  /// [includeProtected] defaults to false on purpose: the cache subsystem does
  /// not walk the download or index directories at all. When true, the caller
  /// gets their size too, but the walk happens through this read-only helper
  /// and never feeds the delete path.
  Future<Map<StorageZone, int>> usage({bool includeProtected = false}) async {
    final sizes = <StorageZone, int>{
      StorageZone.tempCache: (await scan()).totalBytes,
    };
    for (final zone in StorageZone.values) {
      if (zone == StorageZone.tempCache) continue;
      if (!includeProtected) {
        // -1 means "not measured": the protected zone was not walked.
        sizes[zone] = -1;
        continue;
      }
      var total = 0;
      for (final path in await ops.listFilesRecursive(layout.rootOf(zone))) {
        total += await ops.sizeOf(path);
      }
      sizes[zone] = total;
    }
    return sizes;
  }

  String _dirFor(CacheKind kind) => switch (kind) {
        CacheKind.thumbnail => layout.thumbnailDir,
        CacheKind.playbackTemp => layout.playbackTempDir,
        CacheKind.partialDownload => layout.partialDownloadDir,
        CacheKind.unknownFromDirectory => layout.tempRoot,
      };

  Future<bool> _isSafelyInsideTemp(String path) async {
    try {
      await layout.assertInside(StorageZone.tempCache, path);
      return true;
    } on ZoneViolation {
      return false;
    }
  }

  Future<Map<StorageZone, bool>> _protectedSnapshot() async {
    final map = <StorageZone, bool>{};
    for (final zone in StorageZone.values) {
      if (!zone.isProtected) continue;
      map[zone] = await ops.exists(layout.rootOf(zone));
    }
    return map;
  }

  bool _protectedUnchanged(
    Map<StorageZone, bool> before,
    Map<StorageZone, bool> after,
  ) {
    for (final entry in before.entries) {
      if (after[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Human-readable confirmation text. Kept next to the implementation so the
/// wording and the behaviour cannot drift apart.
const String cacheClearConfirmationText =
    '本操作仅清理 TG Media 的可重建缓存和符合条件的临时文件，'
    '不会删除 Telegram 频道消息或云端媒体，也不会删除收藏、媒体索引、'
    '账号授权或用户主动保存的下载文件。';

/// Diagnostics line printed by the settings screen when the report is partial.
String describeCacheReport(CacheClearReport report) {
  final buffer = StringBuffer(report.summary);
  if (report.failures.isNotEmpty) {
    buffer.write('\n失败明细：');
    for (final failure in report.failures.take(10)) {
      buffer.write('\n  ${p.basename(failure.path)} — ${failure.reason}');
    }
  }
  return buffer.toString();
}
