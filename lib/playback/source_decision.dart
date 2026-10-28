/// Which transport a play should use, decided from facts instead of from
/// the path the code happens to be on.
///
/// The device report that motivated this file had a 756,031,238-byte video
/// recorded as `completed=true`, `downloaded=756,031,238`, and still opened
/// over the loopback HTTP proxy, which then declared a 754,966,576-byte body
/// and carried 20,496,682 — `RANGE_TRUNCATED`, `HTTP_BODY_INCOMPLETE`,
/// `PROXY_STALL`, `player_initialization_failed`.
///
/// Two mistakes produced that:
///
/// * the "complete" test trusted TDLib's flag alone. A record can say 100%
///   while the bytes on disk are a fraction of it (a truncated pool file, a
///   purged cache with a surviving record, a partially written window). Such a
///   file is *not* playable and must not be treated as a growing file either,
///   because TDLib will never write another byte for it;
/// * a failure to install the player fell through to "try the other transport"
///   without re-reading the file. By then the file was often complete, and the
///   fallback was the one transport that cannot serve a complete file well.
///
/// So the decision is a pure function of [SourceFacts]. It can be tested
/// without a player, a socket, or a device, and every branch names itself in
/// the diagnostics.
library;

/// The transports a play can end up on.
enum PlaybackSourceKind {
  /// Read the file at its path. No proxy, no resource loader.
  localFile,

  /// `AVAssetResourceLoader` over `tgmedia://` (V2).
  resourceLoader,

  /// Loopback HTTP range proxy (V1).
  httpProxy,

  /// Wait for the whole file, then play it. Only reachable from
  /// [decidePlaybackSource] — i.e. before any stream was attempted. A stream
  /// that *failed* never lands here.
  fullDownload,

  /// Give up on this play and say so. The device report is the reason this
  /// value exists: "no transport left" used to mean "download the whole
  /// file", which turned a 4.9 MB proxy stall into a 593 MB download and a
  /// 162-second wait before the video even started.
  stop,

  /// Streaming could not even start: TDLib has no record for the id, or the
  /// size is unknown. Distinct from [fullDownload] on purpose — "the id the
  /// tile carried is stale" and "the user asked for a complete cache" are not
  /// the same instruction, and only the second one may download a film.
  streamingNotStarted,
}

/// Everything the decision is allowed to look at.
///
/// Deliberately all-value: no api handle, no file handle, no player. That is
/// what makes the decision reproducible in a test with five constructor named
/// arguments.
class SourceFacts {
  const SourceFacts({
    required this.fileId,
    this.hasRecord = true,
    this.claimedComplete = false,
    this.downloadedBytes = 0,
    this.downloadOffset = 0,
    this.recordSize = 0,
    this.expectedBytes = 0,
    this.path = '',
    this.pathExists = false,
    this.diskSize = -1,
  });

  /// No TDLib record at all: nothing is known, so the decision cannot be
  /// anything but "download it first".
  const SourceFacts.missing(this.fileId)
      : hasRecord = false,
        claimedComplete = false,
        downloadedBytes = 0,
        downloadOffset = 0,
        recordSize = 0,
        expectedBytes = 0,
        path = '',
        pathExists = false,
        diskSize = -1;

  final int fileId;
  final bool hasRecord;

  /// TDLib's `is_downloading_completed`. A claim, not a measurement.
  final bool claimedComplete;

  /// `downloaded_size`, counted from [downloadOffset] — the window model.
  final int downloadedBytes;
  final int downloadOffset;

  /// `file.size` as TDLib reports it.
  final int recordSize;

  /// The size the file is supposed to have. 0 while unknown.
  final int expectedBytes;

  /// TDLib's `local.path`. Empty until the transfer names its file.
  final String path;
  final bool pathExists;

  /// `File(path).length()`. -1 when it could not be read.
  final int diskSize;

  bool get sizeKnown => expectedBytes > 0;

  /// The bytes on disk cover the declared size. This — not the flag — is what
  /// "complete" means here.
  bool get diskCoversExpected =>
      expectedBytes > 0 && diskSize >= 0 && diskSize >= expectedBytes;

  /// Playable from disk: a real path, a file behind it, and enough bytes.
  bool get isPlayableFromDisk =>
      path.isNotEmpty && pathExists && diskCoversExpected;

  /// TDLib says finished but the bytes are short. Nothing will ever arrive
  /// for this file again, so waiting is guaranteed to fail: it has to be
  /// re-downloaded, not streamed.
  bool get isShorterThanClaimed {
    if (!claimedComplete || !sizeKnown) return false;
    // A record marked complete whose file is gone is as broken as one that is
    // short: both need a re-download, and neither will ever grow on its own.
    if (!pathExists) return true;
    return diskSize >= 0 && diskSize < expectedBytes;
  }

  /// How many bytes are missing behind the "complete" claim.
  int get missingBytes => isShorterThanClaimed ? expectedBytes - diskSize : 0;

  /// What the panel prints next to the decision.
  String get summary => 'expected=$expectedBytes downloaded=$downloadedBytes '
      'claimed=$claimedComplete disk=$diskSize path=${path.isEmpty ? '-' : path}';

  @override
  String toString() => 'SourceFacts(file=$fileId $summary)';
}

/// The answer, with the sentence that explains it.
class PlaybackDecision {
  const PlaybackDecision({
    required this.source,
    required this.reason,
    required this.facts,
    this.forced = false,
    this.needsRedownload = false,
  });

  final PlaybackSourceKind source;
  final String reason;
  final SourceFacts facts;

  /// `FORCE_STREAMING_TEST` overrode a playable local file on purpose.
  final bool forced;

  /// The file is shorter than TDLib claims: cancel and restart the transfer
  /// before serving any bytes.
  final bool needsRedownload;

  /// The string the diagnostics report uses (`LOCAL_FILE`, `RESOURCE_LOADER`,
  /// `HTTP_PROXY`, `FULL_DOWNLOAD`, `STOP`).
  String get code {
    switch (source) {
      case PlaybackSourceKind.localFile:
        return 'LOCAL_FILE';
      case PlaybackSourceKind.resourceLoader:
        return 'RESOURCE_LOADER';
      case PlaybackSourceKind.httpProxy:
        return 'HTTP_PROXY';
      case PlaybackSourceKind.fullDownload:
        return 'FULL_DOWNLOAD';
      case PlaybackSourceKind.stop:
        return 'STOP';
      case PlaybackSourceKind.streamingNotStarted:
        return 'STREAMING_NOT_STARTED';
    }
  }

  bool get isStreaming =>
      source == PlaybackSourceKind.resourceLoader ||
      source == PlaybackSourceKind.httpProxy;

  @override
  String toString() =>
      'PlaybackDecision($code reason=$reason forced=$forced '
      'redownload=$needsRedownload ${facts.summary})';
}

/// The whole rule, in one place.
///
/// Order matters and is the specification:
///
/// 1. no record / no size → streaming not started (nothing honest to serve,
///    and not an instruction to download);
/// 2. a playable complete file → local file, whatever else is true;
/// 3. streaming switched off → full download;
/// 4. V2 available → resource loader (a short-but-claimed-complete file is
///    flagged for re-download; it is still not a local file);
/// 5. otherwise V1.
///
/// [forceStreaming] is the acceptance switch: it exists to exercise the
/// transports on a file that is already complete, and it never overrides the
/// first rule. Production leaves it false, which is why rule 2 is absolute
/// there.
PlaybackDecision decidePlaybackSource(
  SourceFacts facts, {
  required bool streamingEnabled,
  required bool forceStreaming,
  required bool v2Supported,
}) {
  // No record / no size: streaming cannot start, and that is a *verdict*.
  // It used to be `fullDownload`, which the controller read as an instruction
  // and answered with `downloadFile(limit: 0)` — on a 24 MB video whose tile
  // id had gone stale, that downloaded the file under a different id and
  // reported `finalSource=LOCAL_FILE` with `localFileExists=false`.
  if (!facts.hasRecord) {
    return PlaybackDecision(
      source: PlaybackSourceKind.streamingNotStarted,
      reason: 'no_file_record',
      facts: facts,
    );
  }
  if (!facts.sizeKnown) {
    return PlaybackDecision(
      source: PlaybackSourceKind.streamingNotStarted,
      reason: 'unknown_size',
      facts: facts,
    );
  }
  if (facts.isPlayableFromDisk) {
    if (forceStreaming) {
      return PlaybackDecision(
        source: v2Supported
            ? PlaybackSourceKind.resourceLoader
            : PlaybackSourceKind.httpProxy,
        reason: 'forced_over_complete_file',
        facts: facts,
        forced: true,
      );
    }
    return PlaybackDecision(
      source: PlaybackSourceKind.localFile,
      reason: 'complete_file_on_disk',
      facts: facts,
    );
  }
  if (!streamingEnabled) {
    return PlaybackDecision(
      source: PlaybackSourceKind.fullDownload,
      reason: 'streaming_disabled_by_preference',
      facts: facts,
    );
  }
  // A file that claims to be complete but is not gets one explicit action:
  // restart the transfer. Streaming it would wait forever — TDLib has nothing
  // left to send for a file it considers finished.
  final redownload = facts.isShorterThanClaimed;
  final reason = redownload
      ? 'short_of_claimed_size'
      : (facts.path.isEmpty ? 'no_local_path_yet' : 'partial_file');
  if (v2Supported) {
    return PlaybackDecision(
      source: PlaybackSourceKind.resourceLoader,
      reason: reason,
      facts: facts,
      needsRedownload: redownload,
    );
  }
  return PlaybackDecision(
    source: PlaybackSourceKind.httpProxy,
    reason: reason,
    facts: facts,
    needsRedownload: redownload,
  );
}

/// The rule after a transport failed: re-read the file before trying the next
/// one.
///
/// This is the specific gap in the device report. V2 failed to install, the
/// controller moved to V1 without asking whether the file had finished in the
/// meantime, and V1 — the one transport that cannot serve a finished file
/// without a growing-file race — was handed a complete 720 MB file.
///
/// A complete file after a failed stream is a success, not a step down:
/// return [PlaybackSourceKind.localFile]. A moved-but-incomplete file goes to
/// the other stream. **Nothing left goes to [PlaybackSourceKind.stop]** — the
/// second device report is why: after V1 stalled, "nothing left" meant
/// `fullDownload`, and a 4.9 MB proxy stall became 593 MB downloaded and
/// 162 seconds before the first frame.
///
/// [fullDownload] is deliberately unreachable from here. Waiting for a whole
/// film is a choice the user makes, not something a failed transport gets to
/// decide.
PlaybackDecision decideAfterTransportFailure(
  SourceFacts facts, {
  required PlaybackSourceKind failed,
  required bool v2Supported,
}) {
  // A local file the player refused is not a transport problem: the bytes are
  // all there and the decoder still said no. Asking for the same file again
  // would loop, so this case is decided before "is it complete" — and
  // re-downloading it would be the same bytes into the same decoder.
  if (failed == PlaybackSourceKind.localFile) {
    return PlaybackDecision(
      source: PlaybackSourceKind.stop,
      reason: 'local_file_refused_by_decoder',
      facts: facts,
    );
  }
  if (!facts.hasRecord || !facts.sizeKnown) {
    return PlaybackDecision(
      source: PlaybackSourceKind.stop,
      reason: 'record_lost_after_failure',
      facts: facts,
    );
  }
  if (facts.isPlayableFromDisk) {
    return PlaybackDecision(
      source: PlaybackSourceKind.localFile,
      reason: 'completed_while_stream_was_failing',
      facts: facts,
    );
  }
  switch (failed) {
    case PlaybackSourceKind.resourceLoader:
      // A bridge that exists but did not install leaves exactly one
      // transport-level attempt: the loopback proxy, on the same bytes.
      return PlaybackDecision(
        source: PlaybackSourceKind.httpProxy,
        reason: 'v2_failed_try_v1',
        facts: facts,
        needsRedownload: facts.isShorterThanClaimed,
      );
    case PlaybackSourceKind.httpProxy:
      // Both streaming transports failed on a file that is still short. The
      // honest next state is an error, not a download.
      return PlaybackDecision(
        source: PlaybackSourceKind.stop,
        reason: 'v1_failed_stop',
        facts: facts,
      );
    case PlaybackSourceKind.localFile:
    case PlaybackSourceKind.fullDownload:
    case PlaybackSourceKind.stop:
    case PlaybackSourceKind.streamingNotStarted:
      return PlaybackDecision(
        source: PlaybackSourceKind.stop,
        reason: 'nothing_left_to_try',
        facts: facts,
      );
  }
}
