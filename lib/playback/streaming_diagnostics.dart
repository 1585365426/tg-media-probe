/// Live evidence for one play, and the verdict derived from it.
///
/// Why this file exists: "边下边播" is a claim about *data*, not about a code
/// path. Handing AVPlayer a `http://127.0.0.1:port/...` URL proves nothing —
/// if the proxy silently waits for the whole file before answering, the user
/// still watches a full download and the code still calls it "streaming". The
/// only honest answer comes from the numbers the run actually produced:
///
/// * did the player start (`isPlaying` / `position > 0`)?
/// * how many of the total bytes were on disk at that moment?
/// * did the proxy answer at least one `206 Partial Content`?
/// * was the file still incomplete then?
///
/// Every field here is written by the component that owns the fact:
/// * TDLib window/bytes  → `VideoSourceResolver`'s file watch (`updateFile`);
/// * Range/status/206    → `StreamProxyServer` (its own callbacks);
/// * playhead/status/err → `VideoPlayerHandle` (the player's own value).
///
/// Nothing is inferred from which branch the code took. When the data cannot
/// settle the question, the verdict stays [StreamingVerdict.unknown] — that is
/// a result, not a gap to paper over.
library;

import 'package:flutter/foundation.dart';

import '../td/td_models.dart' show FileState;
import '../util/byte_format.dart';
import '../util/redact.dart';
import 'mp4_probe.dart';
import 'download_audit.dart';
import 'source_decision.dart';
import 'playback_failure.dart';
import 'stream_proxy.dart' show ProxyExchange;

/// What the recorded evidence says.
enum StreamingVerdict {
  /// Not enough real data to say anything yet.
  unknown,

  /// The player was running while bytes were still missing.
  /// Requires all six conditions of the acceptance rule.
  streamingActive,

  /// The player only started once the whole file was on disk.
  fullDownloadBeforePlayback,

  /// Streaming was attempted and abandoned; the full download took over.
  fallbackUsed,

  /// The pipeline never entered the streaming branch for this play — either
  /// the resolver skipped it (prefetch cache) or the player was fed a local
  /// file path. Bytes-on-disk numbers alone cannot make this a stream.
  streamingNotStarted,
}

extension StreamingVerdictView on StreamingVerdict {
  /// The line the diagnostics screen must show. Never "Streaming" on its own.
  String get label => switch (this) {
        StreamingVerdict.streamingActive => '✅ 已确认：边下边播',
        StreamingVerdict.fullDownloadBeforePlayback => '⚠️ 全部下载完成后播放',
        StreamingVerdict.fallbackUsed => '⏭️ 流式失败，已回退到完整下载',
        StreamingVerdict.streamingNotStarted => '⛔ Streaming 未启动',
        StreamingVerdict.unknown => '❓ 无法判定',
      };

  /// The token written into the timeline and the acceptance report.
  String get code => switch (this) {
        StreamingVerdict.streamingActive => 'STREAMING_CONFIRMED',
        StreamingVerdict.fullDownloadBeforePlayback =>
          'FULL_DOWNLOAD_BEFORE_PLAYBACK',
        StreamingVerdict.fallbackUsed => 'STREAMING_FALLBACK',
        StreamingVerdict.streamingNotStarted => 'STREAMING_NOT_STARTED',
        StreamingVerdict.unknown => 'UNKNOWN',
      };
}

/// One `(time, bytes)` sample of the TDLib transfer, for the "downloaded keeps
/// moving" evidence line.
class StreamingGrowthSample {
  const StreamingGrowthSample(this.millis, this.bytes);

  final int millis;
  final int bytes;
}

/// One Streaming V2 event, stamped with the play it belongs to.
///
/// The acceptance questions are per-request ("did request 3 get more than one
/// respond", "did the tail request finish or was it cancelled"), so the log
/// keeps the fields instead of a rendered string.
class ResourceLoaderEvent {
  const ResourceLoaderEvent({
    required this.name,
    required this.fields,
    required this.chatId,
    required this.messageId,
    required this.fileId,
    required this.generation,
    required this.elapsedMillis,
  });

  /// `resourceLoaderCreated`, `contentInfoRequested`, `contentInfoReady`,
  /// `dataRequestCreated`, `respond`, `waitingForGrowth`, `growthDetected`,
  /// `targetedDownloadRequested`, `dataRequestFinished`,
  /// `dataRequestCancelled`, `playerItemCreated`, `playerReady`,
  /// `playerFailed`.
  final String name;
  final Map<String, Object?> fields;
  final int? chatId;
  final int? messageId;
  final int? fileId;
  final int generation;
  final int elapsedMillis;

  Object? operator [](String key) => fields[key];

  /// `t=120ms dataRequestCreated offset=0 length=524288 file=9123 gen=7`
  @override
  String toString() {
    final rest = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final identity = 'file=${fileId ?? '-'} msg=${messageId ?? '-'} '
        'chat=${chatId ?? '-'} gen=$generation';
    return 't=${elapsedMillis}ms $name'
        '${rest.isEmpty ? '' : ' $rest'} $identity';
  }
}

/// Live streaming diagnostics for the current (or last) play.
///
/// A [ChangeNotifier] because both the on-device overlay and the settings
/// diagnostics section render from it and must follow the transfer in real
/// time. Reset once per play by [beginPlay]; the previous run's verdict stays
/// readable until the next one starts.
class StreamingDiagnostics extends ChangeNotifier {
  /// The instance the whole app shares: the resolver writes to it, the feed
  /// overlay and the settings diagnostics section read from it. Tests build
  /// their own instead.
  static final StreamingDiagnostics instance = StreamingDiagnostics();

  /// Whether the diagnostics overlay / panel is on. Off by default: normal
  /// users never see any of this.
  bool _enabled = false;

  /// True when the resolver took the streaming branch for this play.
  bool _streamingEnabled = false;

  /// Snapshot of [_forceTest] taken when the current play began. The panel and
  /// the verdict must reflect the mode that was active **during the play**,
  /// not whatever the toggle says right now — otherwise pressing 结束验收
  /// before reading the report rewrites history to OFF.
  bool _forceTestAtPlay = false;

  /// Set when an acceptance run is ended: from then on no later play may
  /// wipe the recorded evidence. Only [startAcceptance] unseals it.
  bool _sealedResult = false;

  // ---- streaming decision trace -------------------------------------
  //
  // The ON→OFF question had no answer on screen because the decision was
  // implicit: several branches returned a local file without saying why.
  // These fields make the decision itself evidence: every LOCAL_FILE /
  // FALLBACK return has to name its reason.

  /// The preference layer: is streaming allowed for an ordinary play?
  bool? _decisionPreference;

  /// The acceptance layer: was FORCE_STREAMING_TEST on for this play?
  bool? _decisionForce;

  /// Did the video pass the structural checks (size known, path, format)?
  bool? _decisionCandidate;
  String? _decisionCandidateReason;

  /// Did the loopback proxy actually bind and get handed to the player?
  bool? _decisionProxyAvailable;

  /// Was the file already whole when the play was resolved?
  bool? _decisionFileComplete;

  /// The transport decision taken from measured facts. Separate from
  /// `_decision` above, which is the *legacy* branch label: this one names the
  /// transport the play should have used (`LOCAL_FILE`, `RESOURCE_LOADER`,
  /// `HTTP_PROXY`, `FULL_DOWNLOAD`) and the numbers it was based on, so a
  /// report can be audited without re-running the device.
  String? _playbackDecision;
  String? _playbackDecisionReason;
  int? _decisionLocalSize;
  int? _decisionExpectedSize;
  bool? _decisionDiskCovers;
  bool _decisionRedownload = false;
  List<int> _preloadFileIds = const <int>[];
  bool _v2Attempted = false;
  bool _v2Failed = false;
  bool _v1Attempted = false;
  bool _v1Failed = false;
  String? _finalSource;

  /// Every `downloadFile` of the current play, with the caller that sent it
  /// and the bytes it actually moved. This is the object that answers "who
  /// downloaded 152 MB before the first frame" — and it is fed by the transfer
  /// layer itself, not by an inference from which branch ran.
  final DownloadAudit downloadAudit = DownloadAudit();

  /// STREAM / LOCAL_FILE / FALLBACK — what the resolver returned.
  String? _decision;
  String? _decisionReason;

  /// FORCE_STREAMING_TEST: the developer/acceptance switch. While on, the
  /// feed controller must not serve the play from the prefetch cache and must
  /// not run background prefetches — every play goes through the streaming
  /// resolver, and a full download before playback is a FAIL, not a success.
  bool _forceTest = false;

  /// The app's standing preference for the current video: streaming first.
  ///
  /// Sourced from [AppPreferences.streamingPlayback] at startup and exposed
  /// here so the panel can show TEST / PREFERENCE / EFFECTIVE side by side —
  /// and so a preference that is off is *visible*, not inferred from a
  /// silent full download.
  bool _preferenceStreaming = true;

  bool get userStreamingPreference => _preferenceStreaming;

  /// What the live player was actually handed: `STREAM_HTTP` (a loopback URL
  /// served by the range proxy) or `LOCAL_FILE` (a path). Written by the feed
  /// controller immediately before `player.activate`, from the source it is
  /// about to open — never inferred afterwards.
  String? _playerSourceType;

  // ---- Streaming V2 (AVAssetResourceLoader) -------------------------------
  //
  // Counted separately from the V1 HTTP numbers on purpose. A V2 run has no
  // 206 and no Content-Range, and reading its result through the V1 counters
  // would report "streaming never started" for a perfectly good play.
  int _rlSessions = 0;
  int _rlRequests = 0;
  int _rlResponds = 0;
  int _rlBytes = 0;
  int _rlStalls = 0;
  String? _rlContentInfo;

  /// `(requestId, offset)` already counted, so the two producers of
  /// `dataRequestCreated` (Swift per loading request, Dart per chunk) cannot
  /// double the request count. Bounded like the event log.
  final Set<String> _v2RequestKeys = <String>{};

  static const int maxV2RequestKeys = 4000;

  /// The first read that failed, and what the native side said about it.
  ///
  /// Kept raw and kept once. "读取失败" on the error page is the end of a chain,
  /// and the answer to "where did it break" is the *first* `supplyError` or
  /// `playerFailed`, not the last retry — a report that only has the final
  /// text cannot tell a decode refusal from a range the loader never served.
  Map<String, Object?>? _firstReadError;

  /// Why the play stopped without a second transport, when V2-only is on.
  String? _v2StopReason;

  /// The exact URL the player opened in STREAM_HTTP mode.
  String? _proxyUrl;

  int? _chatId;
  int? _messageId;
  int? _fileId;

  /// The list item the user tapped, exactly as the local index stored it.
  /// Kept apart from the TDLib file state: if the two disagree the app is
  /// playing a different file than the tile shows, which is a real defect and
  /// must be visible instead of being averaged into one number.
  int? _recordFileId;
  int? _recordMessageId;
  int _recordSizeBytes = 0;

  /// Every HTTP exchange the proxy really performed, oldest first, capped so a
  /// long play cannot grow the report without bound.
  final List<ProxyExchange> _exchanges = <ProxyExchange>[];
  static const int _maxExchanges = 12;

  /// Exchanges where the player asked for more bytes than it received.
  int _truncatedCount = 0;

  /// Exchanges whose body carried fewer bytes than their `Content-Length`,
  /// for any reason (stall or client close).
  int _incompleteCount = 0;

  /// Exchanges whose `Content-Length` did not match the span the request
  /// asked for. This must stay 0: it is the "headers lie" defect.
  int _headerMismatchCount = 0;

  /// Requests that asked for bytes away from 0 — a moov probe or a seek.
  int _forwardRangeRequests = 0;

  /// Which play these numbers belong to.
  ///
  /// Incremented by [beginPlay]; every resolver-side writer passes the value
  /// it captured when its play started. A watcher, proxy or parser left over
  /// from a superseded play can therefore never write into the live block —
  /// that leak is what once showed "300 MB → 302 MB" growth for a 23 MB video.
  int _generation = 0;

  /// The current play generation. Everything recorded against an older one is
  /// dropped, and the resource loader uses the same number to refuse a byte
  /// from a video the user already left.
  int get generation => _generation;

  /// `clicked → active → player`, the three identities every device report
  /// has to be able to compare. `clicked` is the list item, `active` the
  /// record the controller claimed, `player` what was handed to the player.
  int? _clickedFileId;
  int? _activeFileId;
  int? _playerFileId;
  int? _clickedChatId;
  int? _clickedMessageId;
  int? _activeChatId;
  int? _activeMessageId;

  int? get clickedFileId => _clickedFileId;
  int? get activeFileId => _activeFileId;
  int? get playerFileId => _playerFileId;

  /// True when the tapped video, the claimed video and the played video are
  /// the same file. Null-safe: while fewer than three are known it returns
  /// true (nothing has contradicted anything yet), and the report prints `-`.
  bool get identityOk {
    final ids = <int?>[_clickedFileId, _activeFileId, _playerFileId]
        .whereType<int>()
        .where((id) => id != 0)
        .toSet();
    return ids.length <= 1;
  }

  /// Where the `moov` atom sits, scanned from the bytes on disk.
  MoovPosition _moov = MoovPosition.unknown;

  /// `moov` box span, when the scan could compute it (`-1` otherwise).
  int _moovStart = -1;
  int _moovEnd = -1;

  /// The last FILE_ID_RESOLVE snapshot — see [noteFileIdResolve].
  int? _resolveClickedId;
  int? _resolveRecordId;
  int? _resolveResolvedId;
  int? _resolveTdlibId;
  int? _resolveMessageId;
  int? _resolveGeneration;
  String? _resolveUniqueId;
  final List<String> _remaps = <String>[];

  /// Player lifecycle, with the clock of this play.
  int? _playerCreatedMillis;
  int? _playerReadyMillis;
  int? _playerFailedMillis;
  String? _playerFailedText;

  /// Why this play failed, in the one vocabulary the report and the error page
  /// share. Null while the play is healthy.
  PlaybackFailure? _failureKind;
  String? _failureMessage;

  int _totalBytes = 0;
  int _downloadedBytes = 0;

  /// Last time `downloaded` actually grew, as wall-clock millis.
  ///
  /// The question a frozen play has to answer is "is anything still arriving",
  /// and a percentage cannot answer it: 0.1 % looks identical whether TDLib is
  /// writing or dead. This is the number that tells them apart.
  int _lastGrowthAt = 0;
  int _headBytes = 0;
  int _downloadOffset = 0;
  int _windowStart = 0;
  int _windowEnd = 0;

  /// Bytes measured behind the file's path, or -1 when nothing was measured.
  ///
  /// Kept apart from [_downloadedBytes] on purpose. `downloaded_size` is
  /// TDLib's count of what it has written; a `stat` is the length of the file.
  /// Neither one alone answers "is the whole film here" — a pool file can be
  /// full length with an unwritten middle — so the panel prints both and the
  /// completion flag needs both.
  int _diskBytes = -1;

  /// A `completed` claim that the disk did not confirm. Reported, never used
  /// to draw a progress bar.
  String? _completionRefusal;

  bool _isDownloading = false;
  bool _isDownloadingCompleted = false;

  int _rangeRequests = 0;
  String? _lastRange;
  int? _lastStatus;
  int _partialContentCount = 0;
  int _windowMoves = 0;
  int _stalls = 0;
  String? _lastStallReason;

  Duration _playerTime = Duration.zero;
  Duration _playerDuration = Duration.zero;
  String _timeControlStatus = 'unknown';
  bool _hasStartedPlaying = false;
  String? _playerError;

  bool _fallback = false;
  String? _fallbackReason;

  int? _firstPlaybackDownloadedBytes;
  int? _firstPlaybackTotalBytes;
  bool _firstPlaybackCompleted = false;
  int? _firstPlaybackMillis;
  int? _downloadCompletedMillis;
  int? _firstBytesMillis;
  int? _first206Millis;
  int? _firstRangeMillis;
  int? _proxyStartedMillis;

  /// When the first V2 `dataRequestCreated` arrived.
  ///
  /// V2 has no port to bind, so [proxyStartedMillis] — V1's "the transport is
  /// really up" marker — is never set on a resource-loader play. Without this
  /// the verdict read `attempted=false` for a run that had already pushed
  /// hundreds of megabytes into the player, and the panel reported
  /// STREAMING_NOT_STARTED next to a playing video.
  int? _v2StartedMillis;

  /// True between [startAcceptance] and the moment the verdict settles.
  bool _acceptanceRunning = false;

  DateTime? _startedAt;
  final DateTime Function() _clock;

  StreamingDiagnostics({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final List<StreamingGrowthSample> _growth = <StreamingGrowthSample>[];
  final List<String> _events = <String>[];

  // ---- reads ---------------------------------------------------------

  bool get enabled => _enabled;
  bool get streamingEnabled => _streamingEnabled;
  bool get forceStreamingTest => _forceTest;

  /// Whether FORCE_STREAMING_TEST was on when the recorded play started.
  bool get forceTestAtPlay => _forceTestAtPlay;
  String? get playerSourceType => _playerSourceType;
  String? get proxyUrl => _proxyUrl;
  int? get chatId => _chatId;
  int? get messageId => _messageId;
  int? get fileId => _fileId;

  /// Size the tapped list item claims, straight from the index record.
  int get recordSizeBytes => _recordSizeBytes;
  int? get recordFileId => _recordFileId;
  int? get recordMessageId => _recordMessageId;

  /// The tapped item and the file TDLib is serving are two different files.
  /// Unknown sizes on either side are "not comparable", never a mismatch.
  bool get recordSizeMismatch =>
      _recordSizeBytes > 0 &&
      _totalBytes > 0 &&
      _recordSizeBytes != _totalBytes;

  List<ProxyExchange> get exchanges => List<ProxyExchange>.unmodifiable(_exchanges);
  int get truncatedCount => _truncatedCount;

  /// 206 bodies that carried fewer bytes than their `Content-Length`.
  int get incompleteCount => _incompleteCount;

  /// 206 headers whose `Content-Length` did not match `Content-Range`.
  int get headerMismatchCount => _headerMismatchCount;
  int get forwardRangeRequests => _forwardRangeRequests;
  MoovPosition get moov => _moov;
  int? get playerCreatedMillis => _playerCreatedMillis;
  int? get playerReadyMillis => _playerReadyMillis;
  int? get playerFailedMillis => _playerFailedMillis;
  String? get playerFailedText => _playerFailedText;

  /// The classified reason this play ended in an error page, or null.
  PlaybackFailure? get failureKind => _failureKind;
  String? get failureMessage => _failureMessage;

  int get totalBytes => _totalBytes;
  int get downloadedBytes => _downloadedBytes;

  /// The measured length of the file behind the path, or -1 when unmeasured.
  int get diskBytes => _diskBytes;

  /// True only when the bytes behind the path reach the declared total *and*
  /// TDLib's own completion claim agreed. Both halves are needed: see
  /// [noteCompleted].
  bool get diskCoversTotal =>
      _totalBytes > 0 && _diskBytes >= 0 && _diskBytes >= _totalBytes;

  /// Whether the whole file is on disk, and how that was established.
  ///
  /// Two independent facts can prove it: TDLib's own completion claim, or a
  /// measured length that reaches the total. The panel used to print only the
  /// claim, so a play whose file was already whole read
  /// `disk=162308586 B FULL` / `downloaded=100.0%` / `completed=false` — three
  /// lines that cannot all be true. `completed` now means "the bytes are
  /// there", and [completionEvidence] says which fact produced it.
  bool get transferCompleted =>
      _isDownloadingCompleted || diskCoversTotal;

  /// `TDLIB` / `DISK` / `NONE` — never a bare boolean, so the source of the
  /// claim stays visible in the report.
  String get completionEvidence {
    if (_isDownloadingCompleted) return 'TDLIB';
    if (diskCoversTotal) return 'DISK';
    return 'NONE';
  }

  /// Why a `completed` claim was not turned into `100%`, when it was refused.
  String? get completionRefusal => _completionRefusal;

  int get headBytes => _headBytes;
  int get downloadOffset => _downloadOffset;
  int get windowStart => _windowStart;
  int get windowEnd => _windowEnd;

  bool get isDownloading => _isDownloading;
  bool get isDownloadingCompleted => _isDownloadingCompleted;

  int get rangeRequests => _rangeRequests;
  String? get lastRange => _lastRange;
  int? get lastStatus => _lastStatus;
  int get partialContentCount => _partialContentCount;
  bool get sawPartialContent => _partialContentCount > 0;
  int get windowMoves => _windowMoves;

  /// Streaming V2 counters, as the native loader reported them.
  int get resourceLoaderRequests => _rlRequests;
  int get resourceLoaderResponds => _rlResponds;
  int get resourceLoaderBytes => _rlBytes;
  int get resourceLoaderStalls => _rlStalls;
  int get resourceLoaderSessions => _rlSessions;
  String? get resourceLoaderContentInfo => _rlContentInfo;

  /// The first read that failed, in the native side's own words. Null when
  /// nothing failed.
  Map<String, Object?>? get firstReadError =>
      _firstReadError == null ? null : Map<String, Object?>.unmodifiable(_firstReadError!);

  /// Why a V2-only play stopped, when it did.
  String? get v2StopReason => _v2StopReason;
  int get stalls => _stalls;
  String? get lastStallReason => _lastStallReason;

  Duration get playerTime => _playerTime;
  Duration get playerDuration => _playerDuration;
  String get timeControlStatus => _timeControlStatus;
  bool get hasStartedPlaying => _hasStartedPlaying;
  String? get playerError => _playerError;

  bool get fallback => _fallback;
  String? get fallbackReason => _fallbackReason;

  int? get firstPlaybackDownloadedBytes => _firstPlaybackDownloadedBytes;
  int? get firstPlaybackTotalBytes => _firstPlaybackTotalBytes;
  int? get firstPlaybackMillis => _firstPlaybackMillis;
  int? get downloadCompletedMillis => _downloadCompletedMillis;
  int? get first206Millis => _first206Millis;
  int? get firstRangeMillis => _firstRangeMillis;
  int? get proxyStartedMillis => _proxyStartedMillis;
  int? get v2StartedMillis => _v2StartedMillis;

  /// Whether TDLib had already finished when the first frame played.
  bool get firstPlaybackCompleted => _firstPlaybackCompleted;

  /// Byte-count samples taken while the transfer ran, oldest first.
  /// Monotonically increasing: it is the "downloaded keeps moving" evidence.
  List<StreamingGrowthSample> get growth => growthSamples;

  bool get acceptanceRunning => _acceptanceRunning;

  /// True when an armed acceptance run has produced enough data to decide.
  bool get acceptanceConcluded =>
      _acceptanceRunning && verdict != StreamingVerdict.unknown;

  /// The single line a device run has to answer: streamed, or waited?
  String get acceptanceConclusion => verdict.code;

  List<StreamingGrowthSample> get growthSamples =>
      List<StreamingGrowthSample>.unmodifiable(_growth);

  /// The newest events first, already redacted (no paths, no tokens).
  List<String> get events => List<String>.unmodifiable(_events.reversed);

  /// 0..1 from the raw TDLib `downloaded_size`; 0 while the total is unknown.
  double get downloadedPercent {
    if (_totalBytes <= 0) return 0;
    final value = _downloadedBytes / _totalBytes;
    return value.clamp(0.0, 1.0);
  }

  String _percentString() =>
      '${(downloadedPercent * 100).toStringAsFixed(1)}%';

  /// Seconds since the download last moved. `-` before the first byte.
  ///
  /// Read together with `isDownloading`: `true` + a growing silence is exactly
  /// the "0.1 % and frozen" shape, and it is the only pair that can say it.
  String get transferSilenceSeconds {
    if (_lastGrowthAt == 0) return '-';
    final ms = DateTime.now().millisecondsSinceEpoch - _lastGrowthAt;
    return '${ms <= 0 ? 0 : (ms / 1000).floor()}';
  }

  /// `match=YES/NO/-` for the panel: `-` means one side has no size yet, so
  /// the comparison would be a guess.
  String _sizeMatchLabel() {
    if (_recordSizeBytes <= 0 || _totalBytes <= 0) return 'match=-';
    return recordSizeMismatch ? 'match=NO' : 'match=YES';
  }

  /// The verdict, computed from the recorded facts only.
  ///
  /// Order matters and is the acceptance rule itself:
  /// 1. a fallback happened → [StreamingVerdict.fallbackUsed];
  /// 2. the playhead never moved → [StreamingVerdict.unknown]
  ///    (a spinner is not evidence of anything);
  /// 3. the total is unknown → [StreamingVerdict.unknown]
  ///    ("146 MB" means nothing without the other number);
  /// 4. the file was already complete when playback started →
  ///    [StreamingVerdict.fullDownloadBeforePlayback], whatever the URL was;
  /// 5. at least one `206` for a real Range request while bytes were still
  ///    missing → [StreamingVerdict.streamingActive];
  /// 6. otherwise → [StreamingVerdict.unknown].
  StreamingVerdict get verdict {
    // "Streaming never ran" is not a fallback. A fallback that never bound a
    // proxy and never served a byte is a decision made before the pipeline
    // started, and the report has to say NOT_STARTED with a reason — calling
    // it STREAMING_FALLBACK was exactly the mislabel the device report caught.
    //
    // V2 has no proxy to bind, so its "did the transport run at all" evidence
    // is the native loader's own event stream: a data request, or a respond.
    // Reading only [proxyStartedMillis] made every resource-loader run look
    // unstarted — 275 responds and 133 MB delivered to AVPlayer, reported as
    // `req=0 resp=0 bytes=0` because nothing ever incremented those counters
    // from the path that actually serves the bytes.
    final attempted = _proxyStartedMillis != null ||
        _v2StartedMillis != null ||
        _rangeRequests > 0 ||
        _rlRequests > 0 ||
        _rlResponds > 0;
    if (_fallback && !attempted) return StreamingVerdict.streamingNotStarted;
    if (_fallback) return StreamingVerdict.fallbackUsed;
    final atFirstPlayback = _firstPlaybackDownloadedBytes;
    // No confirmed playhead = nothing to compare against.
    if (atFirstPlayback == null) return StreamingVerdict.unknown;
    final totalAtFirstPlayback = _firstPlaybackTotalBytes ?? 0;
    // Without a total, "146 MB" cannot be placed on any scale.
    if (totalAtFirstPlayback <= 0) return StreamingVerdict.unknown;
    // A forced run that never bound the proxy did not test streaming at all —
    // whatever the download numbers say. Reported before the completion check
    // so a prefetched video cannot pass off as "streaming was verified".
    if (_forceTestAtPlay && !attempted) {
      return StreamingVerdict.streamingNotStarted;
    }
    // Full file before the first played frame = not play-while-downloading.
    if (atFirstPlayback >= totalAtFirstPlayback || _firstPlaybackCompleted) {
      return StreamingVerdict.fullDownloadBeforePlayback;
    }
    // The play started while bytes were still missing, but the pipeline never
    // entered the streaming branch (or handed the player a local path): that
    // is "streaming did not start", not a confirmed stream and not an
    // unanswerable question.
    if (!_streamingEnabled || _playerSourceType == 'LOCAL_FILE') {
      return StreamingVerdict.streamingNotStarted;
    }
    // V2 has no status line: what proves the player was served from a partial
    // file is a data request that really carried bytes.
    final servedV2 = (_rlRequests > 0 || _rlResponds > 0) && _rlBytes > 0;
    if (!sawPartialContent && !servedV2) {
      return _forceTestAtPlay
          ? StreamingVerdict.streamingNotStarted
          : StreamingVerdict.unknown;
    }
    // A V2 play that answered nothing at all is not evidence of anything, even
    // if the transport was chosen.
    if (servedV2) return StreamingVerdict.streamingActive;
    if (_rangeRequests == 0) {
      return _forceTestAtPlay
          ? StreamingVerdict.streamingNotStarted
          : StreamingVerdict.unknown;
    }
    return StreamingVerdict.streamingActive;
  }

  bool get isStreamingConfirmed => verdict == StreamingVerdict.streamingActive;

  // ---- writes --------------------------------------------------------

  /// Turns the on-device overlay / diagnostics panel on or off.
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  /// Arms / disarms FORCE_STREAMING_TEST. The acceptance start button turns
  /// this on; ending the run turns it off. See [_forceTest].
  void setForceStreamingTest(bool value) {
    if (_forceTest == value) return;
    _forceTest = value;
    notifyListeners();
  }

  /// Records the preference layer (see [AppPreferences.streamingPlayback]).
  void setStreamingPreference(bool value) {
    if (_preferenceStreaming == value) return;
    _preferenceStreaming = value;
    notifyListeners();
  }

  /// Writes the streaming decision trace. Fields are merged: the resolver
  /// fills preference/force first, then candidate, then the final decision.
  ///
  /// [decision] is one of `STREAM` / `LOCAL_FILE` / `FALLBACK`; [reason] is a
  /// stable token (never prose) so a device report can be matched to the
  /// branch that produced it without guessing.
  void noteDecision({
    bool? preference,
    bool? force,
    bool? candidate,
    String? candidateReason,
    bool? proxyAvailable,
    bool? fileComplete,
    String? decision,
    String? reason,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    if (preference != null) _decisionPreference = preference;
    if (force != null) _decisionForce = force;
    if (candidate != null) _decisionCandidate = candidate;
    if (candidateReason != null) _decisionCandidateReason = candidateReason;
    if (proxyAvailable != null) _decisionProxyAvailable = proxyAvailable;
    if (fileComplete != null) _decisionFileComplete = fileComplete;
    if (decision != null) _decision = decision;
    if (reason != null) _decisionReason = reason;
    notifyListeners();
  }

  String? get decision => _decision;
  String? get decisionReason => _decisionReason;

  /// The decided transport, with the facts behind it.
  ///
  /// Every field here is copied from [playback_decision.SourceFacts], whose
  /// `diskSize` came from a `stat` — the difference between "TDLib says 100%"
  /// and "the bytes are actually there" is the whole point of the line.
  void noteSourceDecision(PlaybackDecision decision, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _playbackDecision = decision.code;
    _playbackDecisionReason = decision.reason;
    _decisionLocalSize = decision.facts.diskSize;
    _decisionExpectedSize = decision.facts.expectedBytes;
    _decisionDiskCovers = decision.facts.diskCoversExpected;
    _decisionRedownload = decision.needsRedownload;
    // The decision already measured the file; the panel uses that measurement
    // instead of leaving `disk` at "unknown" until a completion claim arrives.
    if (decision.facts.diskSize >= 0) _diskBytes = decision.facts.diskSize;
    _note('playbackDecision=${decision.code} reason=${decision.reason} '
        'disk=${decision.facts.diskSize} expected=${decision.facts.expectedBytes}');
    notifyListeners();
  }

  /// The transport was actually tried, and whether it failed. Counted
  /// separately from the decision: "decided V2" and "V2 ran" are different
  /// statements, and the report has to be able to tell them apart.
  void noteTransportAttempt(String transport, {required bool failed}) {
    if (_sealedResult) return;
    switch (transport) {
      case 'RESOURCE_LOADER':
        _v2Attempted = true;
        if (failed) _v2Failed = true;
      case 'HTTP_PROXY':
        _v1Attempted = true;
        if (failed) _v1Failed = true;
    }
  }

  /// Records that a transport is being *entered*, before anything can fail.
  ///
  /// [noteTransportAttempt] only fires on the failure path, so a run where V2
  /// was tried and threw before the player existed reported
  /// `v2Attempted=false` — the report then claimed V2 was never used while the
  /// device log showed a `tgmedia://` session. An attempt is a fact at entry,
  /// not at exit.
  void noteTransportStart(String transport) {
    if (_sealedResult) return;
    switch (transport) {
      case 'RESOURCE_LOADER':
        _v2Attempted = true;
      case 'HTTP_PROXY':
        _v1Attempted = true;
    }
    _note('transportStart=$transport');
    notifyListeners();
  }

  /// Closes the whole-file door for the rest of this play.
  ///
  /// Called the moment a streaming transport is entered. From then on a
  /// `downloadFile(limit: 0)` is refused at the api and recorded as
  /// [blockedWholeFileCount] — including one attempted by a future code path
  /// that has not been written yet.
  void forbidWholeFile(String why) {
    downloadAudit.forbidWholeFile(why);
    _note('forbidWholeFile=$why');
  }

  /// How many whole-file requests were refused during this play.
  int get blockedWholeFileCount => downloadAudit.blockedWholeFileCount;

  bool get wholeFileAllowed => downloadAudit.wholeFileAllowed;

  /// Opens the whole-file door. Called once per play by the controller — a
  /// retry of the same play must not reopen it.
  void allowWholeFile() {
    downloadAudit.allowWholeFile();
  }

  /// Which id the user tapped, which id the record carried, which id the
  /// resolver used, and which id TDLib answered for.
  ///
  /// The device report that prompted this printed `record file=4999` and
  /// `no_file_record` in the same block, then downloaded `file=2221`. Without
  /// these four numbers side by side, "the record exists" and "the record was
  /// not found" are both true statements about different ids.
  void noteFileIdResolve({
    required int clickedFileId,
    required int recordFileId,
    required int resolvedFileId,
    required int tdlibFileId,
    int? messageId,
    int? generation,
    String? fileUniqueId,
  }) {
    _resolveClickedId = clickedFileId;
    _resolveRecordId = recordFileId;
    _resolveResolvedId = resolvedFileId;
    _resolveTdlibId = tdlibFileId;
    _resolveMessageId = messageId;
    _resolveGeneration = generation;
    _resolveUniqueId = fileUniqueId;
    _note('fileIdResolve clicked=$clickedFileId record=$recordFileId '
        'resolved=$resolvedFileId tdlib=$tdlibFileId');
  }

  /// The resolver swapped one file id for another. Always printed: a play that
  /// downloads a different file than the one tapped has to say so.
  void noteFileIdRemap({
    required int oldId,
    required int newId,
    required String reason,
  }) {
    _remaps.add('old=$oldId new=$newId reason=$reason');
    _note('fileIdRemap old=$oldId new=$newId reason=$reason');
    notifyListeners();
  }

  List<String> get fileIdRemaps => List<String>.unmodifiable(_remaps);

  /// What the player finally opened.
  void noteFinalSource(String source) {
    if (_sealedResult) return;
    _finalSource = source;
    _note('finalSource=$source');
  }

  /// The file ids the preload window is warming, for the isolation check.
  void notePreloadWindow(Iterable<int> fileIds) {
    if (_sealedResult) return;
    _preloadFileIds = List<int>.unmodifiable(fileIds);
  }

  String? get playbackDecision => _playbackDecision;
  String? get playbackDecisionReason => _playbackDecisionReason;
  int? get decisionLocalSize => _decisionLocalSize;
  int? get decisionExpectedSize => _decisionExpectedSize;
  bool? get decisionDiskCovers => _decisionDiskCovers;
  bool get decisionNeedsRedownload => _decisionRedownload;
  List<int> get preloadFileIds => _preloadFileIds;
  bool get v2Attempted => _v2Attempted;
  bool get v2Failed => _v2Failed;
  bool get v1Attempted => _v1Attempted;
  bool get v1Failed => _v1Failed;
  String? get finalSource => _finalSource;

  /// Records what the player is about to open — called from the feed
  /// controller immediately before `player.activate`, with the same source.
  ///
  /// `STREAM_HTTP` carries the loopback URL so the report can show the exact
  /// address AVPlayer streamed from; `LOCAL_FILE` is a full-download play and
  /// forces the verdict off `STREAMING_CONFIRMED`.
  void notePlayerSource({
    required bool isStreaming,
    required String url,
    int? generation,
    String? sourceLabel,
  }) {
    if (_sealedResult || _stale(generation)) return;
    if (sourceLabel != null) {
      // A V2 play names its own transport (`RESOURCE_LOADER`); the two
      // booleans above can only say "some kind of stream", which is no longer
      // enough to tell which transport served the bytes.
      _playerSourceType = sourceLabel;
      _proxyUrl = sourceLabel == 'RESOURCE_LOADER' ? url : null;
    } else {
      _playerSourceType = isStreaming ? 'STREAM_HTTP' : 'LOCAL_FILE';
      _proxyUrl = isStreaming ? url : null;
    }
    _note('playerSource=$_playerSourceType');
    notifyListeners();
  }

  /// Streaming V2: the resource loader exists for this play.
  void noteResourceLoaderSession({int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _rlSessions++;
    _note('RL session #$_rlSessions');
    notifyListeners();
  }

  /// Streaming V2: the content information block AVFoundation was given.
  void noteResourceLoaderContentInfo({
    required int total,
    required String contentType,
    required bool byteRangeAccessSupported,
    required bool entireLengthOnDemand,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    _rlContentInfo = 'total=$total type=$contentType '
        'byteRange=$byteRangeAccessSupported onDemand=$entireLengthOnDemand';
    _note('RL contentInfo $_rlContentInfo');
    notifyListeners();
  }

  /// Streaming V2: one `AVAssetResourceLoadingDataRequest`.
  ///
  /// The counters below are fed from [noteResourceLoaderEvent] — the event
  /// stream the native loader and the Dart supply both write to. There used to
  /// be a second pair of methods (`noteResourceLoaderRequest` /
  /// `noteResourceLoaderRespond`) that no production path ever called, so
  /// `_rlRequests` stayed 0 through a 275-respond play and the verdict read
  /// STREAMING_NOT_STARTED over a playing video. One source of truth now.
  void _countV2Event(String name, Map<String, Object?> fields) {
    switch (name) {
      case 'dataRequestCreated':
        // Two producers write this name: Swift once per AVPlayer loading
        // request, Dart once per chunk it serves. The pair
        // `(requestId, offset)` identifies one read, so both land once.
        final requestId = _fieldInt(fields['requestId']) ?? -1;
        final offset = _fieldInt(fields['requestedOffset']) ??
            _fieldInt(fields['offset']) ??
            -1;
        final key = '$requestId|$offset';
        if (_v2RequestKeys.add(key)) {
          if (_v2RequestKeys.length > maxV2RequestKeys) {
            _v2RequestKeys.remove(_v2RequestKeys.first);
          }
          _rlRequests++;
        }
        _v2StartedMillis ??= _elapsed();
      case 'respond':
        _rlResponds++;
        final bytes = _fieldInt(fields['respondBytes']) ??
            _fieldInt(fields['bytes']) ??
            0;
        if (bytes > 0) _rlBytes += bytes;
      case 'supplyError':
      case 'waitTimeout':
        _rlStalls++;
    }
  }

  /// Streaming V2: a data request gave up, with the reason the supply gave.
  void noteResourceLoaderStall(String reason, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _rlStalls++;
    _note('RL stall #$_rlStalls $reason');
    notifyListeners();
  }

  /// The first failed read, kept once and kept raw.
  ///
  /// This is the line that answers "读取失败发生在哪一环": a `supplyError` means
  /// the loader could not produce the bytes the player asked for, while a
  /// `playerFailed` means the bytes were there and AVFoundation refused them.
  /// The error page shows one string for both, so without this the two are
  /// indistinguishable after the fact.
  void noteReadError({
    required String source,
    String? code,
    String? message,
    int? offset,
    int? requestId,
    int? served,
    int? generation,
  }) {
    if (_firstReadError != null) return;
    if (_stale(generation)) return;
    _firstReadError = <String, Object?>{
      'source': source,
      'code': code,
      'message': message,
      'offset': offset,
      'requestId': requestId,
      'served': served,
      'atMillis': _elapsed(),
    };
    _note('FIRST READ ERROR $source code=${code ?? '-'} '
        'offset=${offset ?? '-'} msg=${_sanitize(message ?? '')}');
    notifyListeners();
  }

  /// A V2-only play stopped instead of falling back.
  ///
  /// Recorded because the *absence* of V1 and of a whole-file request is the
  /// acceptance criterion now: a report has to be able to show that the play
  /// ended deliberately, not that it silently turned into something else.
  void noteV2OnlyStop(String reason, {int? generation}) {
    if (_stale(generation)) return;
    _v2StopReason = _sanitize(reason);
    _note('V2_ONLY stop: $_v2StopReason');
    notifyListeners();
  }

  /// Streaming V2 free-form event (session open/close, steering, off-by-default
  /// platform refusal). Kept as text because it is read by a human on a device.
  void noteResourceLoader(String text, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _note('RL $text');
  }

  /// Streaming V2 event log.
  ///
  /// One entry per thing that actually happened — a content information
  /// request, a data request, a respond, a window move, a finished request, a
  /// player item becoming ready. Free-text `_note` lines cannot answer "how
  /// many responds did request 3 get", and the acceptance questions are
  /// exactly that specific.
  ///
  /// Every entry carries the identity it belongs to, so a request left over
  /// from the previous video is visible as a different `fileId`/generation
  /// instead of being mixed into the current play's numbers.
  final List<ResourceLoaderEvent> _rlLog = <ResourceLoaderEvent>[];

  /// Bounded: an idle player polls, and a 4 GB film would otherwise grow this
  /// list for the whole session.
  static const int maxResourceLoaderEvents = 400;

  List<ResourceLoaderEvent> get resourceLoaderLog =>
      List<ResourceLoaderEvent>.unmodifiable(_rlLog);

  void noteResourceLoaderEvent(
    String name, {
    Map<String, Object?> fields = const <String, Object?>{},
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    _countV2Event(name, fields);
    if (_rlLog.length >= maxResourceLoaderEvents) _rlLog.removeAt(0);
    _rlLog.add(ResourceLoaderEvent(
      name: name,
      fields: fields,
      chatId: _chatId,
      messageId: _messageId,
      fileId: _fileId,
      generation: generation ?? _generation,
      elapsedMillis: _elapsed(),
    ));
    // The two events that mean "a read did not finish" are captured here, at
    // the moment they arrive. Later events keep overwriting the log; the first
    // failure is the one that explains the play.
    if (name == 'supplyError' || name == 'playerFailed') {
      noteReadError(
        source: name,
        code: fields['code'] as String?,
        message: (fields['message'] as String?) ??
            (fields['error'] as String?) ??
            (fields['reason'] as String?),
        offset: _fieldInt(fields['offset']) ?? _fieldInt(fields['requestedOffset']),
        requestId: _fieldInt(fields['requestId']),
        served: _fieldInt(fields['served']),
        generation: generation,
      );
    }
    _note('RL $name ${fields.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
    notifyListeners();
  }

  static int? _fieldInt(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  /// The tapped list item, as the local index has it.
  ///
  /// Written by the feed controller before it resolves a play. It survives
  /// [beginPlay] on purpose: the record describes what the user chose, the
  /// play block describes what TDLib serves, and the whole point is to see
  /// the two side by side.
  void noteRecordSnapshot({
    required int fileId,
    required int messageId,
    required int sizeBytes,
  }) {
    if (_recordFileId != fileId) _remaps.clear();
    _recordFileId = fileId;
    _recordMessageId = messageId;
    _recordSizeBytes = sizeBytes;
    notifyListeners();
  }

  /// One stage of the play pipeline, tagged with the ids it belongs to.
  ///
  /// The six stages a device report needs — CLICKED / ACTIVE / RESOLVE /
  /// PROXY / PLAYER / PRELOAD — all write the same three ids, so a run can
  /// prove `clickedFileId == activeFileId == playerFileId` instead of
  /// assuming it. A mismatch is a defect, not a display quirk.
  void noteStage(
    String stage, {
    int? chatId,
    int? messageId,
    int? fileId,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    if (stage == 'CLICKED') {
      _clickedFileId = fileId;
      _clickedChatId = chatId;
      _clickedMessageId = messageId;
    } else if (stage == 'ACTIVE') {
      _activeFileId = fileId;
      _activeChatId = chatId;
      _activeMessageId = messageId;
    } else if (stage == 'PLAYER') {
      _playerFileId = fileId;
    }
    _note('$stage chat=${chatId ?? '-'} msg=${messageId ?? '-'} '
        'file=${fileId ?? '-'}');
  }

  /// The full HTTP exchange, as the proxy really wrote it.
  ///
  /// Counters stay with [noteRangeRequest] / [noteResponse] — this one keeps
  /// the per-request detail the acceptance asks for: what was asked, what was
  /// declared, how many bytes actually went into the socket.
  void noteExchange(ProxyExchange exchange, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _exchanges.add(exchange);
    if (_exchanges.length > _maxExchanges) _exchanges.removeAt(0);
    if (exchange.truncated) _truncatedCount++;
    if (!exchange.bodyComplete) _incompleteCount++;
    if (!exchange.lengthMatchesRequest) _headerMismatchCount++;
    if (exchange.isForwardRange) _forwardRangeRequests++;
    _note('http ${exchange.describe()}');
    notifyListeners();
  }

  /// Where `moov` sits, scanned from the bytes on disk by the resolver.
  void noteMoov(MoovPosition position, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    if (_moov == position) return;
    _moov = position;
    _note('moov=${position.name}');
    notifyListeners();
  }

  /// Same verdict, plus the box offsets when the layout allowed computing them.
  ///
  /// A tail-moov report has to name *where* the tail starts: "moov=afterMdat"
  /// alone cannot be told apart from "the player is waiting for a box 638 MB
  /// away", and that distance is the whole diagnosis.
  void noteMoovScan(MoovScan scan, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _moov = scan.position;
    _moovStart = scan.start;
    _moovEnd = scan.end;
    _note('moov=${scan.position.name} at=${scan.start}..${scan.end} '
        'len=${scan.length}');
    notifyListeners();
  }

  /// Records why the play failed. Called once, from the failure path, so the
  /// panel and the exported report name the same reason the user was shown.
  void noteFailure(PlaybackFailure kind, {String? message, int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _failureKind = kind;
    _failureMessage = message;
    _note('failure=${kind.code}${message == null ? '' : ': $message'}');
    notifyListeners();
  }

  /// The player object was constructed for this play.
  void notePlayerCreated({int? generation}) {    if (_sealedResult || _stale(generation)) return;
    _playerCreatedMillis ??= _elapsed();
    _note('player created');
    notifyListeners();
  }

  /// `initialize()` returned: AVPlayerItem reached readyToPlay.
  void notePlayerReady({int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _playerReadyMillis ??= _elapsed();
    _note('player ready');
    notifyListeners();
  }

  /// `initialize()` failed or timed out. [reason] is the player's own message.
  void notePlayerFailed(String reason, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _playerFailedMillis ??= _elapsed();
    _playerFailedText ??= _sanitize(reason);
    _note('player failed: $_playerFailedText');
    notifyListeners();
  }

  /// Clears the previous run and starts recording a new one.
  ///
  /// [streaming] is the resolver's decision, recorded as such — it is *not*
  /// treated as proof (see [verdict]).
  int beginPlay({
    required int fileId,
    required bool streaming,
    int? chatId,
    int? messageId,
    int? totalBytes,
  }) {
    // A settled acceptance result is frozen: browsing afterwards must not
    // replace the verdict the run produced (this was the "ghost panel" hole
    // in reverse — a later LOCAL_FILE play overwriting a real run).
    if (_sealedResult) return _generation;
    // New play, new generation: every callback from the previous one is now
    // stale by construction, whatever it was still holding.
    _generation++;
    _forceTestAtPlay = _forceTest;
    _streamingEnabled = streaming;
    _fileId = fileId;
    _chatId = chatId;
    _messageId = messageId;
    _totalBytes = totalBytes ?? 0;
    _downloadedBytes = 0;
    // Measured length and the refused claim belong to the video that was
    // played: a swipe must never inherit the previous file's evidence.
    _diskBytes = -1;
    _completionRefusal = null;
    _headBytes = 0;
    _downloadOffset = 0;
    _windowStart = 0;
    _windowEnd = 0;
    _isDownloading = false;
    _isDownloadingCompleted = false;
    _rangeRequests = 0;
    _lastRange = null;
    _lastStatus = null;
    _partialContentCount = 0;
    _windowMoves = 0;
    _stalls = 0;
    _lastStallReason = null;
    _playerTime = Duration.zero;
    _playerDuration = Duration.zero;
    _timeControlStatus = 'unknown';
    _hasStartedPlaying = false;
    _playerError = null;
    _playerSourceType = null;
    _proxyUrl = null;
    _firstRangeMillis = null;
    _proxyStartedMillis = null;
    _v2StartedMillis = null;
    _fallback = false;
    _fallbackReason = null;
    _firstPlaybackDownloadedBytes = null;
    _firstPlaybackTotalBytes = null;
    _firstPlaybackCompleted = false;
    _firstPlaybackMillis = null;
    _downloadCompletedMillis = null;
    _firstBytesMillis = null;
    _first206Millis = null;
    _exchanges.clear();
    _truncatedCount = 0;
    _incompleteCount = 0;
    _headerMismatchCount = 0;
    _forwardRangeRequests = 0;
    _rlSessions = 0;
    _rlRequests = 0;
    _rlResponds = 0;
    _rlBytes = 0;
    _rlStalls = 0;
    _rlContentInfo = null;
    _v2RequestKeys.clear();
    _rlLog.clear();
    // Per play: the first failed read and the reason a V2-only play stopped
    // belong to the video the user tapped, not to the session.
    _firstReadError = null;
    _v2StopReason = null;
    _moov = MoovPosition.unknown;
    _moovStart = -1;
    _moovEnd = -1;
    _playerCreatedMillis = null;
    _playerReadyMillis = null;
    _playerFailedMillis = null;
    _playerFailedText = null;
    _failureKind = null;
    _failureMessage = null;
    _decisionPreference = null;
    _decisionForce = null;
    _decisionCandidate = null;
    _decisionCandidateReason = null;
    _decisionProxyAvailable = null;
    _decisionFileComplete = null;
    _decision = null;
    _decisionReason = null;
    _playbackDecision = null;
    _playbackDecisionReason = null;
    _decisionLocalSize = null;
    _decisionExpectedSize = null;
    _decisionDiskCovers = null;
    _decisionRedownload = false;
    _preloadFileIds = const <int>[];
    _v2Attempted = false;
    _v2Failed = false;
    _v1Attempted = false;
    _v1Failed = false;
    _finalSource = null;
    _resolveClickedId = null;
    _resolveRecordId = null;
    _resolveResolvedId = null;
    _resolveTdlibId = null;
    _resolveMessageId = null;
    _resolveGeneration = null;
    _resolveUniqueId = null;
    // `_remaps` is deliberately *not* cleared here: `beginPlay` runs again on
    // every `_streamOnce` retry, and a retry is exactly when a remap happens
    // (4999 → 2221). It is cleared per navigation, in [noteRecordSnapshot].
    // The download audit belongs to the play, not to the process: a report has
    // to answer "which requests did *this* play send", not "which requests has
    // the app ever sent".
    downloadAudit
      ..reset()
      ..tag(chatId: chatId ?? 0, messageId: messageId ?? 0, generation: _generation);
    _startedAt = _clock();
    _growth.clear();
    _events.clear();
    notifyListeners();
    return _generation;
  }

  /// Arms a fresh acceptance run: clears every piece of evidence so the next
  /// play — and only the next play — decides the verdict.
  ///
  /// Deliberately does not fake a video, a transfer or a player event. If the
  /// next play is served from a complete cache, the honest answer is
  /// [StreamingVerdict.fullDownloadBeforePlayback].
  void startAcceptance() {
    // Unseal first: a previous run's frozen evidence must be wiped here,
    // exactly once per accepted start.
    _sealedResult = false;
    beginPlay(fileId: 0, streaming: false);
    _acceptanceRunning = true;
    notifyListeners();
  }

  /// Ends the armed run; the recorded evidence stays on screen — and stays
  /// sealed until the next [startAcceptance], no matter how many ordinary
  /// plays happen in between.
  void stopAcceptance() {
    _acceptanceRunning = false;
    _sealedResult = true;
    notifyListeners();
  }

  /// The resolver picked the streaming branch. **Recorded, not trusted**: it
  /// only says which path was taken. [verdict] still waits for the data.
  void noteStreamingSelected({int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _streamingEnabled = true;
    notifyListeners();
  }

  /// The range proxy bound its port and the player URL exists. `url` is the
  /// exact `http://127.0.0.1:port/<token>` the player will be handed.
  void noteProxyStarted(String url, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _proxyStartedMillis ??= _elapsed();
    _proxyUrl = url;
    _note('proxy started');
    notifyListeners();
  }

  /// TDLib said bytes exist. Straight from `updateFile` / `updateFileProgress`.
  ///
  /// `completed` is recorded as a transfer state, never as a byte count and
  /// never as "100%": the flag can be raised for a file whose bytes are short,
  /// and rendering it turned a claim into a progress bar. Only
  /// [noteCompleted] — which requires a measured length — can declare the file
  /// whole.
  void updateTransfer({
    required int downloadedBytes,
    required int totalBytes,
    required int downloadOffset,
    required bool completed,
    bool isDownloading = true,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    if (downloadedBytes > _downloadedBytes ||
        downloadOffset != _downloadOffset) {
      _lastGrowthAt = DateTime.now().millisecondsSinceEpoch;
    }
    _downloadedBytes = downloadedBytes;
    if (totalBytes > 0) _totalBytes = totalBytes;
    _downloadOffset = downloadOffset;
    if (!completed) _isDownloadingCompleted = false;
    _isDownloading = isDownloading && !completed;
    if (downloadOffset == 0) {
      _headBytes = downloadedBytes;
    } else if (completed) {
      _headBytes = _totalBytes;
    }
    _windowStart = downloadOffset;
    _windowEnd = downloadOffset + downloadedBytes;
    if (_firstBytesMillis == null && downloadedBytes > 0) {
      _firstBytesMillis = _elapsed();
    }
    _sampleGrowth();
    notifyListeners();
  }

  /// Same as [updateTransfer], straight from a parsed [FileState] — the shape
  /// `updateFile` already gives, so the caller cannot misread the window.
  void updateTransferFromState(FileState state, {int? generation}) {
    updateTransfer(
      downloadedBytes: state.downloadedSize,
      totalBytes: state.expectedSize,
      downloadOffset: state.downloadOffset,
      completed: state.isCompleted,
      generation: generation,
    );
  }

  /// The player asked for a byte range. Straight from the proxy's request.
  void noteRangeRequest({required int from, int? to, int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _rangeRequests++;
    _firstRangeMillis ??= _elapsed();
    _lastRange = '$from-${to ?? 'end'}';
    // One line per request, in the shape the acceptance report asks for:
    // `Range #1 bytes=0-2097151`.
    _note('Range #$_rangeRequests bytes=$from-${to ?? 'end'}');
    notifyListeners();
  }

  /// The proxy answered. [status] is the real HTTP status it wrote.
  void noteResponse({
    required int status,
    required int from,
    required int end,
    required int total,
    required int length,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    _lastStatus = status;
    if (status == 206) {
      _partialContentCount++;
      _first206Millis ??= _elapsed();
    }
    if (total > 0) _totalBytes = total;
    _note('HTTP $status $from-$end/$total ${length}B');
  }

  /// The proxy moved the TDLib download window to serve a distant range.
  void noteWindowMove(int start, int end, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _windowMoves++;
    _windowStart = start;
    _windowEnd = end;
    _note('window→$start-$end');
  }

  /// No TDLib progress for a whole quiet window: a real stall, not slowness.
  void noteStall(String reason, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _stalls++;
    _lastStallReason = reason;
    _note('stall $reason');
  }

  /// Streaming gave up and the full download took over.
  ///
  /// The reason is redacted here: it can carry a TDLib message with a container
  /// path, and this text is what reaches the diagnostics export.
  void noteFallback(String reason, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    _fallback = true;
    _fallbackReason = redactText(reason);
    _streamingEnabled = false;
    _note('fallback ${_fallbackReason!}');
  }

  /// TDLib reported the whole file on disk.
  ///
  /// This used to be `_downloadedBytes = _totalBytes` — the flag copied into a
  /// byte count. On device that printed `1.19 GB / 1.19 GB · 100%` seconds
  /// after the tap on a file that had barely started, because a claim was
  /// being rendered as a measurement.
  ///
  /// [diskBytes] is the real length behind the path. Completion is declared
  /// only when it reaches [totalBytes]; otherwise the claim is recorded as
  /// refused and the progress numbers stay where the transfer actually is.
  void noteCompleted({
    int? totalBytes,
    int? diskBytes,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    if (totalBytes != null && totalBytes > 0) _totalBytes = totalBytes;
    final measured = diskBytes ?? _diskBytes;
    if (measured >= 0) _diskBytes = measured;
    final confirmed = _totalBytes > 0 && measured >= _totalBytes;
    if (!confirmed) {
      _completionRefusal = 'claimed_complete disk=$measured total=$_totalBytes';
      _isDownloading = true;
      _note('completion refused: $_completionRefusal');
      notifyListeners();
      return;
    }
    if (!_isDownloadingCompleted) {
      _isDownloadingCompleted = true;
      _downloadCompletedMillis = _elapsed();
    }
    _isDownloading = false;
    _completionRefusal = null;
    _headBytes = _totalBytes;
    // The one place `downloadedBytes` may be raised to the total: a length
    // that reaches it is the only evidence that the whole file is there.
    _downloadedBytes = _totalBytes;
    notifyListeners();
  }

  /// A measured length behind the path, with no completion claim attached.
  ///
  /// Called from the source decision, which already stats the file: the panel
  /// then shows what is on disk before the transfer finishes, instead of
  /// waiting for a `completed` flag that may arrive as a lie or not at all.
  void noteDiskMeasured(int bytes, {int? generation}) {
    if (_sealedResult || _stale(generation)) return;
    if (bytes < 0) return;
    _diskBytes = bytes;
    notifyListeners();
  }

  /// The player's own value: playhead, status, decoder error.
  ///
  /// Called from the player's listener, so every field is what AVPlayer
  /// reported — including [StreamingVerdict] inputs `isPlaying`,
  /// `isBuffering` and `position`.
  void updatePlayer({
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required bool isBuffering,
    String? error,
    int? generation,
  }) {
    if (_sealedResult || _stale(generation)) return;
    _playerTime = position;
    _playerDuration = duration;
    _playerError = error;
    // `video_player` does not surface AVPlayer's raw `timeControlStatus`
    // enum; this is the plugin's own view of the same state, named after
    // the values AVPlayer uses so a device log reads the same.
    _timeControlStatus = isPlaying
        ? 'playing'
        : (isBuffering ? 'waitingToPlayAtSpecifiedRate' : 'paused');
    // "Started playing" is the player moving under its own power, not the
    // source being a stream URL.
    if (isPlaying && position > Duration.zero) {
      _markFirstPlayback();
    }
    notifyListeners();
  }

  /// Snapshots the bytes at the first confirmed playhead movement.
  ///
  /// Returns true once, the first time the evidence is taken.
  bool recordFirstPlayback() => _markFirstPlayback();

  bool _markFirstPlayback() {
    if (_sealedResult) return false;
    if (_firstPlaybackDownloadedBytes != null) return false;
    _hasStartedPlaying = true;
    _firstPlaybackDownloadedBytes = _downloadedBytes;
    _firstPlaybackTotalBytes = _totalBytes;
    _firstPlaybackCompleted = _isDownloadingCompleted;
    _firstPlaybackMillis = _elapsed();
    return true;
  }

  /// The play ended; keeps the evidence on screen until the next one.
  void endPlay() {
    _isDownloading = false;
    notifyListeners();
  }

  int _elapsed() {
    final start = _startedAt;
    if (start == null) return 0;
    return _clock().difference(start).inMilliseconds;
  }

  /// Keeps at most 40 samples, one per distinct byte count: enough to show a
  /// curve, small enough to stay out of the way.
  void _sampleGrowth() {
    if (_growth.isNotEmpty && _growth.last.bytes == _downloadedBytes) return;
    if (_growth.length >= 40) return;
    _growth.add(StreamingGrowthSample(_elapsed(), _downloadedBytes));
  }

  void _note(String text) {
    if (_events.length >= 24) _events.removeAt(0);
    _events.add(text);
    notifyListeners();
  }

  /// True when [generation] belongs to a play that is no longer the current
  /// one. `null` means an unguarded caller (the feed controller, which has
  /// its own generation gate) and is accepted.
  bool _stale(int? generation) =>
      generation != null && generation != _generation;

  /// Lines for the settings diagnostics section. Raw counts, no decoration.
  List<String> panelLines() => <String>[
        // The three lines that make "the test mode was actually on"
        // verifiable on the screen itself — the gap that let a full download
        // run pass itself off as a streaming run before.
        // ON if the mode is live now (armed, waiting for the play) or if it
        // was on when the recorded play started; "(ended)" marks the latter.
        'STREAMING TEST: ${(_forceTest || _forceTestAtPlay) ? 'ON' : 'OFF'}'
        '${(!_forceTest && _forceTestAtPlay) ? ' (ended)' : ''}',
        'PREFERENCE STREAMING: ${userStreamingPreference ? 'ON' : 'OFF'}',
        'EFFECTIVE STREAMING: ${_streamingEnabled ? 'ON' : 'OFF'}',
        'playerSourceType=${_playerSourceType ?? '-'}',
        // The decision itself, with the reason that produced it: this is the
        // line that answers "why did effective streaming end up OFF?".
        'decision=${_decision ?? '-'} reason=${_decisionReason ?? '-'}',
        // The measured decision: transport, why, and the two sizes that
        // decided it. `disk` is a stat, `expected` is TDLib's claim.
        'playbackDecision=${_playbackDecision ?? '-'} '
            'reason=${_playbackDecisionReason ?? '-'}',
        'localFile=${_decisionDiskCovers == null ? '-' : (_decisionDiskCovers! ? 'covers' : 'SHORT')} '
            'disk=${_decisionLocalSize ?? '-'} expected=${_decisionExpectedSize ?? '-'} '
            'redownload=${_decisionRedownload ? 'yes' : 'no'}',
        'candidate=${_decisionCandidate ?? '-'} '
            'complete=${_decisionFileComplete ?? '-'} '
            'proxyAvailable=${_decisionProxyAvailable ?? '-'}'
        '${_decisionCandidateReason == null ? '' : ' candidateReason=$_decisionCandidateReason'}',
        if (_proxyUrl != null) 'proxyUrl=${redactText(_proxyUrl!)}',
        'streamingEnabled=${_streamingEnabled ? 'true' : 'false'}',
        'file=${_fileId ?? '-'} msg=${_messageId ?? '-'} chat=${_chatId ?? '-'}',
        // Two sizes, always both: the tile's size and the size of the file
        // TDLib is actually serving. `match=NO` means the play opened a
        // different file than the tile advertised.
        'record file=${_recordFileId ?? '-'} msg=${_recordMessageId ?? '-'} '
            'size=$_recordSizeBytes B',
        'tdlib total=$_totalBytes B ${_sizeMatchLabel()}',
        'identity clicked=${_clickedFileId ?? '-'} '
            'active=${_activeFileId ?? '-'} '
            'player=${_playerFileId ?? '-'} '
            '${identityOk ? 'OK' : 'BUG'}',
        'total=$_totalBytes B downloaded=$_downloadedBytes B '
            '(${_percentString()})',
        // Two different questions, two different numbers: TDLib's count of what
        // it wrote, and the length actually behind the path.
        'disk=$_diskBytes B ${diskCoversTotal ? 'FULL' : 'PARTIAL'}'
            '${_completionRefusal == null ? '' : ' refused="$_completionRefusal"'}',
        'head=$_headBytes B downloadOffset=$_downloadOffset',
        'window=$_windowStart-$_windowEnd moves=$_windowMoves',
        // Who asked TDLib for bytes, and which request moved them. The header
        // line is the counter; the calls below it are the evidence.
        ...downloadAudit.summary(max: 4),
        // What the stall watchdog saw, in its own words. Without these lines a
        // report of a frozen play says "0.1 %" and nothing else; with them it
        // says whether TDLib was silent, for how long, and what was done.
        for (final note in downloadAudit.notes) 'event $note',
        // `completed` says whether the bytes are there; the evidence suffix
        // says which fact proved it. A file that was already whole when the
        // play started never produces a completion update, and the panel used
        // to print `disk=… FULL` / `100.0%` / `completed=false` together.
        'isDownloading=${_isDownloading ? 'true' : 'false'} '
            'completed=${transferCompleted ? 'true' : 'false'} '
            'evidence=$completionEvidence '
            'silent=${transferSilenceSeconds}s',
        'range=${_lastRange ?? '-'} requests=$_rangeRequests '
            'status=${_lastStatus ?? '-'} 206x$_partialContentCount',
        'range truncated=$_truncatedCount forward=$_forwardRangeRequests '
            'moov=${_moov.name}'
            '${_moovStart >= 0 ? ' moovAt=$_moovStart..$_moovEnd' : ''}',
        if (_playerSourceType == 'RESOURCE_LOADER' || _rlRequests > 0) ...[
          'v2 sessions=$_rlSessions req=$_rlRequests resp=$_rlResponds '
              'bytes=$_rlBytes stalls=$_rlStalls',
          // The window V2 is running on, and the three byte counts that used
          // to be reported as one number.
          _v2WindowLine(),
          _v2BytesLine(),
          'firstReadError=${firstReadError == null ? '-' : _firstReadErrorLine()}',
          // The last few V2 events, oldest first: the sequence that answers
          // "did it wait for growth or did it finish short".
          for (final event in _rlLog.reversed.take(6).toList().reversed)
            'rl ${event.name} ${event.fields.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
        ],
        // One line per exchange, newest last: what the player asked for, what
        // the proxy declared, and how many bytes really went out.
        for (final exchange in _exchanges.reversed.take(4))
          'http ${exchange.describe()}',
        'player=${_playerTime.inSeconds}s/${_playerDuration.inSeconds}s '
            'status=$_timeControlStatus started=${_hasStartedPlaying ? 'true' : 'false'}',
        if (_playerError != null) 'playerError=${_sanitize(_playerError!)}',
        if (_fallback) 'fallback=$_fallbackReason',
        'verdict=${verdict.code} stalls=$_stalls',
      ];

  /// A decoder error trimmed and redacted for the export: the text is what
  /// AVFoundation produced, so it can mention a container path.
  static String _sanitize(String text) {
    final clean = redactText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 160 ? clean : '${clean.substring(0, 160)}…';
  }

  /// The TDLib window the resource loader is currently on.
  String _v2WindowLine() {
    final call = downloadAudit.lastCallFor(DownloadCaller.resourceLoader);
    if (call == null) return 'V2_WINDOW offset=- limit=-';
    return 'V2_WINDOW offset=${call.offset} '
        'limit=${call.limit <= 0 ? 'WHOLE_FILE' : call.limit} '
        'grew=${call.grew} cause="${call.cause}"';
  }

  /// Three counts that must not be confused with each other:
  ///
  /// * `toPlayer` — bytes actually handed to `AVAssetResourceLoadingDataRequest`
  ///   (what played);
  /// * `dlGrew` — bytes TDLib wrote for windows V2 asked for (what downloaded);
  /// * `diskDownloaded` — the length measured behind the path (`-1` when no
  ///   stat has run). This is what "how much is really on disk" means, and it
  ///   is deliberately not `downloaded_size`: a pool file can be full length
  ///   with an unwritten middle, which is exactly how a 989 KB file was once
  ///   reported as complete.
  ///
  /// A play can have `toPlayer` > 0 with `dlGrew` well under the total, and a
  /// request can exist with all three at zero.
  String _v2BytesLine() {
    final grew = downloadAudit.grewBy(DownloadCaller.resourceLoader);
    return 'V2_BYTES dataRequests=$_rlRequests responds=$_rlResponds '
        'toPlayer=$_rlBytes dlGrew=$grew '
        'diskDownloaded=${_diskBytes < 0 ? '-' : _diskBytes}/$_totalBytes';
  }

  /// The first failed read, as one readable line.
  String _firstReadErrorLine() {
    final error = _firstReadError;
    if (error == null) return 'none';
    return 'source=${error['source']} code=${error['code'] ?? '-'} '
        'offset=${error['offset'] ?? '-'} '
        'requestId=${error['requestId'] ?? '-'} '
        'served=${error['served'] ?? '-'} '
        'msg="${_sanitize('${error['message'] ?? ''}')}"';
  }

  /// The one-screen acceptance result, in the shape the task asks for.
  ///
  /// ```
  /// STREAMING_CONFIRMED
  /// firstPlayback = 8.4s
  /// downloaded = 146 MB / 1.08 GB
  /// completion = 93.7s
  /// ```
  ///
  /// …or the honest alternative: `FULL_DOWNLOAD_BEFORE_PLAYBACK` when the
  /// player only started after the file was whole, `STREAMING_FALLBACK`
  /// when streaming was abandoned, `UNKNOWN` when the run never produced
  /// the data needed to tell.
  List<String> acceptanceLines() {
    final verdict = this.verdict;
    final lines = <String>[verdict.code];
    // A forced run made on a file that was already 100% on disk before the
    // play started cannot measure streaming at all: the resource loader served
    // it, the player played it, and neither fact says anything about
    // play-while-downloading. Reported as INVALID rather than FAILED — "the
    // pipeline broke" and "the test had nothing to prove" are different
    // sentences, and the device report's `fileComplete=true` /
    // `downloadedAtFirstPlayback=155 MB` is the second one.
    //
    // Gated on the resolver's own pre-play measurement (`fileComplete`), not on
    // "the total was reached before the first frame": a file that finishes
    // during the first two seconds of a real stream is a different case and
    // must keep the FAILED marker.
    final completeBeforePlay = _decisionFileComplete == true;
    if (_forceTestAtPlay &&
        completeBeforePlay &&
        verdict != StreamingVerdict.streamingActive) {
      lines.add('STREAMING_TEST_INVALID: file_complete_before_play');
    } else if (_forceTestAtPlay &&
        verdict == StreamingVerdict.fullDownloadBeforePlayback) {
      // Forced-test failure marker: the acceptance must not read a full
      // download as a pass, whatever else the run produced.
      lines.add('STREAMING_TEST_FAILED: '
          'FULL_DOWNLOAD_OCCURRED_BEFORE_PLAYBACK');
    }
    // Streaming never ran during a forced run is its own failure: the marker
    // names it so a report cannot be read as "we tried and it was slow".
    if (_forceTestAtPlay && verdict == StreamingVerdict.streamingNotStarted) {
      lines.add('STREAMING_TEST_FAILED: STREAMING_NOT_STARTED');
    }
    // The decision trace, always present: preference / force / candidate /
    // proxy / completion / the branch taken and why.
    lines.addAll(<String>[
      'StreamingDecision:',
      'preference=${_decisionPreference ?? userStreamingPreference}',
      'forceTest=${_decisionForce ?? _forceTestAtPlay}',
      'candidate=${_decisionCandidate ?? '-'}'
          '${_decisionCandidateReason == null ? '' : ' (${_decisionCandidateReason!})'}',
      'proxyAvailable=${_decisionProxyAvailable ?? '-'}',
      'fileComplete=${_decisionFileComplete ?? '-'}',
      'decision=${_decision ?? '-'}',
      'reason=${_decisionReason ?? '-'}',
    ]);
    // The measured half: which transport the facts picked, what the file
    // really measured, and which attempts actually ran. A report that says
    // "V1 proxy, 20 MB carried" has to be able to answer "why not LOCAL_FILE".
    lines.addAll(<String>[
      'playbackDecision=${_playbackDecision ?? '-'}',
      'playbackDecisionReason=${_playbackDecisionReason ?? '-'}',
      'finalSource=${_finalSource ?? _playerSourceType ?? '-'}',
      // `LOCAL_FILE` next to `localFileExists=false / localFileSize=-1` is a
      // contradiction, not a nuance: nothing was on disk, so nothing could
      // have been opened from disk. The device report had exactly that pair.
      if ((_finalSource ?? '') == 'LOCAL_FILE' &&
          ((_decisionLocalSize ?? -1) < 0 ||
              (_decisionExpectedSize ?? 0) <= 0 ||
              (_decisionLocalSize ?? 0) < (_decisionExpectedSize ?? 0)))
        'FINAL_SOURCE_INCONSISTENT: finalSource=LOCAL_FILE '
            'localFileSize=${_decisionLocalSize ?? -1} '
            'expectedFileSize=${_decisionExpectedSize ?? 0}',
      'localFileExists=${_decisionLocalSize == null ? '-' : (_decisionLocalSize! > 0 ? 'true' : 'false')}',
      'localFileSize=${_decisionLocalSize ?? '-'}',
      'expectedFileSize=${_decisionExpectedSize ?? '-'}',
      'diskCoversExpected=${_decisionDiskCovers ?? '-'}',
      'needsRedownload=${_decisionRedownload ? 'true' : 'false'}',
      'v2Attempted=${_v2Attempted ? 'true' : 'false'} '
          'v2Failed=${_v2Failed ? 'true' : 'false'}',
      'v1Attempted=${_v1Attempted ? 'true' : 'false'} '
          'v1Failed=${_v1Failed ? 'true' : 'false'}',
      'activeFileId=${_activeFileId ?? '-'}',
      'playerFileId=${_playerFileId ?? '-'}',
      'preloadFileIds=$_preloadFileIds',
    ]);
    // Every LOCAL_FILE has to name why it is not a stream — the one question
    // the device reports kept failing to answer.
    if (_decision == 'LOCAL_FILE') {
      lines.add('LOCAL_FILE_REASON=${_decisionReason ?? 'unknown'}');
    }
    if (_fallback && _fallbackReason != null) {
      lines.add('fallbackReason=$_fallbackReason');
    }
    final playback = _firstPlaybackMillis;
    lines.add(playback == null
        ? 'firstPlayback=-'
        : 'firstPlayback=${_seconds(playback)}');
    final downloaded = _firstPlaybackDownloadedBytes;
    final total = _firstPlaybackTotalBytes;
    lines.add(downloaded == null || total == null || total <= 0
        ? 'downloadedAtFirstPlayback=-'
        : 'downloadedAtFirstPlayback=${formatBytes(downloaded)}');
    lines.add(total == null || total <= 0
        ? 'total=-'
        : 'total=${formatBytes(total)}');
    lines.add(_recordSizeBytes <= 0
        ? 'recordSize=-'
        : 'recordSize=${formatBytes(_recordSizeBytes)} '
            'recordFile=${_recordFileId ?? '-'}');
    // The tile said one size, TDLib served another: the play opened a
    // different file than the one tapped. Nothing else in this report can be
    // read correctly until that is fixed, so it gets its own banner line.
    if (recordSizeMismatch) {
      lines.add('SIZE_MISMATCH: record=${formatBytes(_recordSizeBytes)} '
          'file=${_recordFileId ?? '-'} / tdlib=${formatBytes(_totalBytes)} '
          'file=${_fileId ?? '-'}');
    }
    final completed = _downloadCompletedMillis;
    // A file that was already whole when the play started produces no
    // completion update, so `-` would read as "never finished". It did finish
    // — before this play began, which is itself the reason the run cannot
    // measure streaming.
    final preexistingCompletion = completed == null &&
        (_decisionFileComplete == true ||
            ((_firstPlaybackTotalBytes ?? 0) > 0 &&
                (_firstPlaybackDownloadedBytes ?? 0) >=
                    (_firstPlaybackTotalBytes ?? 0)));
    lines.add(completed != null
        ? 'completedAt=${_seconds(completed)}'
        : (preexistingCompletion ? 'completedAt=before_play' : 'completedAt=-'));
    final first206 = _first206Millis;
    lines.add(first206 == null
        ? 'first206=-'
        : 'first206=${_seconds(first206)}');
    final firstRange = _firstRangeMillis;
    lines.add(firstRange == null
        ? 'firstRangeRequest=-'
        : 'firstRangeRequest=${_seconds(firstRange)}');
    final proxy = _proxyStartedMillis;
    lines.add(proxy == null
        ? 'proxyStarted=-'
        : 'proxyStarted=${_seconds(proxy)}');
    lines.add('effectiveStreaming=${_streamingEnabled ? 'true' : 'false'} '
        'playerSourceType=${_playerSourceType ?? '-'}');
    if (_proxyUrl != null) lines.add('proxyUrl=${redactText(_proxyUrl!)}');
    lines.add('206x$_partialContentCount rangeRequests=$_rangeRequests '
        'windowMoves=$_windowMoves stalls=$_stalls');
    // The HTTP evidence, one line per exchange. This is the part a device
    // report needs to answer "why did the player not start" without guessing:
    // the requested range, the range the proxy declared, and the bytes it
    // actually pushed.
    if (_exchanges.isNotEmpty) {
      lines.add('RangeExchanges:');
      for (final exchange in _exchanges) {
        lines.add('  ${exchange.describe()}');
      }
    }
    // Which transport served the bytes. V2 runs through
    // AVAssetResourceLoader on a `tgmedia://` URL and never opens a socket;
    // V1 runs over the loopback HTTP proxy. A report that cannot name the
    // transport cannot be read correctly.
    if (_playerSourceType == 'RESOURCE_LOADER') {
      lines.add('STREAMING V2');
      lines.add('source=AVASSET_RESOURCE_LOADER scheme=tgmedia');
      lines.add('resourceLoaderRequests=$_rlRequests '
          'responds=$_rlResponds respondBytes=$_rlBytes stalls=$_rlStalls');
      if (_rlContentInfo != null) lines.add('contentInfo=$_rlContentInfo');
    } else if (_playerSourceType == 'STREAM_HTTP') {
      lines.add('STREAMING V1');
      lines.add('source=STREAM_HTTP scheme=http');
    }
    lines.add('RANGE_TRUNCATED=$_truncatedCount');
    // The download audit: every `downloadFile` this play sent, the caller that
    // sent it, the window it asked for, and the bytes it moved. Without this
    // block "152 MB appeared" is an observation; with it, it is a named call.
    lines.add('DOWNLOAD_AUDIT calls=${downloadAudit.count} '
        'unbounded=${downloadAudit.unboundedCalls.length}');
    // The explicit "did anything ask for the whole file" answer. Kept separate
    // from the audit header because it is an acceptance criterion, not a
    // counter: `WHOLE_FILE_DOWNLOADS=0` with `bounded` growth is the pass.
    //
    // Split by caller, because under B+ the play's own download *is* one
    // whole-file request and it belongs to the Downloader. A single
    // `WHOLE_FILE_DOWNLOADS=1` line read like a breach on every normal play.
    lines.add('WHOLE_FILE_DOWNLOADS=${downloadAudit.unboundedCalls.length} '
        'byDownloader=${downloadAudit.unboundedCallsByDownloader.length} '
        'byOther=${downloadAudit.unboundedCallsByOther.length} '
        'wholeFileAllowed=${downloadAudit.wholeFileAllowed ? 'true' : 'false'}');
    if (downloadAudit.unboundedCallsByOther.isNotEmpty) {
      lines.add('WHOLE_FILE_BY_OTHER: '
          '${downloadAudit.unboundedCallsByOther.map((c) => '${c.caller.label} file=${c.fileId}').join(', ')}');
    }
    // V2-only: which window the resource loader ran on, what it moved, and the
    // first read that failed. `v1Attempted=false` above is the "V1 was not
    // called" half; these lines are the "what V2 actually did" half.
    lines.add(_v2WindowLine());
    lines.add(_v2BytesLine());
    lines.add('FIRST_READ_ERROR ${_firstReadErrorLine()}');
    lines.add('V2_ONLY_STOP=${_v2StopReason ?? '-'}');
    // The hard guard's own verdict. `AUTO_FULL_DOWNLOAD_BLOCKED=0` is a pass
    // only when nothing tried; a non-zero count with no FULL_DOWNLOAD bytes is
    // also a pass — the code path existed and was stopped, which is exactly
    // what the guard is for.
    lines.add('AUTO_FULL_DOWNLOAD_BLOCKED=${downloadAudit.blockedWholeFileCount} '
        'wholeFileAllowed=${downloadAudit.wholeFileAllowed ? 'true' : 'false'} '
        'revokedBy=${downloadAudit.wholeFileRevokedBy ?? '-'}');
    if (downloadAudit.blockedWholeFileCount > 0) {
      lines.add('FULL_DOWNLOAD_GUARD fired: '
          '${downloadAudit.blockedWholeFile.join(' | ')}');
    }
    lines.add('DOWNLOAD_GROWTH ${downloadAudit.growthSummary()}');
    final largest = downloadAudit.largest;
    if (largest != null) {
      lines.add('LARGEST_DOWNLOAD caller=${largest.caller.label} '
          'file=${largest.fileId} offset=${largest.offset} '
          'limit=${largest.limit <= 0 ? 'WHOLE_FILE' : largest.limit} '
          'grew=${largest.grew}');
    }
    lines.addAll(downloadAudit.summary(max: 10));
    // Header/body agreement, counted from the exchanges the proxy really
    // performed: a 206 that declared more bytes than it carried is the
    // failure mode that reads as "无法连接服务器" on the device.
    lines.add('HTTP_BODY_INCOMPLETE=$_incompleteCount '
        'HTTP_HEADER_MISMATCH=$_headerMismatchCount');
    // The identity chain. Three different videos in this block is the
    // "点 A 播 B" defect, stated as data instead of a suspicion.
    lines.add('CLICKED file=${_clickedFileId ?? '-'} '
        'chat=${_clickedChatId ?? '-'} msg=${_clickedMessageId ?? '-'}');
    lines.add('ACTIVE file=${_activeFileId ?? '-'} '
        'chat=${_activeChatId ?? '-'} msg=${_activeMessageId ?? '-'}');
    lines.add('PLAYER file=${_playerFileId ?? '-'} '
        'chat=${_activeChatId ?? '-'} msg=${_activeMessageId ?? '-'}');
    lines.add(identityOk
        ? 'IDENTITY=OK'
        : 'IDENTITY=BUG: clicked=${_clickedFileId ?? '-'} '
            'active=${_activeFileId ?? '-'} player=${_playerFileId ?? '-'}');
    // The four ids side by side. A report that says "record exists" and
    // "no_file_record" at once is describing two different ids, and this line
    // is where that becomes visible instead of contradictory.
    lines.add('FILE_ID_RESOLVE: clickedFileId=${_resolveClickedId ?? '-'} '
        'recordFileId=${_resolveRecordId ?? '-'} '
        'resolvedFileId=${_resolveResolvedId ?? '-'} '
        'tdlibFileId=${_resolveTdlibId ?? '-'} '
        'fileUniqueId=${_resolveUniqueId ?? '-'} '
        'messageId=${_resolveMessageId ?? '-'} '
        'generation=${_resolveGeneration ?? '-'}');
    for (final remap in _remaps) {
      lines.add('FILE_ID_REMAP $remap');
    }
    lines.add(_forwardRangeRequests == 0
        ? 'tailRequests=0 NO_TAIL_REQUEST'
        : 'tailRequests=$_forwardRangeRequests');
    lines.add('moov=${_moov.name}');
    lines.add('failure=${_failureKind?.code ?? 'NONE'}'
        '${_failureMessage == null ? '' : ' ${_failureMessage!}'}');
    lines.add('playerItemCreated=${_stamp(_playerCreatedMillis)} '
        'ready=${_stamp(_playerReadyMillis)} '
        'failed=${_stamp(_playerFailedMillis)}');
    if (_playerFailedText != null) {
      lines.add('playerFailure=$_playerFailedText');
    }
    return lines;
  }

  static String _stamp(int? millis) => millis == null ? '-' : _seconds(millis);

  static String _seconds(int millis) => '${(millis / 1000).toStringAsFixed(1)}s';

  /// Machine-readable form for the diagnostics export.
  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': _enabled,
        'forceStreamingTest': _forceTest,
        'preferenceStreaming': userStreamingPreference,
        'streamingEnabled': _streamingEnabled,
        'playerSourceType': _playerSourceType,
        'proxyUrl': _proxyUrl == null ? null : redactText(_proxyUrl!),
        'fileId': _fileId,
        'chatId': _chatId,
        'messageId': _messageId,
        'recordFileId': _recordFileId,
        'recordMessageId': _recordMessageId,
        'recordSizeBytes': _recordSizeBytes,
        'recordSizeMismatch': recordSizeMismatch,
        'totalBytes': _totalBytes,
        'downloadedBytes': _downloadedBytes,
        'diskBytes': _diskBytes,
        'diskCoversTotal': diskCoversTotal,
        'completionRefusal': _completionRefusal,
        'downloadedPercent':
            double.parse((downloadedPercent * 100).toStringAsFixed(1)),
        'headBytes': _headBytes,
        'downloadOffset': _downloadOffset,
        'windowStart': _windowStart,
        'windowEnd': _windowEnd,
        'isDownloading': _isDownloading,
        'isDownloadingCompleted': _isDownloadingCompleted,
        'rangeRequests': _rangeRequests,
        'lastRange': _lastRange,
        'lastStatus': _lastStatus,
        'partialContentCount': _partialContentCount,
        'windowMoves': _windowMoves,
        'stalls': _stalls,
        'lastStallReason': _lastStallReason,
        'playerSeconds': _playerTime.inSeconds,
        'durationSeconds': _playerDuration.inSeconds,
        'timeControlStatus': _timeControlStatus,
        'hasStartedPlaying': _hasStartedPlaying,
        'playerError': _playerError == null ? null : _sanitize(_playerError!),
        'fallback': _fallback,
        'fallbackReason': _fallbackReason,
        'firstPlayback': <String, Object?>{
          'millis': _firstPlaybackMillis,
          'downloadedBytes': _firstPlaybackDownloadedBytes,
          'totalBytes': _firstPlaybackTotalBytes,
          'completed': _firstPlaybackCompleted,
        },
        'firstRangeMillis': _firstRangeMillis,
        'proxyStartedMillis': _proxyStartedMillis,
        'verdict': verdict.code,
        'moov': _moov.name,
        // Why the play failed, in the same vocabulary the error page used.
        // A report that says "network" for every failure cannot be acted on;
        // this is the field that tells a codec problem from a stalled
        // download.
        'failure': <String, Object?>{
          'kind': _failureKind?.code,
          'message': _failureMessage,
          'retryable': _failureKind?.retryable,
        },
        'truncatedRanges': _truncatedCount,
        // The measured half of the decision, exported beside the transport
        // counts: a report that says "V1 proxy" must carry the disk size that
        // made it choose that.
        'playback': <String, Object?>{
          'decision': _playbackDecision,
          'decisionReason': _playbackDecisionReason,
          'finalSource': _finalSource,
          'localFileSize': _decisionLocalSize,
          'expectedFileSize': _decisionExpectedSize,
          'diskCoversExpected': _decisionDiskCovers,
          'needsRedownload': _decisionRedownload,
          'activeFileId': _activeFileId,
          'playerFileId': _playerFileId,
          'preloadFileIds': _preloadFileIds,
          'v2Attempted': _v2Attempted,
          'v2Failed': _v2Failed,
          'v1Attempted': _v1Attempted,
          'v1Failed': _v1Failed,
        },
        // The audit as data: every request, who sent it, and the bytes it
        // moved. A report can sum this; it cannot sum a log line.
        'downloadAudit': <String, Object?>{
          'calls': <Map<String, Object?>>[
            for (final call in downloadAudit.calls) call.toJson(),
          ],
          'growthByCaller': downloadAudit.growthSummary(),
          'unboundedCalls': downloadAudit.unboundedCalls.length,
          'largest': downloadAudit.largest?.toJson(),
          'wholeFileAllowed': downloadAudit.wholeFileAllowed,
          'wholeFileRevokedBy': downloadAudit.wholeFileRevokedBy,
          'blockedWholeFile': downloadAudit.blockedWholeFile,
        },
        'resourceLoader': <String, Object?>{
          'sessions': _rlSessions,
          'requests': _rlRequests,
          'responds': _rlResponds,
          'bytes': _rlBytes,
          'stalls': _rlStalls,
          'contentInfo': _rlContentInfo,
          // What this loader asked TDLib for and what it moved, next to the
          // bytes it handed the player. Three counts, three meanings.
          'window': downloadAudit.lastCallFor(DownloadCaller.resourceLoader)?.toJson(),
          'downloadedForWindows':
              downloadAudit.grewBy(DownloadCaller.resourceLoader),
          'firstReadError': _firstReadError,
          'v2OnlyStop': _v2StopReason,
          // The ordered events, each stamped with chat/message/file/generation
          // — the part of the report that answers "did it wait for growth or
          // did it finish short".
          'events': <Map<String, Object?>>[
            for (final event in _rlLog)
              <String, Object?>{
                'name': event.name,
                'at': event.elapsedMillis,
                'chat': event.chatId,
                'message': event.messageId,
                'file': event.fileId,
                'generation': event.generation,
                ...event.fields,
              },
          ],
        },
        'incompleteBodies': _incompleteCount,
        'headerMismatches': _headerMismatchCount,
        'identity': <String, Object?>{
          'clicked': _clickedFileId,
          'active': _activeFileId,
          'player': _playerFileId,
          'ok': identityOk,
        },
        'forwardRangeRequests': _forwardRangeRequests,
        'playerTimeline': <String, Object?>{
          'createdMillis': _playerCreatedMillis,
          'readyMillis': _playerReadyMillis,
          'failedMillis': _playerFailedMillis,
          'failure': _playerFailedText,
        },
        'exchanges': <Object?>[
          for (final exchange in _exchanges)
            <String, Object?>{
              'index': exchange.index,
              'method': exchange.method,
              'range': exchange.rangeHeader,
              'status': exchange.status,
              'servedFrom': exchange.servedFrom,
              'servedTo': exchange.servedTo,
              'total': exchange.total,
              'declaredLength': exchange.declaredLength,
              'writtenBytes': exchange.writtenBytes,
              'contentRange': exchange.contentRange,
              'contentType': exchange.contentType,
              'contentEncoding': exchange.contentEncoding,
              'truncated': exchange.truncated,
              'note': exchange.note,
            },
        ],
      };

  /// Human-readable block (settings screen + clipboard export).
  List<String> diagnosticLines() => <String>[
        'streaming (${verdict.code})',
        ...panelLines(),
        if (_growth.length > 1)
          'growth=${_growth.map((s) => '${_seconds(s.millis)}:${formatBytes(s.bytes)}').join(' → ')}',
        if (_events.isNotEmpty) 'events=${events.join(' | ')}',
      ];
}
