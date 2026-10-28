/// Device-failure regressions: a large video that is still downloading, a file
/// id TDLib rejects, a play failure that must not reset the list, and a missing
/// file name that has to come from the message.
///
/// Every case here was reported from the phone, and every assertion names the
/// behaviour that was wrong — not the implementation that fixed it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/media_metadata.dart';
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

import 'support/sandbox.dart';

// ------------------------------------------------------------------ fixtures

MediaRecord video(
  int messageId, {
  int chatId = 1,
  int fileId = 0,
  String? name,
  int date = 1700000000,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: fileId == 0 ? 1000 + messageId : fileId,
      kind: MediaKind.video,
      width: 1080,
      height: 1920,
      durationSeconds: 30,
      sizeBytes: 4096,
      fileName: name,
      messageDateUnix: date + messageId,
    );

/// A transfer that emits exactly the updates it is told to, with real delays.
class ScriptedTransfer implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  ScriptedTransfer({
    this.expectedSize = 4096,
    this.chunkBytes = 0,
    this.chunkCount = 0,
    this.chunkDelay = Duration.zero,
    this.completeAtEnd = true,
    this.failIds = const <int, String>{},
  });

  final int expectedSize;
  final int chunkBytes;
  final int chunkCount;
  final Duration chunkDelay;
  final bool completeAtEnd;

  /// `fileId -> TDLib error text` for ids that must be refused.
  final Map<int, String> failIds;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();

  /// Files the script finished; `stat` reports them as complete on disk.
  final Set<int> _done = <int>{};
  final List<int> started = <int>[];
  final List<int> cancelled = <int>[];
  int statCalls = 0;

  @override
  Future<FileState?> stat(int fileId) async {
    statCalls++;
    // A finished scripted transfer becomes a real, measured local file —
    // TDLib's `stat` is what the B+ chain reads its watermark from, and a fake
    // that never completes would hold every play in its wait loop.
    final done = _done.contains(fileId);
    return FileState(
      id: fileId,
      size: done ? expectedSize : 0,
      expectedSize: expectedSize,
      downloadedSize: done ? expectedSize : 0,
      isCompleted: done,
      path: done ? '/pool/$fileId' : '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    started.add(fileId);
    final error = failIds[fileId];
    if (error != null) throw VideoSourceException(error);
    if (chunkCount > 0 && chunkBytes > 0) {
      // Bytes first, completion last: the watchdog has to see growth.
      unawaited(_emitChunks(fileId));
      return;
    }
    if (completeAtEnd) _complete(fileId);
  }

  Future<void> _emitChunks(int fileId) async {
    for (var i = 1; i <= chunkCount; i++) {
      await Future<void>.delayed(chunkDelay);
      if (_updates.isClosed) return;
      _updates.add(FileState(
        id: fileId,
        size: 0,
        expectedSize: expectedSize,
        downloadedSize: (chunkBytes * i).clamp(0, expectedSize),
        isCompleted: false,
        path: '',
        canBeDownloaded: true,
      ));
    }
    if (!completeAtEnd) return;
    await Future<void>.delayed(chunkDelay);
    _complete(fileId);
  }

  void _complete(int fileId) {
    if (_updates.isClosed) return;
    _done.add(fileId);
    _updates.add(FileState(
      id: fileId,
      size: expectedSize,
      expectedSize: expectedSize,
      downloadedSize: expectedSize,
      isCompleted: true,
      path: '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    if (caller == DownloadCaller.preload) {
      started.add(fileId);
      return;
    }
    await start(fileId, caller: caller, cause: cause);
  }
  @override
  Future<void> cancel(int fileId) async => cancelled.add(fileId);

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

class FakeMetadata implements MediaMetadataLookup {
  FakeMetadata({this.records = const <String, MediaRecord>{}});

  /// `chatId:messageId -> record`.
  final Map<String, MediaRecord> records;
  final List<String> requests = <String>[];

  @override
  Future<MediaRecord?> fetch(int chatId, int messageId) async {
    requests.add('$chatId:$messageId');
    return records['$chatId:$messageId'];
  }
}

class _Player implements PlayerHandle, PlayerProgress {
  _Player(this.path);

  @override
  final String path;
  bool _playing = false;
  bool _disposed = false;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 30);

  @override
  bool get isPlaying => _playing;
  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {}
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> disposePlayer() async => _disposed = true;
}

class _Factory implements PlayerFactory {
  final List<_Player> created = <_Player>[];

  @override
  PlayerHandle create(String path) {
    final player = _Player(path);
    created.add(player);
    return player;
  }
}

// --------------------------------------------------------------------- tests

void main() {
  group('a large video that is still arriving', () {
    test('is not failed just because it takes longer than the quiet window',
        () async {
      final api = ScriptedTransfer(
        expectedSize: 20 * 1024 * 1024,
        chunkBytes: 2 * 1024 * 1024,
        chunkCount: 15,
        chunkDelay: const Duration(milliseconds: 30),
      );
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        // The window is 13x the chunk gap: under a full-suite load a timer can
        // jitter badly, and the test must measure "steady growth is never a
        // stall", not "the runner was fast today". 450 ms of transfer crosses
        // the 400 ms window several times.
        stallTimeout: const Duration(milliseconds: 400),
        taskTimeout: const Duration(seconds: 30),
      );

      final stopwatch = Stopwatch()..start();
      final path = await resolver.resolve(7);
      stopwatch.stop();

      expect(path, '/pool/7');
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 200)),
          reason: 'the test must outlast the quiet window to prove anything');
      await api.close();
    });

    test('a transfer that trickles past the task ceiling ends with 超时, not '
        '网络不可用', () async {
      final api = ScriptedTransfer(
        expectedSize: 80 * 1024 * 1024,
        chunkBytes: 1024,
        chunkCount: 40,
        chunkDelay: const Duration(milliseconds: 20),
        completeAtEnd: false,
      );
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        stallTimeout: const Duration(milliseconds: 200),
        taskTimeout: const Duration(milliseconds: 120),
      );

      await expectLater(
        resolver.resolve(8),
        throwsA(isA<VideoSourceTimeout>()
            .having((e) => e.isStall, 'isStall', isFalse)
            .having((e) => e.message, 'message', contains('超时'))),
      );
      await api.close();
    });
  });

  group('a file id TDLib rejects', () {
    test('is re-read from the message and played with the fresh id', () async {
      final api = ScriptedTransfer(
        failIds: const <int, String>{111: 'TDLib error 400: File not found'},
      );
      final metadata = FakeMetadata(records: <String, MediaRecord>{
        '1:42': video(42, fileId: 222, name: '45641345461.MP4'),
      });
      final resolver = VideoSourceResolver(
        api: api,
        metadata: metadata,
        fileExists: (_) async => true,
      );

      MediaRecord? repaired;
      final path = await resolver.resolve(
        111,
        chatId: 1,
        messageId: 42,
        onRecordRefreshed: (fresh) => repaired = fresh,
      );

      expect(api.started, <int>[111, 222]);
      expect(path, '/pool/222');
      expect(metadata.requests, <String>['1:42']);
      // The repair is also the moment the name becomes known; the controller
      // persists it so the label does not fall back to the channel title again.
      expect(repaired?.fileId, 222);
      expect(repaired?.fileName, '45641345461.MP4');
      await api.close();
    });

    test('fails with a real message when the message no longer exists',
        () async {
      final api = ScriptedTransfer(
        failIds: const <int, String>{111: 'TDLib error 400: File not found'},
      );
      final resolver = VideoSourceResolver(
        api: api,
        metadata: FakeMetadata(),
        fileExists: (_) async => true,
      );

      await expectLater(
        resolver.resolve(111, chatId: 1, messageId: 42),
        throwsA(isA<VideoSourceException>()
            .having((e) => e.message, 'message', contains('文件已失效'))),
      );
      // One attempt on the stale id, one message read, no retry storm.
      expect(api.started, <int>[111]);
      await api.close();
    });

    test('the failure is not cached: a second resolve tries again', () async {
      final api = ScriptedTransfer(
        failIds: const <int, String>{111: 'TDLib error 400: File not found'},
      );
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
      );

      await expectLater(
        resolver.resolve(111),
        throwsA(isA<VideoSourceException>()),
      );
      expect(resolver.inflightCount, 0, reason: '失败不得留在在飞表里');

      await expectLater(
        resolver.resolve(111),
        throwsA(isA<VideoSourceException>()),
      );
      expect(api.started.length, 2, reason: '第二次必须真的重试');
      await api.close();
    });
  });

  group('a failed play', () {
    late TestSandbox sandbox;

    setUp(() async {
      sandbox = await TestSandbox.create();
    });

    tearDown(() async {
      await sandbox.dispose();
    });

    Future<IndexStore> storeWith(List<MediaRecord> records) async {
      final store = IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
      await store.open();
      await store.upsertAll(records);
      return store;
    }

    test('retry keeps the loaded list and the position', () async {
      final records = <MediaRecord>[video(1), video(2), video(3), video(4)];
      final store = await storeWith(records);
      // Newest first, so index 1 is message 3. Prefetch is off: the point of
      // this test is the failure path, not the prefetch that would hide it.
      final api = ScriptedTransfer(
        failIds: <int, String>{1003: 'TDLib error 400: File not found'},
      );
      final factory = _Factory();
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: factory),
        sources: VideoSourceResolver(
          api: api,
          fileExists: (_) async => true,
          // Pool paths are fake: the volume answers for them, and the short
          // stall window keeps a genuinely refused id from sitting out the
          // 15 s production timeout twice inside one test.
          diskSizeOf: (_) async => 4096,
          stallTimeout: const Duration(milliseconds: 200),
        ),
        chatTitles: const <int, String>{1: '测试频道'},
        preloadCount: 0,
        pollInterval: null,
      );

      await controller.load();
      expect(controller.phase, FeedPhase.ready);

      await controller.goNext();
      expect(controller.index, 1);
      expect(controller.phase, FeedPhase.error);

      // The list must not be rebuilt by a retry: that is the "回到 1/38" bug.
      await controller.retry();
      expect(controller.index, 1, reason: '重试必须停在同一条');
      expect(controller.length, 4, reason: '重试不得清空已加载列表');
      expect(controller.positionLabel, startsWith('2 / 4'));

      // Once TDLib stops refusing the id, the same retry succeeds.
      api.failIds.clear();
      await controller.retry();
      expect(controller.phase, FeedPhase.ready);
      expect(controller.index, 1);
      controller.dispose();
    });

    test('a missing file name is filled from the message and persisted',
        () async {
      final bare = video(42, name: null);
      final store = await storeWith(<MediaRecord>[bare]);
      final api = ScriptedTransfer();
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: api,
          fileExists: (_) async => true,
          diskSizeOf: (_) async => 4096,
          stallTimeout: const Duration(milliseconds: 200),
        ),
        metadata: FakeMetadata(records: <String, MediaRecord>{
          '1:42': video(42, name: '45641345461.MP4'),
        }),
        chatTitles: const <int, String>{1: '测试频道'},
        pollInterval: null,
      );

      await controller.load();
      expect(controller.phase, FeedPhase.ready);

      // The lookup is fire-and-forget so it never delays the play; give it the
      // microtask it needs.
      await Future<void>.delayed(Duration.zero);

      expect(controller.current?.fileName, '45641345461.MP4');
      expect(controller.titleOf(controller.current!), '45641345461.MP4');

      final page = await store.page(limit: 10, chatId: 1);
      expect(page.items.single.fileName, '45641345461.MP4',
          reason: '修好的名字要写回索引，否则下次启动又丢');
      controller.dispose();
      await api.close();
    });

    test('a nameless video still has a label the user can match', () async {
      final store = await storeWith(<MediaRecord>[video(42, name: null)]);
      final controller = FeedController(
        source: IndexFeedSource(store: store, chatId: 1),
        player: SinglePlayerController(factory: _Factory()),
        sources: VideoSourceResolver(
          api: ScriptedTransfer(),
          fileExists: (_) async => true,
          diskSizeOf: (_) async => 4096,
          stallTimeout: const Duration(milliseconds: 200),
        ),
        chatTitles: const <int, String>{1: '测试频道'},
        pollInterval: null,
      );

      await controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(controller.titleOf(controller.current!), '测试频道 · #42');
      controller.dispose();
    });
  });
}
