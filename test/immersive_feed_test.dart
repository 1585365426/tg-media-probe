/// Immersive playback regressions.
///
/// The rules the device team signed off on, one per test:
/// * the video owns the screen while it plays — chrome (channel name, number
///   entry, title, date, size, position, synced count, tab bar) is hidden;
/// * one tap reveals the chrome, the next tap hides it again;
/// * a swipe inherits the current immersive state instead of re-hiding;
/// * buffering and errors are state, not chrome: they stay visible;
/// * leaving the feed (back / tab switch) persists the last playhead.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/playback/watch_store.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';
import 'package:tg_media_probe/storage/file_ops.dart';

import 'support/sandbox.dart';

// ------------------------------------------------------------------ fixtures

MediaRecord video(int messageId) => MediaRecord(
      chatId: 1,
      messageId: messageId,
      fileId: 1000 + messageId,
      kind: MediaKind.video,
      sizeBytes: 4096,
      fileName: 'v$messageId.mp4',
      messageDateUnix: 1700000000 + messageId,
    );

class _Transfer implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) => startRange(
        fileId,
        offset: 0,
        limit: StreamWindow.preloadBytes,
        caller: DownloadCaller.preload,
      );

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  @override
  Future<FileState?> stat(int fileId) async => FileState(
        id: fileId,
        size: 0,
        expectedSize: 4096,
        downloadedSize: 0,
        isCompleted: false,
        path: '',
        canBeDownloaded: true,
      );

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    _updates.add(FileState(
      id: fileId,
      size: 4096,
      expectedSize: 4096,
      downloadedSize: 4096,
      isCompleted: true,
      path: '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    // A preload produces bytes and nothing else; every other caller is the
    // play's own bounded window.
    if (caller == DownloadCaller.preload) return;
    await start(fileId, caller: caller, cause: cause);
  }
  @override
  Future<void> cancel(int fileId) async {}

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

class _Player implements PlayerHandle, PlayerProgress {
  _Player(this.path);

  @override
  final String path;
  bool _playing = false;
  bool _disposed = false;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 30);

  @override
  bool get isPlaying => _playing;
  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {}
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> disposePlayer() async => _disposed = true;
}

class _Factory implements PlayerFactory {
  final List<_Player> created = <_Player>[];

  @override
  PlayerHandle create(String path) {
    final player = _Player(path);
    created.add(player);
    return player;
  }
}

// --------------------------------------------------------------------- tests

void main() {
  group('FeedImmersivePlan', () {
    test('the pager phases are the only ones where overlays exist', () {
      // Playback phases with items: a tap can reveal chrome.
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.buffering, itemCount: 1),
        isTrue,
      );
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.ready, itemCount: 1),
        isTrue,
      );
      // An error over a loaded list keeps the items behind the failure card.
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.error, itemCount: 4),
        isTrue,
      );

      // Everything else replaces the pager: nothing to reveal.
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.loading, itemCount: 0),
        isFalse,
      );
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.empty, itemCount: 0),
        isFalse,
      );
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.error, itemCount: 0),
        isFalse,
      );
      expect(
        FeedImmersivePlan.playbackActive(
            phase: FeedPhase.ready, itemCount: 0),
        isFalse,
      );
    });

    test('overlays follow the tap flag: immersive by default', () {
      // Default state: chrome hidden — the immersive default.
      expect(
        FeedImmersivePlan.overlaysVisible(
            phase: FeedPhase.ready, itemCount: 1, controlVisible: false),
        isFalse,
      );
      // One tap: chrome appears.
      expect(
        FeedImmersivePlan.overlaysVisible(
            phase: FeedPhase.ready, itemCount: 1, controlVisible: true),
        isTrue,
      );
      // Even with the flag on, phases without a pager show nothing.
      expect(
        FeedImmersivePlan.overlaysVisible(
            phase: FeedPhase.loading, itemCount: 0, controlVisible: true),
        isFalse,
      );
    });

    test('the tab bar hides only for a playing feed tab', () {
      expect(
        FeedImmersivePlan.tabBarHidden(
            feedTabActive: true, playbackActive: true),
        isTrue,
      );
      // Another tab on top: the shell chrome must be back.
      expect(
        FeedImmersivePlan.tabBarHidden(
            feedTabActive: false, playbackActive: true),
        isFalse,
      );
      // Feed tab but no video on screen (loading/empty).
      expect(
        FeedImmersivePlan.tabBarHidden(
            feedTabActive: true, playbackActive: false),
        isFalse,
      );
    });
  });

  group('swipes inherit the immersive state', () {
    late TestSandbox sandbox;

    setUp(() async {
      sandbox = await TestSandbox.create();
    });

    tearDown(() async {
      await sandbox.dispose();
    });

    Future<(FeedController, _Factory, _Transfer)> rig(
      List<MediaRecord> records,
    ) async {
      final store = IndexStore(
        directory: sandbox.layout.indexDir,
        ops: sandbox.ops,
      );
      await store.open();
      await store.upsertAll(records);
      final api = _Transfer();
      final factory = _Factory();
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: factory),
        sources: VideoSourceResolver(api: api, fileExists: (_) async => true),
        preloadCount: 0,
        pollInterval: null,
      );
      await controller.load();
      return (controller, factory, api);
    }

    test('revealed chrome survives a page turn', () async {
      final (controller, _, api) = await rig(
        <MediaRecord>[video(1), video(2), video(3)],
      );
      expect(controller.phase, FeedPhase.ready);
      expect(controller.controlVisible, isFalse,
          reason: '播放开始默认沉浸');

      controller.toggleControls();
      expect(controller.controlVisible, isTrue);

      // The swipe must not re-hide: "新视频自动继承当前沉浸模式".
      await controller.goNext();
      expect(controller.index, 1);
      expect(controller.controlVisible, isTrue,
          reason: '滑动切换不得重新隐藏信息层');

      controller.dispose();
      await api.close();
    });

    test('an immersive swipe stays immersive', () async {
      final (controller, _, api) = await rig(
        <MediaRecord>[video(1), video(2)],
      );
      expect(controller.controlVisible, isFalse);

      await controller.goNext();
      expect(controller.controlVisible, isFalse,
          reason: '本来就沉浸，滑动不得弹出信息层');

      controller.dispose();
      await api.close();
    });

    test('leaving the feed persists the last playhead', () async {
      final store = IndexStore(
        directory: sandbox.layout.indexDir,
        ops: sandbox.ops,
      );
      await store.open();
      await store.upsertAll(<MediaRecord>[video(1), video(2)]);
      final api = _Transfer();
      final watch = WatchStore(
        directory: sandbox.layout.indexDir,
        ops: const IoFileOps(),
      );
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(api: api, fileExists: (_) async => true),
        watch: watch,
        preloadCount: 0,
        pollInterval: null,
      );
      await controller.load();
      expect(controller.phase, FeedPhase.ready);

      // Simulate 12 seconds watched, then leave the feed without any poll
      // tick in between: shutdown() is the only writer left.
      final handle = controller.player.active as _Player;
      handle.position = const Duration(seconds: 12);
      await controller.shutdown();

      // The write is fire-and-forget; give the file IO a beat.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Newest first: with messages 1 and 2 in the index the feed lands on 2.
      final entry = watch.read(1, 2);
      expect(entry, isNotNull, reason: '退出播放页必须落盘最后进度');
      expect(entry!.positionMs, 12000);

      controller.dispose();
      await api.close();
    });

    test('backgrounding the feed persists the playhead too', () async {
      final store = IndexStore(
        directory: sandbox.layout.indexDir,
        ops: sandbox.ops,
      );
      await store.open();
      await store.upsertAll(<MediaRecord>[video(1)]);
      final api = _Transfer();
      final watch = WatchStore(
        directory: sandbox.layout.indexDir,
        ops: const IoFileOps(),
      );
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(api: api, fileExists: (_) async => true),
        watch: watch,
        preloadCount: 0,
        pollInterval: null,
      );
      await controller.load();
      expect(controller.phase, FeedPhase.ready);

      final handle = controller.player.active as _Player;
      handle.position = const Duration(seconds: 5);
      // Tab switch / app background: the decoder is released, the playhead
      // must be written before it goes.
      await controller.handleLifecycle(AppLifecycleState.paused);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final entry = watch.read(1, 1);
      expect(entry, isNotNull);
      expect(entry!.positionMs, 5000);

      controller.dispose();
      await api.close();
    });
  });
}
