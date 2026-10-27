/// Photo exclusion: TG Media is a video library, so a Telegram photo takes
/// no row, no number, no count, no download and no feed slot — and a photo-
/// heavy channel must page through exactly as smoothly as a video-only one.
///
/// The choke point is [MediaRecord.fromMessage]: a photo message builds no
/// record at all, while the sync cursor keeps walking raw message ids, so
/// pagination never mistakes a photo run for the end of history.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/channel_sync.dart';
import 'package:tg_media_probe/data/history_source.dart';
import 'package:tg_media_probe/data/index_store.dart';
import 'package:tg_media_probe/data/media_record.dart';

import 'support/sandbox.dart';

Map<String, Object?> videoMessage(int id) => <String, Object?>{
      '@type': 'message',
      'id': id,
      'date': 1700000000 + id,
      'has_protected_content': false,
      'content': <String, Object?>{
        '@type': 'messageVideo',
        'video': <String, Object?>{
          'duration': 10,
          'width': 720,
          'height': 1280,
          'file_name': 'v$id.mp4',
          'mime_type': 'video/mp4',
          'video': <String, Object?>{
            'id': 700000 + id,
            'expected_size': 4096,
            'local': <String, Object?>{'downloaded_size': 0},
          },
        },
      },
    };

Map<String, Object?> photoMessage(int id) => <String, Object?>{
      '@type': 'message',
      'id': id,
      'date': 1700000000 + id,
      'has_protected_content': false,
      'content': <String, Object?>{
        '@type': 'messagePhoto',
        'photo': <String, Object?>{
          'sizes': <Object?>[
            <String, Object?>{
              '@type': 'photoSize',
              'width': 1280,
              'height': 960,
              'photo': <String, Object?>{
                'id': 800000 + id,
                'expected_size': 250000,
              },
            },
          ],
        },
      },
    };

/// Newest-first history of [total] messages: photos and videos interleaved,
/// [photoRatio] of them photos — the shape of the reported channel.
class MixedChannel implements HistorySource {
  MixedChannel({this.total = 300, this.photoRatio = 3});

  final int total;

  /// Every Nth message (newest first) is a photo.
  final int photoRatio;

  final List<int> requestedFrom = <int>[];

  @override
  Future<HistoryPage> history({
    required int chatId,
    required int fromMessageId,
    required int offset,
    required int limit,
  }) async {
    requestedFrom.add(fromMessageId);
    final start = fromMessageId == 0 ? total : fromMessageId - 1;
    final messages = <Map<String, Object?>>[];
    for (var id = start; id > start - limit && id >= 1; id--) {
      messages.add(id % photoRatio == 0 ? photoMessage(id) : videoMessage(id));
    }
    return HistoryPage(messages: messages);
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

  Future<IndexStore> openStore() async {
    final store = IndexStore(
      directory: sandbox.layout.indexDir,
      ops: sandbox.ops,
    );
    await store.open();
    return store;
  }

  group('MediaRecord.fromMessage', () {
    test('a photo builds no record at all', () {
      final record = MediaRecord.fromMessage(
        chatId: 1,
        message: photoMessage(101),
      );
      expect(record, isNull, reason: '图片不进入视频媒体库');
    });

    test('a video still builds a full record', () {
      final record = MediaRecord.fromMessage(
        chatId: 1,
        message: videoMessage(102),
      );
      expect(record, isNotNull);
      expect(record!.kind, MediaKind.video);
      expect(record.fileId, 700000 + 102);
      expect(record.sizeBytes, 4096);
      expect(record.fileName, 'v102.mp4');
    });
  });

  group('a photo-heavy channel', () {
    test('indexes only videos and counts only videos', () async {
      final store = await openStore();
      final engine = ChannelSyncEngine(
        source: MixedChannel(photoRatio: 2),
        store: store,
      );

      final report = await engine.syncCycle(
        chatIds: const <int>[1],
        pagesPerChannel: 5,
      );

      expect(report.isError, isFalse, reason: report.lastError);
      expect(report.insertedRecords, greaterThan(0));
      // Nothing that is not a video ever reached the mirror.
      final counts = store.countByChat(videosOnly: false);
      final all = counts[1] ?? 0;
      final videos = store.countByChat()[1] ?? 0;
      expect(all, videos, reason: '镜像里只允许有视频行');
      expect(videos, greaterThan(0));
    });

    test('photos never stall the pagination cursor', () async {
      final store = await openStore();
      final source = MixedChannel(total: 300, photoRatio: 2);
      final engine = ChannelSyncEngine(source: source, store: store);

      // Many rounds: every round must move the cursor to strictly older
      // messages, photo runs included, until history really ends.
      for (var round = 0; round < 6; round++) {
        final report = await engine.syncCycle(
          chatIds: const <int>[1],
          pagesPerChannel: 5,
          resume: true,
        );
        if (report.reachedEnd) break;
      }
      final videos = store.countByChat()[1] ?? 0;
      // 300 messages, every 2nd is a video → 150 videos, interleaved.
      expect(videos, 150,
          reason: '图片不得影响视频总数（视频编号 1..150，不跳号）');
    });

    test('the video-only pager skips photo rows without losing videos',
        () async {
      final store = await openStore();
      // Seed the mirror the old way: photos and videos side by side, the
      // shape an upgraded install still carries.
      final records = <MediaRecord>[
        for (var id = 10; id >= 1; id--)
          MediaRecord(
            chatId: 1,
            messageId: id,
            fileId: 700000 + id,
            kind: id.isEven ? MediaKind.video : MediaKind.photo,
            sizeBytes: 4096,
            fileName: 'm$id',
            messageDateUnix: 1700000000 + id,
          ),
      ];
      await store.upsertAll(records);

      final pager = MediaPager(
        store: store,
        chatId: 1,
        pageSize: 3,
        videosOnly: true,
      );
      final seen = <int>[];
      while (pager.hasMore) {
        final page = await pager.next();
        seen.addAll(page.items.map((r) => r.messageId));
        if (page.items.isEmpty) break;
      }
      expect(seen, hasLength(5), reason: '只应有 5 条视频（偶数 id）');
      expect(seen.every((id) => id.isEven), isTrue, reason: '奇数 id 是图片，不得出现');
    });
  });
}
