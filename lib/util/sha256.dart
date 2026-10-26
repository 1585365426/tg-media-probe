/// SHA-256, HMAC-SHA256 and PBKDF2-HMAC-SHA256 in pure Dart.
///
/// Implemented here rather than pulled from `package:crypto` because the
/// passcode hash is the one place where a silent algorithm change is
/// unrecoverable: a different PBKDF2 output locks every existing user out of
/// their own app. Pinning the implementation to this file, with the RFC test
/// vectors in `test/sha256_test.dart`, keeps stored hashes verifiable across
/// dependency bumps.
///
/// Not constant time and not intended for large inputs; it exists to turn a
/// short passcode into a stored verifier.
library;

import 'dart:typed_data';

const int _u32 = 0xFFFFFFFF;

const List<int> _roundConstants = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _u32;

/// 32-byte SHA-256 digest of [message].
Uint8List sha256(List<int> message) {
  final bitLength = message.length * 8;

  // Pad: 0x80, then zeros until the block is 56 bytes long, then the 64-bit
  // big-endian message length. Always at least one extra block.
  final totalLength = ((message.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(totalLength)..setRange(0, message.length, message);
  padded[message.length] = 0x80;

  // A message longer than 2^32 bits cannot happen here; the high word is still
  // written so the encoding matches the specification for any input.
  final highBits = (bitLength ~/ 0x100000000) & _u32;
  final lowBits = bitLength & _u32;
  void writeU32(int at, int value) {
    padded[at] = (value >> 24) & 0xFF;
    padded[at + 1] = (value >> 16) & 0xFF;
    padded[at + 2] = (value >> 8) & 0xFF;
    padded[at + 3] = value & 0xFF;
  }

  writeU32(totalLength - 8, highBits);
  writeU32(totalLength - 4, lowBits);

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final schedule = Uint32List(64);

  for (var chunk = 0; chunk < totalLength; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final at = chunk + i * 4;
      schedule[i] = (padded[at] << 24) |
          (padded[at + 1] << 16) |
          (padded[at + 2] << 8) |
          padded[at + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = schedule[i - 15];
      final y = schedule[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      schedule[i] =
          (schedule[i - 16] + s0 + schedule[i - 7] + s1) & _u32;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _u32) & g);
      final temp1 = (h + s1 + ch + _roundConstants[i] + schedule[i]) & _u32;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & _u32;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _u32;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _u32;
    }

    h0 = (h0 + a) & _u32;
    h1 = (h1 + b) & _u32;
    h2 = (h2 + c) & _u32;
    h3 = (h3 + d) & _u32;
    h4 = (h4 + e) & _u32;
    h5 = (h5 + f) & _u32;
    h6 = (h6 + g) & _u32;
    h7 = (h7 + h) & _u32;
  }

  final digest = Uint8List(32);
  final words = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    final value = words[i];
    digest[i * 4] = (value >> 24) & 0xFF;
    digest[i * 4 + 1] = (value >> 16) & 0xFF;
    digest[i * 4 + 2] = (value >> 8) & 0xFF;
    digest[i * 4 + 3] = value & 0xFF;
  }
  return digest;
}

const int _blockSize = 64;

/// HMAC-SHA256 as specified in RFC 2104.
Uint8List hmacSha256(List<int> key, List<int> message) {
  var normalised = key.length > _blockSize
      ? sha256(key)
      : Uint8List.fromList(List<int>.from(key));
  if (normalised.length < _blockSize) {
    final padded = Uint8List(_blockSize)..setRange(0, normalised.length, normalised);
    normalised = padded;
  }

  final inner = Uint8List(_blockSize);
  final outer = Uint8List(_blockSize);
  for (var i = 0; i < _blockSize; i++) {
    inner[i] = normalised[i] ^ 0x36;
    outer[i] = normalised[i] ^ 0x5c;
  }

  final innerDigest = sha256(<int>[...inner, ...message]);
  return sha256(<int>[...outer, ...innerDigest]);
}

/// PBKDF2 with HMAC-SHA256 as the pseudo-random function (RFC 8018 §5.2).
///
/// [iterations] is the work factor. Raising it invalidates nothing: the value
/// is stored next to the hash, so an old record keeps verifying with its own
/// count and only new records use the new one.
Uint8List pbkdf2HmacSha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int keyLength,
}) {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
  }
  if (keyLength < 1) {
    throw ArgumentError.value(keyLength, 'keyLength', 'must be >= 1');
  }

  const digestLength = 32;
  final blockCount = (keyLength + digestLength - 1) ~/ digestLength;
  final output = Uint8List(blockCount * digestLength);

  for (var block = 1; block <= blockCount; block++) {
    // U1 = PRF(password, salt || INT_32_BE(block))
    final seed = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt)
      ..[salt.length] = (block >> 24) & 0xFF
      ..[salt.length + 1] = (block >> 16) & 0xFF
      ..[salt.length + 2] = (block >> 8) & 0xFF
      ..[salt.length + 3] = block & 0xFF;

    var u = hmacSha256(password, seed);
    final accumulator = Uint8List.fromList(u);

    for (var round = 1; round < iterations; round++) {
      u = hmacSha256(password, u);
      for (var i = 0; i < digestLength; i++) {
        accumulator[i] ^= u[i];
      }
    }

    output.setRange((block - 1) * digestLength, block * digestLength, accumulator);
  }

  return Uint8List.sublistView(output, 0, keyLength);
}

/// Byte-wise comparison that does not exit early on the first difference.
///
/// A passcode verifier that returns after the first mismatching byte leaks how
/// many leading bytes were correct to anything that can time the call.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError.value(hex, 'hex', 'length must be even');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
