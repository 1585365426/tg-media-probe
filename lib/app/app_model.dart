import 'package:flutter/material.dart';

import '../data/media_record.dart';
import '../td/td_models.dart';
import 'app_services.dart';
import 'app_settings.dart';

/// UI-facing state: current settings, sign-in state, known channels.
///
/// Separate from [AppServices] because this object changes on every tap while
/// the services object is built once. Widgets listen to this; services are read
/// through it.
class AppModel extends ChangeNotifier {
  AppModel({required this.services})
      : _settings = services.settingsStore.value;

  final AppServices services;

  AppSettings _settings;
  AppSettings get settings => _settings;

  bool _signedIn = false;
  bool get signedIn => _signedIn;

  List<ChatSummary> _channels = const <ChatSummary>[];
  List<ChatSummary> get channels => _channels;

  /// Last sync outcome, shown on the channel tab. Null before the first run.
  String? _syncStatus;
  String? get syncStatus => _syncStatus;

  bool _syncing = false;
  bool get syncing => _syncing;

  ThemeMode get themeMode => switch (_settings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  bool get muted => _settings.muted;

  /// Favourite keys, kept in the model so list rows rebuild without touching
  /// the store on every frame.
  final Set<String> _favoriteKeys = <String>{};
  Set<String> get favoriteKeys => _favoriteKeys;

  void hydrateFavorites() {
    _favoriteKeys
      ..clear()
      ..addAll(services.favorites.keys);
    notifyListeners();
  }

  bool isFavorite(MediaRecord record) => _favoriteKeys.contains(record.key);

  Future<void> toggleFavorite(MediaRecord record) async {
    final nowFavorite = await services.favorites.toggle(record);
    if (nowFavorite) {
      _favoriteKeys.add(record.key);
    } else {
      _favoriteKeys.remove(record.key);
    }
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    _settings = await services.settingsStore.setTheme(mode);
    notifyListeners();
  }

  Future<void> setMuted(bool muted) async {
    _settings = await services.settingsStore.setMuted(muted);
    notifyListeners();
  }

  Future<void> setCategory(int? chatId) async {
    _settings = await services.settingsStore.setCategory(chatId);
    notifyListeners();
  }

  Future<void> setDurationFilter(DurationFilter filter) async {
    _settings = await services.settingsStore.setDurationFilter(filter);
    notifyListeners();
  }

  void markSignedIn(bool value) {
    _signedIn = value;
    notifyListeners();
  }

  void setChannels(List<ChatSummary> channels) {
    _channels = List<ChatSummary>.unmodifiable(channels);
    notifyListeners();
  }

  void setSyncing(bool value, {String? status}) {
    _syncing = value;
    if (status != null) _syncStatus = status;
    notifyListeners();
  }

  void setSyncStatus(String status) {
    _syncStatus = status;
    notifyListeners();
  }

  /// Whether the video tab's search bar is expanded.
  ///
  /// Lives here rather than inside the video page because the search icon sits
  /// in the shell's app bar — the two widgets must agree without one holding a
  /// GlobalKey to the other.
  bool _searchOpen = false;
  bool get searchOpen => _searchOpen;

  String _searchText = '';
  String get searchText => _searchText;

  void toggleSearch() {
    _searchOpen = !_searchOpen;
    if (!_searchOpen) _searchText = '';
    notifyListeners();
  }

  void setSearchText(String value) {
    if (_searchText == value) return;
    _searchText = value;
    notifyListeners();
  }

  void closeSearch() {
    if (!_searchOpen && _searchText.isEmpty) return;
    _searchOpen = false;
    _searchText = '';
    notifyListeners();
  }
}

/// Makes services + model reachable without adding a state-management package.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.services,
    required this.model,
    required super.child,
  });

  final AppServices services;
  final AppModel model;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this widget');
    return scope!;
  }

  /// Non-listening read, for callbacks that must not rebuild on every notify.
  static AppScope read(BuildContext context) {
    final element = context.getElementForInheritedWidgetOfExactType<AppScope>();
    final scope = element?.widget as AppScope?;
    assert(scope != null, 'AppScope missing above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      oldWidget.services != services || oldWidget.model != model;
}
