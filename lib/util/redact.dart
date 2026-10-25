/// Log redaction. Nothing sensitive may reach logs, screenshots or the repo:
/// API hash, phone number, login code, 2FA password, tokens.
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
};

/// Recursively replaces values of sensitive keys.
Object? redactValue(Object? value, {String? key}) {
  if (key != null && _secretKeys.contains(key.toLowerCase())) {
    return '[redacted]';
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
String redactText(String input) {
  var out = input;
  // 32-hex API hash / bot token fragment.
  out = out.replaceAll(RegExp(r'\b[a-fA-F0-9]{32}\b'), '[redacted-hash]');
  // E.164 phone numbers.
  out = out.replaceAll(RegExp(r'\+\d{8,15}\b'), '[redacted-phone]');
  // "password":"..." style pairs that survived as plain text.
  out = out.replaceAllMapped(
    RegExp(r'"(password|code|phone_number|api_hash)"\s*:\s*"[^"]*"'),
    (m) => '"${m.group(1)}":"[redacted]"',
  );
  return out;
}
