// The window arithmetic that keeps a play from turning into a download.
//
// Every case here is a number the device report disagreed with: a 1.33 GB
// file that had 152 MB on disk before the first frame, a window that ended
// exactly where the reader was standing, a tail probe that asked for the
// whole file because nobody clamped it.
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/stream_window.dart';

void main() {
  group('firstWindow', () {
    test('a 1.33 GB video opens on 16 MB, not on its own size', () {
      const total = 1429876103;
      final window = StreamWindow.firstWindow(total);
      expect(window, StreamWindow.firstBytes);
      expect(window, 16 * 1024 * 1024);
      // The whole point: the first request is a small fraction of the file.
      expect(window / total, lessThan(0.02));
    });

    test('a tiny clip is never asked for in 16 MB', () {
      expect(StreamWindow.firstWindow(900 * 1024), 900 * 1024);
    });

    test('an unknown size falls back to the window, not to zero', () {
      expect(StreamWindow.firstWindow(0), StreamWindow.firstBytes);
      expect(StreamWindow.firstWindow(-1), StreamWindow.firstBytes);
    });
  });

  group('windowAt', () {
    test('aligns down to 1 KB, which is what TDLib chunks on', () {
      final (from, to) = StreamWindow.windowAt(1500, 100 * 1024 * 1024);
      expect(from, 1024);
      expect(to, 1024 + StreamWindow.stepBytes - 1);
      expect(StreamWindow.limitFor(from, to), StreamWindow.stepBytes);
    });

    test('clamps to the last byte of the file', () {
      const total = 20 * 1024 * 1024;
      final (from, to) = StreamWindow.windowAt(16 * 1024 * 1024, total);
      expect(from, 16 * 1024 * 1024);
      expect(to, total - 1);
      expect(StreamWindow.limitFor(from, to), 4 * 1024 * 1024);
    });

    test('a tail probe gets one window, never the whole file', () {
      const total = 1429876103;
      final offset = 1426653184;
      final (from, to) = StreamWindow.windowAt(offset, total);
      final limit = StreamWindow.limitFor(from, to);
      expect(limit, lessThanOrEqualTo(StreamWindow.stepBytes));
      expect(to, total - 1);
    });
  });

  group('windowCoversFrom', () {
    test('a head inside the window is covered', () {
      expect(StreamWindow.windowCoversFrom(0, 16 * 1024 * 1024, 0), isTrue);
      // The window is inclusive: its last byte is `from + limit - 1`.
      expect(
        StreamWindow.windowCoversFrom(0, 16 * 1024 * 1024, 16 * 1024 * 1024 - 1),
        isTrue,
      );
    });

    test('a head past the window end is not covered', () {
      expect(
        StreamWindow.windowCoversFrom(0, 16 * 1024 * 1024, 16 * 1024 * 1024 + 1),
        isFalse,
      );
    });

    test('an empty window covers nothing', () {
      expect(StreamWindow.windowCoversFrom(0, 0, 0), isFalse);
    });
  });
}
