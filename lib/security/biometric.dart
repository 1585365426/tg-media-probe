import 'package:local_auth/local_auth.dart';

/// What the device can actually do, as opposed to what it is allowed to do.
enum BiometricAvailability {
  /// No sensor, or the platform reports biometrics unsupported (e.g. an older
  /// device, or a build without the entitlement).
  unsupported,

  /// Sensor present but nothing enrolled — the settings row must send the user
  /// to iOS Settings instead of offering a toggle it cannot honour.
  notEnrolled,

  /// Face ID specifically is enrolled and usable.
  faceId,

  /// Only Touch ID / fingerprint is available. Kept distinct because the task
  /// book asks for "面容ID" and the option must hide itself when there is no
  /// face sensor, not silently fall back to a fingerprint prompt.
  touchIdOnly,
}

extension BiometricAvailabilityLabels on BiometricAvailability {
  bool get canOfferToggle =>
      this == BiometricAvailability.faceId ||
      this == BiometricAvailability.touchIdOnly;

  String get label => switch (this) {
        BiometricAvailability.unsupported => '此设备不支持面容 ID',
        BiometricAvailability.notEnrolled => '尚未在系统设置中录入面容 ID',
        BiometricAvailability.faceId => '面容 ID',
        BiometricAvailability.touchIdOnly => '触控 ID',
      };
}

/// Narrow surface over `local_auth` so the fallback logic can be unit-tested
/// without a real sensor.
abstract class BiometricBackend {
  Future<bool> isDeviceSupported();
  Future<bool> canCheckBiometrics();
  Future<BiometricAvailability> availability();
  Future<bool> authenticate(String reason);
}

class LocalAuthBackend implements BiometricBackend {
  LocalAuthBackend([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> canCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<BiometricAvailability> availability() async {
    try {
      if (!await _auth.isDeviceSupported()) {
        return BiometricAvailability.unsupported;
      }
      if (!await _auth.canCheckBiometrics) {
        return BiometricAvailability.unsupported;
      }
      final enrolled = await _auth.getAvailableBiometrics();
      if (enrolled.isEmpty) return BiometricAvailability.notEnrolled;
      if (enrolled.contains(BiometricType.face)) {
        return BiometricAvailability.faceId;
      }
      if (enrolled.contains(BiometricType.fingerprint) ||
          enrolled.contains(BiometricType.strong)) {
        return BiometricAvailability.touchIdOnly;
      }
      return BiometricAvailability.notEnrolled;
    } catch (_) {
      // MissingPluginException on a platform without the channel, or a platform
      // exception when the sensor is wedged. Either way: unsupported, and the
      // caller keeps the passcode path.
      return BiometricAvailability.unsupported;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      // `biometricOnly: true` is the important flag: without it iOS silently
      // offers the device passcode as a fallback inside the system sheet, which
      // would look like "Face ID worked" while the app's own passcode was
      // bypassed. The app enforces its own fallback right after a false return.
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

enum BiometricResult { success, failed, cancelled, unavailable }

/// Decides whether the Face ID row is shown and what a failed scan means.
class BiometricService {
  BiometricService({required this.backend});

  final BiometricBackend backend;

  BiometricAvailability? _cached;

  Future<BiometricAvailability> availability({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;
    final value = await backend.availability();
    _cached = value;
    return value;
  }

  Future<BiometricResult> authenticate({
    String reason = '解锁 TG Media',
  }) async {
    final state = await availability();
    if (!state.canOfferToggle) return BiometricResult.unavailable;
    try {
      final ok = await backend.authenticate(reason);
      return ok ? BiometricResult.success : BiometricResult.failed;
    } catch (_) {
      return BiometricResult.failed;
    }
  }
}

/// Test double.
class FakeBiometricBackend implements BiometricBackend {
  FakeBiometricBackend({
    this.availabilityValue = BiometricAvailability.faceId,
    this.authResult = true,
    this.throwOnAuth = false,
  });

  BiometricAvailability availabilityValue;
  bool authResult;
  bool throwOnAuth;
  int authCalls = 0;

  @override
  Future<bool> isDeviceSupported() async =>
      availabilityValue != BiometricAvailability.unsupported;

  @override
  Future<bool> canCheckBiometrics() async =>
      availabilityValue != BiometricAvailability.unsupported;

  @override
  Future<BiometricAvailability> availability() async => availabilityValue;

  @override
  Future<bool> authenticate(String reason) async {
    authCalls++;
    if (throwOnAuth) throw StateError('sensor unavailable');
    return authResult;
  }
}
