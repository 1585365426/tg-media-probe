import 'package:flutter/services.dart';

/// How the screen orientation should behave on the current page.
enum ScreenOrientationMode {
  /// Rotate with the device, subject to the iOS orientation lock.
  followSystem,

  /// Force portrait (list pages, settings).
  lockedPortrait,

  /// Force landscape (full-screen video in landscape mode).
  forcedLandscape,
}

extension ScreenOrientationModeWire on ScreenOrientationMode {
  /// Wire value understood by the native side.
  String get wire => switch (this) {
        ScreenOrientationMode.followSystem => 'system',
        ScreenOrientationMode.lockedPortrait => 'portrait',
        ScreenOrientationMode.forcedLandscape => 'landscape',
      };

  String get label => switch (this) {
        ScreenOrientationMode.followSystem => '跟随系统',
        ScreenOrientationMode.lockedPortrait => '锁定竖屏',
        ScreenOrientationMode.forcedLandscape => '强制横屏',
      };
}

/// Dart side of the native orientation bridge.
///
/// Rotation is driven natively (`supportedInterfaceOrientations` +
/// `requestGeometryUpdate` on iOS 16+, `UIDevice.setValue` on iOS 15) because
/// `SystemChrome.setPreferredOrientations` only declares supported
/// orientations — it does not rotate a page that is already on screen, and it
/// cannot express "locked portrait while the player wants landscape".
class OrientationBridge {
  OrientationBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'tgmedia/orientation';

  final MethodChannel _channel;

  ScreenOrientationMode _current = ScreenOrientationMode.followSystem;
  int _applyCount = 0;

  ScreenOrientationMode get current => _current;
  int get applyCount => _applyCount;

  Future<void> setMode(ScreenOrientationMode mode) async {
    _current = mode;
    _applyCount++;
    try {
      await _channel.invokeMethod<void>('setMode', <String, Object?>{
        'mode': mode.wire,
      });
    } on MissingPluginException {
      // Platform without the bridge (desktop test runs, unsupported OS):
      // the Dart state still reflects the request so callers stay consistent.
    }
  }

  /// Returns the app to its default: **portrait**, not "whatever the phone is
  /// doing".
  ///
  /// `followSystem` was the old reset value and it was the wrong one: the app's
  /// Info.plist allows landscape, so leaving a page put the whole UI at the
  /// mercy of however the device was being held. That is how "视频页自动横屏，
  /// 而且切不回竖屏" happens — nothing was holding portrait.
  Future<void> resetToPortrait() async {
    await setMode(ScreenOrientationMode.lockedPortrait);
    await _invokeReset();
  }

  /// Kept for diagnostics: returns everything to the OS.
  Future<void> resetToSystem() async {
    if (_current == ScreenOrientationMode.followSystem && _applyCount > 0) {
      // Still send the reset: the native side may have been left locked by a
      // page that crashed before its own reset.
      await _invokeReset();
      return;
    }
    await setMode(ScreenOrientationMode.followSystem);
    await _invokeReset();
  }

  Future<void> _invokeReset() async {
    try {
      await _channel.invokeMethod<void>('reset');
    } on MissingPluginException {
      // Nothing to reset on this platform.
    }
  }
}

/// Binds an orientation mode to a page lifetime.
///
/// `enter()` applies the page's mode; `dispose()` returns the app to portrait
/// exactly once, no matter how many times it is called. The app has no page
/// that wants free rotation: landscape only exists while the feed is asked for
/// it explicitly.
class PageOrientationScope {
  PageOrientationScope(this.bridge, {this.mode = ScreenOrientationMode.followSystem});

  final OrientationBridge bridge;
  final ScreenOrientationMode mode;

  bool _entered = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get isEntered => _entered;

  Future<void> enter() async {
    if (_disposed) return;
    _entered = true;
    await bridge.setMode(mode);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await bridge.resetToPortrait();
  }
}
