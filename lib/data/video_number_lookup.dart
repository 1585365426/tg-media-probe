/// "Video number" lookup, shared by the player and the channel detail page.
///
/// A number is a 1-based position in the **display order of the current
/// channel's video list**. It is not a message id, a file id or an array index;
/// those are implementation details and are never shown to the user.
///
/// Both entry points must resolve a number the same way, otherwise "38" means
/// two different videos depending on which screen asked. So both call this.
library;

import 'index_store.dart';
import 'media_record.dart';

enum NumberLookupStatus {
  /// Found: [NumberLookupResult.chatId] / [messageId] identify the video.
  found,

  /// The channel (or the whole mirror) ran out before reaching that number.
  notFound,

  /// Zero, negative, absurdly large, or not a number at all.
  invalid,
}

class NumberLookupResult {
  const NumberLookupResult({
    required this.status,
    this.chatId,
    this.messageId,
    this.videoCount = 0,
  });

  final NumberLookupStatus status;
  final int? chatId;
  final int? messageId;

  /// How many playable videos were seen while looking. Used for the "未找到该编号
  /// （当前共 N 条）" message, so the number shown is the real one.
  final int videoCount;
}

class VideoNumberLookup {
  const VideoNumberLookup._();

  /// Upper bound for a typed number. Not a list limit — it only keeps a typo
  /// like 999999999 from turning into a million page reads.
  static const int maxNumber = 100000;

  /// Hard cap on pages walked while looking, so a huge channel cannot make the
  /// lookup run for minutes. At 40 rows per page this covers 40k messages.
  static const int defaultMaxPages = 1000;

  static Future<NumberLookupResult> find({
    required IndexStore store,
    required int number,
    int? chatId,
    int pageSize = 40,
    int maxPages = defaultMaxPages,
  }) async {
    if (number < 1 || number > maxNumber) {
      return const NumberLookupResult(status: NumberLookupStatus.invalid);
    }

    String? cursor;
    var seen = 0;
    for (var page = 0; page < maxPages; page++) {
      final result =
          await store.page(limit: pageSize, cursor: cursor, chatId: chatId);
      for (final record in result.items) {
        // Same filter as the feed: a video with a file to resolve.
        if (record.kind != MediaKind.video || record.fileId == 0) continue;
        seen++;
        if (seen == number) {
          return NumberLookupResult(
            status: NumberLookupStatus.found,
            chatId: record.chatId,
            messageId: record.messageId,
            videoCount: seen,
          );
        }
      }
      if (!result.hasMore) break;
      cursor = result.nextCursor;
      if (cursor == null) break;
    }

    return NumberLookupResult(
      status: NumberLookupStatus.notFound,
      videoCount: seen,
    );
  }
}
