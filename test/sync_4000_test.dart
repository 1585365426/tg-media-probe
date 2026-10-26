/// A 4000-message channel has to be walkable in bounded batches, resumable after
/// an interruption, and never re-read from the top on every cycle.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/channel_sync.dart';
import 'package:tg_media_probe/data/history_source.dart';
import 'package:tg_media_probe/data/index_store.dart';

import 'support/sandbox.dart';

Map<String, Object?> _message(int id, {required bool video}) {
  if (!video) {
    return <String, Object?>{
      '@type': 'message',
      'id': id,
      'date': 1700000000 + id,
      'has_protected_content': false,
      'content': <String, Object?>{
        '@type': 'messageText',
        'text': <String, Object?>{'text': 'text $id'},
      },
    };
  }
  return <String, Object?>{
    '@type': 'message',
    'id': id,
    'date': 1700000000 + id,
    'has_protected_content': false,
    'content': <String, Object?>{
      '@type': 'messageVideo',
      'video': <String, Object?>{
        'duration': 10,
        'width': 720,
        'height': 1280,
        'file_name': 'v$id.mp4',
        'mime_type': 'video/mp4',
        'supports_streaming': true,
        'video': <String, Object?>{
          'id': 700000 + id,
          'expected_size': 4096,
          'local': <String, Object?>{'downloaded_size': 0},
        },
      },
    },
  };
}

/// 4000 messages, one video every [every] messages (newest first).
class BigChannel implements HistorySource {
  BigChannel({this.total = 4000, this.every = 10});

  final int total;
  final int every;

  final List<int> requestedFrom = <int>[];

  /// Set to a number of upcoming calls that should fail (rate limit / network).
  int failNextCalls = 0;

  int get videoCount => total ~/ every;

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    requestedFrom.add(fromMessageId);
    if (failNextCalls > 0) {
      failNextCalls--;
      return HistoryPage.failure('TDLib error 420: FLOOD_WAIT_5');
    }
    final start = fromMessageId == 0 ? total : fromMessageId - 1;
    final messages = <Map<String, Object?>>[];
    for (var id = start; id > 0 && messages.length < limit; id--) {
      messages.add(_message(id, video: id % every == 1));
    }
    return HistoryPage(messages: messages);
  }
}

void main() {
  late TestSandbox sandbox;
  late IndexStore store;

  setUp(() async {
    sandbox = await TestSandbox.create();
    store = IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await store.open();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  ChannelSyncEngine engine(HistorySource source, {int pageSize = 100}) =>
      ChannelSyncEngine(source: source, store: store, pageSize: pageSize);

  /// Runs cycles until the engine reports the end of history.
  Future<SyncCycleReport> drain(ChannelSyncEngine e, {int maxCycles = 40}) async {
    var report = await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2);
    var cycles = 1;
    while (!report.reachedEnd && !report.isError && cycles < maxCycles) {
      report = await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2);
      cycles++;
    }
    return report;
  }

  test('4000 messages are walked in bounded batches to the end', () async {
    final source = BigChannel();
    final report = await drain(engine(source));

    expect(report.reachedEnd, isTrue, reason: 'must reach the end, not stall');
    expect(report.errors, isEmpty);

    // Every video in the channel is in the mirror.
    expect(store.countByChat()[1], source.videoCount);

    // No video was skipped: the ids are exactly the ones the source offered.
    final indexed = <int>{};
    String? cursor;
    while (true) {
      final page = await store.page(limit: 500, cursor: cursor, chatId: 1);
      for (final record in page.items) {
        indexed.add(record.messageId);
      }
      cursor = page.nextCursor;
      if (!page.hasMore) break;
    }
    expect(indexed, hasLength(source.videoCount));
    expect(indexed.every((id) => id % 10 == 1), isTrue);
  });

  test('cycles always move deeper, never re-reading the same batch', () async {
    final source = BigChannel(total: 4000);
    final e = engine(source);

    for (var i = 0; i < 5; i++) {
      await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 1);
    }

    // Cursors must strictly decrease; a repeated one is the 38-item bug.
    final froms = source.requestedFrom;
    expect(froms.first, 0);
    for (var i = 1; i < froms.length; i++) {
      expect(froms[i], lessThan(froms[i - 1] == 0 ? 4001 : froms[i - 1]),
          reason: 'cursor must advance into older history: $froms');
    }
    expect(froms.toSet().length, froms.length,
        reason: 'no batch may be requested twice');
  });

  test('an interrupted walk resumes where it stopped', () async {
    final source = BigChannel(total: 4000);

    // Five cycles, then "the app is killed".
    final firstEngine = engine(source);
    for (var i = 0; i < 5; i++) {
      await firstEngine.syncCycle(chatIds: <int>[1], pagesPerChannel: 1);
    }
    final afterInterruption = store.countByChat()[1] ?? 0;
    final watermark = store.watermark(1)?.oldestMessageId;
    expect(watermark, isNotNull);

    // A brand new engine over the same store picks up from the watermark.
    final resumed = await drain(engine(source));
    expect(resumed.reachedEnd, isTrue);
    expect(store.countByChat()[1], source.videoCount);
    expect(store.countByChat()[1], greaterThan(afterInterruption));
  });

  test('a refresh from the newest message does not duplicate rows', () async {
    final source = BigChannel(total: 400);
    final e = engine(source);
    await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2, resume: false);
    final before = store.countByChat()[1];

    final again =
        await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2, resume: false);
    expect(store.countByChat()[1], before);
    expect(again.insertedRecords, 0,
        reason: 're-reading the newest pages must insert nothing new');
  });

  test('a rate-limited cycle reports the error and the next one recovers',
      () async {
    final source = BigChannel(total: 800);
    final e = engine(source);
    source.failNextCalls = 1;

    final failed = await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2);
    expect(failed.isError, isTrue);
    expect(failed.lastError, contains('FLOOD_WAIT'));

    final recovered = await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 2);
    expect(recovered.isError, isFalse);
    expect(recovered.pages, greaterThan(0));
    expect(store.countByChat()[1], greaterThan(0));
  });

  test('a batch with no video still advances the walk', () async {
    // Videos only in the oldest 200 messages: the first 3800 are text.
    final source = BigChannel(total: 4000, every: 1000000);
    final e = engine(source);

    final report = await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 3);
    expect(report.rawMessages, 300, reason: 'scanned, not skipped');
    expect(report.reachedEnd, isFalse,
        reason: 'no video here is not the end of history');
    expect(store.watermark(1)?.oldestMessageId, isNotNull,
        reason: 'a video-less batch must still move the cursor');
  });

  test('the end is only claimed by a short page, not by a page budget', () async {
    final source = BigChannel(total: 4000);
    final e = engine(source);

    final budgetLimited =
        await e.syncCycle(chatIds: <int>[1], pagesPerChannel: 1);
    expect(budgetLimited.reachedEnd, isFalse,
        reason: 'running out of budget is not the end of the channel');
    expect(budgetLimited.rawMessages, 100);

    final finished = await drain(e);
    expect(finished.reachedEnd, isTrue);
  });

  test('the store never holds more rows than the channel has messages',
      () async {
    final source = BigChannel(total: 4000);
    await drain(engine(source));

    // 400 videos + 0 non-video rows: the mirror only keeps media.
    expect(store.countByChat(videosOnly: false)[1], source.videoCount);
  });
}
