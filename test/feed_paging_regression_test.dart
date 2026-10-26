/// Regression suite for the on-device report "视频页固定 38 条，触底不加载".
///
/// The failure had one root cause and two symptoms: the sync cursor was taken
/// from the filtered *video* list, so a batch whose newest entry was the only
/// video produced a cursor that pointed back into the same batch. Every cycle
/// re-requested it, inserted nothing new, and the list stayed at whatever count
/// the first sync had produced. These tests pin the raw-message cursor, the
/// four end states (end of history / no video in batch / failure / still
/// running) and the retry path.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/channel_sync.dart';
import 'package:tg_media_probe/data/history_source.dart';
import 'package:tg_media_probe/data/index_store.dart';

import 'support/sandbox.dart';


Map<String, Object?> _message(int id, {required bool video}) {
  if (!video) {
    return <String, Object?>{
      '@type': 'message',
      'id': id,
      'date': 1700000000 + id,
      'has_protected_content': false,
      'content': <String, Object?>{
        '@type': 'messageText',
        'text': <String, Object?>{'text': 'hello $id'},
      },
    };
  }
  return <String, Object?>{
    '@type': 'message',
    'id': id,
    'date': 1700000000 + id,
    'has_protected_content': false,
    'content': <String, Object?>{
      '@type': 'messageVideo',
      'video': <String, Object?>{
        'duration': 30,
        'width': 1920,
        'height': 1080,
        'file_name': 'v$id.mp4',
        'mime_type': 'video/mp4',
        'supports_streaming': true,
        'video': <String, Object?>{
          'id': 900000 + id,
          'expected_size': 1048576,
          'local': <String, Object?>{'downloaded_size': 0},
        },
      },
    },
  };
}

/// A channel whose message ids are 1..[newest], with an explicit set of ids that
/// carry a video. Everything else is plain text, which is the case that used to
/// stall the walk.
class ScriptedChannel implements HistorySource {
  ScriptedChannel({required this.newest, required this.videoIds});

  final int newest;
  final Set<int> videoIds;

  final List<int> fromIds = <int>[];
  final List<int> limits = <int>[];
  String? failNext;

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    fromIds.add(fromMessageId);
    limits.add(limit);
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      return HistoryPage.failure(failure);
    }

    final start = fromMessageId == 0 ? newest : fromMessageId - 1;
    final messages = <Map<String, Object?>>[];
    for (var id = start; id > 0 && messages.length < limit; id--) {
      messages.add(_message(id, video: videoIds.contains(id)));
    }
    return HistoryPage(messages: messages);
  }
}

void main() {
  late TestSandbox sandbox;
  late IndexStore store;

  setUp(() async {
    sandbox = await TestSandbox.create();
    store = IndexStore(directory: sandbox.layout.indexDir, ops: sandbox.ops);
    await store.open();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  ChannelSyncEngine engine(HistorySource source, {int pageSize = 10}) =>
      ChannelSyncEngine(source: source, store: store, pageSize: pageSize);

  group('cursor advances on raw messages', () {
    test('a batch whose only video is its newest message still advances',
        () async {
      // The reported bug in its purest form: page 1 is 10 messages, only the
      // newest is a video. The old cursor became that video's id (100), so the
      // next request asked for messages older than 100 and got the same batch.
      final source = ScriptedChannel(newest: 100, videoIds: <int>{100});
      final first = await engine(source).loadPage(chatId: 1);

      expect(first.records, hasLength(1));
      expect(first.nextCursor, 91,
          reason: 'cursor must be the oldest raw message, not the video');
      expect(first.hasMore, isTrue);

      final second =
          await engine(source).loadPage(chatId: 1, cursor: first.nextCursor);
      expect(second.records, isEmpty);
      expect(second.nextCursor, 81);
      expect(second.hasMore, isTrue,
          reason: 'a page with no video is not the end of the channel');
      expect(second.reachedEnd, isFalse);
    });

    test('38 indexed items grow after the next sync cycle', () async {
      // 38 videos already in the index, then a channel with more history.
      final seeded = ScriptedChannel(
        newest: 138,
        videoIds: <int>{for (var id = 101; id <= 138; id++) id},
      );
      await ChannelSyncEngine(source: seeded, store: store, pageSize: 50)
          .syncCycle(chatIds: <int>[1], pagesPerChannel: 1);
      expect(store.countByChat()[1], 38);

      final older = ScriptedChannel(
        newest: 138,
        videoIds: <int>{for (var id = 1; id <= 138; id++) id},
      );
      final more = ChannelSyncEngine(source: older, store: store, pageSize: 50);
      // Walk two pages starting from the newest; the second page must add the
      // older videos instead of re-reading the first batch.
      var cursor = (await more.loadPage(chatId: 1)).nextCursor;
      cursor = (await more.loadPage(chatId: 1, cursor: cursor)).nextCursor;

      final count = store.countByChat()[1];
      expect(count, greaterThan(38), reason: '触底后必须真的变多');
      expect(older.fromIds, <int>[0, 89]);
      expect(cursor, 39);
    });

    test('a duplicate-only batch still moves the cursor forward', () async {
      final source = ScriptedChannel(
        newest: 30,
        videoIds: <int>{for (var id = 21; id <= 30; id++) id},
      );
      final first = await engine(source).loadPage(chatId: 1);
      expect(first.inserted, 10);

      // Same ten videos again would be impossible with a working cursor; force
      // it by asking from the same place the first page started.
      final repeat = await engine(source).loadPage(chatId: 1, cursor: 31);
      expect(repeat.inserted, 0, reason: 'nothing new to insert');
      expect(repeat.nextCursor, lessThan(31));
    });
  });

  group('the four end states are distinguishable', () {
    test('end of history is reported as reachedEnd', () async {
      final source = ScriptedChannel(newest: 5, videoIds: <int>{1, 3, 5});
      final result = await engine(source).loadPage(chatId: 1);

      expect(result.rawMessageCount, 5, reason: 'short page',);
      expect(result.hasMore, isFalse);
      expect(result.reachedEnd, isTrue);
    });

    test('no video in a full batch is not the end', () async {
      final source = ScriptedChannel(newest: 20, videoIds: <int>{});
      final result = await engine(source).loadPage(chatId: 1);

      expect(result.records, isEmpty);
      expect(result.rawMessageCount, 10);
      expect(result.hasMore, isTrue);
      expect(result.reachedEnd, isFalse);
    });

    test('a failure is an error, not an empty success', () async {
      final source = ScriptedChannel(newest: 20, videoIds: <int>{20})
        ..failNext = 'TDLib error 400: CHANNEL_PRIVATE';
      final result = await engine(source).loadPage(chatId: 1);

      expect(result.isError, isTrue);
      expect(result.hasMore, isFalse);
      expect(result.reachedEnd, isFalse);
      expect(result.error, contains('CHANNEL_PRIVATE'));
    });

    test('a failure can be retried on the next call', () async {
      final source = ScriptedChannel(newest: 20, videoIds: <int>{20})
        ..failNext = 'TDLib error 420: FLOOD_WAIT_3';

      final failed = await engine(source).loadPage(chatId: 1);
      expect(failed.isError, isTrue);

      final retried = await engine(source).loadPage(chatId: 1);
      expect(retried.isError, isFalse);
      expect(retried.records, hasLength(1));
      expect(retried.nextCursor, 11);
    });
  });

  group('a stuck cursor stops instead of looping', () {
    test('a source that ignores the cursor is cut off after one repeat',
        () async {
      // Worst case: TDLib answers with the same ids whatever cursor we send.
      final source = _StuckHistorySource();
      final result = await engine(source).loadPage(chatId: 1);

      expect(result.hasMore, isTrue, reason: 'first page is a full page');

      final again =
          await engine(source).loadPage(chatId: 1, cursor: result.nextCursor);
      expect(again.hasMore, isFalse,
          reason: 'a cursor that did not move must end the walk, not loop');
      expect(again.reachedEnd, isFalse);
    });
  });

  group('two channels do not overwrite each other', () {
    test('syncing chat 2 leaves chat 1 watermark and rows alone', () async {
      final sourceA = ScriptedChannel(newest: 20, videoIds: <int>{20, 19, 18});
      await engine(sourceA).syncCycle(chatIds: <int>[1], pagesPerChannel: 1);
      final watermarkA = store.watermark(1);
      final countA = store.countByChat()[1];

      // pageSize is 10, so 50..41 is one page: both videos are on it.
      final sourceB = ScriptedChannel(newest: 50, videoIds: <int>{50, 45});
      await engine(sourceB).syncCycle(chatIds: <int>[2], pagesPerChannel: 1);

      expect(store.watermark(1)?.oldestMessageId, watermarkA?.oldestMessageId);
      expect(store.countByChat()[1], countA);
      expect(store.countByChat()[2], 2);
    });

    test('a late page for an old chat cannot be written into the new one',
        () async {
      final source = ScriptedChannel(newest: 30, videoIds: <int>{30, 20, 10});
      final result = await engine(source).loadPage(chatId: 7);

      // The result carries the chat it belongs to; the store keys rows by
      // (chatId, messageId), so replaying it under another chat is impossible
      // without changing that field.
      expect(result.chatId, 7);
      expect(store.contains(7, 30), isTrue);
      expect(store.contains(8, 30), isFalse);
    });
  });
}

/// Returns the same ids for every cursor — the pathological case.
class _StuckHistorySource implements HistorySource {
  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    return HistoryPage(messages: <Map<String, Object?>>[
      for (var id = 100; id > 100 - limit; id--)
        _message(id, video: id == 100),
    ]);
  }
}
