/// User-visible preferences that are **not** part of the app lock.
///
/// Kept separate from `AppLockSettings` on purpose: the lock records a verifier
/// and is read on the cold-start path before anything else, while these values
/// are cosmetic and are read after the lock opens. Mixing them would make a
/// corrupted theme value able to break the unlock decision.
///
/// Scope notes, so later steps do not "restore" them by accident:
/// * No `onlyWifi` field. The product decision is "do not restrict by network
///   type", so there is nothing to persist and no toggle to render.
/// * No long-press action field. Long press does nothing on the feed; the
///   gesture is simply not bound.
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

/// How the video page treats device rotation.
///
/// `portraitPreferred` is the default from the spec: the feed stays portrait and
/// landscape is entered deliberately, one video at a time.
enum FeedDirection { portraitPreferred, allowLandscape }

extension FeedDirectionLabel on FeedDirection {
  String get label => switch (this) {
        FeedDirection.portraitPreferred => '竖屏优先',
        FeedDirection.allowLandscape => '允许横屏',
      };

  /// True when the page may rotate itself with the device. `portraitPreferred`
  /// still allows the explicit landscape button — it only stops *automatic*
  /// rotation from reflowing the feed while the user is scrolling.
  bool get followsDevice => this == FeedDirection.allowLandscape;

  static FeedDirection fromName(Object? name) {
    for (final value in FeedDirection.values) {
      if (value.name == name) return value;
    }
    return FeedDirection.portraitPreferred;
  }
}

@immutable
class AppPreferences {
  const AppPreferences({
    this.theme = ThemePreference.system,
    this.feedDirection = FeedDirection.portraitPreferred,
    this.defaultMuted = false,
    this.preloadAdjacent = true,
  });

  /// First launch. Nothing here turns anything on that the spec wants off:
  /// muting is off, theme follows the system, rotation is portrait-first.
  static const AppPreferences initial = AppPreferences();

  final ThemePreference theme;
  final FeedDirection feedDirection;

  /// Sound is on by default; a muted-by-default feed is a support ticket.
  final bool defaultMuted;

  /// Preloads at most the next item's player. Turned off automatically when the
  /// system reports memory pressure, without writing that back here.
  final bool preloadAdjacent;

  AppPreferences copyWith({
    ThemePreference? theme,
    FeedDirection? feedDirection,
    bool? defaultMuted,
    bool? preloadAdjacent,
  }) {
    return AppPreferences(
      theme: theme ?? this.theme,
      feedDirection: feedDirection ?? this.feedDirection,
      defaultMuted: defaultMuted ?? this.defaultMuted,
      preloadAdjacent: preloadAdjacent ?? this.preloadAdjacent,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'theme': theme.name,
        'feedDirection': feedDirection.name,
        'defaultMuted': defaultMuted,
        'preloadAdjacent': preloadAdjacent,
      };

  /// Tolerant decode: an unknown enum name falls back to the default for that
  /// field instead of failing the whole record. A theme value should never be
  /// able to stop the app from starting.
  static AppPreferences fromJson(Map<String, Object?> json) {
    return AppPreferences(
      theme: ThemePreferenceWire.fromName(json['theme']),
      feedDirection: FeedDirectionLabel.fromName(json['feedDirection']),
      defaultMuted: json['defaultMuted'] == true,
      preloadAdjacent: json['preloadAdjacent'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.theme == theme &&
      other.feedDirection == feedDirection &&
      other.defaultMuted == defaultMuted &&
      other.preloadAdjacent == preloadAdjacent;

  @override
  int get hashCode =>
      Object.hash(theme, feedDirection, defaultMuted, preloadAdjacent);

  @override
  String toString() =>
      'AppPreferences(theme=${theme.name}, dir=${feedDirection.name}, '
      'muted=$defaultMuted, preload=$preloadAdjacent)';
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

  Future<void> setFeedDirection(FeedDirection direction) =>
      update(_value.copyWith(feedDirection: direction));

  Future<void> setDefaultMuted(bool muted) =>
      update(_value.copyWith(defaultMuted: muted));

  Future<void> setPreloadAdjacent(bool enabled) =>
      update(_value.copyWith(preloadAdjacent: enabled));
}
