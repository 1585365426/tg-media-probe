/// "Video number" means one thing: the Nth playable video of one channel, in
/// display order. These tests pin that meaning for both entry points.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/data/video_number_lookup.dart';

import 'support/sandbox.dart';

MediaRecord _video(int chatId, int messageId) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 100000 + chatId * 10000 + messageId,
      kind: MediaKind.video,
      width: 720,
      height: 1280,
      durationSeconds: 10,
      sizeBytes: 1024,
      fileName: 'v$messageId.mp4',
      messageDateUnix: 1790000000,
    );

MediaRecord _photo(int chatId, int messageId) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 500000 + messageId,
      kind: MediaKind.photo,
      messageDateUnix: 1790000000,
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
    await sandbox.dispose();
  });

  /// 82 videos and 2 photos per channel, newest id first.
  Future<void> seedChannel(int chatId) async {
    final records = <MediaRecord>[];
    for (var i = 0; i < 84; i++) {
      final id = 200 - i;
      final isPhoto = i == 5 || i == 40;
      records.add(isPhoto ? _photo(chatId, id) : _video(chatId, id));
    }
    await store.upsertAll(records);
  }

  group('numbering', () {
    test('38 finds the 38th video of that channel, skipping photos', () async {
      await seedChannel(1);

      final result = await VideoNumberLookup.find(
        store: store,
        chatId: 1,
        number: 38,
        pageSize: 20,
      );

      expect(result.status, NumberLookupStatus.found);
      expect(result.chatId, 1);
      // The list is 200..117 with photos at 195 and 160; the first 37 videos
      // are 200..163 minus 195, so number 38 is message 162.
      expect(result.messageId, 162);
    });

    test('the same number in another channel stays in that channel', () async {
      await seedChannel(1);
      await seedChannel(2);

      final a = await VideoNumberLookup.find(store: store, chatId: 1, number: 38);
      final b = await VideoNumberLookup.find(store: store, chatId: 2, number: 38);

      expect(a.status, NumberLookupStatus.found);
      expect(b.status, NumberLookupStatus.found);
      expect(a.chatId, 1);
      expect(b.chatId, 2);
      // Same position, different rows: the id alone is not the identity.
      expect(a.messageId, b.messageId);
      expect(a.chatId, isNot(b.chatId));
    });

    test('a number past the end reports the real count', () async {
      await seedChannel(1);

      final result =
          await VideoNumberLookup.find(store: store, chatId: 1, number: 83);

      expect(result.status, NumberLookupStatus.notFound);
      expect(result.videoCount, 82,
          reason: 'the message says "当前共 82 条视频", not a guess');
      expect(result.messageId, isNull);
    });

    test('zero, negative and absurd numbers are invalid', () async {
      await seedChannel(1);
      for (final number in <int>[0, -1, -999, VideoNumberLookup.maxNumber + 1]) {
        final result =
            await VideoNumberLookup.find(store: store, chatId: 1, number: number);
        expect(result.status, NumberLookupStatus.invalid, reason: '$number');
      }
    });

    test('an empty channel has no numbers at all', () async {
      final result = await VideoNumberLookup.find(store: store, chatId: 1, number: 1);
      expect(result.status, NumberLookupStatus.notFound);
      expect(result.videoCount, 0);
    });
  });

  group('paging during the lookup', () {
    test('a number beyond one page is still found', () async {
      await seedChannel(1);

      final result = await VideoNumberLookup.find(
        store: store,
        chatId: 1,
        number: 80,
        pageSize: 10, // forces 8+ page reads
      );

      expect(result.status, NumberLookupStatus.found);
      expect(result.messageId, isNotNull);
    });

    test('appending older rows does not move an existing number', () async {
      // First half only.
      final first = <MediaRecord>[
        for (var i = 0; i < 40; i++) _video(1, 200 - i),
      ];
      await store.upsertAll(first);
      final before = await VideoNumberLookup.find(store: store, chatId: 1, number: 10);
      expect(before.status, NumberLookupStatus.found);

      // A sync appends older videos; the order of the first 40 is unchanged.
      await store.upsertAll(<MediaRecord>[
        for (var i = 40; i < 90; i++) _video(1, 200 - i),
      ]);
      final after = await VideoNumberLookup.find(store: store, chatId: 1, number: 10);

      expect(after.messageId, before.messageId,
          reason: 'number 10 must still be the same video');
    });

    test('the lookup never needs a network client', () async {
      // There is no TdClient in this test at all: a lookup that touched
      // Telegram would not even compile here.
      await seedChannel(1);
      final result = await VideoNumberLookup.find(store: store, chatId: 1, number: 1);
      expect(result.status, NumberLookupStatus.found);
    });

    test('a channel with only photos has zero videos', () async {
      await store.upsertAll(<MediaRecord>[
        for (var i = 0; i < 10; i++) _photo(1, 100 - i),
      ]);

      final result = await VideoNumberLookup.find(store: store, chatId: 1, number: 1);
      expect(result.status, NumberLookupStatus.notFound);
      expect(result.videoCount, 0);
    });
  });
}
