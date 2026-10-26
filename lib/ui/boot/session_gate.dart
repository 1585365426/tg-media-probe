import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../app/app_services.dart';
import '../../security/tdlib_key.dart';
import '../../td/session_restore.dart';
import '../login/login_page.dart';
import 'lock_gate.dart';

/// Launch gate: try to bring the saved Telegram session back before showing the
/// shell.
///
/// The app used to open straight into the channel tab with no client, so every
/// cold start looked like "logged out" even though TDLib had the session on
/// disk — the user had to tap 登录 and re-run a flow whose only real effect was
/// `setTdlibParameters` against an already-authorized database.
///
/// This gate runs once per process. Outcomes:
///
/// | result | what the user sees |
/// |---|---|
/// | `restored` | straight to the shell, signed in, no prompt |
/// | `needsInteraction` | shell + the sign-in screen pushed once, already on the right step |
/// | `needsLogin` | shell; the channel tab offers 登录 as before |
/// | `unavailable` | shell too — local index, favourites, settings still work |
///
/// Every non-`restored` path disposes or adopts the client it was given, so the
/// single-client-per-database lock is never left held.
class SessionGate extends StatefulWidget {
  const SessionGate({super.key, required this.services, required this.model});

  final AppServices services;
  final AppModel model;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  bool _ready = false;
  bool _pushLogin = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    RestoreResult result;
    try {
      result = await SessionRestore(
        layout: widget.services.layout,
        secrets: const KeychainSecretStore(),
      ).run();
    } catch (e) {
      // Restore must never be able to brick the launch: any unexpected failure
      // degrades to "not signed in", which the channel tab already handles.
      result = RestoreResult(
        RestoreOutcome.unavailable,
        message: '恢复登录状态失败：$e',
      );
    }

    if (!mounted) {
      await result.session?.dispose();
      return;
    }

    final client = result.client;
    switch (result.outcome) {
      case RestoreOutcome.restored:
        if (client != null) {
          widget.services.attachClient(client);
          widget.model.markSignedIn(true);
        }
        _notice = null;
      case RestoreOutcome.needsInteraction:
        // Live client, unfinished handshake. Hand it over so the sign-in screen
        // continues on the same connection instead of opening a second client
        // against the same database.
        if (client != null) {
          widget.services.adoptSession(
            AdoptedSession(client: client, stage: result.stage),
          );
        }
        _pushLogin = true;
        _notice = result.message.isEmpty ? null : result.message;
      case RestoreOutcome.needsLogin:
        if (client != null) {
          widget.services.adoptSession(
            AdoptedSession(client: client, stage: result.stage),
          );
        }
        _notice = result.message.isEmpty ? null : result.message;
      case RestoreOutcome.unavailable:
        await result.session?.dispose();
        _notice = result.message.isEmpty ? null : result.message;
    }

    if (!mounted) return;
    setState(() => _ready = true);

    if (_pushLogin) {
      // Pushing needs a Navigator, which only exists once this subtree is in
      // the tree — hence the post-frame hop.
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLogin());
    }
    final notice = _notice;
    if (notice != null && !_pushLogin) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showNotice(notice));
    }
  }

  Future<void> _openLogin() async {
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LoginPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    if (widget.services.hasClient) widget.model.markSignedIn(true);
  }

  void _showNotice(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return LockGate(services: widget.services);
    return const _RestoreSplash();
  }
}

const _splashBackground = Color(0xFF0E1621);

class _RestoreSplash extends StatelessWidget {
  const _RestoreSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _splashBackground,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.play_circle_fill, size: 56, color: Color(0xFF2AABEE)),
            const SizedBox(height: 18),
            const Text(
              '正在恢复登录状态',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '正在打开本机已保存的 Telegram 会话…',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2AABEE)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
