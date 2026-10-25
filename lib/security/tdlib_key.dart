/// Encryption key for the local TDLib database.
///
/// TDLib stores message history, chat titles and file metadata on disk. Without
/// a key that entire store is plaintext: the iOS sandbox stops a remote
/// attacker, but it does not stop anyone holding the unlocked device, and it
/// certainly does not stop a TrollStore-style environment where the container
/// is directly readable.
///
/// Design rules:
/// * The key is generated **on device** from [Random.secure]; it is never
///   derived from the phone number, the api_hash or anything the user typed.
/// * It lives in the Keychain, not in a plist or the app's Documents folder.
/// * A stored key that fails validation is an error, not something to silently
///   replace — overwriting it would lock the user out of an existing database
///   that the old key can still open.
library;

import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal secret storage surface so the key logic can be unit tested without
/// the Keychain platform channel.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain-backed store. `first_unlock_this_device` keeps the value off
/// iCloud Keychain and makes it unreadable before the first unlock after a
/// reboot, which matches TDLib's own "needs the app to be running" model.
class KeychainSecretStore implements SecretStore {
  const KeychainSecretStore([
    this._storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store, used by tests and by any diagnostic path that must not
/// touch the Keychain.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? seed])
      : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// The key is malformed or missing when it should not be.
class TdlibKeyException implements Exception {
  const TdlibKeyException(this.message);

  final String message;

  @override
  String toString() => 'TdlibKeyException: $message';
}

class TdlibDatabaseKey {
  TdlibDatabaseKey({required this.store, Random? random})
      : _random = random ?? Random.secure();

  /// Versioned name: a future change of key length gets a new slot instead of
  /// silently reinterpreting an existing value.
  static const String keyName = 'tg_tdlib_db_key_v1';

  /// 32 bytes encoded as lowercase hex.
  static const int keyHexLength = 64;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  final SecretStore store;
  final Random _random;

  /// Returns the existing key or creates one. Never returns an empty string —
  /// TDLib would then be back to an unencrypted database.
  Future<String> obtain() async {
    final existing = await store.read(keyName);
    if (existing != null) {
      if (!isValid(existing)) {
        throw const TdlibKeyException(
          'Keychain 中的 TDLib 数据库密钥格式不正确（应为 64 位十六进制）。'
          '为避免覆盖仍可打开现有数据库的密钥，此处不自动重建。',
        );
      }
      return existing;
    }
    final generated = generate();
    await store.write(keyName, generated);
    return generated;
  }

  /// Reads without creating. Used by diagnostics.
  Future<String?> peek() async {
    final existing = await store.read(keyName);
    return existing != null && isValid(existing) ? existing : null;
  }

  String generate() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool isValid(String value) => _hex64.hasMatch(value);

  /// First 6 + last 4 characters, safe to print in a status line.
  static String mask(String value) {
    if (value.length <= 12) return '***';
    return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
  }
}
