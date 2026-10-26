/// TDLib authorization state, mapped to the handful of decisions the app
/// actually makes.
///
/// The one mistake this file exists to prevent: treating
/// `authorizationStateWaitTdlibParameters` as "logged out". That state arrives
/// **before** the local database is open, so it says nothing about whether the
/// stored session is still valid. Acting on it means asking for a phone number
/// on every cold start even though the session is sitting on disk, which is
/// exactly the bug this layer was written after.
///
/// Nothing here fabricates an authorization state. The app is logged in when
/// TDLib says `authorizationStateReady`, and not before.
library;

/// Login phase as reported by TDLib, plus two local states.
enum LoginPhase {
  /// `authorizationStateWaitTdlibParameters`: the client has not opened its
  /// database yet. **Not** a logout — a decision cannot be made at this point.
  openingDatabase,

  waitingPhoneNumber,
  waitingCode,
  waitingPassword,
  waitingEmailAddress,
  waitingEmailCode,
  waitingRegistration,
  waitingOtherDevice,

  /// Some flows require a premium purchase or terms acceptance before login.
  waitingPremiumPurchase,

  ready,
  loggingOut,
  closed,

  /// A state this build does not know, or a missing `@type`.
  unknown,
}

/// Parsed authorization state, including the fields the UI needs to render an
/// honest prompt (the 2FA hint comes from Telegram, not from us).
class SessionStatus {
  const SessionStatus({
    required this.phase,
    this.rawType = '',
    this.passwordHint,
    this.hasRecoveryEmail = false,
  });

  const SessionStatus.unknown()
      : phase = LoginPhase.unknown,
        rawType = '',
        passwordHint = null,
        hasRecoveryEmail = false;

  final LoginPhase phase;

  /// Verbatim `@type`, kept for diagnostics and for the "unknown state" screen.
  final String rawType;

  /// `password_hint` from `authorizationStateWaitPassword`. Display only.
  final String? passwordHint;

  final bool hasRecoveryEmail;

  bool get isAuthorized => phase == LoginPhase.ready;

  /// True once TDLib is past the "database not open" stage and has told us
  /// something actionable.
  bool get isDecidable => phase != LoginPhase.openingDatabase;

  bool get awaitsUserInput => needsUserActionFor(phase);

  String get title => describeLoginPhase(phase);

  SessionStatus copyWith({LoginPhase? phase}) => SessionStatus(
        phase: phase ?? this.phase,
        rawType: rawType,
        passwordHint: passwordHint,
        hasRecoveryEmail: hasRecoveryEmail,
      );

  static SessionStatus fromJson(Map<String, Object?> json) {
    final type = json['@type'];
    final rawType = type is String ? type : '';
    final hint = json['password_hint'];

    return SessionStatus(
      phase: phaseForType(rawType),
      rawType: rawType,
      passwordHint: hint is String && hint.isNotEmpty ? hint : null,
      hasRecoveryEmail: json['has_recovery_email_address'] == true,
    );
  }

  static LoginPhase phaseForType(String rawType) => switch (rawType) {
        'authorizationStateWaitTdlibParameters' => LoginPhase.openingDatabase,
        'authorizationStateWaitPhoneNumber' => LoginPhase.waitingPhoneNumber,
        'authorizationStateWaitCode' => LoginPhase.waitingCode,
        'authorizationStateWaitPassword' => LoginPhase.waitingPassword,
        'authorizationStateWaitEmailAddress' => LoginPhase.waitingEmailAddress,
        'authorizationStateWaitEmailCode' => LoginPhase.waitingEmailCode,
        'authorizationStateWaitRegistration' => LoginPhase.waitingRegistration,
        'authorizationStateWaitOtherDeviceConfirmation' =>
          LoginPhase.waitingOtherDevice,
        'authorizationStateWaitPremiumPurchase' =>
          LoginPhase.waitingPremiumPurchase,
        'authorizationStateReady' => LoginPhase.ready,
        'authorizationStateLoggingOut' => LoginPhase.loggingOut,
        'authorizationStateClosed' => LoginPhase.closed,
        _ => LoginPhase.unknown,
      };

  @override
  String toString() => 'SessionStatus(${phase.name}${rawType.isEmpty ? '' : ' / $rawType'})';
}

/// Phases where the app must show a login screen because TDLib needs input.
bool needsUserActionFor(LoginPhase phase) => switch (phase) {
      LoginPhase.waitingPhoneNumber ||
      LoginPhase.waitingCode ||
      LoginPhase.waitingPassword ||
      LoginPhase.waitingEmailAddress ||
      LoginPhase.waitingEmailCode ||
      LoginPhase.waitingRegistration ||
      LoginPhase.waitingOtherDevice ||
      LoginPhase.waitingPremiumPurchase =>
        true,
      LoginPhase.openingDatabase ||
      LoginPhase.ready ||
      LoginPhase.loggingOut ||
      LoginPhase.closed ||
      LoginPhase.unknown =>
        false,
    };

/// Chinese label for each phase. Kept next to the enum so the wording cannot
/// drift away from the state that produced it.
String describeLoginPhase(LoginPhase phase) => switch (phase) {
      LoginPhase.openingDatabase => '正在打开本地会话',
      LoginPhase.waitingPhoneNumber => '等待输入手机号',
      LoginPhase.waitingCode => '等待验证码',
      LoginPhase.waitingPassword => '等待两步验证密码',
      LoginPhase.waitingEmailAddress => '等待邮箱地址',
      LoginPhase.waitingEmailCode => '等待邮箱验证码',
      LoginPhase.waitingRegistration => '等待填写注册信息',
      LoginPhase.waitingOtherDevice => '等待其他设备确认登录',
      LoginPhase.waitingPremiumPurchase => '该账号需要在 Telegram 中完成额外验证',
      LoginPhase.ready => '已登录',
      LoginPhase.loggingOut => '正在退出登录',
      LoginPhase.closed => '会话已关闭',
      LoginPhase.unknown => '会话状态未知',
    };

/// What the app should do at start-up.
enum SessionBootAction {
  /// Open the existing client and go straight to the shell. TDLib may still be
  /// opening its database, and `authorizationStateReady` is expected to follow.
  resumeSilently,

  /// Open the existing client and route to the login screen once TDLib reports
  /// an input-taking phase. The client is reused, never recreated: a second
  /// instance on the same `database_directory` fails with "Can't lock file".
  routeToLogin,

  /// The local database cannot be opened with what is in the Keychain. Requires
  /// a user decision, not a silent recovery: generating a fresh key would make
  /// the existing database unreadable while appearing to work.
  blockedNeedsDecision,
}

class SessionBootPlan {
  const SessionBootPlan({
    required this.action,
    required this.reason,
    this.needsUserConfirmation = false,
  });

  final SessionBootAction action;

  /// User-facing explanation. Never invents a cause: each branch corresponds to
  /// a condition that was actually checked.
  final String reason;

  /// True for [SessionBootAction.blockedNeedsDecision], where the only safe
  /// options are "re-login and lose the local database" or "restore the key".
  final bool needsUserConfirmation;

  @override
  String toString() => 'SessionBootPlan(${action.name}: $reason)';
}

/// Decides what to do with the persisted session.
///
/// Inputs are facts read from the device, not guesses:
/// * [keyPresent] / [keyValid] — the TDLib database key in the Keychain.
/// * [databaseExists] — whether `authMeta/tdlib/db/td.binlog` is on disk.
/// * [phase] — the last authorization state seen, or
///   [LoginPhase.openingDatabase] before the first update arrives.
class SessionBootPlanner {
  const SessionBootPlanner._();

  static SessionBootPlan plan({
    required bool keyPresent,
    required bool keyValid,
    required bool databaseExists,
    required LoginPhase phase,
  }) {
    if (keyPresent && !keyValid) {
      return const SessionBootPlan(
        action: SessionBootAction.blockedNeedsDecision,
        reason: '本地会话密钥格式异常。为避免让现有会话数据不可读，'
            '不会自动重建密钥。可以选择重新登录（会重建本地会话数据，'
            'Telegram 云端消息不受影响），或恢复原有密钥。',
        needsUserConfirmation: true,
      );
    }

    if (!keyPresent && databaseExists) {
      return const SessionBootPlan(
        action: SessionBootAction.blockedNeedsDecision,
        reason: '检测到本地会话数据，但缺少对应的密钥。'
            '用新密钥打开旧数据库只会得到无法读取的数据。'
            '选择重新登录会重建本地会话数据，Telegram 云端消息不受影响。',
        needsUserConfirmation: true,
      );
    }

    if (!keyPresent && !databaseExists) {
      return const SessionBootPlan(
        action: SessionBootAction.routeToLogin,
        reason: '首次启动，需要登录 Telegram。',
      );
    }

    // Key present and database present: reuse them. The phase decides whether
    // a login screen is needed, and "database not open yet" is not a verdict.
    if (phase == LoginPhase.ready) {
      return const SessionBootPlan(
        action: SessionBootAction.resumeSilently,
        reason: '已恢复本地会话（authorizationStateReady）。',
      );
    }

    if (phase == LoginPhase.openingDatabase) {
      return const SessionBootPlan(
        action: SessionBootAction.resumeSilently,
        reason: '正在打开本地会话，等待 Telegram 返回授权状态。',
      );
    }

    if (phase == LoginPhase.loggingOut) {
      return const SessionBootPlan(
        action: SessionBootAction.routeToLogin,
        reason: '上一次会话正在退出登录，需要重新登录。',
      );
    }

    if (phase == LoginPhase.closed) {
      return const SessionBootPlan(
        action: SessionBootAction.routeToLogin,
        reason: '上一次会话已关闭，需要重新登录。',
      );
    }

    if (needsUserActionFor(phase)) {
      return SessionBootPlan(
        action: SessionBootAction.routeToLogin,
        reason: 'Telegram 要求重新验证：${describeLoginPhase(phase)}。',
      );
    }

    // Unknown state: ask TDLib again rather than guess. Routing to login here
    // would prompt a user whose session may still be perfectly valid.
    return const SessionBootPlan(
      action: SessionBootAction.resumeSilently,
      reason: '会话状态未知，已打开本地会话并等待 Telegram 返回状态。',
    );
  }
}

/// Whether a re-login is allowed to discard the local database.
///
/// Only when the user explicitly confirms, and only for the local mirror. The
/// cloud copy is never touched — no TDLib method in this app can delete it.
class ReloginConsent {
  const ReloginConsent({
    required this.confirmed,
    required this.discardsLocalDatabase,
    required this.keepsCloudData,
    required this.summary,
  });

  final bool confirmed;
  final bool discardsLocalDatabase;
  final bool keepsCloudData;
  final String summary;

  static const ReloginConsent prompt = ReloginConsent(
    confirmed: false,
    discardsLocalDatabase: true,
    keepsCloudData: true,
    summary: '重新登录会重建本地的 Telegram 会话数据与媒体索引，'
        '之后再按需从云端重新同步。Telegram 云端的频道消息与媒体不会被删除或修改。',
  );
}
