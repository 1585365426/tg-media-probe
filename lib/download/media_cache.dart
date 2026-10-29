/// The app's media cache: where verified video bytes live, how big it is, and
/// how it is emptied.
///
/// Deliberately narrow. It can only look at, measure and delete files **inside
/// the app's own media root**; there is no method here that reaches Telegram,
/// and the clear routine refuses any path outside that root even if it is
/// handed one.
library;

import 'package:path/path.dart' as p;

import '../platform/disk_space.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';

/// Shown in the clear-cache confirmation. Kept in this file so the wording and
/// the routine it describes cannot drift apart.
const String cacheClearConfirmationText =
    '本操作只删除本机已下载的视频文件，'
    '不会删除 Telegram 频道消息或云端媒体，也不会删除媒体索引、'
    '账号授权或用户主动保存的下载文件。';

class CacheWipe {
  const CacheWipe({
    required this.deletedFiles,
    required this.freedBytes,
    this.skipped = const <String>[],
    this.errors = const <String>[],
  });

  static const CacheWipe none =
      CacheWipe(deletedFiles: 0, freedBytes: 0);

  final int deletedFiles;
  final int freedBytes;

  /// Paths kept on purpose (the video currently open in the player).
  final List<String> skipped;
  final List<String> errors;

  bool get changedAnything => deletedFiles > 0;
}

class MediaCache {
  MediaCache({
    required this.layout,
    this.ops = const IoFileOps(),
    this.diskSpace = const MethodChannelDiskSpace(),
  });

  /// Safety margin kept free when starting a download. 64 MB covers the
  /// container growth and lets the app keep working when a file lands exactly
  /// at the reported free space.
  static const int spaceMargin = 64 * 1024 * 1024;

  final StorageLayout layout;
  final FileOps ops;
  final DiskSpace diskSpace;

  String get root => layout.mediaRoot;

  Future<void> ensureCreated() => ops.createDirectory(root);

  /// Bytes of downloaded media currently on disk.
  Future<int> usedBytes() async {
    var total = 0;
    for (final path in await ops.listFilesRecursive(root)) {
      total += await ops.sizeOf(path);
    }
    return total;
  }

  /// Free space in bytes, or -1 when the platform could not measure it.
  Future<int> freeBytes() => diskSpace.availableBytes();

  /// True when a file of [bytes] fits with [spaceMargin] to spare.
  ///
  /// An unmeasurable free-space value (-1) answers true: the download then
  /// either works or fails with a real write error, which the UI reports. That
  /// is better than blocking every download on a failed platform call.
  Future<bool> hasRoomFor(int bytes) async {
    if (bytes <= 0) return true;
    final free = await freeBytes();
    if (free < 0) return true;
    return free >= bytes + spaceMargin;
  }

  /// Deletes every file under the media root except [keep] (the file the player
  /// currently has open).
  ///
  /// Only local bytes: the channel, the messages and the Telegram-side media
  /// are untouched, and the next play downloads again.
  Future<CacheWipe> clearLocal({Set<String> keep = const <String>{}}) async {
    final files = await ops.listFilesRecursive(root);
    var deleted = 0;
    var freed = 0;
    final skipped = <String>[];
    final errors = <String>[];

    for (final path in files) {
      final normalized = p.normalize(p.absolute(path));
      if (!p.isWithin(p.normalize(p.absolute(root)), normalized)) {
        // A symlink or a stray path that escaped the root is not ours to delete.
        errors.add('outside media root: $path');
        continue;
      }
      if (keep.contains(normalized)) {
        skipped.add(path);
        continue;
      }
      try {
        final size = await ops.sizeOf(path);
        await ops.deleteFile(path);
        // A delete that silently does nothing must not be reported as freed
        // bytes: the user would see "freed 500 MB" on a full disk.
        if (await ops.exists(path)) {
          errors.add('$path: still present after delete');
          continue;
        }
        deleted++;
        freed += size;
      } on Object catch (e) {
        errors.add('$path: $e');
      }
    }

    return CacheWipe(
      deletedFiles: deleted,
      freedBytes: freed,
      skipped: skipped,
      errors: errors,
    );
  }
}
