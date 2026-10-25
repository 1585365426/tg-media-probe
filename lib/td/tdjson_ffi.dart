import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Low level bindings to TDLib's JSON client interface (tdjson).
///
/// The four exported C symbols are the whole public surface we rely on:
///   int td_create_client_id()
///   void td_send(int client_id, const char *request)
///   const char *td_receive(double timeout)
///   const char *td_execute(const char *request)
class TdJsonBindings {
  TdJsonBindings._(this.libraryPath, this._createClientId, this._send,
      this._receive, this._execute);

  /// Path (or pseudo path) of the loaded binary, kept for diagnostics.
  final String libraryPath;

  final int Function() _createClientId;
  final void Function(int clientId, Pointer<Utf8> request) _send;
  final Pointer<Utf8> Function(double timeout) _receive;
  final Pointer<Utf8> Function(Pointer<Utf8> request) _execute;

  static TdJsonBindings? _instance;

  /// Loads tdjson once. Returns null when the binary cannot be located so the
  /// caller can surface a precise error instead of crashing at startup.
  static TdJsonBindings? tryOpen({String? overridePath}) {
    if (_instance != null) return _instance;
    for (final candidate in _candidates(overridePath)) {
      try {
        final lib = candidate == '@process'
            ? DynamicLibrary.process()
            : DynamicLibrary.open(candidate);
        final bindings = TdJsonBindings._(
          candidate,
          lib.lookupFunction<Int32 Function(), int Function()>(
              'td_create_client_id'),
          lib.lookupFunction<Void Function(Int32, Pointer<Utf8>),
              void Function(int, Pointer<Utf8>)>('td_send'),
          lib.lookupFunction<Pointer<Utf8> Function(Double),
              Pointer<Utf8> Function(double)>('td_receive'),
          lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
              Pointer<Utf8> Function(Pointer<Utf8>)>('td_execute'),
        );
        return _instance = bindings;
      } catch (_) {
        // Try the next candidate: frameworks and dylib naming differ per build.
        continue;
      }
    }
    return null;
  }

  static List<String> _candidates(String? overridePath) {
    if (overridePath != null && overridePath.isNotEmpty) {
      return <String>[overridePath];
    }
    final env = Platform.environment['TDJSON_PATH'];
    if (env != null && env.isNotEmpty) {
      return <String>[env];
    }
    if (Platform.isIOS) {
      // Static link (vendored xcframework) exposes the symbols in the app
      // binary itself, so process() is tried first.
      return const <String>[
        '@process',
        'TDLibFramework.framework/TDLibFramework',
        'tdjson.framework/tdjson',
        'libtdjson.dylib',
      ];
    }
    if (Platform.isMacOS) {
      return const <String>[
        '@process',
        'libtdjson.dylib',
        'TDLibFramework.framework/TDLibFramework',
      ];
    }
    if (Platform.isAndroid) {
      return const <String>['libtdjson.so'];
    }
    if (Platform.isWindows) {
      return const <String>['tdjson.dll', 'libtdjson.dll'];
    }
    return const <String>['libtdjson.so'];
  }

  int createClientId() => _createClientId();

  /// Sends one JSON request. TDLib copies the string synchronously, so the
  /// native allocation is released immediately after the call returns.
  void sendJson(int clientId, String json) {
    final native = json.toNativeUtf8();
    try {
      _send(clientId, native);
    } finally {
      malloc.free(native);
    }
  }

  /// Non-blocking receive. Returns null when no event is pending.
  ///
  /// The returned buffer is owned by TDLib and is overwritten by the next
  /// receive call, therefore it is copied to a Dart string and never freed.
  String? receiveJson([double timeout = 0.0]) {
    final ptr = _receive(timeout);
    if (ptr == nullptr) return null;
    return ptr.toDartString();
  }

  /// Synchronous request; only valid for methods marked callable synchronously.
  String? executeJson(String json) {
    final native = json.toNativeUtf8();
    try {
      final res = _execute(native);
      if (res == nullptr) return null;
      return res.toDartString();
    } finally {
      malloc.free(native);
    }
  }
}
