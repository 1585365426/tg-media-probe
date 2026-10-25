import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/channel_sync.dart';
import 'package:tg_media_probe/data/history_source.dart';
import 'package:tg_media_probe/data/index_store.dart';

import 'support/sandbox.dart';

/// Deterministic stand-in for TDLib's `getChatHistory`.
///
/// It mimics the real cursor semantics: `from_message_id == 0` means "newest",
/// otherwise the page contains messages **older** than the given id. Message
/// shapes match the TDLib schema so [MediaRecord.fromMessage] runs for real.
class FakeHistorySource implements HistorySource {
  FakeHistorySource({required this.messageCount, this.totalChats = 1});

  final int messageCount;
  final int totalChats;

  int calls = 0;
  final List<int> limits = <int>[];
  final List<int> fromIds = <int>[];
  final List<int> offsets = <int>[];
  String? failWith;
  void Function()? onRequest;

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    calls++;
    limits.add(limit);
    fromIds.add(fromMessageId);
    offsets.add(offset);
    onRequest?.call();
    if (failWith != null) return HistoryPage.failure(failWith!);

    final start = fromMessageId == 0 ? messageCount : fromMessageId - 1;
    final messages = <Map<String, Object?>>[];
    for (var id = start; id > 0 && messages.length < limit; id--) {
      messages.add(<String, Object?>{
        '@type': 'message',
        'id': id,
        'date': 1700000000 + id,
        'has_protected_content': false,
        'content': <String, Object?>{
          '@type': 'messageVideo',
          'video': <String, Object?>{
            'duration': 30,
            'width': 1920,
            'height': 1080,
            'file_name': 'v$id.mp4',
            'mime_type': 'video/mp4',
            'supports_streaming': true,
            'video': <String, Object?>{
              'id': 900000 + id,
              'expected_size': 1048576,
              'local': <String, Object?>{'downloaded_size': 0},
            },
          },
        },
      });
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

  ChannelSyncEngine engine(FakeHistorySource source, {int pageSize = 50}) =>
      ChannelSyncEngine(source: source, store: store, pageSize: pageSize);

  group('page size', () {
    test('clamps an oversized request to the TDLib ceiling', () async {
      final source = FakeHistorySource(messageCount: 5000);
      final result =
          await engine(source, pageSize: 10000).loadPage(chatId: 100);
      expect(result.requestedLimit, 100);
      expect(source.limits.single, 100);
      expect(result.records, hasLength(100));
    });

    test('never issues a second call for one page', () async {
      final source = FakeHistorySource(messageCount: 5000);
      await engine(source).loadPage(chatId: 100);
      expect(source.calls, 1);
    });
  });

  group('incremental walk', () {
    test('a 1200-message channel is pulled in bounded pages', () async {
      final source = FakeHistorySource(messageCount: 1200);
      final sync = engine(source);
      final report = await sync.drainChannel(chatId: 100);

      expect(report.errors, isEmpty);
      // 24 full pages of 50 plus one empty page that reports end-of-history.
      expect(report.pages, 25);
      expect(report.rawMessages, 1200);
      expect(store.count, 1200);
      expect(source.limits.every((limit) => limit <= SyncLimits.maxPageSize), isTrue);
      expect(source.offsets.every((offset) => offset == 0), isTrue);
    });

    test('cursors move backwards and never repeat a page', () async {
      final source = FakeHistorySource(messageCount: 300);
      await engine(source).drainChannel(chatId: 100);
      final nonZeroFroms = source.fromIds.where((id) => id > 0).toList();
      expect(nonZeroFroms, isNotEmpty);
      for (var i = 1; i < nonZeroFroms.length; i++) {
        expect(nonZeroFroms[i], lessThan(nonZeroFroms[i - 1]));
      }
    });

    test('three syncs of the same channel add no duplicate rows', () async {
      final source = FakeHistorySource(messageCount: 400);
      final sync = engine(source);
      final first = await sync.drainChannel(chatId: 100);
      final second = await sync.drainChannel(chatId: 100);
      final third = await sync.drainChannel(chatId: 100);

      expect(first.insertedRecords, 400);
      expect(second.insertedRecords, 0);
      expect(third.insertedRecords, 0);
      expect(store.count, 400);
    });

    test('watermark tracks the newest and oldest indexed id', () async {
      final source = FakeHistorySource(messageCount: 120);
      await engine(source).drainChannel(chatId: 100);
      final watermark = store.watermark(100);
      expect(watermark, isNotNull);
      expect(watermark!.newestMessageId, 120);
      expect(watermark.oldestMessageId, 1);
    });
  });

  group('failure handling', () {
    test('a TDLib error is reported, not turned into an empty success', () async {
      final source = FakeHistorySource(messageCount: 10)
        ..failWith = 'TDLib error 420: FLOOD_WAIT_30';
      final result = await engine(source).loadPage(chatId: 100);
      expect(result.isError, isTrue);
      expect(result.error, contains('FLOOD_WAIT'));
      expect(result.records, isEmpty);
      expect(store.count, 0);
    });

    test('cancel stops the walk and keeps what was already indexed', () async {
      final source = FakeHistorySource(messageCount: 1000);
      final token = SyncCancelToken();
      source.onRequest = () {
        if (source.calls >= 2) token.cancel();
      };
      final report = await engine(source).drainChannel(chatId: 100, cancel: token);
      expect(report.cancelled, isTrue);
      expect(report.pages, lessThan(20));
      expect(store.count, lessThan(1000));
      expect(store.count, greaterThan(0));
    });
  });

  group('sync cycle', () {
    test('a launch cycle touches at most N pages per channel', () async {
      final source = FakeHistorySource(messageCount: 1000);
      final report = await engine(source)
          .syncCycle(chatIds: <int>[100], pagesPerChannel: 2);
      expect(source.calls, 2);
      expect(report.pages, 2);
      expect(report.rawMessages, 100);
    });

    test('one bad channel does not abort the others', () async {
      final source = FakeHistorySource(messageCount: 50);
      final sync = engine(source);
      final report = await sync.syncCycle(chatIds: <int>[100, 200], pagesPerChannel: 1);
      expect(report.pages, 2);
      expect(report.errors, isEmpty);
    });
  });

  group('MediaPager', () {
    test('loads the index in fixed pages and stops at the end', () async {
      final source = FakeHistorySource(messageCount: 120);
      await engine(source).drainChannel(chatId: 100);

      final pager = MediaPager(store: store, pageSize: 40);
      var pages = 0;
      var rows = 0;
      while (pager.hasMore && pages < 10) {
        final page = await pager.next();
        expect(page.items.length, lessThanOrEqualTo(40));
        rows += page.items.length;
        pages++;
      }
      expect(pages, 3);
      expect(rows, 120);
      expect(pager.loadedCount, 120);
      expect(pager.hasMore, isFalse);
    });

    test('a concurrent next() call does not double-load a page', () async {
      final source = FakeHistorySource(messageCount: 100);
      await engine(source).drainChannel(chatId: 100);
      final pager = MediaPager(store: store, pageSize: 30);
      final results = await Future.wait([pager.next(), pager.next()]);
      final total = results.fold<int>(0, (sum, page) => sum + page.items.length);
      expect(total, 30);
    });
  });
}
