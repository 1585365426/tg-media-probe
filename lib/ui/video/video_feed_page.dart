import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/app_model.dart';
import '../../app/app_services.dart';
import '../../app/app_settings.dart';
import '../../data/channel_sync.dart';
import '../../data/media_record.dart';
import '../../data/video_query.dart';
import '../../platform/orientation_controller.dart';
import '../../platform/video_rotation.dart';
import '../../playback/video_player_handle.dart';
import 'video_tile.dart';

/// Vertical feed, one video at a time.
///
/// Ownership model, which is what keeps the "never two players" rule honest:
/// the page owns the single [SinglePlayerController] slot; a [VideoTile] is
/// stateless and only paints the controller handed to it. Swiping therefore
/// cannot start a second player — the old one is released before the new path
/// is even resolved.
///
/// Mute model:
/// * [AppSettings.coldStart] is muted, so a fresh process never makes noise;
/// * the current value is written back to settings, so tab switches and page
///   pushes inherit it;
/// * each newly activated player gets `setVolume(muted ? 0 : 1)` explicitly,
///   because AVPlayer defaults back to 1.0 per item.
class VideoFeedPage extends StatefulWidget {
  const VideoFeedPage({
    super.key,
    required this.active,
    this.onExit,
  });

  /// False while another tab is in front. Playback is released when it flips.
  final bool active;

  /// Called when the back button is pressed with nothing left to clear.
  final VoidCallback? onExit;

  @override
  State<VideoFeedPage> createState() => _VideoFeedPageState();
}

class _VideoFeedPageState extends State<VideoFeedPage> {
  static const int pageSize = 40;

  late AppModel _model;
  late AppServices _services;

  MediaPager? _pager;
  final List<MediaRecord> _all = <MediaRecord>[];
  List<MediaRecord> _filtered = const <MediaRecord>[];
  VideoQuery _query = VideoQuery.none;

  final PageController _pageController = PageController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  int _current = 0;
  bool _initialized = false;
  bool _loadingPage = false;
  bool _firstPageDone = false;
  String? _loadError;

  final Map<String, String> _paths = <String, String>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, double> _progress = <String, double>{};

  VideoPlayerController? _visible;

  /// Bumped on every activation so a slow download that finishes after the user
  /// already swiped away cannot install itself over the current video.
  int _activationToken = 0;

  bool _muted = true;
  int? _rotation;
  bool _landscape = false;

  /// `mounted` stays true while `dispose` runs, so a bare `mounted` check is
  /// not enough to keep `setState` out of a defunct element.
  bool _disposed = false;

  VideoPlayerController? _loopController;
  bool _seekingBack = false;

  final OrientationBridge _orientation = OrientationBridge();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _services = scope.services;
    _model = scope.model;
    _model.addListener(_onModelChanged);
    _muted = _model.muted;
    _loadFirstPage();
  }

  @override
  void didUpdateWidget(VideoFeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      // Tab switched away: free the decoder immediately rather than waiting for
      // the shell's lifecycle binder (both paths are idempotent).
      _releasePlayer();
    } else if (!oldWidget.active && widget.active) {
      _activateCurrent();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _model.removeListener(_onModelChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _pageController.dispose();
    _releasePlayer();
    _orientation.resetToSystem();
    super.dispose();
  }

  // ---- data --------------------------------------------------------------

  Future<void> _loadFirstPage() async {
    _pager = MediaPager(store: _services.index, pageSize: pageSize);
    _all.clear();
    await _loadMore();
    if (!mounted) return;
    setState(() {
      _firstPageDone = true;
      _rebuildFiltered();
    });
    if (widget.active) _activateCurrent();
  }

  Future<void> _loadMore() async {
    final pager = _pager;
    if (pager == null || _loadingPage || !pager.hasMore) return;
    _loadingPage = true;
    try {
      final page = await pager.next();
      if (!mounted) return;
      for (final record in page.items) {
        if (record.kind == MediaKind.video ||
            record.kind == MediaKind.animation) {
          _all.add(record);
        }
      }
    } catch (e) {
      if (!mounted) return;
      _loadError = e.toString();
    } finally {
      _loadingPage = false;
    }
  }

  void _rebuildFiltered() {
    _filtered = VideoQueryEngine.apply(
      _all,
      _query,
      titleOf: (id) => _services.chatTitles.labelOf(id),
    );
    if (_filtered.isEmpty) {
      _current = 0;
    } else if (_current >= _filtered.length) {
      _current = _filtered.length - 1;
    }
  }

  /// Dragging the page window wider while searching: a query can match a row
  /// that has not been paged in yet, so an empty result is only believable once
  /// the index is exhausted or the attempt budget is spent.
  Future<void> _widenForSearch() async {
    var rounds = 0;
    while (_query.hasText &&
        _filtered.isEmpty &&
        _pager != null &&
        _pager!.hasMore &&
        rounds < 8) {
      await _loadMore();
      rounds++;
      if (!mounted) return;
      setState(_rebuildFiltered);
    }
  }

  // ---- playback ----------------------------------------------------------

  Future<void> _activateCurrent() async {
    if (!widget.active || !_initialized) return;
    if (_filtered.isEmpty) return;

    final record = _filtered[_current];
    final key = record.key;
    final token = ++_activationToken;

    if (_errors.containsKey(key)) {
      if (mounted) setState(() => _visible = null);
      return;
    }

    var path = _paths[key];
    if (path == null) {
      if (mounted) setState(() => _progress[key] = 0);
      try {
        final result = await _services.resolver.ensureLocal(
          record,
          onProgress: (p) {
            if (!mounted || token != _activationToken) return;
            setState(() => _progress[key] = p.fraction);
          },
        );
        path = result.path;
        _paths[key] = path;
      } catch (e) {
        if (!mounted || token != _activationToken) return;
        setState(() {
          _progress.remove(key);
          _errors[key] = _humanError(e);
        });
        return;
      }
    }
    if (!mounted || token != _activationToken) return;
    if (_filtered.isEmpty || _filtered[_current].key != key) return;

    final rotation = await const VideoRotationReader().readRotationDegrees(path);
    if (!mounted || token != _activationToken) return;

    try {
      await _services.player.activate(path, autoplay: true);
    } catch (e) {
      if (!mounted || token != _activationToken) return;
      setState(() {
        _progress.remove(key);
        _errors[key] = '播放失败：$e';
      });
      return;
    }
    if (!mounted || token != _activationToken) return;

    final handle = _services.player.active;
    if (handle is VideoPlayerHandle) {
      // Every new item: force the current mute state. AVPlayer resets volume
      // per item, so skipping this is exactly how a feed surprises the user
      // with audio after a swipe.
      await handle.setVolume(_muted ? 0 : 1);
      _attachLoopGuard(handle.controller);
      if (!mounted) return;
      setState(() {
        _visible = handle.controller;
        _rotation = rotation;
        _progress.remove(key);
      });
    }
  }

  void _attachLoopGuard(VideoPlayerController? controller) {
    if (identical(_loopController, controller)) return;
    _loopController?.removeListener(_onPlaybackTick);
    _loopController = controller;
    _loopController?.addListener(_onPlaybackTick);
  }

  /// Single-video looping: seek to 0 and keep playing. Head-of-list looping is
  /// intentionally absent — `PageView` clamps at index 0.
  void _onPlaybackTick() {
    final controller = _loopController;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized || value.duration <= Duration.zero) return;
    final atEnd = value.isCompleted ||
        value.position >= value.duration - const Duration(milliseconds: 150);
    if (!atEnd || _seekingBack) return;
    _seekingBack = true;
    controller.seekTo(Duration.zero).then((_) {
      _seekingBack = false;
      if (mounted) controller.play();
    }).catchError((Object _) {
      _seekingBack = false;
    });
  }

  void _releasePlayer() {
    _activationToken++;
    _attachLoopGuard(null);
    _services.player.release();
    if (!_disposed && mounted) setState(() => _visible = null);
  }

  void _onPageChanged(int index) {
    setState(() {
      _current = index;
      _visible = null;
      _rotation = null;
    });
    // Old player goes first: pause + dispose before the next path resolves.
    _releasePlayer();
    _activateCurrent();
    if (_filtered.isNotEmpty && index >= _filtered.length - 2) {
      _loadMoreThenRefresh();
    }
  }

  Future<void> _loadMoreThenRefresh() async {
    await _loadMore();
    if (!mounted) return;
    setState(_rebuildFiltered);
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    await _model.setMuted(next);
    final handle = _services.player.active;
    if (handle != null) await handle.setVolume(next ? 0 : 1);
  }

  Future<void> _toggleOrientation() async {
    final next = !_landscape;
    setState(() => _landscape = next);
    await _orientation.setMode(
      next
          ? ScreenOrientationMode.forcedLandscape
          : ScreenOrientationMode.lockedPortrait,
    );
  }

  void _onBack() {
    if (_model.searchOpen) {
      _model.closeSearch();
      return;
    }
    if (_query.isActive) {
      _model.setCategory(null);
      _model.setDurationFilter(DurationFilter.all);
      _searchController.clear();
      return;
    }
    widget.onExit?.call();
  }

  // ---- model changes -----------------------------------------------------

  void _onModelChanged() {
    if (!mounted) return;
    if (_muted != _model.muted) _muted = _model.muted;

    final next = VideoQuery(
      text: _model.searchText,
      categoryChatId: _model.settings.categoryChatId,
      duration: _model.settings.durationFilter,
    );
    if (next == _query) {
      // Favourite toggles and sync counters also notify; just repaint.
      setState(() {});
      return;
    }
    _query = next;
    setState(_rebuildFiltered);
    _widenForSearch();
    _releasePlayer();
    _activateCurrent();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      _model.setSearchText(value);
    });
    setState(() {});
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context).model;
    final theme = Theme.of(context);

    if (!model.signedIn) {
      return _message(
        icon: Icons.play_disabled_outlined,
        title: '登录后查看频道视频',
        body: '视频页展示 Telegram 频道里的视频。请先在「频道」页登录并同步。',
        theme: theme,
      );
    }

    return Column(
      children: <Widget>[
        if (model.searchOpen) _searchBar(theme),
        _filterBar(theme),
        if (_loadError != null)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _loadError!,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: 11,
              ),
            ),
          ),
        Expanded(child: _feed(theme)),
      ],
    );
  }

  Widget _feed(ThemeData theme) {
    if (!_firstPageDone) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filtered.isEmpty) {
      return _message(
        icon: _query.isActive ? Icons.search_off : Icons.video_library_outlined,
        title: _query.isActive ? '没有匹配的视频' : '索引里还没有视频',
        body: _query.isActive
            ? '换个关键词，或清空搜索与筛选条件后重试。当前只搜索本地已同步的 ${_all.length} 条记录。'
            : '到「频道」页点「同步频道与消息」，把频道里的视频读进本地索引。',
        action: _query.isActive
            ? TextButton(
                onPressed: () {
                  _searchController.clear();
                  _model.closeSearch();
                  _model.setCategory(null);
                  _model.setDurationFilter(DurationFilter.all);
                },
                child: const Text('清空条件'),
              )
            : null,
        theme: theme,
      );
    }

    return PageView.builder(
      scrollDirection: Axis.vertical,
      controller: _pageController,
      itemCount: _filtered.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        final record = _filtered[index];
        final isCurrent = index == _current;
        return VideoTile(
          record: record,
          channelTitle: _services.chatTitles.labelOf(record.chatId),
          controller: isCurrent ? _visible : null,
          muted: _muted,
          favorite: _model.isFavorite(record),
          progress: _progress[record.key],
          error: _errors[record.key],
          rotationDegrees: isCurrent ? _rotation : null,
          landscape: _landscape,
          isCurrent: isCurrent,
          onToggleMute: _toggleMute,
          onToggleFavorite: () => _model.toggleFavorite(record),
          onBack: _onBack,
          onToggleOrientation: _toggleOrientation,
        );
      },
    );
  }

  Widget _searchBar(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          controller: _searchController,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索消息文本或频道名称',
            prefixIcon: const Icon(Icons.search, size: 20),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear, size: 18),
              tooltip: '清空搜索',
              onPressed: () {
                _searchController.clear();
                _model.closeSearch();
              },
            ),
          ),
        ),
      );

  Widget _filterBar(ThemeData theme) {
    final categories = VideoQueryEngine.chatIdsOf(_all);
    return Container(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                for (final filter in DurationFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(filter.label, style: const TextStyle(fontSize: 12)),
                      selected: _query.duration == filter,
                      onSelected: (_) {
                        _model.setDurationFilter(filter);
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('全部频道', style: TextStyle(fontSize: 12)),
                    selected: _query.categoryChatId == null,
                    onSelected: (_) => _model.setCategory(null),
                  ),
                ),
                for (final chatId in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(
                        _services.chatTitles.labelOf(chatId),
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _query.categoryChatId == chatId,
                      onSelected: (_) => _model.setCategory(
                        _query.categoryChatId == chatId ? null : chatId,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String body,
    required ThemeData theme,
    Widget? action,
  }) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 46, color: theme.disabledColor),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              if (action != null) ...<Widget>[const SizedBox(height: 12), action],
            ],
          ),
        ),
      );

  static String _humanError(Object error) {
    final text = error.toString();
    if (text.contains('ResolveException(protected')) {
      return '该内容受保护，无法保存到本地播放';
    }
    if (text.contains('ResolveException(timeout')) {
      return '下载超时，下拉可重试';
    }
    if (text.contains('ResolveException(file-id')) {
      return '该消息没有可用的文件标识';
    }
    if (text.contains('promote')) {
      return '下载完成但复制到下载区失败：$text';
    }
    return text;
  }
}
