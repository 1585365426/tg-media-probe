import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';
import 'package:tg_media_probe/storage/temp_zone_report.dart';

import 'support/sandbox.dart';

void main() {
  late TestSandbox box;
  late ActiveFileRegistry activeFiles;
  late TempZoneReport report;

  setUp(() async {
    box = await TestSandbox.create();
    activeFiles = ActiveFileRegistry();
    report = TempZoneReport(
      layout: box.layout,
      ops: box.ops,
      activeFiles: activeFiles,
    );
  });

  tearDown(() async {
    await box.dispose();
  });

  group('inventory', () {
    test('finds files in directories no cache kind knows about', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 100);
      // This is the shape of the bug that made the counter read 0 B while the
      // disk filled up: a writer used a directory nobody had classified.
      await box.writeBytes(
          p.join(box.layout.tempRoot, 'tdlib_files', 'videos', 'x.mp4'), 4096);
      await box.writeBytes(
          p.join(box.layout.tempRoot, 'some_new_feature', 'y.bin'), 512);

      final temp = await report.inventory(StorageZone.tempCache);

      expect(temp.exists, isTrue);
      expect(temp.error, isNull);
      expect(temp.fileCount, 3);
      expect(temp.bytes, 100 + 4096 + 512);
    });

    test('reports the largest files first and caps the list', () async {
      for (var i = 0; i < 12; i++) {
        await box.writeBytes(box.tempFile('f$i.bin'), (i + 1) * 100);
      }

      final temp = await report.inventory(StorageZone.tempCache);

      expect(temp.fileCount, 12);
      expect(temp.entries.length, ZoneInventory.keepLargest);
      expect(temp.entries.first.relativePath, endsWith('f11.bin'));

      final sizes = temp.entries.map((e) => e.bytes).toList();
      final sorted = List<int>.from(sizes)..sort((a, b) => b.compareTo(a));
      expect(sizes, orderedEquals(sorted));
    });

    test('relative paths are relative to the zone root', () async {
      final path = p.join(box.layout.tempRoot, 'tdlib_files', 'videos', 'x.mp4');
      await box.writeBytes(path, 10);

      final temp = await report.inventory(StorageZone.tempCache);

      expect(temp.entries.single.relativePath,
          p.join('tdlib_files', 'videos', 'x.mp4'));
    });

    test('a missing zone reports exists=false instead of throwing', () async {
      await Directory(box.layout.downloadsDir).delete(recursive: true);

      final downloads = await report.inventory(StorageZone.userDownloads);

      expect(downloads.exists, isFalse);
      expect(downloads.fileCount, 0);
      expect(downloads.line, '目录不存在');
      expect(downloads.error, isNull);
    });

    test('counts protected zones too, without deleting anything', () async {
      await box.writeBytes(box.downloadFile('keep.mp4'), 300);
      await box.writeBytes(box.indexFile('idx.json'), 50);
      await box.writeBytes(box.authFile('token'), 20);

      final all = await report.inventoryAll();

      expect(all[StorageZone.userDownloads]!.fileCount, 1);
      expect(all[StorageZone.indexDb]!.fileCount, 1);
      expect(all[StorageZone.authMeta]!.fileCount, 1);
      expect(await box.exists(box.downloadFile('keep.mp4')), isTrue);
    });
  });

  group('clean', () {
    test('refuses to run without explicit confirmation', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 10);

      await expectLater(
        report.cleanTempZone(userConfirmed: false),
        throwsA(isA<TempCleanNotConfirmed>()),
      );
      expect(await box.exists(box.tempFile('a.jpg')), isTrue);
    });

    test('removes temp files and leaves every protected zone untouched', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 100);
      await box.writeBytes(box.downloadFile('keep.mp4'), 300);
      await box.writeBytes(box.indexFile('idx.json'), 50);
      await box.writeBytes(box.authFile('token'), 20);

      final result = await report.cleanTempZone(userConfirmed: true);

      expect(result.deletedFiles, 1);
      expect(result.freedBytes, 100);
      expect(result.succeeded, isTrue);
      expect(result.protectedZonesIntact, isTrue);

      expect(await box.exists(box.downloadFile('keep.mp4')), isTrue);
      expect(await box.exists(box.indexFile('idx.json')), isTrue);
      expect(await box.exists(box.authFile('token')), isTrue);
    });

    test('reaches a nested directory that no cache kind knows about', () async {
      final deep = p.join(box.layout.tempRoot, 'brand_new', 'deep', 'z.bin');
      await box.writeBytes(deep, 777);

      final result = await report.cleanTempZone(userConfirmed: true);

      expect(result.deletedFiles, 1);
      expect(result.freedBytes, 777);
      expect(await box.exists(deep), isFalse);
    });

    test('counts bytes only for files that are really gone', () async {
      await box.writeBytes(box.tempFile('a.bin'), 128);
      await box.writeBytes(box.tempFile('b.bin'), 256);

      final result = await report.cleanTempZone(userConfirmed: true);

      expect(result.scannedFiles, 2);
      expect(result.scannedBytes, 384);
      expect(result.deletedFiles, 2);
      expect(result.freedBytes, 384);

      final after = await report.inventory(StorageZone.tempCache);
      expect(after.fileCount, 0);
      expect(after.bytes, 0);
    });

    test('skips a file the player holds open, then frees it on release', () async {
      final playing = box.tempFile('playing.mp4');
      await box.writeBytes(playing, 900);
      activeFiles.markInUse(playing, reason: 'playing');

      final blocked = await report.cleanTempZone(userConfirmed: true);

      expect(blocked.deletedFiles, 0);
      expect(blocked.skippedInUse, hasLength(1));
      expect(await box.exists(playing), isTrue);

      activeFiles.release(playing);
      final freed = await report.cleanTempZone(userConfirmed: true);

      expect(freed.deletedFiles, 1);
      expect(await box.exists(playing), isFalse);
    });

    test('an empty temp zone reports nothing to do and still succeeds', () async {
      final result = await report.cleanTempZone(userConfirmed: true);

      expect(result.scannedFiles, 0);
      expect(result.nothingToDo, isTrue);
      expect(result.deletedFiles, 0);
      expect(result.succeeded, isTrue);
    });

    test('progress covers every candidate and ends at the total', () async {
      for (var i = 0; i < 3; i++) {
        await box.writeBytes(box.tempFile('p$i.bin'), 10);
      }

      final seen = <int>[];
      var lastTotal = -1;
      await report.cleanTempZone(
        userConfirmed: true,
        onProgress: (done, total, name) {
          seen.add(done);
          lastTotal = total;
        },
      );

      expect(lastTotal, 3);
      expect(seen.first, 0);
      expect(seen.last, 3);
      expect(seen.length, 4);
    });

    test('recreates the temp sub-directories after clearing', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 10);

      await report.cleanTempZone(userConfirmed: true);

      expect(await Directory(box.layout.thumbnailDir).exists(), isTrue);
      expect(await Directory(box.layout.playbackTempDir).exists(), isTrue);
      expect(await Directory(box.layout.partialDownloadDir).exists(), isTrue);
      expect(await Directory(box.layout.tdlibFilesDir).exists(), isTrue);
    });

    test('is idempotent', () async {
      await box.writeBytes(box.tempFile('a.jpg'), 10);
      await report.cleanTempZone(userConfirmed: true);

      final second = await report.cleanTempZone(userConfirmed: true);

      expect(second.deletedFiles, 0);
      expect(second.succeeded, isTrue);
    });
  });

  group('report semantics', () {
    test('a protected zone that vanished during the run fails the report', () {
      const result = TempCleanReport(
        scannedFiles: 1,
        scannedBytes: 10,
        deletedFiles: 1,
        freedBytes: 10,
        skippedInUse: <String>[],
        refusedByGuard: <String>[],
        failures: <MapEntry<String, String>>[],
        protectedZonesBefore: <StorageZone, bool>{
          StorageZone.userDownloads: true,
        },
        protectedZonesAfter: <StorageZone, bool>{
          StorageZone.userDownloads: false,
        },
      );

      expect(result.protectedZonesIntact, isFalse);
      expect(result.succeeded, isFalse);
      expect(result.summary, contains('受保护目录发生变化'));
    });

    test('a guard refusal is reported but does not fake success', () {
      const result = TempCleanReport(
        scannedFiles: 1,
        scannedBytes: 10,
        deletedFiles: 0,
        freedBytes: 0,
        skippedInUse: <String>[],
        refusedByGuard: <String>['x: path escapes the zone root'],
        failures: <MapEntry<String, String>>[],
        protectedZonesBefore: <StorageZone, bool>{},
        protectedZonesAfter: <StorageZone, bool>{},
      );

      expect(result.succeeded, isFalse);
      expect(result.summary, contains('越界拒绝 1 个'));
    });
  });
}
