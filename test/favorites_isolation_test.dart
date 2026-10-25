import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/favorites_store.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';

import 'support/sandbox.dart';

MediaRecord video({
  int chatId = 1,
  int messageId = 1,
  int duration = 30,
  String? caption,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: messageId * 7,
      kind: MediaKind.video,
      durationSeconds: duration,
      caption: caption,
      sizeBytes: 1024,
      messageDateUnix: 1700000000 - messageId,
    );

void main() {
  late TestSandbox box;
  late FavoritesStore favorites;
  late IndexStore index;

  setUp(() async {
    box = await TestSandbox.create();
    favorites = FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
    index = IndexStore(directory: box.layout.indexDir, ops: box.ops);
    await favorites.open();
    await index.open();
  });

  tearDown(() async {
    await box.dispose();
  });

  group('FavoritesStore', () {
    test('starts empty', () {
      expect(favorites.count, 0);
      expect(favorites.all(), isEmpty);
      expect(favorites.isFavorite(1, 1), isFalse);
    });

    test('add is idempotent and survives a reopen', () async {
      expect(await favorites.add(video()), isTrue);
      expect(await favorites.add(video()), isFalse,
          reason: 'adding the same key twice is not a change');

      final reopened =
          FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
      await reopened.open();
      expect(reopened.count, 1);
      expect(reopened.isFavorite(1, 1), isTrue);
      expect(reopened.all().single.caption, isNull);
    });

    test('remove reports whether anything went away', () async {
      await favorites.add(video(messageId: 3));
      expect(await favorites.remove(chatId: 1, messageId: 3), isTrue);
      expect(await favorites.remove(chatId: 1, messageId: 3), isFalse);
      expect(favorites.count, 0);
    });

    test('toggle flips and reports the new state', () async {
      expect(await favorites.toggle(video(messageId: 5)), isTrue);
      expect(favorites.isFavorite(1, 5), isTrue);
      expect(await favorites.toggle(video(messageId: 5)), isFalse);
      expect(favorites.isFavorite(1, 5), isFalse);
    });

    test('all() is newest first', () async {
      await favorites.add(video(messageId: 1));
      await favorites.add(video(messageId: 9));
      await favorites.add(video(messageId: 5));
      expect(favorites.all().map((r) => r.messageId), <int>[1, 5, 9]);
    });

    test('a corrupt file loses the list but does not throw', () async {
      await box.write(box.indexFile('favorites.json'), '{"items": "nope"}');
      final reopened =
          FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
      await reopened.open();
      expect(reopened.count, 0);
    });

    test('the file lives in the index zone, not the cache zone', () {
      expect(favorites.filePath, contains(box.layout.indexDir));
      expect(favorites.filePath, isNot(contains(box.layout.tempRoot)));
    });
  });

  group('favourites survive operations that rewrite the index', () {
    test('removeLocalChannel drops mirror rows but keeps favourites', () async {
      await index.upsertAll(<MediaRecord>[
        video(messageId: 1),
        video(messageId: 2),
      ]);
      await favorites.add(video(messageId: 1));
      expect(index.count, 2);

      final removed = await index.removeLocalChannel(1);
      expect(removed, 2);
      expect(index.count, 0);

      final reopened =
          FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
      await reopened.open();
      expect(reopened.count, 1,
          reason: 'a channel cleanup must not empty the favourites list');
      expect(reopened.isFavorite(1, 1), isTrue);
    });
  });

  group('cache clear leaves favourites untouched', () {
    test('clear() deletes temp files and leaves favourites + index intact',
        () async {
      // Real files in the three temp directories.
      await box.writeBytes(box.tempFile('a.jpg'), 400);
      await box.writeBytes(
          box.tempFile('b.mp4', kind: CacheKindName.player), 600);
      await box.writeBytes(
          box.tempFile('c.part', kind: CacheKindName.partial), 200);
      // A user download that must survive too.
      await box.writeBytes(box.downloadFile('keep.mp4'), 900);

      await index.upsertAll(<MediaRecord>[video(messageId: 1)]);
      await favorites.add(video(messageId: 1));
      await favorites.add(video(messageId: 2));

      final manager = CacheManager(
        layout: box.layout,
        ops: box.ops,
        activeFiles: ActiveFileRegistry(),
        integrityProbe: () async => <String, int>{
          'index': index.count,
          'favorites': favorites.count,
        },
      );

      final before = await manager.scan();
      expect(before.totalBytes, 1200);

      final report = await manager.clear(userConfirmed: true);
      expect(report.succeeded, isTrue, reason: report.summary);
      expect(report.deletedFiles, 3);
      expect(report.freedBytes, 1200);

      expect(await box.exists(box.downloadFile('keep.mp4')), isTrue);
      expect(await box.exists(favorites.filePath), isTrue,
          reason: 'favorites.json must be untouched');

      final reopened =
          FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
      await reopened.open();
      expect(reopened.count, 2);
      expect(reopened.isFavorite(1, 1), isTrue);
      expect(index.count, 1);
    });

    test('the integrity probe fails the run if favourites changed', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 100);
      await favorites.add(video(messageId: 1));

      var calls = 0;
      final manager = CacheManager(
        layout: box.layout,
        ops: box.ops,
        activeFiles: ActiveFileRegistry(),
        integrityProbe: () async {
          calls++;
          return <String, int>{'favorites': calls == 1 ? 1 : 0};
        },
      );

      final report = await manager.clear(userConfirmed: true);
      expect(report.integrityPreserved, isFalse);
      expect(report.succeeded, isFalse,
          reason: 'a partial success must never be reported as success');
    });

    test('clear() refuses to run without user confirmation', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 10);
      final manager = CacheManager(
        layout: box.layout,
        ops: box.ops,
        activeFiles: ActiveFileRegistry(),
      );
      expect(
        () => manager.clear(userConfirmed: false),
        throwsA(isA<CacheClearNotConfirmed>()),
      );
      expect(await box.exists(box.tempFile('a.jpg')), isTrue);
    });

    test('a file held by the player is skipped, not deleted', () async {
      final path = box.tempFile('busy.mp4', kind: CacheKindName.player);
      await box.writeBytes(path, 512);
      final registry = ActiveFileRegistry()..markInUse(path, reason: 'player');
      final manager = CacheManager(
        layout: box.layout,
        ops: box.ops,
        activeFiles: registry,
      );

      final report = await manager.clear(userConfirmed: true);
      expect(report.deletedFiles, 0);
      expect(report.skippedInUse.length, 1);
      expect(await box.exists(path), isTrue);
    });
  });
}
