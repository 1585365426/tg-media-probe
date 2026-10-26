import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/lock/unlock_controller.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/lock_policy.dart';
import 'package:tg_media_probe/security/passcode.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';

/// Everything a test needs, built over an in-memory keychain with the PBKDF2
/// cost lowered so a few hundred verifications still run in well under a second.
class Rig {
  Rig._({
    required this.controller,
    required this.store,
    required this.gate,
    required this.secrets,
    required this.clock,
  });

  final UnlockController controller;
  final AppLockStore store;
  final ScriptedBiometricGate gate;
  final MemorySecretStore secrets;
  final FakeClock clock;

  /// Number of locked -> unlocked transitions observed.
  int get unlockCount => _unlockCount;
  int _unlockCount = 0;

  void _watch() {
    var wasLocked = controller.isLocked;
    controller.addListener(() {
      final lockedNow = controller.isLocked;
      if (wasLocked && !lockedNow) _unlockCount++;
      wasLocked = lockedNow;
    });
  }
}

class FakeClock {
  DateTime value = DateTime.utc(2026, 10, 26, 12);

  DateTime now() => value;

  void advance(Duration by) => value = value.add(by);
}

Future<Rig> rigFor({
  AppLockSettings initial = AppLockSettings.initial,
  BiometricCapability capability = const BiometricCapability(
    kind: BiometricKind.face,
    available: true,
    enrolled: true,
    lockedOut: false,
  ),
  List<BiometricOutcome> outcomes = const <BiometricOutcome>[
    BiometricOutcome.success,
  ],
}) async {
  final secrets = MemorySecretStore();
  final store = AppLockStore(store: secrets, iterations: 64);
  await store.save(initial);
  final gate = ScriptedBiometricGate(capability: capability, outcomes: outcomes);
  final clock = FakeClock();
  final controller = UnlockController(
    lockStore: store,
    gate: gate,
    clock: clock.now,
  );
  final rig = Rig._(
    controller: controller,
    store: store,
    gate: gate,
    secrets: secrets,
    clock: clock,
  );
  rig._watch();
  await controller.start();
  return rig;
}

AppLockSettings locked({
  bool biometric = false,
  AutoLockDelay delay = AutoLockDelay.immediately,
  bool coldStart = true,
  String? passcode = 'correct-horse',
}) {
  final record = PasscodeHasher()
      .hash(passcode ?? 'correct-horse', iterations: 64);
  return AppLockSettings(
    biometricEnabled: biometric,
    passcodeRecord: record.encode(),
    autoLockDelay: delay,
    lockOnColdStart: coldStart,
    hint: '我的常用短语',
  );
}

void main() {
  group('first launch', () {
    test('no lock configured means the shell opens without asking anything',
        () async {
      final h = await rigFor();
      expect(h.controller.phase, UnlockPhase.unlocked);
      expect(h.controller.isLocked, isFalse);
      expect(h.gate.authenticateCount, 0);
      // The capability is still probed: the settings row needs it.
      expect(h.gate.probeCount, 1);
    });

    test('Face ID is off by default, and nothing turns it on', () async {
      final h = await rigFor();
      expect(h.controller.settings.biometricEnabled, isFalse);
      expect(h.controller.settings.passcodeEnabled, isFalse);
      expect(h.controller.canOfferBiometric, isFalse);
    });

    test('a passcode alone locks on cold start and offers no sensor', () async {
      final h = await rigFor(initial: locked());
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.canOfferBiometric, isFalse);
      expect(h.controller.passcodeEnabled, isTrue);
    });

    test('passcode + usable sensor asks for the sensor first', () async {
      final h = await rigFor(initial: locked(biometric: true));
      expect(h.controller.phase, UnlockPhase.requestingBiometric);
      expect(h.controller.canOfferBiometric, isTrue);
    });

    test('a sensor that is locked out falls straight to the passcode', () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        capability: const BiometricCapability(
          kind: BiometricKind.face,
          available: true,
          enrolled: true,
          lockedOut: true,
        ),
      );
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.canOfferBiometric, isFalse);
    });

    test('biometrics without a passcode (hand-edited store) does not lock out',
        () async {
      final h = await rigFor(
        initial: const AppLockSettings(
          biometricEnabled: true,
          passcodeRecord: null,
          autoLockDelay: AutoLockDelay.immediately,
          lockOnColdStart: true,
          hint: null,
        ),
      );
      expect(h.controller.phase, UnlockPhase.unlocked);
    });

    test('lockOnColdStart: false skips the cold-start prompt', () async {
      final h = await rigFor(initial: locked(coldStart: false));
      expect(h.controller.phase, UnlockPhase.unlocked);
    });

    test('a corrupted lock record does not brick the app', () async {
      final secrets = MemorySecretStore(<String, String>{
        AppLockStore.storageKey: '{{{ garbage',
      });
      final store = AppLockStore(store: secrets, iterations: 64);
      final controller = UnlockController(
        lockStore: store,
        gate: ScriptedBiometricGate(),
      );
      await controller.start();
      expect(controller.phase, UnlockPhase.unlocked);
    });
  });

  group('biometric attempts', () {
    test('success unlocks and fires the callback once', () async {
      final h = await rigFor(initial: locked(biometric: true));
      await h.controller.promptBiometric();
      expect(h.controller.phase, UnlockPhase.unlocked);
      expect(h.unlockCount, 1);
      expect(h.gate.authenticateCount, 1);
    });

    test('a lockout hides the sensor and never blames the passcode', () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        outcomes: const <BiometricOutcome>[BiometricOutcome.lockout],
      );
      await h.controller.promptBiometric();
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.canOfferBiometric, isFalse);
      expect(h.controller.message, BiometricOutcome.lockout.message);
      expect(h.controller.message, isNot(contains('密码错误')));
    });

    test('a removed enrolment also hides the sensor', () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        outcomes: const <BiometricOutcome>[BiometricOutcome.notEnrolled],
      );
      await h.controller.promptBiometric();
      expect(h.controller.canOfferBiometric, isFalse);
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('a cancelled scan keeps the sensor tappable', () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        outcomes: const <BiometricOutcome>[BiometricOutcome.userCancel],
      );
      await h.controller.promptBiometric();
      expect(h.controller.phase, UnlockPhase.requestingBiometric);
      expect(h.controller.canOfferBiometric, isTrue);
      expect(h.controller.message, BiometricOutcome.userCancel.message);
    });

    test('the system fallback button moves focus to the passcode', () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        outcomes: const <BiometricOutcome>[BiometricOutcome.userFallback],
      );
      await h.controller.promptBiometric();
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('prompting when no sensor is offered does nothing', () async {
      final h = await rigFor(initial: locked());
      await h.controller.promptBiometric();
      expect(h.gate.authenticateCount, 0);
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('prompting twice does not open two system sheets', () async {
      final h = await rigFor(initial: locked(biometric: true));
      await h.controller.promptBiometric();
      await h.controller.promptBiometric();
      // Already unlocked: the second call returns before touching the gate.
      expect(h.gate.authenticateCount, 1);
    });

    test('a hard failure blocks retries until the settings are reloaded',
        () async {
      final h = await rigFor(
        initial: locked(biometric: true),
        outcomes: const <BiometricOutcome>[BiometricOutcome.notAvailable],
      );
      await h.controller.promptBiometric();
      expect(h.controller.canOfferBiometric, isFalse);

      h.gate.setCapability(const BiometricCapability(
        kind: BiometricKind.face,
        available: true,
        enrolled: true,
        lockedOut: false,
      ));
      await h.controller.reloadSettings();
      expect(h.controller.canOfferBiometric, isTrue);
    });
  });

  group('passcode', () {
    test('the correct passcode unlocks', () async {
      final h = await rigFor(initial: locked());
      final ok = await h.controller.submitPasscode('correct-horse');
      expect(ok, isTrue);
      expect(h.controller.phase, UnlockPhase.unlocked);
      expect(h.unlockCount, 1);
    });

    test('a wrong passcode fails and keeps the app locked', () async {
      final h = await rigFor(initial: locked());
      final ok = await h.controller.submitPasscode('wrong');
      expect(ok, isFalse);
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.message, '密码错误');
      expect(h.controller.failedAttempts, 1);
    });

    test('the hint is display-only and cannot unlock', () async {
      final h = await rigFor(initial: locked());
      expect(h.controller.settings.hint, isNotNull);
      final ok = await h.controller.submitPasscode(h.controller.settings.hint!);
      expect(ok, isFalse);
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('only a PBKDF2 verifier is stored, never the passcode', () async {
      final h = await rigFor(initial: locked());
      final raw = (await h.secrets.read(AppLockStore.storageKey)) ?? '';
      expect(raw, contains('pbkdf2-sha256'));
      expect(raw, isNot(contains('correct-horse')));
    });

    test('a hand-written record with a bad hash never verifies', () async {
      final h = await rigFor(
        initial: const AppLockSettings(
          biometricEnabled: false,
          passcodeRecord: 'pbkdf2-sha256\$v=1\$i=64\$l=32\$s='
              '00000000000000000000000000000000\$h='
              '0000000000000000000000000000000000000000000000000000000000000000',
          autoLockDelay: AutoLockDelay.immediately,
          lockOnColdStart: true,
          hint: null,
        ),
      );
      expect(await h.controller.submitPasscode('correct-horse'), isFalse);
    });

    test('5 wrong attempts are free, the 6th starts a cooldown', () async {
      final h = await rigFor(initial: locked());
      for (var i = 0; i < 5; i++) {
        expect(await h.controller.submitPasscode('nope'), isFalse);
        expect(h.controller.isCoolingDown, isFalse);
      }
      expect(await h.controller.submitPasscode('nope'), isFalse);
      expect(h.controller.phase, UnlockPhase.coolingDown);
      expect(h.controller.cooldownRemaining, greaterThan(Duration.zero));
    });

    test('the correct passcode is refused during the cooldown', () async {
      final h = await rigFor(initial: locked());
      for (var i = 0; i < 6; i++) {
        await h.controller.submitPasscode('nope');
      }
      expect(h.controller.isCoolingDown, isTrue);
      final ok = await h.controller.submitPasscode('correct-horse');
      expect(ok, isFalse);
      expect(h.controller.phase, UnlockPhase.coolingDown);
    });

    test('after the cooldown the passcode works again', () async {
      final h = await rigFor(initial: locked());
      for (var i = 0; i < 6; i++) {
        await h.controller.submitPasscode('nope');
      }
      h.clock.advance(const Duration(seconds: 11));
      h.controller.tickCooldown();
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(await h.controller.submitPasscode('correct-horse'), isTrue);
      expect(h.controller.failedAttempts, 0);
    });

    test('a lock whose passcode vanished reports a failure, not a pass',
        () async {
      final h = await rigFor(initial: locked());
      expect(h.controller.isLocked, isTrue);

      // The verifier is gone from the Keychain (wiped by a restore) while the
      // app is still locked. There is nothing to compare against, so the only
      // honest answer is "cannot unlock here".
      await h.store.save(h.controller.settings.copyWith(passcodeRecord: null));
      await h.controller.reloadSettings();

      expect(await h.controller.submitPasscode('anything'), isFalse);
      expect(h.controller.message, '未设置应用解锁密码');
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('an already unlocked app accepts any submission without verifying',
        () async {
      final h = await rigFor();
      expect(await h.controller.submitPasscode('whatever'), isTrue);
    });
  });

  group('foreground and background', () {
    test('a short trip to the background does not re-lock', () async {
      final h = await rigFor(
        initial: locked(delay: AutoLockDelay.oneMinute),
      );
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      await h.controller.submitPasscode('correct-horse');

      h.controller.onPaused();
      h.clock.advance(const Duration(seconds: 20));
      await h.controller.onResumed();

      expect(h.controller.phase, UnlockPhase.unlocked);
    });

    test('staying away past the delay re-locks', () async {
      final h = await rigFor(
        initial: locked(delay: AutoLockDelay.oneMinute),
      );
      await h.controller.submitPasscode('correct-horse');

      h.controller.onPaused();
      h.clock.advance(const Duration(seconds: 61));
      await h.controller.onResumed();

      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });

    test('resuming without having been backgrounded changes nothing', () async {
      final h = await rigFor(initial: locked());
      await h.controller.submitPasscode('correct-horse');
      await h.controller.onResumed();
      expect(h.controller.phase, UnlockPhase.unlocked);
    });

    test('enrolment removed while backgrounded forces the passcode', () async {
      final h = await rigFor(
        initial: locked(biometric: true, delay: AutoLockDelay.immediately),
      );
      await h.controller.promptBiometric();
      expect(h.controller.phase, UnlockPhase.unlocked);

      h.gate.setCapability(const BiometricCapability(
        kind: BiometricKind.face,
        available: true,
        enrolled: false,
        lockedOut: false,
      ));
      h.controller.onPaused();
      await h.controller.onResumed();

      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.canOfferBiometric, isFalse);
    });

    test('lockNow locks immediately', () async {
      final h = await rigFor(initial: locked(coldStart: false));
      expect(h.controller.phase, UnlockPhase.unlocked);
      h.controller.lockNow();
      expect(h.controller.phase, UnlockPhase.needsPasscode);
    });
  });

  group('settings actions', () {
    test('enabling biometrics without a passcode is refused', () async {
      final h = await rigFor();
      final ok = await h.controller.setBiometricEnabled(true);
      expect(ok, isFalse);
      expect(h.controller.settings.biometricEnabled, isFalse);
      final persisted = await h.store.load();
      expect(persisted.biometricEnabled, isFalse);
    });

    test('enabling biometrics with a passcode persists', () async {
      final h = await rigFor(initial: locked());
      final ok = await h.controller.setBiometricEnabled(true);
      expect(ok, isTrue);
      expect((await h.store.load()).biometricEnabled, isTrue);
    });

    test('turning biometrics off leaves the passcode alone', () async {
      final h = await rigFor(initial: locked(biometric: true));
      await h.controller.setBiometricEnabled(false);
      final persisted = await h.store.load();
      expect(persisted.biometricEnabled, isFalse);
      expect(persisted.passcodeEnabled, isTrue);
    });

    test('reloading settings does not unlock by itself', () async {
      final h = await rigFor(initial: locked());
      expect(h.controller.isLocked, isTrue);
      await h.controller.reloadSettings();
      expect(h.controller.isLocked, isTrue);
    });
  });

  group('recovery', () {
    test('beginRecovery enters the recovery phase without clearing anything',
        () async {
      final h = await rigFor(initial: locked(biometric: true));
      h.controller.beginRecovery();
      expect(h.controller.phase, UnlockPhase.recovering);
      expect(h.controller.settings.passcodeEnabled, isTrue);
    });

    test('completeRecovery drops the lock and the passcode', () async {
      final h = await rigFor(initial: locked(biometric: true));
      h.controller.beginRecovery();
      await h.controller.completeRecovery();

      expect(h.controller.phase, UnlockPhase.unlocked);
      expect(h.controller.settings.lockEnabled, isFalse);
      expect(h.controller.settings.passcodeEnabled, isFalse);
      final persisted = await h.store.load();
      expect(persisted.passcodeRecord, isNull);
      expect(persisted.biometricEnabled, isFalse);
    });

    test('recovery does not touch any other stored secret', () async {
      final h = await rigFor(initial: locked());
      await h.secrets.write('tg_tdlib_db_key_v1', 'a' * 64);
      h.controller.beginRecovery();
      await h.controller.completeRecovery();
      expect(await h.secrets.read('tg_tdlib_db_key_v1'), 'a' * 64);
    });

    test('cancelling recovery keeps the app locked', () async {
      final h = await rigFor(initial: locked());
      h.controller.beginRecovery();
      h.controller.cancelRecovery();
      expect(h.controller.phase, UnlockPhase.needsPasscode);
      expect(h.controller.settings.passcodeEnabled, isTrue);
    });
  });
}
