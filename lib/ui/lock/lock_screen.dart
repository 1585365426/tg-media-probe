import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../security/app_lock.dart';
import '../../security/biometric.dart';

/// Passcode gate shown at cold start when a passcode is configured.
///
/// Behaviour the task book asks for, and where it lives:
/// * wrong passcode → inline error, and the error escalates with the attempt
///   count ([AppLock.delaySecondsFor] adds a growing cooldown after 5 misses);
/// * Face ID is attempted once automatically, then only on tap;
/// * a failed or unavailable biometric scan always lands back on the keypad —
///   there is no state in which Face ID failure leaves the user with nothing to
///   press;
/// * no recovery path exists: the passcode is not stored anywhere, only its
///   PBKDF2 output, so the only way past a forgotten passcode is deleting the
///   app.
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.services,
    required this.onUnlocked,
  });

  final AppServices services;
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _controller = TextEditingController();

  AppLock get _lock => widget.services.appLock;

  bool _busy = false;
  String? _error;
  int _failures = 0;
  int _cooldown = 0;
  Timer? _timer;

  BiometricAvailability _biometric = BiometricAvailability.unsupported;
  bool _biometricEnabled = false;
  String? _biometricHint;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final failures = await _lock.readFailures();
    final enabled = await _lock.isBiometricEnabled();
    final availability = await widget.services.biometrics.availability();
    if (!mounted) return;
    setState(() {
      _failures = failures;
      _biometricEnabled = enabled;
      _biometric = availability;
      _cooldown = AppLock.delaySecondsFor(failures);
    });
    if (_cooldown > 0) _startCountdown(_cooldown);

    // One silent attempt on open, exactly like the system passcode sheet.
    if (enabled && availability.canOfferToggle) {
      await _tryBiometric(auto: true);
    }
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    if (seconds <= 0) return;
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = _cooldown - 1;
      setState(() => _cooldown = next < 0 ? 0 : next);
      if (next <= 0) timer.cancel();
    });
  }

  Future<void> _tryBiometric({bool auto = false}) async {
    if (_busy || _cooldown > 0) return;
    setState(() {
      _busy = true;
      _error = null;
      _biometricHint = null;
    });
    final result = await widget.services.biometrics.authenticate();
    if (!mounted) return;
    switch (result) {
      case BiometricResult.success:
        setState(() => _busy = false);
        widget.onUnlocked();
        return;
      case BiometricResult.failed:
        setState(() {
          _busy = false;
          _biometricHint = '面容 ID 未通过，请改用应用密码';
        });
      case BiometricResult.cancelled:
        setState(() {
          _busy = false;
          _biometricHint = '已取消面容 ID，请改用应用密码';
        });
      case BiometricResult.unavailable:
        setState(() {
          _busy = false;
          _biometric = BiometricAvailability.unsupported;
          _biometricHint = auto ? null : '此设备当前无法使用面容 ID，请改用应用密码';
        });
    }
  }

  Future<void> _submit() async {
    if (_busy || _cooldown > 0) return;
    final passcode = _controller.text;
    if (passcode.isEmpty) {
      setState(() => _error = '请输入应用密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final outcome = await _lock.verify(passcode);
    if (!mounted) return;

    switch (outcome) {
      case UnlockOutcome.success:
        setState(() => _busy = false);
        widget.onUnlocked();
        return;
      case UnlockOutcome.notConfigured:
        setState(() => _busy = false);
        widget.onUnlocked();
        return;
      case UnlockOutcome.wrongPasscode:
        final failures = await _lock.readFailures();
        if (!mounted) return;
        final delay = AppLock.delaySecondsFor(failures);
        setState(() {
          _busy = false;
          _failures = failures;
          _controller.clear();
          _error = delay > 0
              ? '密码不正确（已连续错误 $failures 次），请等待 $delay 秒再试'
              : '密码不正确，还可重试';
        });
        if (delay > 0) _startCountdown(delay);
      case UnlockOutcome.lockedOutTemporarily:
        final failures = await _lock.readFailures();
        if (!mounted) return;
        final delay = AppLock.delaySecondsFor(failures);
        setState(() {
          _busy = false;
          _error = '尝试次数过多，请等待 $delay 秒';
        });
        _startCountdown(delay);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBiometric = _biometricEnabled && _biometric.canOfferToggle;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(Icons.lock_outline, size: 44, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('TG Media 已锁定', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '请输入应用密码解锁。密码仅以哈希形式保存在本机钥匙串，忘记后无法找回。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  obscureText: true,
                  enabled: _cooldown == 0,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '应用密码',
                    border: const OutlineInputBorder(),
                    errorText: _error,
                    helperText: _failures >= AppLock.softLockThreshold
                        ? '连续错误 $_failures 次'
                        : null,
                  ),
                ),
                if (_biometricHint != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _biometricHint!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: (_busy || _cooldown > 0) ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(_cooldown > 0 ? '请等待 $_cooldown 秒' : '解锁'),
                  ),
                ),
                if (showBiometric) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: (_busy || _cooldown > 0) ? null : () => _tryBiometric(),
                    icon: const Icon(Icons.face),
                    label: Text('使用${_biometric.label}解锁'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
