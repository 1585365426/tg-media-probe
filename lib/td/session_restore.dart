/// Automatic session restore on launch.
///
/// Why this exists: `main()` only builds the services that do not need
/// Telegram, and the TDLib client used to be created exclusively by the sign-in
/// screen. Every cold start therefore began with `hasClient == false`, the
/// channel tab showed "尚未登录", and the only way in was to re-run the whole
/// flow by hand — even though TDLib already had the session on disk and answers
/// `authorizationStateReady` as soon as it is configured against that
/// directory. The login code was never re-requested; the *screen* was.
///
/// What this does **not** change:
/// * the database still lives in `StorageZone.authMeta` and is still encrypted
///   with the Keychain-held key ([TdlibDatabaseKey]);
/// * no credential moves anywhere new — `api_id` / `api_hash` are read from the
///   Keychain entries the sign-in screen already created;
/// * a missing, empty or unreadable database is reported as
///   [RestoreOutcome.needsLogin]. It is never papered over with a fresh key,
///   because overwriting the key would make an existing database unreadable.
library;

import 'dart:async';
import 'dart:io';

import '../security/tdlib_key.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';
import 'td_client.dart';
import 'td_models.dart';
import 'td_requests.dart';

/// How far an automatic restore got.
enum RestoreOutcome {
  /// TDLib answered `authorizationStateReady`: the session is live and the app
  /// can go straight to the shell.
  restored,

  /// The local database is valid but Telegram wants one more step (a login
  /// code, the 2FA password, or confirmation on another device). The session
  /// must be handed to the sign-in screen so it can continue on the same
  /// client instead of opening a second one against the same database.
  needsInteraction,

  /// No usable local session: fresh install, or the session was terminated
  /// from another client. Sign-in starts from the phone number.
  needsLogin,

  /// Restore could not be attempted at all — no saved credentials, TDLib not
  /// linked, Keychain unreadable. The shell still works for local features.
  unavailable,
}

/// Outcome plus, when relevant, the live client the caller now owns.
///
/// **Ownership rule:** if [session] is non-null the caller must either hand it
/// to `AppServices.attachClient` (or the sign-in screen) or dispose it. Leaving
/// it unreferenced keeps TDLib's `td.binlog` file lock held, and the next
/// `setTdlibParameters` against the same directory fails with
/// `error 400: Can't lock file ... already in use`.
class RestoreResult {
  const RestoreResult(
    this.outcome, {
    this.session,
    this.stage = AuthStage.unknown,
    this.message = '',
  });

  final RestoreOutcome outcome;
  final TdSession? session;
  final AuthStage stage;
  final String message;

  /// The concrete client, when one was opened. Restore always opens a real
  /// [TdClient] in production; tests substitute a [TdSession].
  TdClient? get client => session is TdClient ? session as TdClient : null;

  @override
  String toString() => 'RestoreResult(${outcome.name}, stage=${stage.name})'
      '${message.isEmpty ? '' : ' $message'}';
}

/// Folds the raw authorization-state stream into a single decision.
///
/// The subtle part is `authorizationStateWaitTdlibParameters`: TDLib emits it
/// *before* the database has been opened, so it says nothing about whether the
/// stored session is valid. Treating it as "logged out" is exactly the mistake
/// that makes an app ask for a phone number on every launch, so it is ignored.
/// Every other known state is a real decision and is latched — a later
/// `waitTdlibParameters` (TDLib reconnecting) cannot undo `ready`.
class AuthStageTracker {
  AuthStage? _decided;

  /// Feeds one raw `@type`. Returns the decision, or null to keep waiting.
  AuthStage? accept(String rawType) {
    final decided = _decided;
    if (decided != null) return decided;

    final stage = AuthState(rawType).stage;
    if (stage == AuthStage.unknown) return null;
    if (stage == AuthStage.waitTdlibParameters) return null;

    _decided = stage;
    return stage;
  }

  AuthStage? get decision => _decided;

  /// Maps a decided stage onto what the app should do about it.
  static RestoreOutcome outcomeFor(AuthStage stage) => switch (stage) {
        AuthStage.ready => RestoreOutcome.restored,
        AuthStage.waitCode ||
        AuthStage.waitPassword ||
        AuthStage.waitOtherDeviceConfirmation =>
          RestoreOutcome.needsInteraction,
        _ => RestoreOutcome.needsLogin,
      };
}

/// Reasons a restore is refused before any client is opened. Pure, so the
/// decision is unit-testable without a Keychain or a database.
enum RestoreRefusal {
  /// Nothing saved in the Keychain: this device has never completed a sign-in.
  noCredentials,

  /// `api_id` is saved but is not a number — the Keychain blob is corrupt.
  malformedCredentials,

  /// The database directory is missing or empty; TDLib would start from zero.
  noSessionFiles,
}

/// Decides whether opening a client is worth it.
///
/// Returns null when restore should proceed.
RestoreRefusal? planRestore({
  required String? apiId,
  required String? apiHash,
  required bool hasSessionFiles,
}) {
  final id = int.tryParse((apiId ?? '').trim());
  final hash = (apiHash ?? '').trim();
  if (id == null || id <= 0) {
    return apiId == null || apiId.trim().isEmpty
        ? RestoreRefusal.noCredentials
        : RestoreRefusal.malformedCredentials;
  }
  if (hash.isEmpty) return RestoreRefusal.noCredentials;
  if (!hasSessionFiles) return RestoreRefusal.noSessionFiles;
  return null;
}

String describeRefusal(RestoreRefusal refusal) => switch (refusal) {
      RestoreRefusal.noCredentials => '本机还没有保存过 Telegram 登录凭据',
      RestoreRefusal.malformedCredentials => '钥匙串里的 api_id 格式不正确',
      RestoreRefusal.noSessionFiles => '本机没有可恢复的会话数据库',
    };

class SessionRestore {
  SessionRestore({
    required this.layout,
    required this.secrets,
    this.ops = const IoFileOps(),
    this.openSession,
    this.timeout = const Duration(seconds: 25),
  });

  /// Keychain slots written by the sign-in screen. Duplicated here on purpose
  /// rather than imported from the widget layer: a UI file is the wrong place
  /// for a storage key other code depends on.
  static const String apiIdKey = 'tg_api_id';
  static const String apiHashKey = 'tg_api_hash';

  final StorageLayout layout;
  final SecretStore secrets;
  final FileOps ops;

  /// Injected for tests; production opens the real native client.
  final TdSession Function()? openSession;

  /// How long TDLib may take to open the database and report its state. A cold
  /// read of a large `td.binlog` is the slow part; 25 s is generous without
  /// making a hung launch look like a freeze.
  final Duration timeout;

  Future<RestoreResult> run() async {
    final apiIdRaw = await _readSafely(apiIdKey);
    final apiHashRaw = await _readSafely(apiHashKey);
    final hasFiles = await hasSessionFiles();

    final refusal = planRestore(
      apiId: apiIdRaw,
      apiHash: apiHashRaw,
      hasSessionFiles: hasFiles,
    );
    if (refusal != null) {
      return RestoreResult(
        // "No credentials" is simply a first run; the sign-in screen prefills
        // nothing but works normally. "No session files" with valid
        // credentials means the database was lost, which also lands on the
        // sign-in screen — the outcome is the same, the message differs.
        RestoreOutcome.unavailable,
        message: describeRefusal(refusal),
      );
    }

    final apiId = int.parse(apiIdRaw!.trim());
    final apiHash = apiHashRaw!.trim();

    final String dbKey;
    try {
      // obtain() returns the existing key; only a device that never stored one
      // gets a fresh value. Refusing on a malformed key (rather than
      // regenerating) is what keeps a readable database readable.
      dbKey = await TdlibDatabaseKey(store: secrets).obtain();
    } on TdlibKeyException catch (e) {
      return RestoreResult(RestoreOutcome.unavailable, message: e.message);
    } catch (e) {
      return RestoreResult(
        RestoreOutcome.unavailable,
        message: '钥匙串读取失败：$e',
      );
    }

    final TdSession session;
    try {
      session = (openSession ?? TdClient.open)();
    } catch (e) {
      return RestoreResult(
        RestoreOutcome.unavailable,
        message: 'TDLib 未能加载：$e',
      );
    }

    final tracker = AuthStageTracker();
    final decided = Completer<AuthStage>();

    void feed(Map<String, Object?> json) {
      final type = json['@type'];
      String? rawType;
      if (type == 'updateAuthorizationState') {
        final state = json['authorization_state'];
        if (state is Map) {
          rawType = AuthState.fromJson(state.cast<String, Object?>()).rawType;
        }
      } else if (type is String && type.startsWith('authorizationState')) {
        // getAuthorizationState answers with the state object itself, not
        // wrapped in an update.
        rawType = type;
      }
      if (rawType == null) return;
      final stage = tracker.accept(rawType);
      if (stage != null && !decided.isCompleted) decided.complete(stage);
    }

    // Subscribe *before* configuring: TDLib pushes the state as soon as the
    // database is open, and a broadcast stream drops anything published before
    // the listener exists.
    final sub = session.updates.listen(feed);

    try {
      final configure = await session.request(
        setTdlibParameters(
          apiId: apiId,
          apiHash: apiHash,
          databaseDirectory: layout.tdlibDatabaseDir,
          filesDirectory: layout.tdlibFilesDir,
          databaseEncryptionKey: dbKey,
          systemVersion: Platform.operatingSystemVersion,
        ),
        timeout: timeout,
      );
      final err = errorText(configure);
      if (err != null) {
        await _abandon(session, sub);
        return RestoreResult(
          RestoreOutcome.unavailable,
          message: err,
        );
      }

      // Belt and braces: ask once directly. If the pushed update already
      // decided, this is a no-op; if it was missed, this is the only way to
      // learn that the session is ready.
      try {
        final state = await session.request(
          getAuthorizationState(),
          timeout: const Duration(seconds: 10),
        );
        feed(state);
      } catch (_) {
        // The push path still governs; a slow answer here is not fatal.
      }

      final stage = await decided.future.timeout(
        timeout,
        onTimeout: () => AuthStage.unknown,
      );
      if (stage == AuthStage.unknown) {
        await _abandon(session, sub);
        return RestoreResult(
          RestoreOutcome.unavailable,
          message: 'TDLib 在 ${timeout.inSeconds}s 内没有报告登录状态',
        );
      }

      final outcome = AuthStageTracker.outcomeFor(stage);
      if (outcome == RestoreOutcome.restored) {
        // The caller keeps the client and the subscription lifetime is tied to
        // the client, so dropping this listener is safe: AppServices re-reads
        // state through the client itself.
        await sub.cancel();
        return RestoreResult(outcome, session: session, stage: stage);
      }

      // needsInteraction / needsLogin: hand the live client over. Opening a
      // second client against the same database is what produced
      // `error 400: Can't lock file td.binlog` on device.
      await sub.cancel();
      return RestoreResult(
        outcome,
        session: session,
        stage: stage,
        message: switch (outcome) {
          RestoreOutcome.needsInteraction => '会话仍有效，需要补充验证',
          _ => '会话已失效，需要重新登录',
        },
      );
    } catch (e) {
      await _abandon(session, sub);
      return RestoreResult(
        RestoreOutcome.unavailable,
        message: '恢复登录状态失败：$e',
      );
    }
  }

  /// True when the database directory holds anything at all.
  ///
  /// Deliberately not `File('td.binlog').exists()`: TDLib has renamed that file
  /// across versions (and keeps side files next to it), so pinning the name
  /// would silently report "no session" after a TDLib upgrade — the very bug
  /// this file exists to fix.
  Future<bool> hasSessionFiles() async {
    try {
      final files = await ops.listFilesRecursive(layout.tdlibDatabaseDir);
      return files.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _readSafely(String key) async {
    try {
      return await secrets.read(key);
    } catch (_) {
      // Keychain locked before first unlock after a reboot: report it as
      // missing rather than crashing the launch.
      return null;
    }
  }

  Future<void> _abandon(TdSession session, StreamSubscription<Object?> sub) async {
    await sub.cancel();
    await session.dispose();
  }
}
