/// Passcode verifier for the app lock.
///
/// Design constraints that shaped this file:
///
/// * The passcode is never stored, and neither is anything that can be turned
///   back into it. Only a PBKDF2-HMAC-SHA256 verifier is kept.
/// * The stored record carries its own iteration count and salt. Raising the
///   work factor later must not invalidate existing records — an old record
///   keeps verifying with the count it was created with.
/// * A hint is **not** a credential. [PasscodeRecord] has no field for one, so
///   no code path can accept a hint in place of the passcode.
/// * Verification is constant time over the derived bytes.
library;

import 'dart:math';

import '../util/sha256.dart';

/// What is persisted. Contains no information that shortens a brute-force
/// search beyond the iteration count, which is written in the clear on purpose
/// (it has to be, to verify).
class PasscodeRecord {
  const PasscodeRecord({
    required this.iterations,
    required this.saltHex,
    required this.hashHex,
    this.keyLength = PasscodeHasher.keyLength,
  });

  final int iterations;
  final String saltHex;
  final String hashHex;
  final int keyLength;

  /// Version prefix so a future algorithm change is a new scheme, not a
  /// reinterpretation of an existing string.
  static const String scheme = 'pbkdf2-sha256';
  static const int version = 1;

  String encode() =>
      '$scheme\$v=$version\$i=$iterations\$l=$keyLength\$s=$saltHex\$h=$hashHex';

  /// Returns null for anything that is not a well-formed record. A corrupted
  /// record must fail closed: the caller then treats the app lock as broken
  /// and requires a full re-login rather than silently unlocking.
  static PasscodeRecord? tryDecode(String raw) {
    final parts = raw.split(r'$');
    if (parts.length != 6) return null;
    if (parts[0] != scheme) return null;

    int? readInt(String token, String name) {
      final prefix = '$name=';
      if (!token.startsWith(prefix)) return null;
      return int.tryParse(token.substring(prefix.length));
    }

    final versionValue = readInt(parts[1], 'v');
    final iterations = readInt(parts[2], 'i');
    final keyLength = readInt(parts[3], 'l');
    if (versionValue != version) return null;
    if (iterations == null || iterations < 1) return null;
    if (keyLength == null || keyLength < 16 || keyLength > 64) return null;
    if (!parts[4].startsWith('s=') || !parts[5].startsWith('h=')) return null;

    final saltHex = parts[4].substring(2);
    final hashHex = parts[5].substring(2);
    if (saltHex.length < 32 || saltHex.length > 128) return null;
    if (hashHex.length != keyLength * 2) return null;
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(saltHex)) return null;
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(hashHex)) return null;

    return PasscodeRecord(
      iterations: iterations,
      saltHex: saltHex,
      hashHex: hashHex,
      keyLength: keyLength,
    );
  }
}

/// Why a passcode was rejected at creation time.
enum PasscodeRejection { tooShort, tooLong, allWhitespace, hasControlCharacters }

extension PasscodeRejectionText on PasscodeRejection {
  String get message => switch (this) {
        PasscodeRejection.tooShort => '密码至少 6 位',
        PasscodeRejection.tooLong => '密码不能超过 128 位',
        PasscodeRejection.allWhitespace => '密码不能全是空格',
        PasscodeRejection.hasControlCharacters => '密码不能包含换行或控制字符',
      };
}

class PasscodeHasher {
  PasscodeHasher({Random? random}) : _random = random ?? Random.secure();

  /// Cost of a fresh record. 120k PBKDF2-HMAC-SHA256 rounds is roughly a
  /// tenth of a second on an A7-class core in AOT Dart; run it off the UI
  /// isolate (`Isolate.run`) so the unlock screen keeps animating.
  static const int defaultIterations = 120000;

  static const int saltLength = 16;
  static const int keyLength = 32;
  static const int minimumLength = 6;
  static const int maximumLength = 128;

  final Random _random;

  /// Null when [passcode] is acceptable, otherwise the reason.
  static PasscodeRejection? validate(String passcode) {
    if (passcode.trim().isEmpty && passcode.isNotEmpty) {
      return PasscodeRejection.allWhitespace;
    }
    if (passcode.length < minimumLength) return PasscodeRejection.tooShort;
    if (passcode.length > maximumLength) return PasscodeRejection.tooLong;
    for (final rune in passcode.runes) {
      if (rune < 0x20 || rune == 0x7F) {
        return PasscodeRejection.hasControlCharacters;
      }
    }
    return null;
  }

  /// Salt and iteration count are explicit parameters so tests can pin them.
  PasscodeRecord hash(
    String passcode, {
    int iterations = defaultIterations,
    List<int>? salt,
  }) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
    }
    final saltBytes = salt ?? List<int>.generate(saltLength, (_) => _random.nextInt(256));
    final derived = pbkdf2HmacSha256(
      password: _utf8Bytes(passcode),
      salt: saltBytes,
      iterations: iterations,
      keyLength: keyLength,
    );
    return PasscodeRecord(
      iterations: iterations,
      saltHex: bytesToHex(saltBytes),
      hashHex: bytesToHex(derived),
    );
  }

  /// Re-derives with the record's own parameters and compares constant time.
  ///
  /// Returns false — never throws — for a malformed record, because a throwing
  /// unlock screen is a crash at the worst possible moment.
  bool verify(PasscodeRecord record, String passcode) {
    try {
      final derived = pbkdf2HmacSha256(
        password: _utf8Bytes(passcode),
        salt: hexToBytes(record.saltHex),
        iterations: record.iterations,
        keyLength: record.keyLength,
      );
      return constantTimeEquals(derived, hexToBytes(record.hashHex));
    } on Object {
      return false;
    }
  }

  /// Convenience for the storage layer: verify a record that was persisted as
  /// a string, treating an unparsable string as a failure.
  bool verifyEncoded(String encoded, String passcode) {
    final record = PasscodeRecord.tryDecode(encoded);
    if (record == null) return false;
    return verify(record, passcode);
  }

  /// UTF-8 encoding done by hand: `dart:convert` would pull the whole codec
  /// machinery into the unlock path for six to twelve characters.
  static List<int> _utf8Bytes(String input) {
    final out = <int>[];
    for (final rune in input.runes) {
      if (rune <= 0x7F) {
        out.add(rune);
      } else if (rune <= 0x7FF) {
        out..add(0xC0 | (rune >> 6))..add(0x80 | (rune & 0x3F));
      } else if (rune <= 0xFFFF) {
        out
          ..add(0xE0 | (rune >> 12))
          ..add(0x80 | ((rune >> 6) & 0x3F))
          ..add(0x80 | (rune & 0x3F));
      } else {
        out
          ..add(0xF0 | (rune >> 18))
          ..add(0x80 | ((rune >> 12) & 0x3F))
          ..add(0x80 | ((rune >> 6) & 0x3F))
          ..add(0x80 | (rune & 0x3F));
      }
    }
    return out;
  }
}

/// Retry pacing after wrong passcodes.
///
/// Without this the app lock is a free oracle: an attacker with the phone can
/// try passcodes as fast as PBKDF2 allows. The delay is enforced by the caller
/// (it must actually wait), but the schedule lives here so it can be tested.
class PasscodeThrottle {
  const PasscodeThrottle({
    this.freeAttempts = 5,
    this.baseDelay = const Duration(seconds: 5),
    this.maxDelay = const Duration(minutes: 5),
  });

  /// Attempts allowed before any delay is applied.
  final int freeAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Delay to wait before the next attempt, given [consecutiveFailures] so far.
  Duration delayFor(int consecutiveFailures) {
    if (consecutiveFailures <= freeAttempts) return Duration.zero;
    final step = consecutiveFailures - freeAttempts;
    // Cap the exponent before shifting: 2^32 seconds overflows nothing in Dart
    // but the intermediate is pointless once it exceeds maxDelay.
    final exponent = step > 16 ? 16 : step;
    final millis = baseDelay.inMilliseconds * (1 << exponent);
    if (millis <= 0 || millis >= maxDelay.inMilliseconds) return maxDelay;
    return Duration(milliseconds: millis);
  }
}
