import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/util/byte_format.dart';

void main() {
  group('formatBytes', () {
    test('keeps single bytes as bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('steps up units at 1024', () {
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(1024 * 1024), '1.00 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('keeps three significant digits', () {
      expect(formatBytes(5809108), '5.54 MB');
      expect(formatBytes(50 * 1024 * 1024), '50.0 MB');
      expect(formatBytes(500 * 1024 * 1024), '500 MB');
    });

    test('negative means "not measured", not "-1 B"', () {
      expect(formatBytes(-1), '—');
    });
  });

  group('formatRate', () {
    test('null and zero both render as an em dash', () {
      expect(formatRate(null), '—');
      expect(formatRate(0), '—');
      expect(formatRate(-5), '—');
    });

    test('appends a per-second suffix', () {
      expect(formatRate(1024), '1.00 KB/s');
      expect(formatRate(2 * 1024 * 1024), '2.00 MB/s');
    });
  });

  group('formatMillis', () {
    test('below one second stays in milliseconds', () {
      expect(formatMillis(0), '0ms');
      expect(formatMillis(999), '999ms');
    });

    test('seconds carry two decimals under ten, one above', () {
      expect(formatMillis(1500), '1.50s');
      expect(formatMillis(10500), '10.5s');
    });

    test('above a minute switches to m/s', () {
      expect(formatMillis(65000), '1m5s');
      expect(formatMillis(125000), '2m5s');
    });
  });
}
