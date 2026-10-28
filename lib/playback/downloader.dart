/// The only module in the app allowed to ask TDLib to download.
///
/// The B+ architecture puts every `downloadFile` behind one door:
///
///   Downloader ── downloadFile(offset=0, limit=0) ── TDLib
///        │
///        └─ writes a local file that only ever grows
///
/// Players, the resource loader, the growing-file reader and preload never
/// reach TDLib's download API — not directly, not through a window, not as a
/// "fallback". A play that needs bytes asks *this* module to make sure a full
/// download is running, and then reads the file from disk.
///
/// `limit = 0` (whole file) exists here and only here. Everywhere else it is
/// an architecture violation, and the audit plus the static-scan CI test are
/// what keep that true.
library;

import 'dart:async';
import 'dart:io' show File;

import '../td/td_models.dart' show FileState;
import 'download_audit.dart';
import 'video_source.dart' show FileTransferApi, VideoSourceException;

/// How much free disk space the device reports, in bytes.
///
/// Returns `-1` when the platform cannot answer. Injected so tests describe
/// their own volume; the production wiring asks the host OS.
typedef FreeBytesProbe = Future<int> Function();

/// The state of the one full download this module manages per file.
enum FullDownloadState {
  /// No download has been requested for this file.
  idle,

  /// TDLib accepted `downloadFile(offset: 0, limit: 0)` and is writing.
  running,

  /// The transfer finished and the bytes were measured on disk.
  completed,

  /// Refused before TDLib was ever asked: not enough free space.
  diskFull,

  /// TDLib rejected or lost the transfer.
  failed,
}

/// One managed whole-file download.
class FullDownloadJob {
  FullDownloadJob({
    required this.fileId,
    required this.chatId,
    required this.messageId,
    required this.generation,
    required this.expectedSize,
    required this.startedAt,
  });

  final int fileId;
  final int chatId;
  final int messageId;
  final int generation;
  final int expectedSize;
  final DateTime startedAt;
  FullDownloadState state = FullDownloadState.running;
  String? failureReason;

  /// Why this job needed no TDLib request, when it did not.
  ///
  /// `already_on_disk`: the measured file already reaches the expected size, so
  /// the download was satisfied before it was sent. Recorded so the report can
  /// tell "the downloader ran" from "the downloader had nothing to do".
  String? shortcut;

  bool get isRunning => state == FullDownloadState.running;
}

/// The download authority.
///
/// Idempotent by construction: [ensureFullDownload] for a file that already
/// has a running job returns it instead of sending a second `downloadFile` —
/// TDLib would otherwise replace the running transfer with itself, and the
/// audit would show two whole-file calls for one tap.
class TelegramMediaDownloader {
  TelegramMediaDownloader({
    // The transport is private on purpose; `this._api` is not legal as a
    // named parameter, so the assignment stays in the initialiser list.
    required FileTransferApi api,
    required this.audit,
    FreeBytesProbe? freeBytes,
    // A download may use this fraction of the *remaining* bytes as headroom
    // before it is allowed to start. The task book's §14 rule:
    // requiredFreeSpace >= (expected - downloaded) × 1.5.
    this.safetyFactor = 1.5,
    // Silence longer than this means the transfer is dead, not slow. TDLib
    // pushes `updateFile` continuously while it writes, so a whole window with
    // no new byte is the only honest "it stopped" signal available.
    this.stallWindow = const Duration(seconds: 15),
    // How many times one job may be cancelled and re-issued before the play is
    // told the truth. Three covers a flapping radio without turning a dead
    // file into an infinite retry loop.
    this.maxStallRestarts = 3,
    this.stallPoll = const Duration(seconds: 3),
  })  :
        // ignore: prefer_initializing_formals
        _api = api,
        _freeBytes = freeBytes ?? _unavailableFreeBytes;

  final FileTransferApi _api;
  final DownloadAudit audit;
  final FreeBytesProbe _freeBytes;
  final double safetyFactor;

  /// Silence budget for one running job — see the constructor.
  final Duration stallWindow;
  final int maxStallRestarts;
  final Duration stallPoll;

  /// One job per file id. A second tap on the same video finds this entry
  /// and stops — the "same chatId+messageId, exactly one download" rule.
  final Map<int, FullDownloadJob> _jobs = <int, FullDownloadJob>{};

  /// Furthest byte TDLib has reported per file, and when it last moved.
  ///
  /// The job's own `running` flag cannot answer "is it still producing": TDLib
  /// has no failure event, so a transfer that died at 512 KB stays `running`
  /// forever and every waiter above it waits with it. That is the device
  /// report's "512 KB / 638 MB, 0.1 %, frozen" state.
  final Map<int, int> _reach = <int, int>{};
  final Map<int, DateTime> _lastAdvance = <int, DateTime>{};
  final Map<int, int> _restarts = <int, int>{};

  StreamSubscription<FileState>? _progress;
  Timer? _stallTimer;
  bool _disposed = false;

  /// Measured disk size of [path]; injectable for tests.
  Future<int> Function(String path) diskSizeOf = _defaultDiskSizeOf;

  static Future<int> _unavailableFreeBytes() async => -1;

  static Future<int> _defaultDiskSizeOf(String path) async {
    try {
      return await _fileLength(path);
    } on Object {
      return -1;
    }
  }

  static Future<int> _fileLength(String path) async {
    // dart:io import lives at the bottom of the file's import list; using a
    // helper keeps the try/catch sites uniform.
    final file = File(path);
    return file.length();
  }

  FullDownloadJob? jobFor(int fileId) => _jobs[fileId];

  /// Whether a whole-file transfer for [fileId] is believed to be running.
  bool isRunning(int fileId) => _jobs[fileId]?.isRunning ?? false;

  /// Marks a job dead when TDLib's own state says the transfer is over.
  ///
  /// Called from the reader's observation loop: TDLib has no explicit
  /// "failed" event, so "declared complete, or reported zero progress with
  /// `canBeDownloaded` false" is the closest honest signal.
  void observeTransfer({
    required int fileId,
    required bool completed,
    required bool canBeDownloaded,
  }) {
    final job = _jobs[fileId];
    if (job == null || job.state != FullDownloadState.running) return;
    if (completed) {
      job.state = FullDownloadState.completed;
      _lastAdvance.remove(fileId);
    } else if (!canBeDownloaded) {
      job.state = FullDownloadState.failed;
      job.failureReason = 'TDLib 报告文件不可再下载';
      _lastAdvance.remove(fileId);
    }
  }

  // ---- stall watchdog ---------------------------------------------------
  //
  // TDLib tells us when a transfer starts and when it finishes. It never tells
  // us it stopped. A transfer that dies mid-file therefore reads as `running`
  // forever: the job keeps `isRunning` true, every waiter above it keeps
  // waiting, and the report has nothing to say. The only evidence available is
  // the absence of new bytes, so that is what this measures.

  /// Seconds since TDLib last wrote a byte for [fileId], or null when the job
  /// has not been observed yet.
  Duration? stallAge(int fileId) {
    final last = _lastAdvance[fileId];
    if (last == null) return null;
    return DateTime.now().difference(last);
  }

  /// Furthest byte seen for [fileId] — `download_offset + downloaded_size`.
  int reachOf(int fileId) => _reach[fileId] ?? 0;

  /// Starts the one observer both the watchdog and the report read.
  ///
  /// Lazily: a Downloader that never started a job must not subscribe to the
  /// update stream at all.
  void _ensureObserver() {
    if (_progress != null || _disposed) return;
    _progress = _api.updates().listen(
      (state) {
        final job = _jobs[state.id];
        if (job == null || !job.isRunning) return;
        final reach = state.downloadOffset + state.downloadedSize;
        final before = _reach[state.id];
        // Monotonic on purpose: a window move reports a smaller
        // `downloaded_size`, and that is not a byte going backwards.
        if (before == null || reach > before) {
          _reach[state.id] = reach;
          _lastAdvance[state.id] = DateTime.now();
        }
      },
      onError: (Object _) {
        // A broken update stream is not a reason to lose the timer: the sweep
        // falls back to `stat`, which is the same measurement one step later.
      },
    );
    _stallTimer = Timer.periodic(stallPoll, (_) => _sweep());
  }

  Future<void> _sweep() async {
    if (_disposed) return;
    var running = 0;
    for (final job in _jobs.values.toList()) {
      if (!job.isRunning) continue;
      running++;
      final fileId = job.fileId;
      final last = _lastAdvance[fileId];
      if (last == null) {
        // First sweep after the request: the baseline is the request time, not
        // the epoch — otherwise every job would look stalled for 50 years.
        _lastAdvance[fileId] = job.startedAt;
        continue;
      }
      if (DateTime.now().difference(last) < stallWindow) continue;

      // Before declaring it dead, ask TDLib directly. Updates can be missed (a
      // broadcast event fired between two awaits), and cancelling a healthy
      // transfer would restart a 638 MB download for nothing.
      final state = await _api.stat(fileId);
      if (state != null) {
        final reach = state.downloadOffset + state.downloadedSize;
        final before = _reach[fileId] ?? 0;
        if (reach > before) {
          _reach[fileId] = reach;
          _lastAdvance[fileId] = DateTime.now();
          continue;
        }
        if (state.isCompleted) {
          job.state = FullDownloadState.completed;
          audit.note('DOWNLOAD_DONE file=$fileId reached=$reach');
          continue;
        }
      }
      if (!job.isRunning) continue;

      final age = DateTime.now().difference(last).inSeconds;
      final tries = _restarts[fileId] ?? 0;
      if (tries >= maxStallRestarts) {
        job.state = FullDownloadState.failed;
        job.failureReason = '下载停滞 ${age}s，已重试 $tries 次';
        audit.note('DOWNLOAD_STALLED file=$fileId age=${age}s '
            'retries=$tries reached=${_reach[fileId] ?? 0} '
            'expected=${job.expectedSize} giving_up');
        _lastAdvance.remove(fileId);
        continue;
      }
      _restarts[fileId] = tries + 1;
      audit.note('DOWNLOAD_STALL file=$fileId age=${age}s '
          'retries=${tries + 1}/$maxStallRestarts '
          'reached=${_reach[fileId] ?? 0} expected=${job.expectedSize}');
      try {
        // Same cancel+issue pair as `restart`, but driven by silence instead of
        // by a claim: this is the only way to turn a dead transfer back into a
        // growing file.
        await _api.cancel(fileId);
        await _api.start(
          fileId,
          caller: DownloadCaller.downloader,
          cause: 'stall restart ${tries + 1}',
        );
        _lastAdvance[fileId] = DateTime.now();
        _reach[fileId] = _reach[fileId] ?? 0;
      } on Object catch (e) {
        job.state = FullDownloadState.failed;
        job.failureReason = '下载停滞且重启失败：$e';
        audit.note('DOWNLOAD_RESTART_FAILED file=$fileId error="$e"');
      }
    }
    if (running == 0) _stopObserver();
  }

  void _stopObserver() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _progress?.cancel();
    _progress = null;
  }

  /// Stops the watchdog. Called when the app tears the playback layer down.
  void dispose() {
    _disposed = true;
    _stopObserver();
    _jobs.clear();
    _reach.clear();
    _lastAdvance.clear();
    _restarts.clear();
  }

  /// Makes sure a full download exists for [fileId], starting one if needed.
  ///
  /// Returns the job (running, completed, or — when the disk check refuses —
  /// `diskFull` with no TDLib call behind it). Never starts a second transfer
  /// for a file that already has one.
  Future<FullDownloadJob> ensureFullDownload({
    required int chatId,
    required int messageId,
    required int fileId,
    required int expectedSize,
    int generation = 0,
    String cause = 'b+ auto full download',
  }) async {
    final existing = _jobs[fileId];
    if (existing != null && existing.isRunning) return existing;

    // Disk rule, measured before anything is asked of TDLib. `remaining` is
    // what is still missing on disk, not the whole file: a half-downloaded
    // video needs room for its other half, and then some.
    int diskSize = -1;
    final path = await _localPath(fileId);
    if (path != null) diskSize = await diskSizeOf(path);
    final remaining = expectedSize > 0 && diskSize >= 0
        ? expectedSize - diskSize
        : expectedSize;

    // Nothing to download: the file already reaches the expected size.
    //
    // Sending `downloadFile` anyway is not harmless. TDLib re-opens the
    // transfer for that file and reports `is_downloading_completed = false`
    // while it re-checks, which is how the device report ended up printing
    // `disk=162308586 B FULL`, `downloaded=100.0%` and `completed=false` at
    // once — and how a play on a finished video kept a WHOLE_FILE call and a
    // `grew=0` line in the audit.
    if (expectedSize > 0 && diskSize >= expectedSize) {
      final job = _jobs[fileId] ??= FullDownloadJob(
        fileId: fileId,
        chatId: chatId,
        messageId: messageId,
        generation: generation,
        expectedSize: expectedSize,
        startedAt: DateTime.now(),
      );
      job.state = FullDownloadState.completed;
      job.failureReason = null;
      job.shortcut = 'already_on_disk';
      return job;
    }

    if (remaining > 0) {
      final free = await _freeBytes();
      if (free >= 0) {
        final required = (remaining * safetyFactor).ceil();
        if (free < required) {
          final job = FullDownloadJob(
            fileId: fileId,
            chatId: chatId,
            messageId: messageId,
            generation: generation,
            expectedSize: expectedSize,
            startedAt: DateTime.now(),
          );
          job.state = FullDownloadState.diskFull;
          job.failureReason =
              '磁盘空间不足：需要 ≥$required 字节（含安全余量），可用 $free 字节';
          _jobs[fileId] = job;
          audit.noteArchitectureViolation(
            'DISK_FULL file=$fileId expected=$expectedSize disk=$diskSize '
            'free=$free required=$required',
          );
          return job;
        }
      }
      // Free space unknown: the play continues, but the report says so — a
      // silent skip would hide the rule behind a platform gap.
    }

    final job = _jobs[fileId] ??= FullDownloadJob(
      fileId: fileId,
      chatId: chatId,
      messageId: messageId,
      generation: generation,
      expectedSize: expectedSize,
      startedAt: DateTime.now(),
    );
    job.state = FullDownloadState.running;
    job.failureReason = null;
    job.shortcut = null;
    // The watchdog's baseline is the moment the request is sent: bytes only
    // exist after TDLib accepts it.
    _reach.remove(fileId);
    _lastAdvance[fileId] = DateTime.now();
    _ensureObserver();
    audit.tag(
      chatId: chatId,
      messageId: messageId,
      generation: generation,
    );
    try {
      await _api.start(
        fileId,
        caller: DownloadCaller.downloader,
        cause: cause,
      );
    } on Object catch (e) {
      // TDLib refused the request: there is no transfer to wait for, and a
      // job left `running` would make every recovery path poll a download
      // that does not exist.
      job.state = FullDownloadState.failed;
      job.failureReason = '$e';
      rethrow;
    }
    return job;
  }

  /// Cancels and re-issues the whole-file request.
  ///
  /// TDLib considers a transfer "finished" even when the file on disk is
  /// short — the one shape where waiting can never help, because no bytes are
  /// ever coming. The restart is what turns that state back into progress,
  /// and it lives *here* so the cancel/issue pair is visible as one audit
  /// entry instead of two unrelated calls.
  Future<FullDownloadJob> restart({
    required int chatId,
    required int messageId,
    required int fileId,
    required int expectedSize,
    int generation = 0,
  }) async {
    await _api.cancel(fileId);
    _jobs.remove(fileId);
    // An explicit restart is a new budget: the previous stall counter is about
    // a transfer that no longer exists.
    _restarts.remove(fileId);
    _reach.remove(fileId);
    _lastAdvance.remove(fileId);
    return ensureFullDownload(
      chatId: chatId,
      messageId: messageId,
      fileId: fileId,
      expectedSize: expectedSize,
      generation: generation,
      cause: 'restart: tdlib complete but disk short',
    );
  }

  Future<void> cancel(int fileId) async {
    _jobs.remove(fileId);
    await _api.cancel(fileId);
  }

  /// The local path TDLib has named for [fileId], or null when it has none.
  Future<String?> _localPath(int fileId) async {
    final state = await _api.stat(fileId);
    final path = state?.path;
    return (path == null || path.isEmpty) ? null : path;
  }
}

/// Thrown by the play chain when the disk refused the download.
class DiskFullException extends VideoSourceException {
  DiskFullException(super.message);
}
