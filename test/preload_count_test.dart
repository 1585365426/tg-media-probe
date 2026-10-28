/// The preload window is a number the user owns: 0–3, forward only, one
/// transfer at a time. These tests pin the bound, the persistence and the
/// "current video wins" rule.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_preferences.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

import 'support/sandbox.dart';

MediaRecord _video(int id) => MediaRecord(
      chatId: 1,
      messageId: id,
      fileId: 900000 + id,
      kind: MediaKind.video,
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

/// Counts transfers and lets a test pick which file ids fail or are instant.
class _Transfer implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  _Transfer({this.localIds = const <int>{}, this.failIds = const <int>{}});

  final Set<int> localIds;
  final Set<int> failIds;
  final List<int> started = <int>[];
  final List<int> cancelled = <int>[];
  /// Every request with the caller that sent it. B+ reads this to prove a
  /// preload never becomes a transfer.
  final List<(int, DownloadCaller)> calls = <(int, DownloadCaller)>[];
  final Set<int> _done = <int>{};

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  @override
  Future<FileState?> stat(int fileId) async {
    // A finished download changes what `stat` answers, the way TDLib does.
    // Without this the B+ chain (reader → disk watermark) could never see the
    // file as complete and every play would wait out its timeout.
    final local = localIds.contains(fileId) || _done.contains(fileId);
    return FileState(
      id: fileId,
      size: local ? 1024 : 0,
      expectedSize: 1024,
      downloadedSize: local ? 1024 : 0,
      isCompleted: local,
      path: local ? '/pool/$fileId' : '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    calls.add((fileId, caller));
    if (failIds.contains(fileId)) {
      throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    }
    started.add(fileId);
    _done.add(fileId);
    // Complete immediately: without an update the resolver would wait for its
    // 15 s timeout and every test here would need half a minute.
    _updates.add(FileState(
      id: fileId,
      size: 1024,
      expectedSize: 1024,
      downloadedSize: 1024,
      isCompleted: true,
      path: '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    calls.add((fileId, caller));
    if (failIds.contains(fileId)) {
      throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    }
    // A preload only ever records the request: it must not produce a path or
    // a completion, or a neighbour would be ready to play.
    if (caller == DownloadCaller.preload) {
      started.add(fileId);
      return;
    }
    await start(fileId, caller: caller, cause: cause);
  }
  @override
  Future<void> cancel(int fileId) async => cancelled.add(fileId);

  @override
  Stream<FileState> updates() => _updates.stream;
}

void main() {
  late TestSandbox sandbox;
  late IndexStore store;

  setUp(() async {
    sandbox = await TestSandbox.create();
    store = IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await store.open();
    await store.upsertAll(<MediaRecord>[for (var i = 0; i < 8; i++) _video(100 - i)]);
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  FeedController controller({
    required _Transfer transfer,
    int preloadCount = 1,
  }) =>
      FeedController(
        source: IndexFeedSource(store: store, chatId: 1, pageSize: 40),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: transfer,
          fileExists: (_) async => true,
          // The pool paths are fake; the stat says a local file is 1024 B.
          diskSizeOf: (_) async => 1024,
        ),
        preloadCount: preloadCount,
        pollInterval: null,
      );

  group('preference', () {
    test('the default is one item, matching the old on/off switch', () {
      const prefs = AppPreferences.initial;
      expect(prefs.preloadCount, 1);
      expect(prefs.preloadAdjacent, isTrue);
      expect(AppPreferences.maxPreloadCount, 3);
    });

    test('a count survives a save and a restart', () async {
      final secrets = MemorySecretStore();
      final store1 = PreferencesStore(store: secrets);
      final first = PreferencesController(store: store1);
      await first.load();

      expect(await first.setPreloadCount(2), isTrue);

      final second = PreferencesController(store: PreferencesStore(store: secrets));
      await second.load();
      expect(second.value.preloadCount, 2);
      expect(second.value.preloadAdjacent, isTrue);
      first.dispose();
      second.dispose();
    });

    test('zero disables it and is remembered', () async {
      final secrets = MemorySecretStore();
      final controller = PreferencesController(store: PreferencesStore(store: secrets));
      await controller.load();

      expect(await controller.setPreloadCount(0), isTrue);

      final again = PreferencesController(store: PreferencesStore(store: secrets));
      await again.load();
      expect(again.value.preloadCount, 0);
      expect(again.value.preloadAdjacent, isFalse,
          reason: 'the legacy flag must agree with the count');
      controller.dispose();
      again.dispose();
    });

    test('negative and above the ceiling are refused, value unchanged',
        () async {
      final secrets = MemorySecretStore();
      final controller = PreferencesController(store: PreferencesStore(store: secrets));
      await controller.load();
      await controller.setPreloadCount(2);

      expect(await controller.setPreloadCount(-1), isFalse);
      expect(await controller.setPreloadCount(4), isFalse);
      expect(await controller.setPreloadCount(999), isFalse);
      expect(controller.value.preloadCount, 2,
          reason: 'a refused value must not overwrite the valid one');
      controller.dispose();
    });

    test('an old record with only the boolean still loads', () {
      final legacy = AppPreferences.fromJson(<String, Object?>{
        'theme': 'dark',
        'defaultMuted': true,
        'preloadAdjacent': false,
      });
      expect(legacy.preloadCount, 0);
      expect(legacy.preloadAdjacent, isFalse);

      final legacyOn = AppPreferences.fromJson(<String, Object?>{
        'preloadAdjacent': true,
      });
      expect(legacyOn.preloadCount, 1);
    });

    test('a hand-edited out-of-range count is clamped, not fatal', () {
      final prefs = AppPreferences.fromJson(<String, Object?>{'preloadCount': 99});
      expect(prefs.preloadCount, AppPreferences.maxPreloadCount);
      final negative = AppPreferences.fromJson(<String, Object?>{'preloadCount': -5});
      expect(negative.preloadCount, 0);
    });
  });

  group('the window bounds transfers', () {
    test('count 0 prefetches nothing', () async {
      final transfer = _Transfer(localIds: <int>{900100});
      final c = controller(transfer: transfer, preloadCount: 0);
      await c.load();
      await Future<void>.delayed(Duration.zero);

      expect(transfer.started, isEmpty);
      expect(c.prefetchCompleted, 0);
      c.shutdown();
    });

    test('count 2 warms exactly the next two items, and downloads nothing',
        () async {
      // B+：预取不再是 TDLib 请求。已在本地的邻居被「warm」，其余等用户点开
      // 时由 Downloader 拉全文件。窗口仍然只有 2 个。
      final transfer = _Transfer(localIds: <int>{900100, 900099, 900098});
      final c = controller(transfer: transfer, preloadCount: 2);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.prefetchCompleted, 2, reason: '窗口内的两个邻居被 warm');
      expect(
        transfer.calls.where((c) => c.$2 == DownloadCaller.preload),
        isEmpty,
        reason: 'B+：preload 不得发出任何 TDLib 请求',
      );
      c.shutdown();
    });

    test('count above the ceiling is clamped by the controller', () async {
      final transfer = _Transfer(localIds: <int>{900100});
      final c = controller(transfer: transfer, preloadCount: 99);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.preloadCount, 99, reason: 'the field keeps what it was given');
      expect(transfer.started.length,
          lessThanOrEqualTo(AppPreferences.maxPreloadCount));
      c.shutdown();
    });

    test('switching cancels the rest of the old window', () async {
      // The item the swipe lands on is already on disk: what this test is
      // about is the preload window, and a play that had to stream would fail
      // for an unrelated reason on a host with no native bridge.
      final transfer = _Transfer(
        localIds: <int>{900100, 900095, 900099, 900098, 900097},
      );
      final c = controller(transfer: transfer, preloadCount: 3);
      await c.load();
      await Future<void>.delayed(Duration.zero);
      final before = transfer.started.length;

      await c.goToIndex(5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newRequests = transfer.started.skip(before).toList();

      // The old window (items 99..97) must not keep working after the switch:
      // the new requests belong to the new position (95 and its neighbours).
      expect(newRequests, isNot(contains(900097)));
      expect(newRequests, isNot(contains(900096)));
      expect(newRequests.length,
          lessThanOrEqualTo(AppPreferences.maxPreloadCount));
      expect(c.current?.messageId, 95);
      // The old requests were accepted by TDLib and keep downloading until
      // someone cancels them — the "152 MB loaded first" report.
      expect(transfer.cancelled, containsAll(<int>[900099, 900098, 900097]));
      expect(transfer.cancelled, isNot(contains(900095)),
          reason: '正在播放的文件不得被预加载的清理取消');
      c.shutdown();
    });
  });

  group('a prefetch cannot hurt the item being watched', () {
    test('a failing prefetch leaves playback ready', () async {
      final transfer = _Transfer(
        localIds: <int>{900100},
        failIds: <int>{900099},
      );
      final c = controller(transfer: transfer, preloadCount: 2);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.phase, FeedPhase.ready);
      expect(c.prefetchFailed, greaterThanOrEqualTo(1));
      expect(c.current?.messageId, 100);
      c.shutdown();
    });

    test('the current item is resolved before the window is prepared',
        () async {
      final transfer = _Transfer();
      final c = controller(transfer: transfer, preloadCount: 2);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The item being watched is the first transfer requested.
      expect(transfer.started.first, 900100);
      c.shutdown();
    });

    // Test 6 from the spec: a neighbour can be warmed, and that must never
    // change what the player is on. The old bug looked like the app loading a
    // 152 MB video first; the fix is that preloading cannot reach the player
    // at all, so the only id that may appear here is the one that was tapped.
    test('a prefetched neighbour never becomes the player', () async {
      // 只有已在本地的邻居会被 warm；未下载的邻居连请求都不发（B+）。
      final transfer = _Transfer(localIds: <int>{900100, 900099});
      final c = controller(transfer: transfer, preloadCount: 3);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.activeFileId, 900100);
      expect(c.current?.messageId, 100);
      // 当前项只由 Downloader 请求一次；预取连请求都不发。
      expect(
        transfer.calls.where((call) => call.$2 == DownloadCaller.preload),
        isEmpty,
        reason: '预加载不得发出 TDLib 请求',
      );
      expect(
        transfer.calls.where((call) => call.$1 == 900100).length,
        lessThanOrEqualTo(1),
        reason: '当前项已在本地的情形下不应再有下载请求',
      );
      // 窗口里只有那个已完成的邻居被 warm，其余等用户点开。
      expect(c.prefetchCompleted, 1);
      c.shutdown();
    });

    test('shutdown stops the window from continuing', () async {
      final transfer = _Transfer();
      final c = controller(transfer: transfer, preloadCount: 3);
      await c.load();
      await Future<void>.delayed(Duration.zero);
      final before = transfer.started.length;

      c.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(transfer.started.length, before);
    });
  });
}
