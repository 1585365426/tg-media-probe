import 'dart:convert';

import 'package:path/path.dart' as p;

import '../storage/file_ops.dart';

/// Theme selection as the user sees it.
enum AppThemeMode { system, light, dark }

extension AppThemeModeWire on AppThemeMode {
  String get wire => switch (this) {
        AppThemeMode.system => 'system',
        AppThemeMode.light => 'light',
        AppThemeMode.dark => 'dark',
      };

  String get label => switch (this) {
        AppThemeMode.system => '跟随系统',
        AppThemeMode.light => '亮色',
        AppThemeMode.dark => '暗色',
      };

  static AppThemeMode fromWire(String? value) => switch (value) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        _ => AppThemeMode.system,
      };
}

/// Duration buckets used by the video filter bar.
///
/// Boundaries are inclusive on the lower edge and exclusive on the upper one
/// (`1-5 分钟` = 60 s ≤ d < 300 s) so every duration lands in exactly one
/// bucket and nothing is silently dropped by a rounding gap.
enum DurationFilter { all, underMinute, oneToFiveMinutes, overFiveMinutes }

extension DurationFilterRule on DurationFilter {
  String get wire => switch (this) {
        DurationFilter.all => 'all',
        DurationFilter.underMinute => 'lt60',
        DurationFilter.oneToFiveMinutes => '60to299',
        DurationFilter.overFiveMinutes => 'gte300',
      };

  String get label => switch (this) {
        DurationFilter.all => '全部时长',
        DurationFilter.underMinute => '1 分钟以内',
        DurationFilter.oneToFiveMinutes => '1-5 分钟',
        DurationFilter.overFiveMinutes => '5 分钟以上',
      };

  /// Null duration (TDLib reported none) only passes [all]: an unknown length
  /// cannot be proven to be inside a bucket, and quietly including it would
  /// make the filter lie.
  bool accepts(int? seconds) {
    switch (this) {
      case DurationFilter.all:
        return true;
      case DurationFilter.underMinute:
        return seconds != null && seconds < 60;
      case DurationFilter.oneToFiveMinutes:
        return seconds != null && seconds >= 60 && seconds < 300;
      case DurationFilter.overFiveMinutes:
        return seconds != null && seconds >= 300;
    }
  }

  static DurationFilter fromWire(String? value) => switch (value) {
        'lt60' => DurationFilter.underMinute,
        '60to299' => DurationFilter.oneToFiveMinutes,
        'gte300' => DurationFilter.overFiveMinutes,
        _ => DurationFilter.all,
      };
}

/// Everything the app remembers between launches, minus the passcode.
///
/// The passcode hash is **not** here: it lives in the Keychain (see
/// `lib/security/app_lock.dart`) because a plist in the container is readable
/// by anyone holding an unlocked device.
class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.muted = true,
    this.categoryChatId,
    this.durationFilter = DurationFilter.all,
  });

  final AppThemeMode themeMode;

  /// Speaker state. Persisted so tab switches and page pushes do not un-mute
  /// the feed behind the user's back.
  final bool muted;

  /// Selected category, expressed as the source chat id. Null means "all".
  final int? categoryChatId;

  final DurationFilter durationFilter;

  /// Value a fresh process starts with.
  ///
  /// The task book requires every cold start to begin muted so a video can
  /// never blast audio the moment the app opens. A stored `false` is therefore
  /// not honoured at startup — only after an explicit unmute tap.
  static const AppSettings coldStart = AppSettings(muted: true);

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? muted,
    Object? categoryChatId = _unset,
    DurationFilter? durationFilter,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        muted: muted ?? this.muted,
        categoryChatId: identical(categoryChatId, _unset)
            ? this.categoryChatId
            : categoryChatId as int?,
        durationFilter: durationFilter ?? this.durationFilter,
      );

  static const Object _unset = Object();

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'theme': themeMode.wire,
        'muted': muted,
        if (categoryChatId != null) 'category': categoryChatId,
        'duration': durationFilter.wire,
      };

  static AppSettings fromJson(Map<String, Object?> json) => AppSettings(
        themeMode: AppThemeModeWire.fromWire(json['theme'] as String?),
        muted: json['muted'] is bool ? json['muted']! as bool : true,
        categoryChatId: json['category'] is int ? json['category']! as int : null,
        durationFilter:
            DurationFilterRule.fromWire(json['duration'] as String?),
      );

  @override
  String toString() =>
      'AppSettings(theme=${themeMode.wire}, muted=$muted, '
      'category=$categoryChatId, duration=${durationFilter.wire})';
}

/// Persists [AppSettings] as a single JSON file written through `.tmp` + rename.
///
/// Lives in the protected zone (`Library/Application Support/tgmedia/secure/app`)
/// so "clear cache" can never erase a user's theme, mute state or filters.
class AppSettingsStore {
  AppSettingsStore({required this.directory, required this.ops});

  final String directory;
  final FileOps ops;

  String get filePath => p.join(directory, 'app_settings.json');
  String get _tmpPath => '$filePath.tmp';

  AppSettings _cached = AppSettings.coldStart;
  bool _loaded = false;

  AppSettings get value => _cached;

  /// Reads the stored settings and returns them with the cold-start override
  /// applied to [AppSettings.muted].
  ///
  /// A corrupt file is not an error worth failing over: the app falls back to
  /// defaults and the next [save] rewrites it.
  Future<AppSettings> load() async {
    if (_loaded) return _cached;
    _loaded = true;
    try {
      if (await ops.exists(filePath)) {
        final decoded = jsonDecode(await ops.readAsString(filePath));
        if (decoded is Map) {
          final parsed = AppSettings.fromJson(decoded.cast<String, Object?>());
          _cached = parsed.copyWith(muted: true);
          if (parsed.muted != true) {
            // Rewrite immediately so the on-disk value matches what the feed
            // is actually doing; otherwise a crash-then-restart would look
            // like the file "had" unmuted and the app "forgot" it.
            await save(_cached);
          }
          return _cached;
        }
      }
    } catch (_) {
      // Unreadable or malformed: defaults, then rewrite on first change.
    }
    _cached = AppSettings.coldStart;
    return _cached;
  }

  Future<void> save(AppSettings settings) async {
    _cached = settings;
    try {
      await ops.createDirectory(directory);
      await ops.writeAsString(_tmpPath, jsonEncode(settings.toJson()));
      await ops.rename(_tmpPath, filePath);
    } catch (_) {
      // Losing a preference is not worth crashing a playback session over.
    }
  }

  // ---- individual setters, all of which persist immediately ---------------

  Future<AppSettings> setTheme(AppThemeMode mode) {
    final next = _cached.copyWith(themeMode: mode);
    return save(next).then((_) => next);
  }

  Future<AppSettings> setMuted(bool muted) {
    final next = _cached.copyWith(muted: muted);
    return save(next).then((_) => next);
  }

  Future<AppSettings> setCategory(int? chatId) {
    final next = _cached.copyWith(categoryChatId: chatId);
    return save(next).then((_) => next);
  }

  Future<AppSettings> setDurationFilter(DurationFilter filter) {
    final next = _cached.copyWith(durationFilter: filter);
    return save(next).then((_) => next);
  }
}
