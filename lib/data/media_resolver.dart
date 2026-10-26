import 'dart:async';

import '../storage/download_mover.dart';
import '../storage/download_paths.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';
import 'media_record.dart';

class ResolveException implements Exception {
  const ResolveException(this.stage, this.message);

  /// `file-id`, `protected`, `download`, `timeout`, `promote`, `empty-file`
  final String stage;
  final String message;

  @override
  String toString() => 'ResolveException($stage): $message';
}

class ResolveProgress {
  const ResolveProgress(this.downloadedBytes, this.totalBytes);

  final int downloadedBytes;
  final int totalBytes;

  double get fraction =>
      totalBytes <= 0 ? 0 : (downloadedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isIndeterminate => totalBytes <= 0;
}

class ResolveResult {
  const ResolveResult({
    required this.path,
    required this.bytes,
    required this.reused,
  });

  /// Always inside `Documents/TGMediaDownloads` — never TDLib's own pool.
  final String path;
  final int bytes;

  /// True when the file was already promoted by an earlier run.
  final bool reused;
}

/// Turns a [MediaRecord] into a playable local path inside the user zone.
///
/// Two rules carried over from step 3 and enforced here:
///
/// * TDLib's own file store is a *cache*. The player never opens a path in
///   `Library/Caches/tgmedia/tdlib_files` — the bytes are promoted into
///   `Documents/TGMediaDownloads/<chat>/<name>_<fileId><ext>` first, so a later
///   cache clear cannot delete a video the user is watching.
/// * A file only counts as present when its size matches what TDLib reported.
///   A truncated leftover is re-fetched instead of played as a 3-second clip.
/// Why [MediaResolver.prefetch] does or does not talk to TDLib.
///
/// Pulled out as a plain function so the skip rules can be asserted without a
/// live client: a wrong answer here either wastes the user's data (fetching a
/// file that is already on disk) or hammers TDLib with duplicate requests.
enum PrefetchDecision {
  /// Start a low-priority background fetch.
  enqueue,

  /// Nothing to fetch: protected media is never pulled to the local zone.
  noFileId,
  protectedContent,

  /// Already handed to TDLib in this session.
  alreadyQueued,

  /// The promoted copy in the user zone is already complete.
  alreadyLocal,
}

PrefetchDecision decidePrefetch({
  required int fileId,
  required bool hasProtectedContent,
  required int expectedBytes,
  required bool alreadyQueued,
  required bool targetExists,
  required int targetBytes,
}) {
  if (fileId == 0) return PrefetchDecision.noFileId;
  if (hasProtectedContent) return PrefetchDecision.protectedContent;
  if (alreadyQueued) return PrefetchDecision.alreadyQueued;
  // A size mismatch means a previous promotion died mid-copy; the file is not
  // playable, so it is worth fetching again.
  if (targetExists && (expectedBytes <= 0 || targetBytes == expectedBytes)) {
    return PrefetchDecision.alreadyLocal;
  }
  return PrefetchDecision.enqueue;
}

class MediaResolver {
  MediaResolver({
    required this.client,
    required this.layout,
    required this.ops,
    DownloadMover? mover,
  }) : mover = mover ?? DownloadMover(layout: layout, ops: ops);

  final TdClient client;
  final StorageLayout layout;
  final FileOps ops;
  final DownloadMover mover;

  /// In-flight resolutions, keyed by `chatId:messageId`, so two widgets asking
  /// for the same video share one download instead of racing each other.
  final Map<String, Future<ResolveResult>> _inFlight =
      <String, Future<ResolveResult>>{};

  /// Keys already handed to TDLib as a background fetch.
  final Set<String> _prefetched = <String>{};

  /// Starts a low-priority background fetch for a clip the user has not
  /// swiped to yet.
  ///
  /// Priority 1 is the lowest TDLib accepts and the on-screen clip asks for 32,
  /// so this cannot starve playback. Nothing is awaited and no completion is
  /// tracked: if it fails or is cancelled, [ensureLocal] simply fetches the
  /// file again when the user actually arrives. This is the only lever that
  /// makes a swipe feel instant without giving up the whole-file download that
  /// the size check and the zone promotion are built on.
  Future<void> prefetch(MediaRecord record) async {
    if (record.fileId == 0 || record.hasProtectedContent) return;
    if (_prefetched.contains(record.key)) return;

    var targetExists = false;
    var targetBytes = 0;
    try {
      final target = targetPathOf(record);
      if (await ops.exists(target)) {
        targetExists = true;
        targetBytes = await ops.sizeOf(target);
      }
    } catch (_) {
      // A stat failure must not cancel the fetch; treat it as "not local".
    }

    final decision = decidePrefetch(
      fileId: record.fileId,
      hasProtectedContent: record.hasProtectedContent,
      expectedBytes: record.sizeBytes,
      alreadyQueued: false,
      targetExists: targetExists,
      targetBytes: targetBytes,
    );
    if (decision != PrefetchDecision.enqueue) return;
    // Reserve before the await: two tiles asking for the same neighbour in the
    // same frame must produce one request, not two.
    if (!_prefetched.add(record.key)) return;

    try {
      await client.request(
        downloadFile(fileId: record.fileId, priority: 1, synchronous: false),
        timeout: const Duration(seconds: 20),
      );
    } catch (_) {
      // Best effort. A failed prefetch must never surface to the user; the
      // activation path owns the real error reporting.
      _prefetched.remove(record.key);
    }
  }

  Future<ResolveResult> ensureLocal(
    MediaRecord record, {
    void Function(ResolveProgress)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) {
    final key = record.key;
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _resolve(record, onProgress, timeout);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// Absolute target inside the user zone, whether or not it exists yet.
  String targetPathOf(MediaRecord record) => userDownloadPath(
        downloadsRoot: layout.downloadsDir,
        chatId: record.chatId,
        fileId: record.fileId,
        fileName: record.fileName,
        mimeType: record.mimeType,
      );

  Future<ResolveResult> _resolve(
    MediaRecord record,
    void Function(ResolveProgress)? onProgress,
    Duration timeout,
  ) async {
    final target = targetPathOf(record);

    if (await ops.exists(target)) {
      final size = await ops.sizeOf(target);
      if (record.sizeBytes <= 0 || size == record.sizeBytes) {
        return ResolveResult(path: target, bytes: size, reused: true);
      }
      // Wrong size: a previous run died mid-copy. Remove it so the promotion
      // below writes into a clean path.
      try {
        await ops.deleteFile(target);
      } catch (_) {
        // If it cannot be removed the promotion will fail loudly on its own.
      }
    }

    if (record.fileId == 0) {
      throw const ResolveException('file-id', '该消息没有可用的 fileId');
    }
    if (record.hasProtectedContent) {
      throw const ResolveException('protected', '该内容受保护，无法下载到本地');
    }

    final completion = Completer<FileState>();
    late final StreamSubscription<Map<String, Object?>> subscription;
    subscription = client.fileUpdates.listen((file) {
      final state = FileState.fromJson(file);
      if (state.id != record.fileId) return;
      onProgress?.call(ResolveProgress(state.downloadedSize, state.expectedSize));
      if (state.isCompleted && !completion.isCompleted) {
        completion.complete(state);
      }
    });

    try {
      final response = await client.request(
        downloadFile(fileId: record.fileId, synchronous: false),
        timeout: const Duration(seconds: 60),
      );
      final error = errorText(response);
      if (error != null) throw ResolveException('download', error);

      final FileState state;
      try {
        state = await completion.future.timeout(timeout);
      } on TimeoutException {
        throw const ResolveException('timeout', '下载超时，已继续等待下次重试');
      }

      if (state.path.isEmpty) {
        throw const ResolveException('empty-file', 'TDLib 报告完成但没有本地路径');
      }

      final moved = await mover.promote(
        sourcePath: state.path,
        chatId: record.chatId,
        fileId: record.fileId,
        expectedBytes: record.sizeBytes > 0 ? record.sizeBytes : state.size,
        fileName: record.fileName,
        mimeType: record.mimeType,
      );
      return ResolveResult(
        path: moved.path,
        bytes: moved.bytes,
        reused: moved.reused,
      );
    } on DownloadPromoteException catch (e) {
      throw ResolveException('promote', e.message);
    } finally {
      await subscription.cancel();
    }
  }
}
