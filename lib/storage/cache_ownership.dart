/// Which files inside the temp zone this build is allowed to delete.
///
/// The rule is a whitelist, not a blacklist. A file is deletable only when the
/// **first path segment under the temp root** names a writer that is registered
/// here. Everything else — a new feature's directory, a stray file dropped at
/// the root, a directory an older build created — is reported and skipped.
///
/// Why a whitelist: the previous version walked the whole temp root and deleted
/// whatever passed the zone guard. That is safe against escaping the sandbox,
/// but it is not safe against "I do not know what this file is". A dropped file
/// with an unknown purpose is exactly the case a cache cleaner must not guess
/// about — deleting it is unrecoverable if it turns out to matter, while leaving
/// it costs a few kilobytes.
///
/// The cost of the strict rule is that a future writer must be registered before
/// its files can be reclaimed. That is the intended trade: a forgotten
/// registration leaks space, a wrong deletion loses data.
library;

import 'package:path/path.dart' as p;

import 'storage_layout.dart';

/// One registered writer of rebuildable cache.
class CacheWriter {
  const CacheWriter({
    required this.id,
    required this.label,
    required this.rebuildable,
  });

  /// Directory name directly under the temp root.
  final String id;

  /// Shown in the storage screen so the user knows what is being cleaned.
  final String label;

  /// False would mean "do not clean this even though it is in the temp zone".
  /// Kept as a field rather than an implicit assumption so a future
  /// non-rebuildable writer has somewhere obvious to be declared.
  final bool rebuildable;
}

/// Result of classifying one path.
class CacheClassification {
  const CacheClassification({required this.known, this.writer, this.reason});

  const CacheClassification.known(CacheWriter this.writer)
      : known = true,
        reason = null;

  const CacheClassification.unknown(this.reason)
      : known = false,
        writer = null;

  final bool known;
  final CacheWriter? writer;

  /// Why the file was not classified, for the diagnostics list.
  final String? reason;
}

class CacheOwnership {
  const CacheOwnership._();

  /// Registered writers. The ids must match the directory names
  /// [StorageLayout] produces — `cache_ownership_test.dart` asserts that, so a
  /// rename on either side fails the build instead of silently disabling
  /// cleanup for that directory.
  static const List<CacheWriter> writers = <CacheWriter>[
    CacheWriter(id: 'thumb', label: '缩略图', rebuildable: true),
    CacheWriter(id: 'player', label: '播放临时文件', rebuildable: true),
    CacheWriter(id: 'partial', label: '未完成的分片', rebuildable: true),
    CacheWriter(id: 'tdlib_files', label: 'Telegram 下载池', rebuildable: true),
  ];

  static CacheWriter? writerById(String id) {
    for (final writer in writers) {
      if (writer.id == id) return writer;
    }
    return null;
  }

  /// Classifies [path] against [layout].
  ///
  /// Uses string operations only: this runs once per file in a clear pass over
  /// a pool that can hold thousands of blobs, and it must not cost a `realpath`.
  /// Containment in the temp zone is enforced separately by
  /// [StorageLayout.assertDeletableByCacheClear], which does resolve symlinks.
  static CacheClassification classify(StorageLayout layout, String path) {
    if (!p.isWithin(layout.tempRoot, path)) {
      return const CacheClassification.unknown('不在临时缓存目录内');
    }

    final relative = p.relative(path, from: layout.tempRoot);
    final segments = p.split(relative);

    if (segments.length < 2) {
      // A file sitting directly in the temp root has no writer that claims it.
      return const CacheClassification.unknown('临时缓存根目录下的散落文件');
    }

    final writer = writerById(segments.first);
    if (writer == null) {
      return CacheClassification.unknown('未登记的缓存目录 ${segments.first}');
    }
    if (!writer.rebuildable) {
      return CacheClassification.unknown('${writer.label}标记为不可重建');
    }

    return CacheClassification.known(writer);
  }

  static bool isKnown(StorageLayout layout, String path) =>
      classify(layout, path).known;

  /// Ids that [StorageLayout] actually creates, used by the consistency test
  /// and by the storage screen to render one row per known writer.
  static Map<String, String> expectedDirectoryNames(StorageLayout layout) =>
      <String, String>{
        'thumb': p.basename(layout.thumbnailDir),
        'player': p.basename(layout.playbackTempDir),
        'partial': p.basename(layout.partialDownloadDir),
        'tdlib_files': p.basename(layout.tdlibFilesDir),
      };
}
