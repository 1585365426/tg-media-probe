import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/util/sha256.dart';

String hex(List<int> bytes) => bytesToHex(bytes);

void main() {
  group('sha256 (FIPS 180-4 / RFC 6234 vectors)', () {
    test('empty input', () {
      expect(
        hex(sha256(const <int>[])),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc"', () {
      expect(
        hex(sha256(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('448-bit message that forces a second padding block', () {
      expect(
        hex(sha256(utf8.encode(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('56-byte input lands exactly on the padding boundary', () {
      // 56 bytes leaves room for 0x80 but not for the 8-byte length, so the
      // padding has to spill into a second block. Off-by-one here is silent.
      final input = utf8.encode('a' * 56);
      expect(input.length, 56);
      expect(
        hex(sha256(input)),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );
    });

    test('55-byte input stays in one block', () {
      final input = utf8.encode('a' * 55);
      expect(
        hex(sha256(input)),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      );
    });

    test('million-a vector', () {
      final input = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
      expect(
        hex(sha256(input)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('binary input is hashed as bytes, not as text', () {
      // 0xFF is not valid UTF-8 on its own. If the implementation tried to
      // decode the input as a string this would throw or normalise the byte.
      final raw = <int>[0x00, 0xFF, 0x80, 0x7F];
      final digest = sha256(raw);
      expect(digest.length, 32);
      // Same length, one byte different, must produce a completely different
      // digest: any per-byte early exit or truncation would show up here.
      final altered = sha256(<int>[0x00, 0xFF, 0x80, 0x7E]);
      expect(hex(digest), isNot(hex(altered)));
      expect(sha256(raw), digest);
    });
  });

  group('hmacSha256 (RFC 4231 vectors)', () {
    test('case 1: 20-byte key, "Hi There"', () {
      expect(
        hex(hmacSha256(
          List<int>.filled(20, 0x0b),
          utf8.encode('Hi There'),
        )),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });

    test('case 2: short key, "what do ya want for nothing?"', () {
      expect(
        hex(hmacSha256(
          utf8.encode('Jefe'),
          utf8.encode('what do ya want for nothing?'),
        )),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });

    test('case 6: key longer than the block size is hashed first', () {
      expect(
        hex(hmacSha256(
          List<int>.filled(131, 0xaa),
          utf8.encode('Test Using Larger Than Block-Size Key - Hash Key First'),
        )),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('pbkdf2HmacSha256', () {
    test('known vector: password/salt/1 iteration', () {
      expect(
        hex(pbkdf2HmacSha256(
          password: utf8.encode('password'),
          salt: utf8.encode('salt'),
          iterations: 1,
          keyLength: 32,
        )),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('known vector: password/salt/2 iterations', () {
      expect(
        hex(pbkdf2HmacSha256(
          password: utf8.encode('password'),
          salt: utf8.encode('salt'),
          iterations: 2,
          keyLength: 32,
        )),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('known vector: password/salt/4096 iterations', () {
      expect(
        hex(pbkdf2HmacSha256(
          password: utf8.encode('password'),
          salt: utf8.encode('salt'),
          iterations: 4096,
          keyLength: 32,
        )),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('key longer than one digest spans two blocks', () {
      final out = pbkdf2HmacSha256(
        password: utf8.encode('password'),
        salt: utf8.encode('salt'),
        iterations: 1,
        keyLength: 40,
      );
      expect(out.length, 40);
      // First 32 bytes are the block-1 output, so the prefix cannot change.
      expect(
        hex(out.sublist(0, 32)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('truncating the requested length does not change the prefix', () {
      final full = pbkdf2HmacSha256(
        password: utf8.encode('pw'),
        salt: utf8.encode('na'),
        iterations: 3,
        keyLength: 32,
      );
      final short = pbkdf2HmacSha256(
        password: utf8.encode('pw'),
        salt: utf8.encode('na'),
        iterations: 3,
        keyLength: 16,
      );
      expect(hex(short), hex(full.sublist(0, 16)));
    });

    test('iterations below 1 is rejected, not silently clamped', () {
      expect(
        () => pbkdf2HmacSha256(
          password: const <int>[1],
          salt: const <int>[2],
          iterations: 0,
          keyLength: 32,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('constantTimeEquals', () {
    test('equal content and equal length is true', () {
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 3]), isTrue);
    });

    test('a difference in the last byte is still false', () {
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 4]), isFalse);
    });

    test('a difference in the first byte is still false', () {
      expect(constantTimeEquals(<int>[9, 2, 3], <int>[1, 2, 3]), isFalse);
    });

    test('length mismatch is false without reading past the end', () {
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 2, 3]), isFalse);
    });

    test('two empty lists are equal', () {
      expect(constantTimeEquals(const <int>[], const <int>[]), isTrue);
    });
  });

  group('hex helpers round-trip', () {
    test('bytesToHex/hexToBytes', () {
      final bytes = <int>[0x00, 0x0F, 0xF0, 0xFF];
      final encoded = bytesToHex(bytes);
      expect(encoded, '000ff0ff');
      expect(hexToBytes(encoded), bytes);
    });

    test('odd-length hex is rejected', () {
      expect(() => hexToBytes('abc'), throwsA(isA<ArgumentError>()));
    });
  });
}
