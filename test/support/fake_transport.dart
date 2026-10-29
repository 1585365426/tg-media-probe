/// Test doubles for the two boundaries around the download state machine:
/// TDLib (a request/response bus with an update stream) and the filesystem
/// (real temp files, because [CacheValidator] is meant to touch disk).
library;

import 'dart:async';

import 'package:tg_media_probe/download/download_manager.dart';

class FakeTdTransport implements TdTransport {
  FakeTdTransport();

  /// Requests in the order they arrived, so "exactly one downloadFile" is an
  /// assertion rather than an impression.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  final StreamController<Map<String, Object?>> _updates =
      StreamController<Map<String, Object?>>.broadcast();

  /// Answers keyed by `@type`. A null answer becomes an empty object.
  final Map<String, Map<String, Object?> Function(Map<String, Object?>)>
      handlers = <String, Map<String, Object?> Function(Map<String, Object?>)>{};

  /// When set, every request fails with this TDLib-shaped error.
  String? failWith;

  /// Requests that were sent but not answered yet, for "is it still blocked?"
  final Set<String> pending = <String>{};

  @override
  Stream<Map<String, Object?>> get updates => _updates.stream;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) async {
    requests.add(request);
    final type = request['@type'] as String? ?? '';
    if (failWith != null) {
      return <String, Object?>{
        '@type': 'error',
        'code': 400,
        'message': failWith,
      };
    }
    final handler = handlers[type];
    return handler == null ? <String, Object?>{'@type': 'ok'} : handler(request);
  }

  void emitUpdateFile({
    required int fileId,
    required int downloadedSize,
    required int size,
    required bool completed,
    String? path,
    bool active = true,
  }) {
    _updates.add(<String, Object?>{
      '@type': 'updateFile',
      'file': fileJson(
        fileId: fileId,
        downloadedSize: downloadedSize,
        size: size,
        completed: completed,
        path: path ?? '',
        active: active,
      ),
    });
  }

  static Map<String, Object?> fileJson({
    required int fileId,
    required int downloadedSize,
    required int size,
    required bool completed,
    required String path,
    bool active = false,
    int downloadedPrefixSize = 0,
  }) =>
      <String, Object?>{
        '@type': 'file',
        'id': fileId,
        'size': size,
        'expected_size': size,
        'local': <String, Object?>{
          'downloaded_size': downloadedSize,
          'downloaded_prefix_size': downloadedPrefixSize,
          'download_offset': 0,
          'is_downloading_completed': completed,
          'is_downloading_active': active,
          'can_be_downloaded': true,
          'path': path,
        },
      };

  int countOf(String type) =>
      requests.where((r) => r['@type'] == type).length;

  Future<void> close() async {
    await _updates.close();
  }
}
