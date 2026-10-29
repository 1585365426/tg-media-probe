/// A [MediaPlayerHandle] that records what the controller asked it to do, so
/// player lifecycle rules can be tested without an AVPlayer.
library;

import 'package:flutter/foundation.dart';
import 'package:tg_media_probe/playback/local_media_player.dart';

class FakePlayer extends ChangeNotifier implements MediaPlayerHandle {
  FakePlayer({
    required this.path,
    this.openDelay = Duration.zero,
    this.failOpen = false,
  });

  final String path;
  final Duration openDelay;
  final bool failOpen;

  bool opened = false;
  bool disposed = false;
  bool playing = false;
  double speed = 1.0;
  double volume = 1.0;
  Duration? lastSeek;
  int openCount = 0;

  @override
  Future<void> open() async {
    openCount++;
    if (openDelay > Duration.zero) await Future<void>.delayed(openDelay);
    if (failOpen) throw StateError('cannot open');
    opened = true;
  }

  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position) async {
    lastSeek = position;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    playing = false;
    super.dispose();
  }

  @override
  bool get isInitialized => opened && !disposed;

  @override
  bool get isPlaying => playing;

  @override
  Duration get position => const Duration(seconds: 3);

  @override
  Duration get duration => const Duration(seconds: 30);

  @override
  double get aspectRatio => 16 / 9;

  @override
  String? get error => null;

  @override
  Listenable get notifier => this;
}

/// Factory that keeps every instance it made, in creation order.
class RecordingPlayerFactory {
  RecordingPlayerFactory({this.failOpen = false, this.openDelay = Duration.zero});

  final bool failOpen;
  final Duration openDelay;
  final List<FakePlayer> created = <FakePlayer>[];

  MediaPlayerHandle call(String path) {
    final player = FakePlayer(
      path: path,
      failOpen: failOpen,
      openDelay: openDelay,
    );
    created.add(player);
    return player;
  }

  FakePlayer get last => created.last;
}
