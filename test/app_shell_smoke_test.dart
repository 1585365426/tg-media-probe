import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_model.dart';
import 'package:tg_media_probe/app/app_services.dart';
import 'package:tg_media_probe/app/app_settings.dart';
import 'package:tg_media_probe/data/chat_title_store.dart';
import 'package:tg_media_probe/data/favorites_store.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
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
  PlayerHandle create(String location, {bool network = false}) =>
      throw UnimplementedError(
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

  testWidgets('shell shows the four top tabs', (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    expect(find.text('频道'), findsWidgets);
    expect(find.text('视频'), findsWidgets);
    expect(find.text('抖音'), findsWidgets);
    expect(find.text('功能'), findsWidgets);
  });

  testWidgets('抖音 hides the app bar and the tab strip entirely',
      (tester) async {
    final harness = await boot(tester);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    // Before: the strip is there and the app bar carries the title.
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);

    await tester.tap(find.text('抖音').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('抖音 drops the filter bar that 视频 keeps', (tester) async {
    final harness = await boot(tester);
    harness.model.markSignedIn(true);
    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Seven duration chips (全部 + six buckets) and nothing else on screen.
    expect(find.byType(ChoiceChip), findsNWidgets(7));

    await tester.tap(find.text('抖音').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChoiceChip), findsNothing);
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
    // The four-zone table renders before the async size probe resolves, so the
    // heading is the stable assertion here.
    expect(find.text('存储占用（四区隔离）'), findsOneWidget);

    // Everything below the storage card is off-screen on a phone viewport and a
    // ListView does not build it until it is scrolled near, so scroll first.
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pump();
    expect(find.text('最近播放耗时'), findsOneWidget);
    expect(find.text('只读声明'), findsOneWidget);
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

  testWidgets('the feed pages past a full screen of photos to reach videos',
      (tester) async {
    final harness = await boot(tester);
    harness.model.markSignedIn(true);

    // 60 photos newer than 3 videos. One 40-row page holds only photos, and an
    // empty list cannot be scrolled, so the load-more trigger at the bottom
    // never fires — the tab used to sit on "no videos" with the index full.
    await tester.runAsync(() async {
      final records = <MediaRecord>[];
      for (var i = 0; i < 60; i++) {
        records.add(MediaRecord(
          chatId: 100,
          messageId: 900 - i,
          fileId: 5000 + i,
          kind: MediaKind.photo,
          sizeBytes: 1024,
          messageDateUnix: 1700000000 + i,
        ));
      }
      for (var i = 0; i < 3; i++) {
        records.add(MediaRecord(
          chatId: 100,
          messageId: 100 - i,
          fileId: 7000 + i,
          kind: MediaKind.video,
          durationSeconds: 30,
          sizeBytes: 2048,
          messageDateUnix: 1699999000 + i,
        ));
      }
      await harness.services.index.upsertAll(records);
    });

    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();
    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('索引里还没有视频'), findsNothing);
  });

  testWidgets('returning to the tab after a sync reloads the mirror',
      (tester) async {
    final harness = await boot(tester);
    harness.model.markSignedIn(true);

    await tester.pumpWidget(wrap(harness.services, harness.model));
    await tester.pump();

    // Start on 频道 with an empty index, so the feed builds its snapshot of
    // nothing.
    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('索引里还没有视频'), findsOneWidget);

    await tester.tap(find.text('频道').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // A sync lands while the feed is hidden.
    await tester.runAsync(() async {
      await harness.services.index.upsertAll(<MediaRecord>[
        MediaRecord(
          chatId: 100,
          messageId: 1,
          fileId: 8000,
          kind: MediaKind.video,
          durationSeconds: 12,
          sizeBytes: 4096,
          messageDateUnix: 1700000000,
        ),
      ]);
    });

    await tester.tap(find.text('视频').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('索引里还没有视频'), findsNothing);
  });
}
