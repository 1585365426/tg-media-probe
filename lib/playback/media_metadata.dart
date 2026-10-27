/// Re-reads one message to repair the metadata the index stored for it.
///
/// Two device failures come from the same root: the index is a snapshot, and a
/// snapshot goes stale.
///
/// * `downloadFile` answers `400: File not found` for a `file_id` that was
///   valid when the message was indexed and is not valid any more (TDLib
///   rebuilt its file database, the message was edited and re-uploaded, the
///   channel replaced the file). Retrying the same id fails forever.
/// * `messageVideo.video.file_name` is empty for a large share of channel
///   videos, so the mirror has no name to show and the player falls back to
///   the channel title. The name is still readable from the message itself.
///
/// Neither is guessable locally, so both are answered by one `getMessage` —
/// a read, on the read-only allowlist, no cloud mutation.
library;

import '../data/media_record.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

/// Fetches the current metadata of one message.
abstract class MediaMetadataLookup {
  /// Returns null when the message is gone, unreadable, or carries no media.
  Future<MediaRecord?> fetch(int chatId, int messageId);
}

class TdMediaMetadataLookup implements MediaMetadataLookup {
  TdMediaMetadataLookup(
    this.client, {
    this.timeout = const Duration(seconds: 10),
  });

  final TdClient client;

  /// `getMessage` is a local-database hit in the common case; ten seconds is
  /// already the "TDLib is not answering" threshold, not a network budget.
  final Duration timeout;

  @override
  Future<MediaRecord?> fetch(int chatId, int messageId) async {
    try {
      final response = await client.request(
        getMessage(chatId: chatId, messageId: messageId),
        timeout: timeout,
      );
      if (errorText(response) != null) return null;
      return MediaRecord.fromMessage(chatId: chatId, message: response);
    } on Object {
      // A failed metadata repair must never become the visible error: the
      // caller already has a real failure to report (or a play already
      // running).
      return null;
    }
  }
}
