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
import 'dart:io';

import '../td/td_client.dart';
import 'playback_trace.dart';
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
  VideoSourceTimeout(this.limit, {this.downloadedBytes = 0, this.expectedBytes = 0})
      : super(_message(limit, downloadedBytes, expectedBytes));

  final Duration limit;
  final int downloadedBytes;
  final int expectedBytes;

  /// The message carries the byte progress: "超时（15 秒）" alone hides whether
  /// the transfer was at 2% or 99%, and those need different advice.
  static String _message(Duration limit, int got, int expected) {
    if (expected <= 0) return '加载超时（${limit.inSeconds} 秒）';
    final percent = (got * 100 / expected).clamp(0, 100).toStringAsFixed(0);
    return '加载超时（${limit.inSeconds} 秒，已下载 ${got}B/'
        '${expected}B，$percent%）';
  }
}

class VideoSourceResolver {
  VideoSourceResolver({
    required this.api,
    this.fetchTimeout = const Duration(seconds: 15),
    this.progressInterval = const Duration(milliseconds: 120),
    Future<bool> Function(String path)? fileExists,
  }) : _fileExists = fileExists ?? _defaultFileExists;

  final FileTransferApi api;

  /// Checks that a path TDLib reports as "downloaded" still exists.
  ///
  /// TDLib's file database remembers a completed file even after the bytes are
  /// gone — the OS purges Library/Caches under pressure, and anything holding
  /// the pool (a cleaner, a jailbreak tool, a future TDLib LRU pass) can drop
  /// the file while the record still says 100%. Without this check the app
  /// hands AVPlayer a path that no longer exists and the user sees a decode
  /// error instead of "已被清理".
  final Future<bool> Function(String path) _fileExists;

  static Future<bool> _defaultFileExists(String path) => File(path).exists();

  /// §4.5: after 15 s the page must show "加载超时" with a retry, not spin.
  final Duration fetchTimeout;

  /// `updateFile` fires per chunk; rebuilding the page on every event costs
  /// more than the transfer. ~8 Hz is what the probe chain settled on.
  final Duration progressInterval;

  final Set<int> _cancelled = <int>{};

  /// One resolve per file id at a time.
  ///
  /// Two callers can race for the same item: the page starts the current video
  /// while the preload window is resolving its neighbour, and a rapid
  /// back-and-forth can land on the item that is already being fetched. Sharing
  /// the future means one `downloadFile`, one wait, one answer.
  final Map<int, Future<String>> _inflight = <int, Future<String>>{};

  /// Resolves [fileId] to an absolute path. Throws [VideoSourceTimeout] when
  /// the transfer does not complete in time and [VideoSourceException] for a
  /// TDLib error.
  Future<String> resolve(
    int fileId, {
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
  }) {
    final running = _inflight[fileId];
    if (running != null) return running;
    final future = _resolveOnce(fileId, onProgress: onProgress, trace: trace);
    _inflight[fileId] = future;
    return future.whenComplete(() => _inflight.remove(fileId));
  }

  /// How many resolves are in flight, for diagnostics and tests.
  int get inflightCount => _inflight.length;

  Future<String> _resolveOnce(
    int fileId, {
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
  }) async {
    _cancelled.remove(fileId);
    trace?.mark(PlaybackStage.resolveStarted);
    onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));

    final existing = await api.stat(fileId);
    if (existing != null) {
      trace?.mark(PlaybackStage.fileRecordKnown,
          bytes: existing.downloadedSize);
      if (existing.expectedSize > 0) trace?.expectedBytes = existing.expectedSize;
    }
    // A "completed" record is only a cache hit if the bytes are actually there
    // and the size agrees. TDLib occasionally reports completion for a record
    // whose file was removed or truncated; trusting it hands the player a dead
    // path and the failure surfaces as a decode error instead of a download.
    final sizeMatches = existing == null ||
        existing.expectedSize <= 0 ||
        existing.size >= existing.expectedSize;
    if (existing != null &&
        existing.isCompleted &&
        existing.path.isNotEmpty &&
        sizeMatches &&
        await _fileExists(existing.path)) {
      trace?.mark(PlaybackStage.fileReady, bytes: existing.size);
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
      if (state.isCompleted) {
        // Complete even when the path is empty: TDLib can report a finished
        // transfer with no local path, and waiting for a later update that
        // never comes would turn a clear error into a 15-second spinner.
        if (!completion.isCompleted) completion.complete(state);
        return;
      }
      final now = DateTime.now();
      if (state.downloadedSize > 0) {
        trace?.downloadedBytes = state.downloadedSize;
        trace?.mark(PlaybackStage.firstBytes, bytes: state.downloadedSize);
      }
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
      trace?.mark(PlaybackStage.downloadRequested);
      await api.start(fileId);

      final state = await completion.future.timeout(fetchTimeout);
      if (_cancelled.contains(fileId)) {
        throw VideoSourceException('已取消');
      }
      if (state.path.isEmpty) {
        // A "completed" file with no path means the player has nothing to
        // open. Fail here with the real reason instead of handing an empty
        // string to AVPlayer, which reports it as an unknown format error.
        throw VideoSourceException('TDLib 报告下载完成但没有返回本地路径');
      }
      trace?.mark(PlaybackStage.fileReady, bytes: state.size);
      if (!await _fileExists(state.path)) {
        // TDLib says done, the filesystem disagrees. Say so instead of handing
        // a dead path to AVPlayer, which would report it as a format error.
        throw VideoSourceException('本地文件已不存在（可能被系统或清理工具删除）');
      }
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.ready,
        downloadedBytes: state.size,
        expectedBytes: state.size,
        path: state.path,
      ));
      return state.path;
    } on TimeoutException {
      final got = trace?.downloadedBytes ?? 0;
      final expected = trace?.expectedBytes ?? 0;
      trace?.errorCategory = 'timeout';
      final failure = VideoSourceTimeout(
        fetchTimeout,
        downloadedBytes: got,
        expectedBytes: expected,
      );
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.failed,
        error: failure.message,
      ));
      // Stop the transfer we walked away from; leaving it running competes with
      // the next video for bandwidth.
      await cancel(fileId);
      throw failure;
    } on VideoSourceException catch (e) {
      trace?.errorCategory ??= e.runtimeType.toString();
      onProgress?.call(VideoSourceUpdate(stage: SourceStage.failed, error: e.message));
      rethrow;
    } on Object catch (e) {
      trace?.errorCategory ??= e.runtimeType.toString();
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
