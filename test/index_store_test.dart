/// Local mirror behaviour: append, replay, page, and the channel order that the
/// numbering depends on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';

import 'support/sandbox.dart';

MediaRecord video({
  required int messageId,
  int chatId = 1,
  int date = 1790000000,
  String? caption,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 900 + messageId,
      kind: MediaKind.video,
      width: 720,
      height: 1280,
      durationSeconds: 12,
      sizeBytes: 1000,
      messageDateUnix: date,
      caption: caption,
    );

void main() {
  late TestSandbox sandbox;
  late IndexStore store;

  setUp(() async {
    sandbox = await TestSandbox.create();
    store = IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await store.open();
  });

  tearDown(() async {
    await store.close();
    await sandbox.dispose();
  });

  test('upsertAll counts only new rows', () async {
    expect(await store.upsertAll(<MediaRecord>[video(messageId: 1)]), 1);
    expect(await store.upsertAll(<MediaRecord>[video(messageId: 1)]), 0);
    expect(store.count, 1);
  });

  test('recordsForChannel is oldest first, per channel', () async {
    await store.upsertAll(<MediaRecord>[
      video(messageId: 3, date: 300),
      video(messageId: 1, date: 100),
      video(messageId: 2, date: 200),
      video(messageId: 10, chatId: 2, date: 50),
    ]);

    expect(
      store.recordsForChannel(1).map((r) => r.messageId).toList(),
      <int>[1, 2, 3],
    );
    expect(store.recordsForChannel(2).single.messageId, 10);
    expect(store.recordsForChannel(3), isEmpty);
  });

  test('same timestamp falls back to message id order', () async {
    await store.upsertAll(<MediaRecord>[
      video(messageId: 9, date: 500),
      video(messageId: 4, date: 500),
    ]);
    expect(
      store.recordsForChannel(1).map((r) => r.messageId).toList(),
      <int>[4, 9],
    );
  });

  test('countByChat counts videos only', () async {
    await store.upsertAll(<MediaRecord>[
      video(messageId: 1),
      video(messageId: 2),
      MediaRecord(
        chatId: 1,
        messageId: 3,
        fileId: 5,
        kind: MediaKind.document,
        messageDateUnix: 1790000000,
      ),
    ]);
    expect(store.countByChat()[1], 2);
  });

  test('captions survive a round trip through the journal', () async {
    await store.upsertAll(<MediaRecord>[
      video(messageId: 7, caption: '海边的日落'),
    ]);
    expect(store.recordsForChannel(1).single.caption, '海边的日落');

    final reopened =
        IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await reopened.open();
    expect(reopened.recordsForChannel(1).single.caption, '海边的日落');
    await reopened.close();
  });

  test('page walks newest first with an opaque cursor', () async {
    await store.upsertAll(<MediaRecord>[
      for (var i = 1; i <= 6; i++) video(messageId: i, date: 100 * i),
    ]);
    final first = await store.page(limit: 2);
    expect(first.items.map((r) => r.messageId).toList(), <int>[6, 5]);
    expect(first.hasMore, isTrue);

    final second = await store.page(limit: 2, cursor: first.nextCursor);
    expect(second.items.map((r) => r.messageId).toList(), <int>[4, 3]);
  });

  test('watermark scan cursor only ever moves downwards', () async {
    await store.setWatermark(chatId: 1, oldestScannedMessageId: 500);
    await store.setWatermark(chatId: 1, oldestScannedMessageId: 900);
    expect(store.watermark(1)!.scanCursor, 500);
    await store.setWatermark(chatId: 1, oldestScannedMessageId: 100);
    expect(store.watermark(1)!.scanCursor, 100);
  });

  test('removeLocalChannel drops rows and watermark for one channel only',
      () async {
    await store.upsertAll(<MediaRecord>[
      video(messageId: 1, chatId: 1),
      video(messageId: 2, chatId: 2),
    ]);
    await store.setWatermark(chatId: 1, newestMessageId: 1);
    final removed = await store.removeLocalChannel(1);
    expect(removed, 1);
    expect(store.count, 1);
    expect(store.watermark(1), isNull);
    expect(store.contains(2, 2), isTrue);
  });

  test('compaction keeps every row', () async {
    await store.upsertAll(<MediaRecord>[
      for (var i = 1; i <= 20; i++) video(messageId: i, date: 100 * i),
    ]);
    await store.compact();
    expect(store.count, 20);

    final reopened =
        IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await reopened.open();
    expect(reopened.count, 20);
    await reopened.close();
  });

  test('a damaged journal line is skipped, not fatal', () async {
    await sandbox.write(
      store.journalPath,
      '{"op":"m","r":{"c":1,"m":1,"f":1,"k":"video"}}\nnot json\n',
    );
    final reopened =
        IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await reopened.open();
    expect(reopened.count, 1);
    expect(reopened.droppedJournalLines, 1);
    await reopened.close();
  });
}
