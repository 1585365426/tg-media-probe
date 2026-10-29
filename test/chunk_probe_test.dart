import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/chunk_probe.dart';
import 'package:tg_media_probe/td/td_models.dart';

/// Tests for the parts of E1 that can be decided without a TDLib.
///
/// Nothing here simulates a download. The engine that talks to TDLib is not
/// exercised by any test on purpose: a fake `updateFile` sequence would produce
/// a green tick for behaviour nobody has observed, which is exactly the
/// "假通过" this phase forbids. What *is* covered is the arithmetic and the
/// verdict rules, because a wrong verdict would mislabel a real run.

const int _mb = 1 << 20;

/// 64-hex digests, so a formatted comparison prints the same width as a real
/// SHA-256 and a truncation bug cannot hide behind a short string.
const String _shaA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _shaB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String _shaC =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const String _shaD =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

ChunkRow _row({
  int index = 0,
  int offset = 0,
  int limit = _mb,
  bool satisfied = true,
  String gate = 'prefixFromOffset',
  int posixBytes = _mb,
  String? posixError,
  String posixSha = _shaA,
  int partBytes = _mb,
  String? partError,
  String partSha = _shaA,
  int? prefixFromZero,
  int? prefixFromOffset,
  int activeRuns = 1,
  bool offsetDrift = false,
  int maxGapMs = 20,
  String? ackError,
  int diskAfter = _mb,
  int? downloadOffset,
  int? prefixSize,
}) {
  final state = FileState(
    id: 1,
    size: diskAfter,
    expectedSize: 1 << 30,
    downloadedSize: limit,
    isCompleted: false,
    path: '/pool/1.mp4',
    canBeDownloaded: true,
    // Defaults model the schema's documented anchoring: a bounded range at
    // `offset` leaves `download_offset == offset` and a prefix that reaches the
    // end of that same range.
    downloadOffset: downloadOffset ?? offset,
    downloadedPrefixSize: prefixSize ?? limit,
    isDownloadingActive: false,
  );
  final snapshot = FileSnapshot(tMs: 0, state: state, diskSize: diskAfter);
  return ChunkRow(
    range: ChunkRange(index: index, offset: offset, limit: limit),
    ackMs: 12,
    ackError: ackError,
    settle: SettleOutcome(
      satisfied: satisfied,
      gate: gate,
      ms: 300,
    ),
    before: snapshot,
    after: snapshot,
    signals: ChunkSignals(
      events: 4,
      activeRuns: activeRuns,
      endedInactive: true,
      offsetDrift: offsetDrift,
      maxGapMs: maxGapMs,
      firstEventMs: 40,
    ),
    prefixFromOffset: prefixFromOffset ?? limit,
    prefixFromZero: prefixFromZero ?? offset + limit,
    prefixFromOffsetError: null,
    prefixFromZeroError: null,
    posix: WindowRead(
      bytes: posixBytes,
      ms: 8,
      sha: posixSha,
      error: posixError,
    ),
    part: WindowRead(
      bytes: partBytes,
      ms: 30,
      sha: partSha,
      error: partError,
    ),
  );
}

void main() {
  group('chunk planning', () {
    test('five consecutive megabytes start at 0 and step by one chunk', () {
      final ranges = planChunks(
        fileSize: 23 * _mb,
        chunkBytes: _mb,
        maxChunks: 5,
      );

      expect(ranges.length, 5);
      expect(ranges.map((r) => r.offset).toList(),
          <int>[0, _mb, 2 * _mb, 3 * _mb, 4 * _mb]);
      expect(ranges.every((r) => r.limit == _mb), isTrue);
      expect(ranges.last.end, 5 * _mb);
    });

    test('the last chunk is clamped instead of asking past EOF', () {
      // TDLib answers a range beyond the file with an error; letting that
      // happen would look like a chunking failure.
      final ranges = planChunks(
        fileSize: 2 * _mb + 512 * 1024,
        chunkBytes: _mb,
        maxChunks: 5,
      );

      expect(ranges.length, 3);
      expect(ranges.last.offset, 2 * _mb);
      expect(ranges.last.limit, 512 * 1024);
      expect(ranges.last.end, 2 * _mb + 512 * 1024);
    });

    test('chunks stop at the file end rather than producing empty ranges', () {
      final ranges = planChunks(fileSize: 2 * _mb, chunkBytes: _mb, maxChunks: 8);
      expect(ranges.length, 2);
    });

    test('a zero chunk size is refused', () {
      expect(() => planChunks(fileSize: _mb, chunkBytes: 0), throwsArgumentError);
    });

    test('an unknown file size yields no plan at all', () {
      expect(planChunks(fileSize: 0, chunkBytes: _mb), isEmpty);
    });
  });

  group('signals read from the update stream', () {
    FileEvent event(
      int tMs, {
      bool active = false,
      int offset = 0,
      int prefix = 0,
    }) =>
        FileEvent(
          seq: tMs,
          tMs: tMs,
          state: FileState(
            id: 1,
            size: 0,
            expectedSize: _mb,
            downloadedSize: prefix,
            isCompleted: false,
            path: '/pool/1.mp4',
            canBeDownloaded: true,
            downloadOffset: offset,
            downloadedPrefixSize: prefix,
            isDownloadingActive: active,
          ),
          diskSize: prefix,
        );

    test('an empty window reports nothing rather than guessing', () {
      expect(ChunkSignals.of(const <FileEvent>[], requestedOffset: 0).events, 0);
      expect(ChunkSignals.of(const <FileEvent>[], requestedOffset: 0).firstEventMs,
          -1);
    });

    test('one false->true transition is one task build', () {
      final signals = ChunkSignals.of(
        <FileEvent>[
          event(10, active: false),
          event(20, active: true),
          event(30, active: true),
          event(40, active: false),
        ],
        requestedOffset: 0,
      );

      expect(signals.activeRuns, 1);
      expect(signals.endedInactive, isTrue);
      expect(signals.maxGapMs, 10);
      expect(signals.firstEventMs, 10);
    });

    test('a restart inside one chunk shows up as two builds', () {
      final signals = ChunkSignals.of(
        <FileEvent>[
          event(10, active: true),
          event(20, active: false),
          event(30, active: true),
        ],
        requestedOffset: 0,
      );

      expect(signals.activeRuns, 2);
      expect(signals.endedInactive, isFalse);
    });

    test('an offset other than the one requested is drift', () {
      final drifted = ChunkSignals.of(
        <FileEvent>[event(10, active: true, offset: 4 * _mb)],
        requestedOffset: _mb,
      );
      expect(drifted.offsetDrift, isTrue);

      final aligned = ChunkSignals.of(
        <FileEvent>[event(10, active: true, offset: _mb)],
        requestedOffset: _mb,
      );
      expect(aligned.offsetDrift, isFalse);
    });
  });

  group('E1 verdict', () {
    test('no chunks means NOT TESTED, never PASS', () {
      final verdict = evaluateE1(
        rows: const <ChunkRow>[],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );
      expect(verdict.status, 'NOT TESTED');
    });

    test('five clean chunks are a PASS', () {
      final rows = <ChunkRow>[
        for (var i = 0; i < 5; i++)
          _row(index: i, offset: i * _mb, downloadOffset: i * _mb),
      ];
      final verdict = evaluateE1(
        rows: rows,
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'PASS');
      expect(verdict.reasons.first, contains('5 个连续分块'));
    });

    test('a chunk that never filled its window is a FAIL', () {
      final rows = <ChunkRow>[
        _row(index: 0),
        _row(
          index: 1,
          offset: _mb,
          satisfied: false,
          gate: 'timeout',
          posixBytes: 0,
        ),
      ];
      final verdict = evaluateE1(
        rows: rows,
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'FAIL');
      expect(verdict.reasons.any((r) => r.contains('没有拿到完整窗口')), isTrue);
    });

    test('a downloadFile error is a FAIL and names the error', () {
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row(ackError: 'TDLib error 400: file reference')],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'FAIL');
      expect(verdict.reasons.first, contains('file reference'));
    });

    test('two readers disagreeing is a FAIL, not a warning', () {
      // If POSIX and readFilePart see different bytes, one of them is reading
      // the wrong window — a player built on either would ship corruption.
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row(posixSha: _shaB)],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'FAIL');
      expect(verdict.reasons.any((r) => r.contains('两个读取器内容不一致')), isTrue);
    });

    test('a short POSIX read is a FAIL even when TDLib reports success', () {
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row(posixBytes: _mb ~/ 2)],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'FAIL');
      expect(verdict.reasons.any((r) => r.contains('POSIX 只读到')), isTrue);
    });

    test('correct chunks that vanish later are CONDITIONAL', () {
      final lost = PersistenceCheck(
        targetIndex: 0,
        checkedAfterChunk: 2,
        offset: 0,
        limit: _mb,
        originalSha: _shaA,
        recheck: const WindowRead(bytes: _mb, ms: 5, sha: _shaC),
      );
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row(index: 0), _row(index: 1, offset: _mb)],
        persistence: <PersistenceCheck>[lost],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'CONDITIONAL');
      expect(verdict.reasons.any((r) => r.contains('旧分块在后续 offset 切换后不可读')),
          isTrue);
      expect(verdict.notes.any((n) => n.contains('1/1 次复查')), isTrue);
    });

    test('a run on an already-complete file cannot be a PASS', () {
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row()],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: true,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'CONDITIONAL');
      expect(verdict.reasons.any((r) => r.contains('文件在实验前已完整')), isTrue);
    });

    test('a prefix anchored to download_offset is called out', () {
      // This is the Q2 answer the player depends on. The schema says the prefix
      // is counted from `download_offset`; if the run agrees, a chunk store may
      // never read the field as an absolute watermark.
      final verdict = evaluateE1(
        rows: <ChunkRow>[
          _row(index: 0, prefixFromZero: _mb),
          _row(index: 1, offset: _mb, prefixFromZero: _mb, prefixSize: _mb),
        ],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'PASS');
      expect(
        verdict.notes.any((n) => n.contains('相对 download_offset 计')),
        isTrue,
      );
    });

    test('a prefix that reaches nothing is downgraded to a progress value', () {
      final verdict = evaluateE1(
        rows: <ChunkRow>[
          _row(index: 0, prefixSize: 0),
          _row(index: 1, offset: _mb, prefixSize: 0),
        ],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'PASS');
      expect(
        verdict.notes.any((n) => n.contains('只能当进度值')),
        isTrue,
      );
    });

    test('a rebuilt task is reported without failing the run', () {
      final verdict = evaluateE1(
        rows: <ChunkRow>[_row(activeRuns: 3)],
        persistence: const <PersistenceCheck>[],
        fileWasCompleteBeforeRun: false,
        chunkBytes: _mb,
      );

      expect(verdict.status, 'PASS');
      expect(verdict.notes.any((n) => n.contains('download task 重建')), isTrue);
    });
  });

  group('persistence check', () {
    PersistenceCheck check(String recheckSha, {int bytes = _mb}) =>
        PersistenceCheck(
          targetIndex: 0,
          checkedAfterChunk: 1,
          offset: 0,
          limit: _mb,
          originalSha: _shaA,
          recheck: WindowRead(bytes: bytes, ms: 4, sha: recheckSha),
        );

    test('identical bytes count as survived', () {
      expect(check(_shaA).survived, isTrue);
    });

    test('different bytes do not', () {
      expect(check(_shaD).survived, isFalse);
    });

    test('a short re-read does not count as survived', () {
      expect(check(_shaA, bytes: 0).survived, isFalse);
    });
  });

  group('localFile parsing', () {
    test('prefix size and active flag are read from local', () {
      final state = FileState.fromJson(<String, Object?>{
        'id': 5626,
        'size': 100,
        'expected_size': 200,
        'local': <String, Object?>{
          'path': '/pool/5626.mp4',
          'is_downloading_completed': false,
          'is_downloading_active': true,
          'can_be_downloaded': true,
          'download_offset': 1024,
          'downloaded_prefix_size': 2048,
          'downloaded_size': 1024,
        },
      });

      expect(state.downloadedPrefixSize, 2048);
      expect(state.isDownloadingActive, isTrue);
      expect(state.downloadOffset, 1024);
      expect(state.transferLine, contains('prefix=2048'));
      expect(state.transferLine, contains('active=1'));
    });

    test('a missing field degrades to zero instead of throwing', () {
      final state = FileState.fromJson(<String, Object?>{'id': 1});
      expect(state.downloadedPrefixSize, 0);
      expect(state.isDownloadingActive, isFalse);
    });
  });

  group('sample selection', () {
    ProbeVideo video(int size, {int fileId = 1}) => ProbeVideo(
          chatId: -100,
          chatTitle: 'channel',
          messageId: 1,
          fileId: fileId,
          size: size,
        );

    test('the closest size wins, not the first one over the target', () {
      final videos = <ProbeVideo>[
        video(8 * _mb, fileId: 1),
        video(24 * _mb, fileId: 2),
        video(31 * _mb, fileId: 3),
      ];

      expect(pickClosest(videos, 23 * _mb)!.fileId, 2);
    });

    test('an exact match beats a near one regardless of order', () {
      final videos = <ProbeVideo>[
        video(593 * _mb, fileId: 7),
        video(10 * _mb, fileId: 8),
      ];
      expect(pickClosest(videos, 10 * _mb)!.fileId, 8);
    });

    test('an empty pool has no closest', () {
      expect(pickClosest(const <ProbeVideo>[], 23 * _mb), isNull);
    });

    test('the three targets are the ones the protocol asks for', () {
      expect(kSampleTargets, <int>[23 * _mb, 152 * _mb, 593 * _mb]);
    });
  });
}
