import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';

import 'support/sandbox.dart';

MediaRecord record(
  int messageId, {
  int chatId = 100,
  int date = 1700000000,
  bool favorite = false,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 900000 + messageId,
      kind: MediaKind.video,
      width: 1920,
      height: 1080,
      durationSeconds: 30,
      sizeBytes: 1048576,
      fileName: 'v$messageId.mp4',
      mimeType: 'video/mp4',
      messageDateUnix: date + messageId,
      favorite: favorite,
    );

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  IndexStore newStore({int compactionThreshold = 2000}) => IndexStore(
        directory: sandbox.layout.indexDir,
        ops: sandbox.ops,
        compactionThreshold: compactionThreshold,
      );

  group('upsert', () {
    test('first insert reports new keys, repeat does not', () async {
      final store = newStore();
      await store.open();
      final first = await store.upsertAll([record(1), record(2), record(3)]);
      final second = await store.upsertAll([record(1), record(2), record(3)]);
      expect(first, 3);
      expect(second, 0);
      expect(store.count, 3);
    });

    test('a resync keeps the local favourite flag', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll([record(1)]);
      expect(await store.setFavorite(chatId: 100, messageId: 1, value: true),
          isTrue);
      // Same message comes back from Telegram without any favourite concept.
      await store.upsertAll([record(1)]);
      expect(store.favoriteCount, 1);
      final page = await store.page(limit: 10);
      expect(page.items.single.favorite, isTrue);
    });

    test('setFavorite on an unknown message is a no-op', () async {
      final store = newStore();
      await store.open();
      expect(await store.setFavorite(chatId: 1, messageId: 2, value: true),
          isFalse);
    });
  });

  group('persistence', () {
    test('state survives a reopen', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll([record(1), record(2)]);
      await store.setFavorite(chatId: 100, messageId: 2, value: true);
      await store.setWatermark(chatId: 100, newestMessageId: 2, oldestMessageId: 1);
      await store.close();

      final reopened = newStore();
      await reopened.open();
      expect(reopened.count, 2);
      expect(reopened.favoriteCount, 1);
      expect(reopened.watermark(100)?.newestMessageId, 2);
      expect(reopened.watermark(100)?.oldestMessageId, 1);
    });

    test('compaction rewrites the snapshot and truncates the journal', () async {
      final store = newStore(compactionThreshold: 5);
      await store.open();
      // Re-upserting the same 5 rows grows the journal while the row count stays
      // put — that ratio is what triggers compaction.
      for (var round = 0; round < 20; round++) {
        await store.upsertAll(List.generate(5, record));
      }
      expect(await sandbox.exists(store.snapshotPath), isTrue,
          reason: 'automatic compaction should have written a snapshot');
      expect(store.count, 5);

      // An explicit compact leaves a clean journal behind.
      await store.compact();
      expect(await store.ops.readAsString(store.journalPath), isEmpty);

      final reopened = newStore(compactionThreshold: 5);
      await reopened.open();
      expect(reopened.count, 5);
    });

    test('appending only new rows does not force a compaction', () async {
      final store = newStore(compactionThreshold: 5);
      await store.open();
      for (var i = 0; i < 20; i++) {
        await store.upsertAll([record(i)]);
      }
      // journal ops == live rows, so the snapshot would save nothing.
      expect(await sandbox.exists(store.snapshotPath), isFalse);
      expect(await store.ops.readAsString(store.journalPath), isNotEmpty);
    });

    test('a corrupt journal line is skipped, not fatal', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll([record(1)]);
      await sandbox.ops.appendAsString(store.journalPath, '{not json}\n');

      final reopened = newStore();
      await reopened.open();
      expect(reopened.count, 1);
      expect(reopened.droppedJournalLines, 1);
    });
  });

  group('pagination', () {
    test('walks 120 rows in 50/50/20 pages without duplicates', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll(List.generate(120, record));

      final seen = <int>{};
      String? cursor;
      final sizes = <int>[];
      var guard = 0;
      while (guard++ < 10) {
        final page = await store.page(limit: 50, cursor: cursor);
        if (page.items.isEmpty) break;
        sizes.add(page.items.length);
        for (final item in page.items) {
          expect(seen.add(item.messageId), isTrue,
              reason: 'duplicate ${item.messageId} across pages');
        }
        cursor = page.nextCursor;
        if (!page.hasMore) break;
      }
      expect(sizes, [50, 50, 20]);
      expect(seen.length, 120);
    });

    test('pages newest first', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll(List.generate(10, record));
      final page = await store.page(limit: 3);
      expect(page.items.map((e) => e.messageId).toList(), [9, 8, 7]);
    });

    test('filters by favourite and by channel', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll([
        record(1),
        record(2),
        record(3, chatId: 200),
      ]);
      await store.setFavorite(chatId: 100, messageId: 2, value: true);

      final favourites = await store.page(limit: 10, favoritesOnly: true);
      expect(favourites.items.map((e) => e.messageId).toList(), [2]);

      final channel = await store.page(limit: 10, chatId: 200);
      expect(channel.items.map((e) => e.messageId).toList(), [3]);
    });

    test('a corrupt cursor restarts from the top instead of crashing', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll(List.generate(5, record));
      final page = await store.page(limit: 2, cursor: 'not-a-cursor');
      expect(page.items, hasLength(2));
    });
  });

  group('local-only removal', () {
    test('drops one channel and keeps the rest', () async {
      final store = newStore();
      await store.open();
      await store.upsertAll([
        record(1),
        record(2),
        record(3, chatId: 200),
      ]);
      final removed = await store.removeLocalChannel(100);
      expect(removed, 2);
      expect(store.count, 1);
      expect(store.watermark(100), isNull);
    });
  });

  test('integrity snapshot exposes the counters used by cache checks', () async {
    final store = newStore();
    await store.open();
    await store.upsertAll([record(1), record(2)]);
    await store.setFavorite(chatId: 100, messageId: 1, value: true);
    final snapshot = await store.integritySnapshot();
    expect(snapshot['index'], 2);
    expect(snapshot['favorites'], 1);
    expect(snapshot['channels'], 0);
  });
}
