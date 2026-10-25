import '../app/app_settings.dart';
import 'media_record.dart';

/// One immutable combination of search text + category + duration bucket.
///
/// Kept as a value object (instead of three loose parameters) so the feed can
/// compare the previous query with the new one and skip a rebuild when nothing
/// changed.
class VideoQuery {
  const VideoQuery({
    this.text = '',
    this.categoryChatId,
    this.duration = DurationFilter.all,
  });

  /// Raw user input. Matching lower-cases it once per evaluation, not per row.
  final String text;

  /// Null = every channel.
  final int? categoryChatId;

  final DurationFilter duration;

  bool get hasText => normalizedText.isNotEmpty;

  bool get isActive =>
      hasText || categoryChatId != null || duration != DurationFilter.all;

  /// Space-separated terms, all of which must hit (AND). This makes
  /// "仓储 4k" narrow instead of widening like an OR would.
  List<String> get terms => normalizedText
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  String get normalizedText => text.trim().toLowerCase();

  VideoQuery copyWith({
    String? text,
    Object? categoryChatId = _unset,
    DurationFilter? duration,
  }) =>
      VideoQuery(
        text: text ?? this.text,
        categoryChatId: identical(categoryChatId, _unset)
            ? this.categoryChatId
            : categoryChatId as int?,
        duration: duration ?? this.duration,
      );

  static const Object _unset = Object();

  /// Empty query — the unfiltered feed.
  static const VideoQuery none = VideoQuery();

  @override
  bool operator ==(Object other) =>
      other is VideoQuery &&
      other.text == text &&
      other.categoryChatId == categoryChatId &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(text, categoryChatId, duration);

  @override
  String toString() =>
      'VideoQuery(text="$text", category=$categoryChatId, '
      'duration=${duration.wire})';
}

/// Pure filtering rules. No TDLib, no widget, no I/O — so the exact predicate
/// the feed uses is the one the tests exercise.
class VideoQueryEngine {
  const VideoQueryEngine._();

  /// True when [record] passes every active condition.
  ///
  /// Search fields, in order: message caption, channel title, file name. All
  /// three are Telegram-supplied strings the user already sees on screen, so
  /// searching them leaks nothing new.
  static bool matches(
    MediaRecord record,
    VideoQuery query, {
    required String Function(int chatId) titleOf,
  }) {
    if (!query.duration.accepts(record.durationSeconds)) return false;
    if (query.categoryChatId != null &&
        record.chatId != query.categoryChatId) {
      return false;
    }
    if (!query.hasText) return true;

    final haystack = StringBuffer()
      ..write(record.caption ?? '')
      ..write('\u0000')
      ..write(titleOf(record.chatId).toLowerCase())
      ..write('\u0000')
      ..write((record.fileName ?? '').toLowerCase());
    final hay = haystack.toString();

    for (final term in query.terms) {
      if (!hay.contains(term)) return false;
    }
    return true;
  }

  static List<MediaRecord> apply(
    Iterable<MediaRecord> records,
    VideoQuery query, {
    required String Function(int chatId) titleOf,
  }) =>
      records
          .where((r) => matches(r, query, titleOf: titleOf))
          .toList(growable: false);

  /// Distinct chat ids present in [records], in first-seen order.
  static List<int> chatIdsOf(Iterable<MediaRecord> records) {
    final seen = <int>{};
    final ids = <int>[];
    for (final record in records) {
      if (seen.add(record.chatId)) ids.add(record.chatId);
    }
    return ids;
  }
}
