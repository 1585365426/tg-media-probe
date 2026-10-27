/// Timing for one playback, stage by stage.
///
/// Why this exists: "第一次播放很慢，第二次很快" is a symptom with at least five
/// candidate causes — a cold TDLib file record, a full media download, a slow
/// AVPlayer setup, a redundant second request, or a wait that ends later than it
/// needs to. Without per-stage timestamps every one of those looks the same:
/// "准备中".
///
/// What is recorded: file/message/chat ids, byte counts, durations, and an error
/// category. What is never recorded: api hash, database key, phone number,
/// tokens, file paths (they contain the container UUID).
library;

/// The stages a play goes through. Ordered: a later stage never precedes an
/// earlier one in a healthy run.
enum PlaybackStage {
  /// The user picked an item.
  selected,

  /// resolve() began: the resolver is about to ask TDLib about the file.
  resolveStarted,

  /// TDLib returned the file record (completed or not, with a size).
  fileRecordKnown,

  /// `downloadFile` was sent.
  downloadRequested,

  /// The first `updateFile` with bytes arrived.
  firstBytes,

  /// The local file is complete and readable.
  fileReady,

  /// The player object was created.
  playerCreated,

  /// The player reported initialisation done.
  playerInitialized,

  /// The first frame is on screen (best effort: the UI marks it).
  firstFrame,

  /// TDLib rejected the stored `file_id` and the message was re-read to obtain
  /// a fresh one. Deliberately last in the enum: it is an *event*, not a point
  /// on the happy path, so it must not change the ordering of the stages above
  /// ([lastStage], [between]).
  fileIdRefreshed,

  /// The message was read again to fill in a missing file name or size.
  metadataFetched,
}

class PlaybackTrace {
  PlaybackTrace({
    required this.fileId,
    this.chatId,
    this.messageId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int fileId;
  final int? chatId;
  final int? messageId;
  final DateTime Function() _clock;

  final Map<PlaybackStage, DateTime> _marks = <PlaybackStage, DateTime>{};
  final Map<PlaybackStage, int> _bytes = <PlaybackStage, int>{};
  String? errorCategory;
  int? expectedBytes;
  int? downloadedBytes;

  /// How many times a transient TDLib failure was retried before the answer.
  int retries = 0;

  /// Free-form, already-redacted note for the diagnostics ("file_id 失效，
  /// 已从消息重新获取"). Never a path and never the message text.
  String? note;

  Map<PlaybackStage, DateTime> get marks => Map<PlaybackStage, DateTime>.unmodifiable(_marks);

  /// Records a stage once. A repeat mark is ignored: the first time a stage was
  /// reached is the number worth reporting.
  void mark(PlaybackStage stage, {int? bytes}) {
    _marks.putIfAbsent(stage, _clock);
    if (bytes != null) _bytes[stage] = bytes;
  }

  bool has(PlaybackStage stage) => _marks.containsKey(stage);

  /// Milliseconds between two stages, or null when either was never reached.
  int? between(PlaybackStage from, PlaybackStage to) {
    final a = _marks[from];
    final b = _marks[to];
    if (a == null || b == null) return null;
    return b.difference(a).inMilliseconds;
  }

  PlaybackStage? get lastStage {
    PlaybackStage? latest;
    for (final stage in _marks.keys) {
      if (latest == null || stage.index > latest.index) latest = stage;
    }
    return latest;
  }

  /// Stage-by-stage breakdown, in enum order.
  List<String> stageLines() {
    final lines = <String>[];
    for (final stage in PlaybackStage.values) {
      final at = _marks[stage];
      if (at == null) continue;
      final prev = _previousMarked(stage);
      final delta = prev == null ? null : at.difference(prev).inMilliseconds;
      final bytes = _bytes[stage];
      lines.add('${stage.name}=${delta == null ? '-' : '${delta}ms'}'
          '${bytes == null ? '' : ' ${bytes}B'}');
    }
    return lines;
  }

  DateTime? _previousMarked(PlaybackStage stage) {
    DateTime? best;
    PlaybackStage? bestStage;
    for (final entry in _marks.entries) {
      if (entry.key.index >= stage.index) continue;
      if (bestStage == null || entry.key.index > bestStage.index) {
        best = entry.value;
        bestStage = entry.key;
      }
    }
    return best;
  }

  /// One line, safe to export. No paths, no credentials, no message text.
  String summary() {
    final total = between(PlaybackStage.selected, PlaybackStage.firstFrame) ??
        between(PlaybackStage.selected, PlaybackStage.fileReady);
    final parts = <String>[
      'file=$fileId',
      if (chatId != null) 'chat=$chatId',
      if (messageId != null) 'msg=$messageId',
      'total=${total ?? -1}ms',
      if (expectedBytes != null) 'expected=${expectedBytes}B',
      if (downloadedBytes != null) 'got=${downloadedBytes}B',
      if (retries > 0) 'retries=$retries',
      if (errorCategory != null) 'error=$errorCategory',
      if (note != null) 'note=$note',
      ...stageLines(),
    ];
    return parts.join(' ');
  }
}

/// A small ring of recent traces, for the diagnostics export.
///
/// Bounded on purpose: the export is a support artifact, not a log file that
/// grows until the disk complains.
class PlaybackTraceLog {
  PlaybackTraceLog({this.capacity = 20});

  static final PlaybackTraceLog instance = PlaybackTraceLog();

  final int capacity;
  final List<PlaybackTrace> _entries = <PlaybackTrace>[];

  List<PlaybackTrace> get entries => List<PlaybackTrace>.unmodifiable(_entries);

  void add(PlaybackTrace trace) {
    _entries.add(trace);
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
  }

  void clear() => _entries.clear();

  /// Lines for the diagnostics sheet. Already free of paths and secrets.
  List<String> diagnosticLines() => <String>[
        'playback ($capacity max, ${_entries.length} recorded)',
        ..._entries.map((e) => e.summary()),
      ];
}
