import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_model.dart';
import 'package:tg_media_probe/app/app_services.dart';
import 'package:tg_media_probe/app/app_settings.dart';
import 'package:tg_media_probe/data/chat_title_store.dart';
import 'package:tg_media_probe/data/favorites_store.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/platform/orientation_controller.dart';
import 'package:tg_media_probe/playback/playback_lifecycle.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/security/app_lock.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
import 'package:tg_media_probe/ui/favorites/favorites_page.dart';

import 'support/sandbox.dart';

/// The favourites list is a portrait screen, but it is opened from a tab that
/// may have left the native side in landscape. This test pins the lock down:
/// without it the list renders sideways on any device that was held flat.
class _NoopPlayerFactory implements PlayerFactory {
  const _NoopPlayerFactory();

  @override
  PlayerHandle create(String path) =>
      throw UnimplementedError('the favourites test never plays video');
}

Future<AppServices> _services(TestSandbox box) async {
  final settings = AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
  await settings.load();
  final favorites = FavoritesStore(directory: box.layout.indexDir, ops: box.ops);
  await favorites.open();
  final titles = ChatTitleStore(directory: box.layout.indexDir, ops: box.ops);
  await titles.open();
  final index = IndexStore(directory: box.layout.indexDir, ops: box.ops);
  await index.open();
  final activeFiles = ActiveFileRegistry();
  final player = SinglePlayerController(
    factory: const _NoopPlayerFactory(),
    activeFiles: activeFiles,
  );
  return AppServices(
    layout: box.layout,
    ops: box.ops,
    settingsStore: settings,
    favorites: favorites,
    chatTitles: titles,
    index: index,
    cache: CacheManager(
      layout: box.layout,
      ops: box.ops,
      activeFiles: activeFiles,
      integrityProbe: index.integritySnapshot,
    ),
    activeFiles: activeFiles,
    appLock: AppLock(store: MemorySecretStore(), iterations: 1000),
    biometrics: BiometricService(backend: FakeBiometricBackend()),
    player: player,
    binder: PlaybackLifecycleBinder(controller: player),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final orientationChannel = MethodChannel(OrientationBridge.channelName);
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(orientationChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(orientationChannel, null);
  });

  testWidgets('favourites locks portrait on entry and releases on exit',
      (tester) async {
    late TestSandbox box;
    late AppServices services;
    late AppModel model;

    await tester.runAsync(() async {
      box = await TestSandbox.create();
      services = await _services(box);
      model = AppModel(services: services)..hydrateFavorites();
      await services.favorites.add(MediaRecord(
        chatId: 9,
        messageId: 1,
        fileId: 99,
        kind: MediaKind.video,
        durationSeconds: 20,
        sizeBytes: 1024,
        messageDateUnix: 1700000000,
      ));
    });
    addTearDown(() async {
      await tester.runAsync(() async => box.dispose());
    });

    await tester.pumpWidget(
      AppScope(
        services: services,
        model: model,
        child: MaterialApp(
          home: FavoritesPage(services: services, model: model),
        ),
      ),
    );
    await tester.pump();

    expect(calls.map((c) => c.method), contains('setMode'));
    expect((calls.first.arguments as Map)['mode'], 'portrait');

    // Leaving the page hands orientation control back to the shell.
    await tester.pumpWidget(
      AppScope(
        services: services,
        model: model,
        child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );
    await tester.pump();

    expect(calls.where((c) => c.method == 'reset'), hasLength(1));
  });
}
