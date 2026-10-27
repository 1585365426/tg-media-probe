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
  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  @override
  Future<FileState?> stat(int fileId) async {
    final local = localIds.contains(fileId);
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
  Future<void> start(int fileId) async {
    if (failIds.contains(fileId)) {
      throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    }
    started.add(fileId);
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
  Future<void> startRange(int fileId, {required int offset, required int limit}) async {
    if (failIds.contains(fileId)) {
      throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    }
    started.add(fileId);
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

    test('count 2 prefetches exactly the next two items', () async {
      final transfer = _Transfer(localIds: <int>{900100});
      final c = controller(transfer: transfer, preloadCount: 2);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // First two items are 100 (local, no transfer) and 99, 98 as prefetch.
      expect(transfer.started, <int>[900099, 900098]);
      expect(c.prefetchCompleted, 2);
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
      final transfer = _Transfer(localIds: <int>{900100, 900099, 900098, 900097});
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
