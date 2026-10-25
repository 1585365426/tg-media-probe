import '../td/td_client.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

/// One `getChatHistory` call's worth of data.
class HistoryPage {
  const HistoryPage({required this.messages, this.error});

  const HistoryPage.failure(String this.error) : messages = const [];

  final List<Map<String, Object?>> messages;
  final String? error;

  bool get hasError => error != null;
}

/// Source of channel history. Abstracted so sync logic can be tested against a
/// deterministic fixture while the app uses the real TDLib implementation.
abstract class HistorySource {
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  });
}

/// Read-only TDLib implementation: `getChatHistory` with an explicit
/// `from_message_id` cursor, `offset` and a bounded `limit`.
///
/// No other TDLib method is reachable from this class, and `getChatHistory`
/// itself is a pure read.
class TdHistorySource implements HistorySource {
  TdHistorySource(this.client, {this.timeout = const Duration(seconds: 30)});

  final TdClient client;
  final Duration timeout;

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    try {
      final response = await client.request(
        getChatHistory(
          chatId: chatId,
          fromMessageId: fromMessageId,
          offset: offset,
          limit: limit,
        ),
        timeout: timeout,
      );
      final error = errorText(response);
      if (error != null) return HistoryPage.failure(error);
      return HistoryPage(messages: messagesFromResponse(response));
    } catch (e) {
      // Network loss, TDLib timeout, closed client: all surface as a real error
      // string, never as an empty success.
      return HistoryPage.failure(e.toString());
    }
  }
}
