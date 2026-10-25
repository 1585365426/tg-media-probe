import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/file_ops.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/sandbox.dart';

/// Fake ops that resolves one specific path to somewhere else, standing in for a
/// symlink that points outside the zone. Creating a real symlink needs
/// privileges on Windows, and the defence under test is the containment check,
/// not the OS call.
class _EscapingOps extends IoFileOps {
  _EscapingOps(this.victim, this.escapeTarget);

  final String victim;
  final String escapeTarget;

  @override
  Future<String> realPath(String path) async {
    if (p.equals(path, victim)) return escapeTarget;
    return super.realPath(path);
  }
}

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  group('layout', () {
    test('four zones are physically disjoint', () {
      final roots = sandbox.layout.allRoots.values.toList();
      expect(roots.toSet().length, roots.length);
      for (var i = 0; i < roots.length; i++) {
        for (var j = 0; j < roots.length; j++) {
          if (i == j) continue;
          expect(p.isWithin(roots[i], roots[j]), isFalse,
              reason: '${roots[i]} must not contain ${roots[j]}');
        }
      }
    });

    test('overlapping zones are rejected at construction', () {
      expect(
        () => StorageLayout.explicit(
          tempRoot: p.join(sandbox.root.path, 'a'),
          downloadsRoot: p.join(sandbox.root.path, 'a', 'nested'),
          indexRoot: p.join(sandbox.root.path, 'b'),
          authRoot: p.join(sandbox.root.path, 'c'),
        ),
        throwsArgumentError,
      );
    });

    test('only tempCache is deletable by the cache cleaner', () {
      expect(StorageZone.tempCache.isClearedByCacheClear, isTrue);
      expect(StorageZone.userDownloads.isClearedByCacheClear, isFalse);
      expect(StorageZone.indexDb.isClearedByCacheClear, isFalse);
      expect(StorageZone.authMeta.isClearedByCacheClear, isFalse);
    });
  });

  group('containment', () {
    test('accepts a real temp file', () async {
      final path = sandbox.tempFile('a.jpg');
      await sandbox.write(path, 'x');
      await sandbox.layout.assertDeletableByCacheClear(path);
    });

    test('rejects user downloads', () async {
      final path = sandbox.downloadFile('keep.mp4');
      await sandbox.write(path, 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(path),
        throwsA(isA<ZoneViolation>().having(
            (e) => e.zone, 'zone', StorageZone.userDownloads)),
      );
    });

    test('rejects the index database', () async {
      final path = sandbox.indexFile('media_journal.jsonl');
      await sandbox.write(path, 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(path),
        throwsA(isA<ZoneViolation>()
            .having((e) => e.zone, 'zone', StorageZone.indexDb)),
      );
    });

    test('rejects account data', () async {
      final path = sandbox.authFile('session.json');
      await sandbox.write(path, 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(path),
        throwsA(isA<ZoneViolation>()
            .having((e) => e.zone, 'zone', StorageZone.authMeta)),
      );
    });

    test('rejects a path that escapes with ..', () async {
      final escaped = p.join(
        sandbox.layout.thumbnailDir,
        '..',
        '..',
        '..',
        '..',
        '..',
        'Documents',
        'TGMediaDownloads',
        'keep.mp4',
      );
      await sandbox.write(sandbox.downloadFile('keep.mp4'), 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(escaped),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('rejects a sibling directory sharing the prefix', () async {
      final sibling = '${sandbox.layout.tempRoot}_evil';
      await sandbox.ops.createDirectory(sibling);
      final path = p.join(sibling, 'x.jpg');
      await sandbox.write(path, 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(path),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('rejects a zone root itself', () async {
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(sandbox.layout.tempRoot),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('rejects a symlink that resolves outside the zone', () async {
      final victim = sandbox.tempFile('link.jpg');
      await sandbox.write(victim, 'x');
      final layout = StorageLayout.forSandbox(
        sandbox.root.path,
        ops: _EscapingOps(victim, sandbox.downloadFile('keep.mp4')),
      );
      await expectLater(
        layout.assertDeletableByCacheClear(victim),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('rejects a path outside every zone', () async {
      final outside = p.join(sandbox.root.path, 'elsewhere', 'x.jpg');
      await sandbox.write(outside, 'x');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(outside),
        throwsA(isA<ZoneViolation>()),
      );
    });
  });
}
