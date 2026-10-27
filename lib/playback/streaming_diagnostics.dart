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

  /// The exact URL the player opened in STREAM_HTTP mode.
  String? _proxyUrl;

  int? _chatId;
  int? _messageId;
  int? _fileId;

  int _totalBytes = 0;
  int _downloadedBytes = 0;
  int _headBytes = 0;
  int _downloadOffset = 0;
  int _windowStart = 0;
  int _windowEnd = 0;

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

  int get totalBytes => _totalBytes;
  int get downloadedBytes => _downloadedBytes;
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
    final attempted = _proxyStartedMillis != null || _rangeRequests > 0;
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
    // No 206 or no Range request means the player was never served from a
    // partial file, whatever the source URL looked like. In the forced test
    // that is a definite failure, not an open question.
    if (!sawPartialContent || _rangeRequests == 0) {
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
  }) {
    if (_sealedResult) return;
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

  /// Records what the player is about to open — called from the feed
  /// controller immediately before `player.activate`, with the same source.
  ///
  /// `STREAM_HTTP` carries the loopback URL so the report can show the exact
  /// address AVPlayer streamed from; `LOCAL_FILE` is a full-download play and
  /// forces the verdict off `STREAMING_CONFIRMED`.
  void notePlayerSource({required bool isStreaming, required String url}) {
    if (_sealedResult) return;
    _playerSourceType = isStreaming ? 'STREAM_HTTP' : 'LOCAL_FILE';
    _proxyUrl = isStreaming ? url : null;
    _note('playerSource=$_playerSourceType');
    notifyListeners();
  }

  /// Clears the previous run and starts recording a new one.
  ///
  /// [streaming] is the resolver's decision, recorded as such — it is *not*
  /// treated as proof (see [verdict]).
  void beginPlay({
    required int fileId,
    required bool streaming,
    int? chatId,
    int? messageId,
    int? totalBytes,
  }) {
    // A settled acceptance result is frozen: browsing afterwards must not
    // replace the verdict the run produced (this was the "ghost panel" hole
    // in reverse — a later LOCAL_FILE play overwriting a real run).
    if (_sealedResult) return;
    _forceTestAtPlay = _forceTest;
    _streamingEnabled = streaming;
    _fileId = fileId;
    _chatId = chatId;
    _messageId = messageId;
    _totalBytes = totalBytes ?? 0;
    _downloadedBytes = 0;
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
    _fallback = false;
    _fallbackReason = null;
    _firstPlaybackDownloadedBytes = null;
    _firstPlaybackTotalBytes = null;
    _firstPlaybackCompleted = false;
    _firstPlaybackMillis = null;
    _downloadCompletedMillis = null;
    _firstBytesMillis = null;
    _first206Millis = null;
    _decisionPreference = null;
    _decisionForce = null;
    _decisionCandidate = null;
    _decisionCandidateReason = null;
    _decisionProxyAvailable = null;
    _decisionFileComplete = null;
    _decision = null;
    _decisionReason = null;
    _startedAt = _clock();
    _growth.clear();
    _events.clear();
    notifyListeners();
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
  void noteStreamingSelected() {
    if (_sealedResult) return;
    _streamingEnabled = true;
    notifyListeners();
  }

  /// The range proxy bound its port and the player URL exists. `url` is the
  /// exact `http://127.0.0.1:port/<token>` the player will be handed.
  void noteProxyStarted(String url) {
    if (_sealedResult) return;
    _proxyStartedMillis ??= _elapsed();
    _proxyUrl = url;
    _note('proxy started');
    notifyListeners();
  }

  /// TDLib said bytes exist. Straight from `updateFile` / `updateFileProgress`.
  void updateTransfer({
    required int downloadedBytes,
    required int totalBytes,
    required int downloadOffset,
    required bool completed,
    bool isDownloading = true,
  }) {
    if (_sealedResult) return;
    _downloadedBytes = downloadedBytes;
    if (totalBytes > 0) _totalBytes = totalBytes;
    _downloadOffset = downloadOffset;
    _isDownloadingCompleted = completed;
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
  void updateTransferFromState(FileState state) {
    updateTransfer(
      downloadedBytes: state.downloadedSize,
      totalBytes: state.expectedSize,
      downloadOffset: state.downloadOffset,
      completed: state.isCompleted,
    );
  }

  /// The player asked for a byte range. Straight from the proxy's request.
  void noteRangeRequest({required int from, int? to}) {
    if (_sealedResult) return;
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
  }) {
    if (_sealedResult) return;
    _lastStatus = status;
    if (status == 206) {
      _partialContentCount++;
      _first206Millis ??= _elapsed();
    }
    if (total > 0) _totalBytes = total;
    _note('HTTP $status $from-$end/$total ${length}B');
  }

  /// The proxy moved the TDLib download window to serve a distant range.
  void noteWindowMove(int start, int end) {
    if (_sealedResult) return;
    _windowMoves++;
    _windowStart = start;
    _windowEnd = end;
    _note('window→$start-$end');
  }

  /// No TDLib progress for a whole quiet window: a real stall, not slowness.
  void noteStall(String reason) {
    if (_sealedResult) return;
    _stalls++;
    _lastStallReason = reason;
    _note('stall $reason');
  }

  /// Streaming gave up and the full download took over.
  ///
  /// The reason is redacted here: it can carry a TDLib message with a container
  /// path, and this text is what reaches the diagnostics export.
  void noteFallback(String reason) {
    if (_sealedResult) return;
    _fallback = true;
    _fallbackReason = redactText(reason);
    _streamingEnabled = false;
    _note('fallback ${_fallbackReason!}');
  }

  /// TDLib reported the whole file on disk.
  void noteCompleted({int? totalBytes}) {
    if (_sealedResult) return;
    if (!_isDownloadingCompleted) {
      _isDownloadingCompleted = true;
      _downloadCompletedMillis = _elapsed();
    }
    _isDownloading = false;
    if (totalBytes != null && totalBytes > 0) _totalBytes = totalBytes;
    _headBytes = _totalBytes;
    _downloadedBytes = _totalBytes;
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
  }) {
    if (_sealedResult) return;
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
        'candidate=${_decisionCandidate ?? '-'} '
            'complete=${_decisionFileComplete ?? '-'} '
            'proxyAvailable=${_decisionProxyAvailable ?? '-'}'
        '${_decisionCandidateReason == null ? '' : ' candidateReason=$_decisionCandidateReason'}',
        if (_proxyUrl != null) 'proxyUrl=${redactText(_proxyUrl!)}',
        'streamingEnabled=${_streamingEnabled ? 'true' : 'false'}',
        'file=${_fileId ?? '-'} msg=${_messageId ?? '-'} chat=${_chatId ?? '-'}',
        'total=$_totalBytes B downloaded=$_downloadedBytes B '
            '(${_percentString()})',
        'head=$_headBytes B downloadOffset=$_downloadOffset',
        'window=$_windowStart-$_windowEnd moves=$_windowMoves',
        'isDownloading=${_isDownloading ? 'true' : 'false'} '
            'completed=${_isDownloadingCompleted ? 'true' : 'false'}',
        'range=${_lastRange ?? '-'} requests=$_rangeRequests '
            'status=${_lastStatus ?? '-'} 206x$_partialContentCount',
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
    // Forced-test failure marker: the acceptance must not read a full download
    // as a pass, whatever else the run produced.
    if (_forceTestAtPlay &&
        verdict == StreamingVerdict.fullDownloadBeforePlayback) {
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
    final completed = _downloadCompletedMillis;
    lines.add(completed == null
        ? 'completedAt=-'
        : 'completedAt=${_seconds(completed)}');
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
    return lines;
  }

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
        'totalBytes': _totalBytes,
        'downloadedBytes': _downloadedBytes,
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
