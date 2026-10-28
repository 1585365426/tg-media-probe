/// `moov` position scan.
///
/// Why it matters: an MP4 with `moov` after `mdat` cannot start from a head-only
/// response — the player must read the end of the file first. The scan is the
/// only way to know which layout a device run is fighting, and it works on the
/// bytes already on disk.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/mp4_probe.dart';

/// Builds `[size][type][payload]` boxes back to back.
Uint8List boxes(List<(String type, int payload)> entries) {
  final builder = BytesBuilder();
  for (final entry in entries) {
    final header = ByteData(8)
      ..setUint32(0, entry.$2 + 8)
      ..setUint8(4, entry.$1.codeUnitAt(0))
      ..setUint8(5, entry.$1.codeUnitAt(1))
      ..setUint8(6, entry.$1.codeUnitAt(2))
      ..setUint8(7, entry.$1.codeUnitAt(3));
    builder.add(header.buffer.asUint8List());
    builder.add(List<int>.filled(entry.$2, 0));
  }
  return builder.toBytes();
}

void main() {
  test('ftyp then moov is a head-mounted file', () {
    final bytes = boxes(<(String, int)>[
      ('ftyp', 24),
      ('moov', 100),
      ('mdat', 4096),
    ]);

    expect(Mp4Probe.locate(bytes), MoovPosition.head);
  });

  test('ftyp, free, moov is still head-mounted', () {
    final bytes = boxes(<(String, int)>[
      ('ftyp', 24),
      ('free', 8),
      ('moov', 64),
      ('mdat', 1024),
    ]);

    expect(Mp4Probe.locate(bytes), MoovPosition.head);
  });

  test('mdat before moov means the player must read the tail', () {
    final bytes = boxes(<(String, int)>[
      ('ftyp', 24),
      ('mdat', 4096),
    ]);

    expect(Mp4Probe.locate(bytes), MoovPosition.afterMdat);
  });

  test('a box that runs past the bytes we have is unknown, not a guess', () {
    final bytes = boxes(<(String, int)>[
      ('ftyp', 24),
      ('free', 65536),
    ]);

    expect(Mp4Probe.locate(bytes), MoovPosition.unknown);
  });

  test('a 64-bit box size is honoured', () {
    final builder = BytesBuilder();
    final header = ByteData(16)
      ..setUint32(0, 1) // largesize follows
      ..setUint8(4, 'f'.codeUnitAt(0))
      ..setUint8(5, 't'.codeUnitAt(0))
      ..setUint8(6, 'y'.codeUnitAt(0))
      ..setUint8(7, 'p'.codeUnitAt(0))
      ..setUint64(8, 32);
    builder.add(header.buffer.asUint8List());
    builder.add(List<int>.filled(16, 0));
    builder.add(boxes(<(String, int)>[('moov', 32)]));

    expect(Mp4Probe.locate(builder.toBytes()), MoovPosition.head);
  });

  test('garbage and empty input stay unknown', () {
    expect(Mp4Probe.locate(<int>[]), MoovPosition.unknown);
    expect(Mp4Probe.locate(List<int>.filled(4, 7)), MoovPosition.unknown);
    expect(
      Mp4Probe.locate(List<int>.generate(64, (i) => i & 0xff)),
      MoovPosition.unknown,
    );
  });

  group('scan reports the offsets a tail fetch would need', () {
    test('a sized mdat pins moov to the byte right after it', () {
      // ftyp(32) + mdat(4096) + moov — a 638 MB Telegram film with the index at
      // the end. `afterMdat` alone cannot tell anyone how far away it is.
      final head = boxes(<(String, int)>[
        ('ftyp', 24),
        ('mdat', 4096),
      ]);
      final total = head.length + 8 + 100; // + moov box

      final scan = Mp4Probe.scan(head, total: total);

      expect(scan.position, MoovPosition.afterMdat);
      expect(scan.start, head.length);
      expect(scan.end, total - 1);
      expect(scan.isTail, isTrue);
      expect(scan.length, total - head.length);
    });

    test('a head moov reports its own span and is not a tail', () {
      final bytes = boxes(<(String, int)>[
        ('ftyp', 24),
        ('moov', 100),
        ('mdat', 4096),
      ]);

      final scan = Mp4Probe.scan(bytes, total: bytes.length);

      expect(scan.position, MoovPosition.head);
      expect(scan.start, 32);
      expect(scan.end, 32 + 8 + 100 - 1);
      expect(scan.isTail, isFalse);
    });

    test('an mdat that runs to EOF cannot locate anything after it', () {
      final builder = BytesBuilder();
      final header = ByteData(8)
        ..setUint32(0, 0) // size 0: this box owns the rest of the file
        ..setUint8(4, 'm'.codeUnitAt(0))
        ..setUint8(5, 'd'.codeUnitAt(0))
        ..setUint8(6, 'a'.codeUnitAt(0))
        ..setUint8(7, 't'.codeUnitAt(0));
      builder.add(header.buffer.asUint8List());
      builder.add(List<int>.filled(64, 0));

      final scan = Mp4Probe.scan(builder.toBytes(), total: 1 << 20);

      expect(scan.position, MoovPosition.unknown);
      expect(scan.start, -1);
    });

    test('locate still answers the old question', () {
      final bytes = boxes(<(String, int)>[
        ('ftyp', 24),
        ('mdat', 4096),
      ]);
      expect(Mp4Probe.locate(bytes), MoovPosition.afterMdat);
    });
  });
}
