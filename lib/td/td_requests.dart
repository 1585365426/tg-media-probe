/// TDLib request builders.
///
/// Every builder returns a plain JSON map so the exact wire format can be
/// asserted in tests against the official `td_api.tl` schema.
/// Read-only by contract: no builder in this file mutates Telegram cloud data.
library;

Map<String, Object?> setTdlibParameters({
  required int apiId,
  required String apiHash,
  required String databaseDirectory,
  required String filesDirectory,
  required String databaseEncryptionKey,
  String systemLanguageCode = 'zh-hans',
  String deviceModel = 'iPhone',
  String systemVersion = 'iOS',
  String applicationVersion = '0.1.0',
}) {
  // An empty key means TDLib writes the whole local database in plaintext.
  // Refusing here is the single choke point that keeps that from happening by
  // accident when a caller forgets the argument's value.
  if (databaseEncryptionKey.isEmpty) {
    throw ArgumentError.value(databaseEncryptionKey, 'databaseEncryptionKey',
        'TDLib database key must not be empty');
  }
  return <String, Object?>{
    '@type': 'setTdlibParameters',
    // Field order and names follow td_api.tl exactly; TDLib rejects unknown
    // or missing parameters, so this map is schema-checked by tests.
    'use_test_dc': false,
    'database_directory': databaseDirectory,
    'files_directory': filesDirectory,
    'database_encryption_key': databaseEncryptionKey,
    'use_file_database': true,
    'use_chat_info_database': true,
    'use_message_database': true,
    'use_secret_chats': false,
    'api_id': apiId,
    'api_hash': apiHash,
    'system_language_code': systemLanguageCode,
    'device_model': deviceModel,
    'system_version': systemVersion,
    'application_version': applicationVersion,
  };
}

Map<String, Object?> getAuthorizationState() => <String, Object?>{
      '@type': 'getAuthorizationState',
    };

Map<String, Object?> setAuthenticationPhoneNumber(String phoneNumber) =>
    <String, Object?>{
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber,
      'settings': <String, Object?>{
        '@type': 'phoneNumberAuthenticationSettings',
        'allow_flash_call': false,
        'is_current_phone_number': true,
        'allow_sms_retriever_api': false,
        'authentication_tokens': <Object?>[],
      },
    };

Map<String, Object?> checkAuthenticationCode(String code) => <String, Object?>{
      '@type': 'checkAuthenticationCode',
      'code': code,
    };

Map<String, Object?> checkAuthenticationPassword(String password) =>
    <String, Object?>{
      '@type': 'checkAuthenticationPassword',
      'password': password,
    };

/// Chat list id for the main list. Channels the account is a member of appear
/// here; private channels the account never joined are not returned by design.
Map<String, Object?> chatListMain() => <String, Object?>{
      '@type': 'chatListMain',
    };

Map<String, Object?> getChats({int limit = 100}) => <String, Object?>{
      '@type': 'getChats',
      'chat_list': chatListMain(),
      'limit': limit,
    };

Map<String, Object?> getChat(int chatId) => <String, Object?>{
      '@type': 'getChat',
      'chat_id': chatId,
    };

/// [fromMessageId] = 0 starts from the newest message; use the oldest seen
/// message id for incremental pagination.
Map<String, Object?> getChatHistory({
  required int chatId,
  int fromMessageId = 0,
  int offset = 0,
  int limit = 50,
  bool onlyLocal = false,
}) =>
    <String, Object?>{
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': fromMessageId,
      'offset': offset,
      'limit': limit,
      'only_local': onlyLocal,
    };

Map<String, Object?> getMessage({required int chatId, required int messageId}) =>
    <String, Object?>{
      '@type': 'getMessage',
      'chat_id': chatId,
      'message_id': messageId,
    };

Map<String, Object?> getFile(int fileId) => <String, Object?>{
      '@type': 'getFile',
      'file_id': fileId,
    };

/// Starts or resumes a download. limit = 0 means "to the end of file".
/// [offset] = 0 restarts; a non-zero offset resumes a partial download, which
/// TDLib keeps in its own file database.
Map<String, Object?> downloadFile({
  required int fileId,
  int priority = 32,
  int offset = 0,
  int limit = 0,
  bool synchronous = false,
}) =>
    <String, Object?>{
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': priority,
      'offset': offset,
      'limit': limit,
      'synchronous': synchronous,
    };

Map<String, Object?> cancelDownloadFile({
  required int fileId,
  bool onlyIfPending = false,
}) =>
    <String, Object?>{
      '@type': 'cancelDownloadFile',
      'file_id': fileId,
      'only_if_pending': onlyIfPending,
    };

Map<String, Object?> logOut() => <String, Object?>{'@type': 'logOut'};

Map<String, Object?> close() => <String, Object?>{'@type': 'close'};

Map<String, Object?> getMe() => <String, Object?>{'@type': 'getMe'};
