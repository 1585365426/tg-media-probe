import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

class ChannelLoadResult {
  const ChannelLoadResult({
    required this.channels,
    required this.scannedChats,
    required this.failedChats,
    this.error,
  });

  final List<ChatSummary> channels;

  /// How many chat ids TDLib returned (channels + private chats + groups).
  final int scannedChats;

  /// `getChat` calls that came back as errors. Non-zero with a healthy
  /// [channels] list is normal when a chat was deleted or is inaccessible.
  final int failedChats;

  /// Fatal error (getChats itself failed). The channel list is empty then.
  final String? error;

  bool get isFatal => error != null;

  Map<int, String> get titles => <int, String>{
        for (final chat in channels) chat.id: chat.title,
      };
}

/// Read-only channel discovery: `getChats` then one `getChat` per id.
///
/// `getChats` only returns ids, so titles need the second call. Both are pure
/// reads; there is no join/leave/mute anywhere in this file, which
/// `test/readonly_guard_test.dart` re-checks by scanning the tree.
class ChannelLoader {
  ChannelLoader(this.client, {this.timeout = const Duration(seconds: 20)});

  final TdClient client;
  final Duration timeout;

  /// Hard cap so a 500-chat account cannot turn one tap into 500 round trips.
  static const int maxChatsPerLoad = 120;

  Future<ChannelLoadResult> load({int limit = maxChatsPerLoad}) async {
    final capped = limit.clamp(1, maxChatsPerLoad);
    try {
      final response = await client.request(
        getChats(limit: capped),
        timeout: timeout,
      );
      final error = errorText(response);
      if (error != null) {
        return ChannelLoadResult(
          channels: const <ChatSummary>[],
          scannedChats: 0,
          failedChats: 0,
          error: error,
        );
      }

      final ids = chatIdsFromResponse(response);
      final channels = <ChatSummary>[];
      var failed = 0;
      for (final id in ids) {
        try {
          final chatResponse =
              await client.request(getChat(id), timeout: timeout);
          final chat = chatFromResponse(chatResponse);
          if (chat == null) {
            failed++;
            continue;
          }
          if (chat.isChannel) channels.add(chat);
        } catch (_) {
          failed++;
        }
      }

      channels.sort((a, b) => a.title.compareTo(b.title));
      return ChannelLoadResult(
        channels: channels,
        scannedChats: ids.length,
        failedChats: failed,
      );
    } catch (e) {
      return ChannelLoadResult(
        channels: const <ChatSummary>[],
        scannedChats: 0,
        failedChats: 0,
        error: e.toString(),
      );
    }
  }
}
