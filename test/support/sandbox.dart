import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/file_ops.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

/// Temporary sandbox that mirrors the iOS directory layout, so tests exercise
/// the same [StorageLayout] the app builds on device.
class TestSandbox {
  TestSandbox._(this.root, this.ops, this.layout);

  final Directory root;
  final FileOps ops;
  final StorageLayout layout;

  static Future<TestSandbox> create() async {
    final dir = await Directory.systemTemp.createTemp('tgmedia_test_');
    const ops = IoFileOps();
    final layout = StorageLayout.forSandbox(dir.path, ops: ops);
    await layout.ensureCreated();
    await ops.createDirectory(layout.downloadsDir);
    await ops.createDirectory(layout.indexDir);
    await ops.createDirectory(layout.authMetaDir);
    return TestSandbox._(dir, ops, layout);
  }

  String tempFile(String name, {CacheKindName kind = CacheKindName.thumb}) {
    final dir = switch (kind) {
      CacheKindName.thumb => layout.thumbnailDir,
      CacheKindName.player => layout.playbackTempDir,
      CacheKindName.partial => layout.partialDownloadDir,
    };
    return p.join(dir, name);
  }

  String downloadFile(String name) => p.join(layout.downloadsDir, name);

  String indexFile(String name) => p.join(layout.indexDir, name);

  String authFile(String name) => p.join(layout.authMetaDir, name);

  Future<void> write(String path, String content) => ops.writeAsString(path, content);

  Future<void> writeBytes(String path, int bytes) =>
      ops.writeAsString(path, 'x' * bytes);

  Future<bool> exists(String path) => ops.exists(path);

  Future<void> dispose() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup must never fail a test run.
    }
  }
}

enum CacheKindName { thumb, player, partial }
