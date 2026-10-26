import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/download_metrics.dart';
import 'package:tg_media_probe/util/byte_format.dart';

void main() {
  group('first byte', () {
    test('stays null until a non-zero byte count arrives', () {
      final metrics = DownloadMetrics(startedAtMillis: 1000, expectedBytes: 1000);
      metrics.observe(1100, 0);
      expect(metrics.timeToFirstByteMillis, isNull);

      metrics.observe(1500, 300);
      expect(metrics.timeToFirstByteMillis, 500);
    });

    test('is measured once, not overwritten by later events', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 1000);
      metrics.observe(400, 100);
      metrics.observe(900, 900);
      expect(metrics.timeToFirstByteMillis, 400);
    });
  });

  group('throughput', () {
    test('needs two samples inside the window', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 100000);
      metrics.observe(100, 1000);
      expect(metrics.bytesPerSecond, isNull);

      metrics.observe(200, 3000);
      expect(metrics.bytesPerSecond, closeTo(20000, 1));
    });

    test('window excludes ramp-up that the average keeps', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 400000);
      metrics.observe(0, 0);
      // Slow start: 1 KB in the first second.
      metrics.observe(1000, 1000);
      // Then a burst.
      metrics.observe(5000, 101000);
      metrics.observe(6000, 301000);

      // Window is the last 3000 ms, so it starts at the 5000 ms sample:
      // 200 KB in 1000 ms.
      expect(metrics.bytesPerSecond, closeTo(200000, 1));
      // Average still carries the slow start: 301 KB over 6 s.
      expect(metrics.averageBytesPerSecond, closeTo(50166.7, 1));
    });

    test('a stalled transfer reports null, never zero', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 100000);
      metrics.observe(1000, 50000);
      metrics.observe(2000, 50000);

      expect(metrics.bytesPerSecond, isNull);
      expect(formatRate(metrics.bytesPerSecond), '—');
      // The average is a real, positive number even though the tail is stalled.
      expect(metrics.averageBytesPerSecond, closeTo(25000, 1));
    });

    test('a single sample never divides by zero', () {
      final metrics = DownloadMetrics(startedAtMillis: 500, expectedBytes: 1000);
      metrics.observe(500, 0);
      expect(metrics.bytesPerSecond, isNull);
      expect(metrics.averageBytesPerSecond, isNull);
    });
  });

  group('progress', () {
    test('unknown expected size never yields a percentage or an ETA', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 0);
      metrics.observe(1000, 5000);

      expect(metrics.hasExpectedSize, isFalse);
      expect(metrics.fraction, 0);
      expect(metrics.etaMillis, isNull);
    });

    test('fraction is clamped to one even if TDLib overshoots', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 1000);
      metrics.observe(1000, 1200);
      expect(metrics.fraction, 1.0);
    });

    test('eta divides the remainder by the windowed rate', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 300000);
      metrics.observe(5000, 100000);
      metrics.observe(6000, 200000);

      // 100 KB/s, 100 KB left.
      expect(metrics.etaMillis, 1000);
    });

    test('eta is zero once the expected size is reached', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 200000);
      metrics.observe(1000, 100000);
      metrics.observe(2000, 200000);
      expect(metrics.etaMillis, 0);
    });
  });

  group('lifecycle', () {
    test('samples are capped and the newest value survives', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 10000000);
      for (var i = 1; i <= 500; i++) {
        metrics.observe(i * 10, i * 1000);
      }
      expect(metrics.samples.length, lessThanOrEqualTo(48));
      expect(metrics.latestBytes, 500000);
    });

    test('observations after completion are ignored', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 1000);
      metrics.observe(100, 500);
      metrics.complete(200);
      final count = metrics.samples.length;

      metrics.observe(300, 900);

      expect(metrics.samples.length, count);
      expect(metrics.latestBytes, 500);
      expect(metrics.isComplete, isTrue);
    });

    test('fail freezes the elapsed time without losing measurements', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 1000);
      metrics.observe(1000, 400);
      metrics.fail(5000);

      expect(metrics.hasFailed, isTrue);
      expect(metrics.elapsedMillis, 5000);
      expect(metrics.latestBytes, 400);
    });

    test('a sample timestamped before the start does not produce negative time', () {
      final metrics = DownloadMetrics(startedAtMillis: 5000, expectedBytes: 1000);
      metrics.observe(4000, 100);
      expect(metrics.elapsedMillis, 0);
      expect(metrics.timeToFirstByteMillis, 0);
    });

    test('summary carries raw and formatted values together', () {
      final metrics = DownloadMetrics(startedAtMillis: 0, expectedBytes: 5809108);
      metrics.observe(400, 1000);
      metrics.observe(1400, 1048576);

      final summary = metrics.summary;
      expect(summary, contains('MB'));
      expect(summary, contains('首字节 400ms'));
      expect(summary, contains('均速'));
    });
  });
}
