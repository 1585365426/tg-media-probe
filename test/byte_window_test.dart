import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/byte_window.dart';

void main() {
  group('FileWindow', () {
    test('maps a logical position to a physical one with no offset', () {
      const window = FileWindow(path: '/p', offset: 0, prefixSize: 1000);
      expect(window.covers(0, 1), isTrue);
      expect(window.covers(999, 1), isTrue);
      expect(window.covers(1000, 1), isFalse);
      expect(window.covers(900, 100), isTrue);
      expect(window.covers(900, 101), isFalse);
      expect(window.physicalOffset(512), 512);
    });

    test('subtracts a non-zero download offset', () {
      // TDLib started this download at byte 4096; the pool file's first byte is
      // logical 4096.
      const window = FileWindow(path: '/p', offset: 4096, prefixSize: 2048);
      expect(window.covers(0, 1), isFalse);
      expect(window.covers(4095, 1), isFalse);
      expect(window.covers(4096, 1), isTrue);
      expect(window.covers(6143, 1), isTrue);
      expect(window.covers(6144, 1), isFalse);
      expect(window.physicalOffset(4096), 0);
      expect(window.physicalOffset(5000), 904);
      expect(window.availableFrom(6000), 144);
      expect(window.availableFrom(10), 0);
    });

    test('an empty window covers nothing', () {
      expect(FileWindow.empty.covers(0, 1), isFalse);
      expect(const FileWindow(path: '', offset: 0, prefixSize: 10).covers(0, 1),
          isFalse);
      expect(const FileWindow(path: '/p', offset: 0, prefixSize: 0).covers(0, 1),
          isFalse);
      // A zero-length read is never "covered": it would loop forever.
      expect(const FileWindow(path: '/p', offset: 0, prefixSize: 10).covers(5, 0),
          isFalse);
    });
  });

  group('parseRangeHeader', () {
    test('no header means the whole body', () {
      expect(parseRangeHeader(null, 1000), isA<RangeNone>());
      expect(parseRangeHeader('', 1000), isA<RangeNone>());
      expect(parseRangeHeader('   ', 1000), isA<RangeNone>());
    });

    test('bytes=0- is the classic AVPlayer open-ended request', () {
      final parsed = parseRangeHeader('bytes=0-', 1000);
      expect(parsed, isA<RangeOk>());
      expect((parsed as RangeOk).range, const ByteRange(0, 999));
      expect(parsed.range.length, 1000);
    });

    test('a closed range is honoured exactly', () {
      final parsed = parseRangeHeader('bytes=100-199', 1000) as RangeOk;
      expect(parsed.range.start, 100);
      expect(parsed.range.endInclusive, 199);
      expect(parsed.range.length, 100);
    });

    test('an end past EOF is clamped, not rejected', () {
      final parsed = parseRangeHeader('bytes=900-5000', 1000) as RangeOk;
      expect(parsed.range, const ByteRange(900, 999));
    });

    test('a suffix range is the tail of the file', () {
      final parsed = parseRangeHeader('bytes=-300', 1000) as RangeOk;
      expect(parsed.range, const ByteRange(700, 999));
      final huge = parseRangeHeader('bytes=-5000', 1000) as RangeOk;
      expect(huge.range, const ByteRange(0, 999));
    });

    test('a start at or past EOF is unsatisfiable, so the server can send 416',
        () {
      final atEof = parseRangeHeader('bytes=1000-', 1000);
      expect(atEof, isA<RangeUnsatisfiable>());
      expect((atEof as RangeUnsatisfiable).totalBytes, 1000);
      expect(parseRangeHeader('bytes=5000-6000', 1000),
          isA<RangeUnsatisfiable>());
    });

    test('multi-range collapses to the first range', () {
      final parsed = parseRangeHeader('bytes=0-99,200-299', 1000) as RangeOk;
      expect(parsed.range, const ByteRange(0, 99));
    });

    test('garbage falls back to a full response instead of an error', () {
      expect(parseRangeHeader('items=0-10', 1000), isA<RangeNone>());
      expect(parseRangeHeader('bytes=abc-def', 1000), isA<RangeNone>());
      expect(parseRangeHeader('bytes=500-100', 1000), isA<RangeNone>());
      expect(parseRangeHeader('bytes=-', 1000), isA<RangeNone>());
      expect(parseRangeHeader('bytes=-0', 1000), isA<RangeNone>());
    });

    test('an unknown total cannot be ranged', () {
      expect(parseRangeHeader('bytes=0-', 0), isA<RangeNone>());
      expect(parseRangeHeader('bytes=0-', -5), isA<RangeNone>());
    });

    test('is case-insensitive', () {
      final parsed = parseRangeHeader('BYTES=10-19', 1000);
      expect(parsed, isA<RangeOk>());
      expect((parsed as RangeOk).range, const ByteRange(10, 19));
    });
  });
}
