/// Stable, human-facing numbering for one channel's videos.
///
/// The number is a **position in history**, not an identity: #001 is the oldest
/// video the channel still exposes, and numbers grow forward in time. That is
/// what makes the numbering stable — a new upload lands after #00N, so every
/// number already handed out keeps pointing at the same message.
///
/// It is deliberately not `messageId`, not `fileId`, and not an index into
/// whatever list the UI happens to be paging. `fileId` in particular changes
/// when TDLib refreshes a file reference, and a number that moves is worse than
/// no number at all.
library;

import 'media_record.dart';

/// Upper bound for a typed number. Keeps a typo like 999999999 from turning
/// into a million comparisons; not a product limit.
const int kMaxMediaNumber = 999999;

/// `#001`, `#023`, `#1234`. Three digits minimum, never truncated: a channel
/// with 1200 videos shows `#1200`, not `#200`.
String formatMediaNumber(int number) {
  if (number < 1) return '#---';
  final digits = number.toString();
  return '#${digits.length >= 3 ? digits : digits.padLeft(3, '0')}';
}

/// Parses user input (`23`, `#23`, ` 023 `). Returns null when the text is not
/// a usable number, so the caller can say "未找到" instead of guessing.
int? parseMediaNumber(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('#')) text = text.substring(1).trim();
  if (text.isEmpty) return null;
  final value = int.tryParse(text);
  if (value == null || value < 1 || value > kMaxMediaNumber) return null;
  return value;
}

/// One video plus the number it is shown under.
class NumberedMedia {
  const NumberedMedia({required this.number, required this.record});

  final int number;
  final MediaRecord record;

  String get label => formatMediaNumber(number);

  /// What the row and the player header show as a title.
  ///
  /// Real data only: the caption if the channel owner wrote one, else the file
  /// name, else a neutral placeholder. The message id is never used here — it
  /// is an implementation detail, not a title.
  String get displayTitle {
    final caption = record.caption;
    if (caption != null && caption.trim().isNotEmpty) {
      return caption.trim().split('\n').first;
    }
    final name = record.fileName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return '视频 $label';
  }

  @override
  String toString() => '$label -> ${record.chatId}/${record.messageId}';
}

/// Immutable snapshot of one channel's videos in numbering order.
///
/// Built from the local mirror on every list build; O(n log n) once, then O(1)
/// lookups. n is a channel's video count, not the whole mirror.
class MediaIndex {
  const MediaIndex._(this.items, this._byKey);

  factory MediaIndex.fromRecords(Iterable<MediaRecord> records) {
    final playable = records
        .where((r) => r.kind == MediaKind.video && r.fileId != 0)
        .toList(growable: false)
      ..sort(compareForNumbering);
    final items = <NumberedMedia>[];
    final byKey = <String, int>{};
    for (var i = 0; i < playable.length; i++) {
      final number = i + 1;
      items.add(NumberedMedia(number: number, record: playable[i]));
      byKey[playable[i].key] = number;
    }
    return MediaIndex._(List<NumberedMedia>.unmodifiable(items),
        Map<String, int>.unmodifiable(byKey));
  }

  static const MediaIndex empty =
      MediaIndex._(<NumberedMedia>[], <String, int>{});

  /// Oldest first. Ties (two videos in the same second) break on message id,
  /// which TDLib assigns monotonically inside a chat.
  static int compareForNumbering(MediaRecord a, MediaRecord b) {
    final byDate = a.messageDateUnix.compareTo(b.messageDateUnix);
    if (byDate != 0) return byDate;
    return a.messageId.compareTo(b.messageId);
  }

  final List<NumberedMedia> items;
  final Map<String, int> _byKey;

  int get length => items.length;
  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  NumberedMedia? byNumber(int number) {
    if (number < 1 || number > items.length) return null;
    return items[number - 1];
  }

  /// 1-based number for a message, or null when it is not indexed (or not a
  /// playable video).
  int? numberFor(int chatId, int messageId) => _byKey['$chatId:$messageId'];

  NumberedMedia? byMessage(int chatId, int messageId) {
    final number = numberFor(chatId, messageId);
    return number == null ? null : byNumber(number);
  }

  /// Zero-based position for a message, for PageView initial pages.
  int? indexFor(int chatId, int messageId) {
    final number = numberFor(chatId, messageId);
    return number == null ? null : number - 1;
  }

  /// Search by number (`23` / `#023`) or by text (caption, file name).
  ///
  /// A pure number query is matched against the number first, and only then as
  /// text, so typing `23` on a video whose caption contains "23" jumps to #023.
  List<NumberedMedia> search(String query) {
    final text = query.trim();
    if (text.isEmpty) return items;
    final asNumber = parseMediaNumber(text);
    if (asNumber != null) {
      final exact = byNumber(asNumber);
      return exact == null ? const <NumberedMedia>[] : <NumberedMedia>[exact];
    }
    final needle = text.toLowerCase();
    return items.where((item) {
      if (item.label.toLowerCase().contains(needle)) return true;
      final caption = item.record.caption;
      if (caption != null && caption.toLowerCase().contains(needle)) {
        return true;
      }
      final name = item.record.fileName;
      return name != null && name.toLowerCase().contains(needle);
    }).toList(growable: false);
  }

  @override
  String toString() => 'MediaIndex(${items.length} videos)';
}
