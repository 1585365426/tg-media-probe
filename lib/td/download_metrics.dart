import '../util/byte_format.dart';

/// One `updateFile` data point, stored relative to the download start.
///
/// Relative milliseconds instead of [DateTime] keeps the whole class pure, so
/// the arithmetic that answers "is this actually slow?" can be unit-tested
/// with synthetic traces instead of guessed at from a screenshot.
class DownloadSample {
  const DownloadSample(this.atMillis, this.bytes);

  final int atMillis;
  final int bytes;

  @override
  String toString() => 'DownloadSample(+${atMillis}ms, $bytes B)';
}

/// Timing and throughput of a single TDLib download.
///
/// Three numbers matter and they answer different questions:
///
/// | number | question it answers |
/// |---|---|
/// | [timeToFirstByteMillis] | is Telegram / the DC reachable at all, or is the wait connection setup? |
/// | [bytesPerSecond] | how fast are bytes arriving *now* (tail window) |
/// | [averageBytesPerSecond] | what the user experienced end to end |
///
/// Averaging from byte zero alone cannot tell a slow link from a slow start,
/// which is exactly the distinction that decides whether more parallelism would
/// help or whether the problem is somewhere else entirely.
class DownloadMetrics {
  DownloadMetrics({
    required this.startedAtMillis,
    required this.expectedBytes,
  });

  /// Wall clock (milliseconds) when `downloadFile` was sent.
  final int startedAtMillis;

  /// `file.expected_size` reported by TDLib. Zero means "unknown", and every
  /// percentage derived from it is then reported as unknown rather than 0 %.
  final int expectedBytes;

  final List<DownloadSample> _samples = <DownloadSample>[];

  /// 48 samples covers the rate window even when TDLib emits an event per
  /// chunk, and bounds memory for multi-gigabyte transfers.
  static const int _maxSamples = 48;

  /// Throughput is measured over the tail only. Tailoring the window is what
  /// removes the TCP ramp-up and TDLib's connection setup from the number;
  /// including them makes a healthy 6 MB/s link report 800 KB/s forever.
  static const int rateWindowMillis = 3000;

  int? _firstByteMillis;
  int? _completedMillis;
  bool _failed = false;

  bool get hasFailed => _failed;
  bool get isComplete => _completedMillis != null;

  int get latestBytes => _samples.isEmpty ? 0 : _samples.last.bytes;

  int get elapsedMillis {
    final end = _completedMillis ??
        (_samples.isEmpty ? startedAtMillis : _samples.last.atMillis);
    final delta = end - startedAtMillis;
    return delta < 0 ? 0 : delta;
  }

  /// Null until the first non-zero byte arrives: "0 ms to first byte" would be
  /// a lie, the transfer simply has not produced anything yet.
  int? get timeToFirstByteMillis {
    final first = _firstByteMillis;
    if (first == null) return null;
    final delta = first - startedAtMillis;
    return delta < 0 ? 0 : delta;
  }

  /// 0 when [expectedBytes] is unknown, so callers must check
  /// [hasExpectedSize] before drawing a progress bar from it.
  bool get hasExpectedSize => expectedBytes > 0;

  double get fraction {
    if (!hasExpectedSize) return 0;
    return (latestBytes / expectedBytes).clamp(0.0, 1.0);
  }

  void observe(int nowMillis, int downloadedBytes) {
    if (_completedMillis != null) return;
    if (downloadedBytes > 0 && _firstByteMillis == null) {
      _firstByteMillis = nowMillis;
    }
    _samples.add(DownloadSample(nowMillis - startedAtMillis, downloadedBytes));
    if (_samples.length > _maxSamples) {
      // Drop from the middle: the head still holds the first-byte reference
      // and the tail holds the rate window, so only interior samples go.
      _samples.removeAt(_samples.length ~/ 2);
    }
  }

  void complete(int nowMillis) {
    _completedMillis = nowMillis;
  }

  void fail(int nowMillis) {
    _failed = true;
    _completedMillis = nowMillis;
  }

  /// Instantaneous throughput over [rateWindowMillis].
  ///
  /// Null with fewer than two samples in the window, and null when the byte
  /// count did not move — a stalled transfer must render as "—", not "0 B/s",
  /// because those two mean different things to whoever reads the screen.
  double? get bytesPerSecond {
    if (_samples.length < 2) return null;
    final last = _samples.last;
    final cutoff = last.atMillis - rateWindowMillis;
    DownloadSample first = _samples.first;
    for (final sample in _samples) {
      if (sample.atMillis >= cutoff) {
        first = sample;
        break;
      }
    }
    final deltaMillis = last.atMillis - first.atMillis;
    if (deltaMillis <= 0) return null;
    final deltaBytes = last.bytes - first.bytes;
    if (deltaBytes <= 0) return null;
    return deltaBytes * 1000 / deltaMillis;
  }

  /// End-to-end average, first-byte wait included. This is the number the user
  /// actually experienced.
  double? get averageBytesPerSecond {
    final millis = elapsedMillis;
    if (millis <= 0 || latestBytes <= 0) return null;
    return latestBytes * 1000 / millis;
  }

  /// Remaining time at the current instantaneous rate. Null whenever either
  /// input is unknown; the UI prints nothing rather than a fake countdown.
  int? get etaMillis {
    final rate = bytesPerSecond;
    if (rate == null || !hasExpectedSize) return null;
    final remaining = expectedBytes - latestBytes;
    if (remaining <= 0) return 0;
    return (remaining / rate * 1000).round();
  }

  /// One line for the probe step detail.
  String get summary {
    final parts = <String>[
      hasExpectedSize
          ? '${formatBytes(latestBytes)} / ${formatBytes(expectedBytes)}'
          : formatBytes(latestBytes),
      '用时 ${formatMillis(elapsedMillis)}',
      if (timeToFirstByteMillis != null)
        '首字节 ${formatMillis(timeToFirstByteMillis!)}',
      '均速 ${formatRate(averageBytesPerSecond)}',
      '即时 ${formatRate(bytesPerSecond)}',
    ];
    return parts.join(' · ');
  }

  /// Test seam: the samples actually retained. Production code has no reason
  /// to read this, the rate window arithmetic does.
  List<DownloadSample> get samples => List<DownloadSample>.unmodifiable(_samples);

  @override
  String toString() => 'DownloadMetrics($summary)';
}
