/// Turns whatever came back from TDLib into one of six states a screen can
/// render, so "permission denied" never shows up as a generic "出错了".
///
/// Why classification lives here instead of in each page: the same failure has
/// to read the same way on the channel list, the channel detail and the feed.
/// When it does not, users report the bug three times as three different bugs.
library;

import 'dart:async';
import 'dart:io';

/// What went wrong, in words a screen can act on.
enum RequestFailure {
  /// No failure. The response was not an error.
  none,

  /// TDLib says 403 / CHAT_FORBIDDEN / CHANNEL_PRIVATE: the account is signed
  /// in but is not allowed to read this chat. Retrying will not help, so the
  /// UI must not offer a retry button that is guaranteed to fail.
  permissionDenied,

  /// 401 / AUTHORIZATION_STATE: the session ended (revoked, logged out on
  /// another device, or the keychain key no longer matches). The only fix is
  /// to sign in again, so the screen points at that instead of a retry.
  sessionExpired,

  /// 429 / FLOOD_WAIT / 420: rate limited. Retrying immediately makes it
  /// worse, so the UI tells the user how long to wait.
  rateLimited,

  /// No connection, DNS failure, timeout. Retrying is exactly the right move.
  offline,

  /// Anything else. Retry is offered but not promised.
  generic,
}

/// TDLib error codes that mean "not allowed", regardless of the message text.
/// 400 is not enough on its own: 400 also covers "chat not found", which is a
/// different fix.
const Set<String> _permissionFragments = <String>{
  'CHAT_FORBIDDEN',
  'CHANNEL_PRIVATE',
  'CHANNEL_INVALID',
  'USER_BANNED_IN_CHANNEL',
  'CHAT_ADMIN_REQUIRED',
  'MESSAGE_DELETE_FORBIDDEN',
  'CHAT_WRITE_FORBIDDEN',
};

const Set<String> _sessionFragments = <String>{
  'AUTH_KEY_UNREGISTERED',
  'AUTH_KEY_INVALID',
  'AUTH_KEY_EMPTY',
  'SESSION_REVOKED',
  'USER_DEACTIVATED',
  'PHONE_NUMBER_BANNED',
};

const Set<String> _rateLimitFragments = <String>{
  'FLOOD_WAIT',
  'TOO_MANY_REQUESTS',
};

/// Classifies a TDLib error by code and message.
///
/// Code first, message second: TDLib's `code` is stable, its message is a
/// translated sentence that changes between versions.
RequestFailure classifyTdError({int? code, String? message}) {
  if (code == null && message == null) return RequestFailure.none;
  final text = (message ?? '').toUpperCase();

  for (final fragment in _sessionFragments) {
    if (text.contains(fragment)) return RequestFailure.sessionExpired;
  }
  if (code == 401) return RequestFailure.sessionExpired;

  for (final fragment in _rateLimitFragments) {
    if (text.contains(fragment)) return RequestFailure.rateLimited;
  }
  if (code == 429 || code == 420) return RequestFailure.rateLimited;

  for (final fragment in _permissionFragments) {
    if (text.contains(fragment)) return RequestFailure.permissionDenied;
  }
  if (code == 403) return RequestFailure.permissionDenied;

  return RequestFailure.generic;
}

/// Classifies an error object that reached a `catch` block.
///
/// Accepts the shapes this app actually produces: a raw TDLib response map,
/// [TimeoutException], [SocketException], and anything whose `toString()`
/// carries a TDLib code (that is how `ChannelDirectoryException` is built).
RequestFailure classifyFailure(Object error) {
  if (error is Map) {
    final code = error['code'];
    final message = error['message'];
    return classifyTdError(
      code: code is int ? code : int.tryParse('${code ?? ''}'),
      message: message is String ? message : null,
    );
  }
  if (error is TimeoutException) return RequestFailure.offline;
  if (error is SocketException) return RequestFailure.offline;
  if (error is HttpException) return RequestFailure.offline;

  final text = error.toString();
  final upper = text.toUpperCase();
  if (upper.contains('SOCKETEXCEPTION') ||
      upper.contains('CONNECTION REFUSED') ||
      upper.contains('NETWORK IS UNREACHABLE') ||
      upper.contains('FAILED HOST LOOKUP') ||
      upper.contains('CONNECTION CLOSED') ||
      upper.contains('TIMEOUT')) {
    return RequestFailure.offline;
  }

  final codeMatch = RegExp(r'(?:CODE|ERROR)\s*[:=]?\s*(\d{3})').firstMatch(upper);
  return classifyTdError(
    code: codeMatch == null ? null : int.tryParse(codeMatch.group(1)!),
    message: text,
  );
}

/// Short title for a failure. Deliberately says what the user can do, not what
/// the code is.
String failureTitle(RequestFailure failure) => switch (failure) {
      RequestFailure.none => '',
      RequestFailure.permissionDenied => '没有权限读取这个内容',
      RequestFailure.sessionExpired => '登录已失效',
      RequestFailure.rateLimited => '请求过于频繁',
      RequestFailure.offline => '网络不可用',
      RequestFailure.generic => '读取失败',
    };

/// One sentence of guidance, matching [failureTitle].
String failureHint(RequestFailure failure) => switch (failure) {
      RequestFailure.none => '',
      RequestFailure.permissionDenied =>
        '当前账号不是该频道的成员，或频道已限制转发。换一个频道，或先在 Telegram 里加入。',
      RequestFailure.sessionExpired => '需要重新登录 Telegram 才能继续。',
      RequestFailure.rateLimited => '稍等一会儿再试；连续重试会让等待时间变长。',
      RequestFailure.offline => '检查网络后重试。已缓存的内容仍可浏览。',
      RequestFailure.generic => '重试一次；如果一直失败，导出诊断信息。',
    };

/// Whether a retry button makes sense. Retrying a permission error just fails
/// again, and retrying a dead session cannot work until the user signs in.
bool isRetryable(RequestFailure failure) =>
    failure == RequestFailure.offline ||
    failure == RequestFailure.generic ||
    failure == RequestFailure.rateLimited;
