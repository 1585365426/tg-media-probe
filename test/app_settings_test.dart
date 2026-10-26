import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/app/app_settings.dart';

import 'support/sandbox.dart';

void main() {
  late TestSandbox box;
  late AppSettingsStore store;

  setUp(() async {
    box = await TestSandbox.create();
    store = AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
  });

  tearDown(() async {
    await box.dispose();
  });

  group('defaults', () {
    test('cold start is muted', () async {
      final settings = await store.load();
      expect(settings.muted, isTrue);
      expect(settings.themeMode, AppThemeMode.system);
      expect(settings.categoryChatId, isNull);
      expect(settings.durationFilter, DurationFilter.all);
    });

    test('a missing file is not an error', () async {
      expect(await box.exists(store.filePath), isFalse);
      await store.load();
      expect(await box.exists(store.filePath), isFalse,
          reason: 'reading defaults must not create a file by itself');
    });
  });

  group('persistence', () {
    test('theme, category and duration survive a restart', () async {
      await store.load();
      await store.setTheme(AppThemeMode.dark);
      await store.setCategory(42);
      await store.setDurationFilter(DurationFilter.tenToTwentyMinutes);

      final reopened =
          AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
      final loaded = await reopened.load();
      expect(loaded.themeMode, AppThemeMode.dark);
      expect(loaded.categoryChatId, 42);
      expect(loaded.durationFilter, DurationFilter.tenToTwentyMinutes);
    });

    test('clearing the category persists as null', () async {
      await store.load();
      await store.setCategory(42);
      await store.setCategory(null);

      final reopened =
          AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
      expect((await reopened.load()).categoryChatId, isNull);
    });

    test('settings live inside the protected zone', () {
      expect(p.isWithin(box.layout.authMetaDir, store.filePath), isTrue);
      expect(p.isWithin(box.layout.tempRoot, store.filePath), isFalse);
    });

    test('write goes through a temp file so a crash cannot truncate it',
        () async {
      await store.load();
      await store.setTheme(AppThemeMode.light);
      expect(await box.exists('${store.filePath}.tmp'), isFalse,
          reason: 'the temp file must be renamed away, not left behind');
      expect(await box.exists(store.filePath), isTrue);
    });
  });

  group('cold-start mute override', () {
    test('an unmuted value on disk still comes back muted', () async {
      await store.load();
      await store.setMuted(false);
      expect(store.value.muted, isFalse);

      final reopened =
          AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
      final loaded = await reopened.load();
      expect(loaded.muted, isTrue,
          reason: 'every cold start must begin muted');
    });

    test('the override is written back so disk and runtime agree', () async {
      await store.load();
      await store.setMuted(false);
      // Simulate the next launch.
      final reopened =
          AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
      await reopened.load();
      final third =
          AppSettingsStore(directory: box.layout.settingsDir, ops: box.ops);
      expect((await third.load()).muted, isTrue);
    });
  });

  group('corruption', () {
    test('unparseable JSON falls back to defaults instead of throwing',
        () async {
      await box.write(store.filePath, '{not json');
      final settings = await store.load();
      expect(settings.themeMode, AppThemeMode.system);
      expect(settings.muted, isTrue);
    });

    test('unknown enum values fall back to the safe default', () async {
      await box.write(
        store.filePath,
        '{"v":1,"theme":"plasma","duration":"forever","muted":false}',
      );
      final settings = await store.load();
      expect(settings.themeMode, AppThemeMode.system);
      expect(settings.durationFilter, DurationFilter.all);
      expect(settings.muted, isTrue);
    });

    test('a directory where the file should be does not crash the app',
        () async {
      await Directory(store.filePath).create(recursive: true);
      final settings = await store.load();
      expect(settings.muted, isTrue);
    });
  });

  group('AppThemeMode codes', () {
    test('round-trip every mode', () {
      for (final mode in AppThemeMode.values) {
        expect(AppThemeModeWire.fromWire(mode.wire), mode);
      }
      expect(AppThemeModeWire.fromWire('nope'), AppThemeMode.system);
      expect(AppThemeModeWire.fromWire(null), AppThemeMode.system);
    });
  });
}
