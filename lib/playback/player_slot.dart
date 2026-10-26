import '../storage/active_files.dart';

/// A single video playback instance.
///
/// Deliberately narrow: the controller must be able to stop and free a player
/// without knowing whether it is `video_player`, AVPlayer, or a test double.
abstract class PlayerHandle {
  String get path;
  bool get isPlaying;
  bool get isDisposed;

  Future<void> load();
  Future<void> play();
  Future<void> pause();

  /// 0.0 = muted, 1.0 = full volume.
  ///
  /// Part of the interface because the feed must apply the mute state to each
  /// newly activated player: every cold start begins muted, and a swipe to the
  /// next video has to inherit whatever the user last chose.
  Future<void> setVolume(double volume);

  /// Stops playback, detaches listeners and releases the decoder.
  Future<void> disposePlayer();
}

abstract class PlayerFactory {
  /// [location] is an absolute file path, or an http URL when [network] is true.
  PlayerHandle create(String location, {bool network = false});
}

class PlayerError implements Exception {
  PlayerError(this.path, this.cause);

  final String path;
  final Object cause;

  @override
  String toString() => 'PlayerError($path): $cause';
}

/// Keeps at most one live video player.
///
/// Guarantees, all asserted by tests:
/// * switching pauses and disposes the previous player **before** the new one
///   starts, so two videos never play at once;
/// * a slow `load()` that finishes after the user already moved on is disposed
///   instead of being installed (the classic "old request overwrites current
///   video" bug);
/// * the file path is registered as in-use while the player holds it, so the
///   cache cleaner cannot delete a file mid-playback;
/// * `release()` / `releaseAll()` are safe to call repeatedly.
class SinglePlayerController {
  SinglePlayerController({required this.factory, this.activeFiles});

  final PlayerFactory factory;
  final ActiveFileRegistry? activeFiles;

  PlayerHandle? _active;
  String? _activePath;

  /// Path registered as in-use for the active player.
  ///
  /// Differs from [_activePath] when playing through the range server: the
  /// location is a URL, but the file that must not be deleted is the pool file
  /// the server is reading from.
  String? _activeGuardPath;
  int _generation = 0;
  int _created = 0;
  int _disposed = 0;

  PlayerHandle? get active => _active;
  String? get activePath => _activePath;
  bool get hasActive => _active != null;

  /// True when the current player reads from the loopback range server.
  bool get isStreaming => _activePath?.startsWith('http') ?? false;

  /// Handles handed out by the factory that have not been disposed yet.
  /// Must stay at 0 or 1; anything higher is a leak.
  int get liveCount => _created - _disposed;
  int get createdCount => _created;
  int get disposedCount => _disposed;

  Future<void> activate(
    String location, {
    bool autoplay = true,
    bool network = false,
    String? guardPath,
  }) async {
    final generation = ++_generation;
    await _disposeActive();

    // A newer activate() may have started while the old player was being torn
    // down; that newer call owns the slot now.
    if (generation != _generation) return;

    final handle = factory.create(location, network: network);
    _created++;
    final guard = guardPath ?? location;
    activeFiles?.markInUse(guard, reason: 'player');

    try {
      await handle.load();
      if (generation != _generation) {
        await _releaseHandle(handle, guard);
        return;
      }
      if (autoplay) {
        await handle.play();
      }
      if (generation != _generation) {
        await _releaseHandle(handle, guard);
        return;
      }
      _active = handle;
      _activePath = location;
      _activeGuardPath = guard;
    } catch (error) {
      await _releaseHandle(handle, guard);
      throw PlayerError(location, error);
    }
  }

  Future<void> pauseActive() async {
    final handle = _active;
    if (handle == null || handle.isDisposed) return;
    await handle.pause();
  }

  /// Stops and frees the current player. Called on page exit, tab switch,
  /// backgrounding and memory warnings.
  Future<void> release() async {
    _generation++;
    await _disposeActive();
  }

  Future<void> releaseAll() => release();

  Future<void> _disposeActive() async {
    final handle = _active;
    final guard = _activeGuardPath ?? _activePath;
    _active = null;
    _activePath = null;
    _activeGuardPath = null;
    if (handle == null) {
      if (guard != null) activeFiles?.release(guard);
      return;
    }
    await _releaseHandle(handle, guard ?? handle.path);
  }

  Future<void> _releaseHandle(PlayerHandle handle, String path) async {
    try {
      if (handle.isPlaying) await handle.pause();
    } catch (_) {
      // Pausing a dead player is not worth failing the release path.
    }
    try {
      await handle.disposePlayer();
    } finally {
      _disposed++;
      activeFiles?.release(path);
    }
  }
}
