import 'dart:async';

import '../playback/byte_window.dart';
import '../playback/range_server.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

/// Exposes one TDLib file as a range-readable byte source.
///
/// Contract with TDLib:
/// * the whole-file download is started with `offset = 0, limit = 0`. Offset
///   trickery is deliberately avoided: a partial download moves
///   `local.download_offset`, which would shift every byte in the pool file and
///   break the mapping this class exists to maintain;
/// * readability is decided from `downloaded_prefix_size`, never from
///   `downloaded_size` — the latter counts bytes anywhere in the file and would
///   let the server read holes;
/// * the file is polled on `updateFile` plus a slow timer, because waiting on
///   updates alone can stall when TDLib is busy and sends none.
class TdStreamSource implements StreamByteSource {
  TdStreamSource({
    required this.client,
    required this.fileId,
    required this.expectedBytes,
    required this.contentType,
    this.tick = const Duration(milliseconds: 60),
  });

  final TdClient client;
  final int fileId;

  @override
  final String contentType;

  /// How often `updateFile` is not enough and the state is re-polled.
  final Duration tick;

  /// Size TDLib reported for the file, used until the first `updateFile`.
  final int expectedBytes;
  FileState? _state;
  StreamSubscription<Map<String, Object?>>? _subscription;
  bool _downloadRequested = false;
  bool _released = false;
  DateTime? _lastRequest;

  @override
  int get totalBytes {
    final state = _state;
    if (state != null && state.totalSize > 0) return state.totalSize;
    return expectedBytes;
  }

  /// Latest window TDLib reported, or null when the pool file has no usable
  /// prefix yet.
  FileWindow? get window => windowOf(_state);

  void start() {
    if (_subscription != null || _released) return;
    _subscription = client.fileUpdates.listen((file) {
      final state = FileState.fromJson(file);
      if (state.id == fileId) _state = state;
    });
  }

  @override
  Future<FileWindow?> ensureReadable(
    int position, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    start();
    await _ensureDownloadRequested();
    final deadline = DateTime.now().add(timeout);
    while (!_released) {
      final current = window;
      if (current != null && current.covers(position, 1)) return current;
      if (DateTime.now().isAfter(deadline)) return null;
      // TDLib can drop a download after a network change; re-ask occasionally
      // instead of waiting forever on a request that no longer exists.
      await _ensureDownloadRequested(force: true);
      await Future<void>.delayed(tick);
    }
    return null;
  }

  Future<void> _ensureDownloadRequested({bool force = false}) async {
    if (_released) return;
    final now = DateTime.now();
    if (!force && _downloadRequested) return;
    if (force && _lastRequest != null) {
      // `downloadFile` is idempotent, but re-sending it on every 60 ms poll
      // floods the client for no benefit.
      if (now.difference(_lastRequest!) < const Duration(seconds: 2)) return;
    }
    _downloadRequested = true;
    _lastRequest = now;
    try {
      await client.request(
        downloadFile(fileId: fileId, priority: 32, synchronous: false),
        timeout: const Duration(seconds: 20),
      );
    } catch (_) {
      // A failed request is retried by the next poll; the caller has a timeout
      // of its own and will fall back to the whole-file path.
      _downloadRequested = false;
    }
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// Turns a TDLib file state into the readable window.
///
/// Two rules that are easy to get wrong and are pinned by tests:
/// * `downloaded_prefix_size` wins; when TDLib reports 0 but the download is
///   complete, the whole file is readable (older TDLib builds do not fill the
///   prefix field);
/// * an empty path means TDLib has not decided where to put the bytes yet, so
///   nothing is readable even if the counters look healthy.
FileWindow? windowOf(FileState? state) {
  if (state == null) return null;
  if (state.path.isEmpty) return null;
  final prefix = state.downloadedPrefixSize > 0
      ? state.downloadedPrefixSize
      : (state.isCompleted ? state.totalSize : 0);
  if (prefix <= 0) return null;
  return FileWindow(
    path: state.path,
    offset: state.downloadOffset,
    prefixSize: prefix,
  );
}

/// Small helper so a caller can read a "how much is available from here" answer
/// without opening the pool file.
Future<int> downloadedPrefixSize(
  TdClient client, {
  required int fileId,
  required int offset,
}) async {
  final response = await client.request(
    getFileDownloadedPrefixSize(fileId: fileId, offset: offset),
    timeout: const Duration(seconds: 20),
  );
  final error = errorText(response);
  if (error != null) return 0;
  final size = response['size'];
  return size is int ? size : 0;
}
