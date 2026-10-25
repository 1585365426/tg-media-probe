import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../security/app_lock.dart';

enum PasscodeMode { create, change, disable }

/// Set / change / turn off the app passcode.
///
/// Every mode that touches an existing lock verifies the current passcode
/// first — [AppLock.changePasscode] and [AppLock.disable] both refuse without
/// it, and this page simply surfaces that refusal. There is no recovery flow:
/// the hash is one-way and the Keychain item is not synced anywhere.
class PasscodeSetupPage extends StatefulWidget {
  const PasscodeSetupPage({
    super.key,
    required this.services,
    required this.mode,
  });

  final AppServices services;
  final PasscodeMode mode;

  @override
  State<PasscodeSetupPage> createState() => _PasscodeSetupPageState();
}

class _PasscodeSetupPageState extends State<PasscodeSetupPage> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
        PasscodeMode.create => '设置应用密码',
        PasscodeMode.change => '修改应用密码',
        PasscodeMode.disable => '关闭应用密码',
      };

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final lock = widget.services.appLock;
    try {
      switch (widget.mode) {
        case PasscodeMode.create:
          final policyError = PasscodePolicy.validate(_next.text);
          if (policyError != null) {
            setState(() => _error = policyError);
            return;
          }
          if (_next.text != _confirm.text) {
            setState(() => _error = '两次输入的密码不一致');
            return;
          }
          await lock.setPasscode(_next.text);
          if (!mounted) return;
          Navigator.of(context).pop(true);
        case PasscodeMode.change:
          if (_next.text != _confirm.text) {
            setState(() => _error = '两次输入的新密码不一致');
            return;
          }
          final policyError = PasscodePolicy.validate(_next.text);
          if (policyError != null) {
            setState(() => _error = policyError);
            return;
          }
          final ok = await lock.changePasscode(
            current: _current.text,
            next: _next.text,
          );
          if (!mounted) return;
          if (!ok) {
            setState(() => _error = '当前密码不正确');
            return;
          }
          Navigator.of(context).pop(true);
        case PasscodeMode.disable:
          final ok = await lock.disable(_current.text);
          if (!mounted) return;
          if (!ok) {
            setState(() => _error = '当前密码不正确，无法关闭');
            return;
          }
          Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsCurrent = widget.mode != PasscodeMode.create;
    final needsNew = widget.mode != PasscodeMode.disable;

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (needsCurrent) ...<Widget>[
            TextField(
              controller: _current,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '当前应用密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (needsNew) ...<Widget>[
            TextField(
              controller: _next,
              obscureText: true,
              autofocus: !needsCurrent,
              decoration: InputDecoration(
                labelText: '新应用密码',
                border: const OutlineInputBorder(),
                helperText: '至少 ${PasscodePolicy.minLength} 位',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '再次输入新密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(_busy ? '处理中…' : '确认'),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '密码只以 PBKDF2-HMAC-SHA256（${PasscodeHash.defaultIterations} 轮 + 随机盐）的哈希形式保存在本机钥匙串，'
              '应用无法还原出原始密码。忘记密码后没有云端找回途径，只能卸载应用清除本地数据。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
