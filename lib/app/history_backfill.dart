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
/// * only a short page (reachedEnd) marks the channel complete.
library;

import '../data/channel_sync.dart';

enum BackfillStop {
  /// Reached the start of history (short page).
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
}

class BackfillResult {
  const BackfillResult({
    required this.stop,
    this.rounds = 0,
    this.pages = 0,
    this.inserted = 0,
    this.error,
  });

  final BackfillStop stop;
  final int rounds;
  final int pages;
  final int inserted;
  final String? error;

  bool get madeProgress => inserted > 0 || pages > 0;
}

/// One bounded slice. Injected so the scheduler can be tested without a TDLib
/// client; the app passes `session.syncHistorySlice`.
typedef SliceFetcher = Future<SyncCycleReport?> Function(int pagesPerChannel);

class HistoryBackfill {
  HistoryBackfill({
    required this.fetch,
    this.pagesPerSlice = 6,
    this.roundsPerKick = 8,
  });

  final SliceFetcher fetch;
  final int pagesPerSlice;
  final int roundsPerKick;

  bool _running = false;

  bool get isRunning => _running;

  /// Number of pages in one slice. Four to eight is the range where a slice
  /// finishes in well under a second on device and still moves the cursor
  /// meaningfully.
  int get slicePages => pagesPerSlice;

  Future<BackfillResult> kick() async {
    if (_running) {
      return const BackfillResult(stop: BackfillStop.busy);
    }
    _running = true;
    var rounds = 0;
    var pages = 0;
    var inserted = 0;
    try {
      for (; rounds < roundsPerKick; rounds++) {
        final report = await fetch(pagesPerSlice);
        if (report == null) {
          return BackfillResult(stop: BackfillStop.idle, rounds: rounds);
        }
        pages += report.pages;
        inserted += report.insertedRecords;
        if (report.isError) {
          return BackfillResult(
            stop: BackfillStop.failed,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
            error: report.lastError,
          );
        }
        if (report.reachedEnd) {
          return BackfillResult(
            stop: BackfillStop.reachedEnd,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
          );
        }
        if (report.pages == 0) {
          return BackfillResult(
            stop: BackfillStop.noProgress,
            rounds: rounds + 1,
            pages: pages,
            inserted: inserted,
          );
        }
        // Yield so a slice never turns into one long synchronous block.
        await Future<void>.delayed(Duration.zero);
      }
      return BackfillResult(
        stop: BackfillStop.budget,
        rounds: rounds,
        pages: pages,
        inserted: inserted,
      );
    } finally {
      _running = false;
    }
  }
}
