/// The single owner of video byte transfers.
///
/// Contract, in the order the code enforces it:
///
/// * at most **one** real transfer at a time — starting a new one cancels the
///   previous one instead of racing it;
/// * a cache hit is decided by [CacheValidator], never by a byte count;
/// * a finished transfer is verified on disk before it is announced as ready;
/// * a stalled transfer is detected from "no new bytes", restarted at most
///   twice, then reported as a failure instead of hanging forever;
/// * cancelling never produces a "complete" state;
/// * a run that finishes after a newer one started cannot touch the newer
///   run's state (see [_Run]) — otherwise starting video #2 would leave the
///   manager believing nothing is downloading.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/media_record.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';
import 'cache_validator.dart';
import 'download_speed.dart';
import 'download_state.dart';
import 'media_cache.dart';

/// The two TDLib calls the manager needs, behind an interface so the state
/// machine can be tested without a phone.
abstract class TdTransport {
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  });

  Stream<Map<String, Object?>> get updates;
}

class TdClientTransport implements TdTransport {
  TdClientTransport(this._client,
      {this.defaultTimeout = const Duration(seconds: 30)});

  final TdClient _client;
  final Duration defaultTimeout;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) =>
      _client.request(request, timeout: timeout ?? defaultTimeout);

  @override
  Stream<Map<String, Object?>> get updates => _client.updates;
}

/// One accepted `ensureLocal` call and the future it will end.
///
/// Identity is what ownership is decided on: `identical(_run, run)` means this
/// run still owns the manager's published state.
class _Run {
  _Run(this.record);

  final MediaRecord record;
  final Completer<DownloadOutcome> outcome = Completer<DownloadOutcome>();
}

class DownloadManager extends ChangeNotifier implements MediaPreparer {
  DownloadManager({
    required this.transport,
    required this.validator,
    required this.cache,
    this.pollInterval = const Duration(milliseconds: 500),
    this.stallTimeout = const Duration(seconds: 25),
    this.maxStallRetries = 1,
    this.requestTimeout = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TdTransport transport;
  final CacheValidator validator;
  final MediaCache cache;

  /// How often the timer samples the transfer for speed and stalls.
  final Duration pollInterval;

  /// No new byte for this long while the file is not complete = stalled.
  /// Long enough to survive a slow server, short enough that the user is not
  /// left staring at a frozen percentage.
  final Duration stallTimeout;

  final int maxStallRetries;
  final Duration requestTimeout;
  final DateTime Function() _clock;

  final SpeedMeter _speed = SpeedMeter();

  DownloadState _state = DownloadState.idle;
  @override
  DownloadState get state => _state;

  _Run? _run;

  int? _activeFileId;
  @override
  int? get activeFileId => _activeFileId;

  StreamSubscription<Map<String, Object?>>? _subscription;
  Timer? _timer;
  int _lastBytes = 0;
  int _totalBytes = 0;
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _retries = 0;
  bool _cancelled = false;
  bool _disposed = false;

  /// MediaRecord currently being prepared, for diagnostics in the badge.
  MediaRecord? get activeRecord => _run?.record;

  void _publish(DownloadState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  /// Ensures [record] is a verified local file and returns its path.
  ///
  /// Concurrent calls for the same file join the running transfer; a call for a
  /// different file cancels it first. That is the "one download at a time" rule
  /// expressed as code rather than as a convention.
  @override
  Future<DownloadOutcome> ensureLocal(MediaRecord record) async {
    if (record.fileId == 0) {
      return const DownloadOutcome.failed(DownloadFailure.notDownloadable);
    }
    final running = _run;
    if (running != null && running.record.fileId == record.fileId) {
      return running.outcome.future;
    }
    if (_activeFileId != null) {
      await cancel();
    }

    _cancelled = false;
    _retries = 0;
    _activeFileId = record.fileId;
    final run = _Run(record);
    _run = run;
    _speed.reset();

    final outcome = await _prepare(run);
    // `_prepare` returns only when the transfer ended (ready, failed or
    // cancelled), so this is the single exit point. `_settle` is idempotent and
    // refuses to tear down a newer run's state.
    _settle(run, outcome);
    return outcome;
  }

  bool _owns(_Run run) => !_disposed && identical(_run, run);

  Future<DownloadOutcome> _prepare(_Run run) async {
    final record = run.record;
    _publish(DownloadState(
      phase: DownloadPhase.checking,
      totalBytes: record.sizeBytes,
    ));

    final file = await _getFile(record.fileId);
    if (!_owns(run)) return const DownloadOutcome.failed(DownloadFailure.cancelled);
    if (file == null) {
      return const DownloadOutcome.failed(DownloadFailure.network,
          detail: 'getFile returned no file');
    }

    final total = file.size > 0 ? file.size : file.expectedSize;
    _totalBytes = total > 0 ? total : record.sizeBytes;

    final verdict = await validator.validate(
      path: file.path,
      expectedSize: _totalBytes,
      downloadCompleted: file.isCompleted,
    );
    if (!_owns(run)) return const DownloadOutcome.failed(DownloadFailure.cancelled);
    if (verdict.isPlayable) {
      _publish(DownloadState(
        phase: DownloadPhase.ready,
        receivedBytes: _totalBytes,
        totalBytes: _totalBytes,
        localPath: file.path,
      ));
      return DownloadOutcome.ready(file.path);
    }
    if (_cancelled) {
      return const DownloadOutcome.failed(DownloadFailure.cancelled);
    }

    if (verdict.shouldDelete) {
      // Bytes that are the wrong size or unreadable are worse than no bytes:
      // TDLib will not re-fetch them otherwise.
      await _discard(record.fileId);
    }

    if (!await cache.hasRoomFor(_totalBytes)) {
      return const DownloadOutcome.failed(DownloadFailure.insufficientSpace);
    }
    if (!_owns(run)) return const DownloadOutcome.failed(DownloadFailure.cancelled);

    // A partial file reports `downloaded_size` relative to `download_offset`.
    // Since every request here is `offset = 0`, the contiguous prefix is the
    // only number that can be shown as absolute progress.
    return _start(run,
        startBytes: verdict == CacheVerdict.incomplete
            ? file.downloadedPrefixSize
            : 0);
  }

  Future<DownloadOutcome> _start(_Run run, {required int startBytes}) async {
    _lastBytes = startBytes < 0 ? 0 : startBytes;
    _lastProgressAt = _clock();
    _speed.begin(_lastBytes, _lastProgressAt);
    _publish(DownloadState(
      phase: DownloadPhase.downloading,
      receivedBytes: _lastBytes,
      totalBytes: _totalBytes,
    ));

    _subscription = transport.updates.listen((event) => _onUpdate(event, run));
    _timer = Timer.periodic(pollInterval, (_) => _tick(run));

    final response = await _request(downloadFile(
      fileId: run.record.fileId,
      priority: 32,
      offset: 0,
      limit: 0,
    ));
    final error = errorText(response);
    if (error != null) {
      return DownloadOutcome.failed(_classify(error), detail: error);
    }
    // Either the transfer completes through `updateFile`, or the timer reports
    // the stall. Both paths end the same future.
    return run.outcome.future;
  }

  void _onUpdate(Map<String, Object?> event, _Run run) {
    if (!identical(_run, run)) return;
    if (!_isUpdateFile(event, run.record.fileId)) return;
    final fileJson = event['file'];
    if (fileJson is! Map) return;
    _applyFileState(FileState.fromJson(fileJson.cast<String, Object?>()), run);
  }

  static bool _isUpdateFile(Map<String, Object?> event, int fileId) {
    if (event['@type'] != 'updateFile') return false;
    final file = event['file'];
    if (file is! Map) return false;
    final id = file['id'];
    return id == fileId;
  }

  void _applyFileState(FileState file, _Run run) {
    if (_disposed || !identical(_run, run)) return;
    final now = _clock();
    _lastBytes = file.downloadedSize;
    if (file.size > 0) _totalBytes = file.size;
    _speed.sample(file.downloadedSize, now);
    _lastProgressAt = now;

    if (file.isCompleted) {
      unawaited(_verify(file, now, run));
      return;
    }
    _publish(_state.copyWith(
      phase: DownloadPhase.downloading,
      receivedBytes: file.downloadedSize,
      totalBytes: _totalBytes,
      bytesPerSecond: _speed.bytesPerSecond,
    ));
  }

  Future<void> _verify(FileState file, DateTime now, _Run run) async {
    _speed.reset();
    _publish(DownloadState(
      phase: DownloadPhase.verifying,
      receivedBytes: _totalBytes,
      totalBytes: _totalBytes,
      bytesPerSecond: 0,
      localPath: file.path,
    ));
    final verdict = await validator.validate(
      path: file.path,
      expectedSize: _totalBytes,
      downloadCompleted: true,
    );
    if (!identical(_run, run)) {
      if (!run.outcome.isCompleted) {
        run.outcome.complete(
          const DownloadOutcome.failed(DownloadFailure.cancelled),
        );
      }
      return;
    }
    if (verdict.isPlayable) {
      _publish(DownloadState(
        phase: DownloadPhase.ready,
        receivedBytes: _totalBytes,
        totalBytes: _totalBytes,
        localPath: file.path,
      ));
      _settle(run, DownloadOutcome.ready(file.path));
      return;
    }
    // Completed by TDLib but not usable on disk: delete and report, so the
    // next attempt starts from zero instead of trusting the same bytes.
    await _discard(run.record.fileId);
    _settle(
      run,
      DownloadOutcome.failed(
        verdict == CacheVerdict.unreadable
            ? DownloadFailure.corrupt
            : DownloadFailure.storage,
        detail: verdict.name,
      ),
    );
  }

  void _tick(_Run run) {
    if (_disposed || !identical(_run, run)) return;
    final now = _clock();
    _speed.tick(now);

    if (_state.phase == DownloadPhase.downloading) {
      _publish(_state.copyWith(
        receivedBytes: _lastBytes,
        totalBytes: _totalBytes,
        bytesPerSecond: _speed.bytesPerSecond,
      ));
    }

    if (_state.phase != DownloadPhase.downloading) return;
    if (now.difference(_lastProgressAt) < stallTimeout) return;
    unawaited(_recoverStall(run));
  }

  /// A transfer that stopped reporting. TDLib has no "the transfer died" event,
  /// so this is the only place that can notice. One restart is worth trying;
  /// after that the honest answer is a failure the user can retry.
  Future<void> _recoverStall(_Run run) async {
    if (!identical(_run, run)) return;
    if (_retries >= maxStallRetries) {
      _publish(_state.copyWith(
        phase: DownloadPhase.failed,
        failure: DownloadFailure.network,
        bytesPerSecond: 0,
        detail: 'stalled at $_lastBytes of $_totalBytes',
      ));
      _settle(
        run,
        const DownloadOutcome.failed(DownloadFailure.network,
            detail: 'stalled'),
      );
      return;
    }
    _retries++;
    _lastProgressAt = _clock();
    await _request(cancelDownloadFile(fileId: run.record.fileId));
    final response = await _request(downloadFile(
      fileId: run.record.fileId,
      priority: 32,
      offset: 0,
      limit: 0,
    ));
    final error = errorText(response);
    if (error != null) {
      _settle(run, DownloadOutcome.failed(_classify(error), detail: error));
    }
  }

  /// User-initiated stop. Always ends in [DownloadFailure.cancelled], never in
  /// a completed state.
  @override
  Future<void> cancel() async {
    final run = _run;
    final fileId = _activeFileId;
    _cancelled = true;
    if (fileId != null) {
      await _request(cancelDownloadFile(fileId: fileId));
    }
    if (run != null) {
      _publish(_state.copyWith(
        phase: DownloadPhase.cancelled,
        failure: DownloadFailure.cancelled,
        bytesPerSecond: 0,
      ));
      _settle(run, const DownloadOutcome.failed(DownloadFailure.cancelled));
    } else {
      _teardown();
      _activeFileId = null;
    }
  }

  /// Ends [run] and clears the manager's state — but only if [run] is still the
  /// current one. A run that was cancelled by a newer `ensureLocal` must not
  /// wipe that newer run's subscription, timer or file id.
  void _settle(_Run run, DownloadOutcome outcome) {
    if (identical(_run, run)) {
      _teardown();
      _activeFileId = null;
      _run = null;
    }
    if (!run.outcome.isCompleted) run.outcome.complete(outcome);
  }

  void _teardown() {
    _subscription?.cancel();
    _subscription = null;
    _timer?.cancel();
    _timer = null;
  }

  Future<FileState?> _getFile(int fileId) async {
    final response = await _request(getFile(fileId));
    final error = errorText(response);
    if (error != null) return null;
    return fileFromResponse(response);
  }

  Future<void> _discard(int fileId) async {
    if (fileId <= 0) return;
    await _request(deleteFile(fileId));
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> request) async {
    try {
      return await transport.request(request, timeout: requestTimeout);
    } on Object catch (e) {
      return <String, Object?>{
        '@type': 'error',
        'code': -1,
        'message': '$e',
      };
    }
  }

  static DownloadFailure _classify(String error) {
    final text = error.toUpperCase();
    if (text.contains('DISK') || text.contains('STORAGE')) {
      return DownloadFailure.insufficientSpace;
    }
    if (text.contains('NOT ENOUGH') || text.contains('TOO BIG')) {
      return DownloadFailure.insufficientSpace;
    }
    if (text.contains('CAN_BE_DOWNLOADED')) {
      return DownloadFailure.notDownloadable;
    }
    return DownloadFailure.network;
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    final run = _run;
    _run = null;
    _activeFileId = null;
    if (run != null && !run.outcome.isCompleted) {
      run.outcome.complete(
        const DownloadOutcome.failed(DownloadFailure.cancelled),
      );
    }
    super.dispose();
  }
}
