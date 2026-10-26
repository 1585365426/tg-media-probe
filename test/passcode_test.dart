import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/security/passcode.dart';

/// Fixed salt so hashes are reproducible across runs.
final List<int> fixedSalt = List<int>.generate(16, (i) => i);

/// Low cost for tests. Production uses [PasscodeHasher.defaultIterations].
const int testIterations = 1000;

void main() {
  final hasher = PasscodeHasher(random: Random(1));

  group('PasscodeHasher.hash', () {
    test('same passcode, same salt, same iterations is deterministic', () {
      final a = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      final b = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      expect(a.hashHex, b.hashHex);
      expect(a.saltHex, b.saltHex);
    });

    test('a different salt changes the verifier', () {
      final a = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      final b = hasher.hash(
        '123456',
        iterations: testIterations,
        salt: List<int>.generate(16, (i) => i + 1),
      );
      expect(a.hashHex, isNot(b.hashHex));
    });

    test('a different passcode changes the verifier', () {
      final a = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      final b = hasher.hash('123457', iterations: testIterations, salt: fixedSalt);
      expect(a.hashHex, isNot(b.hashHex));
    });

    test('generated salts differ between records', () {
      final a = hasher.hash('123456', iterations: 10);
      final b = hasher.hash('123456', iterations: 10);
      expect(a.saltHex, isNot(b.saltHex));
      expect(a.saltHex.length, PasscodeHasher.saltLength * 2);
    });

    test('the stored record never contains the passcode', () {
      const passcode = 'MySecret42';
      final record = hasher.hash(passcode, iterations: testIterations, salt: fixedSalt);
      final encoded = record.encode();
      expect(encoded.contains(passcode), isFalse);
      expect(record.hashHex.contains('4d795365637265743432'), isFalse);
    });

    test('iterations below 1 is rejected', () {
      expect(
        () => hasher.hash('123456', iterations: 0, salt: fixedSalt),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('PasscodeHasher.verify', () {
    test('accepts the right passcode', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      expect(hasher.verify(record, '123456'), isTrue);
    });

    test('rejects a wrong passcode', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      expect(hasher.verify(record, '123457'), isFalse);
    });

    test('rejects an empty passcode', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      expect(hasher.verify(record, ''), isFalse);
    });

    test('rejects a strict prefix of the right passcode', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      expect(hasher.verify(record, '12345'), isFalse);
    });

    test('a record made with a low cost still verifies after the default rises',
        () {
      // This is the migration guarantee: only new records use the new cost.
      final old = hasher.hash('123456', iterations: 100, salt: fixedSalt);
      expect(hasher.verify(old, '123456'), isTrue);
      expect(old.iterations, 100);

      final fresh = hasher.hash('123456', salt: fixedSalt);
      expect(fresh.iterations, PasscodeHasher.defaultIterations);
      expect(hasher.verify(fresh, '123456'), isTrue);
    });

    test('one flipped hex character in the hash fails', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      final chars = record.hashHex.split('');
      chars[0] = chars[0] == 'a' ? 'b' : 'a';
      final tampered = PasscodeRecord(
        iterations: record.iterations,
        saltHex: record.saltHex,
        hashHex: chars.join(),
        keyLength: record.keyLength,
      );
      expect(hasher.verify(tampered, '123456'), isFalse);
    });

    test('a tampered salt fails instead of throwing', () {
      final record = hasher.hash('123456', iterations: testIterations, salt: fixedSalt);
      final tampered = PasscodeRecord(
        iterations: record.iterations,
        saltHex: 'zz',
        hashHex: record.hashHex,
        keyLength: record.keyLength,
      );
      expect(hasher.verify(tampered, '123456'), isFalse);
    });

    test('an unparsable record fails closed', () {
      expect(hasher.verifyEncoded('', '123456'), isFalse);
      expect(hasher.verifyEncoded('garbage', '123456'), isFalse);
      expect(hasher.verifyEncoded('pbkdf2-sha256\$v=9\$i=1\$l=32\$s=00\$h=00', '123456'),
          isFalse);
    });

    test('non-ASCII passcodes round-trip', () {
      const passcode = '密码测试🔒';
      final record = hasher.hash(passcode, iterations: testIterations, salt: fixedSalt);
      expect(hasher.verify(record, passcode), isTrue);
      expect(hasher.verify(record, '密码测试'), isFalse);
    });
  });

  group('PasscodeRecord encode/decode', () {
    test('round-trips every field', () {
      final record = hasher.hash('123456', iterations: 777, salt: fixedSalt);
      final decoded = PasscodeRecord.tryDecode(record.encode());
      expect(decoded, isNotNull);
      expect(decoded!.iterations, 777);
      expect(decoded.saltHex, record.saltHex);
      expect(decoded.hashHex, record.hashHex);
      expect(decoded.keyLength, record.keyLength);
    });

    test('the encoded form carries the algorithm and version', () {
      final encoded =
          hasher.hash('123456', iterations: 10, salt: fixedSalt).encode();
      expect(encoded.startsWith('pbkdf2-sha256\$v=1\$'), isTrue);
    });

    test('rejects a wrong scheme rather than guessing', () {
      final encoded = hasher
          .hash('123456', iterations: 10, salt: fixedSalt)
          .encode()
          .replaceFirst('pbkdf2-sha256', 'md5');
      expect(PasscodeRecord.tryDecode(encoded), isNull);
    });

    test('rejects a hash whose length does not match the key length', () {
      final record = hasher.hash('123456', iterations: 10, salt: fixedSalt);
      final broken =
          'pbkdf2-sha256\$v=1\$i=10\$l=32\$s=${record.saltHex}\$h=00';
      expect(PasscodeRecord.tryDecode(broken), isNull);
    });

    test('rejects a zero iteration count', () {
      final record = hasher.hash('123456', iterations: 10, salt: fixedSalt);
      final broken =
          'pbkdf2-sha256\$v=1\$i=0\$l=32\$s=${record.saltHex}\$h=${record.hashHex}';
      expect(PasscodeRecord.tryDecode(broken), isNull);
    });

    test('rejects non-hex digits', () {
      final record = hasher.hash('123456', iterations: 10, salt: fixedSalt);
      final broken = 'pbkdf2-sha256\$v=1\$i=10\$l=32\$s=${record.saltHex}\$h=${'z' * 64}';
      expect(PasscodeRecord.tryDecode(broken), isNull);
    });
  });

  group('PasscodeHasher.validate', () {
    test('accepts a six-character passcode', () {
      expect(PasscodeHasher.validate('123456'), isNull);
    });

    test('rejects fewer than six characters', () {
      expect(PasscodeHasher.validate('12345'), PasscodeRejection.tooShort);
    });

    test('rejects more than the maximum', () {
      expect(
        PasscodeHasher.validate('a' * 129),
        PasscodeRejection.tooLong,
      );
    });

    test('rejects whitespace-only', () {
      expect(
        PasscodeHasher.validate('      '),
        PasscodeRejection.allWhitespace,
      );
    });

    test('rejects embedded newlines', () {
      expect(
        PasscodeHasher.validate('12345\n6'),
        PasscodeRejection.hasControlCharacters,
      );
    });

    test('accepts an emoji passcode of sufficient length', () {
      expect(PasscodeHasher.validate('🔒🔒🔒🔒🔒🔒'), isNull);
    });
  });

  group('PasscodeThrottle', () {
    const throttle = PasscodeThrottle(
      freeAttempts: 3,
      baseDelay: Duration(seconds: 1),
      maxDelay: Duration(seconds: 30),
    );

    test('no delay within the free attempts', () {
      expect(throttle.delayFor(0), Duration.zero);
      expect(throttle.delayFor(3), Duration.zero);
    });

    test('grows after the free attempts', () {
      expect(throttle.delayFor(4), const Duration(seconds: 2));
      expect(throttle.delayFor(5), const Duration(seconds: 4));
      expect(throttle.delayFor(6), const Duration(seconds: 8));
    });

    test('is capped', () {
      expect(throttle.delayFor(50), const Duration(seconds: 30));
      expect(throttle.delayFor(10000), const Duration(seconds: 30));
    });

    test('never goes negative for absurd counters', () {
      expect(throttle.delayFor(1 << 40).isNegative, isFalse);
    });
  });
}
