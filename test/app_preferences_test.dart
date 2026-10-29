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
    if (failOnWrite) throw StateError('write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('defaults match the product spec', () {
    const prefs = AppPreferences.initial;
    expect(prefs.theme, ThemePreference.system);
    expect(prefs.playbackSpeed, 1.0);
    // The diagnostic badge is a verification aid, so it ships off.
    expect(prefs.diagnosticBadge, isFalse);
    expect(prefs.defaultMuted, isFalse);
  });

  test('theme preference maps onto ThemeMode', () {
    expect(ThemePreference.system.themeMode, ThemeMode.system);
    expect(ThemePreference.light.themeMode, ThemeMode.light);
    expect(ThemePreference.dark.themeMode, ThemeMode.dark);
  });

  test('round trip keeps every field', () {
    const prefs = AppPreferences(
      theme: ThemePreference.dark,
      defaultMuted: true,
      playbackSpeed: 1.5,
      diagnosticBadge: true,
    );
    final decoded = AppPreferences.fromJson(prefs.toJson());
    expect(decoded, prefs);
  });

  test('unknown values fall back instead of failing the record', () {
    final decoded = AppPreferences.fromJson(<String, Object?>{
      'theme': 'neon',
      'playbackSpeed': 3.7,
      'diagnosticBadge': 'yes',
    });
    expect(decoded.theme, ThemePreference.system);
    expect(decoded.playbackSpeed, 1.0);
    // A non-boolean badge flag is read as "off", never as "on".
    expect(decoded.diagnosticBadge, isFalse);
  });

  test('every offered speed survives the round trip', () {
    for (final speed in kPlaybackSpeeds) {
      final decoded =
          AppPreferences.fromJson(<String, Object?>{'playbackSpeed': speed});
      expect(decoded.playbackSpeed, speed);
    }
  });

  test('formatPlaybackSpeed prints a usable label', () {
    expect(formatPlaybackSpeed(1.0), '1.0x');
    expect(formatPlaybackSpeed(0.5), '0.5x');
    expect(formatPlaybackSpeed(1.25), '1.25x');
    expect(formatPlaybackSpeed(2.0), '2.0x');
  });

  test('controller rejects an unsupported speed', () async {
    final controller =
        PreferencesController(store: PreferencesStore(store: FailingStore()));
    await controller.load();
    expect(await controller.setPlaybackSpeed(3.0), isFalse);
    expect(controller.value.playbackSpeed, 1.0);
    expect(await controller.setPlaybackSpeed(1.5), isTrue);
    expect(controller.value.playbackSpeed, 1.5);
  });

  test('a failed write leaves the in-memory value untouched', () async {
    final store = FailingStore(failOnWrite: true);
    final controller =
        PreferencesController(store: PreferencesStore(store: store));
    await controller.load();
    await controller.setDiagnosticBadge(true);
    expect(controller.value.diagnosticBadge, isFalse);
    expect(controller.lastError, isNotNull);
  });

  test('the theme preference persists through the controller', () async {
    final controller =
        PreferencesController(store: PreferencesStore(store: FailingStore()));
    await controller.load();
    await controller.setTheme(ThemePreference.dark);
    expect(controller.value.theme, ThemePreference.dark);
  });

  test('a corrupt stored record starts from defaults', () async {
    final store = FailingStore();
    store.values[PreferencesStore.storageKey] = 'not json';
    final loaded = await PreferencesStore(store: store).load();
    expect(loaded, AppPreferences.initial);
  });
}
