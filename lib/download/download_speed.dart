/// Throughput measurement from real byte counters.
///
/// Everything here is fed by `updateFile`'s `downloaded_size`, so the number on
/// screen is a measurement. Three properties matter for a usable reading:
///
/// * a short window (default 1 s) so the figure tracks the transfer;
/// * smoothing, so a single late update does not print 0 B/s while bytes are
///   clearly moving;
/// * a decay rule, so a stopped transfer actually falls to zero instead of
///   showing yesterday's speed forever.
library;

class _Sample {
  const _Sample(this.at, this.bytes);

  final DateTime at;
  final int bytes;
}

class SpeedMeter {
  SpeedMeter({
    this.window = const Duration(seconds: 1),
    this.smoothing = 0.4,
    this.decayFactor = 0.6,
  });

  /// Span the rate is computed over. Shorter than 500 ms is noise, longer than
  /// 2 s feels laggy when a transfer starts or stalls.
  final Duration window;

  /// Weight of the newest measurement. 0.4 keeps a visible reaction while
  /// dropping single-sample spikes.
  final double smoothing;

  /// Multiplier applied per sample when the byte counter did not move.
  final double decayFactor;

  final List<_Sample> _samples = <_Sample>[];
  double _rate = 0;
  int? _lastBytes;
  DateTime? _lastProgressAt;

  double get bytesPerSecond => _rate;

  /// Starts a transfer. A new download must not inherit the previous speed.
  void begin(int bytes, DateTime now) {
    _samples
      ..clear()
      ..add(_Sample(now, bytes));
    _lastBytes = bytes;
    _lastProgressAt = now;
    _rate = 0;
  }

  /// One reported byte count. Ignores a counter that moved backwards: TDLib
  /// resets `downloaded_size` when a range download is replaced, and a negative
  /// delta is not negative throughput.
  void sample(int bytes, DateTime now) {
    final last = _lastBytes;
    if (last == null) {
      begin(bytes, now);
      return;
    }
    if (bytes < last) {
      begin(bytes, now);
      return;
    }
    _lastBytes = bytes;
    _samples.add(_Sample(now, bytes));

    // Drop samples that fell out of the window, but always keep the newest one
    // so the window cannot become empty on a fast transfer.
    while (_samples.length > 2 &&
        now.difference(_samples.first.at) > window) {
      _samples.removeAt(0);
    }

    final first = _samples.first;
    final elapsedMs = now.difference(first.at).inMilliseconds;
    if (bytes > last) _lastProgressAt = now;

    if (elapsedMs < 100) return; // too little time to divide by
    final delta = bytes - first.bytes;
    final instant = delta <= 0 ? 0.0 : delta * 1000.0 / elapsedMs;

    if (instant <= 0) {
      _rate = _rate * decayFactor;
      if (_rate < 512) _rate = 0;
      return;
    }
    _rate = _rate <= 0 ? instant : _rate * (1 - smoothing) + instant * smoothing;
  }

  /// Called on a timer when no new byte count arrived. A transfer that stopped
  /// reporting has to fall to zero; the UI treats 0 as "no speed to show".
  void tick(DateTime now) {
    final lastProgress = _lastProgressAt;
    if (lastProgress == null) return;
    final idle = now.difference(lastProgress);
    if (idle <= window) return;
    _rate = _rate * decayFactor;
    if (idle > window * 4 || _rate < 512) _rate = 0;
  }

  void reset() {
    _samples.clear();
    _rate = 0;
    _lastBytes = null;
    _lastProgressAt = null;
  }
}
