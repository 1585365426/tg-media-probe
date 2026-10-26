import 'package:flutter/foundation.dart';

/// Stage timings for one playback activation.
///
/// The reason this exists: "视频加载速度慢" is a report, not a measurement. Before
/// choosing between prefetch, promotion and streaming, the six stages below have
/// to be separable, because they have completely different causes:
///
/// | mark            | what it measures                          |
/// |-----------------|-------------------------------------------|
/// | `activate`      | the moment the page started working on it |
/// | `index`         | reading the mirror / widening the query   |
/// | `stream-url`    | publishing a loopback range URL           |
/// | `player-load`   | AVPlayer reaching ready-to-play           |
/// | `promote`       | whole-file download + copy into Documents |
/// | `rotation`      | native track-transform read               |
///
/// [summary] is shown on the diagnostics page and printed in debug builds, so a
/// device report comes back as numbers instead of an adjective.
class PlaybackTimeline {
  PlaybackTimeline._(this.recordKey, this.startedAt);

  factory PlaybackTimeline.start(String recordKey) =>
      PlaybackTimeline._(recordKey, DateTime.now());

  final String recordKey;
  final DateTime startedAt;
  final Map<String, int> _marks = <String, int>{};

  /// Which path actually played: `file`, `stream`, or `failed`.
  String outcome = 'pending';

  /// Wall-clock ms since [startedAt] for each mark, in insertion order.
  Map<String, int> get marks => Map<String, int>.unmodifiable(_marks);

  DateTime get _now => DateTime.now();

  void mark(String stage) {
    final elapsed = _now.difference(startedAt).inMilliseconds;
    // First writer wins: re-marking a stage would hide the original cost.
    _marks.putIfAbsent(stage, () => elapsed);
  }

  void finish(String outcome) {
    this.outcome = outcome;
    mark('done');
    if (kDebugMode) {
      debugPrint('[playback] $recordKey $outcome ${summary()}');
    }
  }

  /// `activate=0 index=12 stream-url=40 player-load=310 …`
  String summary() {
    if (_marks.isEmpty) return '(no marks)';
    final buffer = StringBuffer();
    var previous = 0;
    for (final entry in _marks.entries) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write('${entry.key}=${entry.value}');
      previous = entry.value;
    }
    buffer.write(' total=${previous}ms');
    return buffer.toString();
  }

  @override
  String toString() => 'PlaybackTimeline($recordKey, $outcome, ${summary()})';
}

/// Ring buffer of the most recent activations, for the diagnostics page.
///
/// Kept in memory only: writing timings to disk would create a log file nothing
/// clears, and the point is a quick look after "it felt slow", not a trace.
class PlaybackTimelineLog {
  PlaybackTimelineLog._();

  static const int capacity = 10;
  static final List<PlaybackTimeline> _recent = <PlaybackTimeline>[];

  static List<PlaybackTimeline> get recent =>
      List<PlaybackTimeline>.unmodifiable(_recent);

  static void record(PlaybackTimeline timeline) {
    _recent.insert(0, timeline);
    if (_recent.length > capacity) {
      _recent.removeRange(capacity, _recent.length);
    }
  }

  static void clear() => _recent.clear();
}
