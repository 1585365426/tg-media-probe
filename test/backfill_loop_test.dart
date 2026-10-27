/// Regressions for "the channel count stops at 725".
///
/// Four separate defects fed that one number, and each has its own test here:
/// the scheduler never asked for another slice, one finished channel ended the
/// whole walk, the resume point was a media id instead of a scanned id, and a
/// flood wait was retried immediately instead of being honoured.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/history_backfill.dart';
import 'package:tg_media_probe/data/channel_sync.dart';
import 'package:tg_media_probe/data/history_source.dart';
import 'package:tg_media_probe/data/index_store.dart';

import 'support/sandbox.dart';

/// A channel with [count] messages, every [videoEvery]-th one a video.
class FakeHistory implements HistorySource {
  FakeHistory({required this.messages, this.videoEvery = 1});

  final Map<int, int> messages;
  final int videoEvery;
  final Map<int, int> calls = <int, int>{};

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    calls[chatId] = (calls[chatId] ?? 0) + 1;
    final total = messages[chatId] ?? 0;
    // Newest first: ids count down from `total`.
    final top = fromMessageId == 0 ? total : fromMessageId;
    final batch = <Map<String, Object?>>[];
    for (var id = top; id > 0 && batch.length < limit; id--) {
      if (videoEvery > 1 && id % videoEvery != 0) {
        batch.add(<String, Object?>{'id': id, 'date': 1700000000 + id});
        continue;
      }
      batch.add(<String, Object?>{
        'id': id,
        'date': 1700000000 + id,
        'content': <String, Object?>{
          '@type': 'messageVideo',
          'video': <String, Object?>{
            'file': <String, Object?>{'id': 900000 + id, 'expected_size': 1024},
            'file_name': 'v$id.mp4',
            'duration': 10,
            'width': 1080,
            'height': 1920,
          },
        },
      });
    }
    return HistoryPage(messages: batch);
  }
}

SyncCycleReport report({
  bool reachedEnd = false,
  int pages = 1,
  int inserted = 0,
  String? error,
  Duration? retryAfter,
  int channelsTotal = 1,
  int channelsAtEnd = 0,
}) =>
    SyncCycleReport(
      pages: pages,
      rawMessages: pages * 50,
      insertedRecords: inserted,
      errors: <String>[?error],
      cancelled: false,
      reachedEnd: reachedEnd,
      lastError: error,
      retryAfter: retryAfter,
      channelsTotal: channelsTotal,
      channelsAtEnd: channelsAtEnd,
      channelsProgressed: pages > 0 ? 1 : 0,
    );

void main() {
  group('a cycle only ends when every channel is exhausted', () {
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

    test('a drained 5-message channel does not end a 4000-message one',
        () async {
      // This is the exact shape of the device report: the directory holds a
      // tiny channel next to the big one, the tiny one returns a short page on
      // the first request, and the old report said "reachedEnd" — so the
      // scheduler stopped with the big channel still at 725.
      final source = FakeHistory(
        messages: <int, int>{1: 5, 2: 4000},
        videoEvery: 3,
      );
      final engine = ChannelSyncEngine(source: source, store: store);

      final cycle = await engine.syncCycle(
        chatIds: <int>[1, 2],
        pagesPerChannel: 4,
        pageGap: Duration.zero,
      );

      expect(cycle.channelsTotal, 2);
      expect(cycle.channelsAtEnd, 1, reason: '只有 5 条那个频道走完了');
      expect(cycle.reachedEnd, isFalse,
          reason: '还有一个频道没走完，不能报结束');
      expect(store.countByChat()[2], greaterThan(0));
    });

    test('the resume cursor is the scanned id, not the oldest media id',
        () async {
      // videoEvery: 10 means a 50-message batch contains 5 videos; the old code
      // stored the oldest *video* id as the resume point, so the next slice
      // re-read almost the same batch and the count crawled.
      final source = FakeHistory(
        messages: <int, int>{7: 500},
        videoEvery: 10,
      );
      final engine = ChannelSyncEngine(source: source, store: store);

      await engine.syncCycle(chatIds: <int>[7], pagesPerChannel: 1, pageGap: Duration.zero);
      final first = store.watermark(7);
      final firstCount = store.countByChat()[7] ?? 0;

      await engine.syncCycle(chatIds: <int>[7], pagesPerChannel: 1, pageGap: Duration.zero);
      final second = store.watermark(7);
      final secondCount = store.countByChat()[7] ?? 0;

      // 500 messages, limit 50: one slice consumes ids 500..451, so the cursor
      // is 451 even though the oldest video in that batch is 460.
      expect(first?.scanCursor, 451);
      expect(first?.oldestMessageId, 460,
          reason: '媒体水位仍是媒体 id，两者必须分开');
      expect(second?.scanCursor, lessThan(451));
      expect(secondCount, greaterThan(firstCount),
          reason: '第二片必须真的往里走，不能重复读同一批');
    });

    test('a channel that errors does not stop the others', () async {
      final source = _BrokenChannel(brokenChatId: 1, messages: <int, int>{2: 400});
      final engine = ChannelSyncEngine(source: source, store: store);

      final cycle = await engine.syncCycle(
        chatIds: <int>[1, 2],
        pagesPerChannel: 2,
        pageGap: Duration.zero,
      );

      expect(cycle.isError, isTrue);
      expect(store.countByChat()[2], greaterThan(0),
          reason: '一个频道报错不能让后面的频道一个都不走');
    });
  });

  group('the scheduler keeps asking', () {
    test('start() re-kicks after a budget stop until the work is done',
        () async {
      var calls = 0;
      final backfill = HistoryBackfill(
        idleDelay: const Duration(milliseconds: 5),
        maxIdleDelay: const Duration(milliseconds: 20),
        fetch: (pages) async {
          calls++;
          // Three productive slices, then the walk reports the end.
          if (calls < 3) return report(pages: 2, inserted: 4);
          return report(reachedEnd: true, pages: 0);
        },
      );

      backfill.start();
      // Give the loop time for three kicks and the stop.
      for (var i = 0; i < 60 && backfill.isLooping; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(backfill.isLooping, isFalse, reason: '走完就该停，不能空转');
      expect(calls, 3);
    });

    test('a flooded slice waits the retry_after instead of retrying at once',
        () async {
      final backfill = HistoryBackfill(
        idleDelay: const Duration(milliseconds: 5),
        fetch: (pages) async => report(
          pages: 0,
          error: 'TDLib error 420: FLOOD_WAIT_42',
          retryAfter: parseRetryAfter('TDLib error 420: FLOOD_WAIT_42'),
        ),
      );

      final result = await backfill.kick();
      expect(result.stop, BackfillStop.failed);
      expect(backfill.delayAfter(result), const Duration(seconds: 42));
    });

    test('repeated failures back off exponentially, capped', () async {
      final backfill = HistoryBackfill(
        idleDelay: const Duration(milliseconds: 10),
        maxIdleDelay: const Duration(milliseconds: 40),
        fetch: (pages) async => report(pages: 0, error: 'boom'),
      );

      final delays = <Duration>[];
      for (var i = 0; i < 5; i++) {
        delays.add(backfill.delayAfter(await backfill.kick()));
      }

      expect(delays.first, const Duration(milliseconds: 10));
      expect(delays[1], const Duration(milliseconds: 20));
      expect(delays[3], const Duration(milliseconds: 40));
      expect(delays.last, const Duration(milliseconds: 40),
          reason: '退避要有上限，否则一次故障会把回填停半天');
    });

    test('stop() ends the loop between slices', () async {
      var calls = 0;
      final backfill = HistoryBackfill(
        idleDelay: const Duration(milliseconds: 5),
        fetch: (pages) async {
          calls++;
          return report(pages: 1, inserted: 1);
        },
      );

      backfill.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      backfill.stop();
      final seen = calls;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(backfill.isLooping, isFalse);
      expect(calls, seen, reason: 'stop 之后不能再发请求');
      expect(seen, greaterThan(1), reason: '循环必须真的跑过几轮');
    });
  });

  group('flood wait parsing', () {
    test('reads the seconds out of the TDLib text', () {
      expect(parseRetryAfter('TDLib error 420: FLOOD_WAIT_37'),
          const Duration(seconds: 37));
      expect(parseRetryAfter('网络不可用'), isNull);
      expect(parseRetryAfter(null), isNull);
    });

    test('caps an absurd wait so a bad string cannot park the app for a day',
        () {
      expect(parseRetryAfter('FLOOD_WAIT_86400'), const Duration(seconds: 900));
    });
  });
}

/// Fails one channel, answers normally for the rest.
class _BrokenChannel implements HistorySource {
  _BrokenChannel({required this.brokenChatId, required this.messages});

  final int brokenChatId;
  final Map<int, int> messages;

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    if (chatId == brokenChatId) {
      return const HistoryPage.failure('TDLib error 400: CHANNEL_INVALID');
    }
    final total = messages[chatId] ?? 0;
    final top = fromMessageId == 0 ? total : fromMessageId;
    final batch = <Map<String, Object?>>[];
    for (var id = top; id > 0 && batch.length < limit; id--) {
      batch.add(<String, Object?>{
        'id': id,
        'date': 1700000000 + id,
        'content': <String, Object?>{
          '@type': 'messageVideo',
          'video': <String, Object?>{
            'file': <String, Object?>{'id': 900000 + id, 'expected_size': 1024},
            'file_name': 'v$id.mp4',
          },
        },
      });
    }
    return HistoryPage(messages: batch);
  }
}
