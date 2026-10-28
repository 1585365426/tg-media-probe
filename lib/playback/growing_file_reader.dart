/// Reads a file that the Downloader is still writing.
///
/// This class sits between the downloader and the player's byte supply. It
/// owns exactly one number — the safe watermark — and one rule:
///
///   safeWatermark = min(TDLib downloaded reach, filesystem stat size)
///
/// The min is the whole point. TDLib's `downloaded_size` is what TDLib
/// *believes* it wrote; the stat is what the filesystem actually holds. A
/// report once showed TDLib claiming 100 MB while 80 MB existed — trusting
/// either alone serves a hole as video. Both numbers must agree before a
/// byte is called readable.
///
/// It never talks to TDLib's download API. It observes the `updateFile`
/// stream (read-only) and stats the file — that is all. If the bytes a
/// player asked for are past the watermark and the download is not done, the
/// answer is WAIT, never EOF, and the timeout is [waitTimeout].
library;

import 'dart:async';
import 'dart:io' show File;

import '../td/td_models.dart' show FileState;

/// Where TDLib's own progress stands, as the reader may see it.
///
/// Implemented by the resolver's live file watch — observation only, no
/// download authority. Kept as an interface so tests can script the
/// TDLib side without a client.
abstract class TdProgressSource {
  /// `download_offset + downloaded_size`: how far TDLib has written.
  int get tdlibReach;

  /// TDLib considers the transfer finished.
  bool get tdlibCompleted;

  /// Fired whenever TDLib reports new state for the file.
  Stream<void> get changes;

  /// True while TDLib would keep downloading this file.
  bool get tdlibCanDownload;
}

/// What [GrowingFileReader.read] found at an offset.
class ReadResult {
  const ReadResult._({
    required this.available,
    required this.readableTo,
    required this.watermark,
    required this.completed,
  });

  /// Bytes [offset]..[readableTo] (inclusive) may be served from disk.
  const ReadResult.available({
    required int offset,
    required int readableTo,
    required int watermark,
  }) : this._(
          available: true,
          readableTo: readableTo,
          watermark: watermark,
          completed: false,
        );

  /// Nothing readable at [offset] yet — wait, not EOF.
  const ReadResult.waiting({required int watermark})
      : this._(
          available: false,
          readableTo: -1,
          watermark: watermark,
          completed: false,
        );

  /// The whole file is on disk and measured.
  const ReadResult.complete({required int expectedSize})
      : this._(
          available: true,
          readableTo: expectedSize - 1,
          watermark: expectedSize,
          completed: true,
        );

  final bool available;
  final int readableTo;
  final int watermark;
  final bool completed;
}

/// Why [GrowingFileReader.waitFor] gave up.
enum WaitOutcome {
  /// The watermark passed the requested offset.
  arrived,

  /// The whole file is on disk.
  completed,

  /// [GrowingFileReader.waitTimeout] elapsed without growth.
  timeout,

  /// The reader was invalidated (a newer play owns the file now).
  invalidated,
}

/// The one reader for one growing file and one play generation.
class GrowingFileReader {
  GrowingFileReader({
    required this.path,
    required this.expectedSize,
    required this.generation,
    // Observation source, kept private: a named parameter cannot start with an
    // underscore, so the initialiser list is the only place to assign it.
    TdProgressSource? progress,
    Future<int> Function(String path)? diskSizeOf,
    this.waitTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 200),
  })  :
        // ignore: prefer_initializing_formals
        _progress = progress,
        _diskSizeOf = diskSizeOf ?? _defaultDiskSize {
    _subscription = _progress?.changes.listen(
      (_) => _wake(),
      onError: (Object _) {
        // A broken update stream must not kill the reader; the stat poll
        // below is the fallback observation path.
      },
    );
  }

  final String path;
  final int expectedSize;
  final int generation;

  /// Task book §8: the default wait before WAIT_TIMEOUT is 10 s.
  final Duration waitTimeout;

  /// Fallback observation cadence when no update event fires.
  final Duration pollInterval;

  final TdProgressSource? _progress;
  final Future<int> Function(String path) _diskSizeOf;
  StreamSubscription<void>? _subscription;

  int _diskSize = -1;
  int _tdlibReach = 0;
  bool _invalidated = false;
  final List<Completer<void>> _waiters = <Completer<void>>[];
  final List<void Function()> _completeListeners = <void Function()>[];

  /// Measured disk size; -1 until the first successful stat.
  int get diskSize => _diskSize;

  /// TDLib's own reach (observation only — never readable by itself).
  int get tdlibReach => _tdlibReach;

  /// `min(TDLib reach, disk stat)`. The number every read decision uses.
  int get safeWatermark {
    final disk = _diskSize;
    // No measurement means no bytes: a missing file must read as zero even
    // when TDLib claims a reach. Trusting the claim alone is the historical
    // "100 % on a file that is not there" shape.
    if (disk < 0) return 0;
    final tdlib = _tdlibReach;
    if (tdlib <= 0) return disk;
    return tdlib < disk ? tdlib : disk;
  }

  /// Whole file on disk, measured. A claim without bytes is never complete.
  bool get isComplete =>
      !_invalidated && expectedSize > 0 && _diskSize >= expectedSize;

  /// Fires when [isComplete] flips to true (at most once).
  void onComplete(void Function() listener) =>
      _completeListeners.add(listener);

  /// A newer play owns this file: every waiter wakes as invalidated and no
  /// further read is honoured.
  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    _wake();
  }

  bool get isInvalidated => _invalidated;

  static Future<int> _defaultDiskSize(String path) async {
    try {
      return await File(path).length();
    } on Object {
      return -1;
    }
  }

  /// One stat, folded in. `updateFile` stops once TDLib considers the
  /// transfer finished, so the poll is what keeps a late play from waiting on
  /// silence forever.
  Future<void> refresh() async {
    if (_invalidated) return;
    if (_progress != null) {
      _tdlibReach = _progress.tdlibReach;
    }
    final size = await _diskSizeOf(path);
    final before = isComplete;
    if (size >= 0) _diskSize = size;
    if (!before && isComplete) {
      for (final listener in _completeListeners) {
        listener();
      }
      _wake();
    }
  }

  /// Reads the state at [offset]. Never throws; "not yet" is a waiting
  /// result, not an error and never an EOF.
  Future<ReadResult> read(int offset) async {
    if (_invalidated) return ReadResult.waiting(watermark: safeWatermark);
    if (isComplete) return ReadResult.complete(expectedSize: expectedSize);
    await refresh();
    if (isComplete) return ReadResult.complete(expectedSize: expectedSize);
    final watermark = safeWatermark;
    // The watermark is "how many head bytes exist"; the last readable byte
    // is watermark-1. A request at or below it is servable now.
    if (offset >= 0 && offset < watermark) {
      return ReadResult.available(
        offset: offset,
        readableTo: watermark - 1,
        watermark: watermark,
      );
    }
    return ReadResult.waiting(watermark: watermark);
  }

  /// Waits until [offset] is readable, the file completes, the timeout
  /// fires, or the reader is invalidated — whichever comes first.
  ///
  /// Event-driven through [TdProgressSource.changes], with a [pollInterval]
  /// stat as the fallback observation path.
  Future<WaitOutcome> waitFor(
    int offset, {
    Duration? timeout,
    int? generation,
  }) async {
    if (_invalidated || (generation != null && generation != this.generation)) {
      return WaitOutcome.invalidated;
    }
    final deadline =
        DateTime.now().add(timeout ?? waitTimeout).millisecondsSinceEpoch;
    while (!_invalidated) {
      if (isComplete) return WaitOutcome.completed;
      await refresh();
      if (isComplete) return WaitOutcome.completed;
      if (offset < safeWatermark) return WaitOutcome.arrived;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now >= deadline) return WaitOutcome.timeout;
      await _nextSignal(
        Duration(milliseconds: (deadline - now).clamp(0, pollInterval.inMilliseconds)),
      );
    }
    return WaitOutcome.invalidated;
  }

  Future<void> _nextSignal(Duration maxWait) {
    final completer = Completer<void>();
    _waiters.add(completer);
    // The poll is the floor: even without update events the loop re-stats at
    // [pollInterval], because a silent TDLib is a state, not an absence.
    final timer = Timer(maxWait, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.whenComplete(() => timer.cancel());
  }

  void _wake() {
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Detaches from the update stream. The reader itself is inert afterwards
  /// until [invalidate] semantics take over.
  Future<void> dispose() async {
    invalidate();
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// Shapes a TDLib [FileState] into the observation the reader needs.
class FileStateProgress implements TdProgressSource {
  FileStateProgress({required this.states, required this.fileId});

  final Stream<FileState> states;
  final int fileId;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  int _reach = 0;
  bool _completed = false;
  bool _canDownload = true;
  StreamSubscription<FileState>? _sub;

  @override
  int get tdlibReach => _reach;

  @override
  bool get tdlibCompleted => _completed;

  @override
  bool get tdlibCanDownload => _canDownload;

  @override
  Stream<void> get changes => _changes.stream;

  /// Starts consuming [states] for [fileId]. Read-only: no download is ever
  /// requested here.
  void start() {
    _sub = states.listen(
      (state) {
        if (state.id != fileId) return;
        _reach = state.downloadOffset + state.downloadedSize;
        _completed = state.isCompleted;
        _canDownload = state.canBeDownloaded;
        if (!_changes.isClosed) _changes.add(null);
      },
      onError: (Object _) {
        // Observation only; the stat poll covers the gap.
      },
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _changes.close();
  }
}
