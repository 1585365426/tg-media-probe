/// Log redaction. Nothing sensitive may reach logs, screenshots, the
/// diagnostics export or the repo: API hash, phone number, login code, 2FA
/// password, session tokens, and the TDLib database key.
///
/// Two layers, because they fail differently:
///
/// * [redactJson] works on structure — it knows a value is sensitive because of
///   its key. This is the reliable layer.
/// * [redactText] works on shape — it pattern-matches free-form strings such as
///   TDLib error messages that echo the request back. This is the backstop for
///   anything that reached a string before it was redacted.
///
/// Neither layer is allowed to throw: a logging path that fails because of an
/// odd input would take the app down at the exact moment something went wrong.
library;

const Set<String> _secretKeys = <String>{
  'api_hash',
  'apihash',
  'phone',
  'phone_number',
  'code',
  'password',
  'token',
  'access_token',
  'session',
  'database_encryption_key',
  'passcode',
  'passcode_record',
  'password_hint_from_user',
  'auth_code',
  'login_code',
  'two_step_password',
  'hint_secret',
};

/// Mask applied to a value whose key says it is sensitive.
const String redactionMask = '[redacted]';

/// Recursively replaces values of sensitive keys.
Object? redactValue(Object? value, {String? key}) {
  if (key != null && _secretKeys.contains(key.toLowerCase())) {
    return redactionMask;
  }
  if (value is Map) {
    return value.map((k, v) => MapEntry(
          k,
          redactValue(v, key: k is String ? k : null),
        ));
  }
  if (value is List) {
    return value.map((v) => redactValue(v)).toList();
  }
  return value;
}

Map<String, Object?> redactJson(Map<String, Object?> json) {
  final result = redactValue(json);
  if (result is Map) return result.cast<String, Object?>();
  return json;
}

/// Pattern based scrubbing for free-form text (exception messages, TDLib
/// errors sometimes echo the request).
///
/// Order matters: the 64-character rule runs before the 32-character one so a
/// database key is not partially matched, and the JWT rule runs before the
/// generic `token=` rule so the whole token goes, not just its prefix.
String redactText(String input) {
  var out = input;

  // A passcode record goes first: its salt is 32 hex characters and its hash is
  // 64, so the generic hex rules below would eat it in pieces and leave a
  // partially visible record. The record also leaks the iteration count and
  // salt, which is more than a log line ever needs to carry.
  out = out.replaceAll(
    RegExp(r'pbkdf2-sha256\$v=\d+\$i=\d+\$l=\d+\$s=[0-9a-f]+\$h=[0-9a-f]+'),
    '[redacted-passcode-record]',
  );

  // TDLib database key: 64 lowercase hex characters.
  out = out.replaceAll(RegExp(r'\b[a-f0-9]{64}\b'), '[redacted-dbkey]');
  // 32-hex API hash / bot token fragment.
  out = out.replaceAll(RegExp(r'\b[a-fA-F0-9]{32}\b'), '[redacted-hash]');

  // JWT: header.payload.signature, base64url in all three parts.
  out = out.replaceAll(
    RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
    '[redacted-jwt]',
  );

  // Telegram bot token: "<bot id>:<secret>" where the secret is long.
  out = out.replaceAll(
    RegExp(r'\b\d{6,12}:[A-Za-z0-9_-]{20,}\b'),
    '[redacted-bot-token]',
  );

  // Authorization: Bearer <token>
  out = out.replaceAllMapped(
    // Dart's RegExp has neither inline flags nor lookbehind: `(?i)` throws
    // "Invalid group" at construction time, which would take down the log
    // path this function exists to protect.
    RegExp(r'\bbearer\s+[A-Za-z0-9._\-+/=]{8,}', caseSensitive: false),
    (m) => 'Bearer [redacted-token]',
  );

  // query/form style token or key parameters.
  out = out.replaceAllMapped(
    RegExp(r'\b(token|api_hash|api_key|access_token|password|code)=([^&\s]+)',
        caseSensitive: false),
    (m) => '${m.group(1)}=[redacted]',
  );

  // E.164 phone numbers.
  out = out.replaceAll(RegExp(r'\+\d{8,15}\b'), '[redacted-phone]');
  // Chinese mainland mobile numbers without the country code. Deliberately not
  // a bare 11-digit rule: message ids and file sizes are also 11 digits, and
  // masking those would make diagnostics useless. Dart's RegExp has no
  // lookbehind, so the preceding character is captured and put back instead.
  out = out.replaceAllMapped(
    RegExp(r'(^|[^0-9])((?:\+?86[ -]?)?1[3-9]\d{9})(?![0-9])'),
    (m) => '${m.group(1)}[redacted-phone]',
  );

  // "password":"..." style pairs that survived as plain text.
  out = out.replaceAllMapped(
    RegExp(r'"(password|code|phone_number|api_hash|token)"\s*:\s*"[^"]*"'),
    (m) => '"${m.group(1)}":"[redacted]"',
  );

  // e-mail addresses (the email login flow sends them).
  out = out.replaceAll(
    RegExp(r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'),
    '[redacted-email]',
  );

  return out;
}

/// Redacts a structured diagnostics payload: sensitive keys first, then every
/// remaining string is pattern-scrubbed and every number is left alone.
///
/// Used by the "export diagnostics" action. Keys are preserved so the export
/// still says *what* was removed.
Map<String, Object?> redactDiagnostics(Map<String, Object?> input) {
  final structured = redactJson(input);
  final scrubbed = _scrubStrings(structured);
  if (scrubbed is Map) return scrubbed.cast<String, Object?>();
  return structured;
}

Object? _scrubStrings(Object? value) {
  if (value is Map) {
    // Rebuilt as Map<String, Object?> rather than mapped in place: the stored
    // payload is untyped after the first pass, and a nested map that keeps
    // Object? keys fails every caller that casts it back.
    final out = <String, Object?>{};
    value.forEach((k, v) => out['$k'] = _scrubStrings(v));
    return out;
  }
  if (value is List) {
    return value.map<Object?>((v) => _scrubStrings(v)).toList();
  }
  if (value is String) {
    if (value == redactionMask) return value;
    return redactText(value);
  }
  return value;
}

/// True when [text] still contains something that looks like a secret.
///
/// A pre-flight check for the diagnostics export: if this returns true after
/// redaction, the export is refused rather than shipped. Failing closed on a
/// leak is cheap; a leaked key is not recoverable.
bool mayContainSecret(String text) {
  if (RegExp(r'\b[a-f0-9]{64}\b').hasMatch(text)) return true;
  if (RegExp(r'\b[a-fA-F0-9]{32}\b').hasMatch(text)) return true;
  if (RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.').hasMatch(text)) return true;
  if (RegExp(r'\b\d{6,12}:[A-Za-z0-9_-]{20,}\b').hasMatch(text)) return true;
  if (RegExp(r'(^|[^0-9])1[3-9]\d{9}(?![0-9])').hasMatch(text)) return true;
  if (RegExp(r'pbkdf2-sha256\$v=').hasMatch(text)) return true;
  return false;
}
