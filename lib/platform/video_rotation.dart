import 'package:flutter/services.dart';

/// Reads the video rotation that TDLib does not report.
///
/// TDLib's `video` object has `width`, `height`, `duration` — no rotation. A
/// phone-shot video can be stored as 1920x1080 with a 90° transform, so treating
/// the raw width/height as the display aspect ratio is wrong. The authoritative
/// value is the AVFoundation track's `preferredTransform`, read natively.
///
/// If the native side cannot answer (missing file, no video track, plugin not
/// registered), this returns null. Null means **unknown** — callers must not
/// substitute a guess such as 0.
class VideoRotationReader {
  const VideoRotationReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'tgmedia/video_meta';

  final MethodChannel _channel;

  Future<int?> readRotationDegrees(String path) async {
    if (path.isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<int>(
        'rotationDegrees',
        <String, Object?>{'path': path},
      );
      return normalizeDegrees(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Accepts only the four values AVFoundation can produce.
  ///
  /// `-90` is normalised to `270`; anything else (e.g. a transform with a
  /// non-orthogonal matrix, or a nonsense value from a stale plugin) becomes
  /// null rather than a silent default.
  static int? normalizeDegrees(int? raw) {
    if (raw == null) return null;
    final normalized = ((raw % 360) + 360) % 360;
    return switch (normalized) {
      0 => 0,
      90 => 90,
      180 => 180,
      270 => 270,
      _ => null,
    };
  }

  /// True when the stored width/height are swapped for display.
  static bool isQuarterTurn(int? degrees) => degrees == 90 || degrees == 270;

  /// Display dimensions after applying rotation. Returns the raw values when
  /// rotation is unknown, plus a flag so callers can mark the item as
  /// "unclassified" instead of pretending the ratio is confirmed.
  static ({int? width, int? height, bool rotationKnown}) displaySize({
    required int? width,
    required int? height,
    required int? rotationDegrees,
  }) {
    if (width == null || height == null) {
      return (width: width, height: height, rotationKnown: rotationDegrees != null);
    }
    if (isQuarterTurn(rotationDegrees)) {
      return (width: height, height: width, rotationKnown: true);
    }
    return (width: width, height: height, rotationKnown: rotationDegrees != null);
  }
}
