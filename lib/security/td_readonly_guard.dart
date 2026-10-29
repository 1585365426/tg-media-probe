/// Read-only enforcement for Telegram cloud data.
///
/// TG Media mirrors cloud data into a local index and never writes back. That
/// is not a UI convention: every request that leaves the app passes through
/// [TdClient.request], which calls [TdReadOnlyGuard.assertAllowed] before the
/// payload is serialised. A cloud-mutating method therefore cannot be sent even
/// if some future code path tries.
///
/// `readonly_guard_test.dart` additionally scans every source file under `lib/`
/// for the method names below, so a forbidden call fails the build.
library;

class TdReadOnlyViolation implements Exception {
  const TdReadOnlyViolation(
    this.method, {
    this.source,
    this.reason = 'is a cloud-mutating TDLib method; TG Media is read-only',
  });

  final Object? method;
  final String? source;

  /// Why the method was refused. Kept separate from the message so the
  /// "known write" and "unclassified" cases read differently.
  final String reason;

  @override
  String toString() =>
      'TdReadOnlyViolation: ${method ?? '<missing @type>'} $reason'
      '${source == null ? '' : ' ($source)'}';
}

class TdReadOnlyGuard {
  const TdReadOnlyGuard._();

  /// TDLib methods that create, modify or delete anything on Telegram's side.
  ///
  /// The list is intentionally broader than "delete messages": editing, sending,
  /// forwarding, joining/leaving and chat administration are all writes to the
  /// server and none of them belong in a mirroring client.
  static const Set<String> cloudMutatingMethods = <String>{
    // ---- messages: delete / edit / send / forward ----
    'deleteMessages',
    'deleteScheduledMessages',
    'deleteChatHistory',
    'deleteMessage', // not a real TDLib method; listed so typos are caught too
    'editMessageText',
    'editMessageCaption',
    'editMessageMedia',
    'editMessageReplyMarkup',
    'editMessageSchedulingState',
    'editInlineMessageText',
    'editInlineMessageCaption',
    'editInlineMessageMedia',
    'editInlineMessageReplyMarkup',
    'editInlineMessageSchedulingState',
    'forwardMessages',
    'sendMessage',
    'sendMessageAlbum',
    'sendInlineQueryResultMessage',
    'sendQuickReplyShortcutMessages',
    'resendMessages',
    'addLocalMessage',
    'setGameScore',
    // ---- chats and channels: lifecycle and administration ----
    'deleteChat',
    'deleteSupergroup',
    'createNewSecretChat',
    'createPrivateChat',
    'createBasicGroupChat',
    'createSupergroupChat',
    'joinChat',
    'leaveChat',
    'addChatMembers',
    'removeChatMember',
    'banChatMember',
    'unbanChatMember',
    'setChatMemberStatus',
    'setChatTitle',
    'setChatPhoto',
    'setChatDescription',
    'setChatPermissions',
    'setChatDraftMessage',
    'setChatMessageAutoDeleteTime',
    'setChatSlowModeDelay',
    'setChatClientData',
    'setChatNotificationSettings',
    'setChatTheme',
    'setChatAvailableReactions',
    'setChatLocation',
    'setChatDiscussionGroup',
    'toggleChatIsPinned',
    'toggleChatIsMarkedAsUnread',
    'toggleChatHasProtectedContent',
    'pinChatMessage',
    'unpinChatMessage',
    'unpinAllChatMessages',
    'deleteChatReplyMarkup',
    'clearAllDraftMessages',
    // ---- account / profile ----
    'setName',
    'setBio',
    'setUsername',
    'setWebsite',
    'setProfilePhoto',
    'deleteProfilePhoto',
    'setEmojiStatus',
    'setAccentColor',
  };

  /// Methods whose name mentions deletion but which only touch **local** data.
  /// Kept as an explicit allowlist so the distinction is documented rather than
  /// implied by omission.
  static const Set<String> localOnlyMethods = <String>{
    'deleteFile', // deletes the cached file from the local file database only
    // Fetching or cancelling a byte transfer changes TDLib's local file store
    // and nothing on the server: no message is touched, no chat is modified.
    'downloadFile',
    'cancelDownloadFile',
    'removeFileFromDownloads',
    'removeTopChat',
    'removeSavedAnimation',
    'removeFavoriteSticker',
    'removeRecentlyFoundChat',
  };

  /// Every TDLib method this app is allowed to send.
  ///
  /// This is the positive list, not a denylist. A denylist can only block the
  /// methods someone remembered to add; the first new TDLib write verb would
  /// sail through a guard that only checks what it knows. Anything absent here
  /// is refused, so adding a capability requires editing this set on purpose.
  ///
  /// Contents are reads plus the session/authentication calls that necessarily
  /// precede them — none of those write to a chat, a message or an account.
  static const Set<String> readOnlyMethods = <String>{
    // session setup and login (no cloud data is written)
    'setTdlibParameters',
    'getAuthorizationState',
    'setAuthenticationPhoneNumber',
    'checkAuthenticationCode',
    'checkAuthenticationPassword',
    'logOut',
    'close',
    // reads
    'getMe',
    'getChats',
    'getChat',
    'getChatHistory',
    'getMessage',
    'getFile',
    'getRemoteFile',
    'getOption',
    'getUser',
    'getSupergroup',
    'getBasicGroup',
    'getStorageStatistics',
    'getNetworkStatistics',
    'loadChats',
    'searchChats',
    'searchChatMessages',
    // byte-level reads: local file store, no cloud data is written
    'getFileDownloadedPrefixSize',
    'readFilePart',
  };

  /// True for a method that is either an allowed read or an allowed local
  /// operation.
  static bool isAllowed(String type) =>
      readOnlyMethods.contains(type) || localOnlyMethods.contains(type);

  static bool isCloudMutating(Object? type) =>
      type is String && cloudMutatingMethods.contains(type);

  static bool isLocalOnly(String type) => localOnlyMethods.contains(type);

  /// Throws [TdReadOnlyViolation] for anything that is not a read.
  ///
  /// Unknown method names are rejected as well: a new TDLib method has to be
  /// classified deliberately before it can be used.
  static void assertAllowed(Object? type, {String? source}) {
    if (type is! String || type.isEmpty) {
      throw TdReadOnlyViolation(type, source: source);
    }
    if (cloudMutatingMethods.contains(type)) {
      throw TdReadOnlyViolation(type, source: source);
    }
    if (!isAllowed(type)) {
      // Reachable only with a method nobody classified. The message says so
      // instead of calling a read "mutating", so the fix is obvious.
      throw TdReadOnlyViolation(type,
          source: source, reason: 'is not on the read-only allowlist');
    }
  }

  /// Names that must never appear anywhere in `lib/` outside this file.
  static List<String> get scanPatterns => cloudMutatingMethods.toList()..sort();
}
