/// Byte and rate formatting for the probe screen.
///
/// One implementation only. The probe prints raw byte counts next to formatted
/// ones on purpose — if the two used different rounding they would disagree,
/// and a number that disagrees with itself is not evidence.
library;

const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB'];

/// 1024-based, matching what the iOS storage screen shows for app data.
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  // Three significant digits. A fixed decimal count either loses 5.54 MB or
  // prints 1234.00 MB of noise.
  final String text;
  if (value >= 100) {
    text = value.toStringAsFixed(0);
  } else if (value >= 10) {
    text = value.toStringAsFixed(1);
  } else {
    text = value.toStringAsFixed(2);
  }
  return '$text ${_units[unit]}';
}

/// Null or non-positive throughput renders as an em dash, never as "0 B/s":
/// zero is a measurement, an em dash means "not measured yet".
String formatRate(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '—';
  return '${formatBytes(bytesPerSecond.round())}/s';
}

String formatMillis(int millis) {
  if (millis < 0) return '—';
  if (millis < 1000) return '${millis}ms';
  final seconds = millis / 1000;
  if (seconds < 10) return '${seconds.toStringAsFixed(2)}s';
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds ~/ 60;
  final rest = seconds - minutes * 60;
  return '${minutes}m${rest.toStringAsFixed(0)}s';
}
