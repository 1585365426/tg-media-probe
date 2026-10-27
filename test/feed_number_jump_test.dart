/// "Jump to video number": 1-based, over the *current* list, bound to a stable
/// (chatId, messageId) rather than to an array slot.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

import 'support/sandbox.dart';

MediaRecord _video(int id, {int chatId = 1}) => MediaRecord(
      chatId: chatId,
      messageId: id,
      fileId: 100000 + chatId * 1000 + id,
      kind: MediaKind.video,
      width: 1080,
      height: 1920,
      durationSeconds: 15,
      sizeBytes: 1024,
      fileName: 'v$id.mp4',
      messageDateUnix: 1790000000,
    );

class _Player implements PlayerHandle {
  _Player(this.path);
  @override
  final String path;
  Duration position = Duration.zero;
  Duration duration = const Duration(seconds: 15);
  @override
  bool get isPlaying => false;
  @override
  bool get isDisposed => false;
  @override
  Future<void> load() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> disposePlayer() async {}
}

class _Factory implements PlayerFactory {
  @override
  PlayerHandle create(String path) => _Player(path);
}

class _Transfer implements FileTransferApi {
  @override
  Future<FileState?> stat(int fileId) async => FileState(
        id: fileId,
        size: 1024,
        expectedSize: 1024,
        downloadedSize: 1024,
        isCompleted: true,
        path: '/pool/$fileId',
        canBeDownloaded: true,
      );
  @override
  Future<void> start(int fileId) async {}
  @override
  Future<void> startRange(int fileId, {required int offset, required int limit}) async {}
  @override
  Future<void> cancel(int fileId) async {}
  @override
  Stream<FileState> updates() => const Stream<FileState>.empty();
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

  Future<void> seed(int count, {int chatId = 1}) async {
    final records = <MediaRecord>[];
    // Newest first, so position 1 is the highest id.
    for (var i = 0; i < count; i++) {
      records.add(_video(1000 - i, chatId: chatId));
    }
    await store.upsertAll(records);
  }

  FeedController controller({int? chatId}) => FeedController(
        source: IndexFeedSource(store: store, chatId: chatId, pageSize: 20),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: _Transfer(),
          fileExists: (_) async => true,
        ),
        pollInterval: null,
      );

  test('number 1 opens the first item', () async {
    await seed(50);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(await c.openNumber(1), NumberJumpResult.opened);
    expect(c.index, 0);
    expect(c.current?.messageId, 1000);
    c.shutdown();
  });

  test('number 38 opens the thirty-eighth item, not the first', () async {
    await seed(82);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(await c.openNumber(38), NumberJumpResult.opened);
    expect(c.index, 37);
    expect(c.current?.messageId, 1000 - 37);
    c.shutdown();
  });

  test('a number past the loaded window keeps paging until it is reachable',
      () async {
    await seed(82);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);
    // pageSize 20: only 20 items are in memory at this point.
    expect(c.length, 20);

    expect(await c.openNumber(60), NumberJumpResult.opened);
    expect(c.length, greaterThanOrEqualTo(60));
    expect(c.current?.messageId, 1000 - 59);
    c.shutdown();
  });

  test('a number beyond the whole list reports notFound and stays put',
      () async {
    await seed(10);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);
    final before = c.current?.messageId;

    expect(await c.openNumber(500), NumberJumpResult.notFound);
    expect(c.current?.messageId, before,
        reason: 'a miss must not jump back to item 1');
    expect(c.index, 0);
    c.shutdown();
  });

  test('zero, negative and absurd numbers are invalid, not a lookup', () async {
    await seed(10);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(await c.openNumber(0), NumberJumpResult.invalid);
    expect(await c.openNumber(-3), NumberJumpResult.invalid);
    expect(await c.openNumber(FeedController.maxNumber + 1),
        NumberJumpResult.invalid);
    c.shutdown();
  });

  test('the whole list is reachable by number, including its tail', () async {
    await seed(82);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(await c.openNumber(82), NumberJumpResult.opened);
    expect(c.current?.messageId, 1000 - 81);
    expect(c.atEnd, isTrue);
    c.shutdown();
  });

  test('the number is stable after the list grows', () async {
    await seed(30);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);
    expect(await c.openNumber(10), NumberJumpResult.opened);
    final tenth = c.current?.messageId;

    // More rows arrive (a later sync); the tenth item is still the same video
    // because the list is ordered newest-first and the new rows are older.
    await seed(30);
    await store.upsertAll(<MediaRecord>[
      for (var i = 30; i < 40; i++) _video(1000 - i, chatId: 1),
    ]);
    final fresh = controller(chatId: 1);
    await fresh.load();
    await Future<void>.delayed(Duration.zero);
    expect(await fresh.openNumber(10), NumberJumpResult.opened);

    expect(fresh.current?.messageId, tenth);
    fresh.shutdown();
    c.shutdown();
  });

  test('a number jump never looks at Telegram', () async {
    // The controller has no client at all in this test: if openNumber tried a
    // network lookup it would not compile, let alone pass.
    await seed(5);
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(await c.openNumber(3), NumberJumpResult.opened);
    c.shutdown();
  });
}
