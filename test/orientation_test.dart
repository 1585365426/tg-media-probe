import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/platform/orientation_controller.dart';
import 'package:tg_media_probe/platform/video_rotation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final orientationChannel = MethodChannel(OrientationBridge.channelName);
  final videoChannel = MethodChannel(VideoRotationReader.channelName);
  late List<MethodCall> orientationCalls;

  Object? videoResponse;
  Object? videoResponseError;

  setUp(() {
    orientationCalls = <MethodCall>[];
    videoResponse = null;
    videoResponseError = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(orientationChannel, (call) async {
      orientationCalls.add(call);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(videoChannel, (call) async {
      if (videoResponseError != null) throw videoResponseError!;
      return videoResponse;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(orientationChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(videoChannel, null);
  });

  group('orientation bridge', () {
    test('maps the three modes to their wire values', () async {
      final bridge = OrientationBridge(channel: orientationChannel);
      await bridge.setMode(ScreenOrientationMode.followSystem);
      await bridge.setMode(ScreenOrientationMode.lockedPortrait);
      await bridge.setMode(ScreenOrientationMode.forcedLandscape);

      expect(orientationCalls.map((c) => c.method).toList(),
          ['setMode', 'setMode', 'setMode']);
      expect(orientationCalls.map((c) => (c.arguments as Map)['mode']).toList(),
          ['system', 'portrait', 'landscape']);
      expect(bridge.current, ScreenOrientationMode.forcedLandscape);
    });

    test('page scope returns to portrait on dispose, exactly once', () async {
      final bridge = OrientationBridge(channel: orientationChannel);
      final scope = PageOrientationScope(
        bridge,
        mode: ScreenOrientationMode.forcedLandscape,
      );
      await scope.enter();
      expect(orientationCalls.last.method, 'setMode');
      expect((orientationCalls.last.arguments as Map)['mode'], 'landscape');

      orientationCalls.clear();
      await scope.dispose();
      await scope.dispose();
      await scope.dispose();

      expect(scope.isDisposed, isTrue);
      expect(orientationCalls.where((c) => c.method == 'reset'), hasLength(1));
      // Portrait, not "whatever the phone is doing": the app has no page that
      // wants free rotation, and followSystem here was the stuck-landscape bug.
      expect(bridge.current, ScreenOrientationMode.lockedPortrait);
      expect(
        orientationCalls
            .where((c) => c.method == 'setMode')
            .map((c) => (c.arguments as Map)['mode'])
            .toList(),
        <String>['portrait'],
      );
    });

    test('resetToPortrait applies portrait before telling the system to reset',
        () async {
      final bridge = OrientationBridge(channel: orientationChannel);
      await bridge.setMode(ScreenOrientationMode.forcedLandscape);
      orientationCalls.clear();

      await bridge.resetToPortrait();

      expect(orientationCalls.map((c) => c.method).toList(),
          <String>['setMode', 'reset']);
      expect((orientationCalls.first.arguments as Map)['mode'], 'portrait');
      expect(bridge.current, ScreenOrientationMode.lockedPortrait);
    });

    test('the shell holds portrait while the feed borrows landscape', () async {
      final bridge = OrientationBridge(channel: orientationChannel);
      final shell = PageOrientationScope(bridge,
          mode: ScreenOrientationMode.lockedPortrait);
      final feed = PageOrientationScope(bridge,
          mode: ScreenOrientationMode.forcedLandscape);

      await shell.enter();
      await feed.enter();
      expect(bridge.current, ScreenOrientationMode.forcedLandscape);

      await feed.dispose();
      expect(bridge.current, ScreenOrientationMode.lockedPortrait,
          reason: 'leaving the feed must not leave the app sideways');

      await shell.dispose();
      expect(bridge.current, ScreenOrientationMode.lockedPortrait);
    });

    test('a page that never entered still resets on dispose', () async {
      final bridge = OrientationBridge(channel: orientationChannel);
      final scope = PageOrientationScope(bridge,
          mode: ScreenOrientationMode.lockedPortrait);
      await scope.dispose();
      expect(orientationCalls.where((c) => c.method == 'reset'), hasLength(1));
    });

    test('a platform without the bridge does not throw', () async {
      final bridge = OrientationBridge(channel: const MethodChannel('tgmedia/nope'));
      await bridge.setMode(ScreenOrientationMode.forcedLandscape);
      await bridge.resetToSystem();
      expect(bridge.current, ScreenOrientationMode.followSystem);
    });
  });

  group('video rotation', () {
    const reader = VideoRotationReader();

    test('reads 90 degrees from the native track transform', () async {
      videoResponse = 90;
      expect(await reader.readRotationDegrees('/tmp/a.mp4'), 90);
    });

    test('normalises -90 to 270', () async {
      videoResponse = -90;
      expect(await reader.readRotationDegrees('/tmp/a.mp4'), 270);
    });

    test('returns null for a non-orthogonal transform instead of guessing',
        () async {
      videoResponse = 45;
      expect(await reader.readRotationDegrees('/tmp/a.mp4'), isNull);
    });

    test('returns null when the native side has no answer', () async {
      videoResponse = null;
      expect(await reader.readRotationDegrees('/tmp/a.mp4'), isNull);
    });

    test('returns null when the plugin is missing', () async {
      const missing = VideoRotationReader(channel: MethodChannel('tgmedia/missing'));
      expect(await missing.readRotationDegrees('/tmp/a.mp4'), isNull);
    });

    test('returns null on a platform error', () async {
      videoResponseError = PlatformException(code: 'asset_error');
      expect(await reader.readRotationDegrees('/tmp/a.mp4'), isNull);
    });

    test('an empty path is not sent to the platform', () async {
      expect(await reader.readRotationDegrees(''), isNull);
    });

    test('normalizeDegrees accepts only the four real values', () {
      expect(VideoRotationReader.normalizeDegrees(0), 0);
      expect(VideoRotationReader.normalizeDegrees(90), 90);
      expect(VideoRotationReader.normalizeDegrees(180), 180);
      expect(VideoRotationReader.normalizeDegrees(270), 270);
      expect(VideoRotationReader.normalizeDegrees(-90), 270);
      expect(VideoRotationReader.normalizeDegrees(360), 0);
      expect(VideoRotationReader.normalizeDegrees(450), 90);
      expect(VideoRotationReader.normalizeDegrees(45), isNull);
      expect(VideoRotationReader.normalizeDegrees(null), isNull);
    });

    test('quarter turns swap the display dimensions', () {
      final rotated = VideoRotationReader.displaySize(
        width: 1920,
        height: 1080,
        rotationDegrees: 90,
      );
      expect(rotated.width, 1080);
      expect(rotated.height, 1920);
      expect(rotated.rotationKnown, isTrue);

      final unrotated = VideoRotationReader.displaySize(
        width: 1920,
        height: 1080,
        rotationDegrees: 0,
      );
      expect(unrotated.width, 1920);
      expect(unrotated.rotationKnown, isTrue);

      final unknown = VideoRotationReader.displaySize(
        width: 1920,
        height: 1080,
        rotationDegrees: null,
      );
      expect(unknown.width, 1920);
      expect(unknown.rotationKnown, isFalse);
    });
  });
}
