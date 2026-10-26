/// Face ID / Touch ID gate for the local app lock.
///
/// Scope, stated once so no later screen forgets it:
///
/// * Biometrics unlock **this app**. They are not a Telegram credential and are
///   never sent to Telegram, never stored, and never used to derive the TDLib
///   database key.
/// * No biometric template ever reaches Dart. `LAContext.evaluatePolicy` returns
///   a boolean; the template stays inside the Secure Enclave.
/// * The gate is an interface with a scripted implementation so the lock
///   decisions can be tested without a device. Anything that needs a real
///   sensor is marked unverified until it runs on the iPhone.
library;

import 'package:flutter/services.dart';

/// Which sensor the device advertises.
enum BiometricKind { none, face, touch, optic, unknown }

/// A capability snapshot. Distinct from an attempt outcome: capability answers
/// "can this device do it at all, right now", which decides whether the setting
/// toggle is even offered.
class BiometricCapability {
  const BiometricCapability({
    required this.kind,
    required this.available,
    required this.enrolled,
    required this.lockedOut,
  });

  const BiometricCapability.unavailable()
      : kind = BiometricKind.none,
        available = false,
        enrolled = false,
        lockedOut = false;

  final BiometricKind kind;

  /// Hardware present and usable.
  final bool available;

  /// The user has enrolled at least one face or finger.
  final bool enrolled;

  /// The sensor is temporarily disabled after too many failed attempts. It
  /// recovers only after a successful device-passcode unlock.
  final bool lockedOut;

  /// A device with no sensor can still report `available == true` from a
  /// platform that only looked at enrolment, so the kind is part of the check.
  bool get canAuthenticate =>
      kind != BiometricKind.none && available && enrolled && !lockedOut;

  /// Name shown in the settings row. Never assume Face ID: an iPhone 8 has
  /// Touch ID and an SE has no Face ID at all.
  String get label => switch (kind) {
        BiometricKind.face => '面容 ID',
        BiometricKind.touch => '触控 ID',
        BiometricKind.optic => '光学 ID',
        BiometricKind.none => '生物识别',
        BiometricKind.unknown => '生物识别',
      };

  /// Why the toggle should be disabled, or null when it can be offered.
  String? get unavailableReason {
    if (kind == BiometricKind.none || !available) return '此设备不支持生物识别';
    if (!enrolled) return '请先在系统设置中录入$label';
    if (lockedOut) return '$label已被系统暂时锁定，需要先用设备密码解锁';
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'available': available,
        'enrolled': enrolled,
        'lockedOut': lockedOut,
      };

  static BiometricCapability fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    return BiometricCapability(
      kind: BiometricKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => BiometricKind.unknown,
      ),
      available: json['available'] == true,
      enrolled: json['enrolled'] == true,
      lockedOut: json['lockedOut'] == true,
    );
  }
}

/// Result of one authentication attempt.
enum BiometricOutcome {
  success,

  /// The user tapped Cancel.
  userCancel,

  /// iOS cancelled on its own: another app came to the foreground, the call was
  /// interrupted by a phone call.
  systemCancel,

  /// The user chose the "use passcode" button in the system sheet.
  userFallback,

  /// Too many failures; the sensor is off until the device passcode is used.
  lockout,

  /// Nothing enrolled, or enrolment was removed in Settings while the app was
  /// in the background.
  notEnrolled,

  /// No sensor, or the sensor is unavailable (e.g. covered).
  notAvailable,

  /// The device has no passcode set. iOS refuses biometrics in that case.
  passcodeNotSet,

  /// The app itself cancelled (it moved to the background mid-prompt).
  appCancel,

  /// Anything else, including a missing platform channel.
  error,
}

extension BiometricOutcomeMeaning on BiometricOutcome {
  bool get isSuccess => this == BiometricOutcome.success;

  /// The sensor cannot be used again until the user fixes something outside
  /// this app. The lock screen must fall back to the passcode immediately and
  /// must not keep re-prompting.
  bool get requiresFallback =>
      this == BiometricOutcome.lockout ||
      this == BiometricOutcome.notEnrolled ||
      this == BiometricOutcome.notAvailable ||
      this == BiometricOutcome.passcodeNotSet ||
      this == BiometricOutcome.error;

  /// The user (or the system) chose to stop. Retrying immediately would just
  /// re-open the sheet the user dismissed, so the UI waits for a tap.
  bool get isCancellation =>
      this == BiometricOutcome.userCancel ||
      this == BiometricOutcome.systemCancel ||
      this == BiometricOutcome.appCancel ||
      this == BiometricOutcome.userFallback;

  /// Shown under the unlock button. Deliberately neutral: a failed face scan is
  /// not an accusation, and the message must not reveal whether the passcode
  /// was the thing that failed.
  String get message => switch (this) {
        BiometricOutcome.success => '已解锁',
        BiometricOutcome.userCancel => '已取消',
        BiometricOutcome.systemCancel => '识别被中断',
        BiometricOutcome.userFallback => '请使用应用密码解锁',
        BiometricOutcome.lockout => '生物识别已被锁定，请用应用密码解锁',
        BiometricOutcome.notEnrolled => '系统未录入生物识别，请用应用密码解锁',
        BiometricOutcome.notAvailable => '生物识别暂不可用，请用应用密码解锁',
        BiometricOutcome.passcodeNotSet => '设备未设置密码，请用应用密码解锁',
        BiometricOutcome.appCancel => '识别已取消',
        BiometricOutcome.error => '识别失败，请用应用密码解锁',
      };
}

abstract class BiometricGate {
  /// Current capability. Cheap enough to call when the settings page opens.
  Future<BiometricCapability> probe();

  /// Shows the system prompt. [reason] is shown to the user by iOS.
  Future<BiometricOutcome> authenticate({required String reason});
}

/// Talks to `ios/Runner/BiometricChannel.swift`.
///
/// The native side returns outcome names as strings, not `LAError` numbers: a
/// numeric code that shifts between iOS versions would silently turn into
/// [BiometricOutcome.error], and "recognition failed" would then look like
/// "sensor missing".
class MethodChannelBiometricGate implements BiometricGate {
  MethodChannelBiometricGate({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.tgmedia/biometric';

  final MethodChannel _channel;

  @override
  Future<BiometricCapability> probe() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('probe');
      if (raw == null) return const BiometricCapability.unavailable();
      return BiometricCapability.fromJson(raw);
    } on Object {
      // No channel (unit test host, Android, a build without the Swift file).
      // Reporting "unavailable" is the only honest answer.
      return const BiometricCapability.unavailable();
    }
  }

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    try {
      final raw = await _channel.invokeMethod<String>(
        'authenticate',
        <String, Object?>{'reason': reason},
      );
      return _outcomeFromName(raw);
    } on PlatformException catch (e) {
      return _outcomeFromName(e.code);
    } on MissingPluginException {
      return BiometricOutcome.notAvailable;
    } on Object {
      return BiometricOutcome.error;
    }
  }

  static BiometricOutcome _outcomeFromName(String? name) {
    for (final outcome in BiometricOutcome.values) {
      if (outcome.name == name) return outcome;
    }
    return BiometricOutcome.error;
  }
}

/// Deterministic gate for tests and for the "no sensor" path.
class ScriptedBiometricGate implements BiometricGate {
  ScriptedBiometricGate({
    this.capability = const BiometricCapability(
      kind: BiometricKind.face,
      available: true,
      enrolled: true,
      lockedOut: false,
    ),
    List<BiometricOutcome> outcomes = const <BiometricOutcome>[
      BiometricOutcome.success,
    ],
  }) : _outcomes = List<BiometricOutcome>.from(outcomes);

  /// Mutable so a test can simulate the user editing Settings mid-session.
  BiometricCapability capability;

  final List<BiometricOutcome> _outcomes;

  int probeCount = 0;
  int authenticateCount = 0;
  final List<String> reasons = <String>[];

  /// After the scripted outcomes run out, this is returned every time.
  BiometricOutcome repeatLast = BiometricOutcome.success;

  void setCapability(BiometricCapability next) => capability = next;

  @override
  Future<BiometricCapability> probe() async {
    probeCount++;
    return capability;
  }

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    authenticateCount++;
    reasons.add(reason);
    if (_outcomes.isEmpty) return repeatLast;
    return _outcomes.removeAt(0);
  }
}
