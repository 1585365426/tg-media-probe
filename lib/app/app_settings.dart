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

/// Duration buckets offered by the video tab.
///
/// Six real buckets plus [all]. Boundaries are half-open `[from, to)` so a
/// 60-second clip belongs to exactly one bucket and nothing falls between two.
enum DurationFilter {
  all,
  underMinute,
  oneToThreeMinutes,
  threeToFiveMinutes,
  fiveToTenMinutes,
  tenToTwentyMinutes,
  overTwentyMinutes,
}

extension DurationFilterRule on DurationFilter {
  String get wire => switch (this) {
        DurationFilter.all => 'all',
        DurationFilter.underMinute => 'lt60',
        DurationFilter.oneToThreeMinutes => '60to179',
        DurationFilter.threeToFiveMinutes => '180to299',
        DurationFilter.fiveToTenMinutes => '300to599',
        DurationFilter.tenToTwentyMinutes => '600to1199',
        DurationFilter.overTwentyMinutes => 'gte1200',
      };

  String get label => switch (this) {
        DurationFilter.all => '全部时长',
        DurationFilter.underMinute => '1 分钟以内',
        DurationFilter.oneToThreeMinutes => '1-3 分钟',
        DurationFilter.threeToFiveMinutes => '3-5 分钟',
        DurationFilter.fiveToTenMinutes => '5-10 分钟',
        DurationFilter.tenToTwentyMinutes => '10-20 分钟',
        DurationFilter.overTwentyMinutes => '20 分钟以上',
      };

  /// Shorter label for the chip row, where six buckets and the channel row have
  /// to share 375 pt.
  String get chipLabel => switch (this) {
        DurationFilter.all => '全部',
        DurationFilter.underMinute => '<1 分',
        DurationFilter.oneToThreeMinutes => '1-3 分',
        DurationFilter.threeToFiveMinutes => '3-5 分',
        DurationFilter.fiveToTenMinutes => '5-10 分',
        DurationFilter.tenToTwentyMinutes => '10-20 分',
        DurationFilter.overTwentyMinutes => '>20 分',
      };

  /// Null duration (TDLib reported none) only passes [all]: an unknown length
  /// cannot be proven to be inside a bucket, and quietly including it would
  /// make the filter lie.
  bool accepts(int? seconds) {
    if (this == DurationFilter.all) return true;
    if (seconds == null) return false;
    final bounds = _bounds;
    return seconds >= bounds.$1 && seconds < bounds.$2;
  }

  /// `[from, to)` in seconds. [overTwentyMinutes] has no upper bound, expressed
  /// as a very large int rather than infinity so the type stays comparable.
  (int, int) get _bounds => switch (this) {
        DurationFilter.all => (0, 1 << 31),
        DurationFilter.underMinute => (0, 60),
        DurationFilter.oneToThreeMinutes => (60, 180),
        DurationFilter.threeToFiveMinutes => (180, 300),
        DurationFilter.fiveToTenMinutes => (300, 600),
        DurationFilter.tenToTwentyMinutes => (600, 1200),
        DurationFilter.overTwentyMinutes => (1200, 1 << 31),
      };

  static DurationFilter fromWire(String? value) => switch (value) {
        'lt60' => DurationFilter.underMinute,
        '60to179' => DurationFilter.oneToThreeMinutes,
        '180to299' => DurationFilter.threeToFiveMinutes,
        '300to599' => DurationFilter.fiveToTenMinutes,
        '600to1199' => DurationFilter.tenToTwentyMinutes,
        'gte1200' => DurationFilter.overTwentyMinutes,
        // An older build stored a single 1-5 minute bucket. It spans two of the
        // new buckets, so picking either would silently hide half of what the
        // user had selected; resetting to 全部 is the only honest mapping.
        '60to299' => DurationFilter.all,
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
    this.streamingEnabled = true,
  });

  final AppThemeMode themeMode;

  /// Speaker state. Persisted so tab switches and page pushes do not un-mute
  /// the feed behind the user's back.
  final bool muted;

  /// Selected category, expressed as the source chat id. Null means "all".
  final int? categoryChatId;

  final DurationFilter durationFilter;

  /// Whether video playback may go through the loopback range server.
  ///
  /// On by default (it is the only thing that makes the first frame fast), but
  /// exposed in settings because it is the one component that depends on
  /// AVPlayer accepting `http://127.0.0.1`. If a device or iOS build refuses,
  /// the feed already falls back on its own after two failed items; this switch
  /// lets the user stop paying for the attempt instead of waiting it out.
  final bool streamingEnabled;

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
    bool? streamingEnabled,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        muted: muted ?? this.muted,
        categoryChatId: identical(categoryChatId, _unset)
            ? this.categoryChatId
            : categoryChatId as int?,
        durationFilter: durationFilter ?? this.durationFilter,
        streamingEnabled: streamingEnabled ?? this.streamingEnabled,
      );

  static const Object _unset = Object();

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'theme': themeMode.wire,
        'muted': muted,
        if (categoryChatId != null) 'category': categoryChatId,
        'duration': durationFilter.wire,
        'streaming': streamingEnabled,
      };

  static AppSettings fromJson(Map<String, Object?> json) => AppSettings(
        themeMode: AppThemeModeWire.fromWire(json['theme'] as String?),
        muted: json['muted'] is bool ? json['muted']! as bool : true,
        categoryChatId: json['category'] is int ? json['category']! as int : null,
        durationFilter:
            DurationFilterRule.fromWire(json['duration'] as String?),
        // Missing key means a settings file written before the switch existed.
        // Streaming was the default then and is the default now, so an absent
        // value must not silently disable it.
        streamingEnabled:
            json['streaming'] is bool ? json['streaming']! as bool : true,
      );

  @override
  String toString() =>
      'AppSettings(theme=${themeMode.wire}, muted=$muted, '
      'category=$categoryChatId, duration=${durationFilter.wire}, '
      'streaming=$streamingEnabled)';
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

  Future<AppSettings> setStreamingEnabled(bool enabled) {
    final next = _cached.copyWith(streamingEnabled: enabled);
    return save(next).then((_) => next);
  }
}
