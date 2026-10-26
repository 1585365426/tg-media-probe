import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../app_shell.dart';
import '../lock/lock_screen.dart';

/// Shows [LockScreen] when a passcode is configured, the shell otherwise.
///
/// Verification runs on cold start only. It is deliberately not re-run when the
/// app comes back from background: the task book asks for verification "打开App时",
/// and re-locking on every glance at a notification would make the feed
/// unusable. Recorded as a known trade-off in the step 4 report.
///
/// Moved out of `main.dart` so [SessionGate] can hand off to it without the
/// launch path importing the whole app root.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.services});

  final AppServices services;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  bool? _lockEnabled;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var enabled = false;
    try {
      enabled = await widget.services.appLock.isEnabled();
    } catch (_) {
      // Keychain unreadable: fail closed is wrong here — the user would be
      // locked out of their own app with no way in. The settings screen still
      // shows the state it can read.
      enabled = false;
    }
    if (!mounted) return;
    setState(() => _lockEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _lockEnabled;
    if (enabled == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!enabled) return const AppShell();
    return LockScreen(
      services: widget.services,
      onUnlocked: () => setState(() => _lockEnabled = false),
    );
  }
}
