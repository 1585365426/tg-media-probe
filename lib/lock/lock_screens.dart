/// Unlock screen, passcode setup, and the recovery entry point.
///
/// Behaviour rules from §8 that this file is responsible for:
/// * a biometric failure never reads as a wrong passcode;
/// * the passcode field is always available — biometrics are an accelerator,
///   never the only door;
/// * the hint is displayed, never compared;
/// * the recovery path is the only escape from a forgotten passcode, and it is
///   honest about what it destroys.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../security/passcode.dart';
import '../ui/app_theme.dart';
import 'unlock_controller.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({
    super.key,
    required this.controller,
    required this.onForgotPasscode,
  });

  final UnlockController controller;
  final Future<void> Function() onForgotPasscode;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final TextEditingController _passcode = TextEditingController();
  Timer? _ticker;
  bool _autoPrompted = false;

  /// The phase the screen last rendered, so a transition **back** into
  /// `requestingBiometric` (re-lock while the screen is already up) re-arms the
  /// sheet instead of leaving a disabled "正在请求…" button behind.
  UnlockPhase? _lastPhase;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.controller.tickCooldown();
      widget.controller.tickBiometricWatchdog();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoPrompt());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _ticker?.cancel();
    _passcode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final phase = widget.controller.phase;
    final rearmed = phase == UnlockPhase.requestingBiometric &&
        _lastPhase != UnlockPhase.requestingBiometric;
    _lastPhase = phase;
    setState(() {});
    if (!rearmed) return;
    if (widget.controller.awaitingBiometric) return;
    if (!widget.controller.canOfferBiometric) return;
    // A fresh lock cycle: one prompt per cycle, never a loop.
    scheduleMicrotask(widget.controller.promptBiometric);
  }

  /// §8.3: with biometrics available, the sheet opens by itself — once. A
  /// cancel must not reopen it, or the user is trapped in a prompt loop.
  void _maybeAutoPrompt() {
    final controller = widget.controller;
    if (_autoPrompted) return;
    if (controller.phase != UnlockPhase.requestingBiometric) return;
    if (!controller.canOfferBiometric) return;
    _autoPrompted = true;
    controller.promptBiometric();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final coolingDown = controller.isCoolingDown;
    final label = controller.capability.label;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.lock_outline, size: 40, color: scheme.primary),
                const SizedBox(height: 16),
                Text('TG Media 已锁定', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  controller.passcodeEnabled
                      ? '输入应用解锁密码继续'
                      : '这个应用设置了锁定',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                if (controller.canOfferBiometric) ...<Widget>[
                  FilledButton.tonalIcon(
                    onPressed: controller.phase == UnlockPhase.requestingBiometric
                        ? null
                        : controller.promptBiometric,
                    icon: const Icon(Icons.face_retouching_natural),
                    label: Text(
                      controller.phase == UnlockPhase.requestingBiometric
                          ? '正在请求 $label…'
                          : '使用 $label 解锁',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (controller.passcodeEnabled) ...<Widget>[
                  TextField(
                    controller: _passcode,
                    obscureText: true,
                    enabled: !coolingDown,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: '应用解锁密码',
                      helperText: controller.settings.hint == null
                          ? null
                          : '提示：${controller.settings.hint}',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: coolingDown ? null : _submit,
                      child: Text(coolingDown ? '请稍候…' : '解锁'),
                    ),
                  ),
                ],
                if (controller.message != null) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    controller.message!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
                if (controller.biometricUnavailableReason != null &&
                    controller.settings.biometricEnabled) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    controller.biometricUnavailableReason!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                TextButton(
                  onPressed: widget.onForgotPasscode,
                  child: const Text('忘记应用密码'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final value = _passcode.text;
    if (value.isEmpty) return;
    final ok = await widget.controller.submitPasscode(value);
    if (!ok && mounted) {
      _passcode.clear();
    }
  }
}

/// Sets or replaces the app passcode.
///
/// Returns true when a new passcode was stored. The caller reloads the lock
/// settings afterwards; this screen never unlocks anything by itself.
class PasscodeSetupScreen extends StatefulWidget {
  const PasscodeSetupScreen({
    super.key,
    required this.store,
    this.title = '设置应用解锁密码',
    this.requireCurrent = false,
  });

  final AppLockStore store;
  final String title;

  /// True when a passcode already exists and must be entered first.
  final bool requireCurrent;

  @override
  State<PasscodeSetupScreen> createState() => _PasscodeSetupScreenState();
}

class _PasscodeSetupScreenState extends State<PasscodeSetupScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _hint = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    _hint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(AppTheme.pagePadding),
        children: <Widget>[
          if (widget.requireCurrent) ...<Widget>[
            TextField(
              controller: _current,
              obscureText: true,
              decoration: const InputDecoration(labelText: '当前应用密码'),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '新密码',
              helperText: '6–128 位，不能全是空格或包含换行',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(labelText: '再次输入新密码'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hint,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: '提示词（可选）',
              helperText: '提示词只用于显示，不能用来解锁',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '正在保存…' : '保存'),
          ),
          const SizedBox(height: 10),
          Text(
            '密码不以明文保存，也不会上传。忘记密码只能通过重新验证 Telegram 账号来重置。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.requireCurrent) {
        final settings = await widget.store.load();
        final ok = await widget.store.verifyPasscode(
          _current.text,
          settings: settings,
        );
        if (!ok) {
          setState(() => _error = '当前密码不正确');
          return;
        }
      }

      final next = _next.text;
      if (next != _confirm.text) {
        setState(() => _error = '两次输入不一致');
        return;
      }
      final rejection = await widget.store.setPasscode(next);
      if (rejection != null) {
        setState(() => _error = rejection.message);
        return;
      }
      if (_hint.text.trim().isNotEmpty) {
        final settings = await widget.store.load();
        await widget.store.save(settings.copyWith(hint: _hint.text.trim()));
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Asks for the current passcode before a destructive lock change.
Future<bool> confirmWithPasscode(
  BuildContext context,
  AppLockStore store,
) async {
  final controller = TextEditingController();
  try {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('验证应用密码'),
            content: TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '应用解锁密码'),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ==
        true &&
        await store.verifyPasscode(controller.text);
  } finally {
    controller.dispose();
  }
}

/// Display-only explanation of the recovery path, with the one action it offers.
Future<bool> confirmRecoveryReset(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('忘记应用密码'),
      content: Text(LockRecoveryPlan.telegramReauth.summary),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('重新验证并重置'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Small helper used by the settings row: which label describes the current
/// lock state, without implying a sensor that may not exist.
String describeLockState(AppLockSettings settings, BiometricCapability capability) {
  if (!settings.lockEnabled) return '未启用';
  if (!settings.passcodeEnabled) return '仅生物识别（异常配置）';
  if (settings.biometricEnabled) {
    return capability.canAuthenticate ? '密码 + ${capability.label}' : '仅密码';
  }
  return '仅密码';
}

/// Human wording for the "no passcode yet" rejection, used by the Face ID row.
const String faceIdNeedsPasscodeText = '请先设置应用解锁密码';
