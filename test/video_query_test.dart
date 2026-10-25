import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_settings.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/data/video_query.dart';

MediaRecord video({
  int chatId = 1,
  int messageId = 1,
  int? duration = 30,
  String? caption,
  String? fileName,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: messageId * 10,
      kind: MediaKind.video,
      durationSeconds: duration,
      caption: caption,
      fileName: fileName,
      messageDateUnix: 1700000000 - messageId,
    );

String titleOf(int chatId) => switch (chatId) {
      1 => '18号仓储',
      2 => '摄影素材库',
      _ => '频道 $chatId',
    };

void main() {
  final records = <MediaRecord>[
    video(chatId: 1, messageId: 1, duration: 30, caption: '仓库 全景 巡检'),
    video(chatId: 1, messageId: 2, duration: 120, caption: '货架 细节'),
    video(chatId: 2, messageId: 3, duration: 400, caption: '夜景 延时'),
    video(chatId: 2, messageId: 4, duration: null, caption: '未知时长片段'),
    video(chatId: 1, messageId: 5, duration: 59, caption: null, fileName: 'clip_alpha.mp4'),
  ];

  group('VideoQuery', () {
    test('empty query is inactive and passes everything', () {
      const query = VideoQuery.none;
      expect(query.isActive, isFalse);
      expect(query.hasText, isFalse);
      expect(
        VideoQueryEngine.apply(records, query, titleOf: titleOf).length,
        records.length,
      );
    });

    test('whitespace-only text is treated as no search', () {
      const query = VideoQuery(text: '   ');
      expect(query.hasText, isFalse);
      expect(query.isActive, isFalse);
    });

    test('copyWith can clear the category with an explicit null', () {
      const query = VideoQuery(categoryChatId: 7);
      expect(query.copyWith().categoryChatId, 7);
      expect(query.copyWith(categoryChatId: null).categoryChatId, isNull);
    });

    test('equality is by value so the feed can skip rebuilds', () {
      expect(
        const VideoQuery(text: 'a', categoryChatId: 1),
        const VideoQuery(text: 'a', categoryChatId: 1),
      );
      expect(
        const VideoQuery(text: 'a').hashCode,
        const VideoQuery(text: 'a').hashCode,
      );
      expect(
        const VideoQuery(text: 'a'),
        isNot(const VideoQuery(text: 'b')),
      );
    });
  });

  group('duration buckets', () {
    test('boundaries are inclusive at the bottom, exclusive at the top', () {
      const under = DurationFilter.underMinute;
      expect(under.accepts(0), isTrue);
      expect(under.accepts(59), isTrue);
      expect(under.accepts(60), isFalse);

      const mid = DurationFilter.oneToFiveMinutes;
      expect(mid.accepts(59), isFalse);
      expect(mid.accepts(60), isTrue);
      expect(mid.accepts(299), isTrue);
      expect(mid.accepts(300), isFalse);

      const over = DurationFilter.overFiveMinutes;
      expect(over.accepts(299), isFalse);
      expect(over.accepts(300), isTrue);
      expect(over.accepts(9999), isTrue);
    });

    test('an unknown duration only passes the "all" bucket', () {
      expect(DurationFilter.all.accepts(null), isTrue);
      expect(DurationFilter.underMinute.accepts(null), isFalse);
      expect(DurationFilter.oneToFiveMinutes.accepts(null), isFalse);
      expect(DurationFilter.overFiveMinutes.accepts(null), isFalse);
    });

    test('every record lands in exactly one bucket', () {
      for (final record in records) {
        if (record.durationSeconds == null) continue;
        final hits = DurationFilter.values
            .where((f) => f != DurationFilter.all)
            .where((f) => f.accepts(record.durationSeconds))
            .toList();
        expect(hits.length, 1, reason: '${record.messageId}');
      }
    });

    test('wire codes round-trip', () {
      for (final filter in DurationFilter.values) {
        expect(DurationFilterRule.fromWire(filter.wire), filter);
      }
      expect(DurationFilterRule.fromWire('nonsense'), DurationFilter.all);
      expect(DurationFilterRule.fromWire(null), DurationFilter.all);
    });
  });

  group('search', () {
    test('matches message captions case-insensitively', () {
      const query = VideoQuery(text: '巡检');
      final hits = VideoQueryEngine.apply(records, query, titleOf: titleOf);
      expect(hits.map((r) => r.messageId), <int>[1]);
    });

    test('matches channel titles', () {
      const query = VideoQuery(text: '摄影');
      final hits = VideoQueryEngine.apply(records, query, titleOf: titleOf);
      expect(hits.map((r) => r.messageId), containsAll(<int>[3, 4]));
      expect(hits.length, 2);
    });

    test('matches file names', () {
      const query = VideoQuery(text: 'alpha');
      final hits = VideoQueryEngine.apply(records, query, titleOf: titleOf);
      expect(hits.map((r) => r.messageId), <int>[5]);
    });

    test('multiple terms are ANDed', () {
      expect(
        VideoQueryEngine.apply(
          records,
          const VideoQuery(text: '仓库 巡检'),
          titleOf: titleOf,
        ).length,
        1,
      );
      expect(
        VideoQueryEngine.apply(
          records,
          const VideoQuery(text: '仓库 夜景'),
          titleOf: titleOf,
        ),
        isEmpty,
      );
    });

    test('no match returns an empty list, not everything', () {
      final hits = VideoQueryEngine.apply(
        records,
        const VideoQuery(text: '不存在的关键词'),
        titleOf: titleOf,
      );
      expect(hits, isEmpty);
    });
  });

  group('category filter', () {
    test('keeps only the selected chat', () {
      final hits = VideoQueryEngine.apply(
        records,
        const VideoQuery(categoryChatId: 2),
        titleOf: titleOf,
      );
      expect(hits.every((r) => r.chatId == 2), isTrue);
      expect(hits.length, 2);
    });

    test('chatIdsOf lists each channel once, in first-seen order', () {
      expect(VideoQueryEngine.chatIdsOf(records), <int>[1, 2]);
    });
  });

  group('combined conditions', () {
    test('search + category + duration all apply together', () {
      final hits = VideoQueryEngine.apply(
        records,
        const VideoQuery(
          text: '18号',
          categoryChatId: 1,
          duration: DurationFilter.oneToFiveMinutes,
        ),
        titleOf: titleOf,
      );
      // Only message 2: chat 1, 120 s, and its channel title contains 18号.
      expect(hits.map((r) => r.messageId), <int>[2]);
    });

    test('a duration filter excludes rows with unknown length', () {
      final hits = VideoQueryEngine.apply(
        records,
        const VideoQuery(categoryChatId: 2, duration: DurationFilter.overFiveMinutes),
        titleOf: titleOf,
      );
      expect(hits.map((r) => r.messageId), <int>[3]);
    });
  });

  group('MediaRecord caption plumbing', () {
    test('caption survives JSON round-trip', () {
      final record = video(caption: '仓库 全景');
      final restored = MediaRecord.fromJson(record.toJson());
      expect(restored, isNotNull);
      expect(restored!.caption, '仓库 全景');
    });

    test('a caption is folded to lower case and capped at 512 chars', () {
      final long = 'A' * 600;
      final record = MediaRecord.fromMessage(
        chatId: 9,
        message: <String, Object?>{
          'id': 11,
          'date': 1700000000,
          'content': <String, Object?>{
            '@type': 'messageVideo',
            'caption': <String, Object?>{'text': long},
            'video': <String, Object?>{
              'duration': 10,
              'width': 100,
              'height': 200,
              'video': <String, Object?>{'id': 5, 'expected_size': 1000},
            },
          },
        },
      );
      expect(record, isNotNull);
      expect(record!.caption!.length, 512);
      expect(record.caption, record.caption!.toLowerCase());
    });

    test('an empty caption becomes null instead of an empty string', () {
      final record = MediaRecord.fromMessage(
        chatId: 9,
        message: <String, Object?>{
          'id': 12,
          'date': 1700000000,
          'content': <String, Object?>{
            '@type': 'messageVideo',
            'caption': <String, Object?>{'text': '   '},
            'video': <String, Object?>{
              'duration': 10,
              'video': <String, Object?>{'id': 6, 'expected_size': 10},
            },
          },
        },
      );
      expect(record!.caption, isNull);
    });
  }, skip: false);
}
