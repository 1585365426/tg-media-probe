/// The states a local-file download can be in.
///
/// One rule shapes every field here: a state is only ever published from
/// something TDLib or the filesystem actually said. There is no "assume it is
/// done" branch, and [DownloadPhase.ready] is reachable from exactly one place
/// in the manager after all four checks passed.
library;

import 'package:flutter/foundation.dart';

import '../data/media_record.dart';
import '../util/byte_format.dart';

enum DownloadPhase {
  /// Nothing requested yet.
  idle,

  /// Looking at the local cache / TDLib's view of the file.
  checking,

  /// Bytes are moving. `bytesPerSecond` is measured, never synthesised.
  downloading,

  /// TDLib says complete; the file is being checked on disk.
  verifying,

  /// Complete **and** verified. The only phase the player may open.
  ready,

  /// Stopped with a reason the user can act on.
  failed,

  /// Stopped by the user. Never reported as ready.
  cancelled,
}

/// Why a download did not end in [DownloadPhase.ready].
enum DownloadFailure {
  none,
  network,
  insufficientSpace,
  corrupt,
  notDownloadable,
  cancelled,
  storage,
}

extension DownloadFailureText on DownloadFailure {
  /// User-facing sentence. Kept in the model so the player page, the list row
  /// and the badge cannot disagree about what went wrong.
  String get message => switch (this) {
        DownloadFailure.none => '',
        DownloadFailure.network => '网络连接失败，请重试',
        DownloadFailure.insufficientSpace => '磁盘空间不足，请清理空间后重试',
        DownloadFailure.corrupt => '本地文件损坏，需要重新下载',
        DownloadFailure.notDownloadable => '该视频无法下载',
        DownloadFailure.cancelled => '已取消下载',
        DownloadFailure.storage => '本地文件写入失败',
      };

  bool get isRetryable => switch (this) {
        DownloadFailure.network || DownloadFailure.corrupt => true,
        _ => false,
      };
}

@immutable
class DownloadState {
  const DownloadState({
    this.phase = DownloadPhase.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
    this.localPath,
    this.failure = DownloadFailure.none,
    this.detail,
  });

  static const DownloadState idle = DownloadState();

  final DownloadPhase phase;

  /// Bytes on disk for this file, as TDLib reports them.
  final int receivedBytes;

  /// `file.size` when known, else `expected_size`. 0 means "not known yet".
  final int totalBytes;

  /// Measured throughput. 0 when no transfer is running.
  final double bytesPerSecond;

  /// Real path from `file.local.path`. Only non-null in [DownloadPhase.ready].
  final String? localPath;

  final DownloadFailure failure;

  /// Extra context for logs, never a stack trace and never shown raw.
  final String? detail;

  bool get isReady => phase == DownloadPhase.ready && localPath != null;

  bool get isBusy =>
      phase == DownloadPhase.checking ||
      phase == DownloadPhase.downloading ||
      phase == DownloadPhase.verifying;

  bool get isFailed => phase == DownloadPhase.failed;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// `50 MB / 500 MB`, or an em dash while the size is unknown.
  String get progressLabel => totalBytes <= 0
      ? formatBytes(receivedBytes)
      : '${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}';

  DownloadState copyWith({
    DownloadPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    double? bytesPerSecond,
    String? localPath,
    DownloadFailure? failure,
    String? detail,
    bool clearPath = false,
  }) {
    return DownloadState(
      phase: phase ?? this.phase,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      localPath: clearPath ? null : (localPath ?? this.localPath),
      failure: failure ?? this.failure,
      detail: detail ?? this.detail,
    );
  }

  @override
  String toString() =>
      'DownloadState(${phase.name}, $receivedBytes/$totalBytes, '
      '${bytesPerSecond.toStringAsFixed(0)}B/s, ${failure.name})';
}

/// Result of `DownloadManager.ensureLocal`: either a verified path or a reason.
@immutable
class DownloadOutcome {
  const DownloadOutcome.ready(String this.path)
      : failure = DownloadFailure.none,
        detail = null;

  const DownloadOutcome.failed(this.failure, {this.detail}) : path = null;

  final String? path;
  final DownloadFailure failure;
  final String? detail;

  bool get isReady => path != null;

  String get message => failure.message;

  @override
  String toString() =>
      isReady ? 'DownloadOutcome.ready($path)' : 'DownloadOutcome.failed($failure)';
}

/// What the player needs from the download layer.
///
/// The player must not know that TDLib exists, and a widget test must be able to
/// drive the page without touching the filesystem — real file IO never completes
/// inside the test binding's fake-async zone, so an abstraction here is what
/// keeps the page testable at all.
abstract class MediaPreparer implements Listenable {
  DownloadState get state;

  /// File id of the transfer in progress, or null.
  int? get activeFileId;

  /// Resolves to a verified local path, or a failure the UI can show.
  Future<DownloadOutcome> ensureLocal(MediaRecord record);

  Future<void> cancel();
}
