import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_preferences.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';

/// A [SecretStore] whose writes can be made to fail, for the "a setting that did
/// not persist must not appear to be on" rule.
class FailingStore implements SecretStore {
  FailingStore({this.failOnWrite = false});

  final bool failOnWrite;
  final Map<String, String> values = <String, String>{};
  int writeCount = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (failOnWrite) throw StateError('keychain unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  group('AppPreferences defaults', () {
    test('first launch is system theme, portrait-first, sound on, preload on', () {
      const initial = AppPreferences.initial;
      expect(initial.theme, ThemePreference.system);
      expect(initial.feedDirection, FeedDirection.portraitPreferred);
      expect(initial.defaultMuted, isFalse);
      expect(initial.preloadAdjacent, isTrue);
    });

    test('theme preference maps onto ThemeMode without inventing a value', () {
      expect(ThemePreference.system.themeMode, ThemeMode.system);
      expect(ThemePreference.light.themeMode, ThemeMode.light);
      expect(ThemePreference.dark.themeMode, ThemeMode.dark);
    });

    test('there is no network restriction or long-press setting to persist', () {
      // Guards against a later step restoring a toggle that was cancelled.
      final keys = AppPreferences.initial.toJson().keys.toSet();
      expect(keys, containsAll(<String>['theme', 'feedDirection']));
      expect(keys.any((k) => k.toLowerCase().contains('wifi')), isFalse);
      expect(keys.any((k) => k.toLowerCase().contains('longpress')), isFalse);
      expect(keys.any((k) => k.toLowerCase().contains('download')), isFalse);
      expect(keys.any((k) => k.toLowerCase().contains('favorite')), isFalse);
    });
  });

  group('PreferencesStore persistence', () {
    test('round-trips every field through the store', () async {
      final secrets = MemorySecretStore();
      final store = PreferencesStore(store: secrets);
      const next = AppPreferences(
        theme: ThemePreference.dark,
        feedDirection: FeedDirection.allowLandscape,
        defaultMuted: true,
        preloadAdjacent: false,
      );

      await store.save(next);
      final loaded = await PreferencesStore(store: secrets).load();

      expect(loaded, next);
    });

    test('an empty store yields the documented defaults', () async {
      final store = PreferencesStore(store: MemorySecretStore());
      expect(await store.load(), AppPreferences.initial);
    });

    test('corrupt JSON falls back to defaults instead of throwing', () async {
      final secrets = MemorySecretStore(
        <String, String>{PreferencesStore.storageKey: '{not json'},
      );
      final store = PreferencesStore(store: secrets);
      expect(await store.load(), AppPreferences.initial);
    });

    test('a JSON array instead of an object is treated as corrupt', () async {
      final secrets = MemorySecretStore(
        <String, String>{PreferencesStore.storageKey: '[1,2,3]'},
      );
      expect(await PreferencesStore(store: secrets).load(), AppPreferences.initial);
    });

    test('an unknown enum name only resets that field', () async {
      final secrets = MemorySecretStore(<String, String>{
        PreferencesStore.storageKey:
            '{"theme":"neon","feedDirection":"allowLandscape","defaultMuted":true}',
      });
      final loaded = await PreferencesStore(store: secrets).load();
      expect(loaded.theme, ThemePreference.system);
      expect(loaded.feedDirection, FeedDirection.allowLandscape);
      expect(loaded.defaultMuted, isTrue);
    });

    test('preloadAdjacent is only false when it was explicitly stored as false',
        () async {
      final secrets = MemorySecretStore(<String, String>{
        PreferencesStore.storageKey: '{"theme":"dark"}',
      });
      final loaded = await PreferencesStore(store: secrets).load();
      expect(loaded.preloadAdjacent, isTrue);
    });

    test('the storage slot is versioned', () {
      expect(PreferencesStore.storageKey, endsWith('_v1'));
    });
  });

  group('PreferencesController', () {
    test('starts unloaded and reports the defaults', () {
      final controller = PreferencesController(
        store: PreferencesStore(store: MemorySecretStore()),
      );
      expect(controller.isLoaded, isFalse);
      expect(controller.value, AppPreferences.initial);
    });

    test('load reads what was persisted', () async {
      final secrets = MemorySecretStore(<String, String>{
        PreferencesStore.storageKey: '{"theme":"light","defaultMuted":true}',
      });
      final controller = PreferencesController(
        store: PreferencesStore(store: secrets),
      );
      await controller.load();
      expect(controller.isLoaded, isTrue);
      expect(controller.value.theme, ThemePreference.light);
      expect(controller.value.defaultMuted, isTrue);
    });

    test('setters persist and notify', () async {
      final secrets = MemorySecretStore();
      final controller = PreferencesController(
        store: PreferencesStore(store: secrets),
      );
      await controller.load();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setTheme(ThemePreference.dark);
      await controller.setDefaultMuted(true);
      await controller.setFeedDirection(FeedDirection.allowLandscape);
      await controller.setPreloadAdjacent(false);

      expect(notifications, greaterThanOrEqualTo(4));
      expect(controller.value.theme, ThemePreference.dark);
      expect(controller.value.defaultMuted, isTrue);
      expect(controller.value.feedDirection, FeedDirection.allowLandscape);
      expect(controller.value.preloadAdjacent, isFalse);

      final reloaded =
          await PreferencesStore(store: secrets).load();
      expect(reloaded, controller.value);
    });

    test('a failed write leaves the in-memory value untouched', () async {
      final controller = PreferencesController(
        store: PreferencesStore(store: FailingStore(failOnWrite: true)),
      );
      await controller.load();
      await controller.setTheme(ThemePreference.dark);

      expect(controller.value.theme, ThemePreference.system);
      expect(controller.lastError, isNotNull);
      expect(controller.isSaving, isFalse);
    });

    test('setting the same value does not write again', () async {
      final secrets = FailingStore();
      final controller = PreferencesController(
        store: PreferencesStore(store: secrets),
      );
      await controller.load();
      final before = secrets.writeCount;
      await controller.setTheme(ThemePreference.system);
      expect(secrets.writeCount, before);
    });
  });
}
