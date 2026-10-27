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
import '../platform/orientation_controller.dart';
import '../platform/orientation_coordinator.dart';
import '../playback/player_slot.dart';
import '../playback/video_player_handle.dart';
import '../playback/video_source.dart';
import '../playback/watch_store.dart';
import '../storage/file_ops.dart';
import '../storage/active_files.dart';
import '../playback/media_metadata.dart';
import '../td/td_error_kind.dart';
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
    this.coordinator,
    this.isActive = true,
    this.playbackImmersive,
    this.onExitPlayback,
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

  /// Injectable for tests; the app uses [OrientationCoordinator.instance].
  final OrientationCoordinator? coordinator;

  /// False while the shell shows another tab. The feed releases its decoder
  /// instead of playing audio behind the settings page.
  final bool isActive;

  /// Set to true while the feed is playing a video, so the shell can hide its
  /// bottom tab bar (immersive playback). Null when nobody listens.
  final ValueNotifier<bool>? playbackImmersive;

  /// "Back" for the shell-embedded feed (no Navigator route to pop). The
  /// shell wires this to switching back to the channel tab. Null when the page
  /// has no in-app exit (tests).
  final VoidCallback? onExitPlayback;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with WidgetsBindingObserver {
  late final OrientationCoordinator _orientation;

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
    _orientation = widget.coordinator ??
        (widget.orientation == null
            ? OrientationCoordinator.instance
            : OrientationCoordinator(bridge: widget.orientation));
    _activeFiles = widget.activeFiles ?? ActiveFileRegistry();
    _chatFilter = widget.initialChatId;
    // Opening the player is portrait. Only the full-screen button may ask for
    // landscape, and removing this owner restores portrait by construction.
    _orientation.set(
      OrientationCoordinator.feedOwner,
      OrientationIntent.playbackPortrait,
    );
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
    // One lookup object for both users: the resolver (file id repair) and the
    // controller (file name repair).
    final metadata = TdMediaMetadataLookup(client);
    final controller = FeedController(
      source: IndexFeedSource(store: store, chatId: _chatFilter),
      player: SinglePlayerController(
        factory: const VideoPlayerFactory(),
        activeFiles: _activeFiles,
      ),
      sources: VideoSourceResolver(
        api: TdFileTransferApi(client),
        // One `getMessage` is what repairs a stale file id and what fills in a
        // missing file name — both were reported from the device.
        metadata: metadata,
      ),
      metadata: metadata,
      // Watch state lives next to the index (protected zone), keyed by
      // chatId+messageId so a longer list never inherits another video's
      // resume point.
      watch: WatchStore(directory: store.directory, ops: const IoFileOps()),
      chatTitles: titles,
      defaultMuted: widget.preferences.defaultMuted,
      preloadCount: widget.preferences.preloadCount,
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
    if (!mounted) return;
    _syncImmersiveNotifier();
    setState(() {});
    // The controller's index is the truth; the PageView has to follow it.
    //
    // Tapping a row, a number jump and a programmatic move all change the
    // controller without touching the pager, so the page kept showing item 1
    // while the player was already on item 5 — reported as "点击播放的不是这一条".
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPagerToController());
  }

  /// Publishes "a video is on screen" to the shell, which hides its tab bar.
  ///
  /// Written on every controller change so phase transitions cannot miss it.
  /// The value deliberately ignores [FeedController.controlVisible]: revealing
  /// overlays with a tap is not "leaving playback", so the tab bar stays
  /// hidden until the user actually leaves the feed.
  void _syncImmersiveNotifier() {
    final notifier = widget.playbackImmersive;
    final controller = _controller;
    if (notifier == null) return;
    final value = widget.isActive &&
        FeedImmersivePlan.playbackActive(
          phase: controller?.phase ?? FeedPhase.idle,
          itemCount: controller?.length ?? 0,
        );
    if (notifier.value != value) notifier.value = value;
  }

  void _syncPagerToController() {
    if (!mounted || _disposed) return;
    final controller = _controller;
    if (controller == null || !_pager.hasClients) return;
    final target = controller.index;
    if (target < 0) return;
    final current = _pager.page;
    if (current == null) return;
    if (current.round() == target) return;
    // jumpToPage, not animate: this is a correction, not a navigation.
    _pager.jumpToPage(target);
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
    // The tab bar must come back the moment the feed tab stops being the
    // visible one, even though the feed keeps its state in the IndexedStack.
    _syncImmersiveNotifier();
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
    // The feed is gone: the shell must bring its tab bar back.
    final notifier = widget.playbackImmersive;
    if (notifier != null && notifier.value) notifier.value = false;
    _orientation.clear(OrientationCoordinator.feedOwner);
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
    // Immersive by default: the video owns the screen. One tap on the video
    // reveals the chrome (top bar, info, controls); the next tap hides it.
    // Buffering and errors are not chrome and render independently.
    final overlaysVisible = FeedImmersivePlan.overlaysVisible(
      phase: controller.phase,
      itemCount: controller.length,
      controlVisible: controller.controlVisible,
    );
    return Scaffold(
      backgroundColor: AppTheme.feedBackground,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildPager(controller),
            if (overlays.showTopBar && overlaysVisible) _buildTopBar(),
            if (overlays.showInfo && overlaysVisible) _buildInfo(controller),
            if (overlays.showControls && overlaysVisible)
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
        // With items already loaded, the list stays: a failed transfer is not
        // a reason to drop the user back to the first video. The error is an
        // overlay on top of the item that failed.
        if (controller.length == 0) {
          return FailureView(
            failure: controller.failure,
            detail: controller.error,
            onRetry: controller.retry,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildPageView(controller),
            _buildErrorOverlay(controller),
          ],
        );
      case FeedPhase.buffering:
      case FeedPhase.ready:
        return _buildPageView(controller);
    }
  }

  Widget _buildPageView(FeedController controller) {
    return PageView.builder(
      controller: _pager,
      scrollDirection: Axis.vertical,
      itemCount: controller.length,
      onPageChanged: (index) {
        // One call, awaited by nobody on purpose: goToIndex now extends the
        // list when the target is past the loaded window, so the old
        // "goToIndex then goNext" pair (which raced and computed an
        // out-of-range target from the stale index) is gone.
        controller.goToIndex(index);
      },
      itemBuilder: (context, index) => _buildPage(controller, index),
    );
  }

  /// Failure card over the current item, with two different recoveries:
  /// [FeedController.retry] re-activates this item (position kept), and
  /// [FeedController.reload] rebuilds the list (position lost) — only the
  /// second one is allowed to move the user back to item 1.
  Widget _buildErrorOverlay(FeedController controller) {
    final theme = Theme.of(context);
    final retryable = isRetryable(controller.failure);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Material(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  failureTitle(controller.failure),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  <String>[
                    failureHint(controller.failure),
                    if (controller.error != null) controller.error!,
                  ].join('\n'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 10),
                Text(
                  '当前 ${controller.positionLabel}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white38),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: controller.reload,
                      child: const Text(
                        '重新加载列表',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                    if (retryable)
                      FilledButton(
                        onPressed: controller.retry,
                        child: const Text('重试'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

  /// True when the top bar has a back affordance. A pushed route pops itself;
  /// the shell-embedded feed (no route to pop) calls back into the shell so
  /// the user is never trapped in an immersive feed with no tab bar.
  bool get _canExit =>
      widget.showBackButton || widget.onExitPlayback != null;

  void _handleExit() {
    if (widget.showBackButton) {
      Navigator.of(context).maybePop();
      return;
    }
    widget.onExitPlayback?.call();
  }

  Widget _buildTopBar() {
    final directory = widget.session.directory;
    final channelTitle = _chatFilter == null
        ? '视频'
        : (directory?.titles[_chatFilter] ?? '视频');
    final current = _controller?.current;
    // The name of the video now leads, and the channel becomes the second line:
    // in landscape the bottom info block is hidden, so the top bar was the only
    // place left where the file name could have been shown — and it showed the
    // channel instead.
    final title = current == null ? channelTitle : _controller!.titleOf(current);
    final subtitle = current == null || title == channelTitle ? null : channelTitle;
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
            if (_canExit)
              IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                onPressed: _handleExit,
              )
            else
              const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                ],
              ),
            ),
            // Top entry is "jump to video number", not a text search: the
            // product replaced filename search with a 1-based number over the
            // current list. Nothing here touches Telegram.
            IconButton(
              tooltip: '输入视频编号',
              icon: const Icon(Icons.tag, color: Colors.white),
              onPressed: _openNumberBox,
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
                '${controller.currentChannelTitle} · #${record.messageId} · '
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
    final wantLandscape = !_isLandscape;
    final intent = wantLandscape
        ? OrientationIntent.playbackLandscape
        : OrientationIntent.playbackPortrait;
    try {
      await _orientation.set(OrientationCoordinator.feedOwner, intent);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || _disposed) return;

      final wanted =
          wantLandscape ? Orientation.landscape : Orientation.portrait;
      if (MediaQuery.of(context).orientation == wanted) return;

      // Two different failures look the same to the user: the system lock, and
      // a bridge that answered nothing. Say which one, don't just retry.
      final status = _orientation.status;
      final message = status.outcome == OrientationOutcome.failed ||
              status.outcome == OrientationOutcome.unsupported
          ? '方向切换失败：${status.message ?? '系统拒绝'}'
          : '系统方向锁已开启，无法自动旋转';
      setState(() => _rotationHint = message);
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || _disposed) return;
      setState(() => _rotationHint = null);
      // The state machine must not keep claiming landscape if the screen is
      // still portrait.
      if (wantLandscape) {
        await _orientation.set(
          OrientationCoordinator.feedOwner,
          OrientationIntent.playbackPortrait,
        );
      }
    } finally {
      _rotationHintBusy = false;
    }
  }

  /// Asks for a 1-based number and opens that item.
  Future<void> _openNumberBox() async {
    final controller = _controller;
    if (controller == null) return;
    final input = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController();
        return AlertDialog(
          title: const Text('输入视频编号'),
          content: TextField(
            controller: field,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '1 – ${controller.length}',
              helperText: '按当前列表顺序从 1 开始',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(field.text),
              child: const Text('打开'),
            ),
          ],
        );
      },
    );
    if (!mounted || _disposed) return;
    await _jumpToNumber(input ?? '');
  }

  Future<void> _jumpToNumber(String raw) async {
    final controller = _controller;
    if (controller == null) return;
    final trimmed = raw.trim();
    final number = int.tryParse(trimmed);
    final outcome = number == null || trimmed.isEmpty
        ? NumberJumpResult.invalid
        : await controller.openNumber(number);
    if (!mounted || _disposed) return;
    if (outcome == NumberJumpResult.opened) {
      if (_pager.hasClients) _pager.jumpToPage(controller.index);
      return;
    }
    final message = outcome == NumberJumpResult.invalid
        ? '请输入 1 – ${controller.length} 之间的编号'
        : '未找到该编号（当前共 ${controller.length} 条）';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

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
