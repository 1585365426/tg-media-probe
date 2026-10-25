import 'app_settings.dart';
import '../data/channel_sync.dart';
import '../data/chat_title_store.dart';
import '../data/favorites_store.dart';
import '../data/history_source.dart';
import '../data/index_store.dart';
import '../data/media_resolver.dart';
import '../playback/playback_lifecycle.dart';
import '../playback/player_slot.dart';
import '../playback/video_player_handle.dart';
import '../security/app_lock.dart';
import '../security/biometric.dart';
import '../security/tdlib_key.dart';
import '../storage/active_files.dart';
import '../storage/app_paths.dart';
import '../storage/cache_manager.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';
import '../td/td_client.dart';

/// Composition root: every long-lived object the UI needs, wired once.
///
/// Nothing here reaches into a widget, and nothing is a global singleton — the
/// app builds one of these in `main()`, which keeps the storage layout, the
/// active-file registry and the single-player slot sharing one instance
/// (two registries would let the cache cleaner delete a file that is playing).
class AppServices {
  AppServices({
    required this.layout,
    required this.ops,
    required this.settingsStore,
    required this.favorites,
    required this.chatTitles,
    required this.index,
    required this.cache,
    required this.activeFiles,
    required this.appLock,
    required this.biometrics,
    required this.player,
    required this.binder,
  });

  final StorageLayout layout;
  final FileOps ops;
  final AppSettingsStore settingsStore;
  final FavoritesStore favorites;
  final ChatTitleStore chatTitles;
  final IndexStore index;
  final CacheManager cache;
  final ActiveFileRegistry activeFiles;
  final AppLock appLock;
  final BiometricService biometrics;
  final SinglePlayerController player;
  final PlaybackLifecycleBinder binder;

  TdClient? _client;
  MediaResolver? _resolver;
  ChannelSyncEngine? _sync;
  HistorySource? _history;

  TdClient? get client => _client;
  bool get hasClient => _client != null;

  MediaResolver get resolver {
    final value = _resolver;
    if (value == null) throw StateError('TDLib 客户端尚未就绪');
    return value;
  }

  ChannelSyncEngine get sync {
    final value = _sync;
    if (value == null) throw StateError('TDLib 客户端尚未就绪');
    return value;
  }

  /// Wires the TDLib client in after login.
  void attachClient(TdClient client) {
    _client = client;
    _history = TdHistorySource(client);
    _resolver = MediaResolver(client: client, layout: layout, ops: ops);
    _sync = ChannelSyncEngine(source: _history!, store: index);
  }

  Future<void> dispose() async {
    binder.handlePageDispose();
    await player.releaseAll();
    await _client?.dispose();
    // Closing the store flushes nothing (journal appends are already on disk)
    // but stops late writes from a screen that is being torn down.
    await index.close();
  }

  /// Builds everything that does not need a logged-in Telegram session.
  ///
  /// Order matters: the storage layout must exist before any store opens, and
  /// the integrity probe must be bound to the same [IndexStore] instance the
  /// sync writes to, or a cache clear would compare counters from two
  /// different mirrors and "detect" a regression that never happened.
  static Future<AppServices> bootstrap({FileOps? fileOps}) async {
    final ops = fileOps ?? const IoFileOps();
    final layout = await AppPaths.resolveLayout(ops: ops);
    await layout.ensureCreated();

    final settingsStore = AppSettingsStore(
      directory: layout.settingsDir,
      ops: ops,
    );
    await settingsStore.load();

    final favorites = FavoritesStore(directory: layout.indexDir, ops: ops);
    await favorites.open();

    final chatTitles = ChatTitleStore(directory: layout.indexDir, ops: ops);
    await chatTitles.open();

    final index = IndexStore(directory: layout.indexDir, ops: ops);
    await index.open();

    final activeFiles = ActiveFileRegistry();
    final cache = CacheManager(
      layout: layout,
      ops: ops,
      activeFiles: activeFiles,
      integrityProbe: () async {
        final counters = await index.integritySnapshot();
        return <String, int>{
          ...counters,
          'localFavorites': favorites.count,
          'chatTitles': chatTitles.count,
        };
      },
    );

    final player = SinglePlayerController(
      factory: const VideoPlayerFactory(),
      activeFiles: activeFiles,
    );
    final binder = PlaybackLifecycleBinder(controller: player);

    return AppServices(
      layout: layout,
      ops: ops,
      settingsStore: settingsStore,
      favorites: favorites,
      chatTitles: chatTitles,
      index: index,
      cache: cache,
      activeFiles: activeFiles,
      appLock: AppLock(store: const KeychainSecretStore()),
      biometrics: BiometricService(backend: LocalAuthBackend()),
      player: player,
      binder: binder,
    );
  }
}
