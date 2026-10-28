/// The three numbers must never be confused:
/// * how many videos are **loaded** in the feed's window,
/// * how many the **index** says the channel has,
/// * how many cache **files** exist on disk.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/data/video_number_lookup.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_budget.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

import 'support/sandbox.dart';

MediaRecord _video(int id, {int chatId = 1, bool photo = false}) => MediaRecord(
      chatId: chatId,
      messageId: id,
      fileId: photo ? 500000 + id : 900000 + id,
      kind: photo ? MediaKind.photo : MediaKind.video,
      width: 720,
      height: 1280,
      durationSeconds: 10,
      sizeBytes: 1024,
      fileName: 'v$id.mp4',
      messageDateUnix: 1790000000,
    );

class _Player implements PlayerHandle {
  _Player(this.path);
  @override
  final String path;
  Duration position = Duration.zero;
  Duration duration = const Duration(seconds: 10);
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
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

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
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {}
  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {}
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

  /// 84 rows: 82 videos + 2 photos, both inside the first 40 rows so the first
  /// page yields exactly the 38 from the report.
  Future<void> seed84() async {
    await store.upsertAll(<MediaRecord>[
      for (var i = 0; i < 84; i++)
        _video(300 - i, photo: i == 5 || i == 20),
    ]);
  }

  FeedController controller({int pageSize = 40}) => FeedController(
        source: IndexFeedSource(store: store, chatId: 1, pageSize: pageSize),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: _Transfer(),
          fileExists: (_) async => true,
        ),
        pollInterval: null,
      );

  test('loaded window is 38 while the index holds 82', () async {
    await seed84();
    final c = controller();
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(c.length, 38, reason: 'one page of 40 rows minus 2 photos');
    expect(c.syncedVideos, 82, reason: 'the index is the source of truth');
    expect(c.positionLabel, contains('已同步 82'));
    expect(c.loadedAll, isFalse);
    c.shutdown();
  });

  test('rebuilding the page does not lose the indexed count', () async {
    await seed84();
    final first = controller();
    await first.load();
    await Future<void>.delayed(Duration.zero);
    expect(first.syncedVideos, 82);
    first.shutdown();

    // A fresh controller is what a tab switch / page rebuild does.
    final second = controller();
    await second.load();
    await Future<void>.delayed(Duration.zero);

    expect(second.syncedVideos, 82, reason: '38 is a window, not a total');
    expect(second.length, 38);
    second.shutdown();
  });

  test('wording separates loaded from synced, never claims a total', () async {
    await seed84();
    final c = controller();
    await c.load();
    await Future<void>.delayed(Duration.zero);

    // "1 / 38 · 已同步 82" — the first number is the playhead, the second the
    // window, the third what the channel actually has.
    expect(c.positionLabel, startsWith('1 / 38'));
    expect(c.positionLabel, contains('已同步 82'));
    c.shutdown();
  });

  test('clearing cache leaves counts, lookup and watch progress intact',
      () async {
    await seed84();
    // Some cache files to clean.
    for (var i = 0; i < 12; i++) {
      await sandbox.writeBytes(
          p.join(sandbox.layout.thumbnailDir, 't$i.jpg'), CacheBudget.mb);
    }
    final beforeCount = store.countByChat()[1];
    final beforeLookup =
        await VideoNumberLookup.find(store: store, chatId: 1, number: 38);

    final cleaner = AutoCacheCleaner(
      layout: sandbox.layout,
      ops: sandbox.ops,
      activeFiles: ActiveFileRegistry(),
    );
    final result = await cleaner.check(limitBytes: 10 * CacheBudget.mb);
    expect(result.deletedFiles, greaterThan(0));

    expect(store.countByChat()[1], beforeCount);
    final afterLookup =
        await VideoNumberLookup.find(store: store, chatId: 1, number: 38);
    expect(afterLookup.messageId, beforeLookup.messageId,
        reason: 'number 38 still points at the same video');

    final c = controller();
    await c.load();
    await Future<void>.delayed(Duration.zero);
    expect(c.syncedVideos, 82);
    c.shutdown();
  });

  test('three separate counters: index rows, videos, cache files', () async {
    await seed84();
    await sandbox.writeBytes(
        p.join(sandbox.layout.thumbnailDir, 'only-one.jpg'), 1024);

    expect(store.count, 84, reason: 'rows (videos + photos)');
    expect(store.countByChat()[1], 82, reason: 'videos only');
    expect(await sandbox.ops.listFilesRecursive(sandbox.layout.thumbnailDir),
        hasLength(1), reason: 'cache files are unrelated to either');
  });

  test('a much larger index still reports the real total', () async {
    // 800 videos: the reported "stuck at 725" case, from the counting side.
    await store.upsertAll(<MediaRecord>[
      for (var i = 0; i < 800; i++) _video(5000 - i),
    ]);
    final c = controller(pageSize: 40);
    await c.load();
    await Future<void>.delayed(Duration.zero);

    expect(c.length, 40);
    expect(c.syncedVideos, 800);
    expect(c.positionLabel, contains('已同步 800'));
    c.shutdown();
  });
}
