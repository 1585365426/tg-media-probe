import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/lock_policy.dart';
import 'package:tg_media_probe/security/passcode.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';

const BiometricCapability usableSensor = BiometricCapability(
  kind: BiometricKind.face,
  available: true,
  enrolled: true,
  lockedOut: false,
);

const BiometricCapability lockedSensor = BiometricCapability(
  kind: BiometricKind.face,
  available: true,
  enrolled: true,
  lockedOut: true,
);

/// A cheap passcode record so the tests do not spend a second each on KDF work.
const int cheapIterations = 100;

Future<AppLockStore> newStore([Map<String, String>? seed]) async {
  return AppLockStore(
    store: MemorySecretStore(seed),
    iterations: cheapIterations,
  );
}

Future<AppLockSettings> settingsWithPasscode(
  AppLockStore store, {
  bool biometrics = false,
  AutoLockDelay delay = AutoLockDelay.immediately,
  bool lockOnColdStart = true,
}) async {
  await store.setPasscode('123456');
  final base = await store.load();
  final patched = base.copyWith(
    biometricEnabled: biometrics,
    autoLockDelay: delay,
    lockOnColdStart: lockOnColdStart,
  );
  await store.save(patched);
  return patched;
}

void main() {
  group('AppLockSettings defaults', () {
    test('first launch has Face ID off and no passcode', () {
      const initial = AppLockSettings.initial;
      expect(initial.biometricEnabled, isFalse);
      expect(initial.passcodeEnabled, isFalse);
      expect(initial.lockEnabled, isFalse);
      expect(initial.hint, isNull);
    });

    test('auto-lock defaults to immediately and cold start locks', () {
      expect(AppLockSettings.initial.autoLockDelay, AutoLockDelay.immediately);
      expect(AppLockSettings.initial.lockOnColdStart, isTrue);
    });

    test('a passcode alone enables the lock', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(settings.passcodeEnabled, isTrue);
      expect(settings.lockEnabled, isTrue);
    });

    test('biometrics cannot be enabled without a passcode', () {
      const initial = AppLockSettings.initial;
      final attempted = initial.withBiometrics(true);
      expect(attempted.biometricEnabled, isFalse);
      expect(identical(attempted, initial), isTrue);
    });

    test('biometrics can be enabled once a passcode exists', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(settings.withBiometrics(true).biometricEnabled, isTrue);
    });

    test('disabling biometrics keeps the passcode', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      final disabled = settings.withBiometrics(false);
      expect(disabled.biometricEnabled, isFalse);
      expect(disabled.passcodeRecord, settings.passcodeRecord);
    });

    test('copyWith can clear the passcode without touching other fields', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(
        store,
        biometrics: true,
        delay: AutoLockDelay.oneMinute,
      );
      final cleared = settings.copyWith(passcodeRecord: null, hint: null);
      expect(cleared.passcodeRecord, isNull);
      expect(cleared.autoLockDelay, AutoLockDelay.oneMinute);
      // The settings object still says biometrics were on; the store is the
      // one that turns them off together with the passcode.
      expect(cleared.biometricEnabled, isTrue);
    });
  });

  group('LockEvaluator.decide', () {
    test('nothing configured means no prompt', () {
      expect(
        LockEvaluator.decide(
          settings: AppLockSettings.initial,
          coldStart: true,
          sinceBackground: const Duration(minutes: 10),
          capability: usableSensor,
        ),
        LockRequirement.none,
      );
    });

    test('cold start with lockOnColdStart asks for the passcode', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: usableSensor,
        ),
        LockRequirement.passcodeOnly,
      );
    });

    test('cold start with lockOnColdStart disabled does not ask', () async {
      final store = await newStore();
      final settings =
          await settingsWithPasscode(store, lockOnColdStart: false);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: usableSensor,
        ),
        LockRequirement.none,
      );
    });

    test('foreground without backgrounding does not ask again', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: false,
          sinceBackground: null,
          capability: usableSensor,
        ),
        LockRequirement.none,
      );
    });

    test('immediately locks after any background time', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: false,
          sinceBackground: const Duration(milliseconds: 1),
          capability: usableSensor,
        ),
        LockRequirement.passcodeOnly,
      );
    });

    test('a 30 second delay tolerates 29 seconds', () async {
      final store = await newStore();
      final settings =
          await settingsWithPasscode(store, delay: AutoLockDelay.thirtySeconds);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: false,
          sinceBackground: const Duration(seconds: 29),
          capability: usableSensor,
        ),
        LockRequirement.none,
      );
    });

    test('a 30 second delay locks at exactly 30 seconds', () async {
      final store = await newStore();
      final settings =
          await settingsWithPasscode(store, delay: AutoLockDelay.thirtySeconds);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: false,
          sinceBackground: const Duration(seconds: 30),
          capability: usableSensor,
        ),
        LockRequirement.passcodeOnly,
      );
    });

    test('a usable sensor is offered before the passcode', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: usableSensor,
        ),
        LockRequirement.biometricThenPasscode,
      );
    });

    test('a locked-out sensor falls back to the passcode', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: lockedSensor,
        ),
        LockRequirement.passcodeOnly,
      );
    });

    test('biometrics on but the sensor removed in Settings falls back', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: const BiometricCapability(
            kind: BiometricKind.face,
            available: true,
            enrolled: false,
            lockedOut: false,
          ),
        ),
        LockRequirement.passcodeOnly,
      );
    });

    test('a hand-edited store with biometrics but no passcode does not lock out',
        () async {
      // Defensive: [withBiometrics] refuses this combination, so reaching it
      // means the stored blob was edited. Demanding an unlock with nothing to
      // verify against would be a permanent lockout.
      const corrupted = AppLockSettings(
        biometricEnabled: true,
        passcodeRecord: null,
        autoLockDelay: AutoLockDelay.immediately,
        lockOnColdStart: true,
        hint: null,
      );
      expect(corrupted.lockEnabled, isTrue);
      expect(
        LockEvaluator.decide(
          settings: corrupted,
          coldStart: true,
          sinceBackground: null,
          capability: usableSensor,
        ),
        LockRequirement.none,
      );
    });
  });

  group('LockEvaluator.afterOutcome', () {
    test('success clears the requirement', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.afterOutcome(BiometricOutcome.success, settings),
        LockRequirement.none,
      );
    });

    test('a lockout hides the sensor', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.afterOutcome(BiometricOutcome.lockout, settings),
        LockRequirement.passcodeOnly,
      );
    });

    test('a user cancel keeps the sensor tappable', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      expect(
        LockEvaluator.afterOutcome(BiometricOutcome.userCancel, settings),
        LockRequirement.biometricThenPasscode,
      );
    });

    test('a user cancel without biometrics stays on the passcode', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store);
      expect(
        LockEvaluator.afterOutcome(BiometricOutcome.userCancel, settings),
        LockRequirement.passcodeOnly,
      );
    });

    test('every non-success outcome still leaves a way in', () async {
      final store = await newStore();
      final settings = await settingsWithPasscode(store, biometrics: true);
      for (final outcome in BiometricOutcome.values) {
        if (outcome == BiometricOutcome.success) continue;
        expect(
          LockEvaluator.afterOutcome(outcome, settings).isLocked,
          isTrue,
          reason: outcome.name,
        );
      }
    });
  });

  group('AppLockStore persistence', () {
    test('an empty store loads the first-launch defaults', () async {
      final store = await newStore();
      final settings = await store.load();
      expect(settings.biometricEnabled, isFalse);
      expect(settings.passcodeEnabled, isFalse);
    });

    test('round-trips every field', () async {
      final store = await newStore();
      final saved = await settingsWithPasscode(
        store,
        biometrics: true,
        delay: AutoLockDelay.fiveMinutes,
        lockOnColdStart: false,
      );
      final loaded = await store.load();
      expect(loaded.biometricEnabled, saved.biometricEnabled);
      expect(loaded.passcodeRecord, saved.passcodeRecord);
      expect(loaded.autoLockDelay, AutoLockDelay.fiveMinutes);
      expect(loaded.lockOnColdStart, isFalse);
    });

    test('survives a hint containing quotes, backslashes and newlines', () async {
      final store = await newStore();
      const hint = '提示 "引号" \\ 反斜杠\n换行';
      await store.save(AppLockSettings.initial.copyWith(hint: hint));
      expect((await store.load()).hint, hint);
    });

    test('a corrupted blob falls back to no lock instead of throwing', () async {
      final store = await newStore(<String, String>{
        AppLockStore.storageKey: '{"biometricEnabled":tru',
      });
      final settings = await store.load();
      expect(settings.lockEnabled, isFalse);
    });

    test('an unknown auto-lock name falls back to immediately', () async {
      final store = await newStore(<String, String>{
        AppLockStore.storageKey:
            '{"biometricEnabled":false,"autoLockDelay":"forever",'
                '"lockOnColdStart":true,"passcodeRecord":null,"hint":null}',
      });
      expect((await store.load()).autoLockDelay, AutoLockDelay.immediately);
    });

    test('setPasscode rejects a short passcode and stores nothing', () async {
      final store = await newStore();
      final rejection = await store.setPasscode('123');
      expect(rejection, PasscodeRejection.tooShort);
      expect((await store.load()).passcodeRecord, isNull);
    });

    test('setPasscode stores a verifier, not the passcode', () async {
      final store = await newStore();
      expect(await store.setPasscode('123456'), isNull);
      final raw = await store.store.read(AppLockStore.storageKey);
      expect(raw, isNotNull);
      expect(raw!.contains('123456'), isFalse);
    });

    test('verifyPasscode accepts the right one and rejects the rest', () async {
      final store = await newStore();
      await store.setPasscode('123456');
      expect(await store.verifyPasscode('123456'), isTrue);
      expect(await store.verifyPasscode('123457'), isFalse);
      expect(await store.verifyPasscode(''), isFalse);
    });

    test('verifyPasscode on a store without a passcode is false', () async {
      final store = await newStore();
      expect(await store.verifyPasscode('123456'), isFalse);
    });

    test('verifyPasscode is false for a hand-corrupted record', () async {
      final store = await newStore(<String, String>{
        AppLockStore.storageKey:
            '{"biometricEnabled":true,"autoLockDelay":"immediately",'
                '"lockOnColdStart":true,"passcodeRecord":"md5\$deadbeef","hint":null}',
      });
      expect(await store.verifyPasscode('123456'), isFalse);
    });

    test('clearPasscode removes the verifier and switches biometrics off',
        () async {
      final store = await newStore();
      await settingsWithPasscode(store, biometrics: true);
      final cleared = await store.clearPasscode();
      expect(cleared.passcodeRecord, isNull);
      expect(cleared.biometricEnabled, isFalse);
      expect(cleared.lockEnabled, isFalse);

      final reloaded = await store.load();
      expect(reloaded.lockEnabled, isFalse);
    });

    test('replacing the passcode keeps the user locked in, not out', () async {
      final store = await newStore();
      await store.setPasscode('123456');
      await store.setPasscode('abcdef');
      expect(await store.verifyPasscode('abcdef'), isTrue);
      expect(await store.verifyPasscode('123456'), isFalse);
    });
  });

  group('recovery plan', () {
    test('the plan clears the lock, not the Telegram session', () {
      const plan = LockRecoveryPlan.telegramReauth;
      expect(plan.clearsPasscode, isTrue);
      expect(plan.requiresTelegramReauth, isTrue);
      expect(plan.keepsTelegramSession, isFalse);
      expect(plan.summary, contains('Telegram'));
      expect(plan.summary, contains('不会被修改'));
    });

    test('applyRecoveryReset leaves no lock behind', () async {
      final store = await newStore();
      await settingsWithPasscode(store, biometrics: true);
      final reset = await store.applyRecoveryReset();
      expect(reset.lockEnabled, isFalse);
      expect(reset.hint, isNull);
      expect((await store.load()).lockEnabled, isFalse);
    });

    test('afterRecoveryReset coincides with the first-launch defaults', () {
      const settings = AppLockSettings.initial;
      final reset = settings.afterRecoveryReset();
      expect(reset.biometricEnabled, settings.biometricEnabled);
      expect(reset.passcodeRecord, settings.passcodeRecord);
      expect(reset.autoLockDelay, settings.autoLockDelay);
      expect(reset.lockOnColdStart, settings.lockOnColdStart);
    });
  });

  group('AutoLockDelay', () {
    test('labels and durations are consistent', () {
      expect(AutoLockDelay.immediately.duration, Duration.zero);
      expect(AutoLockDelay.thirtySeconds.duration, const Duration(seconds: 30));
      expect(AutoLockDelay.oneMinute.duration, const Duration(minutes: 1));
      expect(AutoLockDelay.fiveMinutes.duration, const Duration(minutes: 5));
      for (final delay in AutoLockDelay.values) {
        expect(delay.label.trim(), isNotEmpty);
      }
    });
  });
}
