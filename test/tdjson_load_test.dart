import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/tdjson_ffi.dart';

/// Runtime load test for the native library.
///
/// On the Windows dev box there is no TDLib binary, so this test is skipped
/// and the load path stays 未验证 until it runs inside the iOS build (or with
/// TDJSON_PATH pointing at a local build).
void main() {
  final path = Platform.environment['TDJSON_PATH'];

  test('tdjson loads and creates a client id', () {
    final bindings = TdJsonBindings.tryOpen(overridePath: path);
    expect(bindings, isNotNull, reason: 'TDLib binary not loadable from $path');
    final clientId = bindings!.createClientId();
    expect(clientId, greaterThanOrEqualTo(0));
    final state = bindings.executeJson('{"@type":"getOption","name":"version"}');
    expect(state, isNotNull);
  },
      skip: (path == null || path.isEmpty)
          ? 'TDJSON_PATH 未设置：本机无 TDLib 二进制，运行时加载未验证'
          : false);
}
