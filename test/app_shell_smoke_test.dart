import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_model.dart';
import 'package:tg_media_probe/app/app_services.dart';
import 'package:tg_media_probe/app/app_settings.dart';
import 'package:tg_media_probe/data/chat_title_store.dart';
import 'package:tg_media_probe/data/favorites_store.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/playback/playback_lifecycle.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/security/app_lock.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
import 'package:tg_media_probe/ui/app_shell.dart';

import 'support/sandbox.dart';

/// Widget-level smoke test for the shell.
///
/// Deliberately does not call `AppServices.bootstrap()`: that needs
/// `path_provider` and the Keychain. The real objects below are the same
/// classes the app builds, just pointed at a temp sandbox and a memory
/// Keychain, so the widgets under test are the shipped ones.
class _NoopPlayerFactory implements PlayerFactory {
  const _NoopPlayerFactory();

  @override
  PlayerHandle create(String path) => throw UnimplementedError(
        'the shell test never activates a player',
      );
}

Future<({AppServices services, AppModel model, TestSandbox box})> buildHarness()
    async {
  final box = await TestSandbox.create();
  final settingsStore =
      AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
  await settingsStore.load();
  final favorites = FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
  await favorites.open();
  final titles = ChatTitleStore(directory: box.layout.indexDir, ops: box.ops);
  await titles.open();
  final index = IndexStore(directory: box.layout.indexDir, ops: box.ops);
  await index.open();
  final activeFiles = ActiveFileRegistry();
  final cache = CacheManager(
    layout: box.layout,
    ops: box.ops,
    activeFiles: activeFiles,
    integrityProbe: index.integritySnapshot,
  );
  final player = SinglePlayerController(
    factory: const _NoopPlayerFactory(),
    activeFiles: activeFiles,
  );

  final services = AppServices(
    layout: box.layout,
    ops: box.ops,
    settingsStore: settingsStore,
    favorites: favorites,
    chatTitles: titles,
    index: index,
    cache: cache,
    activeFiles: activeFiles,
    appLock: AppLock(store: MemorySecretStore(), iterations: 1000),
    biometrics: BiometricService(backend: FakeBiometricBackend()),
    player: player,
    binder: PlaybackLifecycleBinder(controller: player),
  );
  final model = AppModel(services: services)..hydrateFavorites();
  return (services: services, model: model, box: box);
}

Widget wrap(AppServices services, AppModel model) => AppScope(
      services: services,
      model: model,
      child: AnimatedBuilder(
        animation: model,
        builder: (context, _) => MaterialApp(
          themeMode: model.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2AABEE)),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2AABEE),
              brightness: Brightness.dark,
            ),
          ),
          home: const AppShell(),
        ),
      ),
    );

void main() {
  // Every testWidgets body runs in a fake-async zone where real file I/O never
  // completes, so harness construction and any model call that touches disk go
  // through `tester.runAsync`.
  Future<({AppServices services, AppModel model, TestSandbox box})> boot(
    WidgetTester tester,
  ) async {
    late ({AppServices services, AppModel model, TestSandbox box}) harness;
    await tester.runAsync(() async {
      harness = await buildHarness();
    });
    addTearDown(() async {
      await tester.runAsync(() async => harness.box.dispose());
    });
    return harness;
  }

  testWidgets('shell shows the three top tabs', (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    expect(find.text('频道'), findsWidgets);
    expect(find.text('视频'), findsWidgets);
    expect(find.text('功能'), findsWidgets);
  });

  testWidgets('channel tab asks the user to sign in first', (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    expect(find.text('尚未登录 Telegram'), findsOneWidget);
    expect(find.text('登录 Telegram'), findsOneWidget);
  });

  testWidgets('video tab explains that sign-in is required', (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('登录后查看频道视频'), findsOneWidget);
  });

  testWidgets('tools tab exposes settings, favourites and the read-only notice',
      (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    await tester.tap(find.text('功能').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('只读声明'), findsOneWidget);
    // The four-zone table renders before the async size probe resolves, so the
    // heading is the stable assertion here.
    expect(find.text('存储占用（四区隔离）'), findsOneWidget);
  });

  testWidgets('theme switch is applied without a restart', (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();
    expect(harness.model.themeMode, ThemeMode.system);

    await tester.runAsync(() async {
      await harness.model.setThemeMode(AppThemeMode.dark);
    });
    await tester.pump();
    expect(harness.model.themeMode, ThemeMode.dark);

    await tester.runAsync(() async {
      await harness.model.setThemeMode(AppThemeMode.light);
    });
    await tester.pump();
    expect(harness.model.themeMode, ThemeMode.light);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
  });

  testWidgets('an active search query reports no matches on an empty index',
      (tester) async {
    final harness = await boot(tester);
    harness.model.markSignedIn(true);

    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    harness.model.setSearchText('anything');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('没有匹配的视频'), findsOneWidget);
    expect(find.text('清空条件'), findsOneWidget);
  });
}
