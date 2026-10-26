import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/playback_lifecycle.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/util/latest_only.dart';

/// Player double that records the two things a leak would show up as: how many
/// instances are alive at once, and how many are still marked as playing.
class StressPlayer implements PlayerHandle {
  StressPlayer(this.path, this.ledger, {required this.delay, required this.fails});

  @override
  final String path;
  final StressLedger ledger;
  final Duration delay;
  final bool fails;

  bool _playing = false;
  bool _disposed = false;
  bool _loaded = false;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fails) throw StateError('decode failed: $path');
    _loaded = true;
  }

  @override
  Future<void> play() async {
    if (!_loaded) throw StateError('play before load: $path');
    if (_disposed) throw StateError('play after dispose: $path');
    if (!_playing) {
      _playing = true;
      ledger.onPlay();
    }
  }

  @override
  Future<void> pause() async {
    if (_playing) {
      _playing = false;
      ledger.onPause();
    }
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    await pause();
    _disposed = true;
    ledger.onDispose();
  }
}

class StressLedger {
  int created = 0;
  int disposed = 0;
  int playing = 0;
  int maxPlaying = 0;
  int errors = 0;

  void onCreate() => created++;
  void onDispose() => disposed++;

  void onPlay() {
    playing++;
    if (playing > maxPlaying) maxPlaying = playing;
  }

  void onPause() {
    if (playing > 0) playing--;
  }

  int get live => created - disposed;
}

class StressFactory implements PlayerFactory {
  StressFactory(this.ledger);

  final StressLedger ledger;

  @override
  PlayerHandle create(String path) {
    ledger.onCreate();
    return StressPlayer(
      path,
      ledger,
      // Every seventh path is slow, every eleventh fails to decode. Both
      // patterns are deterministic so a failure is reproducible.
      delay: path.contains('slow') ? const Duration(milliseconds: 8) : Duration.zero,
      fails: path.contains('broken'),
    );
  }
}

void main() {
  late StressLedger ledger;
  late ActiveFileRegistry registry;
  late SinglePlayerController controller;

  setUp(() {
    ledger = StressLedger();
    registry = ActiveFileRegistry();
    controller = SinglePlayerController(
      factory: StressFactory(ledger),
      activeFiles: registry,
    );
  });

  group('sequential switching', () {
    test('100 switches leak nothing and never overlap', () async {
      for (var i = 0; i < 100; i++) {
        await controller.activate('clip$i.mp4');
        expect(controller.liveCount, 1, reason: 'switch $i leaked a player');
        expect(ledger.live, 1, reason: 'switch $i left $ledger.live alive');
        expect(ledger.playing, 1, reason: 'switch $i had overlap');
        expect(registry.activePaths, hasLength(1));
      }
      expect(ledger.maxPlaying, 1);
      expect(ledger.created, 100);
      expect(ledger.disposed, 99);
      expect(controller.activePath, 'clip99.mp4');
    });

    test('1000 switches still hold one player', () async {
      // The feed is a swipe loop; 100 is the requirement, 1000 is the cheap
      // check that nothing accumulates per switch (a listener, a registry entry,
      // a completer).
      for (var i = 0; i < 1000; i++) {
        await controller.activate('clip$i.mp4');
      }
      expect(ledger.live, 1);
      expect(registry.activePaths, hasLength(1));
      expect(ledger.maxPlaying, 1);
      expect(ledger.created, 1000);
      expect(ledger.disposed, 999);
    });

    test('a release between switches keeps the ledger consistent', () async {
      for (var i = 0; i < 50; i++) {
        await controller.activate('clip$i.mp4');
        if (i % 10 == 9) {
          await controller.release();
          expect(controller.liveCount, 0);
          expect(registry.activePaths, isEmpty);
        }
      }
      await controller.release();
      expect(ledger.live, 0);
      expect(ledger.playing, 0);
    });
  });

  group('rapid switching without awaiting', () {
    test('firing 100 activates at once ends with exactly one survivor', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 100; i++) {
        futures.add(controller.activate('clip$i.mp4'));
      }
      await Future.wait(futures);

      // Every intermediate handle must be disposed; only the last path may be
      // active. A generation check that is missing shows up here as live > 1.
      expect(ledger.live, 1);
      expect(controller.activePath, 'clip99.mp4');
      expect(ledger.maxPlaying, lessThanOrEqualTo(1));
      expect(registry.activePaths, hasLength(1));
    });

    test('a slow load overtaken by a fast one is disposed, not installed',
        () async {
      final slow = controller.activate('slow.mp4');
      await Future<void>.delayed(Duration.zero);
      final fast = controller.activate('fast.mp4');
      await Future.wait([slow, fast]);

      expect(controller.activePath, 'fast.mp4');
      expect(ledger.live, 1);
      expect(ledger.maxPlaying, 1);
    });

    test('interleaved activations and releases settle at zero', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 40; i++) {
        futures.add(controller.activate('clip$i.mp4'));
        if (i % 5 == 4) futures.add(controller.release());
      }
      await Future.wait(futures);
      await controller.release();

      expect(ledger.live, 0);
      expect(ledger.playing, 0);
      expect(registry.activePaths, isEmpty);
    });
  });

  group('failure paths', () {
    test('a decode failure is reported and leaks nothing', () async {
      await expectLater(
        controller.activate('broken.mp4'),
        throwsA(isA<PlayerError>()),
      );
      expect(ledger.live, 0);
      expect(registry.activePaths, isEmpty);
    });

    test('failures inside a 100-switch run do not accumulate', () async {
      var failures = 0;
      for (var i = 0; i < 100; i++) {
        final path = i % 7 == 3 ? 'broken$i.mp4' : 'clip$i.mp4';
        try {
          await controller.activate(path);
        } on PlayerError {
          failures++;
        }
      }
      expect(failures, greaterThan(0));
      // At most one live player at the end, whether it is the last attempt or
      // the last successful one.
      expect(ledger.live, lessThanOrEqualTo(1));
      expect(ledger.playing, lessThanOrEqualTo(1));
      expect(registry.activePaths.length, lessThanOrEqualTo(1));
    });

    test('switching from a failed state still works', () async {
      await expectLater(
        controller.activate('broken.mp4'),
        throwsA(isA<PlayerError>()),
      );
      await controller.activate('clip.mp4');
      expect(controller.activePath, 'clip.mp4');
      expect(ledger.live, 1);
    });
  });

  group('lifecycle during switching', () {
    test('backgrounding mid-switch releases the player', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      await controller.activate('clip0.mp4');
      final pending = controller.activate('clip1.mp4');
      await binder.handleLifecycle(AppLifecycleState.paused);
      await pending;

      // Whatever won the race, nothing may be left playing in the background:
      // iOS suspends the process and the decoder is reclaimed under us.
      expect(ledger.playing, 0);
      expect(binder.releaseCount, 1);
    });

    test('a memory warning during a 100-switch run settles at zero', () async {
      final binder = PlaybackLifecycleBinder(controller: controller);
      for (var i = 0; i < 100; i++) {
        await controller.activate('clip$i.mp4');
        if (i % 25 == 0) await binder.handleMemoryWarning();
      }
      await controller.release();
      expect(ledger.live, 0);
      expect(ledger.playing, 0);
      expect(registry.activePaths, isEmpty);
    });
  });

  group('LatestOnly', () {
    test('only the newest token is accepted', () {
      final gate = LatestOnly();
      final first = gate.issue();
      final second = gate.issue();
      expect(gate.accepts(first), isFalse);
      expect(gate.accepts(second), isTrue);
    });

    test('invalidate stales everything without issuing', () {
      final gate = LatestOnly();
      final token = gate.issue();
      gate.invalidate();
      expect(gate.accepts(token), isFalse);
    });

    test('a slow old task cannot overwrite a newer result', () async {
      final slot = LatestOnlySlot<String>();
      final results = <String>[];

      final slow = slot.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'old';
      });
      final fast = slot.run(() async => 'new');

      final fastValue = await fast;
      final slowValue = await slow;
      if (fastValue != null) results.add(fastValue);
      if (slowValue != null) results.add(slowValue);

      expect(results, <String>['new']);
    });

    test('a task that completes after cancelAll returns null', () async {
      final slot = LatestOnlySlot<int>();
      final pending = slot.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 1;
      });
      slot.cancelAll();
      expect(await pending, isNull);
    });

    test('an error from the newest task still propagates', () async {
      final slot = LatestOnlySlot<int>();
      await expectLater(
        slot.run(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
    });

    test('an error from an obsolete task is swallowed', () async {
      final slot = LatestOnlySlot<int>();
      final doomed = slot.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw StateError('late failure');
      });
      slot.run(() async => 2);
      expect(await doomed, isNull);
    });
  });

  group('InFlightRegistry', () {
    test('the same key runs once', () async {
      final registry = InFlightRegistry();
      var calls = 0;
      Future<void> load() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final a = registry.fetch('thumb-1', load);
      final b = registry.fetch('thumb-1', load);
      expect(identical(a, b), isTrue);
      await Future.wait([a, b]);
      expect(calls, 1);
      expect(registry.contains('thumb-1'), isFalse);
    });

    test('different keys run independently', () async {
      final registry = InFlightRegistry();
      var calls = 0;
      Future<void> load() async {
        calls++;
      }

      await Future.wait([
        registry.fetch('a', load),
        registry.fetch('b', load),
      ]);
      expect(calls, 2);
    });

    test('a failed load is forgotten so it can be retried', () async {
      final registry = InFlightRegistry();
      await expectLater(
        registry.fetch('a', () async => throw StateError('nope')),
        throwsA(isA<StateError>()),
      );
      expect(registry.contains('a'), isFalse);
      await registry.fetch('a', () async {});
      expect(registry.length, 0);
    });

    test('the cache is bounded', () async {
      final registry = InFlightRegistry(maxEntries: 4);
      final hang = Completer<void>();
      for (var i = 0; i < 10; i++) {
        unawaited(registry.fetch('k$i', () => hang.future));
      }
      expect(registry.length, lessThanOrEqualTo(4));
      hang.complete();
    });
  });
}
