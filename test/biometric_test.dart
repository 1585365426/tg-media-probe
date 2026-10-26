import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/security/biometric.dart';

void main() {
  group('BiometricCapability', () {
    test('canAuthenticate needs hardware, enrolment and no lockout', () {
      const ok = BiometricCapability(
        kind: BiometricKind.face,
        available: true,
        enrolled: true,
        lockedOut: false,
      );
      expect(ok.canAuthenticate, isTrue);
      expect(ok.unavailableReason, isNull);

      final noHardware = BiometricCapability(
        kind: BiometricKind.none,
        available: ok.available,
        enrolled: ok.enrolled,
        lockedOut: ok.lockedOut,
      );
      expect(noHardware.canAuthenticate, isFalse);
      expect(noHardware.unavailableReason, '此设备不支持生物识别');

      final notEnrolled = BiometricCapability(
        kind: BiometricKind.face,
        available: true,
        enrolled: false,
        lockedOut: false,
      );
      expect(notEnrolled.canAuthenticate, isFalse);
      expect(notEnrolled.unavailableReason, contains('录入'));

      final locked = BiometricCapability(
        kind: BiometricKind.face,
        available: true,
        enrolled: true,
        lockedOut: true,
      );
      expect(locked.canAuthenticate, isFalse);
      expect(locked.unavailableReason, contains('锁定'));
    });

    test('label follows the sensor instead of assuming Face ID', () {
      BiometricCapability withKind(BiometricKind kind) => BiometricCapability(
            kind: kind,
            available: true,
            enrolled: true,
            lockedOut: false,
          );
      expect(withKind(BiometricKind.face).label, '面容 ID');
      expect(withKind(BiometricKind.touch).label, '触控 ID');
      expect(withKind(BiometricKind.optic).label, '光学 ID');
    });

    test('unavailable default reports no hardware', () {
      const cap = BiometricCapability.unavailable();
      expect(cap.kind, BiometricKind.none);
      expect(cap.canAuthenticate, isFalse);
      expect(cap.lockedOut, isFalse);
    });

    test('json round-trip keeps every field', () {
      const original = BiometricCapability(
        kind: BiometricKind.touch,
        available: true,
        enrolled: false,
        lockedOut: true,
      );
      final restored = BiometricCapability.fromJson(original.toJson());
      expect(restored.kind, original.kind);
      expect(restored.available, original.available);
      expect(restored.enrolled, original.enrolled);
      expect(restored.lockedOut, original.lockedOut);
    });

    test('an unknown sensor name degrades to unknown, not to face', () {
      final restored = BiometricCapability.fromJson(<String, Object?>{
        'kind': 'palmPrint',
        'available': true,
        'enrolled': true,
        'lockedOut': false,
      });
      expect(restored.kind, BiometricKind.unknown);
    });
  });

  group('BiometricOutcome classification', () {
    test('only success is success', () {
      for (final outcome in BiometricOutcome.values) {
        expect(outcome.isSuccess, outcome == BiometricOutcome.success,
            reason: outcome.name);
      }
    });

    test('hard failures require the passcode fallback', () {
      for (final outcome in <BiometricOutcome>[
        BiometricOutcome.lockout,
        BiometricOutcome.notEnrolled,
        BiometricOutcome.notAvailable,
        BiometricOutcome.passcodeNotSet,
        BiometricOutcome.error,
      ]) {
        expect(outcome.requiresFallback, isTrue, reason: outcome.name);
        expect(outcome.isCancellation, isFalse, reason: outcome.name);
      }
    });

    test('cancellations do not count as failures', () {
      for (final outcome in <BiometricOutcome>[
        BiometricOutcome.userCancel,
        BiometricOutcome.systemCancel,
        BiometricOutcome.appCancel,
        BiometricOutcome.userFallback,
      ]) {
        expect(outcome.isCancellation, isTrue, reason: outcome.name);
        expect(outcome.requiresFallback, isFalse, reason: outcome.name);
      }
    });

    test('success needs neither fallback nor retry', () {
      expect(BiometricOutcome.success.requiresFallback, isFalse);
      expect(BiometricOutcome.success.isCancellation, isFalse);
    });

    test('every outcome has a non-empty Chinese message', () {
      for (final outcome in BiometricOutcome.values) {
        expect(outcome.message.trim(), isNotEmpty, reason: outcome.name);
      }
    });

    test('the failure message does not leak whether the passcode matched', () {
      // A wrong face scan must not read like "wrong password": the lock screen
      // shows this text before the passcode field is even focused.
      final text = BiometricOutcome.error.message;
      expect(text.contains('密码错误'), isFalse);
      expect(text.contains('不正确'), isFalse);
    });
  });

  group('ScriptedBiometricGate', () {
    test('returns the scripted sequence and then repeats the last value', () async {
      final gate = ScriptedBiometricGate(outcomes: const <BiometricOutcome>[
        BiometricOutcome.userCancel,
        BiometricOutcome.success,
      ]);
      expect(
        await gate.authenticate(reason: 'a'),
        BiometricOutcome.userCancel,
      );
      expect(await gate.authenticate(reason: 'b'), BiometricOutcome.success);
      expect(await gate.authenticate(reason: 'c'), BiometricOutcome.success);
      expect(gate.authenticateCount, 3);
      expect(gate.reasons, <String>['a', 'b', 'c']);
    });

    test('probe reports the configured capability', () async {
      final gate = ScriptedBiometricGate(
        capability: const BiometricCapability(
          kind: BiometricKind.touch,
          available: true,
          enrolled: false,
          lockedOut: false,
        ),
      );
      final cap = await gate.probe();
      expect(cap.kind, BiometricKind.touch);
      expect(cap.canAuthenticate, isFalse);
      expect(gate.probeCount, 1);
    });

    test('capability can change mid-session (user edits Settings)', () async {
      final gate = ScriptedBiometricGate();
      expect((await gate.probe()).canAuthenticate, isTrue);
      gate.setCapability(const BiometricCapability.unavailable());
      expect((await gate.probe()).canAuthenticate, isFalse);
    });
  });

  group('MethodChannelBiometricGate', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const channel = MethodChannel(MethodChannelBiometricGate.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('probe maps the native payload', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'probe');
        return <String, Object?>{
          'kind': 'face',
          'available': true,
          'enrolled': true,
          'lockedOut': false,
        };
      });
      final cap = await MethodChannelBiometricGate().probe();
      expect(cap.kind, BiometricKind.face);
      expect(cap.canAuthenticate, isTrue);
    });

    test('probe without a channel reports unavailable instead of throwing',
        () async {
      final cap = await MethodChannelBiometricGate(
        channel: const MethodChannel('com.tgmedia/biometric.absent'),
      ).probe();
      expect(cap.canAuthenticate, isFalse);
      expect(cap.kind, BiometricKind.none);
    });

    test('authenticate passes the reason through', () async {
      String? seenReason;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'authenticate');
        seenReason = (call.arguments as Map)['reason'] as String?;
        return 'success';
      });
      final outcome =
          await MethodChannelBiometricGate().authenticate(reason: '解锁 TG Media');
      expect(outcome, BiometricOutcome.success);
      expect(seenReason, '解锁 TG Media');
    });

    test('each native outcome name maps to its enum value', () async {
      for (final expected in BiometricOutcome.values) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => expected.name,
        );
        expect(
          await MethodChannelBiometricGate().authenticate(reason: 'r'),
          expected,
        );
      }
    });

    test('a PlatformException code is mapped, not swallowed', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'lockout');
      });
      expect(
        await MethodChannelBiometricGate().authenticate(reason: 'r'),
        BiometricOutcome.lockout,
      );
    });

    test('an unknown exception becomes error, never success', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('boom');
      });
      final outcome = await MethodChannelBiometricGate().authenticate(reason: 'r');
      expect(outcome, BiometricOutcome.error);
      expect(outcome.isSuccess, isFalse);
    });

    test('a missing plugin becomes notAvailable', () async {
      final gate = MethodChannelBiometricGate(
        channel: const MethodChannel('com.tgmedia/biometric.missing'),
      );
      final outcome = await gate.authenticate(reason: 'r');
      expect(outcome, BiometricOutcome.notAvailable);
    });
  });
}
