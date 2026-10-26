/// One place that decides what orientation the app is allowed to be in.
///
/// The bug this replaces: every page owned its own orientation future. The feed
/// entered portrait, the toggle asked for landscape, and on the way out the page
/// scope called `reset` — which tells the native side "allow every orientation"
/// and, on iOS 15, picks a *landscape* target when the screen is already
/// sideways. Popping back to the channel list therefore left the channel list in
/// landscape, and nothing in the app was asserting portrait any more.
///
/// Model: a stack of owners, each with an intent. The top of the stack wins.
/// * the app registers `nonPlaybackPortrait` once at start-up;
/// * the feed registers `playbackPortrait` while it is open;
/// * the full-screen button is the only thing that registers
///   `playbackLandscape`.
///
/// Removing the feed from the stack restores portrait **by construction**, so a
/// page that is disposed mid-flight cannot strand the app sideways.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'orientation_controller.dart';

/// What a page is allowed to do with the screen.
enum OrientationIntent {
  /// Channel list, channel detail, settings, login, unlock: portrait, always.
  nonPlaybackPortrait,

  /// The player, before the user asks for full screen.
  playbackPortrait,

  /// The player after an explicit full-screen tap.
  playbackLandscape,
}

/// Result of the last native request, for the UI to report honestly.
enum OrientationOutcome { idle, applied, failed, unsupported }

class OrientationStatus {
  const OrientationStatus(this.outcome, [this.message]);

  final OrientationOutcome outcome;
  final String? message;

  bool get isProblem =>
      outcome == OrientationOutcome.failed ||
      outcome == OrientationOutcome.unsupported;
}

class OrientationCoordinator {
  OrientationCoordinator({OrientationBridge? bridge})
      : _bridge = bridge ?? OrientationBridge();

  /// The app-wide instance. One stack for the whole process is the point: two
  /// coordinators would be two opinions again.
  static final OrientationCoordinator instance = OrientationCoordinator();

  static const String appOwner = 'app';
  static const String feedOwner = 'feed';

  final OrientationBridge _bridge;

  /// Insertion-ordered stack: owner -> intent. Re-setting an owner moves it to
  /// the top, which is what "this page is active now" means.
  final Map<String, OrientationIntent> _stack = <String, OrientationIntent>{};

  OrientationStatus _status = const OrientationStatus(OrientationOutcome.idle);
  OrientationIntent? _applied;
  int _requestSeq = 0;
  Future<void> _tail = Future<void>.value();
  int _requestCount = 0;

  OrientationStatus get status => _status;
  OrientationIntent? get current => _stack.isEmpty ? null : _stack.values.last;
  OrientationIntent? get applied => _applied;
  int get requestCount => _requestCount;

  /// Registers (or updates) an owner's intent and applies the new top.
  Future<void> set(String owner, OrientationIntent intent) {
    _stack.remove(owner);
    _stack[owner] = intent;
    return _apply();
  }

  /// Removes an owner. The previous owner's intent takes over immediately.
  Future<void> clear(String owner) {
    if (_stack.remove(owner) == null) return _tail;
    return _apply();
  }

  /// Applies the top of the stack. Serialised: at most one native call is in
  /// flight, and a late answer for a superseded request cannot overwrite the
  /// state a newer request established.
  Future<void> _apply() {
    final intent = current;
    if (intent == null) return _tail;
    final seq = ++_requestSeq;
    _tail = _tail.then((_) async {
      if (seq != _requestSeq) return; // superseded before it started
      _requestCount++;
      try {
        await _bridge.setMode(_modeFor(intent));
        if (seq != _requestSeq) return; // superseded while awaiting
        _applied = intent;
        _status = const OrientationStatus(OrientationOutcome.applied);
      } on MissingPluginException {
        if (seq != _requestSeq) return;
        _status = const OrientationStatus(
          OrientationOutcome.unsupported,
          '当前平台没有方向桥接，方向未设置',
        );
      } on PlatformException catch (e) {
        if (seq != _requestSeq) return;
        _status = OrientationStatus(
          OrientationOutcome.failed,
          e.message ?? '方向请求被系统拒绝',
        );
      }
    });
    return _tail;
  }

  static ScreenOrientationMode _modeFor(OrientationIntent intent) =>
      switch (intent) {
        OrientationIntent.nonPlaybackPortrait =>
          ScreenOrientationMode.lockedPortrait,
        OrientationIntent.playbackPortrait => ScreenOrientationMode.lockedPortrait,
        OrientationIntent.playbackLandscape =>
          ScreenOrientationMode.forcedLandscape,
      };

  /// Test seam: forget everything without touching the platform.
  void resetForTest() {
    _stack.clear();
    _applied = null;
    _status = const OrientationStatus(OrientationOutcome.idle);
    _requestSeq = 0;
    _requestCount = 0;
    _tail = Future<void>.value();
  }
}
