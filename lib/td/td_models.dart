/// Parsers for the subset of TDLib objects the probe needs.
///
/// All parsers tolerate missing keys: TDLib adds/removes fields between
/// versions, and a hard cast would turn a schema change into a crash.
library;

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

String? _asString(Object? v) => v is String ? v : null;

bool _asBool(Object? v, {bool fallback = false}) => v is bool ? v : fallback;

List<Map<String, Object?>> _asList(Object? v) {
  if (v is List) {
    return v.whereType<Map>().map((e) => e.cast<String, Object?>()).toList();
  }
  return const <Map<String, Object?>>[];
}

Map<String, Object?> _asMap(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

enum AuthStage {
  waitTdlibParameters,
  waitPhoneNumber,
  waitCode,
  waitPassword,
  waitOtherDeviceConfirmation,
  ready,
  loggingOut,
  closed,
  unknown,
}

class AuthState {
  const AuthState(this.rawType);

  /// Raw `@type` value from TDLib, kept verbatim for diagnostics.
  final String rawType;

  static AuthState fromJson(Map<String, Object?> json) =>
      AuthState(_asString(json['@type']) ?? 'unknown');

  AuthStage get stage {
    switch (rawType) {
      case 'authorizationStateWaitTdlibParameters':
        return AuthStage.waitTdlibParameters;
      case 'authorizationStateWaitPhoneNumber':
        return AuthStage.waitPhoneNumber;
      case 'authorizationStateWaitCode':
        return AuthStage.waitCode;
      case 'authorizationStateWaitPassword':
        return AuthStage.waitPassword;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        return AuthStage.waitOtherDeviceConfirmation;
      case 'authorizationStateReady':
        return AuthStage.ready;
      case 'authorizationStateLoggingOut':
        return AuthStage.loggingOut;
      case 'authorizationStateClosed':
        return AuthStage.closed;
      default:
        return AuthStage.unknown;
    }
  }

  @override
  String toString() => rawType;
}

class ChatSummary {
  const ChatSummary({
    required this.id,
    required this.title,
    required this.type,
    required this.isChannel,
    required this.username,
    required this.hasProtectedContent,
  });

  final int id;
  final String title;

  /// `chatTypeSupergroup`, `chatTypePrivate`, ...
  final String type;
  final bool isChannel;
  final String? username;
  final bool hasProtectedContent;

  static ChatSummary fromJson(Map<String, Object?> json) {
    final chatType = _asMap(json['type']);
    final usernames = _asMap(json['usernames']);
    final active = usernames['active_usernames'];
    final firstUsername =
        active is List && active.isNotEmpty ? _asString(active.first) : null;
    return ChatSummary(
      id: _asInt(json['id']) ?? 0,
      title: _asString(json['title']) ?? '(no title)',
      type: _asString(chatType['@type']) ?? 'unknown',
      isChannel: _asBool(chatType['is_channel']),
      username: firstUsername,
      hasProtectedContent: _asBool(json['has_protected_content']),
    );
  }

  @override
  String toString() => 'ChatSummary($id, $title, $type, channel=$isChannel)';
}

/// Metadata of a video as reported by TDLib.
///
/// Note: TDLib's `video` object has no rotation field. Rotation has to be read
/// from the media file itself (AVFoundation track transform) after the file is
/// available locally, so [hasRotationInfo] is always false at this layer.
class VideoMeta {
  const VideoMeta({
    required this.width,
    required this.height,
    required this.durationSeconds,
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.expectedSize,
    required this.downloadedSize,
    required this.isDownloaded,
    required this.localPath,
    required this.supportsStreaming,
    this.rotationDegrees,
  });

  final int? width;
  final int? height;
  final int? durationSeconds;
  final int fileId;
  final String? fileName;
  final String? mimeType;
  final int expectedSize;
  final int downloadedSize;
  final bool isDownloaded;

  /// Absolute sandbox path reported by TDLib; empty until bytes exist locally.
  final String localPath;
  final bool supportsStreaming;

  /// Only set when rotation was read from the local file, never guessed.
  final int? rotationDegrees;

  bool get hasRotationInfo => rotationDegrees != null;

  static VideoMeta? fromMessage(Map<String, Object?> message) {
    final content = _asMap(message['content']);
    if (_asString(content['@type']) != 'messageVideo') return null;
    final video = _asMap(content['video']);
    if (video.isEmpty) return null;
    final file = _asMap(video['video']);
    final local = _asMap(file['local']);
    return VideoMeta(
      width: _asInt(video['width']),
      height: _asInt(video['height']),
      durationSeconds: _asInt(video['duration']),
      fileId: _asInt(file['id']) ?? 0,
      fileName: _asString(video['file_name']),
      mimeType: _asString(video['mime_type']),
      expectedSize: _asInt(file['expected_size']) ?? 0,
      downloadedSize: _asInt(local['downloaded_size']) ?? 0,
      isDownloaded: _asBool(local['is_downloading_completed']),
      localPath: _asString(local['path']) ?? '',
      supportsStreaming: _asBool(video['supports_streaming']),
    );
  }

  VideoMeta withRotation(int? degrees) => VideoMeta(
        width: width,
        height: height,
        durationSeconds: durationSeconds,
        fileId: fileId,
        fileName: fileName,
        mimeType: mimeType,
        expectedSize: expectedSize,
        downloadedSize: downloadedSize,
        isDownloaded: isDownloaded,
        localPath: localPath,
        supportsStreaming: supportsStreaming,
        rotationDegrees: degrees,
      );

  @override
  String toString() =>
      'VideoMeta(${width}x$height, ${durationSeconds}s, ${expectedSize}B, '
      'fileId=$fileId, downloaded=$isDownloaded)';
}

class FileState {
  const FileState({
    required this.id,
    required this.size,
    required this.expectedSize,
    required this.downloadedSize,
    required this.isCompleted,
    required this.path,
    required this.canBeDownloaded,
  });

  final int id;
  final int size;
  final int expectedSize;
  final int downloadedSize;
  final bool isCompleted;
  final String path;
  final bool canBeDownloaded;

  static FileState fromJson(Map<String, Object?> json) {
    final local = _asMap(json['local']);
    return FileState(
      id: _asInt(json['id']) ?? 0,
      size: _asInt(json['size']) ?? 0,
      expectedSize: _asInt(json['expected_size']) ?? 0,
      downloadedSize: _asInt(local['downloaded_size']) ?? 0,
      isCompleted: _asBool(local['is_downloading_completed']),
      path: _asString(local['path']) ?? '',
      canBeDownloaded: _asBool(local['can_be_downloaded']),
    );
  }
}

/// Extracts a [FileState] from a `getFile` response.
///
/// `getFile` returns the `file` object directly (no wrapper), which is why this
/// cannot reuse the `updateFile` path — that one has to unwrap `file` first.
FileState? fileFromResponse(Map<String, Object?> json) {
  if (_asString(json['@type']) != 'file') return null;
  return FileState.fromJson(json);
}

/// The signed-in account, as far as the settings page needs it.
///
/// Parsed from `getMe`. Nothing here is derived: a missing field stays null and
/// the row renders "—" rather than an invented placeholder.
class AccountInfo {
  const AccountInfo({
    required this.userId,
    this.firstName = '',
    this.lastName = '',
    this.username,
    this.phoneNumber,
  });

  final int userId;
  final String firstName;
  final String lastName;
  final String? username;

  /// Raw E.164 number from TDLib. Masked before display; never logged.
  final String? phoneNumber;

  String get displayName {
    final full = '$firstName $lastName'.trim();
    if (full.isNotEmpty) return full;
    if (username != null && username!.isNotEmpty) return '@$username';
    return 'Telegram 账号';
  }

  String get handle {
    if (username != null && username!.isNotEmpty) return '@$username';
    return '#$userId';
  }

  /// `+86 138****0000` style masking. Returns null when there is no number, so
  /// the caller can omit the row instead of printing "null".
  String? get maskedPhone {
    final phone = phoneNumber;
    if (phone == null || phone.isEmpty) return null;
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) return '****';
    final head = digits.substring(0, digits.length > 11 ? 4 : 3);
    final tail = digits.substring(digits.length - 4);
    final prefix = phone.startsWith('+') ? '+' : '';
    return '$prefix$head****$tail';
  }

  static AccountInfo? fromJson(Map<String, Object?> json) {
    if (_asString(json['@type']) != 'user') return null;
    final id = _asInt(json['id']);
    if (id == null) return null;
    final usernames = _asMap(json['usernames']);
    final active = usernames['active_usernames'];
    final firstUsername =
        active is List && active.isNotEmpty ? _asString(active.first) : null;
    return AccountInfo(
      userId: id,
      firstName: _asString(json['first_name']) ?? '',
      lastName: _asString(json['last_name']) ?? '',
      username: firstUsername ?? _asString(usernames['editable_username']),
      phoneNumber: _asString(json['phone_number']),
    );
  }
}

/// Extracts an [AccountInfo] from a `getMe` response.
AccountInfo? accountFromResponse(Map<String, Object?> json) =>
    AccountInfo.fromJson(json);

/// Extracts `messages` from a `getChatHistory` response, tolerating `error`.
List<Map<String, Object?>> messagesFromResponse(Map<String, Object?> json) {
  if (_asString(json['@type']) == 'error') return const <Map<String, Object?>>[];
  return _asList(json['messages']);
}

/// Extracts `chat_ids` from a `getChats` response.
List<int> chatIdsFromResponse(Map<String, Object?> json) {
  final ids = json['chat_ids'];
  if (ids is List) {
    return ids.map(_asInt).whereType<int>().toList();
  }
  return const <int>[];
}

/// Extracts `chats` from a `getChat` response; TDLib returns a single object.
ChatSummary? chatFromResponse(Map<String, Object?> json) {
  if (_asString(json['@type']) == 'chat') return ChatSummary.fromJson(json);
  return null;
}

String? errorText(Map<String, Object?> json) {
  if (_asString(json['@type']) != 'error') return null;
  final code = _asInt(json['code']);
  final message = _asString(json['message']) ?? 'unknown TDLib error';
  return 'TDLib error ${code ?? '?'}: $message';
}
