/// Full-screen vertical video feed (§4).
///
/// Layout rules the task book is explicit about, kept in one place:
/// * no right-hand action column — no like, comment, share, favourite or
///   download;
/// * three overlay layers only: top bar, bottom info block, controls;
/// * the bottom info block is hidden in landscape;
/// * the search entry lives in the top bar and searches the **local** channel
///   directory, never Telegram.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../data/channel_directory.dart';
import '../platform/orientation_controller.dart';
import '../playback/player_slot.dart';
import '../playback/video_player_handle.dart';
import '../playback/video_source.dart';
import '../storage/active_files.dart';
import '../util/byte_format.dart';
import 'app_theme.dart';
import 'feed_controller.dart';
import 'status_view.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({
    super.key,
    required this.session,
    required this.preferences,
    this.initialChatId,
    this.initialMessageId,
    this.showBackButton = false,
    this.activeFiles,
    this.orientation,
    this.isActive = true,
  });

  final AppSession session;
  final AppPreferences preferences;

  /// When set, the feed is limited to one channel.
  final int? initialChatId;

  /// When set, the feed opens on this message (the row the user tapped).
  final int? initialMessageId;

  /// True when the page was pushed as a route (channel detail -> play).
  final bool showBackButton;

  /// Shared registry so a cache clear cannot delete a file mid-playback.
  final ActiveFileRegistry? activeFiles;

  final OrientationBridge? orientation;

  /// False while the shell shows another tab. The feed releases its decoder
  /// instead of playing audio behind the settings page.
  final bool isActive;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with WidgetsBindingObserver {
  late final OrientationBridge _orientation;
  late final PageOrientationScope _orientationScope;

  final PageController _pager = PageController();
  late final ActiveFileRegistry _activeFiles;

  FeedController? _controller;
  int? _chatFilter;
  bool _isLandscape = false;
  bool _rotationHintBusy = false;
  bool _disposed = false;
  String? _rotationHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _orientation = widget.orientation ?? OrientationBridge();
    _orientationScope = PageOrientationScope(
      _orientation,
      mode: ScreenOrientationMode.lockedPortrait,
    );
    _activeFiles = widget.activeFiles ?? ActiveFileRegistry();
    _chatFilter = widget.initialChatId;
    _orientationScope.enter();
    _rebuildController();
  }

  /// Builds (or rebuilds) the controller for the current channel filter.
  ///
  /// A filter change is a different pager, so a new controller is the honest
  /// representation — reusing one would keep the old page cursor.
  void _rebuildController() {
    final store = widget.session.feedStore;
    final client = widget.session.client;
    if (store == null || client == null) return;

    final previous = _controller;
    if (previous != null) {
      previous.removeListener(_onControllerChanged);
      previous.shutdown();
      previous.dispose();
    }

    final titles = widget.session.directory?.titles ?? const <int, String>{};
    final controller = FeedController(
      source: IndexFeedSource(store: store, chatId: _chatFilter),
      player: SinglePlayerController(
        factory: const VideoPlayerFactory(),
        activeFiles: _activeFiles,
      ),
      sources: VideoSourceResolver(api: TdFileTransferApi(client)),
      chatTitles: titles,
      defaultMuted: widget.preferences.defaultMuted,
      preloadAdjacent: widget.preferences.preloadAdjacent,
    );
    controller.addListener(_onControllerChanged);
    _controller = controller;
    final messageId = widget.initialMessageId;
    final chatId = _chatFilter;
    unawaited(() async {
      await controller.load();
      // Tapping a row must open that video, not just the channel: load() lands
      // on the newest item, so jump once the index has a first page.
      if (messageId == null || chatId == null) return;
      await controller.goToMessage(chatId, messageId);
    }());
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller?.handleLifecycle(state);
  }

  @override
  void didUpdateWidget(FeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    // Tab switch: same lifecycle contract as backgrounding.
    _controller?.handleLifecycle(
      widget.isActive ? AppLifecycleState.resumed : AppLifecycleState.paused,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pure layout state: no controller notification here, or setState would be
    // called during build.
    _isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      controller.shutdown();
      controller.dispose();
    }
    _orientationScope.dispose();
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        backgroundColor: AppTheme.feedBackground,
        body: const StatusView(
          kind: StatusKind.error,
          title: '尚未登录',
          message: '登录 Telegram 后才有可播放的内容。',
        ),
      );
    }
    final overlays = FeedOverlayPlan.forOrientation(
      MediaQuery.of(context).orientation,
    );
    return Scaffold(
      backgroundColor: AppTheme.feedBackground,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildPager(controller),
            if (overlays.showTopBar) _buildTopBar(),
            if (overlays.showInfo) _buildInfo(controller),
            if (overlays.showControls && controller.controlVisible)
              _buildControls(controller),
            if (_rotationHint != null) _buildRotationHint(),
          ],
        ),
      ),
    );
  }

  Widget _buildPager(FeedController controller) {
    switch (controller.phase) {
      case FeedPhase.idle:
      case FeedPhase.loading:
        return const StatusView.loading(title: '正在准备视频');
      case FeedPhase.empty:
        return StatusView.empty(
          title: '该频道暂无视频',
          message: '同步完成后这里会出现可播放的视频。',
          actionLabel: '刷新',
          onAction: controller.retry,
        );
      case FeedPhase.error:
        return FailureView(
          failure: controller.failure,
          detail: controller.error,
          onRetry: controller.retry,
        );
      case FeedPhase.buffering:
      case FeedPhase.ready:
        return PageView.builder(
          controller: _pager,
          scrollDirection: Axis.vertical,
          itemCount: controller.length,
          onPageChanged: (index) {
            // The pager already moved; the controller releases the old player
            // before resolving the new item.
            controller.goToIndex(index);
            if (index >= controller.length - 1) controller.goNext();
          },
          itemBuilder: (context, index) => _buildPage(controller, index),
        );
    }
  }

  Widget _buildPage(FeedController controller, int index) {
    final isCurrent = index == controller.index;
    final handle = controller.player.active;
    final controllerValue = handle is VideoPlayerHandle
        ? handle.controller?.value
        : null;
    final initialized =
        isCurrent && controllerValue != null && controllerValue.isInitialized;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.toggleControls,
      onDoubleTap: controller.togglePlayPause,
      // Long press is deliberately unbound: the confirmed decision is "no
      // action", so no handler is registered at all.
      child: ColoredBox(
        color: AppTheme.feedBackground,
        child: initialized
            ? _buildVideoSurface(controllerValue)
            : _buildBuffering(controller, isCurrent),
      ),
    );
  }

  Widget _buildVideoSurface(VideoPlayerValue value) {
    final controller = _activeController;
    if (controller == null) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
        ),
      );
    }
    final ratio = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
    final video = VideoPlayer(controller);
    // Portrait-ish content fills the screen (cover); anything wider keeps its
    // whole frame with letterboxing (contain). §4.1: never stretch.
    if (ratio < 0.95) {
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(width: ratio * 1000, height: 1000, child: video),
        ),
      );
    }
    return Center(child: AspectRatio(aspectRatio: ratio, child: video));
  }

  VideoPlayerController? get _activeController {
    final handle = _controller?.player.active;
    if (handle is VideoPlayerHandle) return handle.controller;
    return null;
  }

  Widget _buildBuffering(FeedController controller, bool isCurrent) {
    if (!isCurrent) {
      return const Center(
        child: Icon(Icons.play_circle_outline, color: Colors.white24, size: 56),
      );
    }
    final fraction = controller.bufferFraction;
    final label = fraction > 0
        ? '正在缓冲 ${(fraction * 100).round()}%'
        : '正在准备视频…';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final directory = widget.session.directory;
    final title = _chatFilter == null
        ? '视频'
        : (directory?.titles[_chatFilter] ?? '视频');
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0x66000000), Color(0x00000000)],
          ),
        ),
        child: Row(
          children: <Widget>[
            if (widget.showBackButton)
              IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Search stays on the feed page (confirmed decision #3) and reads
            // the local channel list only.
            IconButton(
              tooltip: '搜索频道',
              icon: const Icon(Icons.search, color: Colors.white),
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(FeedController controller) {
    final record = controller.current;
    if (record == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: <Color>[Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                controller.titleOf(record),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${controller.currentChannelTitle} · '
                '${_formatDate(record.messageDateUnix)}'
                '${record.sizeBytes > 0 ? ' · ${formatBytes(record.sizeBytes)}' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                controller.positionLabel,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 64),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(FeedController controller) {
    final duration = controller.duration;
    final position = controller.position;
    final total = duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds;
    final value = position.inMilliseconds.clamp(0, total).toDouble();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: controller.isPlaying ? '暂停' : '播放',
              icon: Icon(
                controller.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: controller.togglePlayPause,
            ),
            Text(
              _formatDuration(position),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: value,
                max: total.toDouble(),
                onChanged: (next) =>
                    controller.seekTo(Duration(milliseconds: next.round())),
              ),
            ),
            Text(
              _formatDuration(duration),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            IconButton(
              tooltip: controller.muted ? '取消静音' : '静音',
              icon: Icon(
                controller.muted ? Icons.volume_off : Icons.volume_up,
                color: Colors.white,
              ),
              onPressed: () => controller.setMuted(!controller.muted),
            ),
            IconButton(
              tooltip: _isLandscape ? '退出横屏' : '横屏',
              icon: const Icon(Icons.screen_rotation, color: Colors.white),
              onPressed: _toggleLandscape,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRotationHint() {
    return Positioned(
      left: 16,
      right: 16,
      top: 64,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        ),
        child: Text(
          _rotationHint!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }

  /// Rotates natively, then **verifies** that the screen actually rotated.
  ///
  /// iOS refuses the geometry update without an error when the user has the
  /// system orientation lock on. Reporting success without checking would be the
  /// "button does nothing" failure the spec forbids.
  Future<void> _toggleLandscape() async {
    if (_rotationHintBusy) return;
    _rotationHintBusy = true;
    final target = _isLandscape
        ? ScreenOrientationMode.lockedPortrait
        : ScreenOrientationMode.forcedLandscape;
    try {
      await _orientation.setMode(target);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || _disposed) return;

      final wanted = target == ScreenOrientationMode.forcedLandscape
          ? Orientation.landscape
          : Orientation.portrait;
      if (MediaQuery.of(context).orientation == wanted) return;

      setState(() => _rotationHint = '系统方向锁已开启，无法自动旋转');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || _disposed) return;
      setState(() => _rotationHint = null);
    } finally {
      _rotationHintBusy = false;
    }
  }

  Future<void> _openSearch() async {
    final directory = widget.session.directory;
    if (directory == null) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ChannelPicker(directory: directory),
    );
    if (!mounted || _disposed || picked == null) return;
    setState(() {
      _chatFilter = picked == _allChannels ? null : picked;
    });
    _rebuildController();
    if (_pager.hasClients) _pager.jumpToPage(0);
  }

  static const int _allChannels = -1;

  static String _formatDate(int unixSeconds) {
    if (unixSeconds <= 0) return '日期未知';
    final date = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Channel picker backed by the local directory.
///
/// Pops `-1` for "all channels", a chat id for one channel, or null when
/// dismissed. The list and the filtering both come from
/// [ChannelDirectory.search], which never touches the network.
class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker({required this.directory});

  final ChannelDirectory directory;

  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends State<_ChannelPicker> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.directory.search(_query.text);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppTheme.pagePadding),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '搜索频道（本地）',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('全部频道'),
              onTap: () => Navigator.of(context).pop(-1),
            ),
            const Divider(height: 1),
            Flexible(
              child: results.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有匹配的频道'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final entry = results[index];
                        return ListTile(
                          title: Text(entry.title),
                          subtitle: Text(
                            entry.videoCount == null
                                ? '统计中'
                                : '${entry.videoCount} 个视频',
                          ),
                          onTap: () => Navigator.of(context).pop(entry.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
