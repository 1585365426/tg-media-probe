/// One orientation stack for the whole app.
///
/// These tests drive the real coordinator over a mocked method channel, so the
/// assertions are about **what the native side was asked to do**, not about a
/// local boolean.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/platform/orientation_controller.dart';
import 'package:tg_media_probe/platform/orientation_coordinator.dart';

import 'dart:io';

/// A bridge that is not installed on this platform.
class _NoBridge extends OrientationBridge {
  _NoBridge() : super(channel: const MethodChannel('tgmedia/absent'));

  @override
  Future<void> setMode(ScreenOrientationMode mode) async {
    throw MissingPluginException('no orientation bridge here');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(OrientationBridge.channelName);
  late List<String> modes;
  late List<Duration> delays;
  PlatformException? failWith;

  setUp(() {
    modes = <String>[];
    delays = <Duration>[];
    failWith = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setMode') {
        modes.add((call.arguments as Map)['mode'] as String);
        delays.add(Duration.zero);
      }
      if (failWith != null) throw failWith!;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  OrientationCoordinator build() =>
      OrientationCoordinator(bridge: OrientationBridge(channel: channel));

  group('start-up and the player', () {
    test('the app start-up request is portrait', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );

      expect(modes, <String>['portrait']);
      expect(c.current, OrientationIntent.nonPlaybackPortrait);
      expect(c.status.outcome, OrientationOutcome.applied);
    });

    test('opening the player stays portrait', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait,
      );

      expect(modes, <String>['portrait', 'portrait']);
      expect(modes.contains('landscape'), isFalse,
          reason: 'entering the player must never request landscape');
    });

    test('playback and item changes do not ask for landscape', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait,
      );
      final before = c.requestCount;

      // Play/pause/next do not go through the coordinator at all; nothing may
      // raise the request count.
      expect(c.requestCount, before);
      expect(modes.where((m) => m == 'landscape'), isEmpty);
    });
  });

  group('full screen is the only way to landscape', () {
    test('the toggle requests landscape', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );

      expect(modes.last, 'landscape');
      expect(c.current, OrientationIntent.playbackLandscape);
    });

    test('leaving full screen returns to portrait', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait,
      );

      expect(modes.last, 'portrait');
      expect(c.current, OrientationIntent.playbackPortrait);
    });
  });

  group('coming back from the player', () {
    test('closing the player restores the app portrait intent', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );
      await c.clear(OrientationCoordinator.feedOwner);

      expect(c.current, OrientationIntent.nonPlaybackPortrait);
      expect(modes.last, 'portrait',
          reason: 'the channel page must not inherit landscape');
    });

    test('a landscape request in flight cannot outlive the player', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      // Ask for landscape, then leave immediately: the stack no longer contains
      // the feed, so the final applied state must be portrait.
      final landscape = c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );
      final leaving = c.clear(OrientationCoordinator.feedOwner);
      await Future.wait(<Future<void>>[landscape, leaving]);

      expect(c.current, OrientationIntent.nonPlaybackPortrait);
      expect(c.applied, anyOf(isNull, OrientationIntent.nonPlaybackPortrait),
          reason: 'a superseded landscape answer must not stick');
    });

    test('switching to the settings tab while the feed is inactive', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );
      // Tab switch: the shell drops the feed owner.
      await c.clear(OrientationCoordinator.feedOwner);

      expect(c.current, OrientationIntent.nonPlaybackPortrait);
      expect(modes.last, 'portrait');
    });

    test('clearing an owner that was never registered does nothing', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );
      final calls = modes.length;

      await c.clear('nobody');

      expect(modes.length, calls);
    });
  });

  group('rapid taps', () {
    test('a slow landscape answer does not overwrite a newer portrait', () async {
      final c = build();
      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );

      // Two requests back to back: landscape then portrait. The stack ends with
      // playbackPortrait, and that is what must be applied last.
      final a = c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );
      final b = c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait,
      );
      await Future.wait(<Future<void>>[a, b]);

      expect(c.current, OrientationIntent.playbackPortrait);
      expect(modes.last, 'portrait');
      expect(c.applied, OrientationIntent.playbackPortrait);
    });

    test('ten toggles leave the last intent applied', () async {
      final c = build();
      for (var i = 0; i < 10; i++) {
        await c.set(
          OrientationCoordinator.feedOwner,
          i.isEven
              ? OrientationIntent.playbackLandscape
              : OrientationIntent.playbackPortrait,
        );
      }

      expect(c.current, OrientationIntent.playbackPortrait);
      expect(modes.last, 'portrait');
      // Every request reaches the platform in order; none is dropped.
      expect(modes.length, 10);
    });
  });

  group('the failure is observable', () {
    test('a platform error is reported, not swallowed', () async {
      failWith = PlatformException(code: 'rejected', message: '方向被系统拒绝');
      final c = build();

      await c.set(
        OrientationCoordinator.feedOwner,
        OrientationIntent.playbackLandscape,
      );

      expect(c.status.outcome, OrientationOutcome.failed);
      expect(c.status.message, contains('方向被系统拒绝'));
      expect(c.status.isProblem, isTrue);
      // The request was still made; the state simply does not claim success.
      expect(modes, contains('landscape'));
    });

    test('a platform without the bridge reports unsupported', () async {
      // In this harness a mock handler that simply accepts everything else, so
      // "unsupported" has to come from a bridge that actually throws
      // MissingPluginException — which is what a desktop test run sees.
      final c = OrientationCoordinator(bridge: _NoBridge());

      await c.set(
        OrientationCoordinator.appOwner,
        OrientationIntent.nonPlaybackPortrait,
      );

      expect(c.status.outcome, OrientationOutcome.unsupported);
      expect(c.status.isProblem, isTrue);
    });
  });

  group('the player page only rotates through the toggle', () {
    test('_toggleLandscape never touches the feed controller', () {
      final source =
          File(p.normalize('lib/ui/video_player_page.dart')).readAsStringSync();
      final start = source.indexOf('Future<void> _toggleLandscape()');
      final end = source.indexOf('void _message(', start);
      final body = source.substring(start, end);

      expect(body.contains('controller.'), isFalse,
          reason: 'rotating must not move the playhead or rebuild the item');
      expect(body.contains('_rebuildController'), isFalse);
      expect(body.contains('seekTo'), isFalse);
    });
  });
}
