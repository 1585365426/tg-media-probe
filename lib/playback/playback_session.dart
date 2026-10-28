/// One tap, one session.
///
/// The device reports that motivated this file all shared one shape: state
/// from an earlier play leaked into a later one, or a counter that belonged to
/// "the transport" was read as if it belonged to "the video". Both mistakes
/// come from not having a thing whose lifetime *is* the play. This is that
/// thing.
///
/// A [PlaybackSession] is created when the user opens a video and is replaced
/// — never mutated across — when they open another. Everything the play is
/// allowed to remember lives here: the file the tap resolved to, whether
/// streaming was tried, whether the whole-file fallback was spent, and what
/// the play finally played from.
library;

/// The one file a tap is allowed to play.
///
/// Resolved from `chatId` + `messageId` — never from a remembered `fileId`.
/// A `fileId` is TDLib's runtime handle: the device log had a tile carrying
/// `4999` while TDLib's live record sat at `2221`, and every module that kept
/// its own id was wrong in its own way. This object is the single answer the
/// whole play reads from.
class PlayableFile {
  const PlayableFile({
    required this.chatId,
    required this.messageId,
    required this.fileId,
    this.fileUniqueId = '',
    this.expectedSize = 0,
    this.localPath = '',
    this.localSize = -1,
    this.isComplete = false,
    this.generation = 0,
  });

  final int chatId;
  final int messageId;

  /// The live TDLib id at resolve time. Runtime value, not an identity.
  final int fileId;

  /// TDLib's stable id, when the metadata source provides one. Empty when it
  /// does not — absence here is honest, a stale one would not be.
  final String fileUniqueId;
  final int expectedSize;

  /// What is actually behind the path, measured. -1 = not measurable.
  final int localSize;
  final String localPath;

  /// True only when [localPath] exists **and** [localSize] reaches
  /// [expectedSize]. A record's word is not part of this.
  final bool isComplete;
  final int generation;
}

/// The state of exactly one play.
///
/// `fullDownloadFallbackUsed` is the load-bearing field. It is a session
/// field on purpose — a global would let play B inherit play A's spent
/// fallback (or worse, its unspent one), and a per-transport field would
/// reset every time a transport hiccupped. One tap, one whole-file download,
/// at most.
class PlaybackSession {
  PlaybackSession({
    required this.chatId,
    required this.messageId,
    String? sessionId,
  }) : sessionId = sessionId ??
            'p-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
                '-$messageId';

  final String sessionId;
  final int chatId;
  final int messageId;

  /// Updated when the message is re-resolved; the tile's id may be stale.
  int resolvedFileId = 0;
  bool streamingAttempted = false;

  /// Spent by the first whole-file fallback this session makes. There is no
  /// second one: a play that streamed, fell back, and failed again stops and
  /// says so instead of downloading twice.
  bool fullDownloadFallbackUsed = false;
  String finalSource = '';
  bool playerReady = false;

  bool get canUseFullDownloadFallback => !fullDownloadFallbackUsed;

  /// Marks the fallback spent and answers whether *this* call is the one that
  /// gets it. `false` means somebody in this session already spent it.
  bool spendFullDownloadFallback() {
    if (fullDownloadFallbackUsed) return false;
    fullDownloadFallbackUsed = true;
    return true;
  }
}
