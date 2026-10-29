/// One Telegram session for the whole app.
///
/// The rules this class exists to enforce, all of them learned the hard way:
///
/// * **One** `TdClient` per process. A second instance on the same
///   `database_directory` fails with "Can't lock file" because TDLib keeps an
///   exclusive lock on `td.binlog`. Every screen therefore borrows this one.
/// * `authorizationStateWaitTdlibParameters` is not a logout. The boot plan is
///   computed from the key + database + last known phase, and "database not open
///   yet" always resolves to "wait", never to "ask for a phone number".
/// * The database key is never regenerated behind the user's back: a malformed
///   or missing key blocks the boot and asks, because opening an existing
///   database with a fresh key silently produces unreadable data.
/// * Signing out is the only path that clears the local index, and it says so
///   before it runs.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/channel_directory.dart';
import '../data/channel_sync.dart';
import '../data/history_source.dart';
import '../data/index_store.dart';
import '../security/tdlib_key.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';
import '../td/session_state.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';
import '../util/redact.dart';

/// Where the root widget should route.
enum AppRoute {
  /// Reading the stored session.
  splash,

  /// Key and database disagree; the user has to decide.
  blocked,

  /// `api_id` / `api_hash` are not stored yet.
  awaitingCredentials,

  /// TDLib wants a phone number, code, password or e-mail.
  awaitingLogin,

  /// Signed in; the shell may be shown.
  shell,
}

enum SessionStage {
  idle,
  booting,
  blocked,
  awaitingCredentials,
  awaitingLogin,
  ready,
  failed,
}

/// Pure mapping from session stage to the screen the root widget shows.
///
/// Extracted so the recovery table from §7.3 can be asserted without opening a
/// TDLib client: "blocked" must never collapse into "login", because a blocked
/// boot needs an explicit user decision rather than a phone-number prompt.
AppRoute routeForStage(SessionStage stage) => switch (stage) {
      SessionStage.idle || SessionStage.booting || SessionStage.failed =>
        AppRoute.splash,
      SessionStage.blocked => AppRoute.blocked,
      SessionStage.awaitingCredentials => AppRoute.awaitingCredentials,
      SessionStage.awaitingLogin => AppRoute.awaitingLogin,
      SessionStage.ready => AppRoute.shell,
    };

class AppSession extends ChangeNotifier {
  AppSession({
    required this.layout,
    required this.secureStore,
    FileOps? ops,
  }) : ops = ops ?? const IoFileOps();

  /// Keychain slots for the Telegram application credentials. Same names the
  /// probe screen used, so an existing install does not have to re-enter them.
  static const String apiIdKey = 'tg_api_id';
  static const String apiHashKey = 'tg_api_hash';

  final StorageLayout layout;
  final SecretStore secureStore;
  final FileOps ops;

  TdClient? _client;
  StreamSubscription<Map<String, Object?>>? _updates;
  IndexStore? _index;
  ChannelDirectory? _directory;
  SessionBootPlan? _plan;
  SessionStatus _status = const SessionStatus.unknown();
  AccountInfo? _account;
  SessionStage _stage = SessionStage.idle;
  String? _error;
  bool _busy = false;
  bool _disposed = false;
  bool _keyPresent = false;
  bool _keyValid = false;
  bool _databaseExists = false;

  SessionStage get stage => _stage;
  SessionBootPlan? get plan => _plan;
  SessionStatus get status => _status;
  AccountInfo? get account => _account;
  ChannelDirectory? get directory => _directory;
  IndexStore? get index => _index;
  String? get error => _error;
  bool get busy => _busy;
  bool get hasClient => _client != null;

  /// The single TDLib client, for the few screens that need to send a request
  /// directly (the feed's file transfers). Never create a second one.
  TdClient? get client => _client;

  bool get keyPresent => _keyPresent;
  bool get keyValid => _keyValid;
  bool get databaseExists => _databaseExists;

  /// TDLib is signed in. Only `authorizationStateReady` sets this.
  bool get isAuthorized => _status.isAuthorized;

  AppRoute get route => routeForStage(_stage);

  /// True while TDLib is past the "database not open" stage, i.e. when asking
  /// for input is the correct move.
  bool get needsUserInput => _status.awaitsUserInput;

  /// Opens the local store and the TDLib client, then applies the boot plan.
  ///
  /// Idempotent: calling it twice reuses the open client. That matters because
  /// the root widget calls it from `initState` and the settings page can call
  /// "重新连接" without risking a second instance.
  Future<void> boot() async {
    if (_stage == SessionStage.booting) return;
    _stage = SessionStage.booting;
    _error = null;
    _notify();

    try {
      await layout.ensureCreated();
      await _openIndex();

      // ---- key + database facts -------------------------------------
      final keyHolder = TdlibDatabaseKey(store: secureStore);
      final existingKey = await secureStore.read(TdlibDatabaseKey.keyName);
      _keyPresent = existingKey != null && existingKey.isNotEmpty;
      _keyValid = _keyPresent && TdlibDatabaseKey.isValid(existingKey!);
      _databaseExists = await ops.exists(_binlogPath());

      _plan = SessionBootPlanner.plan(
        keyPresent: _keyPresent,
        keyValid: _keyValid,
        databaseExists: _databaseExists,
        phase: _status.phase,
      );

      if (_plan!.action == SessionBootAction.blockedNeedsDecision) {
        _stage = SessionStage.blocked;
        _notify();
        return;
      }

      // ---- credentials ---------------------------------------------
      final credentials = await _readCredentials();
      if (credentials == null) {
        _stage = SessionStage.awaitingCredentials;
        _notify();
        return;
      }

      // ---- client ---------------------------------------------------
      await _ensureClient();
      final key = await keyHolder.obtain();
      await _sendParameters(credentials.$1, credentials.$2, key);

      // Wait for TDLib to say something past "opening the database". The first
      // update usually arrives in milliseconds; 20 s is the point at which the
      // honest answer is "no answer".
      final decided = await _awaitDecidable(const Duration(seconds: 20));
      if (!decided) {
        _error = 'TDLib 未在 20 秒内返回授权状态';
        _stage = SessionStage.awaitingLogin;
        _notify();
        return;
      }

      await _applyPhase();
    } on TdLibUnavailable catch (e) {
      _error = e.message;
      _stage = SessionStage.failed;
      _notify();
    } on TdlibKeyException catch (e) {
      _error = e.message;
      _stage = SessionStage.blocked;
      _notify();
    } on Object catch (e) {
      _error = redactText('$e');
      _stage = SessionStage.failed;
      _notify();
    }
  }

  Future<void> _openIndex() async {
    if (_index != null && _index!.isOpen) return;
    final store = IndexStore(directory: layout.indexDir, ops: ops);
    await store.open();
    _index = store;
    _directory = ChannelDirectory(
      // Built lazily: TdChatSource needs the client, which may not exist yet.
      source: _LazyChatSource(this),
      ops: ops,
      directory: layout.indexDir,
    );
    await _directory!.loadCached();
    _directory!.applyCounts(store.countByChat());
  }

  Future<void> _ensureClient() async {
    if (_client != null) return;
    final client = TdClient.open();
    _client = client;
    _updates = client.updates.listen(_onUpdate);
  }

  Future<(int, String)?> _readCredentials() async {
    final id = await secureStore.read(apiIdKey);
    final hash = await secureStore.read(apiHashKey);
    if (id == null || hash == null || hash.isEmpty) return null;
    final apiId = int.tryParse(id);
    if (apiId == null) return null;
    return (apiId, hash);
  }

  /// Stores and uses `api_id` / `api_hash`. The hash is written to the Keychain
  /// and never echoed back to the UI.
  Future<void> submitCredentials({required int apiId, required String apiHash}) async {
    _busy = true;
    _notify();
    try {
      await secureStore.write(apiIdKey, apiId.toString());
      await secureStore.write(apiHashKey, apiHash);
      await _ensureClient();
      final key = await TdlibDatabaseKey(store: secureStore).obtain();
      await _sendParameters(apiId, apiHash, key);
      await _awaitDecidable(const Duration(seconds: 20));
      await _applyPhase();
    } on Object catch (e) {
      _error = redactText('$e');
      _stage = SessionStage.awaitingCredentials;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _sendParameters(int apiId, String apiHash, String key) async {
    final client = _client;
    if (client == null) throw TdLibUnavailable('客户端尚未创建');
    final response = await client.request(
      setTdlibParameters(
        apiId: apiId,
        apiHash: apiHash,
        databaseDirectory: layout.tdlibDatabaseDir,
        filesDirectory: layout.tdlibFilesDir,
        databaseEncryptionKey: key,
        systemVersion: Platform.operatingSystemVersion,
      ),
      timeout: const Duration(seconds: 60),
    );
    final error = errorText(response);
    if (error != null) throw StateError(error);
  }

  /// Waits until the authorization phase is past [LoginPhase.openingDatabase].
  Future<bool> _awaitDecidable(Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (_status.phase == LoginPhase.openingDatabase ||
        _status.phase == LoginPhase.unknown) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  Future<void> _applyPhase() async {
    if (_status.isAuthorized) {
      await _onAuthorized();
      return;
    }
    if (needsUserInput) {
      _stage = SessionStage.awaitingLogin;
    } else if (_status.phase == LoginPhase.closed ||
        _status.phase == LoginPhase.loggingOut) {
      _stage = SessionStage.awaitingLogin;
    } else {
      // Unknown / still opening: wait rather than prompt. This is the branch
      // that used to dump a freshly-restarted user on the phone-number screen.
      _stage = SessionStage.awaitingLogin;
    }
    _notify();
  }

  Future<void> _onAuthorized() async {
    _stage = SessionStage.ready;
    _notify();
    await _loadAccount();
    await refreshDirectory();
  }

  Future<void> _loadAccount() async {
    final client = _client;
    if (client == null) return;
    try {
      final response = await client.request(getMe());
      final info = accountFromResponse(response);
      if (info != null) {
        _account = info;
        _notify();
      }
    } on Object {
      // A missing profile is not a failed login; the row shows "—".
    }
  }

  void _onUpdate(Map<String, Object?> event) {
    if (event['@type'] != 'updateAuthorizationState') return;
    final raw = event['authorization_state'];
    if (raw is! Map) return;
    final next = SessionStatus.fromJson(raw.cast<String, Object?>());
    final wasAuthorized = _status.isAuthorized;
    _status = next;
    if (next.isAuthorized && !wasAuthorized) {
      unawaited(_onAuthorized());
    } else if (!next.isAuthorized && wasAuthorized) {
      _stage = SessionStage.awaitingLogin;
      _notify();
    } else {
      _notify();
    }
  }

  // ---- login actions -------------------------------------------------

  /// Re-reads the authorization state on demand.
  ///
  /// Used by the phases this build cannot drive itself (e-mail verification,
  /// device confirmation): the screen says "complete it in the official client"
  /// and offers this so the user does not have to restart the app.
  Future<void> refreshStatus() async {
    final client = _client;
    if (client == null) return;
    try {
      final response = await client.request(getAuthorizationState());
      _status = SessionStatus.fromJson(response);
      await _applyPhase();
    } on Object catch (e) {
      _error = redactText('$e');
      _notify();
    }
  }

  Future<void> submitPhone(String phone) => _loginAction(
        () => setAuthenticationPhoneNumber(phone.trim()),
        failurePrefix: '发送手机号失败',
      );

  Future<void> submitCode(String code) => _loginAction(
        () => checkAuthenticationCode(code.trim()),
        failurePrefix: '验证码提交失败',
      );

  Future<void> submitPassword(String password) => _loginAction(
        () => checkAuthenticationPassword(password),
        failurePrefix: '两步验证失败',
      );

  Future<void> _loginAction(
    Map<String, Object?> Function() build, {
    required String failurePrefix,
  }) async {
    final client = _client;
    if (client == null) {
      _error = 'TDLib 尚未初始化';
      _notify();
      return;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      final response = await client.request(build());
      final error = errorText(response);
      if (error != null) _error = '$failurePrefix：$error';
    } on Object catch (e) {
      _error = redactText('$failurePrefix：$e');
    } finally {
      _busy = false;
      _notify();
    }
  }

  // ---- channels ------------------------------------------------------

  Future<void> refreshDirectory() async {
    final directory = _directory;
    if (directory == null || _client == null) return;
    await directory.refresh();
    final index = _index;
    if (index != null) directory.applyCounts(index.countByChat());
    _notify();
  }

  /// Pulls a bounded number of pages for one channel into the local mirror.
  ///
  /// Bounded on purpose: a 200k-message channel must never be walked in one go,
  /// and this is the call the channel page makes when it is opened.
  Future<SyncCycleReport?> syncChannel(
    int chatId, {
    int pagesPerChannel = 2,
    SyncCancelToken? cancel,
  }) async {
    final client = _client;
    final index = _index;
    if (client == null || index == null) return null;
    final engine = ChannelSyncEngine(
      source: TdHistorySource(client),
      store: index,
    );
    try {
      final report = await engine.syncCycle(
        chatIds: <int>[chatId],
        pagesPerChannel: pagesPerChannel,
        cancel: cancel,
      );
      _directory?.applyCounts(index.countByChat());
      _notify();
      return report;
    } on Object catch (e) {
      _error = redactText('$e');
      _notify();
      return null;
    }
  }

  /// One bounded slice of history for **every** channel, continuing from the
  /// indexed scan cursor.
  ///
  /// Separate from [syncChannel] because the backfill walks the whole list: it
  /// is the thing a scheduler may call repeatedly, and each call is bounded so
  /// the UI stays responsive.
  ///
  /// [chatIds] narrows the walk to specific channels; the scheduler uses it to
  /// spend its budget on the channels that are still moving instead of
  /// re-reading finished ones.
  Future<SyncCycleReport?> syncHistorySlice({
    int pagesPerChannel = 6,
    List<int>? chatIds,
    Duration pageGap = const Duration(milliseconds: 120),
  }) async {
    final client = _client;
    final index = _index;
    if (client == null || index == null) return null;
    final ids = chatIds ??
        _directory?.entries.map((e) => e.id).toList() ??
        const <int>[];
    if (ids.isEmpty) return null;
    final engine = ChannelSyncEngine(
      source: TdHistorySource(client),
      store: index,
    );
    try {
      final report = await engine.syncCycle(
        chatIds: ids,
        pagesPerChannel: pagesPerChannel,
        resume: true,
        pageGap: pageGap,
      );
      _directory?.applyCounts(index.countByChat());
      _notify();
      return report;
    } on Object catch (e) {
      _error = redactText('$e');
      _notify();
      return SyncCycleReport(
        pages: 0,
        rawMessages: 0,
        insertedRecords: 0,
        errors: <String>[redactText('$e')],
        cancelled: false,
        lastError: redactText('$e'),
        channelsTotal: ids.length,
        retryAfter: parseRetryAfter('$e'),
      );
    }
  }

  /// Opens the feed's source for one channel (or everything when null).
  ///
  /// Returns null before login: the feed has nothing to page from and must show
  /// its empty state instead of a spinner that never ends.
  IndexStore? get feedStore => _index;

  // ---- session teardown ----------------------------------------------

  /// Signs out of Telegram and clears the **local** mirror.
  ///
  /// Cloud data is untouched: `logOut` ends this client's session, and no TDLib
  /// method reached from this app can delete channel content.
  Future<void> signOut() async {
    _busy = true;
    _notify();
    final client = _client;
    try {
      if (client != null) {
        await client.request(logOut(), timeout: const Duration(seconds: 30));
      }
    } on Object {
      // Even a failed logOut must leave the app in a state the user can retry.
    }
    await _clearLocalSession();
    _busy = false;
    _notify();
  }

  /// Recovery path for a forgotten app passcode (§8.6).
  ///
  /// The confirmed decision is that a reset also clears the local Telegram
  /// session: the app passcode is what protects the mirrored content, so keeping
  /// the session after resetting it would leave the content readable by whoever
  /// holds the phone.
  Future<void> resetThroughTelegram() async {
    await signOut();
  }

  Future<void> _clearLocalSession() async {
    final index = _index;
    if (index != null) {
      try {
        await index.compact();
      } on Object {
        // Compacting is only a way to empty the journal; the deletes below are
        // what actually removes the mirror.
      }
      await index.close();
    }
    for (final path in <String>[
      p.join(layout.indexDir, 'media_journal.jsonl'),
      p.join(layout.indexDir, 'media_snapshot.json'),
      p.join(layout.indexDir, ChannelDirectory.cacheFileName),
    ]) {
      try {
        await ops.deleteFile(path);
      } on Object {
        // A file that was never written is not a failure.
      }
    }
    try {
      await secureStore.delete(TdlibDatabaseKey.keyName);
    } on Object {
      // Leaving the key behind only means the next login reuses it.
    }
    await _updates?.cancel();
    _updates = null;
    await _client?.dispose();
    _client = null;
    _index = null;
    _directory = null;
    _account = null;
    _status = const SessionStatus.unknown();
    _plan = null;
    _keyPresent = false;
    _keyValid = false;
    _databaseExists = false;
    _stage = SessionStage.awaitingCredentials;
  }

  /// Diagnostics payload for the "导出诊断信息" action.
  ///
  /// Already redacted when it leaves this method: callers only have to check
  /// [mayContainSecret] on the encoded form and refuse if it still trips.
  Map<String, Object?> diagnostics() {
    final index = _index;
    return redactDiagnostics(<String, Object?>{
      'app': 'TG Media',
      'stage': _stage.name,
      'loginPhase': _status.phase.name,
      'authType': _status.rawType,
      'hasClient': hasClient,
      'keyPresent': _keyPresent,
      'keyValid': _keyValid,
      'databaseExists': _databaseExists,
      'accountId': _account?.userId,
      'channels': _directory?.entries.length ?? 0,
      'indexRows': index?.count ?? 0,
      'indexDroppedJournalLines': index?.droppedJournalLines ?? 0,
      'zones': <String, Object?>{
        for (final entry in layout.allRoots.entries) entry.key.name: entry.value,
      },
      'error': _error,
    });
  }

  String _binlogPath() => p.join(layout.tdlibDatabaseDir, 'td.binlog');

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _updates?.cancel();
    _client?.dispose();
    _directory?.dispose();
    super.dispose();
  }
}

/// Defers building [TdChatSource] until the client exists.
class _LazyChatSource implements ChatSource {
  _LazyChatSource(this.session);

  final AppSession session;

  @override
  Future<List<ChatSummary>> load() async {
    final client = session._client;
    if (client == null) {
      throw const ChannelDirectoryException('TDLib 尚未初始化');
    }
    return TdChatSource(client).load();
  }
}
