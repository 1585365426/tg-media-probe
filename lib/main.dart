import 'package:flutter/material.dart';

import 'app/app_model.dart';
import 'app/app_services.dart';
import 'ui/app_shell.dart';
import 'ui/lock/lock_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final services = await AppServices.bootstrap();
    final model = AppModel(services: services)..hydrateFavorites();
    runApp(TgMediaApp(services: services, model: model));
  } catch (error) {
    // A failed bootstrap (Keychain unavailable, container not writable) must
    // surface as readable text, not a white screen with a silent exception.
    runApp(_BootstrapFailureApp(message: error.toString()));
  }
}

class TgMediaApp extends StatelessWidget {
  const TgMediaApp({super.key, required this.services, required this.model});

  final AppServices services;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      model: model,
      child: AnimatedBuilder(
        animation: model,
        builder: (context, _) => MaterialApp(
          title: 'TG Media',
          debugShowCheckedModeBanner: false,
          // Switching theme rebuilds from here, so it takes effect without a
          // restart — the model notifies and only themeMode changes.
          themeMode: model.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: LockGate(services: services),
        ),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2AABEE),
          brightness: brightness,
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      );
}

/// Shows [LockScreen] when a passcode is configured, the shell otherwise.
///
/// Verification runs on cold start only. It is deliberately not re-run when the
/// app comes back from background: the task book asks for verification "打开App时",
/// and re-locking on every glance at a notification would make the feed
/// unusable. Recorded as a known trade-off in the step 4 report.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.services});

  final AppServices services;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  bool? _lockEnabled;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var enabled = false;
    try {
      enabled = await widget.services.appLock.isEnabled();
    } catch (_) {
      // Keychain unreadable: fail closed is wrong here — the user would be
      // locked out of their own app with no way in. The settings screen still
      // shows the state it can read.
      enabled = false;
    }
    if (!mounted) return;
    setState(() => _lockEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _lockEnabled;
    if (enabled == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!enabled) return const AppShell();
    return LockScreen(
      services: widget.services,
      onUnlocked: () => setState(() => _lockEnabled = false),
    );
  }
}

class _BootstrapFailureApp extends StatelessWidget {
  const _BootstrapFailureApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TgMediaApp._theme(Brightness.light),
      home: Scaffold(
        appBar: AppBar(title: const Text('启动失败')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('应用初始化未完成，以下是原始错误：'),
              const SizedBox(height: 12),
              SelectableText(
                message,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
