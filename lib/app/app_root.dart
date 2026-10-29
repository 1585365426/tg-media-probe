/// Application root: services, routing gate, and the two-tab shell.
///
/// The gate order is the product decision, not an implementation detail:
///
/// ```
/// 读取设置 -> 应用锁（Face ID / 密码） -> Telegram 会话 -> 主界面
/// ```
///
/// The lock comes before the session so a locked app never paints a channel
/// title. The session is opened in the background while the lock is on screen,
/// because opening TDLib is the slow part and the unlock screen does not need it.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../download/cache_validator.dart';
import '../download/download_manager.dart';
import '../download/media_cache.dart';
import '../lock/lock_screens.dart';
import '../lock/unlock_controller.dart';
import '../platform/orientation_coordinator.dart';
import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../security/tdlib_key.dart';
import '../storage/app_paths.dart';
import '../ui/app_theme.dart';
import '../ui/channel_page.dart';
import '../ui/login_page.dart';
import '../ui/settings_page.dart';
import '../ui/status_view.dart';
import '../util/redact.dart';
import 'app_preferences.dart';
import 'app_session.dart';
import 'history_backfill.dart';

/// Holds portrait for every route that is not the player.
///
/// The player pushes its own landscape scope on top and restores portrait when
/// it leaves, so this host only has to guarantee the default.
class _PortraitHost extends StatefulWidget {
  const _PortraitHost({required this.child});

  final Widget child;

  @override
  State<_PortraitHost> createState() => _PortraitHostState();
}

class _PortraitHostState extends State<_PortraitHost> {
  final OrientationCoordinator _coordinator = OrientationCoordinator.instance;

  @override
  void initState() {
    super.initState();
    _coordinator.set(
      OrientationCoordinator.appOwner,
      OrientationIntent.nonPlaybackPortrait,
    );
  }

  @override
  void dispose() {
    _coordinator.clear(OrientationCoordinator.appOwner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Resolves the single TdClient at call time: the manager is constructed before
/// TDLib finishes booting, and a transport holding a captured null would never
/// recover from that.
class _SessionTransport implements TdTransport {
  _SessionTransport(this._session);

  final AppSession _session;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) {
    final client = _session.client;
    if (client == null) {
      throw StateError('TDLib 尚未就绪');
    }
    return client.request(
      request,
      timeout: timeout ?? const Duration(seconds: 30),
    );
  }

  @override
  Stream<Map<String, Object?>> get updates =>
      _session.client?.updates ?? const Stream<Map<String, Object?>>.empty();
}

class TgMediaApp extends StatefulWidget {
  const TgMediaApp({
    super.key,
    this.secureStore,
    this.biometricGate,
  });

  /// Injected by tests; the app uses the Keychain and LocalAuthentication.
  final SecretStore? secureStore;
  final BiometricGate? biometricGate;

  @override
  State<TgMediaApp> createState() => _TgMediaAppState();
}

class _TgMediaAppState extends State<TgMediaApp> with WidgetsBindingObserver {
  late final SecretStore _secure;
  late final BiometricGate _gate;
  late final PreferencesController _preferences;
  late final AppLockStore _lockStore;
  late final UnlockController _lock;

  AppSession? _session;
  MediaCache? _cache;
  DownloadManager? _downloads;
  HistoryBackfill? _backfill;
  bool _ready = false;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _secure = widget.secureStore ?? const KeychainSecretStore();
    _gate = widget.biometricGate ?? MethodChannelBiometricGate();
    _preferences = PreferencesController(store: PreferencesStore(store: _secure));
    _lockStore = AppLockStore(store: _secure);
    _lock = UnlockController(lockStore: _lockStore, gate: _gate);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _preferences.load();
      await _lock.start();

      final layout = await AppPaths.resolveLayout();
      await layout.ensureCreated();
      final session = AppSession(layout: layout, secureStore: _secure);
      final cache = MediaCache(layout: layout);
      await cache.ensureCreated();
      _cache = cache;
      _downloads = DownloadManager(
        transport: _SessionTransport(session),
        validator: const CacheValidator(),
        cache: cache,
      );
      _session = session;
      if (mounted) setState(() => _ready = true);
      unawaited(session.boot());
      _runBackfill();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _bootError = redactText('$e');
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_lock.onResumed());
        _runBackfill();
      case AppLifecycleState.inactive:
        // iOS reports inactive for the Face ID sheet, the app switcher and the
        // notification shade. Treating those as "left the app" made every
        // unlock re-lock itself while the scan was still on screen.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _backfill?.stop();
        _lock.onPaused();
    }
  }

  /// The history walk is a loop, not a one-shot kick: a single kick is why a
  /// 4000-message channel froze part way. `start()` is idempotent.
  void _runBackfill() {
    final session = _session;
    if (session == null) return;
    final backfill = _backfill ??= HistoryBackfill(
      fetch: (pages) => session.syncHistorySlice(pagesPerChannel: pages),
    );
    backfill.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backfill?.stop();
    _downloads?.dispose();
    _session?.dispose();
    _lock.dispose();
    _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _preferences,
      builder: (context, _) => MaterialApp(
        title: 'TG Media',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _preferences.value.theme.themeMode,
        home: _PortraitHost(child: _buildRoot()),
      ),
    );
  }

  Widget _buildRoot() {
    if (!_ready) {
      return const _SplashScreen(label: '正在启动');
    }
    if (_bootError != null) {
      return Scaffold(
        body: StatusView.error(
          title: '启动失败',
          message: _bootError,
          actionLabel: '重试',
          onAction: () {
            setState(() {
              _bootError = null;
              _ready = false;
            });
            unawaited(_bootstrap());
          },
        ),
      );
    }

    final session = _session;
    final cache = _cache;
    final downloads = _downloads;
    if (session == null || cache == null || downloads == null) {
      return const _SplashScreen(label: '正在准备存储');
    }

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_lock, session]),
      builder: (context, _) {
        if (_lock.isLocked) {
          return UnlockScreen(
            controller: _lock,
            onForgotPasscode: () => _recoverPasscode(session),
          );
        }
        switch (session.route) {
          case AppRoute.splash:
            return const _SplashScreen(label: '正在恢复 Telegram 会话');
          case AppRoute.blocked:
          case AppRoute.awaitingCredentials:
          case AppRoute.awaitingLogin:
            return LoginPage(session: session);
          case AppRoute.shell:
            return AppShell(
              session: session,
              preferences: _preferences,
              lock: _lock,
              lockStore: _lockStore,
              cache: cache,
              downloads: downloads,
            );
        }
      },
    );
  }

  /// The only way out of a forgotten passcode: re-authenticate through Telegram
  /// by clearing the local session, then drop the app lock.
  Future<void> _recoverPasscode(AppSession session) async {
    final confirmed = await confirmRecoveryReset(context);
    if (!confirmed || !mounted) return;
    await session.resetThroughTelegram();
    await _lock.completeRecovery();
    if (!mounted) return;
    await session.boot();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 16),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two tabs, fixed order, no third entry and no nested tab bars.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.session,
    required this.preferences,
    required this.lock,
    required this.lockStore,
    required this.cache,
    required this.downloads,
  });

  final AppSession session;
  final PreferencesController preferences;
  final UnlockController lock;
  final AppLockStore lockStore;
  final MediaCache cache;
  final DownloadManager downloads;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          ChannelPage(
            session: widget.session,
            preferences: widget.preferences,
            downloads: widget.downloads,
            cache: widget.cache,
          ),
          SettingsPage(
            session: widget.session,
            preferences: widget.preferences,
            lock: widget.lock,
            lockStore: widget.lockStore,
            cache: widget.cache,
            downloads: widget.downloads,
          ),
        ],
      ),
      bottomNavigationBar: CupertinoTabBar(
        currentIndex: _index,
        onTap: _select,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        activeColor: scheme.primary,
        inactiveColor: scheme.onSurfaceVariant,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.list_bullet),
            activeIcon: Icon(CupertinoIcons.list_bullet),
            label: '频道',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.gear),
            activeIcon: Icon(CupertinoIcons.gear),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
