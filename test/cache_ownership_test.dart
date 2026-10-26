import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/cache_ownership.dart';

import 'support/sandbox.dart';

void main() {
  late TestSandbox box;

  setUp(() async {
    box = await TestSandbox.create();
  });

  tearDown(() async {
    await box.dispose();
  });

  group('registry consistency', () {
    test('every registered id matches the directory StorageLayout creates', () {
      // A rename on either side would otherwise silently stop cleanup for that
      // directory: the layout would write to `files/` while the whitelist still
      // says `tdlib_files/`, and the only symptom would be a pool that never
      // shrinks.
      final names = CacheOwnership.expectedDirectoryNames(box.layout);
      for (final writer in CacheOwnership.writers) {
        expect(names[writer.id], writer.id,
            reason: 'writer ${writer.id} does not match its layout directory');
      }
      expect(
        names.keys.toSet(),
        CacheOwnership.writers.map((w) => w.id).toSet(),
        reason: 'a layout directory has no registered writer, or the reverse',
      );
    });

    test('every writer has a non-empty label', () {
      for (final writer in CacheOwnership.writers) {
        expect(writer.label.trim(), isNotEmpty, reason: writer.id);
      }
    });

    test('writerById finds registered ids and rejects the rest', () {
      expect(CacheOwnership.writerById('thumb'), isNotNull);
      expect(CacheOwnership.writerById('tdlib_files'), isNotNull);
      expect(CacheOwnership.writerById('something_else'), isNull);
    });
  });

  group('classify', () {
    test('a file under thumb is known', () {
      final path = p.join(box.layout.thumbnailDir, 'a.jpg');
      final result = CacheOwnership.classify(box.layout, path);
      expect(result.known, isTrue);
      expect(result.writer!.id, 'thumb');
      expect(result.writer!.label, '缩略图');
    });

    test('a deeply nested file under a known writer is known', () {
      final path =
          p.join(box.layout.tdlibFilesDir, 'videos', '2026', '01', 'x.mp4');
      expect(CacheOwnership.isKnown(box.layout, path), isTrue);
    });

    test('a file under an unregistered directory is unknown', () {
      final path = p.join(box.layout.tempRoot, 'new_feature', 'x.bin');
      final result = CacheOwnership.classify(box.layout, path);
      expect(result.known, isFalse);
      expect(result.reason, contains('未登记'));
      expect(result.writer, isNull);
    });

    test('a file directly at the temp root is unknown', () {
      final path = p.join(box.layout.tempRoot, 'loose.bin');
      final result = CacheOwnership.classify(box.layout, path);
      expect(result.known, isFalse);
      expect(result.reason, contains('散落'));
    });

    test('the temp root itself is not a file and is not known', () {
      expect(CacheOwnership.isKnown(box.layout, box.layout.tempRoot), isFalse);
    });

    test('a path outside the temp zone is unknown', () {
      final outside = p.join(box.layout.downloadsDir, 'thumb', 'a.jpg');
      final result = CacheOwnership.classify(box.layout, outside);
      expect(result.known, isFalse);
      expect(result.reason, contains('不在临时缓存目录内'));
    });

    test('a path that only looks like a known writer is rejected', () {
      // `thumb_old/` must not be accepted because it starts with the same
      // characters. Classification splits path segments, so it does not.
      final path = p.join(box.layout.tempRoot, 'thumb_old', 'a.jpg');
      expect(CacheOwnership.isKnown(box.layout, path), isFalse);
    });

    test('a path traversing out of the temp root is unknown', () {
      final path =
          p.join(box.layout.tempRoot, 'thumb', '..', '..', 'Documents', 'x.mp4');
      // p.isWithin normalises the `..` segments, so this resolves outside.
      expect(CacheOwnership.isKnown(box.layout, path), isFalse);
    });

    test('classification is pure string work and needs no filesystem', () {
      // No file is created here on purpose: the clear loop calls this once per
      // candidate and must not pay a realpath per file.
      final path = p.join(box.layout.tempRoot, 'player', 'session', 'a.mp4');
      expect(CacheOwnership.isKnown(box.layout, path), isTrue);
    });
  });

  group('writes that are deliberately not cleanable', () {
    test('a writer could be declared non-rebuildable', () {
      // Documents the extension point: the flag exists so a future writer that
      // must survive a clear has somewhere to say so, instead of relying on
      // nobody adding it to the list.
      const writer = CacheWriter(
        id: 'x',
        label: 'x',
        rebuildable: false,
      );
      expect(writer.rebuildable, isFalse);
    });
  });
}
