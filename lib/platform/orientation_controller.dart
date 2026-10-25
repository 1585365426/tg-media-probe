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

  /// Called when a page is destroyed. Every page resets to follow-system, so a
  /// page that forced landscape cannot leave the next page stuck sideways.
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
/// `enter()` applies the page's mode; `dispose()` returns the app to
/// follow-system exactly once, no matter how many times it is called.
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
    await bridge.resetToSystem();
  }
}
