/// Turns a TDLib `file_id` into a local path the player can open.
///
/// This is the streaming path, not a download feature: the bytes land in
/// TDLib's own pool under `Library/Caches/tgmedia/tdlib_files`, which is a
/// registered rebuildable cache writer. Nothing is copied into
/// `Documents/TGMediaDownloads`, no record is kept, and there is no UI for it —
/// §10 of the product spec cancels downloads as a user-facing feature while
/// keeping the transfer that playback needs.
///
/// Two behaviours matter for the "video never loads" class of bug:
/// * `getFile` runs first. A file already on disk resolves with no transfer at
///   all, so re-opening the same video is instant and does not re-download.
/// * A bounded timeout produces an explicit failure. Infinite spinners are
///   forbidden by the spec, so `resolve` never hangs.
library;

import 'dart:async';

import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

/// The only TDLib surface this file needs. Abstracted so the resolution logic
/// can be tested without a native library.
abstract class FileTransferApi {
  Future<FileState?> stat(int fileId);
  Future<void> start(int fileId);
  Future<void> cancel(int fileId);
  Stream<FileState> updates();
}

class TdFileTransferApi implements FileTransferApi {
  TdFileTransferApi(this.client);

  final TdClient client;

  @override
  Future<FileState?> stat(int fileId) async {
    final response = await client.request(
      getFile(fileId),
      timeout: const Duration(seconds: 20),
    );
    if (errorText(response) != null) return null;
    return fileFromResponse(response);
  }

  @override
  Future<void> start(int fileId) async {
    // priority 32 is the same value the probe chain uses: high enough to beat
    // thumbnail fetches, low enough not to starve the chat list.
    final response = await client.request(
      downloadFile(fileId: fileId),
      timeout: const Duration(seconds: 60),
    );
    final error = errorText(response);
    if (error != null) throw VideoSourceException(error);
  }

  @override
  Future<void> cancel(int fileId) async {
    try {
      await client.request(
        cancelDownloadFile(fileId: fileId),
        timeout: const Duration(seconds: 10),
      );
    } on Object {
      // Cancelling a transfer that already finished is not an error.
    }
  }

  @override
  Stream<FileState> updates() => client.fileUpdates.map(FileState.fromJson);
}

enum SourceStage { probing, fetching, ready, failed }

class VideoSourceUpdate {
  const VideoSourceUpdate({
    required this.stage,
    this.downloadedBytes = 0,
    this.expectedBytes = 0,
    this.path,
    this.error,
  });

  final SourceStage stage;
  final int downloadedBytes;
  final int expectedBytes;
  final String? path;
  final String? error;

  double get fraction {
    if (expectedBytes <= 0) return 0;
    final value = downloadedBytes / expectedBytes;
    return value.isNaN ? 0 : value.clamp(0, 1).toDouble();
  }

  @override
  String toString() => 'VideoSourceUpdate(${stage.name}, '
      '$downloadedBytes/$expectedBytes${path == null ? '' : ' → $path'})';
}

class VideoSourceException implements Exception {
  VideoSourceException(this.message);

  final String message;

  @override
  String toString() => 'VideoSourceException: $message';
}

class VideoSourceTimeout extends VideoSourceException {
  VideoSourceTimeout(this.limit) : super('加载超时（${limit.inSeconds} 秒）');

  final Duration limit;
}

class VideoSourceResolver {
  VideoSourceResolver({
    required this.api,
    this.fetchTimeout = const Duration(seconds: 15),
    this.progressInterval = const Duration(milliseconds: 120),
  });

  final FileTransferApi api;

  /// §4.5: after 15 s the page must show "加载超时" with a retry, not spin.
  final Duration fetchTimeout;

  /// `updateFile` fires per chunk; rebuilding the page on every event costs
  /// more than the transfer. ~8 Hz is what the probe chain settled on.
  final Duration progressInterval;

  final Set<int> _cancelled = <int>{};

  /// Resolves [fileId] to an absolute path. Throws [VideoSourceTimeout] when
  /// the transfer does not complete in time and [VideoSourceException] for a
  /// TDLib error.
  Future<String> resolve(
    int fileId, {
    void Function(VideoSourceUpdate update)? onProgress,
  }) async {
    _cancelled.remove(fileId);
    onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));

    final existing = await api.stat(fileId);
    if (existing != null && existing.isCompleted && existing.path.isNotEmpty) {
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.ready,
        downloadedBytes: existing.size,
        expectedBytes: existing.size,
        path: existing.path,
      ));
      return existing.path;
    }

    final expected = existing?.expectedSize ?? 0;
    final completion = Completer<FileState>();
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

    final subscription = api.updates().listen((state) {
      if (state.id != fileId) return;
      if (state.isCompleted && state.path.isNotEmpty) {
        if (!completion.isCompleted) completion.complete(state);
        return;
      }
      final now = DateTime.now();
      if (now.difference(lastEmit) < progressInterval) return;
      lastEmit = now;
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.fetching,
        downloadedBytes: state.downloadedSize,
        expectedBytes: expected > 0 ? expected : state.expectedSize,
      ));
    });

    try {
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.fetching,
        expectedBytes: expected,
      ));
      await api.start(fileId);

      final state = await completion.future.timeout(fetchTimeout);
      if (_cancelled.contains(fileId)) {
        throw VideoSourceException('已取消');
      }
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.ready,
        downloadedBytes: state.size,
        expectedBytes: state.size,
        path: state.path,
      ));
      return state.path;
    } on TimeoutException {
      final failure = VideoSourceTimeout(fetchTimeout);
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.failed,
        error: failure.message,
      ));
      // Stop the transfer we walked away from; leaving it running competes with
      // the next video for bandwidth.
      await cancel(fileId);
      throw failure;
    } on VideoSourceException catch (e) {
      onProgress?.call(VideoSourceUpdate(stage: SourceStage.failed, error: e.message));
      rethrow;
    } on Object catch (e) {
      onProgress?.call(VideoSourceUpdate(stage: SourceStage.failed, error: '$e'));
      throw VideoSourceException('$e');
    } finally {
      await subscription.cancel();
    }
  }

  /// Stops an in-flight transfer. Idempotent.
  Future<void> cancel(int fileId) async {
    _cancelled.add(fileId);
    await api.cancel(fileId);
  }

  /// Clears the cancellation marks so the same file can be resolved again.
  void reset() => _cancelled.clear();
}
