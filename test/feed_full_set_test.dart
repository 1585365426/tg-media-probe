/// Reproduces the on-device report: 82 videos indexed (channel detail says
/// "已加载 84 条，其中视频 82 条"), but the feed shows only 38.
///
/// 38 is not a limit in the code — it is what one 40-record page yields after
/// two non-video rows are filtered out. So the question this file answers is:
/// why does the feed stop after that first page?
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

import 'support/sandbox.dart';

MediaRecord _video(int messageId, {int chatId = 1}) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 100000 + messageId,
      kind: MediaKind.video,
      width: 1080,
      height: 1920,
      durationSeconds: 20,
      sizeBytes: 1024 * 1024,
      fileName: 'v$messageId.mp4',
      // Dates are deliberately identical for the whole fixture: that is what a
      // channel dump looks like, and it exercises the tie-breaker in the sort.
      messageDateUnix: 1790000000,
    );

MediaRecord _photo(int messageId, {int chatId = 1}) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 500000 + messageId,
      kind: MediaKind.photo,
      messageDateUnix: 1790000000,
    );

class _NoopPlayer implements PlayerHandle {
  @override
  final String path;
  _NoopPlayer(this.path);

  Duration position = Duration.zero;
  Duration duration = const Duration(seconds: 20);
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
  PlayerHandle create(String path) => _NoopPlayer(path);
}

class _FakeTransfer implements FileTransferApi {
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

  /// 84 rows: 82 videos interleaved with 2 photos, mirroring the screenshot.
  Future<void> seed84() async {
    final records = <MediaRecord>[];
    for (var id = 200; id > 116; id--) {
      // two photos at positions that land inside the first page of 40 rows
      final isPhoto = id == 195 || id == 180;
      records.add(isPhoto ? _photo(id) : _video(id));
    }
    await store.upsertAll(records);
  }

  FeedController controller({int? chatId}) => FeedController(
        source: IndexFeedSource(store: store, chatId: chatId),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: _FakeTransfer(),
          fileExists: (_) async => true,
        ),
        pollInterval: null,
      );

  test('the index really holds 82 videos in 84 rows', () async {
    await seed84();

    expect(store.countByChat()[1], 82);
    expect((await store.page(limit: 500, chatId: 1)).items, hasLength(84));
  });

  test('the first page of 40 rows yields 38 videos', () async {
    await seed84();
    final page = await store.page(limit: 40, chatId: 1);

    expect(page.items, hasLength(40));
    expect(page.items.where((r) => r.kind == MediaKind.video), hasLength(38));
    expect(page.hasMore, isTrue, reason: '44 rows still behind this page');
  });

  test('swiping to the tail extends the list instead of stopping at 38',
      () async {
    await seed84();
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);
    expect(c.length, 38, reason: 'the first page is 40 rows minus 2 photos');

    // What the page does on every swipe: goToIndex(viewIndex). Reaching the
    // last loaded item must pull the next page, or the PageView has nothing
    // left to scroll and no further callback ever arrives.
    await c.goToIndex(37);
    await Future<void>.delayed(Duration.zero);

    expect(c.length, greaterThan(38),
        reason: 'the tail of the window must extend the window');
    expect(c.current, isNotNull);
    c.shutdown();
  });

  test('walking the whole window reaches all 82 videos', () async {
    await seed84();
    final c = controller(chatId: 1);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    var guard = 0;
    while (guard++ < 200) {
      final before = c.length;
      await c.goToIndex(c.length - 1);
      await Future<void>.delayed(Duration.zero);
      if (c.length == before) break;
    }

    expect(c.length, 82,
        reason: 'every indexed video must be reachable from the feed');
    expect(c.atEnd, isTrue);
    c.shutdown();
  });

  test('the feed without a chat filter reaches everything too', () async {
    await seed84();
    final c = controller();
    await c.load();
    await Future<void>.delayed(Duration.zero);

    var guard = 0;
    while (guard++ < 200) {
      final before = c.length;
      await c.goToIndex(c.length - 1);
      await Future<void>.delayed(Duration.zero);
      if (c.length == before) break;
    }
    expect(c.length, 82);
    c.shutdown();
  });
}
