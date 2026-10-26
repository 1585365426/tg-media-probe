import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';

import 'support/sandbox.dart';

MediaRecord _video({
  required int chatId,
  required int messageId,
  int fileId = 1,
  int date = 1700000000,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: fileId,
      kind: MediaKind.video,
      durationSeconds: 30,
      sizeBytes: 1024,
      messageDateUnix: date,
    );

void main() {
  late TestSandbox box;
  late IndexStore store;

  setUp(() async {
    box = await TestSandbox.create();
    store = IndexStore(directory: box.layout.indexDir, ops: box.ops);
    await store.open();
  });

  tearDown(() async {
    await box.dispose();
  });

  group('IndexStore.revision', () {
    test('starts at zero after open, even when replaying a journal', () async {
      await store.upsertAll(<MediaRecord>[_video(chatId: 1, messageId: 1)]);
      await store.close();

      final reopened = IndexStore(directory: box.layout.indexDir, ops: box.ops);
      await reopened.open();
      expect(reopened.count, 1);
      // Replay must not bump: no reader exists during open, and a counter of
      // replay operations would tell callers nothing.
      expect(reopened.revision, 0);
      await reopened.close();
    });

    test('advances on upsertAll', () async {
      final before = store.revision;
      await store.upsertAll(<MediaRecord>[_video(chatId: 1, messageId: 1)]);
      expect(store.revision, before + 1);
    });

    test('advances once per upsertAll call, not once per record', () async {
      final before = store.revision;
      await store.upsertAll(<MediaRecord>[
        _video(chatId: 1, messageId: 1, fileId: 1),
        _video(chatId: 1, messageId: 2, fileId: 2),
        _video(chatId: 1, messageId: 3, fileId: 3),
      ]);
      expect(store.revision, before + 1);
    });

    test('does not advance on an empty upsertAll', () async {
      final before = store.revision;
      final inserted = await store.upsertAll(const <MediaRecord>[]);
      expect(inserted, 0);
      expect(store.revision, before);
    });

    test('advances on setFavorite', () async {
      await store.upsertAll(<MediaRecord>[_video(chatId: 1, messageId: 1)]);
      final before = store.revision;
      final changed = await store.setFavorite(
        chatId: 1,
        messageId: 1,
        value: true,
      );
      expect(changed, isTrue);
      expect(store.revision, before + 1);
    });

    test('does not advance when setFavorite misses the record', () async {
      final before = store.revision;
      final changed = await store.setFavorite(
        chatId: 99,
        messageId: 99,
        value: true,
      );
      expect(changed, isFalse);
      expect(store.revision, before);
    });

    test('advances on removeLocalChannel when rows were removed', () async {
      await store.upsertAll(<MediaRecord>[_video(chatId: 1, messageId: 1)]);
      final before = store.revision;
      final removed = await store.removeLocalChannel(1);
      expect(removed, 1);
      expect(store.revision, before + 1);
    });

    test('does not advance when removeLocalChannel removes nothing', () async {
      final before = store.revision;
      final removed = await store.removeLocalChannel(42);
      expect(removed, 0);
      expect(store.revision, before);
    });

    test('advances on setWatermark', () async {
      final before = store.revision;
      await store.setWatermark(chatId: 1, newestMessageId: 10);
      expect(store.revision, before + 1);
    });

    test('a reader can tell a sync happened between two reads', () async {
      // This is the contract the video feed relies on: snapshot, sync, compare.
      final seenAtLoad = store.revision;
      await store.upsertAll(<MediaRecord>[_video(chatId: 1, messageId: 1)]);
      expect(store.revision, isNot(seenAtLoad));
    });
  });
}
