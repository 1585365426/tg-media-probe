/// Cache ceiling: how much disk the app may use, and what to do when it does not.
///
/// Scope, stated up front because it is easy to oversell:
/// * only the three whitelisted temp directories are ever deleted
///   (`thumb/`, `player/`, `partial/`) — the same set `CacheManager` clears;
/// * the TDLib file pool (`tdlib_files/`) is **counted, never deleted** here.
///   Deleting pool files behind TDLib's back leaves its file database pointing
///   at bytes that no longer exist; doing it properly needs a per-file
///   `deleteFile` through TDLib, which this round does not implement. When the
///   whitelist is empty and the budget is still exceeded, the result says so
///   instead of pretending success.
/// * nothing outside the whitelist is scanned: no Application Support, no whole
///   Caches directory, no index, no session.
library;

import 'active_files.dart';
import 'cache_manager.dart';
import 'file_ops.dart';
import 'storage_layout.dart';

/// Allowed ceilings. Bytes are the unit; the UI formats MB/GB.
class CacheBudget {
  const CacheBudget._();

  static const int mb = 1024 * 1024;
  static const int gb = 1024 * mb;

  static const int defaultLimit = 1 * gb;
  static const int minLimit = 256 * mb;
  static const int maxLimit = 20 * gb;

  /// Presets offered in settings; custom values are allowed within
  /// [minLimit]..[maxLimit].
  static const List<int> presets = <int>[
    512 * mb,
    1 * gb,
    2 * gb,
    5 * gb,
  ];

  /// Clean down to this fraction of the limit once it is exceeded. 1 GB → 800 MB.
  static const double targetRatio = 0.8;

  static int targetBytesFor(int limit) => (limit * targetRatio).round();

  static bool isAllowed(int limit) => limit >= minLimit && limit <= maxLimit;

  static int clamp(int limit) => limit.clamp(minLimit, maxLimit);

  static String format(int bytes) {
    if (bytes >= gb) {
      final value = bytes / gb;
      return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} GB';
    }
    return '${(bytes / mb).round()} MB';
  }
}

class CacheUsage {
  const CacheUsage({
    required this.thumbBytes,
    required this.playerBytes,
    required this.partialBytes,
    required this.poolBytes,
  });

  final int thumbBytes;
  final int playerBytes;
  final int partialBytes;

  /// TDLib's own pool. Counted, not managed by this cleaner.
  final int poolBytes;

  int get cleanableBytes => thumbBytes + playerBytes + partialBytes;
  int get totalBytes => cleanableBytes + poolBytes;
}

enum AutoCleanStop {
  /// Under the limit: nothing to do.
  withinLimit,

  /// Reached the target (≈80% of the limit).
  reachedTarget,

  /// The whitelist is empty but the pool still pushes the total over.
  poolOnly,

  /// A run was already in progress.
  busy,

  /// Only possible when an explicit force run is requested.
  nothingToDelete,
}

class AutoCleanResult {
  const AutoCleanResult({
    required this.stop,
    required this.beforeBytes,
    required this.afterBytes,
    this.deletedFiles = 0,
    this.freedBytes = 0,
    this.skippedInUse = 0,
    this.failures = 0,
    this.atUnix,
  });

  final AutoCleanStop stop;
  final int beforeBytes;
  final int afterBytes;
  final int deletedFiles;
  final int freedBytes;
  final int skippedInUse;
  final int failures;
  final int? atUnix;

  bool get didWork => deletedFiles > 0;

  String summary() {
    switch (stop) {
      case AutoCleanStop.withinLimit:
        return '未超限（${CacheBudget.format(beforeBytes)}）';
      case AutoCleanStop.reachedTarget:
        return '已清理 $deletedFiles 个文件，释放 ${CacheBudget.format(freedBytes)}，'
            '当前 ${CacheBudget.format(afterBytes)}';
      case AutoCleanStop.poolOnly:
        return '可清理目录已空，仍有 ${CacheBudget.format(afterBytes)}'
            '（TDLib 文件池，暂不自动删除）';
      case AutoCleanStop.busy:
        return '已有一个清理任务在运行';
      case AutoCleanStop.nothingToDelete:
        return '没有可安全删除的缓存文件';
    }
  }
}

/// The cleaner itself.
///
/// Order is fixed: thumbnails first (cheapest to rebuild), then playback
/// temporaries, then unfinished downloads. Full media in the TDLib pool is out
/// of scope for the reason at the top of this file.
class AutoCacheCleaner {
  AutoCacheCleaner({
    required this.layout,
    required this.ops,
    required this.activeFiles,
    CacheManager? manager,
    this.onResult,
  }) : _manager = manager ??
            CacheManager(layout: layout, ops: ops, activeFiles: activeFiles);

  final StorageLayout layout;
  final FileOps ops;
  final ActiveFileRegistry activeFiles;
  final CacheManager _manager;

  /// Called after every run so the settings row can show the last result.
  final void Function(AutoCleanResult result)? onResult;

  bool _running = false;

  bool get isRunning => _running;

  Future<CacheUsage> usage() async {
    final scan = await _manager.scan();
    var thumb = 0;
    var player = 0;
    var partial = 0;
    for (final entry in scan.entries) {
      switch (entry.kind.name) {
        case 'thumbnail':
          thumb += entry.bytes;
        case 'playbackTemp':
          player += entry.bytes;
        case 'partialDownload':
          partial += entry.bytes;
      }
    }
    final pool = await _directoryBytes(layout.tdlibFilesDir);
    return CacheUsage(
      thumbBytes: thumb,
      playerBytes: player,
      partialBytes: partial,
      poolBytes: pool,
    );
  }

  /// Checks the ceiling and cleans down to ~80% when exceeded.
  Future<AutoCleanResult> check({
    required int limitBytes,
    bool force = false,
  }) async {
    if (_running) {
      return const AutoCleanResult(
        stop: AutoCleanStop.busy,
        beforeBytes: 0,
        afterBytes: 0,
      );
    }
    _running = true;
    try {
      final before = await usage();
      // The cleaner obeys the number it is given. Clamping to the UI minimum
      // here made small limits untestable and, worse, silently ignored a
      // deliberately low ceiling.
      final limit = limitBytes > 0 ? limitBytes : CacheBudget.defaultLimit;
      if (!force && before.totalBytes <= limit) {
        final result = AutoCleanResult(
          stop: AutoCleanStop.withinLimit,
          beforeBytes: before.totalBytes,
          afterBytes: before.totalBytes,
          atUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
        onResult?.call(result);
        return result;
      }

      final target = CacheBudget.targetBytesFor(limit);
      final scan = await _manager.scan();
      // Stable order: thumbnails, then player temporaries, then partials.
      final ordered = <CacheEntry>[
        ...scan.entries.where((e) => e.kind.name == 'thumbnail'),
        ...scan.entries.where((e) => e.kind.name == 'playbackTemp'),
        ...scan.entries.where((e) => e.kind.name == 'partialDownload'),
      ];

      var remaining = before.totalBytes;
      var deleted = 0;
      var freed = 0;
      var skipped = 0;
      var failures = 0;
      var sinceYield = 0;

      for (final entry in ordered) {
        if (remaining <= target) break;
        if (activeFiles.isInUse(entry.path)) {
          skipped++;
          continue;
        }
        try {
          await layout.assertDeletableByCacheClear(entry.path);
          final size = await ops.sizeOf(entry.path);
          await ops.deleteFile(entry.path);
          if (await ops.exists(entry.path)) {
            failures++;
            continue;
          }
          deleted++;
          freed += size;
          remaining -= size;
        } on Object {
          // A file that vanished between scan and delete is not a failure; a
          // guard rejection is. Either way the loop moves on and the count is
          // reported honestly.
          if (await ops.exists(entry.path)) failures++;
        }
        if (++sinceYield >= 20) {
          sinceYield = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }

      final after = await usage();
      final stop = remaining <= target
          ? AutoCleanStop.reachedTarget
          : (after.cleanableBytes == 0 && after.poolBytes > 0
              ? AutoCleanStop.poolOnly
              : AutoCleanStop.nothingToDelete);
      final result = AutoCleanResult(
        stop: stop,
        beforeBytes: before.totalBytes,
        afterBytes: after.totalBytes,
        deletedFiles: deleted,
        freedBytes: freed,
        skippedInUse: skipped,
        failures: failures,
        atUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      onResult?.call(result);
      return result;
    } finally {
      _running = false;
    }
  }

  Future<int> _directoryBytes(String dir) async {
    var total = 0;
    for (final path in await ops.listFilesRecursive(dir)) {
      total += await ops.sizeOf(path);
    }
    return total;
  }
}
