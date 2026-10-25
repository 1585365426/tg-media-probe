import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/app_model.dart';
import '../../app/app_services.dart';
import '../../data/media_record.dart';
import '../../platform/orientation_controller.dart';
import '../../platform/video_rotation.dart';
import '../../playback/video_player_handle.dart';
import 'video_tile.dart';

/// Full-screen player for a single record, used by the favourites list.
///
/// Shares the app-wide single-player slot, so opening this from the feed cannot
/// leave two decoders alive; leaving the page releases the slot.
class SingleVideoPage extends StatefulWidget {
  const SingleVideoPage({
    super.key,
    required this.services,
    required this.model,
    required this.record,
  });

  final AppServices services;
  final AppModel model;
  final MediaRecord record;

  @override
  State<SingleVideoPage> createState() => _SingleVideoPageState();
}

class _SingleVideoPageState extends State<SingleVideoPage> {
  VideoPlayerController? _controller;
  String? _error;
  double? _progress;
  int? _rotation;
  bool _landscape = false;
  bool _muted = true;
  VideoPlayerController? _loopController;
  bool _seekingBack = false;

  final OrientationBridge _orientation = OrientationBridge();

  @override
  void initState() {
    super.initState();
    _muted = widget.model.muted;
    _start();
  }

  @override
  void dispose() {
    _loopController?.removeListener(_onTick);
    widget.services.player.release();
    _orientation.resetToSystem();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final result = await widget.services.resolver.ensureLocal(
        widget.record,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p.fraction);
        },
      );
      final rotation =
          await const VideoRotationReader().readRotationDegrees(result.path);
      await widget.services.player.activate(result.path);
      if (!mounted) return;
      final handle = widget.services.player.active;
      if (handle is VideoPlayerHandle) {
        await handle.setVolume(_muted ? 0 : 1);
        final controller = handle.controller;
        if (controller != null) {
          _loopController = controller..addListener(_onTick);
        }
        if (!mounted) return;
        setState(() {
          _controller = controller;
          _rotation = rotation;
          _progress = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error = e.toString();
      });
    }
  }

  void _onTick() {
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

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    await widget.model.setMuted(next);
    final handle = widget.services.player.active;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) => VideoTile(
          record: widget.record,
          channelTitle: widget.services.chatTitles.labelOf(widget.record.chatId),
          controller: _controller,
          muted: _muted,
          favorite: widget.model.isFavorite(widget.record),
          progress: _progress,
          error: _error,
          rotationDegrees: _rotation,
          landscape: _landscape,
          isCurrent: true,
          onToggleMute: _toggleMute,
          onToggleFavorite: () => widget.model.toggleFavorite(widget.record),
          onBack: () => Navigator.of(context).maybePop(),
          onToggleOrientation: _toggleOrientation,
        ),
      ),
    );
  }
}
