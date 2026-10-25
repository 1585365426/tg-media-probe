import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../data/media_record.dart';
import '../../platform/video_rotation.dart';

/// One full-screen page of the vertical feed.
///
/// Stateless on purpose: the feed owns the single player slot, so a tile can
/// never start playback by itself. It only renders whatever controller it is
/// handed, which makes "two videos playing at once" structurally impossible.
class VideoTile extends StatelessWidget {
  const VideoTile({
    super.key,
    required this.record,
    required this.channelTitle,
    required this.controller,
    required this.muted,
    required this.favorite,
    required this.progress,
    required this.error,
    required this.rotationDegrees,
    required this.landscape,
    required this.isCurrent,
    required this.onToggleMute,
    required this.onToggleFavorite,
    required this.onBack,
    required this.onToggleOrientation,
  });

  final MediaRecord record;
  final String channelTitle;

  /// Non-null only for the page that currently owns the player slot.
  final VideoPlayerController? controller;

  final bool muted;
  final bool favorite;

  /// 0–1 while the file is being fetched, null when not applicable.
  final double? progress;

  final String? error;

  /// Read from the AVFoundation track transform. Null means unknown — the
  /// UI says so instead of guessing 0°.
  final int? rotationDegrees;

  final bool landscape;
  final bool isCurrent;

  final VoidCallback onToggleMute;
  final VoidCallback onToggleFavorite;
  final VoidCallback onBack;
  final VoidCallback onToggleOrientation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = controller?.value;
    final ready = value != null && value.isInitialized;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(child: _surface(value, ready, theme)),
          if (error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _footer(theme),
            ),
          Positioned(
            right: 10,
            bottom: 96,
            child: _actions(theme),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: SafeArea(
              child: IconButton.filledTonal(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, size: 20),
                tooltip: '返回',
              ),
            ),
          ),
          if (isCurrent && progress != null && error == null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(value: progress == 0 ? null : progress),
            ),
        ],
      ),
    );
  }

  Widget _surface(VideoPlayerValue? value, bool ready, ThemeData theme) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 10),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }
    if (!ready) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(color: Colors.white70),
          const SizedBox(height: 12),
          Text(
            progress == null ? '准备中…' : '正在下载 ${(progress! * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      );
    }

    // Aspect ratio comes from AVFoundation, adjusted for the track transform:
    // a phone-shot 1920x1080 with a 90° transform occupies 1080x1920 on screen.
    final size = VideoRotationReader.displaySize(
      width: record.width,
      height: record.height,
      rotationDegrees: rotationDegrees,
    );
    final ratio = (size.width != null && size.height != null && size.height! > 0)
        ? size.width! / size.height!
        : value!.aspectRatio;

    return AspectRatio(
      aspectRatio: ratio,
      child: VideoPlayer(controller!),
    );
  }

  Widget _footer(ThemeData theme) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 40, 76, 18),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      channelTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                <String>[
                  _durationLabel(record.durationSeconds),
                  if (record.width != null && record.height != null)
                    '${record.width}x${record.height}',
                  if (rotationDegrees != null) '旋转 $rotationDegrees°',
                  if (record.hasProtectedContent) '受保护',
                ].join(' · '),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              if ((record.caption ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  record.caption!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _actions(ThemeData theme) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _actionButton(
            icon: favorite ? Icons.star : Icons.star_border,
            color: favorite ? Colors.amber : Colors.white,
            label: favorite ? '已收藏' : '收藏',
            onTap: onToggleFavorite,
          ),
          const SizedBox(height: 16),
          _actionButton(
            icon: muted ? Icons.volume_off : Icons.volume_up,
            color: Colors.white,
            label: muted ? '已静音' : '有声',
            onTap: onToggleMute,
          ),
          const SizedBox(height: 16),
          _actionButton(
            icon: landscape ? Icons.stay_current_portrait : Icons.screen_rotation,
            color: Colors.white,
            label: landscape ? '竖屏' : '横屏',
            onTap: onToggleOrientation,
          ),
        ],
      );

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Column(
          children: <Widget>[
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      );

  static String _durationLabel(int? seconds) {
    if (seconds == null) return '时长未知';
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
  }
}
