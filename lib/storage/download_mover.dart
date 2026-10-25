/// Moves a downloaded blob from the rebuildable TDLib pool into the zone the
/// user owns.
///
/// Why a separate step instead of pointing TDLib straight at the downloads
/// folder: TDLib treats everything under `files_directory` as its own cache and
/// will delete it whenever it wants (storage optimisation, file
/// de-duplication). Anything the user asked to keep must therefore live
/// outside that tree, under a path this app controls.
///
/// The copy is done through a `.part` file followed by a rename so a crash or a
/// kill can never leave a truncated file under the final name.
library;

import 'package:path/path.dart' as p;

import 'download_paths.dart';
import 'file_ops.dart';
import 'storage_layout.dart';

/// A promotion that failed. Carries the stage so the UI can say *where* it
/// broke instead of a generic "download failed".
class DownloadPromoteException implements Exception {
  const DownloadPromoteException(this.stage, this.message, {this.path});

  /// `source` | `target` | `copy` | `rename` | `verify`
  final String stage;
  final String message;
  final String? path;

  @override
  String toString() =>
      'DownloadPromoteException[$stage] $message${path == null ? '' : ' ($path)'}';
}

class DownloadMoveResult {
  const DownloadMoveResult({
    required this.path,
    required this.bytes,
    required this.reused,
  });

  /// Absolute path inside [StorageZone.userDownloads].
  final String path;
  final int bytes;

  /// True when the file was already there with the right size and nothing was
  /// copied. Makes repeated runs idempotent.
  final bool reused;

  @override
  String toString() =>
      'DownloadMoveResult($bytes B, reused=$reused, $path)';
}

class DownloadMover {
  DownloadMover({required this.layout, FileOps? ops})
      : ops = ops ?? layout.ops;

  final StorageLayout layout;
  final FileOps ops;

  /// Copies [sourcePath] into the user download zone.
  ///
  /// [expectedBytes] comes from TDLib's `file.size`; passing 0 skips the size
  /// precondition (only for callers that genuinely have no size yet — the probe
  /// always has one).
  Future<DownloadMoveResult> promote({
    required String sourcePath,
    required int chatId,
    required int fileId,
    required int expectedBytes,
    String? fileName,
    String? mimeType,
  }) async {
    if (!await ops.exists(sourcePath)) {
      throw DownloadPromoteException(
          'source', 'TDLib 报告已完成，但文件不存在', path: sourcePath);
    }

    final sourceBytes = await ops.sizeOf(sourcePath);
    if (expectedBytes > 0 && sourceBytes != expectedBytes) {
      throw DownloadPromoteException(
        'source',
        'TDLib 池内文件大小不符: local=$sourceBytes expected=$expectedBytes',
        path: sourcePath,
      );
    }

    final target = userDownloadPath(
      downloadsRoot: layout.downloadsDir,
      chatId: chatId,
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
    );

    // Defence in depth: if the naming rules ever regress, this refuses to write
    // outside the zone instead of trusting the string.
    try {
      await layout.assertInside(StorageZone.userDownloads, target);
    } on ZoneViolation catch (e) {
      throw DownloadPromoteException('target', e.message, path: target);
    }

    await ops.createDirectory(p.dirname(target));

    // Idempotent path: same file id, same size -> nothing to do.
    if (await ops.exists(target)) {
      final existing = await ops.sizeOf(target);
      if (existing == sourceBytes) {
        return DownloadMoveResult(
            path: target, bytes: existing, reused: true);
      }
      // A leftover with the wrong size is our own half-written artefact; the
      // pool copy is authoritative, so replace it.
      await ops.deleteFile(target);
    }

    final part = '$target.part';
    try {
      await ops.copyFile(sourcePath, part);
      final copied = await ops.sizeOf(part);
      if (copied != sourceBytes) {
        throw DownloadPromoteException(
          'copy',
          '复制后大小不符: copied=$copied source=$sourceBytes',
          path: part,
        );
      }
      await ops.rename(part, target);
    } on DownloadPromoteException {
      await _discard(part);
      rethrow;
    } catch (e) {
      await _discard(part);
      throw DownloadPromoteException('copy', e.toString(), path: sourcePath);
    }

    if (!await ops.exists(target)) {
      throw DownloadPromoteException(
          'verify', '重命名后目标文件不存在', path: target);
    }
    final finalBytes = await ops.sizeOf(target);
    if (finalBytes != sourceBytes) {
      throw DownloadPromoteException(
        'verify',
        '最终文件大小不符: final=$finalBytes source=$sourceBytes',
        path: target,
      );
    }

    return DownloadMoveResult(
        path: target, bytes: finalBytes, reused: false);
  }

  Future<void> _discard(String path) async {
    try {
      await ops.deleteFile(path);
    } catch (_) {
      // A stray `.part` is harmless and gets overwritten next run; never mask
      // the original failure with a cleanup error.
    }
  }
}
