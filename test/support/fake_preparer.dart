/// In-memory [MediaPreparer]. No filesystem, no TDLib: a widget test can then
/// assert what the page does with a ready file or a failure without waiting on
/// real IO (which never completes inside the test binding's fake-async zone).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/download/download_state.dart';

class FakePreparer extends ChangeNotifier implements MediaPreparer {
  FakePreparer({
    this.path = '/fake/video.mp4',
    this.failure,
    this.detail,
    this.inFlight,
  });

  final String path;
  final DownloadFailure? failure;
  final String? detail;

  /// State published while [ensureLocal] is still waiting, so a test can look
  /// at the screen mid-transfer. The wait ends when [release] is called.
  final DownloadState? inFlight;

  final List<MediaRecord> requests = <MediaRecord>[];
  int cancelCount = 0;

  final Completer<void> _released = Completer<void>();

  /// Finishes an in-flight [ensureLocal]. Safe to call when nothing is held.
  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  bool get isHeld => inFlight != null && !_released.isCompleted;

  DownloadState _state = DownloadState.idle;

  @override
  DownloadState get state => _state;

  @override
  int? get activeFileId => _active;

  int? _active;

  @override
  Future<DownloadOutcome> ensureLocal(MediaRecord record) async {
    requests.add(record);
    _active = record.fileId;
    final held = inFlight;
    if (held != null) {
      _state = held;
      notifyListeners();
      await _released.future;
    }
    final result = failure == null
        ? DownloadOutcome.ready(path)
        : DownloadOutcome.failed(failure!, detail: detail);
    _state = result.isReady
        ? DownloadState(
            phase: DownloadPhase.ready,
            receivedBytes: record.sizeBytes,
            totalBytes: record.sizeBytes,
            localPath: path,
          )
        : DownloadState(phase: DownloadPhase.failed, failure: failure!);
    notifyListeners();
    return result;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }
}
