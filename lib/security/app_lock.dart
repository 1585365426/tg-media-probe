import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tdlib_key.dart';

/// PBKDF2-HMAC-SHA256, 32-byte output, single block.
///
/// Hand-written because `crypto` ships HMAC and SHA-256 but no KDF, and pulling
/// a second crypto package in for one function is a worse trade than 20 lines
/// with a published test vector behind them (see `test/app_lock_test.dart`).
///
/// Cost note: pure-Dart HMAC runs at roughly 5–15 µs per iteration on an
/// iPhone, so [defaultIterations] lands around 0.6–1.5 s. That is intentional —
/// it is the only thing making an offline guess against the stored hash
/// expensive — and it is why callers run it through [deriveAsync].
Uint8List pbkdf2Sha256({
  required String password,
  required List<int> salt,
  required int iterations,
  int keyLength = 32,
}) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  if (salt.isEmpty) throw ArgumentError.value(salt, 'salt');
  final hmac = Hmac(sha256, utf8.encode(password));
  final result = Uint8List(keyLength);
  var offset = 0;
  var blockIndex = 1;

  while (offset < keyLength) {
    // INT(i) big-endian, as RFC 8018 §5.2 requires.
    final block = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
    block[salt.length] = (blockIndex >> 24) & 0xff;
    block[salt.length + 1] = (blockIndex >> 16) & 0xff;
    block[salt.length + 2] = (blockIndex >> 8) & 0xff;
    block[salt.length + 3] = blockIndex & 0xff;

    var u = Uint8List.fromList(hmac.convert(block).bytes);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }

    final take = min(t.length, keyLength - offset);
    result.setRange(offset, offset + take, t.sublist(0, take));
    offset += take;
    blockIndex++;
  }
  return result;
}

/// Runs the KDF off the UI isolate. 100k HMAC rounds on the main isolate would
/// freeze the passcode screen for a second with no way to show progress.
Future<Uint8List> deriveAsync({
  required String password,
  required List<int> salt,
  required int iterations,
  int keyLength = 32,
}) =>
    Isolate.run(() => pbkdf2Sha256(
          password: password,
          salt: salt,
          iterations: iterations,
          keyLength: keyLength,
        ));

/// Stored form of the app passcode. Never contains the passcode itself, only a
/// salted KDF output.
class PasscodeHash {
  const PasscodeHash({
    required this.iterations,
    required this.salt,
    required this.hash,
  });

  final int iterations;
  final Uint8List salt;
  final Uint8List hash;

  static const String scheme = 'pbkdf2-sha256';
  static const int defaultIterations = 100000;
  static const int saltBytes = 16;

  String encode() {
    final b64 = base64Url.encode;
    return '$scheme\$$iterations\$${b64(salt)}\$${b64(hash)}';
  }

  static PasscodeHash? tryDecode(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(r'$');
    if (parts.length != 4 || parts[0] != scheme) return null;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations < 1000) return null;
    try {
      final salt = base64Url.decode(parts[2]);
      final hash = base64Url.decode(parts[3]);
      if (salt.isEmpty || hash.isEmpty) return null;
      return PasscodeHash(iterations: iterations, salt: salt, hash: hash);
    } catch (_) {
      return null;
    }
  }

  /// Derives and compares in constant time.
  Future<bool> verify(String passcode) async {
    final candidate = await deriveAsync(
      password: passcode,
      salt: salt,
      iterations: iterations,
      keyLength: hash.length,
    );
    return constantTimeEquals(candidate, hash);
  }

  static Future<PasscodeHash> create(
    String passcode, {
    int iterations = defaultIterations,
    Random? random,
  }) async {
    final rng = random ?? Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(saltBytes, (_) => rng.nextInt(256)),
    );
    final hash = await deriveAsync(
      password: passcode,
      salt: salt,
      iterations: iterations,
    );
    return PasscodeHash(
      iterations: iterations,
      salt: salt,
      hash: Uint8List.fromList(hash),
    );
  }
}

/// Byte-wise comparison that does not exit early, so timing cannot be used to
/// walk the hash out one prefix at a time.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Passcode policy, checked before anything is written.
class PasscodePolicy {
  const PasscodePolicy._();

  static const int minLength = 6;
  static const int maxLength = 64;

  /// Returns an error message, or null when [value] is acceptable.
  static String? validate(String value) {
    if (value.length < minLength) return '应用密码至少 $minLength 位';
    if (value.length > maxLength) return '应用密码最多 $maxLength 位';
    if (value.trim().isEmpty) return '应用密码不能只包含空格';
    return null;
  }
}

/// Result of one unlock attempt, so the UI can say *why* it failed.
enum UnlockOutcome {
  success,
  wrongPasscode,
  notConfigured,
  lockedOutTemporarily,
}

/// Passcode + Face ID state.
///
/// The hash goes to the Keychain through [SecretStore] (same mechanism as the
/// TDLib database key), never to a plist, a JSON file or `SharedPreferences`.
/// The failure counter goes there too: a counter an attacker can reset by
/// editing a file is not a counter.
class AppLock {
  AppLock({
    required this.store,
    this.hashKey = 'tg_app_lock_v1',
    this.biometricKey = 'tg_app_lock_biometric_v1',
    this.failuresKey = 'tg_app_lock_failures_v1',
    this.iterations = PasscodeHash.defaultIterations,
  });

  final SecretStore store;
  final String hashKey;
  final String biometricKey;
  final String failuresKey;
  final int iterations;

  /// Attempts after which the UI starts adding a forced wait.
  static const int softLockThreshold = 5;

  /// Seconds of enforced delay once [softLockThreshold] is reached. Grows with
  /// the attempt count but is capped so a fat-fingered user is not bricked.
  static int delaySecondsFor(int failures) {
    if (failures < softLockThreshold) return 0;
    final extra = failures - softLockThreshold + 1;
    return min(30, extra * 5);
  }

  Future<PasscodeHash?> readHash() async =>
      PasscodeHash.tryDecode(await store.read(hashKey));

  Future<bool> isEnabled() async => await readHash() != null;

  /// Sets the first passcode. Refuses to overwrite an existing one — changing
  /// it requires [changePasscode], which verifies the current passcode first.
  Future<void> setPasscode(String passcode) async {
    final policyError = PasscodePolicy.validate(passcode);
    if (policyError != null) throw ArgumentError(policyError);
    if (await isEnabled()) {
      throw StateError('应用密码已设置，修改需先验证原密码');
    }
    final hash = await PasscodeHash.create(passcode, iterations: iterations);
    await store.write(hashKey, hash.encode());
    await resetFailures();
  }

  Future<UnlockOutcome> verify(String passcode) async {
    final stored = await readHash();
    if (stored == null) return UnlockOutcome.notConfigured;

    final failures = await readFailures();
    if (delaySecondsFor(failures) > 0) {
      // Caller is expected to have waited; this is the backstop that keeps a
      // scripted caller honest.
      return UnlockOutcome.lockedOutTemporarily;
    }

    if (await stored.verify(passcode)) {
      await resetFailures();
      return UnlockOutcome.success;
    }
    await _bumpFailures();
    return UnlockOutcome.wrongPasscode;
  }

  /// Verifies without touching the failure counter — used by the settings
  /// screen when the app is already unlocked and the user is editing settings.
  Future<bool> check(String passcode) async {
    final stored = await readHash();
    if (stored == null) return true;
    return stored.verify(passcode);
  }

  Future<bool> changePasscode({
    required String current,
    required String next,
  }) async {
    if (!await check(current)) return false;
    final policyError = PasscodePolicy.validate(next);
    if (policyError != null) throw ArgumentError(policyError);
    final hash = await PasscodeHash.create(next, iterations: iterations);
    await store.write(hashKey, hash.encode());
    await resetFailures();
    return true;
  }

  /// Turning the lock off always costs the current passcode.
  Future<bool> disable(String current) async {
    if (!await check(current)) return false;
    await store.delete(hashKey);
    await store.delete(biometricKey);
    await resetFailures();
    return true;
  }

  Future<bool> isBiometricEnabled() async =>
      (await store.read(biometricKey)) == 'true';

  Future<void> setBiometricEnabled(bool enabled) => enabled
      ? store.write(biometricKey, 'true')
      : store.delete(biometricKey);

  Future<int> readFailures() async {
    final raw = await store.read(failuresKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> resetFailures() => store.delete(failuresKey);

  Future<void> _bumpFailures() async {
    final next = await readFailures() + 1;
    await store.write(failuresKey, '$next');
  }
}
