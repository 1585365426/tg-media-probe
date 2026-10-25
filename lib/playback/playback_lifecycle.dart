import 'package:flutter/widgets.dart';

import 'player_slot.dart';

/// Releases the player on the events that otherwise leave a decoder (and
/// sometimes audio) running in the background:
///
/// * the app goes to background / inactive;
/// * the system sends a memory warning;
/// * the user switches the top-level tab away from the video tab;
/// * the video page is popped.
class PlaybackLifecycleBinder {
  PlaybackLifecycleBinder({required this.controller, this.onRelease});

  final SinglePlayerController controller;
  final void Function(String reason)? onRelease;

  int _releaseCount = 0;
  String? _lastReason;

  int get releaseCount => _releaseCount;
  String? get lastReason => _lastReason;

  Future<void> handleLifecycle(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) return;
    await _release('lifecycle:${state.name}');
  }

  Future<void> handleMemoryWarning() => _release('memory-warning');

  Future<void> handleTabChanged(int index) => _release('tab:$index');

  Future<void> handlePageDispose() => _release('page-dispose');

  Future<void> _release(String reason) async {
    _releaseCount++;
    _lastReason = reason;
    await controller.releaseAll();
    onRelease?.call(reason);
  }
}

/// Thin bridge into the Flutter binding. Kept separate so the release logic
/// above can be unit-tested without a widget tree.
class PlaybackLifecycleObserver extends StatefulWidget {
  const PlaybackLifecycleObserver({
    super.key,
    required this.binder,
    required this.child,
  });

  final PlaybackLifecycleBinder binder;
  final Widget child;

  @override
  State<PlaybackLifecycleObserver> createState() =>
      _PlaybackLifecycleObserverState();
}

class _PlaybackLifecycleObserverState extends State<PlaybackLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.binder.handlePageDispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.binder.handleLifecycle(state);
  }

  @override
  void didHaveMemoryPressure() {
    widget.binder.handleMemoryWarning();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
