import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/security/app_lock.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    // Published vectors for PBKDF2-SHA256 with P="password", S="salt",
    // dkLen=32. c=1 and c=2 pin the first two iterations; c=4096 pins the
    // loop, which is where a wrong XOR accumulates and still looks plausible.
    const password = 'password';
    const salt = 'salt';
    const expected = <int, String>{
      1: '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      2: 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      4096: 'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
    };

    for (final entry in expected.entries) {
      test('c=${entry.key} matches the published vector', () {
        final out = pbkdf2Sha256(
          password: password,
          salt: salt.codeUnits,
          iterations: entry.key,
        );
        expect(hex(out), entry.value);
      });
    }

    test('changing the salt changes the output', () {
      final a = pbkdf2Sha256(
          password: password, salt: 'salt'.codeUnits, iterations: 2);
      final b = pbkdf2Sha256(
          password: password, salt: 'Salt'.codeUnits, iterations: 2);
      expect(hex(a), isNot(hex(b)));
    });

    test('different key lengths produce a prefix-compatible result', () {
      final short = pbkdf2Sha256(
          password: password, salt: salt.codeUnits, iterations: 2, keyLength: 16);
      final long = pbkdf2Sha256(
          password: password, salt: salt.codeUnits, iterations: 2, keyLength: 32);
      expect(hex(short), hex(long).substring(0, 32));
    });

    test('rejects nonsense parameters instead of returning garbage', () {
      expect(
        () => pbkdf2Sha256(password: 'x', salt: <int>[1], iterations: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => pbkdf2Sha256(password: 'x', salt: const <int>[], iterations: 1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('constant-time compare', () {
    test('equal arrays compare true, differing ones false', () {
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 3]), isTrue);
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 4]), isFalse);
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 2, 3]), isFalse);
    });
  });

  group('PasscodeHash', () {
    test('verify accepts the right passcode and rejects anything else', () async {
      final hash = await PasscodeHash.create('246813', iterations: 1000);
      expect(await hash.verify('246813'), isTrue);
      expect(await hash.verify('246814'), isFalse);
      expect(await hash.verify(''), isFalse);
    });

    test('encode/decode round-trips without keeping the passcode', () async {
      final hash = await PasscodeHash.create('246813', iterations: 1000);
      final encoded = hash.encode();
      expect(encoded, startsWith('pbkdf2-sha256\$1000\$'));
      expect(encoded.contains('246813'), isFalse,
          reason: 'the passcode itself must never appear in the stored form');

      final decoded = PasscodeHash.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.iterations, 1000);
      expect(await decoded.verify('246813'), isTrue);
    });

    test('two hashes of the same passcode differ (random salt)', () async {
      final a = await PasscodeHash.create('246813', iterations: 1000);
      final b = await PasscodeHash.create('246813', iterations: 1000);
      expect(hex(a.salt), isNot(hex(b.salt)));
      expect(hex(a.hash), isNot(hex(b.hash)));
    });

    test('malformed stored values decode to null', () {
      expect(PasscodeHash.tryDecode(null), isNull);
      expect(PasscodeHash.tryDecode(''), isNull);
      expect(PasscodeHash.tryDecode('plaintext'), isNull);
      expect(PasscodeHash.tryDecode('pbkdf2-sha256\$10\$abc\$def'), isNull,
          reason: 'iteration count below the floor is rejected');
      expect(PasscodeHash.tryDecode('bcrypt\$100000\$abc\$def'), isNull);
    });
  });

  group('PasscodePolicy', () {
    test('accepts 6+ characters', () {
      expect(PasscodePolicy.validate('123456'), isNull);
      expect(PasscodePolicy.validate('abcdef'), isNull);
    });

    test('rejects short, blank and oversized input', () {
      expect(PasscodePolicy.validate('12345'), isNotNull);
      expect(PasscodePolicy.validate('      '), isNotNull);
      expect(PasscodePolicy.validate('a' * 65), isNotNull);
    });
  });

  group('AppLock', () {
    late MemorySecretStore store;
    late AppLock lock;

    setUp(() {
      store = MemorySecretStore();
      lock = AppLock(store: store, iterations: 1000);
    });

    test('starts disabled', () async {
      expect(await lock.isEnabled(), isFalse);
      expect(await lock.verify('anything'), UnlockOutcome.notConfigured);
    });

    test('setPasscode stores only a hash', () async {
      await lock.setPasscode('135790');
      final stored = await store.read(lock.hashKey);
      expect(stored, isNotNull);
      expect(stored!.contains('135790'), isFalse);
      expect(await lock.isEnabled(), isTrue);
    });

    test('a second setPasscode is refused while one exists', () async {
      await lock.setPasscode('135790');
      expect(() => lock.setPasscode('999999'), throwsStateError);
    });

    test('verify reports success, wrong passcode, and counts failures', () async {
      await lock.setPasscode('135790');
      expect(await lock.verify('000000'), UnlockOutcome.wrongPasscode);
      expect(await lock.readFailures(), 1);
      expect(await lock.verify('135790'), UnlockOutcome.success);
      expect(await lock.readFailures(), 0,
          reason: 'a successful unlock clears the counter');
    });

    test('cooldown kicks in after five failures', () async {
      expect(AppLock.delaySecondsFor(0), 0);
      expect(AppLock.delaySecondsFor(4), 0);
      expect(AppLock.delaySecondsFor(5), 5);
      expect(AppLock.delaySecondsFor(6), 10);
      expect(AppLock.delaySecondsFor(100), 30, reason: 'delay is capped');
    });

    test('verify refuses while the cooldown is pending', () async {
      await lock.setPasscode('135790');
      for (var i = 0; i < 5; i++) {
        await lock.verify('000000');
      }
      expect(await lock.verify('135790'), UnlockOutcome.lockedOutTemporarily);
    });

    test('changePasscode requires the current one', () async {
      await lock.setPasscode('135790');
      expect(
        await lock.changePasscode(current: '000000', next: '112233'),
        isFalse,
      );
      expect(await lock.verify('135790'), UnlockOutcome.success);

      expect(
        await lock.changePasscode(current: '135790', next: '112233'),
        isTrue,
      );
      expect(await lock.verify('135790'), UnlockOutcome.wrongPasscode);
      expect(await lock.verify('112233'), UnlockOutcome.success);
    });

    test('disable requires the current passcode and clears biometric state',
        () async {
      await lock.setPasscode('135790');
      await lock.setBiometricEnabled(true);
      expect(await lock.isBiometricEnabled(), isTrue);

      expect(await lock.disable('000000'), isFalse);
      expect(await lock.isEnabled(), isTrue);

      expect(await lock.disable('135790'), isTrue);
      expect(await lock.isEnabled(), isFalse);
      expect(await lock.isBiometricEnabled(), isFalse);
    });

    test('biometric preference is stored as its own key', () async {
      expect(await lock.isBiometricEnabled(), isFalse);
      await lock.setBiometricEnabled(true);
      expect(await lock.isBiometricEnabled(), isTrue);
      await lock.setBiometricEnabled(false);
      expect(await lock.isBiometricEnabled(), isFalse);
      // A passcode is not implied by the flag.
      expect(await lock.isEnabled(), isFalse);
    });

    test('check() does not move the failure counter', () async {
      await lock.setPasscode('135790');
      expect(await lock.check('000000'), isFalse);
      expect(await lock.readFailures(), 0);
    });
  });

  group('BiometricService', () {
    test('no sensor means the toggle must hide', () async {
      final service = BiometricService(
        backend: FakeBiometricBackend(
          availabilityValue: BiometricAvailability.unsupported,
        ),
      );
      expect((await service.availability()).canOfferToggle, isFalse);
      expect(await service.authenticate(), BiometricResult.unavailable);
    });

    test('sensor without enrolment still hides the toggle', () async {
      final service = BiometricService(
        backend: FakeBiometricBackend(
          availabilityValue: BiometricAvailability.notEnrolled,
        ),
      );
      expect((await service.availability()).canOfferToggle, isFalse);
    });

    test('Face ID available reports the faceId state', () async {
      final service = BiometricService(backend: FakeBiometricBackend());
      expect(await service.availability(), BiometricAvailability.faceId);
      expect((await service.availability()).canOfferToggle, isTrue);
    });

    test('a failed scan returns failed, never success', () async {
      final service = BiometricService(
        backend: FakeBiometricBackend(authResult: false),
      );
      expect(await service.authenticate(), BiometricResult.failed);
    });

    test('a throwing sensor degrades to failed instead of propagating',
        () async {
      final service = BiometricService(
        backend: FakeBiometricBackend(throwOnAuth: true),
      );
      expect(await service.authenticate(), BiometricResult.failed);
    });

    test('availability is cached until refresh is requested', () async {
      final backend = FakeBiometricBackend();
      final service = BiometricService(backend: backend);
      expect(await service.availability(), BiometricAvailability.faceId);
      backend.availabilityValue = BiometricAvailability.unsupported;
      expect(await service.availability(), BiometricAvailability.faceId);
      expect(
        await service.availability(refresh: true),
        BiometricAvailability.unsupported,
      );
    });
  });
}
