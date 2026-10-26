/// Unlock state machine: cold start, foreground return, biometric prompt,
/// passcode fallback, cooldown, and the recovery reset.
///
/// This file owns *sequencing*. The policy lives in `security/lock_policy.dart`
/// (what should be demanded) and the sensor lives in `security/biometric.dart`
/// (was it satisfied). Keeping the three apart is what makes the matrix
/// testable without a device: every branch below is driven by an injected
/// capability, clock and gate.
///
/// Invariants the settings page and the unlock screen rely on:
/// * [phase] is never [UnlockPhase.unlocked] unless the requirement was
///   satisfied — a failed scan or a wrong passcode can only ever move it to
///   `needsPasscode`.
/// * A biometric failure message is never phrased as a wrong passcode: the two
///   are different facts and the user must not be told the wrong one.
/// * Starting the controller is safe when no lock is configured: it ends in
///   `unlocked` without touching the sensor, which is what makes "Face ID off
///   by default" observable rather than a claim.
library;

import 'package:flutter/foundation.dart';

import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../security/passcode.dart';

enum UnlockPhase {
  /// Reading the stored lock settings. Nothing is asked yet.
  checking,

  /// The app content may be shown.
  unlocked,

  /// The sensor is being asked, or waiting to be asked.
  requestingBiometric,

  /// Waiting for the app passcode (the biometric button may still be offered).
  needsPasscode,

  /// Too many wrong passcodes: submissions are refused until the delay passes.
  coolingDown,

  /// The user chose "forgot passcode"; a Telegram re-login has to happen first.
  recovering,
}

class UnlockController extends ChangeNotifier {
  UnlockController({
    required this.lockStore,
    required this.gate,
    this.throttle = const PasscodeThrottle(),
    DateTime Function()? clock,
    this.biometricReason = '解锁 TG Media',
    this.onUnlocked,
  }) : _clock = clock ?? DateTime.now;

  final AppLockStore lockStore;
  final BiometricGate gate;
  final PasscodeThrottle throttle;
  final DateTime Function() _clock;
  final String biometricReason;

  /// Called exactly once per successful unlock. The shell uses it to start its
  /// own timers; tests use it to count unlocks.
  final void Function()? onUnlocked;

  AppLockSettings _settings = AppLockSettings.initial;
  UnlockPhase _phase = UnlockPhase.checking;
  BiometricCapability _capability = const BiometricCapability.unavailable();
  String? _message;
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;
  DateTime? _leftForegroundAt;
  bool _backgrounded = false;

  /// Set when the sensor reported something only the user can fix (lockout,
  /// removed enrolment). The biometric button then disappears until the app is
  /// restarted or the settings are reloaded — re-prompting a locked sensor only
  /// burns another failure.
  bool _biometricBlocked = false;

  /// True while a system sheet is up.
  ///
  /// The sheet makes iOS send `inactive`, and answering it sends `resumed`.
  /// Treating that round trip as "the app came back from the background"
  /// re-locked the app in the middle of its own unlock: the phase flipped back
  /// to `requestingBiometric` after a successful scan, which is the "开了 Face ID
  /// 就进不去" report. While the sheet is in flight, resume must not re-evaluate.
  bool _promptInFlight = false;

  /// When the current prompt started, for the watchdog.
  DateTime? _promptStartedAt;

  /// How long a system sheet may stay unanswered before the app stops waiting
  /// and offers the passcode instead. A stuck sheet must not be a dead end.
  static const Duration biometricWatchdog = Duration(seconds: 12);

  AppLockSettings get settings => _settings;
  UnlockPhase get phase => _phase;
  BiometricCapability get capability => _capability;
  String? get message => _message;
  int get failedAttempts => _failedAttempts;

  /// True while the shell must not be shown.
  bool get isLocked => _phase != UnlockPhase.unlocked;

  bool get passcodeEnabled => _settings.passcodeEnabled;

  /// Whether to render the "use Face ID / Touch ID" button.
  bool get canOfferBiometric =>
      _settings.biometricEnabled && _capability.canAuthenticate && !_biometricBlocked;

  /// Why the biometric button is unavailable, or null when it is offered.
  String? get biometricUnavailableReason {
    if (_biometricBlocked) return '生物识别暂不可用，请用应用密码解锁';
    if (!_settings.biometricEnabled) return null;
    return _capability.unavailableReason;
  }

  Duration get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  bool get isCoolingDown =>
      _phase == UnlockPhase.coolingDown && cooldownRemaining > Duration.zero;

  /// Cold start. Decides from the stored settings and a **fresh** capability
  /// probe: the user may have removed their enrolment in Settings while the app
  /// was not running.
  Future<void> start() async {
    _settings = await lockStore.load();
    _capability = await gate.probe();
    _biometricBlocked = false;
    _failedAttempts = 0;
    _cooldownUntil = null;
    _apply(LockEvaluator.decide(
      settings: _settings,
      coldStart: true,
      sinceBackground: null,
      capability: _capability,
    ));
  }

  /// Re-reads the lock settings after the user changed them.
  /// Never unlocks by itself: tightening a setting must not extend access.
  Future<void> reloadSettings() async {
    _settings = await lockStore.load();
    _capability = await gate.probe();
    if (_settings.biometricEnabled && _capability.canAuthenticate) {
      _biometricBlocked = false;
    }
    notifyListeners();
  }

  /// Settings action: enable/disable biometrics.
  ///
  /// Returns false when the request was refused because no passcode exists —
  /// the caller surfaces "先设置应用解锁密码". This is the gate behind the greyed
  /// out switch, enforced here as well so a future call site cannot bypass it.
  Future<bool> setBiometricEnabled(bool enabled) async {
    final next = _settings.withBiometrics(enabled);
    if (enabled && !next.biometricEnabled) return false;
    _settings = next;
    await lockStore.save(next);
    notifyListeners();
    return true;
  }

  /// Asks the sensor. Safe to call when it is not offered: it simply does
  /// nothing, so a double tap cannot produce two system sheets.
  Future<void> promptBiometric() async {
    if (_phase == UnlockPhase.unlocked || _phase == UnlockPhase.checking) return;
    if (_promptInFlight) return;
    if (!canOfferBiometric) return;

    _promptInFlight = true;
    _promptStartedAt = _clock();
    _phase = UnlockPhase.requestingBiometric;
    _message = null;
    notifyListeners();

    try {
      final outcome = await gate.authenticate(reason: biometricReason);
      if (outcome.isSuccess) {
        _failedAttempts = 0;
        _cooldownUntil = null;
        _markUnlocked();
        return;
      }

      // A hard failure hides the sensor; a cancellation keeps it tappable.
      if (outcome.requiresFallback) _biometricBlocked = true;
      _message = outcome.message;
      _apply(LockEvaluator.afterOutcome(outcome, _settings));
    } finally {
      _promptInFlight = false;
      _promptStartedAt = null;
    }
  }

  /// True while the system sheet owns the screen.
  bool get awaitingBiometric => _promptInFlight;

  /// Falls back to the passcode when a sheet never answers.
  ///
  /// Driven by the unlock screen's 1 s ticker. It does not unlock anything: it
  /// only stops the UI from sitting on "正在请求 Face ID…" forever, which is
  /// indistinguishable from a frozen app.
  void tickBiometricWatchdog() {
    if (!_promptInFlight) return;
    final started = _promptStartedAt;
    if (started == null) return;
    if (_clock().difference(started) < biometricWatchdog) return;
    _promptInFlight = false;
    _promptStartedAt = null;
    _biometricBlocked = false;
    _phase = UnlockPhase.needsPasscode;
    _message = '生物识别没有响应，请用应用密码解锁';
    notifyListeners();
  }

  /// Verifies [passcode]. Returns true only when the app became unlocked.
  Future<bool> submitPasscode(String passcode) async {
    if (_phase == UnlockPhase.unlocked) return true;
    final remaining = cooldownRemaining;
    if (remaining > Duration.zero) {
      _phase = UnlockPhase.coolingDown;
      _message = '请等待 ${remaining.inSeconds} 秒后重试';
      notifyListeners();
      return false;
    }
    if (!_settings.passcodeEnabled) {
      // Reachable only with a hand-edited store; there is nothing to verify
      // against, so this is a failure, never a pass.
      _message = '未设置应用解锁密码';
      _phase = UnlockPhase.needsPasscode;
      notifyListeners();
      return false;
    }

    final ok = await lockStore.verifyPasscode(passcode, settings: _settings);
    if (ok) {
      _failedAttempts = 0;
      _cooldownUntil = null;
      _markUnlocked();
      return true;
    }

    _failedAttempts++;
    final delay = throttle.delayFor(_failedAttempts);
    if (delay > Duration.zero) {
      _cooldownUntil = _clock().add(delay);
      _phase = UnlockPhase.coolingDown;
      _message = '密码错误，请等待 ${delay.inSeconds} 秒后重试';
    } else {
      _phase = UnlockPhase.needsPasscode;
      _message = '密码错误';
    }
    notifyListeners();
    return false;
  }

  /// Called from `didChangeAppLifecycleState` when the app leaves the
  /// foreground. The timestamp is what makes "5 分钟后锁定" mean something.
  void onPaused() {
    if (_backgrounded) return;
    _backgrounded = true;
    _leftForegroundAt = _clock();
  }

  /// Called when the app returns. Re-locks when the configured delay elapsed.
  Future<void> onResumed() async {
    if (!_backgrounded) return;
    _backgrounded = false;
    if (_promptInFlight) {
      // The sheet itself caused the inactive->resumed pair; re-evaluating here
      // is what turned a successful scan back into a locked screen.
      return;
    }
    final leftAt = _leftForegroundAt;
    _leftForegroundAt = null;
    if (_phase == UnlockPhase.recovering) return;

    final since = leftAt == null ? null : _clock().difference(leftAt);
    final requirement = LockEvaluator.decide(
      settings: _settings,
      coldStart: false,
      sinceBackground: since ?? Duration.zero,
      capability: _capability,
    );
    if (requirement == LockRequirement.none) return;

    // The sensor may have been removed or locked out while backgrounded.
    _capability = await gate.probe();
    _apply(LockEvaluator.decide(
      settings: _settings,
      coldStart: false,
      sinceBackground: since ?? Duration.zero,
      capability: _capability,
    ));
  }

  /// "锁定" action in the settings page / the shell's quick action.
  void lockNow() {
    if (!_settings.lockEnabled) return;
    _message = null;
    _apply(LockRequirement.passcodeOnly);
  }

  /// Entry point for "忘记应用密码". Nothing is reset yet: §8.6 requires a
  /// Telegram re-authentication first, and that is driven by the caller.
  void beginRecovery() {
    _phase = UnlockPhase.recovering;
    _message = LockRecoveryPlan.telegramReauth.summary;
    notifyListeners();
  }

  /// Called after Telegram confirmed the user. Drops the app lock.
  ///
  /// Deliberately narrow: only the lock record is rewritten. The Telegram side
  /// (session, local database, index) is handled by the caller, because §8.6
  /// requires that a recovery reset clears the local Telegram session too — and
  /// that is not something a lock controller should be able to do on its own.
  Future<void> completeRecovery() async {
    _settings = await lockStore.applyRecoveryReset();
    _capability = await gate.probe();
    _failedAttempts = 0;
    _cooldownUntil = null;
    _biometricBlocked = false;
    _message = '应用锁已重置，请重新设置应用解锁密码';
    _markUnlocked();
  }

  /// Abandons a recovery attempt without changing anything.
  void cancelRecovery() {
    _apply(_settings.passcodeEnabled
        ? LockRequirement.passcodeOnly
        : LockRequirement.none);
  }

  /// Recomputes [cooldownRemaining] and notifies, so a 1 s UI timer can drive
  /// the countdown without the controller owning a timer.
  void tickCooldown() {
    if (_phase != UnlockPhase.coolingDown) return;
    final remaining = cooldownRemaining;
    if (remaining > Duration.zero) {
      _message = '请等待 ${remaining.inSeconds} 秒后重试';
    } else {
      _cooldownUntil = null;
      _phase = UnlockPhase.needsPasscode;
      _message = null;
    }
    notifyListeners();
  }

  void _apply(LockRequirement requirement) {
    switch (requirement) {
      case LockRequirement.none:
        _markUnlocked();
      case LockRequirement.biometricThenPasscode:
        // The message is kept: it explains the scan that just failed. Clearing
        // it here is what made "已取消" disappear before the user could read it.
        _phase = UnlockPhase.requestingBiometric;
        notifyListeners();
      case LockRequirement.passcodeOnly:
        _phase = UnlockPhase.needsPasscode;
        notifyListeners();
    }
  }

  void _markUnlocked() {
    final wasLocked = _phase != UnlockPhase.unlocked;
    _phase = UnlockPhase.unlocked;
    notifyListeners();
    if (wasLocked) onUnlocked?.call();
  }
}
