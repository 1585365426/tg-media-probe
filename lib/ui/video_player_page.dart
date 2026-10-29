/// Full-screen playback for one channel's videos.
///
/// Structure: a vertical [PageView] (one video per page) plus one
/// [PlaybackController] that owns the single player instance. Swiping only
/// changes an index; the controller disposes the old player before opening the
/// next one, so a hundred swipes leave one `AVPlayer`, not a hundred.
///
/// Gestures, exactly as specified: single tap toggles the controls, double tap
/// pauses/resumes, vertical swipe moves between videos, and long press does
/// nothing at all — it is not bound to anything.
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/app_preferences.dart';
import '../data/media_index.dart';
import '../download/download_state.dart';
import '../platform/orientation_coordinator.dart';
import '../playback/local_media_player.dart';
import '../playback/playback_controller.dart';
import '../util/byte_format.dart';
import 'diagnostic_badge.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.downloads,
    required this.preferences,
    this.channelTitle = '',
    this.playerFactory,
  });

  final List<NumberedMedia> items;
  final int initialIndex;
  final MediaPreparer downloads;
  final PreferencesController preferences;
  final String channelTitle;

  /// Injected by tests so the page can be exercised without an AVPlayer.
  final MediaPlayerFactory? playerFactory;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final PlaybackController _controller;
  late final PageController _pager;
  final ValueNotifier<bool> _controls = ValueNotifier<bool>(true);
  final OrientationCoordinator _orientation = OrientationCoordinator.instance;

  bool _landscape = false;
  String? _orientationHint;

  @override
  void initState() {
    super.initState();
    _pager = PageController(initialPage: widget.initialIndex);
    _controller = PlaybackController(
      items: widget.items,
      downloads: widget.downloads,
      initialIndex: widget.initialIndex,
      playbackSpeed: widget.preferences.value.playbackSpeed,
      muted: widget.preferences.value.defaultMuted,
      playerFactory: widget.playerFactory,
    );
    _controller.addListener(_onControllerChanged);
    _orientation.set(OrientationCoordinator.feedOwner,
        OrientationIntent.playbackPortrait);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _pager.dispose();
    _controls.dispose();
    _orientation.clear(OrientationCoordinator.feedOwner);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    if (_pager.hasClients &&
        _pager.page?.round() != _controller.index &&
        _controller.index < widget.items.length) {
      // Keep the pager in step when the index changed through the prev/next
      // buttons rather than a swipe.
      _pager.jumpToPage(_controller.index);
    }
  }

  Future<void> _toggleLandscape() async {
    final next = !_landscape;
    await _orientation.set(
      OrientationCoordinator.feedOwner,
      next
          ? OrientationIntent.playbackLandscape
          : OrientationIntent.playbackPortrait,
    );
    if (!mounted) return;
    final status = _orientation.status;
    setState(() {
      _landscape = next && !status.isProblem;
      // iOS silently refuses to rotate when the device rotation lock is on; the
      // mask still applies to the next physical rotation. Saying so is the
      // honest outcome rather than pretending it worked.
      _orientationHint = next && status.isProblem
          ? '请关闭系统旋转锁定后使用横屏播放'
          : null;
    });
    if (_orientationHint != null) {
      _message(_orientationHint!);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final item = _controller.current;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final showBadge = widget.preferences.value.diagnosticBadge;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controls.value = !_controls.value,
        onDoubleTap: _controller.togglePlay,
        // Long press intentionally unbound.
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PageView.builder(
              controller: _pager,
              scrollDirection: Axis.vertical,
              itemCount: widget.items.length,
              onPageChanged: (index) => _controller.goTo(index),
              itemBuilder: (context, index) => _page(index: index),
            ),
            if (showBadge && item != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 12,
                child: DiagnosticBadge(
                  label: item.label,
                  download: _controller.downloadState,
                  compact: isLandscape,
                ),
              ),
            ValueListenableBuilder<bool>(
              valueListenable: _controls,
              builder: (context, visible, _) => AnimatedOpacity(
                key: const Key('player-chrome'),
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: IgnorePointer(
                  ignoring: !visible,
                  child: _chrome(item, isLandscape),
                ),
              ),
            ),
            if (!isLandscape)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _controls,
                  builder: (context, visible, child) => AnimatedOpacity(
                    key: const Key('player-controls'),
                    opacity: visible ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(ignoring: !visible, child: child),
                  ),
                  child: _bottomSheet(item),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _page({required int index}) {
    final item = widget.items[index];
    final isCurrent = index == _controller.index;
    if (!isCurrent) {
      // Neighbours are deliberately empty: nothing is preloaded, because one
      // active transfer is the rule and a prefetch would break it.
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            item.label,
            style: const TextStyle(color: Colors.white24, fontSize: 28),
          ),
        ),
      );
    }
    return _currentSurface();
  }

  Widget _currentSurface() {
    final player = _controller.player;
    if (_controller.phase == PlaybackPhase.failed) {
      return _failureView();
    }
    if (_controller.phase == PlaybackPhase.preparing || player == null) {
      return _preparingView();
    }
    if (player is LocalMediaPlayer && player.controller != null) {
      return Center(
        child: AspectRatio(
          aspectRatio: player.aspectRatio,
          child: VideoPlayer(player.controller!),
        ),
      );
    }
    // A test double (or a player without a texture) still shows a black stage.
    return const ColoredBox(color: Colors.black);
  }

  Widget _preparingView() {
    final download = _controller.downloadState;
    final item = _controller.current;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                item?.label ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              const Text('正在准备视频',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                child: LinearProgressIndicator(
                  value: download.phase == DownloadPhase.downloading
                      ? download.progress
                      : null,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _progressLine(download),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _progressLine(DownloadState download) {
    switch (download.phase) {
      case DownloadPhase.downloading:
        final rate = download.bytesPerSecond > 0
            ? formatRate(download.bytesPerSecond)
            : '连接中';
        return '$rate · ${download.progressLabel}';
      case DownloadPhase.verifying:
        return '正在校验 ${formatBytes(download.totalBytes)}';
      case DownloadPhase.checking:
        return '正在检查本地缓存';
      default:
        return '';
    }
  }

  Widget _failureView() {
    final download = _controller.downloadState;
    final failedDownload = download.phase == DownloadPhase.failed ||
        download.phase == DownloadPhase.cancelled;
    final message = failedDownload
        ? download.failure.message
        : (_controller.errorMessage ?? '视频无法播放');
    final title = failedDownload
        ? (download.failure == DownloadFailure.insufficientSpace
            ? '磁盘空间不足'
            : '视频下载失败')
        : '视频无法播放';
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _controller.current?.label ?? '',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _controller.retry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chrome(NumberedMedia? item, bool isLandscape) {
    final top = MediaQuery.of(context).padding.top;
    return Stack(
      children: <Widget>[
        Positioned(
          top: top + 4,
          left: 4,
          right: 4,
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              if (item != null && !widget.preferences.value.diagnosticBadge)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              IconButton(
                tooltip: isLandscape ? '退出全屏' : '横屏播放',
                icon: Icon(
                  isLandscape ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white,
                ),
                onPressed: _toggleLandscape,
              ),
            ],
          ),
        ),
        if (item != null)
          Positioned(
            left: 0,
            right: 0,
            top: top + 52,
            child: IgnorePointer(
              child: Center(
                child: Text(
                  widget.channelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _bottomSheet(NumberedMedia? item) {
    if (item == null) return const SizedBox.shrink();
    return Container(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).padding.bottom + 12,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  item.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _progressBar(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                IconButton(
                  tooltip: '上一个',
                  icon: Icon(Icons.skip_previous,
                      color: _controller.hasPrevious
                          ? Colors.white
                          : Colors.white24),
                  onPressed: _controller.hasPrevious
                      ? () => _controller.previous()
                      : null,
                ),
                IconButton(
                  tooltip: _controller.isPlaying ? '暂停' : '播放',
                  iconSize: 40,
                  icon: Icon(
                    _controller.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: _controller.togglePlay,
                ),
                IconButton(
                  tooltip: '下一个',
                  icon: Icon(Icons.skip_next,
                      color: _controller.hasNext ? Colors.white : Colors.white24),
                  onPressed:
                      _controller.hasNext ? () => _controller.next() : null,
                ),
              ],
            ),
          ],
      ),
    );
  }

  Widget _progressBar() {
    final duration = _controller.duration;
    final position = _controller.position;
    final max = duration.inMilliseconds.toDouble();
    final value = max <= 0
        ? 0.0
        : position.inMilliseconds.clamp(0, max).toDouble();
    return Row(
      children: <Widget>[
        Text(
          _time(position),
          style: const TextStyle(
              color: Colors.white70, fontSize: 11, fontFeatures: [
            FontFeature.tabularFigures(),
          ]),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value,
              max: max <= 0 ? 1 : max,
              onChanged: max <= 0
                  ? null
                  : (next) => _controller
                      .seekTo(Duration(milliseconds: next.round())),
            ),
          ),
        ),
        Text(
          _time(duration),
          style: const TextStyle(
              color: Colors.white70, fontSize: 11, fontFeatures: [
            FontFeature.tabularFigures(),
          ]),
        ),
      ],
    );
  }

  static String _time(Duration value) {
    final totalSeconds = value.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
