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
/// * The wait is bounded by **progress**, not by wall-clock. A 200 MB video on
///   a slow link is not a failure; twelve seconds with zero bytes arriving is.
///   Two separate limits enforce that:
///   - [VideoSourceResolver.stallTimeout] — no byte growth for this long means
///     the transfer is dead, and the UI may say "网络中断";
///   - [VideoSourceResolver.taskTimeout] — absolute ceiling, so a transfer that
///     trickles forever still ends with an explicit message instead of an
///     infinite spinner.
library;

import 'dart:async';
import 'dart:io';

import '../data/media_record.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';
import 'media_metadata.dart';
import 'playback_trace.dart';
import 'stream_proxy.dart';
import 'streaming_diagnostics.dart';

/// The only TDLib surface this file needs. Abstracted so the resolution logic
/// can be tested without a native library.
abstract class FileTransferApi {
  Future<FileState?> stat(int fileId);
  Future<void> start(int fileId);
  Future<void> cancel(int fileId);
  Stream<FileState> updates();

  /// Points the TDLib download window at [offset]..[offset+limit].
  ///
  /// TDLib keeps ONE active download per file: a new request with a different
  /// offset/limit replaces the running one (td_api.tl, downloadFile). This is
  /// what lets the proxy serve a range AVPlayer asked for *now* — e.g. the
  /// tail of the file during a moov probe — instead of waiting for the
  /// sequential download to crawl there.
  Future<void> startRange(int fileId, {required int offset, required int limit});
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
  Future<void> startRange(
    int fileId, {
    required int offset,
    required int limit,
  }) async {
    // Priority 16: a range the player is blocked on outranks prefetches but
    // stays below the "start playing" transfer. TDLib aligns offset handling
    // internally; the caller passes byte-exact windows.
    final response = await client.request(
      downloadFile(fileId: fileId, offset: offset, limit: limit, priority: 16),
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

/// What [VideoSourceResolver.resolveStream] hands the player.
///
/// Two shapes, decided by data rather than by hope:
/// * **file** — the whole video is already in the TDLib pool. The player opens
///   the path directly, no proxy, exactly the old fast path.
/// * **stream** — the video is still downloading. The player opens a
///   `http://127.0.0.1/<token>` URL served by [StreamProxyServer], which maps
///   HTTP Range requests onto the bytes TDLib has written so far and waits
///   (bounded) for the rest. The download keeps running behind the play and
///   ends as a complete cache entry.
class PlaySource {
  const PlaySource.file(this.path)
      : url = path,
        isStreaming = false,
        proxy = null;

  const PlaySource.stream(this.url, this.path, this.proxy)
      : isStreaming = true;

  /// What the player opens: a local path (file mode) or a loopback URL
  /// (stream mode). Never a Telegram cloud URL.
  final String url;

  /// The local file backing the play — the TDLib pool entry. The cache
  /// cleaner checks this path against the in-use registry.
  final String path;

  final bool isStreaming;

  /// Non-null in stream mode. The owner must call [dispose] when the play
  /// ends so the listener and its port are freed.
  final StreamProxyServer? proxy;

  Future<void> dispose() async {
    await proxy?.stop();
  }

  @override
  String toString() => isStreaming
      ? 'PlaySource.stream(file=${path.hashCode})'
      : 'PlaySource.file(${path.hashCode})';
}

/// The absolute ceiling was hit: the transfer was still being attempted when
/// the task budget ran out. Not a network verdict — a big file on a slow link
/// reaches this, and so does a stuck server.
class VideoSourceTimeout extends VideoSourceException {
  VideoSourceTimeout(
    this.limit, {
    this.downloadedBytes = 0,
    this.expectedBytes = 0,
  }) : super(_message(limit, downloadedBytes, expectedBytes));

  VideoSourceTimeout._(
    this.limit,
    this.downloadedBytes,
    this.expectedBytes,
    String message,
  ) : super(message);

  final Duration limit;
  final int downloadedBytes;
  final int expectedBytes;

  /// True when the failure was "nothing arrived for a while", false when it was
  /// "the whole task ran out of time". The two need different screens: the
  /// first is a network verdict, the second is not.
  bool get isStall => false;

  /// The message carries the byte progress: "超时（15 秒）" alone hides whether
  /// the transfer was at 2% or 99%, and those need different advice.
  static String _message(Duration limit, int got, int expected) {
    if (expected <= 0) return '加载超时（${limit.inSeconds} 秒）';
    final percent = (got * 100 / expected).clamp(0, 100).toStringAsFixed(0);
    return '加载超时（${limit.inSeconds} 秒，已下载 ${got}B/'
        '${expected}B，$percent%）';
  }
}

/// No byte arrived for [quiet] seconds. This is the only timeout that may be
/// reported as a network problem.
class VideoSourceStalled extends VideoSourceTimeout {
  VideoSourceStalled(
    Duration quiet, {
    int downloadedBytes = 0,
    int expectedBytes = 0,
  }) : super._(
          quiet,
          downloadedBytes,
          expectedBytes,
          _stalledMessage(quiet, downloadedBytes, expectedBytes),
        );

  @override
  bool get isStall => true;

  static String _stalledMessage(Duration quiet, int got, int expected) {
    final waited = '${quiet.inSeconds} 秒';
    if (got <= 0) {
      return '等待 $waited 仍未收到任何数据';
    }
    if (expected <= 0) {
      return '等待 $waited 没有新数据（已下载 ${got}B）';
    }
    final percent = (got * 100 / expected).clamp(0, 100).toStringAsFixed(0);
    return '等待 $waited 没有新数据（已下载 ${got}B/${expected}B，$percent%）';
  }
}

class VideoSourceResolver {
  VideoSourceResolver({
    required this.api,
    this.metadata,
    this.stallTimeout = const Duration(seconds: 15),
    this.taskTimeout = const Duration(minutes: 10),
    this.retryDelays = const <Duration>[
      Duration(milliseconds: 300),
      Duration(milliseconds: 900),
    ],
    this.progressInterval = const Duration(milliseconds: 120),
    this.startupBufferBytes = StreamProxyServer.defaultStartupBufferBytes,
    this.proxyFactory,
    Future<bool> Function(String path)? fileExists,
    StreamingDiagnostics? diagnostics,
  })  : _fileExists = fileExists ?? _defaultFileExists,
        _diagnostics = diagnostics ?? StreamingDiagnostics.instance;

  final FileTransferApi api;

  /// Where the streaming evidence for the current play is recorded. Defaults to
  /// the process-wide instance so the overlay and the settings panel see the
  /// same numbers the resolver produced; tests inject their own.
  final StreamingDiagnostics _diagnostics;

  /// Used to repair stale metadata: a rejected `file_id` is re-read from the
  /// message, and a missing file name is filled in the same way.
  final MediaMetadataLookup? metadata;

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

  /// No byte growth for this long = the transfer is dead. This replaces the old
  /// fixed 15-second cap on the whole download, which failed every large video
  /// on a slow link and reported it as "网络不可用".
  final Duration stallTimeout;

  /// Absolute ceiling for one resolve. Bounded on purpose: the spec forbids an
  /// infinite spinner, and "it has been downloading for an hour" is not a state
  /// the user can act on.
  final Duration taskTimeout;

  /// Backoff for transient TDLib failures (`FLOOD_WAIT`, 500, connection
  /// reset). Two attempts is enough: anything longer is a server problem the
  /// user should see, not something to hide behind a spinner.
  final List<Duration> retryDelays;

  /// `updateFile` fires per chunk; rebuilding the page on every event costs
  /// more than the transfer. ~8 Hz is what the probe chain settled on.
  final Duration progressInterval;

  final Set<int> _cancelled = <int>{};

  /// One resolve per file id at a time — shared by [resolve] and
  /// [resolveStream].
  ///
  /// Two callers can race for the same item: the page starts the current video
  /// while the preload window is resolving its neighbour, and a rapid
  /// back-and-forth can land on the item that is already being fetched. Sharing
  /// the future means one `downloadFile`, one wait, one answer.
  ///
  /// Only *successful* work is shared: the entry is removed when the future
  /// settles, whatever the outcome, so a failed resolve is never replayed from
  /// this map. A permanent failure has to be retried by the caller — and the
  /// caller may legitimately do so after the file id was refreshed.
  final Map<int, Future<PlaySource>> _inflight = <int, Future<PlaySource>>{};

  /// Resolves [fileId] to an absolute path (the full-download contract).
  ///
  /// Kept as the fallback path and the prefetch path; the feed's current video
  /// uses [resolveStream]. The dedupe is shared, so a stream resolve that is
  /// already running for this id is awaited rather than doubled.
  ///
  /// Throws [VideoSourceStalled] when no byte arrives, [VideoSourceTimeout]
  /// when the task ceiling is hit, and [VideoSourceException] for a TDLib error.
  Future<String> resolve(
    int fileId, {
    int? chatId,
    int? messageId,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,

    /// True when this resolve *is* the play the user is watching. A prefetch
    /// must not move the diagnostics panel: the number there has to describe
    /// the video on screen, not a neighbour warming up in the background.
    bool forPlayback = false,
  }) {
    final running = _inflight[fileId];
    if (running != null) return running.then((source) => source.path);
    if (forPlayback) {
      _diagnostics.beginPlay(
        fileId: fileId,
        streaming: false,
        chatId: chatId,
        messageId: messageId,
      );
    }
    final future = _resolveWithRepair(
      fileId,
      chatId: chatId,
      messageId: messageId,
      onProgress: onProgress,
      trace: trace,
      onRecordRefreshed: onRecordRefreshed,
      report: forPlayback,
    ).then((path) => PlaySource.file(path));
    _inflight[fileId] = future;
    return future
        .whenComplete(() => _inflight.remove(fileId))
        .then((source) => source.path);
  }

  /// How many resolves are in flight, for diagnostics and tests.
  int get inflightCount => _inflight.length;

  /// Minimum readable bytes before the streaming path hands the player its
  /// URL. Parameterised, never hard-coded into the flow: 2 MB is the default
  /// the numbers justify, and a test can shrink it to nothing.
  final int startupBufferBytes;

  /// Injectable proxy constructor so tests can pass a pre-built server
  /// (bound to a controlled port) instead of letting production bind one.
  final StreamProxyServer Function(
    FileProgressWatch watch,
    String localPath,
  )? proxyFactory;

  /// Resolves [fileId] for **playback**, choosing between three paths by data:
  ///
  /// * complete cache → [PlaySource.file] (no proxy, the old fast path);
  /// * still downloading → [PlaySource.stream] backed by a loopback HTTP range
  ///   proxy: the play starts once [startupBufferBytes] are on disk and the
  ///   download keeps running behind it until `is_downloading_completed`;
  /// * anything that makes streaming impossible (proxy cannot bind, size
  ///   unknown, no local path) → the caller falls back to [resolve], which is
  ///   the full-download wait with all of its watchdogs.
  ///
  /// Shares the [_inflight] dedupe with [resolve]: one `downloadFile` per file
  /// id, whatever the entry point.
  Future<PlaySource> resolveStream(
    int fileId, {
    int? chatId,
    int? messageId,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
  }) {
    final running = _inflight[fileId];
    if (running != null) return running;
    final future = _streamWithRepair(
      fileId,
      chatId: chatId,
      messageId: messageId,
      onProgress: onProgress,
      trace: trace,
      onRecordRefreshed: onRecordRefreshed,
    );
    _inflight[fileId] = future;
    return future.whenComplete(() => _inflight.remove(fileId));
  }

  /// The streaming loop. Same repair/backoff shape as [_resolveWithRepair]:
  /// a rejected file id is re-read from the message once, transient TDLib
  /// errors get the bounded retry, everything else propagates to the caller.
  Future<PlaySource> _streamWithRepair(
    int fileId, {
    int? chatId,
    int? messageId,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
  }) async {
    var activeId = fileId;
    var retries = 0;
    var repaired = false;

    while (true) {
      try {
        return await _streamOnce(
          activeId,
          chatId: chatId,
          messageId: messageId,
          onProgress: onProgress,
          trace: trace,
        );
      } on _MissingFile catch (e) {
        final canRepair =
            !repaired && metadata != null && chatId != null && messageId != null;
        if (!canRepair) {
          trace?.errorCategory = 'fileMissing';
          throw VideoSourceException(
            '文件已失效（TDLib 返回 ${e.message}），无法从消息重新获取',
          );
        }
        repaired = true;
        final fresh = await metadata!.fetch(chatId, messageId);
        trace?.mark(PlaybackStage.metadataFetched);
        if (fresh == null || fresh.fileId == 0) {
          trace?.errorCategory = 'fileMissing';
          throw VideoSourceException('文件已失效（TDLib 返回 ${e.message}），消息里也取不到新文件');
        }
        if (fresh.fileId != activeId) {
          activeId = fresh.fileId;
          trace?.mark(PlaybackStage.fileIdRefreshed, bytes: fresh.sizeBytes);
          trace?.note = 'file_id 已从消息重新获取';
          trace?.errorCategory = null;
        }
        onRecordRefreshed?.call(fresh);
        continue;
      } on VideoSourceStalled {
        rethrow;
      } on VideoSourceTimeout {
        rethrow;
      } on VideoSourceException catch (e) {
        if (retries >= retryDelays.length || !_isTransient(e.message)) rethrow;
        trace?.retries = ++retries;
        onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));
        await Future<void>.delayed(retryDelays[retries - 1]);
        continue;
      }
    }
  }

  /// One streaming attempt: stat, gate on a complete cache, otherwise start
  /// the download and open the proxy once the startup buffer is on disk.
  Future<PlaySource> _streamOnce(
    int fileId, {
    int? chatId,
    int? messageId,
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
    // Start of a new play's evidence: ids and total come from TDLib's own file
    // record, never from a UI assumption. `streamingEnabled` flips to true
    // later, only if the resolver really takes the streaming branch.
    _diagnostics.beginPlay(
      fileId: fileId,
      streaming: false,
      chatId: chatId,
      messageId: messageId,
      totalBytes: existing?.expectedSize ?? 0,
    );
    if (existing != null) {
      _diagnostics.updateTransfer(
        downloadedBytes: existing.downloadedSize,
        totalBytes: existing.expectedSize,
        downloadOffset: existing.downloadOffset,
        completed: existing.isCompleted,
        isDownloading: !existing.isCompleted,
      );
    }
    // Cache hit check is byte-identical to the full-download path: a complete
    // record with wrong size or a vanished file is NOT a hit — those videos
    // stream (or re-download), they never get a truncated player.
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
      return PlaySource.file(existing.path);
    }

    // A record without a size cannot be streamed honestly: there is no total
    // to advertise in Content-Range. Fall back before touching the transfer.
    if (existing != null && existing.expectedSize <= 0) {
      trace?.mark(PlaybackStage.streamingModeSelected);
      trace?.errorCategory = 'streamingUnavailable';
      throw VideoSourceException('流式播放不可用（文件大小未知）');
    }

    trace?.mark(PlaybackStage.streamingModeSelected);
    _diagnostics.noteStreamingSelected();
    final watch = _LiveFileWatch(
      api,
      fileId,
      initial: existing,
      onState: _diagnostics.updateTransferFromState,
    );

    StreamProxyServer? proxy;
    try {
      trace?.mark(PlaybackStage.downloadRequested);
      // downloadFile answers as soon as TDLib accepts the transfer (a rejected
      // file id fails here and feeds the repair loop); the bytes arrive
      // through the update stream the watcher is already consuming.
      await api.start(fileId);

      // Startup gate: wait until the player can be handed a stream that will
      // not immediately stall. min(buffer, whole file) — a 400 KB clip must
      // not wait for an artificial 2 MB.
      final expected = watch.expectedBytes;
      final target = expected > 0 && expected < startupBufferBytes
          ? expected
          : startupBufferBytes;
      if (watch.headBytes < target) {
        onProgress?.call(VideoSourceUpdate(
          stage: SourceStage.fetching,
          downloadedBytes: watch.headBytes,
          expectedBytes: watch.expectedBytes,
        ));
        await _waitForStartup(watch, target);
      }
      trace?.mark(PlaybackStage.startupBufferReached, bytes: watch.headBytes);

      // The proxy reads the local file; by now TDLib has named it. If it has
      // not, there is nothing to serve — the caller falls back.
      final localPath = watch.localPath;
      if (localPath.isEmpty) {
        trace?.errorCategory = 'streamingUnavailable';
        throw VideoSourceException('流式播放不可用（下载未产生本地文件）');
      }

      proxy = (proxyFactory ?? ((w, p) => _defaultProxy(w, p, trace)))(watch, localPath);
      final url = await proxy.start();
      trace?.mark(PlaybackStage.streamingProxyStarted);
      // When the play ends (or the resolver is torn down) the watch dies with
      // the proxy: one subscription, one owner, no leak.
      proxy.onClose(watch.dispose);

      // Record when the background download finishes. This is the "完整下载：
      // Y 秒" number; the play itself started at [startupBufferReached].
      unawaited(() async {
        try {
          await watch.progress
              .firstWhere((_) => watch.isComplete)
              .timeout(const Duration(minutes: 30));
          if (watch.isComplete) {
            trace?.mark(PlaybackStage.fileCompleted,
                bytes: watch.expectedBytes);
            _diagnostics.noteCompleted(totalBytes: watch.expectedBytes);
          }
        } on Object {
          // The completion marker is diagnostics, not playback: a closed
          // stream or a timeout here must not disturb the play.
        }
      }());

      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.fetching,
        downloadedBytes: watch.headBytes,
        expectedBytes: watch.expectedBytes,
      ));
      return PlaySource.stream(url.toString(), localPath, proxy);
    } on Object catch (e) {
      // Anything that went wrong after the download started leaves the
      // watcher and the proxy behind; close them before the caller's fallback
      // path starts a second transfer.
      if (proxy != null) {
        await proxy.stop();
      } else {
        await watch.dispose();
      }
      // A rejected file id must reach the repair loop as [_MissingFile], the
      // same conversion the full-download path performs on its errors.
      final text = '$e';
      if (_looksMissing(text.toUpperCase())) throw _MissingFile(text);
      rethrow;
    }
  }

  StreamProxyServer _defaultProxy(
    FileProgressWatch watch,
    String localPath,
    PlaybackTrace? trace,
  ) =>
      StreamProxyServer(
        watch: watch,
        startupBufferBytes: startupBufferBytes,
        stallTimeout: stallTimeout,
        onEvent: (event) {
          // The proxy log is the only way to answer "which Range failed and
          // why" after a device run — without it the answer is a guess.
          trace?.noteProxy(event);
        },
        // Structured mirrors of the same events: the diagnostics panel and the
        // streaming verdict read these, so they cannot be shaped by a string.
        onRangeRequest: ({required from, required to}) {
          _diagnostics.noteRangeRequest(from: from, to: to);
          trace?.mark(PlaybackStage.firstRangeRequest);
        },
        onResponse: ({
          required status,
          required from,
          required end,
          required total,
          required length,
        }) {
          _diagnostics.noteResponse(
            status: status,
            from: from,
            end: end,
            total: total,
            length: length,
          );
          if (status == 206) trace?.mark(PlaybackStage.first206Response);
        },
        onWindowMove: ({required start, required end}) {
          _diagnostics.noteWindowMove(start, end);
        },
        onStall: _diagnostics.noteStall,
      );

  /// Waits for the startup buffer with the same two rules as the transfer
  /// wait: every TDLib event resets the stall timer (slow is not failed);
  /// silence for [stallTimeout] is the only network verdict.
  Future<void> _waitForStartup(FileProgressWatch watch, int target) async {
    final stall = Completer<void>();
    Timer? stallTimer;
    void arm() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        if (watch.headBytes < target && !watch.isComplete) {
          if (!stall.isCompleted) stall.complete();
        }
      });
    }

    arm();
    late final StreamSubscription<void> sub;
    sub = watch.progress.listen((_) {
      if (watch.headBytes >= target || watch.isComplete) {
        if (!stall.isCompleted) stall.complete();
      } else {
        arm(); // 有动静：慢，但不是失败
      }
    });
    try {
      await stall.future;
    } finally {
      stallTimer?.cancel();
      await sub.cancel();
    }
    if (watch.headBytes < target && !watch.isComplete) {
      throw VideoSourceStalled(
        stallTimeout,
        downloadedBytes: watch.headBytes,
        expectedBytes: watch.expectedBytes,
      );
    }
  }

  /// True when [path] is still on disk. Used before trusting a prefetched path:
  /// a prefetch can be minutes old, and the OS may have purged the pool.
  Future<bool> isUsable(String path) => _fileExists(path);

  /// Runs one resolve, repairing the file id at most once.
  ///
  /// The loop is deliberately tiny: a stale id is re-read from the message, a
  /// transient error is retried with backoff, and every other outcome is thrown
  /// with the real reason. There is no unbounded retry anywhere.
  Future<String> _resolveWithRepair(
    int fileId, {
    int? chatId,
    int? messageId,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
    bool report = false,
  }) async {
    var activeId = fileId;
    var retries = 0;
    var repaired = false;

    while (true) {
      try {
        return await _resolveOnce(
          activeId,
          onProgress: onProgress,
          trace: trace,
          report: report,
        );
      } on _MissingFile catch (e) {
        // The id is stale. Re-read the message once and try the id it carries.
        final canRepair = !repaired && metadata != null && chatId != null && messageId != null;
        if (!canRepair) {
          trace?.errorCategory = 'fileMissing';
          throw VideoSourceException(
            '文件已失效（TDLib 返回 ${e.message}），无法从消息重新获取',
          );
        }
        repaired = true;
        final fresh = await metadata!.fetch(chatId, messageId);
        trace?.mark(PlaybackStage.metadataFetched);
        if (fresh == null || fresh.fileId == 0) {
          trace?.errorCategory = 'fileMissing';
          throw VideoSourceException('文件已失效（TDLib 返回 ${e.message}），消息里也取不到新文件');
        }
        if (fresh.fileId != activeId) {
          activeId = fresh.fileId;
          trace?.mark(PlaybackStage.fileIdRefreshed, bytes: fresh.sizeBytes);
          trace?.note = 'file_id 已从消息重新获取';
          trace?.errorCategory = null;
        }
        // The fresh record also carries the file name and size the mirror was
        // missing; the caller persists it so the next play starts correct.
        onRecordRefreshed?.call(fresh);
        continue;
      } on VideoSourceStalled {
        // A quiet transfer is not retried here: the caller may retry the whole
        // item, and doubling the wait silently would hide the network state.
        rethrow;
      } on VideoSourceTimeout {
        rethrow;
      } on VideoSourceException catch (e) {
        if (retries >= retryDelays.length || !_isTransient(e.message)) rethrow;
        trace?.retries = ++retries;
        onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));
        await Future<void>.delayed(retryDelays[retries - 1]);
        continue;
      }
    }
  }

  /// A TDLib error that another attempt could plausibly fix.
  static bool _isTransient(String message) {
    final upper = message.toUpperCase();
    if (_looksMissing(upper)) return false;
    return upper.contains('FLOOD_WAIT') ||
        upper.contains('INTERNAL') ||
        upper.contains('CONNECTION') ||
        upper.contains('TIMEOUT') ||
        upper.contains('TRY AGAIN') ||
        upper.contains('500') ||
        upper.contains('503');
  }

  static bool _looksMissing(String upper) =>
      upper.contains('FILE NOT FOUND') ||
      upper.contains('FILE_ID_INVALID') ||
      upper.contains('FILE_REFERENCE') ||
      upper.contains('FILE_IS_DELETED') ||
      upper.contains('FILE_UNAVAILABLE');

  Future<String> _resolveOnce(
    int fileId, {
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    bool report = false,
  }) async {
    _cancelled.remove(fileId);
    trace?.mark(PlaybackStage.resolveStarted);
    onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));

    final existing = await api.stat(fileId);
    if (existing != null) {
      trace?.mark(PlaybackStage.fileRecordKnown,
          bytes: existing.downloadedSize);
      if (existing.expectedSize > 0) trace?.expectedBytes = existing.expectedSize;
      if (report) {
        _diagnostics.updateTransfer(
          downloadedBytes: existing.downloadedSize,
          totalBytes: existing.expectedSize,
          downloadOffset: existing.downloadOffset,
          completed: existing.isCompleted,
          isDownloading: !existing.isCompleted,
        );
      }
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

    var expected = existing?.expectedSize ?? 0;
    final completion = Completer<FileState>();
    // Aborts the wait without pretending the transfer finished. Both watchdogs
    // complete this one: the outcome is "no usable answer", and the exception
    // type says which limit fired.
    final abort = Completer<FileState>();
    final winner = Future.any(<Future<FileState>>[completion.future, abort.future]);
    var got = existing?.downloadedSize ?? 0;
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    Timer? quietTimer;
    Timer? ceilingTimer;

    void armQuiet() {
      quietTimer?.cancel();
      quietTimer = Timer(stallTimeout, () {
        if (abort.isCompleted) return;
        abort.completeError(
          VideoSourceStalled(stallTimeout,
              downloadedBytes: got, expectedBytes: expected),
        );
      });
    }

    final subscription = api.updates().listen((state) {
      if (state.id != fileId) return;
      if (report) {
        _diagnostics.updateTransfer(
          downloadedBytes: state.downloadedSize,
          totalBytes: state.expectedSize,
          downloadOffset: state.downloadOffset,
          completed: state.isCompleted,
        );
      }
      if (state.isCompleted) {
        // Complete even when the path is empty: TDLib can report a finished
        // transfer with no local path, and waiting for a later update that
        // never comes would turn a clear error into a long spinner.
        if (!completion.isCompleted) completion.complete(state);
        if (report) _diagnostics.noteCompleted(totalBytes: expected);
        return;
      }
      if (state.expectedSize > 0) expected = state.expectedSize;
      // Any growth is progress and re-arms the quiet watchdog; that is what
      // makes a large download on a slow link survive.
      if (state.downloadedSize > got) {
        got = state.downloadedSize;
        if (trace != null) {
          trace.downloadedBytes = got;
          if (!trace.has(PlaybackStage.firstBytes)) {
            trace.mark(PlaybackStage.firstBytes, bytes: got);
          }
        }
        armQuiet();
      }
      final now = DateTime.now();
      if (now.difference(lastEmit) < progressInterval) return;
      lastEmit = now;
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.fetching,
        downloadedBytes: got,
        expectedBytes: expected,
      ));
    });

    // Armed through a closure on purpose: the analyzer would otherwise promote
    // the field to non-null and flag the `?.cancel()` in the finally block.
    void armCeiling() {
      ceilingTimer = Timer(taskTimeout, () {
        if (abort.isCompleted) return;
        abort.completeError(
          VideoSourceTimeout(taskTimeout,
              downloadedBytes: got, expectedBytes: expected),
        );
      });
    }

    armCeiling();
    armQuiet();

    try {
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.fetching,
        expectedBytes: expected,
      ));
      trace?.mark(PlaybackStage.downloadRequested);
      // `winner` already listens to `abort`, so a watchdog firing during
      // `start()` cannot become an unhandled error.
      try {
        await api.start(fileId);
      } on Object {
        // The abort future is nobody's business now; mark it handled so a late
        // watchdog does not surface as an unhandled async error.
        winner.ignore();
        rethrow;
      }

      final state = await winner;
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
    } on VideoSourceStalled catch (e) {
      trace?.errorCategory = 'stalled';
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.failed,
        downloadedBytes: e.downloadedBytes,
        expectedBytes: e.expectedBytes,
        error: e.message,
      ));
      // Stop the transfer we walked away from; leaving it running competes with
      // the next video for bandwidth.
      await cancel(fileId);
      rethrow;
    } on VideoSourceTimeout catch (e) {
      trace?.errorCategory = 'taskTimeout';
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.failed,
        downloadedBytes: e.downloadedBytes,
        expectedBytes: e.expectedBytes,
        error: e.message,
      ));
      await cancel(fileId);
      rethrow;
    } on VideoSourceException catch (e) {
      trace?.errorCategory ??= e.runtimeType.toString();
      onProgress?.call(VideoSourceUpdate(stage: SourceStage.failed, error: e.message));
      // A rejected file id is recoverable by re-reading the message; signal it
      // with a type the outer loop understands, and keep the TDLib text.
      if (_looksMissing(e.message.toUpperCase())) {
        throw _MissingFile(e.message);
      }
      rethrow;
    } on Object catch (e) {
      trace?.errorCategory ??= e.runtimeType.toString();
      onProgress?.call(VideoSourceUpdate(stage: SourceStage.failed, error: '$e'));
      final text = '$e';
      if (_looksMissing(text.toUpperCase())) throw _MissingFile(text);
      throw VideoSourceException(text);
    } finally {
      quietTimer?.cancel();
      ceilingTimer?.cancel();
      winner.ignore();
      await subscription.cancel();
      // The completion completer is never completed on the abort path; releasing
      // it here keeps the pair in sync.
      if (!completion.isCompleted) completion.completeError(_Abandoned());
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

/// Internal signal: TDLib rejected the file id. Never escapes this library —
/// [_resolveWithRepair] turns it into a repair attempt or a real message.
class _MissingFile implements Exception {
  _MissingFile(this.message);

  final String message;

  @override
  String toString() => '_MissingFile: $message';
}

/// The proxy's window onto a TDLib download.
///
/// TDLib downloads a *window*, not always the whole file from 0:
/// `downloaded_size` counts from `download_offset`, and a new `downloadFile`
/// with a different offset/limit replaces the running one. This watcher tracks
/// that window and can steer it — which is what lets the proxy serve a tail
/// range (moov probe) or an arbitrary seek in seconds instead of waiting for
/// the sequential download to crawl there.
///
/// Backed by the same `updateFile` stream the wait loop consumes, filtered to
/// one file id. Progress without a local path is ignored on purpose — the
/// proxy reads that exact file, so bytes without a path are numbers, not data.
class _LiveFileWatch implements FileProgressWatch {
  _LiveFileWatch(
    this._api,
    this._fileId, {
    required FileState? initial,
    this.onState,
  }) {
    if (initial != null && initial.path.isNotEmpty) {
      _path = initial.path;
      _windowOffset = initial.downloadOffset;
      _prefix = initial.downloadedSize;
    }
    _expected = initial?.expectedSize ?? 0;
    _complete = initial?.isCompleted == true && _path.isNotEmpty;
    _canDownload = initial?.canBeDownloaded ?? true;
    _subscription = _api.updates().listen(
          _onState,
          onDone: () {
            if (!_changes.isClosed) _changes.close();
          },
          onError: (Object _) {
            // The resolver's error paths own failure reporting; a broken
            // update stream leaves the watch frozen, which the stall watchdog
            // translates into the same network verdict as before.
          },
        );
  }

  final FileTransferApi _api;
  final int _fileId;

  /// Mirrors every parsed `updateFile` to the diagnostics panel. The same
  /// stream that drives the wait loop, so the numbers cannot drift apart.
  final void Function(FileState state)? onState;

  String _path = '';
  int _windowOffset = 0;
  int _prefix = 0;
  int _expected = 0;
  bool _complete = false;
  bool _canDownload = true;

  /// Set while a targeted window is in flight, so a sequential restore can be
  /// skipped when the proxy asks for another window immediately after.
  bool _windowSteered = false;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final StreamSubscription<FileState> _subscription;

  void _onState(FileState state) {
    if (state.id != _fileId) return;
    onState?.call(state);
    if (state.path.isNotEmpty) _path = state.path;
    if (state.expectedSize > _expected) _expected = state.expectedSize;
    _canDownload = state.canBeDownloaded;
    if (state.isCompleted) {
      _complete = true;
      _windowOffset = 0;
      _prefix = state.downloadedSize > 0
          ? state.downloadedSize
          : _expected;
    } else {
      _windowOffset = state.downloadOffset;
      _prefix = state.downloadedSize;
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  int get headBytes => _windowOffset == 0 ? _prefix : 0;

  @override
  int readableEndFrom(int from) {
    if (_complete) return _expected - 1;
    if (from >= _windowOffset && from < _windowOffset + _prefix) {
      return _windowOffset + _prefix - 1;
    }
    return -1;
  }

  @override
  bool covers(int from, int end) {
    if (_complete) return true;
    if (end < from) return true;
    return from >= _windowOffset && end <= _windowOffset + _prefix - 1;
  }

  @override
  int get expectedBytes => _expected;
  @override
  bool get isComplete => _complete;
  @override
  String get localPath => _path;
  @override
  Stream<void> get progress => _changes.stream;

  @override
  Future<void> requestWindow(int from, int end) async {
    if (!_canDownload) {
      throw VideoSourceException('流式播放不可用（该文件不允许下载）');
    }
    _windowSteered = true;
    // 1 KB alignment is what TDLib's chunking expects; the cost is at most
    // 1023 bytes downloaded early.
    final aligned = from & ~1023;
    final limit = end - aligned + 1;
    await _api.startRange(_fileId, offset: aligned, limit: limit);
  }

  @override
  Future<void> resumeSequential() async {
    if (!_windowSteered || _complete) return;
    _windowSteered = false;
    await _api.start(_fileId);
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}

/// Internal signal used to close a completer nobody is waiting for any more.
class _Abandoned implements Exception {
  @override
  String toString() => '_Abandoned';
}
