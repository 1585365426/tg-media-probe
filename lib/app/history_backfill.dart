/// Keeps walking a channel's history into the index, a slice at a time.
///
/// Why this exists: `syncCycle` is deliberately bounded (a few pages per call)
/// so it cannot block the UI. But nothing was calling it *again*. A 4000-message
/// channel therefore stopped wherever the last manual pull happened to land —
/// the reported "count stuck at 725, waiting does not help".
///
/// Rules:
/// * one run at a time, process-wide (a second kick returns busy);
/// * each kick walks at most [roundsPerKick] slices, yielding between them;
/// * a slice that adds nothing and does not advance ends the kick — no busy
///   loop against a channel that has nothing new;
/// * only "every channel reached a short page" marks the work complete;
/// * [start] keeps kicking on its own: a bounded slice plus a scheduler is the
///   only shape that makes a long backfill finish on a phone, because nothing
///   outside this class may call it again;
/// * a flood wait is honoured to the second, and any other failure backs off
///   exponentially — retrying a 429 immediately makes the wait longer.
library;

import 'dart:async';

import '../data/channel_sync.dart';

enum BackfillStop {
  /// Every channel reached the start of history (short page).
  reachedEnd,

  /// Ran out of this kick's budget; more history remains.
  budget,

  /// A slice made no progress; try again later rather than spin.
  noProgress,

  /// Nothing to do (not signed in, no channels, no index).
  idle,

  /// A kick is already running.
  busy,

  /// The slice failed; the cursor is unchanged and the next kick retries.
  failed,

  /// [HistoryBackfill.stop] was called between slices.
  stopped,
}

class BackfillResult {
  const BackfillResult({
    required this.stop,
    this.rounds = 0,
    this.pages = 0,
    this.inserted = 0,
    this.error,
    this.retryAfter,
    this.channelsTotal = 0,
    this.channelsAtEnd = 0,
  });

  final BackfillStop stop;
  final int rounds;
  final int pages;
  final int inserted;
  final String? error;

  /// `FLOOD_WAIT_n` from TDLib, when the slice hit one.
  final Duration? retryAfter;
  final int channelsTotal;
  final int channelsAtEnd;

  bool get madeProgress => inserted > 0 || pages > 0;

  /// True when there is nothing left to walk for any channel.
  bool get complete =>
      stop == BackfillStop.reachedEnd ||
      (channelsTotal > 0 && channelsAtEnd >= channelsTotal);
}

/// One bounded slice. Injected so the scheduler can be tested without a TDLib
/// client; the app passes `session.syncHistorySlice`.
typedef SliceFetcher = Future<SyncCycleReport?> Function(int pagesPerChannel);

class HistoryBackfill {
  HistoryBackfill({
    required this.fetch,
    this.pagesPerSlice = 6,
    this.roundsPerKick = 8,
    this.idleDelay = const Duration(seconds: 2),
    this.maxIdleDelay = const Duration(seconds: 60),
    this.onProgress,
  });

  final SliceFetcher fetch;
  final int pagesPerSlice;
  final int roundsPerKick;

  /// Base delay between kicks. A kick is a few hundred milliseconds of work, so
  /// this is the pause that keeps the walk invisible instead of a battery
  /// drain.
  final Duration idleDelay;

  /// Ceiling for the exponential backoff after consecutive failures.
  final Duration maxIdleDelay;

  /// Called after every kick that changed something, so the UI can refresh its
  /// counts without polling the store.
  final void Function(BackfillResult result)? onProgress;

  bool _running = false;
  bool _looping = false;
  bool _stopRequested = false;
  Timer? _timer;
  Completer<void>? _idle;
  int _consecutiveFailures = 0;
  BackfillResult? _last;

  bool get isRunning => _running;
  bool get isLooping => _looping;
  BackfillResult? get lastResult => _last;

  /// Number of pages in one slice. Four to eight is the range where a slice
  /// finishes in well under a second on device and still moves the cursor
  /// meaningfully.
  int get slicePages => pagesPerSlice;

  /// Starts the self-scheduling loop. Idempotent.
  ///
  /// A single `kick()` is what the app used to do — once per launch — which is
  /// why the count froze: the budget ran out and nothing asked again.
  void start() {
    _stopRequested = false;
    if (_looping) return;
    _looping = true;
    unawaited(_loop());
  }

  /// Stops the loop. A slice already in flight finishes; the next one does not
  /// start. Called when the app goes to the background: iOS would suspend the
  /// process mid-request anyway, and a half-finished page is wasted work.
  void stop() {
    _stopRequested = true;
    _looping = false;
    _timer?.cancel();
    _timer = null;
    // Release the loop's wait, otherwise it stays parked on a timer that was
    // cancelled and never returns.
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  Future<void> _loop() async {
    while (_looping) {
      final result = await kick();
      if (!_looping) return;
      if (result.stop == BackfillStop.stopped) return;
      if (result.complete) {
        // Nothing left anywhere: stop asking Telegram for the same short page.
        _looping = false;
        return;
      }
      final completer = Completer<void>();
      _idle = completer;
      _timer = Timer(delayAfter(result), () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      _timer = null;
      _idle = null;
    }
  }

  /// How long to wait before the next kick. Public so the policy can be
  /// asserted without making a test sleep for a real minute.
  Duration delayAfter(BackfillResult result) {
    // A flood wait is an instruction, not a suggestion.
    final flood = result.retryAfter;
    if (flood != null) {
      _consecutiveFailures = 0;
      return flood;
    }
    if (result.stop == BackfillStop.failed) {
      _consecutiveFailures = (_consecutiveFailures + 1).clamp(0, 6);
      final scaled = idleDelay * (1 << (_consecutiveFailures - 1));
      return scaled > maxIdleDelay ? maxIdleDelay : scaled;
    }
    if (result.stop == BackfillStop.idle) {
      // Not signed in yet, or the channel directory is still loading. There is
      // nothing to walk, so do not poll every two seconds for it.
      return maxIdleDelay;
    }
    _consecutiveFailures = 0;
    return idleDelay;
  }

  Future<BackfillResult> kick() async {
    if (_running) {
      return const BackfillResult(stop: BackfillStop.busy);
    }
    // A manual kick after a stop is a fresh decision by the caller.
    if (!_looping) _stopRequested = false;
    _running = true;
    var rounds = 0;
    var pages = 0;
    var inserted = 0;
    try {
      for (; rounds < roundsPerKick; rounds++) {
        if (_stopRequested) {
          // stop() was called while this kick was working.
          final stopped = BackfillResult(
            stop: BackfillStop.stopped,
            rounds: rounds,
            pages: pages,
            inserted: inserted,
          );
          _last = stopped;
          return stopped;
        }
        final report = await fetch(pagesPerSlice);
        if (report == null) {
          return _remember(BackfillResult(stop: BackfillStop.idle, rounds: rounds));
        }
        pages += report.pages;
        inserted += report.insertedRecords;
        if (report.isError) {
          return _remember(BackfillResult(
            stop: BackfillStop.failed,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
            error: report.lastError,
            retryAfter: report.retryAfter ?? parseRetryAfter(report.lastError),
            channelsTotal: report.channelsTotal,
            channelsAtEnd: report.channelsAtEnd,
          ));
        }
        if (report.reachedEnd) {
          return _remember(BackfillResult(
            stop: BackfillStop.reachedEnd,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
            channelsTotal: report.channelsTotal,
            channelsAtEnd: report.channelsAtEnd,
          ));
        }
        if (report.pages == 0) {
          return _remember(BackfillResult(
            stop: BackfillStop.noProgress,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
            channelsTotal: report.channelsTotal,
            channelsAtEnd: report.channelsAtEnd,
          ));
        }
        // Yield so a slice never turns into one long synchronous block.
        await Future<void>.delayed(Duration.zero);
      }
      return _remember(BackfillResult(
        stop: BackfillStop.budget,
        rounds: rounds,
        pages: pages,
        inserted: inserted,
      ));
    } finally {
      _running = false;
    }
  }

  BackfillResult _remember(BackfillResult result) {
    _last = result;
    if (result.pages > 0 || result.inserted > 0) {
      onProgress?.call(result);
    }
    return result;
  }
}
