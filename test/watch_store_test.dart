/// Watch state: resume, finish, reset, and the rule that a broken disk must not
/// break playback.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/playback/watch_store.dart';
import 'package:tg_media_probe/storage/file_ops.dart';

import 'support/sandbox.dart';

/// FileOps whose writes always fail, to prove the feed degrades quietly.
class _BrokenOps extends IoFileOps {
  @override
  Future<void> writeAsString(String path, String data) async {
    throw const FileSystemException('disk full (simulated)');
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

  WatchStore store({FileOps? ops}) => WatchStore(
        directory: sandbox.layout.indexDir,
        ops: ops ?? sandbox.ops,
      );

  group('resume rules', () {
    WatchEntry entry({
      required int position,
      int duration = 60000,
      bool completed = false,
    }) =>
        WatchEntry(
          chatId: 1,
          messageId: 10,
          positionMs: position,
          durationMs: duration,
          completed: completed,
          updatedAtUnix: 1,
        );

    test('a finished video starts from the beginning', () {
      expect(entry(position: 60000, completed: true).resumePositionMs, 0);
    });

    test('a position of a few seconds is treated as noise', () {
      expect(entry(position: 2500).resumePositionMs, 0);
    });

    test('a normal position resumes two seconds earlier', () {
      expect(entry(position: 30000).resumePositionMs, 28000);
    });

    test('a position in the last 5% restarts instead of resuming', () {
      // Resuming three seconds before the end is worse than replaying.
      expect(entry(position: 59000).resumePositionMs, 0);
    });

    test('a zero duration does not produce a negative resume point', () {
      final e = entry(position: 5000, duration: 0);
      expect(e.resumePositionMs, greaterThanOrEqualTo(0));
    });
  });

  group('persistence', () {
    test('a position survives a new store instance (restart)', () async {
      final first = store();
      await first.upsert(
        1,
        10,
        (current, now) => current.copyWith(
          positionMs: 42000,
          durationMs: 60000,
          updatedAtUnix: now,
        ),
        nowUnix: 1700000000,
      );

      final second = store();
      await second.load();
      final restored = second.read(1, 10);

      expect(restored, isNotNull);
      expect(restored!.positionMs, 42000);
      expect(restored.resumePositionMs, 40000);
      expect(File(p.join(sandbox.layout.indexDir, 'watch.json')).existsSync(),
          isTrue);
    });

    test('the file is written atomically and leaves no temp behind', () async {
      final s = store();
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 5000, updatedAtUnix: now));
      await s.upsert(1, 11, (c, now) => c.copyWith(positionMs: 6000, updatedAtUnix: now));

      final dir = Directory(sandbox.layout.indexDir);
      final temps = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(temps, isEmpty);
    });

    test('two videos are independent', () async {
      final s = store();
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 30000, updatedAtUnix: now));
      await s.upsert(1, 11, (c, now) => c.copyWith(positionMs: 0, completed: true, updatedAtUnix: now));

      await s.load();
      expect(s.read(1, 10)!.positionMs, 30000);
      expect(s.read(1, 11)!.completed, isTrue);
      expect(s.entries, hasLength(2));
    });

    test('the same message id in another chat is a different row', () async {
      final s = store();
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 12000, updatedAtUnix: now));

      await s.load();
      expect(s.read(2, 10), isNull);
    });

    test('a corrupt file is an empty history, not a crash', () async {
      await sandbox.write(p.join(sandbox.layout.indexDir, 'watch.json'), '{not json');
      final s = store();
      await s.load();

      expect(s.entries, isEmpty);
      // And it can still be written afterwards.
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 1000, updatedAtUnix: now));
      final again = store();
      await again.load();
      expect(again.read(1, 10)!.positionMs, 1000);
    });
  });

  group('finish and reset', () {
    test('marking finished keeps the position but restarts playback', () async {
      final s = store();
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 60000, durationMs: 60000, updatedAtUnix: now));
      await s.upsert(1, 10, (c, now) => c.copyWith(completed: true, updatedAtUnix: now));

      await s.load();
      final e = s.read(1, 10)!;
      expect(e.completed, isTrue);
      expect(e.resumePositionMs, 0);
    });

    test('reset removes the row so the video starts over', () async {
      final s = store();
      await s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 30000, updatedAtUnix: now));

      await s.clear(1, 10);

      await s.load();
      expect(s.read(1, 10), isNull);
    });

    test('clearing an unknown row is a no-op', () async {
      final s = store();
      await s.clear(99, 99);
      expect(s.entries, isEmpty);
    });
  });

  group('a failing disk does not break playback', () {
    test('a write failure surfaces to the caller', () async {
      final s = store(ops: _BrokenOps());
      await expectLater(
        s.upsert(1, 10, (c, now) => c.copyWith(positionMs: 5000, updatedAtUnix: now)),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('reading with a broken store still returns null instead of throwing',
        () async {
      final s = WatchStore(
        directory: sandbox.layout.indexDir,
        ops: _BrokenOps(),
      );
      await s.load();
      expect(s.read(1, 10), isNull);
    });
  });
}
