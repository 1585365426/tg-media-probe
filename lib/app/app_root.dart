/// Application root: services, routing gate, and the three-tab shell.
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

import '../lock/lock_screens.dart';
import '../platform/orientation_coordinator.dart';
import '../lock/unlock_controller.dart';
import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../security/tdlib_key.dart';
import '../playback/streaming_diagnostics.dart';
import '../storage/active_files.dart';
import '../storage/app_paths.dart';
import '../storage/file_ops.dart';
import '../storage/temp_zone_report.dart';
import '../ui/app_theme.dart';
import '../ui/channel_pages.dart';
import '../ui/feed_page.dart';
import '../ui/login_page.dart';
import '../ui/settings_page.dart';
import '../ui/status_view.dart';
import '../util/redact.dart';
import 'app_preferences.dart';
import '../storage/cache_budget.dart';
import 'history_backfill.dart';
import 'app_session.dart';

/// Holds portrait for every route that is not the feed.
///
/// The feed pushes its own landscape scope on top and restores portrait when it
/// leaves, so this host only has to guarantee the default. Login, unlock,
/// settings and the channel pages live under it and therefore cannot inherit a
/// sideways window from however the phone is being held.
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
    // Bottom of the stack: portrait for everything that is not the player.
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

  final ActiveFileRegistry _activeFiles = ActiveFileRegistry();

  AppSession? _session;
  TempZoneReport? _storage;
  AutoCacheCleaner? _cleaner;
  HistoryBackfill? _backfill;
  DateTime? _lastMaintenance;
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
      // Diagnostics mode is a persisted choice, so it has to be applied to
      // the shared diagnostics object before any play can record into it.
      StreamingDiagnostics.instance.setEnabled(
        _preferences.value.streamingDiagnostics,
      );
      // The lock is decided before anything else is drawn.
      await _lock.start();

      final layout = await AppPaths.resolveLayout();
      await layout.ensureCreated();
      final session = AppSession(layout: layout, secureStore: _secure);
      _storage = TempZoneReport(
        layout: layout,
        ops: const IoFileOps(),
        activeFiles: _activeFiles,
      );
      _session = session;
      if (mounted) {
        setState(() => _ready = true);
      }
      // Opening TDLib takes a moment; the unlock screen is already up.
      unawaited(session.boot());
      _runMaintenance();
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
        _runMaintenance();
      case AppLifecycleState.inactive:
        // iOS reports inactive for the Face ID sheet, the app switcher and the
        // notification shade. Treating those as "left the app" made every
        // unlock re-lock itself while the scan was still on screen.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // A history slice in flight is wasted work once the process is about to
        // be suspended; the cursor is already persisted, so stopping loses
        // nothing.
        _backfill?.stop();
        _lock.onPaused();
    }
  }

  /// Startup / foreground housekeeping: one cache check and the history walk.
  ///
  /// The cache check is throttled: entering the app ten times in a minute must
  /// not start ten cleaners, and it returns immediately when one is running.
  ///
  /// The history walk is a *loop*, not a one-shot kick. A single kick was the
  /// reason a 4000-message channel froze at 725 videos: the slice budget ran
  /// out, and nothing ever asked again. `start()` is idempotent, so calling it
  /// on every resume is safe.
  void _runMaintenance() {
    final session = _session;
    final storage = _storage;
    if (session == null || storage == null) return;

    final backfill = _backfill ??= HistoryBackfill(
      fetch: (pages) => session.syncHistorySlice(pagesPerChannel: pages),
    );
    backfill.start();

    final now = DateTime.now();
    if (_lastMaintenance != null &&
        now.difference(_lastMaintenance!) < const Duration(seconds: 30)) {
      return;
    }
    _lastMaintenance = now;

    final cleaner = _cleaner ??= AutoCacheCleaner(
      layout: storage.layout,
      ops: const IoFileOps(),
      activeFiles: _activeFiles,
    );
    unawaited(cleaner.check(limitBytes: _preferences.value.cacheLimitBytes));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backfill?.stop();
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
    if (session == null || _storage == null) {
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
              storageReport: _storage!,
              activeFiles: _activeFiles,
            );
        }
      },
    );
  }

  /// §8.6: the only way out of a forgotten passcode. It re-authenticates through
  /// Telegram by clearing the local session, then drops the app lock.
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

/// Three tabs, fixed order, no fourth entry and no nested tab bars (§2).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.session,
    required this.preferences,
    required this.lock,
    required this.lockStore,
    required this.storageReport,
    required this.activeFiles,
  });

  final AppSession session;
  final PreferencesController preferences;
  final UnlockController lock;
  final AppLockStore lockStore;
  final TempZoneReport storageReport;
  final ActiveFileRegistry activeFiles;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// Published by the feed while a video is on screen. While true the shell
  /// hides its bottom tab bar: immersive playback, the three tabs are chrome.
  /// The feed clears it when it stops playing or when the user leaves the tab.
  final ValueNotifier<bool> _feedImmersive = ValueNotifier<bool>(false);

  /// The shell does not own orientation any more.
  ///
  /// `_PortraitHost` holds portrait for every non-player route, and the feed
  /// raises its own intent on the shared [OrientationCoordinator] while it is
  /// open. Two independent holders were exactly how the app ended up sideways
  /// after leaving the player: the shell had set portrait once, in initState,
  /// and nothing re-applied it after the feed's own reset.

  /// The feed is built on first visit only: constructing it opens a player and
  /// starts a transfer, which must not happen while the user is reading the
  /// channel list.
  bool _feedBuilt = false;

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      if (index == 1) _feedBuilt = true;
    });
  }

  /// "Back" out of the immersive feed: with the tab bar hidden there is no
  /// other way out of the feed tab, so the revealed top bar's back button
  /// lands the user on the channel list.
  void _exitFeed() => _select(0);

  @override
  void dispose() {
    _feedImmersive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          ChannelListPage(
            session: widget.session,
            preferences: widget.preferences.value,
            activeFiles: widget.activeFiles,
          ),
          _feedBuilt
              ? FeedPage(
                  session: widget.session,
                  preferences: widget.preferences.value,
                  activeFiles: widget.activeFiles,
                  isActive: _index == 1,
                  playbackImmersive: _feedImmersive,
                  onExitPlayback: _exitFeed,
                )
              : const SizedBox.shrink(),
          SettingsPage(
            session: widget.session,
            preferences: widget.preferences,
            lock: widget.lock,
            lockStore: widget.lockStore,
            storageReport: widget.storageReport,
          ),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: _feedImmersive,
        // The tab bar widget is built once and reused: only its visibility
        // depends on the immersive flag, so the shell body (and the feed's
        // state inside it) is never rebuilt for a visibility flip.
        child: CupertinoTabBar(
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
              icon: Icon(CupertinoIcons.play_rectangle),
              activeIcon: Icon(CupertinoIcons.play_rectangle),
              label: '抖音',
            ),
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.gear),
              activeIcon: Icon(CupertinoIcons.gear),
              label: '设置',
            ),
          ],
        ),
        builder: (context, immersive, tabBar) {
          final hidden = _index == 1 && immersive;
          return hidden ? const SizedBox.shrink() : tabBar!;
        },
      ),
    );
  }
}
