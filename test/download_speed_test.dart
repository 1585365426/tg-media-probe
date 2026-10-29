/// Speed measurement: real deltas, smoothing, no negative rates, and a real
/// decay to zero when the transfer stops.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/download/download_speed.dart';

void main() {
  final t0 = DateTime.fromMillisecondsSinceEpoch(1790000000000);

  test('one second of steady growth reads as the real rate', () {
    final meter = SpeedMeter();
    meter.begin(0, t0);
    meter.sample(1024 * 1024, t0.add(const Duration(milliseconds: 200)));
    meter.sample(2 * 1024 * 1024, t0.add(const Duration(milliseconds: 400)));
    meter.sample(3 * 1024 * 1024, t0.add(const Duration(milliseconds: 600)));
    meter.sample(4 * 1024 * 1024, t0.add(const Duration(milliseconds: 800)));
    meter.sample(5 * 1024 * 1024, t0.add(const Duration(milliseconds: 1000)));
    // ~5 MB/s; smoothing keeps it inside a sane band rather than exact.
    expect(meter.bytesPerSecond, greaterThan(3.5 * 1024 * 1024));
    expect(meter.bytesPerSecond, lessThan(6.5 * 1024 * 1024));
  });

  test('a counter that moves backwards restarts instead of going negative', () {
    final meter = SpeedMeter();
    meter.begin(5 * 1024 * 1024, t0);
    meter.sample(6 * 1024 * 1024, t0.add(const Duration(milliseconds: 500)));
    meter.sample(1024, t0.add(const Duration(milliseconds: 600)));
    expect(meter.bytesPerSecond, greaterThanOrEqualTo(0));
  });

  test('a single idle sample does not zero the reading', () {
    final meter = SpeedMeter();
    meter.begin(0, t0);
    for (var i = 1; i <= 4; i++) {
      meter.sample(i * 2 * 1024 * 1024,
          t0.add(Duration(milliseconds: 250 * i)));
    }
    final before = meter.bytesPerSecond;
    expect(before, greaterThan(0));
    // Same byte count again: the instant rate is 0 but the display must not
    // fall to zero on one late update.
    meter.sample(8 * 1024 * 1024, t0.add(const Duration(milliseconds: 1300)));
    expect(meter.bytesPerSecond, greaterThan(0));
  });

  test('ticking with no progress decays to zero', () {
    final meter = SpeedMeter();
    meter.begin(0, t0);
    for (var i = 1; i <= 4; i++) {
      meter.sample(i * 2 * 1024 * 1024,
          t0.add(Duration(milliseconds: 250 * i)));
    }
    expect(meter.bytesPerSecond, greaterThan(0));
    for (var i = 0; i < 12; i++) {
      meter.tick(t0.add(Duration(milliseconds: 1000 + 500 * i)));
    }
    expect(meter.bytesPerSecond, 0);
  });

  test('begin() clears a previous transfer rate', () {
    final meter = SpeedMeter();
    meter.begin(0, t0);
    meter.sample(4 * 1024 * 1024, t0.add(const Duration(milliseconds: 500)));
    expect(meter.bytesPerSecond, greaterThan(0));
    meter.begin(0, t0.add(const Duration(seconds: 1)));
    expect(meter.bytesPerSecond, 0);
  });

  test('reset() forgets everything', () {
    final meter = SpeedMeter();
    meter.begin(0, t0);
    meter.sample(1024 * 1024, t0.add(const Duration(milliseconds: 500)));
    meter.reset();
    expect(meter.bytesPerSecond, 0);
    // A sample after reset starts a fresh window instead of dividing by the
    // time since the previous transfer.
    meter.sample(4 * 1024 * 1024, t0.add(const Duration(seconds: 10)));
    expect(meter.bytesPerSecond, 0);
  });
}
