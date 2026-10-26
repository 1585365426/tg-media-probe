import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/util/redact.dart';

void main() {
  group('redactText: credential shapes', () {
    test('a 64-character TDLib database key is masked whole', () {
      const key =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final text = redactText('key=$key');
      expect(text.contains(key), isFalse);
      expect(text, contains('[redacted-dbkey]'));
      // Must not be split into two 32-character halves: a half-masked key is
      // still half a key.
      expect(text.contains('0123456789abcdef'), isFalse);
    });

    test('a JWT is masked, not just its header', () {
      const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
          '.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
          '.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      final text = redactText('Authorization: $jwt');
      expect(text.contains('eyJhbGciOiJIUzI1NiIs'), isFalse);
      expect(text, contains('[redacted-jwt]'));
    });

    test('a Telegram bot token is masked', () {
      final text =
          redactText('token 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw rejected');
      expect(text.contains('AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw'), isFalse);
      expect(text, contains('[redacted-bot-token]'));
    });

    test('a Bearer header is masked regardless of case', () {
      for (final header in <String>[
        'Bearer abcdefghijklmnop',
        'bearer abcdefghijklmnop',
        'BEARER abcdefghijklmnop',
      ]) {
        final text = redactText(header);
        expect(text.contains('abcdefghijklmnop'), isFalse, reason: header);
      }
    });

    test('a token in a query string is masked', () {
      final text = redactText('GET /x?token=abc123def456&other=1');
      expect(text.contains('abc123def456'), isFalse);
      expect(text, contains('other=1'));
    });

    test('a stored passcode record is masked', () {
      const record =
          'pbkdf2-sha256\$v=1\$i=120000\$l=32\$s=00112233445566778899aabbccddeeff'
          '\$h=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
      final text = redactText('lock=$record');
      expect(text.contains('pbkdf2-sha256'), isFalse);
      expect(text, contains('[redacted-passcode-record]'));
    });
  });

  group('redactText: personal data', () {
    test('a mainland mobile number without a country code is masked', () {
      final text = redactText('phone 13800001234 failed');
      expect(text.contains('13800001234'), isFalse);
      expect(text, contains('[redacted-phone]'));
    });

    test('a mainland number with +86 is masked by the E.164 rule first', () {
      final text = redactText('phone +8613800001234 failed');
      expect(text.contains('13800001234'), isFalse);
      expect(text, contains('[redacted-phone]'));
    });

    test('an e-mail address is masked', () {
      final text = redactText('code sent to someone@example.com');
      expect(text.contains('someone@example.com'), isFalse);
      expect(text, contains('[redacted-email]'));
    });
  });

  group('redactText: does not eat harmless numbers', () {
    test('a message id that happens to be 11 digits survives', () {
      // Second digit is 2, so it cannot be a mainland mobile prefix. Masking it
      // would make every log line useless for support.
      final text = redactText('message_id 12345678901 not found');
      expect(text, contains('12345678901'));
    });

    test('a file size survives', () {
      final text = redactText('file size 1234567890 bytes');
      expect(text, contains('1234567890'));
    });

    test('a chat id survives', () {
      final text = redactText('chat -1001234567890 channel');
      expect(text, contains('-1001234567890'));
    });

    test('an ordinary sentence is untouched', () {
      const input = '下载失败：网络中断，请重试（错误码 400）';
      expect(redactText(input), input);
    });
  });

  group('redactText is idempotent', () {
    test('running it twice changes nothing further', () {
      const input = 'api_hash=0123456789abcdef0123456789abcdef '
          'phone +8613800001234 '
          'Authorization: Bearer abcdefghijklmnop';
      final once = redactText(input);
      final twice = redactText(once);
      expect(twice, once);
    });
  });

  group('redactDiagnostics', () {
    test('masks by key, then scrubs the remaining strings', () {
      final payload = <String, Object?>{
        'api_id': 12345,
        'api_hash': '0123456789abcdef0123456789abcdef',
        'phone_number': '+8613800001234',
        'note': 'logged in with +8613800001234 from 13800001234',
        'nested': <String, Object?>{
          'password': 'hunter2',
          'detail': 'echo: {"code":"54321"}',
        },
        'list': <Object?>[
          'Bearer abcdefghijklmnop',
          <String, Object?>{'code': '99999'},
        ],
      };

      final safe = redactDiagnostics(payload);

      expect(safe['api_id'], 12345, reason: 'api_id is not secret');
      expect(safe['api_hash'], '[redacted]');
      expect(safe['phone_number'], '[redacted]');
      expect(safe['note'], isNot(contains('13800001234')));
      expect(safe['note'], isNot(contains('138000001234')));

      final nested = safe['nested']! as Map<String, Object?>;
      expect(nested['password'], '[redacted]');
      expect(nested['detail'], isNot(contains('54321')));

      final list = safe['list']! as List<Object?>;
      expect(list[0], isNot(contains('abcdefghijklmnop')));
      expect((list[1]! as Map)['code'], '[redacted]');
    });

    test('a bare secret inside a harmless key is still caught', () {
      final safe = redactDiagnostics(<String, Object?>{
        'message': 'request failed, key 0123456789abcdef0123456789abcdef',
      });
      expect(safe['message'], isNot(contains('0123456789abcdef')));
    });

    test('non-string values are preserved as-is', () {
      final safe = redactDiagnostics(<String, Object?>{
        'count': 7,
        'ok': true,
        'ratio': 0.5,
        'nothing': null,
      });
      expect(safe['count'], 7);
      expect(safe['ok'], isTrue);
      expect(safe['ratio'], 0.5);
      expect(safe['nothing'], isNull);
    });
  });

  group('mayContainSecret', () {
    test('flags each shape the scrubber knows about', () {
      const samples = <String>[
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        '0123456789abcdef0123456789abcdef',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij',
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw',
        'call 13800001234 now',
        'pbkdf2-sha256\$v=1\$i=1',
      ];
      for (final sample in samples) {
        expect(mayContainSecret(sample), isTrue, reason: sample);
      }
    });

    test('does not flag ordinary text', () {
      for (final sample in <String>[
        '下载失败：网络中断',
        'message_id 12345678901',
        'file size 1234567890 bytes',
        'chat -1001234567890',
      ]) {
        expect(mayContainSecret(sample), isFalse, reason: sample);
      }
    });

    test('redacted output no longer trips the check', () {
      const input = 'api_hash=0123456789abcdef0123456789abcdef phone +8613800001234';
      expect(mayContainSecret(redactText(input)), isFalse);
    });
  });
}
