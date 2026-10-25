import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/playback_lifecycle.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/storage/active_files.dart';

class PlayingTracker {
  int playing = 0;
  int maxPlaying = 0;
  int playCalls = 0;

  void started() {
    playing++;
    playCalls++;
    if (playing > maxPlaying) maxPlaying = playing;
  }

  void stopped() {
    if (playing > 0) playing--;
  }
}

class FakePlayer implements PlayerHandle {
  FakePlayer(
    this.path,
    this.tracker, {
    required this.loadDelay,
    required this.failLoad,
  });

  @override
  final String path;
  final PlayingTracker tracker;
  final Duration loadDelay;
  final bool failLoad;

  bool _playing = false;
  bool _disposed = false;
  bool _loaded = false;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    if (failLoad) throw StateError('cannot decode $path');
    _loaded = true;
  }

  @override
  Future<void> play() async {
    if (!_loaded) throw StateError('play before load: $path');
    if (_disposed) throw StateError('play after dispose: $path');
    if (!_playing) {
      _playing = true;
      tracker.started();
    }
  }

  @override
  Future<void> pause() async {
    if (_playing) {
      _playing = false;
      tracker.stopped();
    }
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    await pause();
    _disposed = true;
  }
}

class FakeFactory implements PlayerFactory {
  FakeFactory(this.tracker, {this.slowPaths = const <String>{}});

  final PlayingTracker tracker;
  final Set<String> slowPaths;

  @override
  PlayerHandle create(String path) => FakePlayer(
        path,
        tracker,
        loadDelay: slowPaths.contains(path)
            ? const Duration(milliseconds: 50)
            : Duration.zero,
        failLoad: path.contains('broken'),
      );
}

void main() {
  late PlayingTracker tracker;
  late ActiveFileRegistry registry;
  late FakeFactory factory;
  late SinglePlayerController controller;

  setUp(() {
    tracker = PlayingTracker();
    registry = ActiveFileRegistry();
    factory = FakeFactory(tracker, slowPaths: {'slow.mp4'});
    controller = SinglePlayerController(factory: factory, activeFiles: registry);
  });

  test('100 switches keep exactly one live player and never overlap', () async {
    for (var i = 0; i < 100; i++) {
      await controller.activate('file$i.mp4');
      expect(controller.liveCount, 1, reason: 'switch $i leaked a player');
      expect(tracker.playing, 1, reason: 'switch $i had overlapping playback');
      expect(registry.activePaths, hasLength(1));
    }
    expect(controller.createdCount, 100);
    expect(controller.disposedCount, 99);
    expect(tracker.maxPlaying, 1);
    expect(controller.active!.path, 'file99.mp4');
  });

  test('a slow load that finishes late is discarded, not installed', () async {
    // Let the first activate() get past its bookkeeping and into handle.load()
    // before the second one starts, so both handles really coexist.
    final slow = controller.activate('slow.mp4');
    await Future<void>.delayed(Duration.zero);
    final fast = controller.activate('fast.mp4');
    await Future.wait([slow, fast]);

    expect(controller.active!.path, 'fast.mp4');
    expect(controller.createdCount, 2);
    expect(controller.disposedCount, 1);
    expect(controller.liveCount, 1);
    expect(tracker.maxPlaying, 1);
  });

  test('release frees the player and the file registration', () async {
    await controller.activate('a.mp4');
    expect(registry.isInUse('a.mp4'), isTrue);

    await controller.release();
    expect(controller.hasActive, isFalse);
    expect(controller.liveCount, 0);
    expect(registry.isInUse('a.mp4'), isFalse);
    expect(tracker.playing, 0);
  });

  test('release is idempotent', () async {
    await controller.activate('a.mp4');
    await controller.release();
    await controller.release();
    await controller.releaseAll();
    expect(controller.disposedCount, 1);
    expect(controller.liveCount, 0);
  });

  test('a decode failure surfaces as PlayerError and leaks nothing', () async {
    await expectLater(
      controller.activate('broken.mp4'),
      throwsA(isA<PlayerError>()),
    );
    expect(controller.hasActive, isFalse);
    expect(controller.liveCount, 0);
    expect(registry.activePaths, isEmpty);
  });

  test('pauseActive stops playback without dropping the player', () async {
    await controller.activate('a.mp4');
    await controller.pauseActive();
    expect(tracker.playing, 0);
    expect(controller.hasActive, isTrue);
    expect(controller.liveCount, 1);
  });

  group('lifecycle binder', () {
    test('backgrounding releases the player', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      await controller.activate('a.mp4');
      await binder.handleLifecycle(AppLifecycleState.paused);
      expect(controller.hasActive, isFalse);
      expect(binder.releaseCount, 1);
      expect(binder.lastReason, 'lifecycle:paused');
    });

    test('resuming does not release', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      await controller.activate('a.mp4');
      await binder.handleLifecycle(AppLifecycleState.resumed);
      expect(controller.hasActive, isTrue);
      expect(binder.releaseCount, 0);
    });

    test('memory warning releases the player', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      await controller.activate('a.mp4');
      await binder.handleMemoryWarning();
      expect(controller.liveCount, 0);
      expect(binder.lastReason, 'memory-warning');
    });

    test('switching tabs releases the player', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      await controller.activate('a.mp4');
      await binder.handleTabChanged(0);
      expect(controller.liveCount, 0);
      expect(binder.lastReason, 'tab:0');
    });
  });
}
