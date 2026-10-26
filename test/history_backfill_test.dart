/// History backfill: the thing that kept "725 forever" from moving.
///
/// It must keep slicing while there is history, stop on a short page, never spin
/// when a slice makes no progress, and never run twice at once.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/history_backfill.dart';
import 'package:tg_media_probe/data/channel_sync.dart';

SyncCycleReport _report({
  int pages = 6,
  int raw = 600,
  int inserted = 30,
  bool reachedEnd = false,
  String? error,
}) =>
    SyncCycleReport(
      pages: pages,
      rawMessages: raw,
      insertedRecords: inserted,
      errors: error == null ? const <String>[] : <String>[error],
      cancelled: false,
      reachedEnd: reachedEnd,
      lastError: error,
    );

void main() {
  test('a kick keeps slicing until its budget, then allows another kick',
      () async {
    var slices = 0;
    final backfill = HistoryBackfill(
      fetch: (pages) async {
        slices++;
        // Deep history: never ends, always 6 pages.
        return _report();
      },
      pagesPerSlice: 6,
      roundsPerKick: 8,
    );

    final first = await backfill.kick();

    expect(first.stop, BackfillStop.budget);
    expect(first.rounds, 8);
    expect(first.pages, 48);
    expect(first.inserted, 240);
    expect(slices, 8);

    // The next kick continues; it does not restart from zero pages.
    final second = await backfill.kick();
    expect(second.stop, BackfillStop.budget);
    expect(slices, 16);
  });

  test('a short page ends the walk', () async {
    final backfill = HistoryBackfill(
      fetch: (pages) async => _report(reachedEnd: true, pages: 3, raw: 120),
      roundsPerKick: 8,
    );

    final result = await backfill.kick();

    expect(result.stop, BackfillStop.reachedEnd);
    expect(result.rounds, 1);
  });

  test('a slice with no progress stops instead of spinning', () async {
    var calls = 0;
    final backfill = HistoryBackfill(
      fetch: (pages) async {
        calls++;
        return _report(pages: 0, raw: 0, inserted: 0);
      },
      roundsPerKick: 8,
    );

    final result = await backfill.kick();

    expect(result.stop, BackfillStop.noProgress);
    expect(calls, 1, reason: 'no busy loop against a channel with nothing new');
  });

  test('an error keeps the cursor where it was and reports it', () async {
    final backfill = HistoryBackfill(
      fetch: (pages) async => _report(error: 'TDLib error 420: FLOOD_WAIT_9'),
    );

    final result = await backfill.kick();

    expect(result.stop, BackfillStop.failed);
    expect(result.error, contains('FLOOD_WAIT'));
  });

  test('nothing to do is idle, not an error', () async {
    final backfill = HistoryBackfill(fetch: (pages) async => null);

    final result = await backfill.kick();

    expect(result.stop, BackfillStop.idle);
  });

  test('two kicks cannot overlap', () async {
    var running = false;
    final backfill = HistoryBackfill(
      fetch: (pages) async {
        expect(running, isFalse, reason: 'a second slice started concurrently');
        running = true;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running = false;
        return _report();
      },
      roundsPerKick: 3,
    );

    final first = backfill.kick();
    final second = await backfill.kick();
    expect(second.stop, BackfillStop.busy);
    await first;
  });

  test('the slice size is the configured one', () async {
    var seen = 0;
    final backfill = HistoryBackfill(
      fetch: (pages) async {
        seen = pages;
        return _report(reachedEnd: true);
      },
      pagesPerSlice: 4,
    );

    await backfill.kick();

    expect(seen, 4);
  });

  test('a long walk is bounded per kick, never one unbounded loop', () async {
    var calls = 0;
    final backfill = HistoryBackfill(
      fetch: (pages) async {
        calls++;
        return _report();
      },
      roundsPerKick: 5,
    );
    await backfill.kick();

    expect(calls, 5);
  });
}
