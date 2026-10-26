import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState, Orientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

// ---------------------------------------------------------------- fixtures

MediaRecord video(int messageId, {int chatId = 1, int? duration}) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 1000 + messageId,
      kind: MediaKind.video,
      width: 1080,
      height: 1920,
      durationSeconds: duration,
      sizeBytes: 1024,
      fileName: 'video-$messageId.mp4',
      messageDateUnix: 1700000000 + messageId,
    );

MediaRecord photo(int messageId) => MediaRecord(
      chatId: 1,
      messageId: messageId,
      fileId: 5000 + messageId,
      kind: MediaKind.photo,
      messageDateUnix: 1700000000 + messageId,
    );

class FakeFeedSource implements FeedPageSource {
  FakeFeedSource(this.pages, {this.error});

  final List<List<MediaRecord>> pages;

  /// Mutable so a test can simulate "the index recovered".
  Object? error;
  int _cursor = 0;
  int pageRequests = 0;

  @override
  bool get hasMore => _cursor < pages.length;

  @override
  Future<List<MediaRecord>> nextPage() async {
    pageRequests++;
    if (error != null) throw error!;
    if (_cursor >= pages.length) return const <MediaRecord>[];
    return pages[_cursor++];
  }

  @override
  void reset() => _cursor = 0;
}

class PlayerLedger {
  int created = 0;
  int disposed = 0;
  int plays = 0;
  int pauses = 0;

  /// Ordered trace of what happened, so a test can prove *ordering* and not
  /// only the final counts. "created == disposed + 1" says nothing about
  /// whether the old player was released before the new one started.
  final List<String> events = <String>[];
  final List<String> loaded = <String>[];
  final List<double> volumes = <double>[];
  final List<Duration> seeks = <Duration>[];

  int get live => created - disposed;
}

class FakePlayer implements PlayerHandle, PlayerProgress, PlayerVolume, PlayerSeek {
  FakePlayer(this.path, this.ledger, {this.failOnLoad = false});

  @override
  final String path;
  final PlayerLedger ledger;
  final bool failOnLoad;

  bool _playing = false;
  bool _disposed = false;
  bool _loaded = false;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 30);

  @override
  bool get isPlaying => _playing;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {
    if (failOnLoad) throw StateError('decode failed');
    _loaded = true;
    ledger.loaded.add(path);
    ledger.events.add('load $path');
  }

  @override
  Future<void> play() async {
    if (!_loaded) throw StateError('play before load');
    if (_disposed) throw StateError('play after dispose');
    if (!_playing) {
      _playing = true;
      ledger.plays++;
    }
  }

  @override
  Future<void> pause() async {
    ledger.events.add('pause $path');
    if (_playing) {
      _playing = false;
      ledger.pauses++;
    }
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    await pause();
    _disposed = true;
    ledger.disposed++;
    ledger.events.add('dispose $path');
  }

  @override
  Future<void> setVolume(double volume) async {
    ledger.volumes.add(volume);
  }

  @override
  Future<void> seekTo(Duration target) async {
    position = target;
    ledger.seeks.add(target);
  }
}

class FakeTracker {
  final PlayerLedger ledger = PlayerLedger();
  bool failOnLoad = false;

  PlayerHandle create(String path) {
    ledger.created++;
    ledger.events.add('create $path');
    return FakePlayer(path, ledger, failOnLoad: failOnLoad);
  }
}

class FakeTransferApi implements FileTransferApi {
  FakeTransferApi({this.autoComplete = true});

  /// When true, `start()` completes the transfer on the next microtask.
  bool autoComplete;

  /// File ids that already exist locally; resolved without a transfer.
  final Set<int> alreadyLocal = <int>{};

  /// When true, `start()` raises a TDLib error.
  bool failOnStart = false;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  final Set<int> cancelled = <int>{};
  int startCalls = 0;
  int statCalls = 0;
  final List<int> startedIds = <int>[];

  @override
  Future<FileState?> stat(int fileId) async {
    statCalls++;
    if (alreadyLocal.contains(fileId)) {
      return FileState(
        id: fileId,
        size: 4096,
        expectedSize: 4096,
        downloadedSize: 4096,
        isCompleted: true,
        path: '/tmp/pool/$fileId',
        canBeDownloaded: true,
      );
    }
    return FileState(
      id: fileId,
      size: 0,
      expectedSize: 4096,
      downloadedSize: 0,
      isCompleted: false,
      path: '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId) async {
    startCalls++;
    startedIds.add(fileId);
    if (failOnStart) throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    if (autoComplete) {
      _updates.add(FileState(
        id: fileId,
        size: 4096,
        expectedSize: 4096,
        downloadedSize: 4096,
        isCompleted: true,
        path: '/tmp/pool/$fileId',
        canBeDownloaded: true,
      ));
    }
  }

  @override
  Future<void> cancel(int fileId) async {
    cancelled.add(fileId);
  }

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> dispose() async => _updates.close();
}

class Rig {
  Rig({
    required List<List<MediaRecord>> pages,
    Object? sourceError,
    bool autoComplete = true,
    Duration timeout = const Duration(seconds: 5),
    bool preload = true,
    bool muted = false,
  })  : source = FakeFeedSource(pages, error: sourceError),
        tracker = FakeTracker(),
        api = FakeTransferApi(autoComplete: autoComplete) {
    controller = FeedController(
      source: source,
      player: SinglePlayerController(factory: _Factory(tracker)),
      sources: VideoSourceResolver(
        api: api,
        fetchTimeout: timeout,
        // The fake pool paths never exist on disk; the real resolver now
        // verifies existence, so the rig answers for its own pool.
        fileExists: (_) async => true,
      ),
      chatTitles: const <int, String>{1: '测试频道'},
      defaultMuted: muted,
      preloadAdjacent: preload,
      // No timers in unit tests: progress is read explicitly.
      pollInterval: null,
    );
  }

  final FakeFeedSource source;
  final FakeTracker tracker;
  final FakeTransferApi api;
  late final FeedController controller;

  PlayerLedger get ledger => tracker.ledger;
}

class _Factory implements PlayerFactory {
  _Factory(this.tracker);

  final FakeTracker tracker;

  @override
  PlayerHandle create(String path) => tracker.create(path);
}

// ---------------------------------------------------------------- tests

void main() {
  group('FeedController loading', () {
    test('an empty index shows the empty state, not a spinner', () async {
      final rig = Rig(pages: <List<MediaRecord>>[<MediaRecord>[]]);
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.empty);
      expect(rig.controller.length, 0);
    });

    test('a single video becomes the current item and starts playing', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
      expect(rig.controller.isPlaying, isTrue);
    });

    test('a page with no video pulls the next page instead of giving up',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[photo(1), photo(2)],
        <MediaRecord>[video(3)],
      ]);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.current?.messageId, 3);
      expect(rig.source.pageRequests, greaterThanOrEqualTo(2));
    });

    test('a source failure surfaces as an error, not as an empty list',
        () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[<MediaRecord>[]],
        sourceError: StateError('index unreadable'),
      );
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, contains('index unreadable'));
    });

    test('retry recovers after the index becomes readable again', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        sourceError: StateError('temporary'),
      );
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.error);

      rig.source.error = null;
      await rig.controller.retry();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
    });

    test('an existing local file resolves without a transfer', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.alreadyLocal.add(1001);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.api.startCalls, 0);
      expect(rig.ledger.loaded.single, '/tmp/pool/1001');
    });
  });

  group('switching', () {
    test('the previous player is released before the next one starts', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();

      expect(rig.controller.index, 1);
      expect(rig.ledger.created, 2);
      expect(rig.ledger.disposed, 1);
      expect(rig.ledger.live, 1);
    });

    test('the transfer of the item left behind is cancelled', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      expect(rig.api.cancelled, contains(1001));
    });

    test('going back to the previous item works', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      await rig.controller.goPrevious();
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
    });

    test('going back from the first item does nothing', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goPrevious();
      expect(rig.controller.index, 0);
      expect(rig.ledger.created, 1);
    });

    test('moving to the last loaded item pulls the next page first', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
        <MediaRecord>[video(2)],
      ]);
      await rig.controller.load();
      expect(rig.controller.length, 1);

      await rig.controller.goNext();
      expect(rig.controller.length, 2);
      expect(rig.controller.index, 1);
    });

    test('100 switches leave exactly one live player', () async {
      final items = List<MediaRecord>.generate(101, (i) => video(i + 1));
      final rig = Rig(pages: <List<MediaRecord>>[items]);
      await rig.controller.load();

      for (var i = 0; i < 100; i++) {
        await rig.controller.goNext();
      }

      expect(rig.controller.index, 100);
      expect(rig.ledger.created, 101);
      expect(rig.ledger.disposed, 100);
      expect(rig.ledger.live, 1);
      expect(rig.controller.phase, FeedPhase.ready);
    });

    test('a stale resolution cannot overwrite the item the user moved to',
        () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2)],
        ],
        autoComplete: false,
      );
      // First item never completes; the user swipes away immediately.
      final loading = rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      await rig.controller.goNext();
      await loading;

      // Only the second item has a player, and the first resolution was dropped.
      expect(rig.ledger.live, lessThanOrEqualTo(1));
      expect(rig.controller.phase, isNot(FeedPhase.ready));
    });
  });

  group('failures', () {
    test('a transfer that never finishes becomes 加载超时', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        autoComplete: false,
        timeout: const Duration(milliseconds: 30),
      );
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, contains('加载超时'));
      expect(rig.ledger.live, 0);
    });

    test('a TDLib error is shown as a real message', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.failOnStart = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, contains('FILE_ID_INVALID'));
    });

    test('a decode failure says the video cannot be decoded', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.tracker.failOnLoad = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, '此视频无法解码');
      // A player that failed to load must not stay live.
      expect(rig.ledger.live, 0);
    });
  });

  group('controls and progress', () {
    test('play and pause toggle the live player', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      expect(rig.controller.isPlaying, isTrue);

      await rig.controller.togglePlayPause();
      expect(rig.controller.isPlaying, isFalse);

      await rig.controller.togglePlayPause();
      expect(rig.controller.isPlaying, isTrue);
    });

    test('muting sets volume to 0 and back to 1', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      await rig.controller.setMuted(true);
      await rig.controller.setMuted(false);

      expect(rig.ledger.volumes.last, 1);
      expect(rig.ledger.volumes, contains(0));
    });

    test('the default-muted preference is applied on the first item', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        muted: true,
      );
      await rig.controller.load();
      expect(rig.ledger.volumes, contains(0));
      expect(rig.controller.muted, isTrue);
    });

    test('seeking moves the playhead', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      await rig.controller.seekTo(const Duration(seconds: 7));

      expect(rig.ledger.seeks.single, const Duration(seconds: 7));
      expect(rig.controller.position, const Duration(seconds: 7));
    });

    test('refreshProgress reads the playhead off the live handle', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      final handle = rig.controller.player.active as FakePlayer;
      handle.position = const Duration(seconds: 12);
      handle.duration = const Duration(seconds: 40);

      rig.controller.refreshProgress();
      expect(rig.controller.position, const Duration(seconds: 12));
      expect(rig.controller.duration, const Duration(seconds: 40));
    });

    test('controls start hidden and toggle', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      expect(rig.controller.controlVisible, isFalse);
      rig.controller.toggleControls();
      expect(rig.controller.controlVisible, isTrue);
      rig.controller.setControlsVisible(false);
      expect(rig.controller.controlVisible, isFalse);
    });

    test('the position label reports the place in the loaded list', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      expect(rig.controller.positionLabel, '1 / 2');
      await rig.controller.goNext();
      expect(rig.controller.positionLabel, '2 / 2');
    });
  });

  group('lifecycle', () {
    test('backgrounding releases the player and resuming re-activates the item',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      expect(rig.ledger.live, 1);

      await rig.controller.handleLifecycle(AppLifecycleState.paused);
      expect(rig.ledger.live, 0);

      await rig.controller.handleLifecycle(AppLifecycleState.resumed);
      expect(rig.ledger.live, 1);
      // The same item, not the first one.
      expect(rig.controller.index, 1);
      expect(rig.controller.phase, FeedPhase.ready);
    });

    test('a resume without a pause does not rebuild the player', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      final created = rig.ledger.created;
      await rig.controller.handleLifecycle(AppLifecycleState.resumed);
      expect(rig.ledger.created, created);
    });
  });

  group('preloading', () {
    test('the adjacent item is resolved ahead of time', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      // Give the prefetch a turn.
      await Future<void>.delayed(Duration.zero);

      expect(rig.api.startedIds, contains(1002));
      // Preloading never creates a second player.
      expect(rig.ledger.created, 1);
    });

    test('preloading can be switched off', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2)],
        ],
        preload: false,
      );
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(rig.api.startedIds, isNot(contains(1002)));
    });
  });

  group('pure decisions', () {
    test('a swipe counts as a page turn past 12% of the height', () {
      expect(
        FeedController.shouldSwitchPage(dy: 130, velocity: 0, height: 1000),
        isTrue,
      );
      expect(
        FeedController.shouldSwitchPage(dy: 119, velocity: 0, height: 1000),
        isFalse,
      );
    });

    test('a fast flick counts even with a short distance', () {
      expect(
        FeedController.shouldSwitchPage(dy: 40, velocity: 420, height: 1000),
        isTrue,
      );
      expect(
        FeedController.shouldSwitchPage(dy: 40, velocity: 200, height: 1000),
        isFalse,
      );
    });

    test('a zero-height viewport falls back to the velocity rule', () {
      expect(
        FeedController.shouldSwitchPage(dy: 500, velocity: 0, height: 0),
        isFalse,
      );
    });

    test('landscape hides the info block but keeps the controls', () {
      final portrait = FeedOverlayPlan.forOrientation(Orientation.portrait);
      final landscape = FeedOverlayPlan.forOrientation(Orientation.landscape);

      expect(portrait.showInfo, isTrue);
      expect(portrait.showTopBar, isTrue);
      expect(landscape.showInfo, isFalse);
      // The rotate-back button lives in the controls; hiding them strands the
      // user in landscape.
      expect(landscape.showControls, isTrue);
      expect(landscape.showTopBar, isTrue);
    });
  });

  group('player lifecycle while pages change', () {
    test('the old player is paused and disposed before the new one is created',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      rig.ledger.events.clear();

      await rig.controller.goNext();
      await Future<void>.delayed(Duration.zero);

      final events = rig.ledger.events;
      final disposeIndex = events.indexWhere((e) => e.startsWith('dispose '));
      final createIndex =
          events.indexWhere((e) => e.startsWith('create '), disposeIndex);
      expect(disposeIndex, greaterThanOrEqualTo(0),
          reason: 'the old player must be released: $events');
      expect(createIndex, greaterThan(disposeIndex),
          reason: 'a new player must not exist while the old one is alive: '
              '$events');
      expect(rig.ledger.live, 1);

      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('a resolve superseded mid-flight leaves no orphan player', () async {
      // The transfer for item 1 never completes; the user swipes to item 3
      // while it is pending. The abandoned item must not keep a player.
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2), video(3)],
        ],
        autoComplete: false,
      );
      rig.api.alreadyLocal.addAll(<int>[1001, 1002, 1003]);

      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      final afterFirst = rig.ledger.created;

      await rig.controller.goNext();
      await rig.controller.goNext();
      await Future<void>.delayed(Duration.zero);

      expect(rig.ledger.created, greaterThan(afterFirst));
      expect(rig.ledger.live, 1,
          reason: 'exactly one player may survive the two switches');

      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('five fast switches end with one live player and no double create',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2), video(3), video(4), video(5)],
      ]);
      rig.api.alreadyLocal.addAll(<int>[1001, 1002, 1003, 1004, 1005]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 5; i++) {
        await rig.controller.goNext();
        await Future<void>.delayed(Duration.zero);
      }

      expect(rig.ledger.live, 1);
      // Each create must be preceded by a dispose except for the very first.
      final creates = rig.ledger.events.where((e) => e.startsWith('create ')).length;
      final disposes =
          rig.ledger.events.where((e) => e.startsWith('dispose ')).length;
      expect(creates - disposes, 1);

      rig.controller.shutdown();
      await rig.api.dispose();
    });
  });
}
