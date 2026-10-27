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
}

extension StreamingVerdictView on StreamingVerdict {
  /// The line the diagnostics screen must show. Never "Streaming" on its own.
  String get label => switch (this) {
        StreamingVerdict.streamingActive => '✅ 已确认：边下边播',
        StreamingVerdict.fullDownloadBeforePlayback => '⚠️ 全部下载完成后播放',
        StreamingVerdict.fallbackUsed => '⏭️ 流式失败，已回退到完整下载',
        StreamingVerdict.unknown => '❓ 无法判定',
      };

  /// The token written into the timeline and the acceptance report.
  String get code => switch (this) {
        StreamingVerdict.streamingActive => 'STREAMING_CONFIRMED',
        StreamingVerdict.fullDownloadBeforePlayback =>
          'FULL_DOWNLOAD_BEFORE_PLAYBACK',
        StreamingVerdict.fallbackUsed => 'STREAMING_FALLBACK',
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
    if (_fallback) return StreamingVerdict.fallbackUsed;
    final atFirstPlayback = _firstPlaybackDownloadedBytes;
    // No confirmed playhead = nothing to compare against.
    if (atFirstPlayback == null) return StreamingVerdict.unknown;
    final totalAtFirstPlayback = _firstPlaybackTotalBytes ?? 0;
    // Without a total, "146 MB" cannot be placed on any scale.
    if (totalAtFirstPlayback <= 0) return StreamingVerdict.unknown;
    // Full file before the first played frame = not play-while-downloading.
    if (atFirstPlayback >= totalAtFirstPlayback || _firstPlaybackCompleted) {
      return StreamingVerdict.fullDownloadBeforePlayback;
    }
    // No 206 or no Range request means the player was never served from a
    // partial file, whatever the source URL looked like.
    if (!sawPartialContent || _rangeRequests == 0) {
      return StreamingVerdict.unknown;
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
    _fallback = false;
    _fallbackReason = null;
    _firstPlaybackDownloadedBytes = null;
    _firstPlaybackTotalBytes = null;
    _firstPlaybackCompleted = false;
    _firstPlaybackMillis = null;
    _downloadCompletedMillis = null;
    _firstBytesMillis = null;
    _first206Millis = null;
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
    beginPlay(fileId: 0, streaming: false);
    _acceptanceRunning = true;
    notifyListeners();
  }

  /// Ends the armed run; the recorded evidence stays on screen.
  void stopAcceptance() {
    _acceptanceRunning = false;
    notifyListeners();
  }

  /// The resolver picked the streaming branch. **Recorded, not trusted**: it
  /// only says which path was taken. [verdict] still waits for the data.
  void noteStreamingSelected() {
    _streamingEnabled = true;
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
    _rangeRequests++;
    _lastRange = '$from-${to ?? 'end'}';
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
    _windowMoves++;
    _windowStart = start;
    _windowEnd = end;
    _note('window→$start-$end');
  }

  /// No TDLib progress for a whole quiet window: a real stall, not slowness.
  void noteStall(String reason) {
    _stalls++;
    _lastStallReason = reason;
    _note('stall $reason');
  }

  /// Streaming gave up and the full download took over.
  ///
  /// The reason is redacted here: it can carry a TDLib message with a container
  /// path, and this text is what reaches the diagnostics export.
  void noteFallback(String reason) {
    _fallback = true;
    _fallbackReason = redactText(reason);
    _streamingEnabled = false;
    _note('fallback ${_fallbackReason!}');
  }

  /// TDLib reported the whole file on disk.
  void noteCompleted({int? totalBytes}) {
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
    final lines = <String>[verdict.code];
    final playback = _firstPlaybackMillis;
    lines.add(playback == null
        ? 'firstPlayback=-'
        : 'firstPlayback=${_seconds(playback)}');
    final downloaded = _firstPlaybackDownloadedBytes;
    final total = _firstPlaybackTotalBytes;
    lines.add(downloaded == null || total == null || total <= 0
        ? 'downloaded=-'
        : 'downloaded=${formatBytes(downloaded)} / ${formatBytes(total)}');
    final completed = _downloadCompletedMillis;
    lines.add(completed == null
        ? 'completion=-'
        : 'completion=${_seconds(completed)}');
    final first206 = _first206Millis;
    lines.add(first206 == null
        ? 'first206=-'
        : 'first206=${_seconds(first206)}');
    lines.add('206x$_partialContentCount rangeRequests=$_rangeRequests '
        'windowMoves=$_windowMoves stalls=$_stalls');
    return lines;
  }

  static String _seconds(int millis) => '${(millis / 1000).toStringAsFixed(1)}s';

  /// Machine-readable form for the diagnostics export.
  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': _enabled,
        'streamingEnabled': _streamingEnabled,
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
