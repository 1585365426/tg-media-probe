/// Widget tests for the two-tab shell: exactly 频道 and 设置, no third tab, and
/// the settings groups the product spec asks for.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_preferences.dart';
import 'package:tg_media_probe/app/app_root.dart';
import 'package:tg_media_probe/app/app_session.dart';
import 'package:tg_media_probe/download/cache_validator.dart';
import 'package:tg_media_probe/download/download_manager.dart';
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/lock/unlock_controller.dart';
import 'package:tg_media_probe/platform/disk_space.dart';
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/lock_policy.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';
import 'package:tg_media_probe/ui/app_theme.dart';

import 'support/fake_transport.dart';

class _NoBiometrics implements BiometricGate {
  @override
  Future<BiometricCapability> probe() async =>
      const BiometricCapability.unavailable();

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async =>
      BiometricOutcome.notAvailable;
}

void main() {
  late Directory dir;
  late StorageLayout layout;
  late FakeTdTransport transport;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgmedia_shell_');
    layout = StorageLayout.forSandbox(dir.path);
    await layout.ensureCreated();
    transport = FakeTdTransport();
  });

  tearDown(() async {
    await transport.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Widget> buildShell() async {
    final secure = MemorySecretStore();
    final preferences =
        PreferencesController(store: PreferencesStore(store: secure));
    await preferences.load();
    final session = AppSession(layout: layout, secureStore: secure);
    final cache = MediaCache(layout: layout, diskSpace: const FixedDiskSpace(-1));
    final downloads = DownloadManager(
      transport: transport,
      validator: const CacheValidator(),
      cache: cache,
    );
    final lockStore = AppLockStore(store: secure);
    await lockStore.save(AppLockSettings.initial);
    final lock = UnlockController(lockStore: lockStore, gate: _NoBiometrics());
    await lock.reloadSettings();
    return MaterialApp(
      theme: AppTheme.light(),
      home: AppShell(
        session: session,
        preferences: preferences,
        lock: lock,
        lockStore: lockStore,
        cache: cache,
        downloads: downloads,
      ),
    );
  }

  testWidgets('bottom bar has exactly 频道 and 设置', (tester) async {
    await tester.pumpWidget(await buildShell());
    await tester.pump();

    final bar = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
    expect(bar.items, hasLength(2));
    expect(bar.items[0].label, '频道');
    expect(bar.items[1].label, '设置');
    expect(find.text('抖音'), findsNothing);
    expect(find.text('我的'), findsNothing);
  });

  testWidgets('settings tab shows the final groups', (tester) async {
    await tester.pumpWidget(await buildShell());
    await tester.pump();

    // The settings screen is taller than a phone: give the test surface enough
    // room that every group is built and can be asserted on.
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bar = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
    bar.onTap?.call(1);
    // Not pumpAndSettle: the channel tab legitimately shows an indeterminate
    // spinner while the account is not authorised, and that never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('账户'), findsOneWidget);
    expect(find.text('安全'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('缓存'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    // The deleted features must not reappear anywhere on this screen.
    expect(find.text('收藏'), findsNothing);
    expect(find.text('下载任务'), findsNothing);
    expect(find.text('下载历史'), findsNothing);
    expect(find.text('时长筛选'), findsNothing);
  });

  testWidgets('the diagnostic badge switch exists and is off by default',
      (tester) async {
    await tester.pumpWidget(await buildShell());
    await tester.pump();
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bar = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
    bar.onTap?.call(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.scrollUntilVisible(find.text('实时诊断角标'), 200);
    expect(find.text('实时诊断角标'), findsOneWidget);
    final badge = tester
        .widget<Switch>(find.byKey(const Key('switch-diagnostic-badge')));
    expect(badge.value, isFalse,
        reason: 'the badge is a verification aid, not a default feature');
    // Nothing on a fresh install claims to be on.
    expect(find.text('关闭'), findsWidgets);
  });
}
