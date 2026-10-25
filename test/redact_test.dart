import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/util/redact.dart';

void main() {
  group('redactJson', () {
    test('masks credentials nested anywhere in a TDLib request', () {
      final request = <String, Object?>{
        '@type': 'setTdlibParameters',
        'api_id': 12345,
        'api_hash': '0123456789abcdef0123456789abcdef',
        'database_encryption_key': 'secretkey',
        'nested': <String, Object?>{
          'phone_number': '+8613800000000',
          'code': '54321',
          'password': 'twostep',
        },
      };
      final safe = redactJson(request);
      expect(safe['api_id'], 12345, reason: 'api_id is not secret');
      expect(safe['api_hash'], '[redacted]');
      expect(safe['database_encryption_key'], '[redacted]');
      final nested = safe['nested'] as Map;
      expect(nested['phone_number'], '[redacted]');
      expect(nested['code'], '[redacted]');
      expect(nested['password'], '[redacted]');
    });

    test('leaves harmless fields intact', () {
      final safe = redactJson(<String, Object?>{
        '@type': 'downloadFile',
        'file_id': 42,
        'limit': 0,
      });
      expect(safe['file_id'], 42);
      expect(safe['limit'], 0);
    });
  });

  group('redactText', () {
    test('masks 32 hex characters (api hash / bot token fragment)', () {
      final text = redactText('hash=0123456789abcdef0123456789abcdef failed');
      expect(text.contains('0123456789abcdef'), isFalse);
      expect(text, contains('[redacted-hash]'));
    });

    test('masks E.164 phone numbers', () {
      expect(redactText('PHONE +8613800000000 invalid').contains('13800000000'),
          isFalse);
    });

    test('masks quoted secret pairs echoed by TDLib errors', () {
      final text = redactText('{"code":"12345","api_hash":"abc"}');
      expect(text.contains('12345'), isFalse);
    });
  });
}
