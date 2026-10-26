import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../security/td_readonly_guard.dart';
import 'td_models.dart';
import 'tdjson_ffi.dart';

class TdLibUnavailable implements Exception {
  TdLibUnavailable(this.message);

  final String message;

  @override
  String toString() => 'TdLibUnavailable: $message';
}

/// Async wrapper around tdjson.
///
/// TDLib's JSON interface is single threaded: [receive] may only be called
/// from one thread, and responses are matched to requests by the echoed
/// `@extra` field. Every request therefore gets a unique `@extra` integer.
class TdClient {
  TdClient._(this._bindings, this._clientId);

  final TdJsonBindings _bindings;
  final int _clientId;

  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final StreamController<Map<String, Object?>> _updates =
      StreamController<Map<String, Object?>>.broadcast();
  Timer? _pumpTimer;
  int _nextExtra = 1;
  bool _disposed = false;
  AuthState? _authState;

  AuthState? get authState => _authState;

  Stream<Map<String, Object?>> get updates => _updates.stream;

  Stream<Map<String, Object?>> get fileUpdates => _updates.stream
      .where((e) => e['@type'] == 'updateFile')
      .map((e) => (e['file'] as Map).cast<String, Object?>());

  static TdClient open({String? libraryPath}) {
    final bindings = TdJsonBindings.tryOpen(overridePath: libraryPath);
    if (bindings == null) {
      throw TdLibUnavailable(
        'TDLib binary not found. Checked TDJSON_PATH and platform defaults. '
        'On iOS the vendored xcframework must be linked into the app binary.',
      );
    }
    final client = TdClient._(bindings, bindings.createClientId());
    client._start();
    return client;
  }

  /// Builds a client over fake bindings, without starting the receive pump.
  ///
  /// Exists so the read-only boundary can be tested behaviourally: a rejected
  /// method must leave the fake with an empty send log, which is a stronger
  /// claim than "the guard call appears earlier in the file".
  @visibleForTesting
  static TdClient withBindings(TdJsonBindings bindings, {int clientId = 1}) =>
      TdClient._(bindings, clientId);

  void _start() {
    // 20 ms polling keeps the UI isolate responsive; td_receive(0.0) is
    // non-blocking, so the loop never stalls a frame for long.
    _pumpTimer = Timer.periodic(const Duration(milliseconds: 20), (_) => _pump());
  }

  void _pump() {
    if (_disposed) return;
    try {
      while (true) {
        final raw = _bindings.receiveJson(0.0);
        if (raw == null || raw.isEmpty) break;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        _dispatch(decoded.cast<String, Object?>());
      }
    } catch (e, s) {
      debugPrint('tdjson receive loop error: $e');
      debugPrintStack(stackTrace: s);
    }
  }

  void _dispatch(Map<String, Object?> event) {
    final extra = event['@extra'];
    if (extra is int && _pending.containsKey(extra)) {
      final completer = _pending.remove(extra)!;
      if (!completer.isCompleted) completer.complete(event);
      return;
    }
    if (event['@type'] == 'updateAuthorizationState') {
      final state = event['authorization_state'];
      if (state is Map) {
        _authState = AuthState.fromJson(state.cast<String, Object?>());
      }
    }
    if (!_updates.isClosed) _updates.add(event);
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_disposed) {
      throw StateError('TdClient already disposed');
    }
    // Checked here first so a rejected call has no side effects at all (no
    // @extra consumed, no completer registered); _send re-checks as the last
    // thing before the bytes leave the process.
    TdReadOnlyGuard.assertAllowed(payload['@type'], source: 'TdClient.request');
    final extra = _nextExtra++;
    final request = <String, Object?>{...payload, '@extra': extra};
    final completer = Completer<Map<String, Object?>>();
    _pending[extra] = completer;
    _send(request);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(extra);
      throw TimeoutException(
        'TDLib did not answer ${payload['@type']} within ${timeout.inSeconds}s',
      );
    });
  }

  /// The one and only place that hands bytes to tdjson.
  ///
  /// The guard lives inside this function rather than at the call sites, so
  /// even the `close` sent from [dispose] — which deliberately skips
  /// [request] because the client is already marked disposed — cannot slip
  /// past it. test/readonly_boundary_test.dart asserts this file contains
  /// exactly one `sendJson` call.
  void _send(Map<String, Object?> request) {
    TdReadOnlyGuard.assertAllowed(request['@type'], source: 'TdClient._send');
    _bindings.sendJson(_clientId, jsonEncode(request));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pumpTimer?.cancel();
    try {
      // Routed through _send, so even shutdown passes the guard: `close` is on
      // the allowlist, and a future edit that sends something else here would
      // be rejected instead of silently escaping.
      _send(<String, Object?>{'@type': 'close'});
    } catch (_) {
      // Closing a dead client is not an error worth surfacing.
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('TdClient disposed'));
      }
    }
    _pending.clear();
    await _updates.close();
  }
}
