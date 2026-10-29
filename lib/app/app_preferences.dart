/// User-visible preferences that are **not** part of the app lock.
///
/// Kept separate from `AppLockSettings` on purpose: the lock records a verifier
/// and is read on the cold-start path before anything else, while these values
/// are cosmetic and are read after the lock opens. Mixing them would make a
/// corrupted theme value able to break the unlock decision.
///
/// Scope notes, so nothing creeps back in:
/// * no preload field — the product decision is "only the video the user opened
///   is downloaded", so there is nothing to configure;
/// * no streaming field — there is one playback source, a complete local file;
/// * no long-press action field — long press is not bound to anything.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../security/tdlib_key.dart';

/// Light / dark / follow-system. Maps 1:1 onto [ThemeMode].
enum ThemePreference { system, light, dark }

extension ThemePreferenceWire on ThemePreference {
  ThemeMode get themeMode => switch (this) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      };

  String get label => switch (this) {
        ThemePreference.system => '跟随系统',
        ThemePreference.light => '浅色',
        ThemePreference.dark => '深色',
      };

  static ThemePreference fromName(Object? name) {
    for (final value in ThemePreference.values) {
      if (value.name == name) return value;
    }
    return ThemePreference.system;
  }
}

/// Playback rates offered in settings. 1.0 is the default.
const List<double> kPlaybackSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

String formatPlaybackSpeed(double speed) {
  if (speed == speed.roundToDouble()) return '${speed.toStringAsFixed(1)}x';
  return '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';
}

double _speedFromJson(Object? raw) {
  final value = raw is num ? raw.toDouble() : null;
  if (value == null) return 1.0;
  for (final allowed in kPlaybackSpeeds) {
    if ((allowed - value).abs() < 0.001) return allowed;
  }
  return 1.0;
}

@immutable
class AppPreferences {
  const AppPreferences({
    this.theme = ThemePreference.system,
    this.defaultMuted = false,
    this.playbackSpeed = 1.0,
    this.diagnosticBadge = false,
  });

  static const AppPreferences initial = AppPreferences();

  final ThemePreference theme;

  /// Sound is on by default; a muted-by-default player is a support ticket.
  final bool defaultMuted;

  /// Remembered playback rate, one of [kPlaybackSpeeds].
  final double playbackSpeed;

  /// Top-right diagnostic badge on the player. Off by default: it is a
  /// verification aid, not a feature.
  final bool diagnosticBadge;

  AppPreferences copyWith({
    ThemePreference? theme,
    bool? defaultMuted,
    double? playbackSpeed,
    bool? diagnosticBadge,
  }) =>
      AppPreferences(
        theme: theme ?? this.theme,
        defaultMuted: defaultMuted ?? this.defaultMuted,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        diagnosticBadge: diagnosticBadge ?? this.diagnosticBadge,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'theme': theme.name,
        'defaultMuted': defaultMuted,
        'playbackSpeed': playbackSpeed,
        'diagnosticBadge': diagnosticBadge,
      };

  /// Tolerant decode: an unknown enum name falls back to the default for that
  /// field instead of failing the whole record. A theme value should never be
  /// able to stop the app from starting.
  static AppPreferences fromJson(Map<String, Object?> json) => AppPreferences(
        theme: ThemePreferenceWire.fromName(json['theme']),
        defaultMuted: json['defaultMuted'] == true,
        playbackSpeed: _speedFromJson(json['playbackSpeed']),
        diagnosticBadge: json['diagnosticBadge'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.theme == theme &&
      other.defaultMuted == defaultMuted &&
      other.playbackSpeed == playbackSpeed &&
      other.diagnosticBadge == diagnosticBadge;

  @override
  int get hashCode => Object.hash(
        theme,
        defaultMuted,
        playbackSpeed,
        diagnosticBadge,
      );

  @override
  String toString() => 'AppPreferences(theme=${theme.name}, '
      'speed=$playbackSpeed, badge=$diagnosticBadge)';
}

/// Persistence for [AppPreferences].
///
/// Stored through [SecretStore] rather than a plist so the same code runs in
/// unit tests against [MemorySecretStore]. The slot name is versioned: a future
/// shape gets a new key instead of being decoded as this one.
class PreferencesStore {
  PreferencesStore({required this.store});

  static const String storageKey = 'tg_app_prefs_v1';

  final SecretStore store;

  Future<AppPreferences> load() async {
    final raw = await store.read(storageKey);
    if (raw == null || raw.isEmpty) return AppPreferences.initial;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return AppPreferences.initial;
      return AppPreferences.fromJson(decoded.cast<String, Object?>());
    } on Object {
      // Corrupt record: start from defaults. Losing a theme choice is cheaper
      // than refusing to start because of one bad string.
      return AppPreferences.initial;
    }
  }

  Future<void> save(AppPreferences preferences) =>
      store.write(storageKey, jsonEncode(preferences.toJson()));
}

/// Change-notified wrapper the widget tree listens to.
///
/// Writes go through [PreferencesStore] and the in-memory value is only updated
/// after the write succeeds, so the UI cannot show a setting the app did not
/// keep.
class PreferencesController extends ChangeNotifier {
  PreferencesController({required this.store});

  final PreferencesStore store;

  AppPreferences _value = AppPreferences.initial;
  bool _loaded = false;
  bool _saving = false;
  Object? _lastError;

  AppPreferences get value => _value;
  bool get isLoaded => _loaded;
  bool get isSaving => _saving;
  Object? get lastError => _lastError;

  Future<void> load() async {
    _value = await store.load();
    _loaded = true;
    notifyListeners();
  }

  Future<void> update(AppPreferences next) async {
    if (next == _value) return;
    _saving = true;
    notifyListeners();
    try {
      await store.save(next);
      _value = next;
      _lastError = null;
    } on Object catch (e) {
      // The in-memory value is deliberately left untouched: a toggle that
      // appears on but did not persist is worse than one that bounces back.
      _lastError = e;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> setTheme(ThemePreference theme) =>
      update(_value.copyWith(theme: theme));

  Future<void> setDefaultMuted(bool muted) =>
      update(_value.copyWith(defaultMuted: muted));

  Future<void> setDiagnosticBadge(bool enabled) =>
      update(_value.copyWith(diagnosticBadge: enabled));

  /// Rejects a rate that is not in [kPlaybackSpeeds] instead of silently
  /// storing a clamp the player would not honour.
  Future<bool> setPlaybackSpeed(double speed) async {
    if (!kPlaybackSpeeds.any((value) => (value - speed).abs() < 0.001)) {
      return false;
    }
    await update(_value.copyWith(playbackSpeed: speed));
    return true;
  }
}
