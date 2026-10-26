import 'package:flutter/material.dart';

import 'app/app_model.dart';
import 'app/app_services.dart';
import 'ui/boot/session_gate.dart';

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
          // Launch goes through the session gate: it restores the saved TDLib
          // session before the shell decides it is "logged out" and asks for a
          // login code that Telegram never actually wanted.
          home: SessionGate(services: services, model: model),
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
