/// The LOCAL_FILE architecture as a hard gate.
///
/// These are not behaviour tests. They read the source and fail when a module
/// that must not exist comes back: a resource loader, a range proxy, a growing
/// file reader, a second player chain, a deleted tab. A green suite here is what
/// makes "only a complete local file is ever played" a checked fact instead of a
/// review comment.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strips `//` line comments so prose about a banned symbol cannot fail a scan
/// that is only about code.
String code(String source) {
  final buffer = StringBuffer();
  for (final line in source.split('\n')) {
    final index = line.indexOf('//');
    buffer.writeln(index < 0 ? line : line.substring(0, index));
  }
  return buffer.toString();
}

Iterable<File> dartFiles(String root) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}

void main() {
  final lib = dartFiles('lib').toList();
  final ios = Directory('ios/Runner')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.swift') || f.path.endsWith('.m'))
      .toList();

  test('the old streaming modules are gone', () {
    for (final name in <String>[
      'resource_loader.dart',
      'stream_proxy.dart',
      'growing_file_reader.dart',
      'native_streaming.dart',
      'streaming_diagnostics.dart',
      'source_decision.dart',
      'stream_window.dart',
      'video_source.dart',
      'downloader.dart',
      'player_slot.dart',
      'video_player_handle.dart',
    ]) {
      expect(File('lib/playback/$name').existsSync(), isFalse,
          reason: '$name must not come back');
    }
  });

  test('lib/playback contains only the local player and its controller', () {
    final names = Directory('lib/playback')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(names, <String>['local_media_player.dart', 'playback_controller.dart']);
  });

  test('nothing references a resource loader, proxy or growing file', () {
    const banned = <String>[
      'AVAssetResourceLoader',
      'TGMediaResourceLoader',
      'ResourceLoaderHost',
      'StreamProxy',
      'stream_proxy',
      'GrowingFileReader',
      'ChunkMediaPlayer',
      'tgmedia://',
      'VideoPlayerController.networkUrl',
    ];
    for (final file in lib) {
      final source = code(file.readAsStringSync());
      for (final token in banned) {
        expect(source.contains(token), isFalse,
            reason: '${file.path} still mentions $token');
      }
    }
  });

  test('the iOS side has no streaming bridge left', () {
    expect(Directory('ios/Runner/Streaming').existsSync(), isFalse);
    for (final file in ios) {
      final source = file.readAsStringSync();
      expect(source.contains('AVAssetResourceLoaderDelegate'), isFalse,
          reason: '${file.path} still implements a resource loader');
      expect(source.contains('TGMediaStreamingPlugin'), isFalse,
          reason: '${file.path} still registers the streaming plugin');
    }
  });

  test('downloadFile is only issued by the download manager', () {
    final callers = <String>[];
    for (final file in lib) {
      final source = code(file.readAsStringSync());
      if (source.contains('downloadFile(') &&
          !file.path.endsWith('td_requests.dart') &&
          !file.path.endsWith('download_manager.dart')) {
        callers.add(file.path);
      }
    }
    expect(callers, isEmpty);
  });

  test('the player opens a file, never a network URL', () {
    final source = code(File('lib/playback/local_media_player.dart').readAsStringSync());
    expect(source.contains('VideoPlayerController.file'), isTrue);
    expect(source.contains('http'), isFalse);
  });

  test('the shell has exactly two tabs and no 抖音', () {
    final source = File('lib/app/app_root.dart').readAsStringSync();
    expect(
      RegExp(r'BottomNavigationBarItem\(').allMatches(source).length,
      2,
      reason: 'the shell must define exactly two tabs',
    );
    expect(source.contains('抖音'), isFalse);
    expect(source.contains("label: '频道'"), isTrue);
    expect(source.contains("label: '设置'"), isTrue);
  });

  test('no long-press handler exists on the player', () {
    final source = code(File('lib/ui/video_player_page.dart').readAsStringSync());
    expect(source.contains('onLongPress'), isFalse);
  });

  test('the badge is off unless the preference says otherwise', () {
    final prefs = File('lib/app/app_preferences.dart').readAsStringSync();
    expect(prefs.contains('this.diagnosticBadge = false'), isTrue);
  });

  test('the media cache lives outside Library/Caches', () {
    final layout = File('lib/storage/storage_layout.dart').readAsStringSync();
    // Derived from the index root (Application Support), never from the
    // purgeable Caches root.
    expect(
      layout.contains("p.join(p.dirname(p.absolute(indexRoot)), 'media')"),
      isTrue,
      reason: 'mediaRoot must sit beside the index, not in Library/Caches',
    );
    expect(layout.contains("p.join(tempRoot, 'tdlib_files')"), isFalse);
  });

  test('the retired cache-policy layer is gone', () {
    for (final path in <String>[
      'lib/storage/cache_manager.dart',
      'lib/storage/cache_budget.dart',
      'lib/storage/active_files.dart',
      'lib/storage/temp_zone_report.dart',
      'lib/storage/cache_ownership.dart',
      'lib/ui/storage_panel.dart',
    ]) {
      expect(File(path).existsSync(), isFalse,
          reason: '$path belongs to the streaming-era cache cleaner');
    }
  });

  test('local media bytes are deleted by one module only', () {
    // Allowed: the file operations themselves, the download manager's
    // `deleteFile` TDLib call, the media cache's clear pass, and the session
    // reset, which removes its own index journal (never media).
    const allowed = <String>[
      'file_ops.dart',
      'media_cache.dart',
      'download_manager.dart',
      'td_requests.dart',
      'app_session.dart',
    ];
    final callers = <String>[];
    for (final file in lib) {
      final source = code(file.readAsStringSync());
      if (source.contains('deleteFile(') &&
          !allowed.any((name) => file.path.endsWith(name))) {
        callers.add(file.path);
      }
    }
    expect(callers, isEmpty,
        reason: 'a second deleter of local bytes is how "clear cache" starts '
            'eating things it does not own');
  });

  test('favourites, history and duration filters left no code behind', () {
    const banned = <String>['favorite', '收藏', '时长筛选', '下载历史', '下载任务'];
    for (final file in lib) {
      final source = file.readAsStringSync();
      for (final token in banned) {
        expect(source.contains(token), isFalse,
            reason: '${file.path} still mentions $token');
      }
    }
  });
}
