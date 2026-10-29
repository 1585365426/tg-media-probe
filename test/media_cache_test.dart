/// Media cache: size accounting, room checks, and a clear that only ever
/// deletes inside the app's own media root.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/platform/disk_space.dart';
import 'package:tg_media_probe/storage/file_ops.dart';

import 'support/sandbox.dart';

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
    await Directory(sandbox.layout.tdlibFilesDir).create(recursive: true);
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  MediaCache cacheWith(int free) => MediaCache(
        layout: sandbox.layout,
        ops: const IoFileOps(),
        diskSpace: FixedDiskSpace(free),
      );

  Future<String> writeMedia(String name, int bytes) async {
    final path = p.join(sandbox.layout.tdlibFilesDir, name);
    await sandbox.writeBytes(path, bytes);
    return path;
  }

  test('usedBytes sums the media root only', () async {
    await writeMedia('a.mp4', 1000);
    await writeMedia('b.mp4', 2000);
    await sandbox.writeBytes(sandbox.tempFile('thumb.jpg'), 5000);
    expect(await cacheWith(-1).usedBytes(), 3000);
  });

  test('hasRoomFor keeps a safety margin', () async {
    final cache = cacheWith(MediaCache.spaceMargin + 1000);
    expect(await cache.hasRoomFor(1000), isTrue);
    expect(await cache.hasRoomFor(1001), isFalse);
  });

  test('an unmeasurable free space does not block a download', () async {
    expect(await cacheWith(-1).hasRoomFor(10 * 1024 * 1024 * 1024), isTrue);
  });

  test('clearLocal deletes media files and reports the freed bytes', () async {
    final path = await writeMedia('a.mp4', 1234);
    final wipe = await cacheWith(-1).clearLocal();
    expect(wipe.deletedFiles, 1);
    expect(wipe.freedBytes, 1234);
    expect(await sandbox.exists(path), isFalse);
  });

  test('clearLocal keeps the file the player has open', () async {
    final kept = await writeMedia('playing.mp4', 10);
    await writeMedia('other.mp4', 10);
    final wipe = await cacheWith(-1)
        .clearLocal(keep: <String>{p.normalize(p.absolute(kept))});
    expect(wipe.deletedFiles, 1);
    expect(wipe.skipped, hasLength(1));
    expect(await sandbox.exists(kept), isTrue);
  });

  test('clearLocal never reaches outside the media root', () async {
    final protectedPath = sandbox.indexFile('media_snapshot.json');
    await sandbox.write(protectedPath, '{"records":[]}');
    await writeMedia('a.mp4', 10);

    final wipe = await cacheWith(-1).clearLocal();
    expect(wipe.deletedFiles, 1);
    expect(await sandbox.exists(protectedPath), isTrue);
  });
}
