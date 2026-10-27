import 'video_source.dart';

/// What went wrong with one play, at the level the user can act on.
///
/// The V1 pipeline reported every transport failure as "网络不可用", which is
/// right for exactly one of these and wrong for the other six: a cancelled
/// request, a file TDLib lost, and an AVPlayer item that never became ready
/// all looked like a bad connection, so the retry button was the only advice
/// the screen could give.
///
/// The distinction is also what the acceptance report needs: "streamingActive"
/// with `decoderFailed` is a codec problem, the same verdict with
/// `downloadStalled` is a network problem, and only one of them is worth
/// retrying.
enum PlaybackFailure {
  /// The bytes could not be produced for the player: no AVAssetResourceLoader
  /// bridge, a refused session, a loader that answered with an error.
  resourceLoading,

  /// TDLib stopped growing the file past the grace window while the play was
  /// waiting on it. A pause shorter than the grace is not this.
  downloadStalled,

  /// The file is not where TDLib said it is, or TDLib rejected the file id.
  fileNotFound,

  /// The item never became ready — `AVPlayerItem.status == .failed` before the
  /// first frame, or the initialize bound expired.
  playerInitFailed,

  /// The item became ready and the decoder then refused the bytes.
  decoderFailed,

  /// The play was superseded (swipe, retry, background) — not a failure the
  /// user should see.
  requestCancelled,

  /// TDLib answered with an error of its own (flood wait, chat forbidden,
  /// invalid id): the message is TDLib's, not the transport's.
  tdlibError,

  /// Nothing matched. Kept so an unclassified error is still visible as
  /// unclassified instead of being rounded to "network".
  unknown;

  /// Stable code for the diagnostics panel and the exported report.
  String get code => switch (this) {
        PlaybackFailure.resourceLoading => 'RESOURCE_LOADING',
        PlaybackFailure.downloadStalled => 'DOWNLOAD_STALLED',
        PlaybackFailure.fileNotFound => 'FILE_NOT_FOUND',
        PlaybackFailure.playerInitFailed => 'PLAYER_INIT_FAILED',
        PlaybackFailure.decoderFailed => 'DECODER_FAILED',
        PlaybackFailure.requestCancelled => 'REQUEST_CANCELLED',
        PlaybackFailure.tdlibError => 'TDLIB_ERROR',
        PlaybackFailure.unknown => 'UNKNOWN',
      };

  /// Chinese label for the error page. Only [downloadStalled] and
  /// [resourceLoading] mention the network, because only they are about it.
  String get message => switch (this) {
        PlaybackFailure.resourceLoading => '读取视频数据失败',
        PlaybackFailure.downloadStalled => '下载已停止，读取失败',
        PlaybackFailure.fileNotFound => '视频文件已失效',
        PlaybackFailure.playerInitFailed => '播放器初始化失败',
        PlaybackFailure.decoderFailed => '此视频无法解码',
        PlaybackFailure.requestCancelled => '播放已取消',
        PlaybackFailure.tdlibError => 'Telegram 返回错误',
        PlaybackFailure.unknown => '读取失败',
      };

  /// Whether "重试一次" can plausibly help. A decoder failure and a lost file
  /// cannot be fixed by asking again, and a cancelled play was not a failure.
  bool get retryable => switch (this) {
        PlaybackFailure.resourceLoading => true,
        PlaybackFailure.downloadStalled => true,
        PlaybackFailure.tdlibError => true,
        PlaybackFailure.playerInitFailed => true,
        PlaybackFailure.fileNotFound => false,
        PlaybackFailure.decoderFailed => false,
        PlaybackFailure.requestCancelled => false,
        PlaybackFailure.unknown => true,
      };

  static PlaybackFailure fromCode(String? code) {
    if (code == null || code.isEmpty) return PlaybackFailure.unknown;
    for (final value in PlaybackFailure.values) {
      if (value.code == code) return value;
    }
    return PlaybackFailure.unknown;
  }
}

/// Classifies a thrown object from the resolve/player layer.
///
/// Text matching is the last resort, not the first: the typed exceptions carry
/// everything that matters, and only TDLib's own messages are strings.
PlaybackFailure classifyPlaybackFailure(Object? error) {
  if (error == null) return PlaybackFailure.unknown;
  if (error is VideoSourceStalled) return PlaybackFailure.downloadStalled;
  if (error is VideoSourceTimeout) {
    // The transfer was still being attempted when the budget ran out: the
    // bytes are the problem, so this is a stalled download, not a codec.
    return PlaybackFailure.downloadStalled;
  }
  if (error is VideoSourceException) {
    return classifyPlaybackMessage(error.message);
  }
  if (error is StateError) {
    final text = error.message;
    // `NativeStreamPlayerHandle` reports "AVPlayer Ns 内未就绪" through a
    // StateError; anything else from a StateError is a programming mistake.
    if (text.contains('未就绪') || text.contains('初始化失败')) {
      return PlaybackFailure.playerInitFailed;
    }
    return PlaybackFailure.unknown;
  }
  final text = error.toString();
  if (text.contains('StreamingV2Unavailable')) {
    return PlaybackFailure.resourceLoading;
  }
  return classifyPlaybackMessage(text);
}

/// Same classification for a message we did not throw ourselves: the feed's
/// own `_fail` texts and the strings TDLib returns.
PlaybackFailure classifyPlaybackMessage(String message) {
  final text = message.toUpperCase();
  if (text.isEmpty) return PlaybackFailure.unknown;
  if (text.contains('FILE_ID_INVALID') ||
      text.contains('FILE NOT FOUND') ||
      text.contains('FILE_REFERENCE') ||
      message.contains('文件已失效') ||
      message.contains('文件不存在')) {
    return PlaybackFailure.fileNotFound;
  }
  if (text.contains('FLOOD_WAIT') ||
      text.contains('CHAT_FORBIDDEN') ||
      text.contains('CHANNEL_PRIVATE') ||
      text.contains('TDLIB ERROR') ||
      text.contains('AUTHORIZATION')) {
    return PlaybackFailure.tdlibError;
  }
  if (message.contains('无法解码') || text.contains('DECODE')) {
    return PlaybackFailure.decoderFailed;
  }
  if (message.contains('已取消') || text.contains('CANCEL')) {
    return PlaybackFailure.requestCancelled;
  }
  if (message.contains('初始化失败') || message.contains('未就绪')) {
    return PlaybackFailure.playerInitFailed;
  }
  if (message.contains('流式播放不可用') ||
      message.contains('读取视频数据失败') ||
      text.contains('RESOURCE_LOADER') ||
      text.contains('DOWNLOAD_STALLED')) {
    return PlaybackFailure.resourceLoading;
  }
  return PlaybackFailure.unknown;
}
