/// Generation counter for "only the newest request may touch the UI".
///
/// The pattern it replaces, which appeared in three places already: an async
/// call is started, the user moves on, the call finishes and writes its result
/// into a field that now belongs to something else. The symptom is a video that
/// jumps back to the previous one, or a spinner that stops on the wrong row.
///
/// The rule this enforces: a result is applied only if its token is still the
/// newest one issued. Everything else is dropped — not queued, not logged as an
/// error, just dropped.
library;

/// Issues tokens and validates them.
class LatestOnly {
  LatestOnly({int start = 0}) : _current = start;

  int _current;

  /// Number of tokens issued so far. Exposed for tests and diagnostics.
  int get current => _current;

  /// Claims the next generation. Any outstanding token becomes stale.
  int issue() => ++_current;

  /// True when [token] is the one [issue] returned last.
  bool accepts(int token) => token == _current;

  /// Invalidates everything issued so far, without issuing a new token.
  void invalidate() => _current++;
}

/// Runs at most one task "for real", keeping the newest result and discarding
/// late ones.
///
/// ```dart
/// final slot = LatestOnlySlot<int>();
/// final value = await slot.run(() => loadPage(3));
/// if (value == null) return; // a newer call started; this one is obsolete
/// ```
class LatestOnlySlot<T> {
  final LatestOnly _gate = LatestOnly();

  int get issued => _gate.current;

  /// Runs [task] and returns its value only when no newer call started while it
  /// was running. Returns null when the result is obsolete, and also when
  /// [task] completes with null — callers must not treat null as an error.
  Future<T?> run(Future<T> Function() task) async {
    final token = _gate.issue();
    try {
      final value = await task();
      if (!_gate.accepts(token)) return null;
      return value;
    } on Object {
      // The obsolete path must not throw: the caller already moved on, and an
      // error popup for a cancelled page load is noise.
      if (!_gate.accepts(token)) return null;
      rethrow;
    }
  }

  /// Drops every outstanding token. Call from `dispose()` so a task that
  /// completes after the widget is gone cannot write into it.
  void cancelAll() => _gate.invalidate();
}

/// Small bounded cache for cancelled-then-restarted work, used to stop the same
/// thumbnail from being requested twice while the first request is still in
/// flight.
class InFlightRegistry {
  /// Maximum entries before the oldest is evicted. A paged feed holds 30 to 50
  /// per page, so 96 covers two pages plus a prefetch window.
  InFlightRegistry({this.maxEntries = 96});

  final int maxEntries;
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  final List<String> _order = <String>[];

  int get length => _inFlight.length;

  bool contains(String key) => _inFlight.containsKey(key);

  /// Returns the existing future for [key] when one is already running.
  Future<void> fetch(String key, Future<void> Function() load) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = load().whenComplete(() {
      _inFlight.remove(key);
      _order.remove(key);
    });
    _inFlight[key] = future;
    _order.add(key);
    _evictIfNeeded();
    return future;
  }

  void _evictIfNeeded() {
    while (_order.length > maxEntries) {
      final oldest = _order.removeAt(0);
      // The future itself keeps running; only the dedupe entry is dropped, so a
      // second request for that key starts a fresh load instead of being told
      // "already loading" forever.
      _inFlight.remove(oldest);
    }
  }

  void clear() {
    _inFlight.clear();
    _order.clear();
  }
}
