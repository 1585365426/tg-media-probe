/// App-lock policy: when to ask for Face ID, when to ask for the passcode, and
/// when to ask for nothing.
///
/// Separated from [BiometricGate] on purpose. The gate answers "did the sensor
/// say yes"; this file answers "should the sensor have been asked at all".
/// Mixing the two is how lock screens end up prompting on every foreground
/// event, or never prompting after a reboot.
///
/// Product decisions encoded here (they are requirements, not defaults):
///
/// * Face ID is **off** on first launch. [AppLockSettings.initial] has
///   `biometricEnabled: false`, and nothing in this library turns it on by
///   itself.
/// * Turning biometrics off, or resetting a forgotten passcode, never touches
///   the Telegram session. [AppLockSettings.withBiometrics] and
///   [AppLockSettings.afterRecoveryReset] only touch lock fields.
/// * The passcode hint is a display string. It is never compared against
///   anything and cannot satisfy [LockRequirement].
library;

import '../security/passcode.dart';
import 'biometric.dart';
import 'tdlib_key.dart';

/// How long the app may stay in the background before the next foreground
/// requires unlocking. `immediately` is the strictest and the default.
enum AutoLockDelay { immediately, thirtySeconds, oneMinute, fiveMinutes }

extension AutoLockDelayValue on AutoLockDelay {
  Duration get duration => switch (this) {
        AutoLockDelay.immediately => Duration.zero,
        AutoLockDelay.thirtySeconds => const Duration(seconds: 30),
        AutoLockDelay.oneMinute => const Duration(minutes: 1),
        AutoLockDelay.fiveMinutes => const Duration(minutes: 5),
      };

  String get label => switch (this) {
        AutoLockDelay.immediately => '立即',
        AutoLockDelay.thirtySeconds => '30 秒后',
        AutoLockDelay.oneMinute => '1 分钟后',
        AutoLockDelay.fiveMinutes => '5 分钟后',
      };
}

/// What the user has configured. Persisted as JSON in the Keychain.
class AppLockSettings {
  const AppLockSettings({
    required this.biometricEnabled,
    required this.passcodeRecord,
    required this.autoLockDelay,
    required this.lockOnColdStart,
    required this.hint,
  });

  /// First launch: no lock at all. Collected into one constructor so tests can
  /// assert the default in a single line.
  static const AppLockSettings initial = AppLockSettings(
    biometricEnabled: false,
    passcodeRecord: null,
    autoLockDelay: AutoLockDelay.immediately,
    lockOnColdStart: true,
    hint: null,
  );

  final bool biometricEnabled;

  /// Encoded PBKDF2 verifier, or null when no passcode was ever set.
  final String? passcodeRecord;

  final AutoLockDelay autoLockDelay;

  /// Even with a long [autoLockDelay], a fresh process start asks again unless
  /// the user turned this off. A reboot is the case an attacker controls.
  final bool lockOnColdStart;

  /// Shown on the unlock screen. Never used as a credential.
  final String? hint;

  bool get passcodeEnabled =>
      passcodeRecord != null && passcodeRecord!.isNotEmpty;

  /// The lock is active when *something* can be demanded.
  bool get lockEnabled => passcodeEnabled || biometricEnabled;

  AppLockSettings copyWith({
    bool? biometricEnabled,
    Object? passcodeRecord = _sentinel,
    AutoLockDelay? autoLockDelay,
    bool? lockOnColdStart,
    Object? hint = _sentinel,
  }) {
    return AppLockSettings(
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      passcodeRecord: identical(passcodeRecord, _sentinel)
          ? this.passcodeRecord
          : passcodeRecord as String?,
      autoLockDelay: autoLockDelay ?? this.autoLockDelay,
      lockOnColdStart: lockOnColdStart ?? this.lockOnColdStart,
      hint: identical(hint, _sentinel) ? this.hint : hint as String?,
    );
  }

  /// Enabling biometrics requires a passcode to exist; otherwise a failed scan
  /// would leave no way in. Returns the unchanged settings when that is not the
  /// case, so the caller can surface "先设置应用密码".
  AppLockSettings withBiometrics(bool enabled) {
    if (!passcodeEnabled) return this;
    return copyWith(biometricEnabled: enabled);
  }

  /// Result of the "forgot passcode" flow. Drops the lock, keeps everything
  /// else — the Telegram session lives in a different store and is not touched
  /// here at all.
  AppLockSettings afterRecoveryReset() => const AppLockSettings(
        biometricEnabled: false,
        passcodeRecord: null,
        autoLockDelay: AutoLockDelay.immediately,
        lockOnColdStart: true,
        hint: null,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'biometricEnabled': biometricEnabled,
        'passcodeRecord': passcodeRecord,
        'autoLockDelay': autoLockDelay.name,
        'lockOnColdStart': lockOnColdStart,
        'hint': hint,
      };

  static AppLockSettings fromJson(Map<String, Object?> json) {
    final delayName = json['autoLockDelay'];
    return AppLockSettings(
      biometricEnabled: json['biometricEnabled'] == true,
      passcodeRecord: json['passcodeRecord'] as String?,
      autoLockDelay: AutoLockDelay.values.firstWhere(
        (d) => d.name == delayName,
        orElse: () => AutoLockDelay.immediately,
      ),
      lockOnColdStart: json['lockOnColdStart'] != false,
      hint: json['hint'] as String?,
    );
  }
}

const Object _sentinel = Object();

/// What the unlock screen must demand right now.
enum LockRequirement {
  /// Show the shell straight away.
  none,

  /// Offer the sensor, with the passcode field behind it.
  biometricThenPasscode,

  /// No sensor available for this attempt: passcode only.
  passcodeOnly,
}

extension LockRequirementMeaning on LockRequirement {
  bool get isLocked => this != LockRequirement.none;

  bool get wantsBiometric => this == LockRequirement.biometricThenPasscode;
}

/// Pure decision function. Every input is explicit so the matrix can be
/// enumerated in tests instead of discovered on a device.
class LockEvaluator {
  const LockEvaluator._();

  /// [coldStart] is true for the first frame of a process.
  /// [sinceBackground] is how long the app was not foreground, or null when it
  /// never left the foreground.
  /// [capability] is the live sensor state, not a cached one: the user can
  /// remove enrolment in Settings while the app is backgrounded.
  static LockRequirement decide({
    required AppLockSettings settings,
    required bool coldStart,
    required Duration? sinceBackground,
    required BiometricCapability capability,
  }) {
    if (!settings.lockEnabled) return LockRequirement.none;

    final bool needsUnlock;
    if (coldStart) {
      needsUnlock = settings.lockOnColdStart;
    } else if (sinceBackground == null) {
      needsUnlock = false;
    } else {
      needsUnlock = sinceBackground >= settings.autoLockDelay.duration;
    }
    if (!needsUnlock) return LockRequirement.none;

    // The passcode is the base requirement. Biometrics only ever shorten the
    // path to it: a device whose sensor is locked out, or whose enrolment was
    // removed in Settings while the app was backgrounded, still has to get in.
    // Demanding biometrics without a passcode behind them would be a lockout
    // waiting for the first unenrolled reboot.
    if (settings.passcodeEnabled) {
      if (settings.biometricEnabled && capability.canAuthenticate) {
        return LockRequirement.biometricThenPasscode;
      }
      return LockRequirement.passcodeOnly;
    }

    // Biometrics enabled without a passcode is rejected by
    // [AppLockSettings.withBiometrics], so this is only reachable from a
    // hand-edited store. Demanding nothing beats locking the user out of their
    // own app over a corrupted preference.
    return LockRequirement.none;
  }

  /// After a failed or cancelled scan, what should the screen show?
  ///
  /// A cancellation keeps the biometric button tappable; a hard failure hides
  /// it and moves focus to the passcode field, because re-prompting a locked
  /// sensor does nothing but annoy.
  static LockRequirement afterOutcome(
    BiometricOutcome outcome,
    AppLockSettings settings,
  ) {
    if (outcome.isSuccess) return LockRequirement.none;
    // Every non-success lands on the passcode — including a plain cancel.
    //
    // Returning `biometricThenPasscode` here meant "ask again", and once the
    // unlock screen re-armed the sheet on each transition into that phase (it
    // must, or a re-lock while the screen is up never prompts), a cancel
    // reopened the sheet immediately. That is a prompt loop with no way out.
    //
    // The sensor is still reachable: the unlock screen keeps its button visible
    // whenever the capability allows it, so retrying is a deliberate tap rather
    // than something the app does to the user.
    return LockRequirement.passcodeOnly;
  }
}

/// How the user gets back in after forgetting the app passcode.
///
/// The design constraint is "no silent permanent lockout". The only path that
/// satisfies it without weakening the lock is to re-authenticate against
/// Telegram: that is an authority the user actually holds, and it cannot be
/// produced by someone who merely picked up the phone.
class LockRecoveryPlan {
  const LockRecoveryPlan({
    required this.clearsPasscode,
    required this.keepsTelegramSession,
    required this.requiresTelegramReauth,
    required this.summary,
  });

  final bool clearsPasscode;
  final bool keepsTelegramSession;
  final bool requiresTelegramReauth;
  final String summary;

  /// The single recovery flow this build offers.
  static const LockRecoveryPlan telegramReauth = LockRecoveryPlan(
    clearsPasscode: true,
    keepsTelegramSession: false,
    requiresTelegramReauth: true,
    summary: '忘记应用密码时，只能用 Telegram 账号重新验证后重置应用锁。'
        '重置会关闭应用锁（Face ID 与密码），并要求重新登录 Telegram。'
        'Telegram 云端数据不会被修改。',
  );
}

/// Persistent side of the lock. Storage is a [SecretStore] so the same code
/// runs against the Keychain and against an in-memory map in tests.
class AppLockStore {
  AppLockStore({
    required this.store,
    PasscodeHasher? hasher,
    int? iterations,
  })  : hasher = hasher ?? PasscodeHasher(),
        iterations = iterations ?? PasscodeHasher.defaultIterations;

  /// Versioned slot: a future record shape gets a new key instead of being read
  /// as the old one and failing to decode.
  static const String storageKey = 'tg_app_lock_v1';

  final SecretStore store;
  final PasscodeHasher hasher;

  /// Cost used for newly created records. Tests lower it; the value is written
  /// into each record so verification always uses the record's own count.
  final int iterations;

  Future<AppLockSettings> load() async {
    final raw = await store.read(storageKey);
    if (raw == null || raw.isEmpty) return AppLockSettings.initial;
    try {
      return _decode(raw);
    } on Object {
      // A corrupted preference must not brick the app. Locking out the user
      // because of a bad JSON blob is worse than starting with no lock, and the
      // Telegram session is unaffected either way.
      return AppLockSettings.initial;
    }
  }

  Future<void> save(AppLockSettings settings) =>
      store.write(storageKey, _encode(settings));

  /// Sets or replaces the passcode. Returns the rejection reason when the input
  /// is unacceptable, and null on success.
  Future<PasscodeRejection?> setPasscode(
    String passcode, {
    AppLockSettings? current,
  }) async {
    final rejection = PasscodeHasher.validate(passcode);
    if (rejection != null) return rejection;
    final base = current ?? await load();
    final record = hasher.hash(passcode, iterations: iterations);
    await save(base.copyWith(passcodeRecord: record.encode()));
    return null;
  }

  /// Removes the passcode. Biometrics are switched off at the same time,
  /// because biometrics-without-passcode has no fallback.
  Future<AppLockSettings> clearPasscode() async {
    final current = await load();
    final cleared = current.copyWith(
      passcodeRecord: null,
      biometricEnabled: false,
      hint: null,
    );
    await save(cleared);
    return cleared;
  }

  /// Verifies a passcode against the stored verifier. False for a missing or
  /// unparsable record — never throws, never reports success on a broken store.
  Future<bool> verifyPasscode(String passcode, {AppLockSettings? settings}) async {
    final current = settings ?? await load();
    final record = current.passcodeRecord;
    if (record == null || record.isEmpty) return false;
    return hasher.verifyEncoded(record, passcode);
  }

  /// Applies [LockRecoveryPlan.telegramReauth] after Telegram has confirmed the
  /// user. Only lock fields change; the caller is responsible for the Telegram
  /// side.
  Future<AppLockSettings> applyRecoveryReset() async {
    final reset = AppLockSettings.initial;
    await save(reset);
    return reset;
  }

  /// JSON is encoded by hand: the payload is five fields, two of them nullable,
  /// and a real codec would drag `dart:convert` into the cold-start path for no
  /// benefit. Strings are escaped so a hint containing a quote survives.
  static String _encode(AppLockSettings settings) {
    final parts = <String>[
      '"biometricEnabled":${settings.biometricEnabled}',
      '"autoLockDelay":"${settings.autoLockDelay.name}"',
      '"lockOnColdStart":${settings.lockOnColdStart}',
      '"passcodeRecord":${_encodeNullable(settings.passcodeRecord)}',
      '"hint":${_encodeNullable(settings.hint)}',
    ];
    return '{${parts.join(',')}}';
  }

  static String _encodeNullable(String? value) {
    if (value == null) return 'null';
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$escaped"';
  }

  static AppLockSettings _decode(String raw) {
    return AppLockSettings(
      biometricEnabled: _readBool(raw, 'biometricEnabled') ?? false,
      passcodeRecord: _readString(raw, 'passcodeRecord'),
      autoLockDelay: AutoLockDelay.values.firstWhere(
        (d) => d.name == _readString(raw, 'autoLockDelay'),
        orElse: () => AutoLockDelay.immediately,
      ),
      lockOnColdStart: _readBool(raw, 'lockOnColdStart') ?? true,
      hint: _readString(raw, 'hint'),
    );
  }

  static bool? _readBool(String raw, String key) {
    final token = '"$key":';
    final at = raw.indexOf(token);
    if (at < 0) return null;
    final rest = raw.substring(at + token.length);
    if (rest.startsWith('true')) return true;
    if (rest.startsWith('false')) return false;
    return null;
  }

  static String? _readString(String raw, String key) {
    final token = '"$key":';
    final at = raw.indexOf(token);
    if (at < 0) return null;
    var i = at + token.length;
    if (i >= raw.length) return null;
    if (raw.startsWith('null', i)) return null;
    if (raw[i] != '"') return null;
    i++;
    final buffer = StringBuffer();
    while (i < raw.length) {
      final ch = raw[i];
      if (ch == '\\') {
        if (i + 1 >= raw.length) return null;
        final next = raw[i + 1];
        buffer.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          '"' => '"',
          '\\' => '\\',
          _ => next,
        });
        i += 2;
        continue;
      }
      if (ch == '"') return buffer.toString();
      buffer.write(ch);
      i++;
    }
    return null;
  }
}
