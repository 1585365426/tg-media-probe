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
import 'download_audit.dart';
import 'downloader.dart';
import 'growing_file_reader.dart';
import 'media_metadata.dart';
import 'mp4_probe.dart';
import 'playback_session.dart';
import 'native_streaming.dart';
import 'playback_trace.dart';
import 'resource_loader.dart';
import 'source_decision.dart';
import 'stream_proxy.dart';
import 'stream_window.dart';
import 'streaming_diagnostics.dart';

export 'download_audit.dart';
export 'stream_window.dart';

/// The only TDLib surface this file needs. Abstracted so the resolution logic
/// can be tested without a native library.
abstract class FileTransferApi {
  Future<FileState?> stat(int fileId);

  /// Starts the full download (offset 0, no limit). Only the
  /// [DownloadCaller.downloader] rung may use this: for a play window it
  /// asks TDLib for the whole file.
  Future<void> start(
    int fileId, {
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  });

  Future<void> cancel(int fileId);

  Stream<FileState> updates();

  /// Points the TDLib download window at [offset]..[offset+limit].
  ///
  /// TDLib keeps ONE active download per file: a new request with a different
  /// offset/limit replaces the running one (td_api.tl, downloadFile). This is
  /// what lets the proxy serve a range AVPlayer asked for *now* — e.g. the
  /// tail of the file during a moov probe — instead of waiting for the
  /// sequential download to crawl there.
  ///
  /// [limit] is required to be finite for a play window. `0` (whole file) is
  /// rejected by the production implementation so a call site cannot drift
  /// back into "download 1.33 GB before the first frame".
  Future<void> startRange(
    int fileId, {
    required int offset,
    required int limit,
    int priority = 16,
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  });

  /// Warms the cache for [fileId] at a priority below any play.
  ///
  /// Deliberately a one-shot, bounded request with no observer: a preload must
  /// be able to produce bytes and nothing else — no [PlaySource], no watcher,
  /// no proxy. Bounded because a neighbour the user may never open has no
  /// claim on more than the head of the file.
  Future<void> prefetch(int fileId) => startRange(
        fileId,
        offset: 0,
        limit: StreamWindow.preloadBytes,
        priority: 2,
        caller: DownloadCaller.preload,
        cause: 'preload head',
      );
}

class TdFileTransferApi implements FileTransferApi {
  TdFileTransferApi(
    this.client, {
    DownloadAudit? auditSink,
  }) : audit = auditSink ?? DownloadAudit() {
    // Attribution needs the file updates, and it needs *all* of them —
    // including the ones for files no watcher is listening to (a preload).
    // One subscription here is the only place that sees every transfer.
    _auditSubscription = client.fileUpdates.map(FileState.fromJson).listen(
      (state) {
        audit.observe(
          fileId: state.id,
          offset: state.downloadOffset,
          downloaded: state.downloadedSize,
        );
      },
      onError: (Object _) {
        // A broken update stream must not take the audit down with it; the
        // transfer still has its own watchers.
      },
    );
  }

  final TdClient client;

  /// Every `downloadFile` this app sends, with the caller that sent it.
  final DownloadAudit audit;

  late final StreamSubscription<FileState> _auditSubscription;

  Future<void> dispose() => _auditSubscription.cancel();

  @override
  Future<FileState?> stat(int fileId) async {
    final response = await client.request(
      getFile(fileId),
      timeout: const Duration(seconds: 20),
    );
    if (errorText(response) != null) return null;
    return fileFromResponse(response);
  }

  /// [stat], but a TDLib *rejection* is an error instead of `null`.
  ///
  /// The two cases look identical through [stat] and mean opposite things:
  ///
  /// * `null` — TDLib has no record **yet**; the id is fine, the metadata is
  ///   still loading.
  /// * `FILE_ID_INVALID` / `FILE NOT FOUND` — the id itself is stale; only a
  ///   re-read of the message can fix it.
  ///
  /// Collapsing both into `null` is what produced
  /// `candidateReason=no_file_record` on a video whose record the diagnostics
  /// had just printed, followed by a whole-file download of a *different* file
  /// id once the repair ran.
  ///
  /// Not part of [FileTransferApi]: a test double's `stat` already means "no
  /// record", and widening the interface would force twelve fakes to grow a
  /// method that does the same thing. [VideoSourceResolver._statStrict] uses it
  /// when the api is the real one.
  Future<FileState?> statStrict(int fileId) async {
    final response = await client.request(
      getFile(fileId),
      timeout: const Duration(seconds: 20),
    );
    final error = errorText(response);
    if (error != null) {
      // `stat` swallows this into `null`, which reads as "nothing yet". A
      // rejected id is not nothing: it is the reason the file the user tapped
      // is reachable only through the message.
      throw VideoSourceException(error);
    }
    return fileFromResponse(response);
  }

  @override
  Future<void> start(
    int fileId, {
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  }) async {
    // The last door before the wire. `limit: 0` means "down to the end of the
    // file", and under B+ it belongs to exactly one caller: the Downloader.
    // A streaming play that reached for it is the 622 MB mistake — refused.
    // The Downloader's own whole-file request is the architecture, not a
    // breach, and passes without a key.
    if (caller != DownloadCaller.downloader && !audit.wholeFileAllowed) {
      audit.noteBlockedWholeFile(
        fileId: fileId,
        caller: caller,
        cause: cause,
      );
      throw VideoSourceException(
        'AUTO_FULL_DOWNLOAD_BLOCKED（流式播放期间禁止整文件下载，'
        'caller=${caller.label}）',
      );
    }
    // priority 32 is the same value the probe chain uses: high enough to beat
    // thumbnail fetches, low enough not to starve the chat list.
    audit.record(
      fileId: fileId,
      caller: caller,
      offset: 0,
      limit: 0,
      priority: 32,
      cause: cause.isEmpty ? 'whole file' : cause,
    );
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
    int priority = 16,
    DownloadCaller caller = DownloadCaller.unknown,
    String cause = '',
  }) async {
    if (limit <= 0) {
      // The whole-file request is `start()`. Keeping this rejection here means
      // a window call site cannot silently become an unbounded download.
      throw VideoSourceException('窗口大小必须为正数（limit=$limit）');
    }
    // Priority 16: a range the player is blocked on outranks prefetches but
    // stays below the "start playing" transfer. TDLib aligns offset handling
    // internally; the caller passes byte-exact windows.
    audit.record(
      fileId: fileId,
      caller: caller,
      offset: offset,
      limit: limit,
      priority: priority,
      cause: cause,
    );
    final response = await client.request(
      downloadFile(fileId: fileId, offset: offset, limit: limit, priority: priority),
      timeout: const Duration(seconds: 60),
    );
    final error = errorText(response);
    if (error != null) throw VideoSourceException(error);
  }

  @override
  Future<void> prefetch(int fileId) async {
    // Priority 2: below the play's 32 and below a range the proxy is blocked
    // on (16). TDLib serves one file per priority queue, so a preload can only
    // ever use bandwidth the active play is not asking for. The window is
    // bounded to the head — a neighbour is not a reason to pull a whole film.
    await startRange(
      fileId,
      offset: 0,
      limit: StreamWindow.preloadBytes,
      priority: 2,
      caller: DownloadCaller.preload,
      cause: 'preload head',
    );
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
/// Which transport produced a [PlaySource].
enum PlaySourceKind {
  /// The whole file is on disk: AVPlayer opens the path directly.
  file,

  /// Streaming V1: loopback HTTP range proxy.
  httpStream,

  /// Streaming V2: `AVAssetResourceLoader` on a `tgmedia://` URL.
  resourceLoader,
}

class PlaySource {
  /// [origin] is what the diagnostics report as `finalSource`. It defaults to
  /// `LOCAL_FILE`, which is right for a file that was already complete on
  /// disk; a file that only exists because something waited out a whole
  /// download must say `FULL_DOWNLOAD` — otherwise a 593 MB download to get a
  /// first frame is filed as if the video had always been local.
  const PlaySource.file(this.path, {this.origin = 'LOCAL_FILE'})
      : url = path,
        kind = PlaySourceKind.file,
        proxy = null,
        session = null,
        onDispose = null;

  const PlaySource.stream(this.url, this.path, this.proxy)
      : kind = PlaySourceKind.httpStream,
        session = null,
        onDispose = null,
        origin = 'HTTP_PROXY';

  /// V2: [url] is a `tgmedia://` URL the native loader answers, [path] is the
  /// growing TDLib file and [session] owns the byte supply.
  const PlaySource.resourceLoader(
    this.url,
    this.path,
    this.session, [
    this.onDispose,
  ])  : kind = PlaySourceKind.resourceLoader,
        proxy = null,
        origin = 'RESOURCE_LOADER';

  /// The label `finalSource` carries: `LOCAL_FILE`, `FULL_DOWNLOAD`,
  /// `HTTP_PROXY` or `RESOURCE_LOADER`.
  final String origin;

  /// What the player opens: a local path, a loopback URL (V1) or a
  /// `tgmedia://` URL (V2). Never a Telegram cloud URL.
  final String url;

  /// The local file backing the play — the TDLib pool entry. The cache
  /// cleaner checks this path against the in-use registry.
  final String path;

  final PlaySourceKind kind;

  /// True for either streaming transport.
  bool get isStreaming => kind != PlaySourceKind.file;

  bool get isResourceLoader => kind == PlaySourceKind.resourceLoader;

  /// Non-null in V1 mode. The owner must call [dispose] when the play ends so
  /// the listener and its port are freed.
  final StreamProxyServer? proxy;

  /// Non-null in V2 mode.
  final ResourceLoaderSession? session;

  /// Extra teardown (the file watcher). Kept as a callback so [PlaySource]
  /// does not need to know who created it.
  final Future<void> Function()? onDispose;

  Future<void> dispose() async {
    await proxy?.stop();
    await session?.close();
    await onDispose?.call();
  }

  @override
  String toString() => switch (kind) {
        PlaySourceKind.file => 'PlaySource.file(${path.hashCode})',
        PlaySourceKind.httpStream =>
          'PlaySource.http(file=${path.hashCode})',
        PlaySourceKind.resourceLoader =>
          'PlaySource.resourceLoader(file=${path.hashCode})',
      };
}

/// Which streaming transport a resolve attempt should use.
enum StreamTransport {
  /// V1: loopback HTTP range proxy.
  httpProxy,

  /// V2: AVAssetResourceLoader.
  resourceLoader,
}

/// Streaming never started, and not because a transport failed.
///
/// The message carries the decision reason verbatim (`no_file_record`,
/// `unknown_size`) so the screen and the acceptance report name the same
/// thing. This exception exists to be *not* a fallback trigger: before it, the
/// resolver signalled this case with a plain [VideoSourceException], the
/// controller caught that with the same handler it uses for a stalled proxy,
/// and the handler's answer was `downloadFile(limit: 0)`.
class StreamingNotStarted extends VideoSourceException {
  StreamingNotStarted(this.reason)
      : super(reason == 'unknown_size'
            ? '流式播放未启动（文件大小未知）'
            : '流式播放未启动（$reason）');

  final String reason;
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
    Future<int> Function(String path)? diskSizeOf,
    StreamingDiagnostics? diagnostics,
    NativeStreamingTransport? nativeTransport,
    this.resourceLoaderPathWait = const Duration(seconds: 8),
    this.windowBytes = StreamWindow.stepBytes,
    this.waitTimeout = const Duration(seconds: 10),
    FreeBytesProbe? freeBytes,
  })  : _fileExists = fileExists ?? _defaultFileExists,
        _diskSizeOf = diskSizeOf ?? _defaultDiskSizeOf,
        _diagnostics = diagnostics ?? StreamingDiagnostics.instance,
        _nativeTransport = nativeTransport ?? MethodChannelStreamingTransport(),
        freeBytes = freeBytes ?? _defaultFreeBytes;

  /// B+ WAIT_TIMEOUT default (task book §8): 10 seconds, configurable.
  final Duration waitTimeout;

  /// Free disk space probe; injected in tests, host OS on a device.
  final FreeBytesProbe freeBytes;

  /// The download authority: the only path from this resolver to TDLib's
  /// download API. Every whole-file request a play makes goes through it.
  late final TelegramMediaDownloader downloader = TelegramMediaDownloader(
    api: api,
    audit: _diagnostics.downloadAudit,
    freeBytes: freeBytes,
  )..diskSizeOf = _diskSizeOf;

  static Future<int> _defaultFreeBytes() async => -1;

  /// Streaming V2 bridge. Injected in tests, `MethodChannel` on a device.
  final NativeStreamingTransport _nativeTransport;

  /// How long V2 waits for TDLib to name the local file before giving up on
  /// the transport. This is a *path* wait, not a playback wait: V2 does not
  /// need bytes on disk to start, only a file to read from.
  final Duration resourceLoaderPathWait;

  /// How many bytes one `downloadFile` may ask for. The play opens on
  /// [StreamWindow.firstBytes] and every later window is this size, so a tap
  /// can never turn into a whole-file request.
  final int windowBytes;

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

  /// Measures the bytes behind a path, or -1.
  ///
  /// Injected for the same reason as [_fileExists]: a test can describe a file
  /// that exists with a known length without writing hundreds of megabytes to
  /// a disk. On a device this is `File.length()`.
  final Future<int> Function(String path) _diskSizeOf;

  static Future<bool> _defaultFileExists(String path) => File(path).exists();

  static Future<int> _defaultDiskSizeOf(String path) async {
    try {
      return await File(path).length();
    } on Object {
      return -1;
    }
  }

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

  /// Playback resolves, kept apart from [_inflight] on purpose.
  ///
  /// They used to share one map, which meant a preload of the neighbour and
  /// the user opening that neighbour were the *same* future: the play joined
  /// a full download and the player was handed a local path. `resolveStream`
  /// now only ever joins another streaming resolve, so a preload cannot make
  /// the decision that streaming makes.
  final Map<int, Future<PlaySource>> _inflightStream =
      <int, Future<PlaySource>>{};

  /// V2 resolves, kept apart from both V1 and the full-download map: a
  /// current V2 play must never join a V1 future that has already decided the
  /// transport, or the player ends up opening a URL of the wrong kind.
  final Map<int, Future<PlaySource>> _inflightV2 = <int, Future<PlaySource>>{};

  /// The file the user is watching. A preload must never start, steer or
  /// cancel a transfer for it.
  int? _activePlayFileId;
  final Set<int> _prefetching = <int>{};

  /// Files a preload has already asked TDLib for.
  ///
  /// `downloadFile` returns as soon as TDLib accepts; the transfer keeps
  /// running afterwards. Without this set, a window that is no longer wanted
  /// keeps pulling bandwidth — which is how a 152 MB neighbour was still
  /// loading while the 720 MB video the user had just tapped was waiting for
  /// its first byte. Cancelling them is the only way to stop a request that
  /// was already accepted.
  final Set<int> _warmed = <int>{};

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
    // A playback resolve usually opens the evidence block for its play — but
    // NOT when it is the *fallback* of a play whose block already exists
    // (resolveStream opened it, noteFallback just recorded why streaming
    // died). Re-calling beginPlay here wiped the fallback reason and the
    // proxy/206 evidence, so the acceptance report showed a full download
    // with no explanation. Same file id = same play = keep the evidence.
    int? generation;
    if (forPlayback) {
      if (_activePlayFileId != fileId) _activePlayFileId = fileId;
      if (_diagnostics.fileId != fileId) {
        generation = _diagnostics.beginPlay(
          fileId: fileId,
          streaming: false,
          chatId: chatId,
          messageId: messageId,
        );
      }
    }
    final future = _resolveWithRepair(
      fileId,
      chatId: chatId,
      messageId: messageId,
      onProgress: onProgress,
      trace: trace,
      onRecordRefreshed: onRecordRefreshed,
      report: forPlayback,
      generation: generation,
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

  /// The one entry point every play goes through: turn the tap's
  /// `chatId` + `messageId` into the file TDLib currently owns, with the
  /// disk measured.
  ///
  /// `hintFileId` is where the lookup starts, never where it ends. The device
  /// log had a tile carrying `4999` while TDLib's live record sat at `2221`;
  /// the message is the identity, the id is a runtime handle, and this method
  /// is the only place allowed to marry them.
  Future<PlayableFile> resolvePlayableFile(
    int chatId,
    int messageId, {
    int? hintFileId,
    int? generation,
    PlaybackTrace? trace,
  }) async {
    var fileId = hintFileId ?? 0;
    if (metadata != null) {
      try {
        final fresh = await metadata!.fetch(chatId, messageId);
        if (fresh != null && fresh.fileId != 0) {
          if (hintFileId != null && fresh.fileId != hintFileId) {
            _diagnostics.noteFileIdRemap(
              oldId: hintFileId,
              newId: fresh.fileId,
              reason: 'message re-read',
            );
          }
          fileId = fresh.fileId;
        }
      } on Object {
        // A metadata failure leaves the hint standing: `statStrict` below is
        // the one that says whether the id is alive, and it reports honestly
        // when it is not.
      }
    }
    if (fileId == 0) {
      throw VideoSourceException('消息里没有可播放的文件');
    }
    FileState? state;
    try {
      state = await _statStrict(fileId);
    } on VideoSourceException catch (e) {
      if (_looksMissing(e.message.toUpperCase())) throw _MissingFile(e.message);
      rethrow;
    }
    final facts = await _factsFor(state, fileId);
    _diagnostics.noteDiskMeasured(facts.diskSize, generation: generation);
    return PlayableFile(
      chatId: chatId,
      messageId: messageId,
      fileId: fileId,
      expectedSize: facts.expectedBytes,
      localPath: facts.path,
      localSize: facts.diskSize,
      // The record's word is not part of this: `isPlayableFromDisk` needs a
      // real path, real bytes, and a byte count that reaches the end.
      isComplete: facts.isPlayableFromDisk,
      generation: generation ?? 0,
    );
  }

  /// The explicit last rung: wait for the whole file, then hand it over.
  ///
  /// Reachable only from a session that still owns its one full-download
  /// fallback — the caller (the feed) checks and spends that before coming
  /// here. Every watchdog from [_resolveWithRepair] applies; the returned
  /// [PlayableFile] is measured, so a "completed" transfer with no bytes
  /// behind the path reads as `isComplete: false` and not as a play.
  Future<PlayableFile> downloadWhole(
    int chatId,
    int messageId,
    int fileId, {
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    int? generation,
  }) async {
    final path = await _resolveWithRepair(
      fileId,
      chatId: chatId,
      messageId: messageId,
      onProgress: onProgress,
      trace: trace,
      report: true,
      generation: generation,
    );
    final state = await _statStrict(fileId);
    final facts = await _factsFor(state, fileId);
    _diagnostics.noteDiskMeasured(facts.diskSize, generation: generation);
    return PlayableFile(
      chatId: chatId,
      messageId: messageId,
      fileId: fileId,
      expectedSize: facts.expectedBytes,
      localPath: facts.path.isNotEmpty ? facts.path : path,
      localSize: facts.diskSize,
      isComplete: facts.isPlayableFromDisk,
      generation: generation ?? 0,
    );
  }

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
    String? mimeType,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
  }) =>
      _resolveStreamTransport(
        fileId,
        chatId: chatId,
        messageId: messageId,
        mimeType: mimeType,
        onProgress: onProgress,
        trace: trace,
        onRecordRefreshed: onRecordRefreshed,
        transport: StreamTransport.httpProxy,
      );

  /// Streaming V2 entry point: `AVAssetResourceLoader` instead of the loopback
  /// proxy. Throws [StreamingV2Unavailable] when the platform has no bridge,
  /// which is the signal the feed uses to drop back to V1.
  Future<PlaySource> resolveStreamV2(
    int fileId, {
    int? chatId,
    int? messageId,
    String? mimeType,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
  }) =>
      _resolveStreamTransport(
        fileId,
        chatId: chatId,
        messageId: messageId,
        mimeType: mimeType,
        onProgress: onProgress,
        trace: trace,
        onRecordRefreshed: onRecordRefreshed,
        transport: StreamTransport.resourceLoader,
      );

  Future<PlaySource> _resolveStreamTransport(
    int fileId, {
    required StreamTransport transport,
    int? chatId,
    int? messageId,
    String? mimeType,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
  }) {
    // From this moment the file belongs to the play: preloads step aside and
    // nothing on the preload path may cancel or re-steer its transfer.
    _activePlayFileId = fileId;
    final inflight = transport == StreamTransport.resourceLoader
        ? _inflightV2
        : _inflightStream;
    final running = inflight[fileId];
    if (running != null) return running;
    // Preference layer, before anything else: streaming off and no forced
    // test means this play is a plain full download — and it says so, instead
    // of looking like a streaming pipeline that mysteriously produced a path.
    if (!_diagnostics.forceStreamingTest &&
        !_diagnostics.userStreamingPreference) {
      // Written *after* the full download: `resolve(forPlayback: true)` opens
      // a fresh evidence block, which would erase anything recorded first.
      return resolve(
        fileId,
        chatId: chatId,
        messageId: messageId,
        onProgress: onProgress,
        trace: trace,
        onRecordRefreshed: onRecordRefreshed,
        forPlayback: true,
      ).then((path) {
        _diagnostics.noteDecision(
          preference: false,
          force: false,
          candidate: false,
          candidateReason: 'streaming_disabled_by_preference',
          decision: 'LOCAL_FILE',
          reason: 'streaming_disabled_by_preference',
        );
        // The user turned streaming off: what plays is a finished local file.
        // `finalSource` is a closed set (RESOURCE_LOADER / LOCAL_FILE /
        // FAILED), so this path reports LOCAL_FILE like every other disk play —
        // the "why" is the decision line above, not a fourth source name.
        return PlaySource.file(path);
      });
    }
    final future = _streamWithRepair(
      fileId,
      chatId: chatId,
      messageId: messageId,
      mimeType: mimeType,
      onProgress: onProgress,
      trace: trace,
      onRecordRefreshed: onRecordRefreshed,
      transport: transport,
    );
    inflight[fileId] = future;
    return future.whenComplete(() => inflight.remove(fileId));
  }

  /// Reads the TDLib record, keeping "rejected id" and "no record yet" apart.
  ///
  /// [TdFileTransferApi.stat] answers `null` for both; that collapse is what
  /// let a stale `file_id` look like a video with no record, which the decision
  /// layer then read as "nothing honest to serve" — and the answer to that used
  /// to be a whole-file download under the *repaired* id.
  Future<FileState?> _statStrict(int fileId) {
    final api = this.api;
    if (api is TdFileTransferApi) return api.statStrict(fileId);
    return api.stat(fileId);
  }

  /// Reads every fact the decision is allowed to use.
  ///
  /// Two independent measurements: `diskSize` from a `stat`, `downloadedBytes`
  /// from TDLib's counter. Neither is allowed to stand in for the other — the
  /// device report showed a record at 100% with ~21 MB behind it, and a file
  /// whose length reached the total with a hole in the middle. Completeness
  /// needs both, and only [SourceFacts.isPlayableFromDisk] combines them.
  Future<SourceFacts> _factsFor(FileState? state, int fileId) async {
    if (state == null) return SourceFacts.missing(fileId);
    var exists = false;
    // Measured, or unknown. It used to start at `state.size` — the size TDLib
    // *declares* — and that single line is how a 989 KB file was reported as a
    // complete `LOCAL_FILE`: whenever the stat failed, the declared total stood
    // in for the bytes on disk. A stat that cannot run says "unknown" (-1), and
    // unknown is never complete.
    var diskSize = -1;
    if (state.path.isNotEmpty) {
      // The injected probe owns "does it exist"; `stat` owns "how big".
      // Keeping them separate is what lets a test describe a file that has no
      // bytes behind it, and what keeps a vanished file from being called
      // complete because a record remembers it.
      exists = await _fileExists(state.path);
      if (exists) {
        final measured = await _diskSizeOf(state.path);
        if (measured > 0) diskSize = measured;
      } else {
        diskSize = -1;
      }
    }
    return SourceFacts(
      fileId: fileId,
      hasRecord: true,
      claimedComplete: state.isCompleted,
      downloadedBytes: state.downloadedSize,
      downloadOffset: state.downloadOffset,
      recordSize: state.size,
      expectedBytes: state.expectedSize,
      path: state.path,
      pathExists: exists,
      diskSize: diskSize,
    );
  }

  /// The same facts, for a caller that is not currently resolving — the feed
  /// asks after a transport failed, to find out whether the file finished in
  /// the meantime.
  Future<SourceFacts> inspect(int fileId) async {
    FileState? state;
    try {
      state = await api.stat(fileId);
    } on Object {
      state = null;
    }
    return _factsFor(state, fileId);
  }

  /// Low-priority warm start for an item the user has not opened.
  ///
  /// Returns false when the request was refused (TDLib error, no such file).
  /// It never returns a path and never waits for completion: "preload
  /// finished" must not be able to mean "ready to play", because that is how
  /// a neighbour ended up in the player.
  Future<bool> prefetch(int fileId) async {
    if (fileId <= 0) return false;
    if (_activePlayFileId == fileId) return true;
    if (!_prefetching.add(fileId)) return true;
    try {
      // B+: preload never downloads. A warm neighbour is a *local* fact —
      // whether its bytes are already complete. Anything else waits for the
      // user's tap, which is where [downloader.ensureFullDownload] lives.
      // `api.prefetch` (a TDLib range request) has no caller left under B+.
      final state = await api.stat(fileId);
      if (state == null) return false;
      final facts = await _factsFor(state, fileId);
      _warmed.add(fileId);
      return facts.isPlayableFromDisk;
    } on Object {
      return false;
    } finally {
      _prefetching.remove(fileId);
    }
  }

  /// Stops warming files that are no longer in the preload window.
  ///
  /// [keep] is the new window. Anything warmed earlier that is not in it — and
  /// is not the file being watched — is cancelled at the TDLib level, because
  /// a `downloadFile` that was already accepted cannot be un-asked any other
  /// way. The active file is never touched: its window belongs to the play.
  Future<void> abandonWarm(Iterable<int> keep) async {
    final wanted = keep.toSet();
    final stale = _warmed
        .where((id) => !wanted.contains(id) && id != _activePlayFileId)
        .toList();
    for (final id in stale) {
      _warmed.remove(id);
      try {
        await api.cancel(id);
      } on Object {
        // A transfer that already finished is not an error.
      }
    }
  }

  /// The streaming loop. Same repair/backoff shape as [_resolveWithRepair]:
  /// a rejected file id is re-read from the message once, transient TDLib
  /// errors get the bounded retry, everything else propagates to the caller.
  Future<PlaySource> _streamWithRepair(
    int fileId, {
    int? chatId,
    int? messageId,
    String? mimeType,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    void Function(MediaRecord fresh)? onRecordRefreshed,
    StreamTransport transport = StreamTransport.httpProxy,
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
          mimeType: mimeType,
          onProgress: onProgress,
          trace: trace,
          transport: transport,
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
          // The id moved. Recorded as its own line: a play that downloads a
          // different file than the one tapped has to say so, and this is the
          // only place that knows both ids.
          _diagnostics.noteFileIdRemap(
            oldId: activeId,
            newId: fresh.fileId,
            reason: 'tabled_id_rejected_re_read_message',
          );
          activeId = fresh.fileId;
          trace?.mark(PlaybackStage.fileIdRefreshed, bytes: fresh.sizeBytes);
          trace?.note = 'file_id 已从消息重新获取';
          trace?.errorCategory = null;
        }
        onRecordRefreshed?.call(fresh);
        continue;
      } on StreamingNotStarted {
        // A decision, not a transport failure: no repair, no retry, no download.
        rethrow;
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
    String? mimeType,
    void Function(VideoSourceUpdate update)? onProgress,
    PlaybackTrace? trace,
    StreamTransport transport = StreamTransport.httpProxy,
  }) async {
    _cancelled.remove(fileId);
    trace?.mark(PlaybackStage.resolveStarted);
    onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));

    // One id repair per attempt. Thrown as [_MissingFile] so the caller's loop
    // re-reads the message, exactly like a TDLib rejection does.
    var repairedId = false;

    FileState? existing;
    try {
      // `statStrict`, not `stat`: a rejected id must be repairable, and
      // swallowing the error into `null` is what made a stale `file_id` look
      // like a video with no TDLib record at all.
      existing = await _statStrict(fileId);
    } on VideoSourceException catch (e) {
      final text = e.message;
      if (_looksMissing(text.toUpperCase())) {
        throw _MissingFile(text);
      }
      rethrow;
    }
    if (existing != null) {
      trace?.mark(PlaybackStage.fileRecordKnown,
          bytes: existing.downloadedSize);
      if (existing.expectedSize > 0) trace?.expectedBytes = existing.expectedSize;
    }
    // Who asked for which id, and which id TDLib actually answered for. A
    // report that prints "record exists" and "no_file_record" in the same
    // block is describing two different ids; this line is where that shows.
    _diagnostics.noteFileIdResolve(
      clickedFileId: _diagnostics.clickedFileId ?? fileId,
      recordFileId: _diagnostics.recordFileId ?? fileId,
      resolvedFileId: fileId,
      tdlibFileId: existing?.id ?? 0,
      messageId: messageId,
      generation: _diagnostics.generation,
    );
    // Start of a new play's evidence: ids and total come from TDLib's own file
    // record, never from a UI assumption. `streamingEnabled` flips to true
    // later, only if the resolver really takes the streaming branch.
    final generation = _diagnostics.beginPlay(
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
        generation: generation,
      );
    }
    // One rule, one place. The old check trusted `is_downloading_completed`
    // and then, when it failed, still opened the proxy — which is how a
    // 756 MB file whose bytes were already on disk ended up in a growing-file
    // response that could only carry 20 MB of them.
    final facts = await _factsFor(existing, fileId);
    final decision = decidePlaybackSource(
      facts,
      streamingEnabled: _diagnostics.userStreamingPreference,
      forceStreaming: _diagnostics.forceStreamingTest,
      v2Supported: transport == StreamTransport.resourceLoader,
    );
    _diagnostics.noteSourceDecision(decision, generation: generation);
    final fileComplete = facts.isPlayableFromDisk;
    final forced = decision.forced;
    _diagnostics.noteDecision(
      preference: _diagnostics.userStreamingPreference,
      force: forced,
      fileComplete: fileComplete,
      generation: generation,
    );
    if (decision.source == PlaybackSourceKind.localFile) {
      trace?.mark(PlaybackStage.fileReady, bytes: facts.diskSize);
      onProgress?.call(VideoSourceUpdate(
        stage: SourceStage.ready,
        downloadedBytes: facts.diskSize,
        expectedBytes: facts.expectedBytes,
        path: facts.path,
      ));
      return PlaySource.file(facts.path);
    }

    // No record, or no size to put in Content-Range. This is *not* an
    // instruction to download the whole file any more. The device report:
    //
    //   record file=4999 size=24316497 ... match=YES
    //   candidateReason=no_file_record
    //   playbackDecision=FULL_DOWNLOAD
    //   DOWNLOAD AUDIT #1 file=4999 limit=WHOLE_FILE grew=0
    //                    #2 file=2221 limit=WHOLE_FILE grew=24316497
    //
    // The record existed; TDLib just did not answer for that id, and `stat`
    // turned the rejection into the same `null` it uses for "nothing yet". The
    // id had moved to 2221, and the only code that could have noticed was the
    // repair loop — which never ran, because "no record" was treated as a
    // transport verdict instead of a stale id.
    if (decision.source == PlaybackSourceKind.streamingNotStarted ||
        decision.source == PlaybackSourceKind.fullDownload) {
      // A missing record is a repairable id problem: re-read the message and
      // let the caller's repair loop re-resolve. It gets exactly one attempt.
      if (!repairedId && metadata != null && chatId != null && messageId != null) {
        repairedId = true;
        trace?.errorCategory = 'streamingUnavailable';
        throw _MissingFile('no_file_record（TDLib 无 file_id=$fileId 的记录）');
      }
      trace?.mark(PlaybackStage.streamingModeSelected);
      trace?.errorCategory = 'streamingUnavailable';
      _diagnostics.noteDecision(
        candidate: false,
        candidateReason: decision.reason,
        decision: 'STREAMING_NOT_STARTED',
        reason: decision.reason,
        generation: generation,
      );
      // Not a fallback: there is nothing to fall back *to* that does not
      // involve downloading the file. The play stops and the screen says why.
      throw StreamingNotStarted(decision.reason);
    }

    // TDLib says finished, the disk says otherwise. Nothing more will ever be
    // sent for this file, so waiting is a guaranteed stall: the Downloader
    // cancels and re-issues the whole-file request. B+ routes that pair
    // through the downloader — the resolver itself never sends `downloadFile`.
    if (decision.needsRedownload) {
      _diagnostics.noteSourceDecision(decision, generation: generation);
      try {
        await downloader.restart(
          chatId: chatId ?? 0,
          messageId: messageId ?? 0,
          fileId: fileId,
          expectedSize: facts.expectedBytes,
          generation: generation,
        );
      } on Object catch (e) {
        _diagnostics.noteDecision(
          candidate: false,
          candidateReason: 'redownload_failed',
          decision: 'FALLBACK',
          reason: 'redownload_failed',
          generation: generation,
        );
        throw VideoSourceException('文件不完整且无法重新下载：$e');
      }
    }

    trace?.mark(PlaybackStage.streamingModeSelected);
    _diagnostics.noteDecision(candidate: true, generation: generation);
    _diagnostics.noteStreamingSelected(generation: generation);

    // B+: the whole file IS the play's download. The Downloader starts it —
    // or joins the one already running for this file — after measuring the
    // disk rule (remaining × 1.5 free required). This is the play's single
    // legal `limit = 0`, and it happens *before* the player exists.
    final FullDownloadJob job;
    try {
      job = await downloader.ensureFullDownload(
        chatId: chatId ?? 0,
        messageId: messageId ?? 0,
        fileId: fileId,
        expectedSize: facts.expectedBytes,
        generation: generation,
      );
    } on Object catch (e) {
      // TDLib refused the id. That is the one error the repair loop can fix by
      // re-reading the message, so it has to arrive as [_MissingFile] — a raw
      // VideoSourceException here would end the play on a stale file id.
      final text = '$e';
      if (_looksMissing(text.toUpperCase())) throw _MissingFile(text);
      rethrow;
    }
    if (job.state == FullDownloadState.diskFull) {
      throw DiskFullException(job.failureReason ?? '磁盘空间不足');
    }
    // From here on no caller but the Downloader may send a whole-file
    // request. The gate is closed *after* the download exists, because the
    // download itself is the request the gate exists to allow.
    _diagnostics.forbidWholeFile(
      transport == StreamTransport.resourceLoader ? 'streaming:V2' : 'streaming:V1',
    );
    final watch = _LiveFileWatch(
      api,
      fileId,
      trustClaimedComplete: !decision.needsRedownload,
      windowBytes: windowBytes,
      initial: existing,
      // Guarded by the generation captured above: a watcher left over from a
      // superseded play keeps receiving `updateFile` for its own file, and
      // without this it wrote that file's byte counts into the live panel
      // (the "300 MB → 302 MB growth while playing a 23 MB video" report).
      onState: (state) {
        _diagnostics.updateTransferFromState(
          state,
          generation: generation,
        );
        // The job is the Downloader's bookkeeping, and only TDLib's own
        // updates can close it: without this the job stayed `running` for the
        // life of the process, so `isRunning` lied and a recovery path waited
        // on a download that had already ended.
        downloader.observeTransfer(
          fileId: fileId,
          completed: state.isCompleted,
          canBeDownloaded: state.canBeDownloaded,
        );
      },
      // Same measurement the decision layer uses: the watcher may not complete
      // the file on a length it did not read itself.
      diskSizeOf: _measureDisk,
    );
    await watch.seed();

    StreamProxyServer? proxy;
    try {
      trace?.mark(PlaybackStage.downloadRequested);
      // No first window here any more. The Downloader owns the transfer and
      // it is already running — the old `startRange(offset: 0, limit: 16MB,
      // caller: PLAYER)` is exactly the path B+ deletes: the player's very
      // existence must not reach TDLib's download API.

      if (transport == StreamTransport.resourceLoader) {
        // V2 has no startup gate. AVFoundation asks for the ranges it needs and
        // the loader answers as the file grows, so waiting for 2 MB here would
        // only add time to first frame. The one thing V2 cannot start without
        // is a file TDLib has named.
        onProgress?.call(VideoSourceUpdate(
          stage: SourceStage.fetching,
          downloadedBytes: watch.headBytes,
          expectedBytes: watch.expectedBytes,
        ));
        await _waitForPath(watch, resourceLoaderPathWait);
        trace?.mark(PlaybackStage.startupBufferReached, bytes: watch.headBytes);
      } else {
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
      }

      // The proxy reads the local file; by now TDLib has named it. If it has
      // not, there is nothing to serve — the caller falls back.
      final localPath = watch.localPath;
      if (localPath.isEmpty) {
        trace?.errorCategory = 'streamingUnavailable';
        _diagnostics.noteDecision(
          candidate: false,
          candidateReason: 'no_local_path',
          decision: 'FALLBACK',
          reason: 'no_local_path',
          generation: generation,
        );
        throw VideoSourceException('流式播放不可用（下载未产生本地文件）');
      }

      if (transport == StreamTransport.resourceLoader) {
        // The reader sees the same file the Downloader writes: TDLib's
        // progress is observation (the watch, via the bridge), the disk is
        // measured, and the watermark is the min of the two. It cannot
        // download anything.
        final bridge = _LiveProgressBridge(watch);
        final reader = GrowingFileReader(
          path: localPath,
          expectedSize: watch.expectedBytes,
          generation: generation,
          progress: bridge,
          diskSizeOf: _measureDisk,
          waitTimeout: waitTimeout,
        );
        return await _startResourceLoader(
          fileId: fileId,
          chatId: chatId,
          messageId: messageId,
          mimeType: mimeType,
          watch: watch,
          reader: reader,
          localPath: localPath,
          generation: generation,
          fileComplete: fileComplete,
          trace: trace,
          onProgress: onProgress,
          onDispose: () async {
            await reader.dispose();
            await watch.dispose();
          },
        );
      }

      proxy = (proxyFactory ??
              ((w, p) =>
                  _defaultProxy(w, p, trace, mimeType, generation)))(
          watch, localPath);
      final url = await proxy.start();
      trace?.mark(PlaybackStage.streamingProxyStarted);
      // The exact loopback URL the player will open — the acceptance report
      // prints it next to playerSourceType so a device run shows *where* the
      // bytes came from.
      _diagnostics.noteProxyStarted(url.toString(), generation: generation);
      _diagnostics.noteDecision(
        proxyAvailable: true,
        decision: 'STREAM',
        reason: fileComplete
            ? 'complete_file_served_over_http'
            : 'streaming_active',
        generation: generation,
      );
      // When the play ends (or the resolver is torn down) the watch dies with
      // the proxy: one subscription, one owner, no leak.
      proxy.onClose(watch.dispose);

      // Record when the background download finishes. This is the "完整下载：
      // Y 秒" number; the play itself started at [startupBufferReached].
      _watchForCompletion(watch, trace, generation);

      // Which moov layout the player is up against decides whether a head-only
      // response can even work; the scan reads the bytes already on disk, so
      // it costs nothing and never blocks the play.
      unawaited(_probeMoov(localPath, watch, generation));

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
      // Nothing was served: the proxy never handed the player a URL.
      _diagnostics.noteDecision(
        proxyAvailable: false,
        decision: 'FALLBACK',
        reason: proxy != null
            ? 'proxy_start_failed'
            : (transport == StreamTransport.resourceLoader
                ? 'resource_loader_unavailable'
                : 'stream_initialization_failed'),
        generation: generation,
      );
      if (_looksMissing(text.toUpperCase())) throw _MissingFile(text);
      rethrow;
    }
  }

  /// Opens a V2 session and hands the player a `tgmedia://` URL.
  ///
  /// Nothing is downloaded *for* the loader here. TDLib is already running (the
  /// transfer started above); the session's job is to answer "what can you give
  /// me at offset N right now", and to move the download window when the player
  /// asks for a range the sequential transfer will not reach in time.
  Future<PlaySource> _startResourceLoader({
    required int fileId,
    required int? chatId,
    required int? messageId,
    required String? mimeType,
    required FileProgressWatch watch,
    required GrowingFileReader reader,
    required String localPath,
    required int generation,
    required bool fileComplete,
    PlaybackTrace? trace,
    void Function(VideoSourceUpdate update)? onProgress,
    Future<void> Function()? onDispose,
  }) async {
    final session = ResourceLoaderSession(
      sessionId: '${fileId}_$generation',
      fileId: fileId,
      chatId: chatId ?? 0,
      messageId: messageId ?? 0,
      generation: generation,
      reader: reader,
      mimeType: (mimeType != null && mimeType.isNotEmpty)
          ? mimeType
          : 'video/mp4',
      transport: _nativeTransport,
      // The transport must use the same generation the UI uses, or a session
      // that is still "current" here would already be stale there.
      activeGeneration: () => _diagnostics.generation,
      diagnostics: _diagnostics,
    );
    // Throws [StreamingV2Unavailable] when the platform has no bridge; the
    // caller's catch disposes the watcher and the feed drops to V1.
    await session.open();
    ResourceLoaderHost.instance.register(session);

    trace?.mark(PlaybackStage.resourceLoaderStarted);
    _diagnostics.noteResourceLoaderSession(generation: generation);
    _diagnostics.notePlayerSource(
      isStreaming: true,
      url: session.url,
      generation: generation,
      sourceLabel: StreamingV2.sourceLabel,
    );
    _diagnostics.noteDecision(
      proxyAvailable: true,
      decision: 'STREAM',
      reason: fileComplete
          ? 'complete_file_served_by_resource_loader'
          : 'resource_loader_active',
      generation: generation,
    );

    _watchForCompletion(watch, trace, generation);
    unawaited(_probeMoov(localPath, watch, generation));
    onProgress?.call(VideoSourceUpdate(
      stage: SourceStage.fetching,
      downloadedBytes: watch.headBytes,
      expectedBytes: watch.expectedBytes,
    ));
    return PlaySource.resourceLoader(
      session.url,
      localPath,
      session,
      onDispose ?? watch.dispose,
    );
  }

  /// Waits for TDLib to name the local file.
  ///
  /// V2 does not need bytes to start; it needs a path. This is a bounded wait
  /// on a metadata fact (`updateFile` carrying `path`), not on the download:
  /// a slow link delays it by milliseconds, a broken file never produces it.
  Future<void> _waitForPath(FileProgressWatch watch, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (watch.localPath.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _watchForCompletion(
    FileProgressWatch watch,
    PlaybackTrace? trace,
    int generation,
  ) {
    unawaited(() async {
      try {
        await watch.progress
            .firstWhere((_) => watch.isComplete)
            .timeout(const Duration(minutes: 30));
        if (watch.isComplete) {
          // The flag fired; the number that goes on screen is measured, not
          // copied from the total. `noteCompleted` refuses to declare 100%
          // without a length that reaches the end.
          final disk = await _measureDisk(watch.localPath);
          trace?.mark(
            PlaybackStage.fileCompleted,
            bytes: disk >= 0 ? disk : watch.expectedBytes,
          );
          _diagnostics.noteCompleted(
            totalBytes: watch.expectedBytes,
            diskBytes: disk,
            generation: generation,
          );
        }
      } on Object {
        // The completion marker is diagnostics, not playback: a closed stream
        // or a timeout here must not disturb the play.
      }
    }());
  }

  /// Real byte length behind [path], or -1 when it cannot be measured.
  Future<int> _measureDisk(String path) async {
    if (path.isEmpty) return -1;
    final measured = await _diskSizeOf(path);
    return measured < 0 ? -1 : measured;
  }

  StreamProxyServer _defaultProxy(
    FileProgressWatch watch,
    String localPath,
    PlaybackTrace? trace, [
    String? mimeType,
    int? generation,
  ]) =>
      StreamProxyServer(
        watch: watch,
        startupBufferBytes: startupBufferBytes,
        stallTimeout: stallTimeout,
        contentType:
            (mimeType != null && mimeType.isNotEmpty) ? mimeType : 'video/mp4',
        onEvent: (event) {
          // The proxy log is the only way to answer "which Range failed and
          // why" after a device run — without it the answer is a guess.
          trace?.noteProxy(event);
        },
        // Structured mirrors of the same events: the diagnostics panel and the
        // streaming verdict read these, so they cannot be shaped by a string.
        onRangeRequest: ({required from, required to}) {
          _diagnostics.noteRangeRequest(
            from: from,
            to: to,
            generation: generation,
          );
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
            generation: generation,
          );
          if (status == 206) trace?.mark(PlaybackStage.first206Response);
        },
        onWindowMove: ({required start, required end}) {
          _diagnostics.noteWindowMove(start, end, generation: generation);
        },
        // The full exchange — request header, declared Content-Range/Length,
        // bytes actually written. The acceptance report prints these one per
        // line; without them "why didn't the player start" is unknowable.
        onExchange: (exchange) =>
            _diagnostics.noteExchange(exchange, generation: generation),
        onStall: (reason) =>
            _diagnostics.noteStall(reason, generation: generation),
      );

  /// Reads the first box headers of the file and records where `moov` sits.
  ///
  /// `afterMdat` is the case that makes a progressive HTTP response fail: the
  /// player must read the end of the file before it can build its tracks. The
  /// scan runs on whatever is already on disk and never delays the play.
  Future<void> _probeMoov(
    String path,
    FileProgressWatch watch, [
    int? generation,
  ]) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final onDisk = await file.length();
      final available = watch.headBytes > 0
          ? (watch.headBytes < onDisk ? watch.headBytes : onDisk)
          : 0;
      if (available < 16) return;
      final take = available < Mp4Probe.scanBytes ? available : Mp4Probe.scanBytes;
      final handle = await file.open();
      try {
        final bytes = await handle.read(take);
        _diagnostics.noteMoov(Mp4Probe.locate(bytes), generation: generation);
      } finally {
        await handle.close();
      }
    } on Object {
      // Diagnostics only: a probe that cannot read must not touch playback.
    }
  }

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
    int? generation,
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
          generation: generation,
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
          _diagnostics.noteFileIdRemap(
            oldId: activeId,
            newId: fresh.fileId,
            reason: 'tdlib_rejected_id_re_read_message',
          );
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
    int? generation,
  }) async {
    _cancelled.remove(fileId);
    trace?.mark(PlaybackStage.resolveStarted);
    onProgress?.call(const VideoSourceUpdate(stage: SourceStage.probing));

    FileState? existing;
    try {
      // `statStrict` first: a rejected id must reach the repair loop *before*
      // a `downloadFile` is sent for it. The device log had
      // `#1 caller=FULL_DOWNLOAD file=4999 ... grew=0` — one request spent on
      // an id TDLib had already disowned.
      existing = await _statStrict(fileId);
    } on VideoSourceException catch (e) {
      final text = e.message;
      if (_looksMissing(text.toUpperCase())) throw _MissingFile(text);
      rethrow;
    }
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
          generation: generation,
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
          generation: generation,
        );
      }
      if (state.isCompleted) {
        // Complete even when the path is empty: TDLib can report a finished
        // transfer with no local path, and waiting for a later update that
        // never comes would turn a clear error into a long spinner.
        if (!completion.isCompleted) completion.complete(state);
        if (report) {
          // Measured before it is printed: a full-download path still must not
          // put "809 MB / 809 MB" on screen unless 809 MB are behind the path.
          unawaited(() async {
            final disk = await _measureDisk(state.path);
            _diagnostics.noteCompleted(
              totalBytes: expected,
              diskBytes: disk,
              generation: generation,
            );
          }());
        }
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
        // The one place a whole-file request is correct: the play never had a
        // stream to fail (unknown size, no record, streaming switched off) and
        // the user is waiting for a complete cache. The caller badge says so
        // in the audit, and [DownloadAudit.wholeFileAllowed] is the gate that
        // keeps a *failed* stream from reaching this line.
        await api.start(
          fileId,
          caller: DownloadCaller.downloader,
          cause: 'whole file: no stream attempted',
        );
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
class _LiveFileWatch implements FileProgressWatch, WindowContinuation {
  _LiveFileWatch(
    this._api,
    this._fileId, {
    required FileState? initial,
    this.onState,
    this.trustClaimedComplete = true,
    this.windowBytes = StreamWindow.stepBytes,
    Future<int> Function(String path)? diskSizeOf,
  }) : diskSizeOf = diskSizeOf ?? VideoSourceResolver._defaultDiskSizeOf {
    if (initial != null && initial.path.isNotEmpty) {
      _path = initial.path;
      _windowOffset = initial.downloadOffset;
      _prefix = initial.downloadedSize;
      _lastOffset = initial.downloadOffset;
      _lastDownloaded = initial.downloadedSize;
      _present.add(_windowOffset, _windowOffset + _prefix - 1);
    }
    _expected = initial?.expectedSize ?? 0;
    // A record that claims completion while the bytes are short must not be
    // trusted twice: the decision layer already sent it back for a
    // re-download, and believing the claim here would serve holes as video.
    // `_claimedComplete` is kept only so a *measured* count can finish the
    // job later — see [_countCovers].
    _claimedComplete = initial?.isCompleted == true;
    _complete = trustClaimedComplete && _claimedComplete && _countCovers;
    if (_complete && _expected > 0) _present.add(0, _expected - 1);
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

  /// One stat after the subscription exists, so a play never waits on an
  ///  that fired before anyone was listening.
  ///
  /// The whole-file request returns *before* TDLib pushes its first update, and
  /// the push can beat the subscription that follows it — the event is then
  /// gone for good (broadcast stream), and a watch stuck at 0 bytes rides the
  /// stall watchdog into a phantom failure.
  Future<void> seed() async {
    try {
      final state = await _api.stat(_fileId);
      if (state != null) _onState(state);
    } on Object {
      // A failed seed leaves the subscription (and the watchdog) in charge.
    }
  }

  final FileTransferApi _api;
  final int _fileId;

  /// Mirrors every parsed `updateFile` to the diagnostics panel. The same
  /// stream that drives the wait loop, so the numbers cannot drift apart.
  final void Function(FileState state)? onState;

  /// Whether TDLib's "completed" flag may be believed before the disk is
  /// measured. False for a file the decision layer flagged as short.
  final bool trustClaimedComplete;

  /// Measures the bytes behind the path; shared with the decision layer so one
  /// play cannot measure the same file two different ways.
  final Future<int> Function(String path) diskSizeOf;

  /// Size of one download window. Every request this watch issues is bounded
  /// by it, so a play can never ask TDLib for the whole file.
  final int windowBytes;

  /// `(offset, limit)` of the window TDLib was last given, and the offset the
  /// reader last asked for — the two facts that answer "why was this window
  /// opened" and "is it used up".
  int _requestedFrom = -1;
  int _requestedLimit = 0;
  int _readOffset = -1;

  String _path = '';
  int _windowOffset = 0;
  int _prefix = 0;
  int _expected = 0;
  bool _complete = false;
  bool _canDownload = true;

  /// The last `download_offset` / `downloaded_size` TDLib reported, kept apart
  /// from the window fields because they answer a different question: the
  /// fields drive the readable map, these decide whether the whole file is
  /// counted.
  int _lastOffset = 0;
  int _lastDownloaded = 0;

  /// TDLib's `is_downloading_completed`. A claim, kept for the report; it never
  /// on its own turns [_complete] on.
  bool _claimedComplete = false;

  /// `downloaded_size` counts the whole file from byte 0.
  ///
  /// A windowed transfer reports `offset=N, downloaded=limit`: true, and
  /// meaningless for completeness. Zero-sized records are "unknown", not
  /// "complete".
  bool get _countCovers =>
      _lastOffset == 0 && _expected > 0 && _lastDownloaded >= _expected;

  /// Every byte range TDLib has already written, across all window moves.
  ///
  /// The local file keeps what was downloaded; only the *window* moves. Using
  /// the live window as the readable map made a tail probe erase the head from
  /// the proxy's point of view — the main `bytes=0-` response then sat on
  /// bytes that were already on disk and called it a stall.
  final ByteCoverage _present = ByteCoverage();

  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final StreamSubscription<FileState> _subscription;

  void _onState(FileState state) {
    if (state.id != _fileId) return;
    onState?.call(state);
    if (state.path.isNotEmpty) _path = state.path;
    if (state.expectedSize > _expected) _expected = state.expectedSize;
    _canDownload = state.canBeDownloaded;
    _claimedComplete = state.isCompleted;
    _lastOffset = state.downloadOffset;
    _lastDownloaded = state.downloadedSize;
    if (state.isCompleted && _countCovers) {
      _complete = true;
      _windowOffset = 0;
      _prefix = _lastDownloaded;
      if (_expected > 0) _present.add(0, _expected - 1);
    } else {
      // The flag alone never widens the readable map. A file whose tail window
      // was written first has the full length and a hole in the middle; adding
      // `0..total-1` here handed the reader zero-filled bytes and AVPlayer
      // answered "此视频无法解码" — and every later video inherited it,
      // because the same claim was made again for each of them.
      _windowOffset = state.downloadOffset;
      _prefix = state.downloadedSize;
      if (_path.isNotEmpty && _prefix > 0) {
        _present.add(_windowOffset, _windowOffset + _prefix - 1);
      }
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  int get headBytes {
    if (_complete) return _expected;
    return _present.prefixLength;
  }

  @override
  int readableEndFrom(int from) {
    if (_complete) return _expected - 1;
    return _present.endFrom(from);
  }

  @override
  bool covers(int from, int end) {
    if (_complete) return true;
    return _present.covers(from, end);
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
  bool get canDownload => _canDownload;

  @override
  Future<void> requestWindow(int from, int end) async {
    if (!_canDownload) {
      throw VideoSourceException('流式播放不可用（该文件不允许下载）');
    }

    // 1 KB alignment is what TDLib's chunking expects; the cost is at most
    // 1023 bytes downloaded early.
    final aligned = from & StreamWindow.alignMask;
    final limit = end - aligned + 1;
    await _issueWindow(
      aligned,
      limit,
      DownloadCaller.resourceLoader,
      _readOffset >= 0 ? 'player=$_readOffset' : 'player=?',
    );
  }

  /// Sends one bounded `downloadFile` and remembers it.
  Future<void> _issueWindow(
    int offset,
    int limit,
    DownloadCaller caller,
    String cause,
  ) async {
    if (limit <= 0) return;
    _requestedFrom = offset;
    _requestedLimit = limit;
    await _api.startRange(
      _fileId,
      offset: offset,
      limit: limit,
      // Priority 16: a window the reader is blocked on outranks a preload,
      // stays below the first-window transfer.
      priority: 16,
      caller: caller,
      cause: cause,
    );
  }

  @override
  Future<void> resumeSequential() async {
    if (_complete || _expected <= 0) return;
    final head = headBytes;
    if (head >= _expected) return;
    // The download TDLib is running still covers the byte the reader needs:
    // re-asking would restart a transfer that is already producing it.
    if (StreamWindow.windowCoversFrom(_requestedFrom, _requestedLimit, head) &&
        !windowExhausted) {
      return;
    }
    final (from, to) = StreamWindow.windowAt(head, _expected, size: windowBytes);

    await _issueWindow(
      from,
      StreamWindow.limitFor(from, to),
      DownloadCaller.proxy,
      'sequential',
    );
  }

  /// True when the window TDLib was given is fully on disk, so no further byte
  /// will arrive until another window is requested.
  ///
  /// Derived from the bytes actually observed rather than from a "finished"
  /// flag: TDLib does not announce "this window is done", it just goes quiet.
  @override
  bool get windowExhausted {
    if (_complete || _requestedLimit <= 0 || _requestedFrom < 0) return false;
    if (_present.covers(_requestedFrom, _requestedFrom + _requestedLimit - 1)) {
      return true;
    }
    // TDLib caps `downloaded_size` at the requested limit and occasionally
    // reports it a byte short; both mean the window is finished, and waiting
    // for the missing byte would burn the whole stall budget on a transfer
    // that has already stopped.
    return _windowOffset == _requestedFrom && _prefix >= _requestedLimit - 1;
  }

  /// The window TDLib was last given. Printed in the stall message so a device
  /// report says whether a stall happened *inside* a window or at its edge —
  /// the 4.9 MB proxy stall cannot be told apart from a spent window without
  /// these two numbers.
  @override
  int get windowFrom => _requestedFrom;

  @override
  int get windowLimit => _requestedLimit;

  @override
  Future<void> continueWindow({
    DownloadCaller caller = DownloadCaller.resourceLoader,
  }) async {
    if (_complete || _expected <= 0) return;
    if (!windowExhausted) return;
    final next = _requestedFrom + _requestedLimit;
    if (next >= _expected) return;
    final (from, to) = StreamWindow.windowAt(next, _expected, size: windowBytes);
    await _issueWindow(
      from,
      StreamWindow.limitFor(from, to),
      caller,
      'continue from $next',
    );
  }

  @override
  void markRead(int offset) {
    _readOffset = offset;
  }

  /// Measures the file and folds the result in.
  ///
  /// `updateFile` is the only thing that normally moves [_present]. A play that
  /// starts after TDLib stopped reporting the file would wait on silence, so
  /// one `stat` is taken — but a stat is a *length*, and a TDLib pool file can
  /// reach the full length with an unwritten middle. Completing on length
  /// alone is what made a 1.19 GB video show `100%` seconds after the tap and
  /// then fail to decode: `_present` was widened to the whole file while the
  /// bytes were not there.
  ///
  /// So the length only completes the file when TDLib's own counter already
  /// covers it. Otherwise the reading stays "not complete", the loader keeps
  /// asking, and the window machinery keeps downloading.
  @override
  Future<void> refresh() async {
    if (_path.isEmpty) return;
    if (_complete && _expected > 0) return;
    final size = await diskSizeOf(_path);
    if (size <= 0) return;
    if (_expected > 0 && size >= _expected && _countCovers) {
      _complete = true;
      _windowOffset = 0;
      _prefix = size;
      _present.add(0, _expected - 1);
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}

/// TDLib observation for [GrowingFileReader], read straight off the watch.
///
/// Purely a lens: no download call can be reached through it.
class _LiveProgressBridge implements TdProgressSource {
  _LiveProgressBridge(this._watch);

  final FileProgressWatch _watch;

  @override
  int get tdlibReach => _watch.headBytes;

  @override
  bool get tdlibCompleted => _watch.isComplete;

  @override
  bool get tdlibCanDownload => _watch.canDownload;

  @override
  Stream<void> get changes => _watch.progress;
}

/// Internal signal used to close a completer nobody is waiting for any more.
class _Abandoned implements Exception {
  @override
  String toString() => '_Abandoned';
}
