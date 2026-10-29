/// Numbering: #001 is the oldest video, a new upload appends, and a number is
/// never derived from a message id or a file id.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_index.dart';
import 'package:tg_media_probe/data/media_record.dart';

MediaRecord video({
  required int messageId,
  int chatId = 1,
  int date = 1790000000,
  int fileIdOffset = 0,
  String? caption,
  String? fileName,
  MediaKind kind = MediaKind.video,
}) =>
    MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 500 + messageId + fileIdOffset,
      kind: kind,
      messageDateUnix: date,
      sizeBytes: 1000 + messageId,
      caption: caption,
      fileName: fileName,
    );

void main() {
  test('formatMediaNumber pads to three digits and never truncates', () {
    expect(formatMediaNumber(1), '#001');
    expect(formatMediaNumber(23), '#023');
    expect(formatMediaNumber(999), '#999');
    expect(formatMediaNumber(1234), '#1234');
    expect(formatMediaNumber(0), '#---');
  });

  test('parseMediaNumber accepts bare and hashed input', () {
    expect(parseMediaNumber('23'), 23);
    expect(parseMediaNumber(' #023 '), 23);
    expect(parseMediaNumber('0'), isNull);
    expect(parseMediaNumber('-4'), isNull);
    expect(parseMediaNumber('abc'), isNull);
    expect(parseMediaNumber('9999999999'), isNull);
  });

  test('#001 is the oldest message, not the newest', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 103, date: 300),
      video(messageId: 101, date: 100),
      video(messageId: 102, date: 200),
    ]);
    expect(index.byNumber(1)!.record.messageId, 101);
    expect(index.byNumber(2)!.record.messageId, 102);
    expect(index.byNumber(3)!.record.messageId, 103);
    expect(index.byNumber(1)!.label, '#001');
  });

  test('a new upload appends and never renumbers the existing videos', () {
    final before = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 100, date: 100),
      video(messageId: 101, date: 200),
      video(messageId: 102, date: 300),
    ]);
    final after = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 100, date: 100),
      video(messageId: 101, date: 200),
      video(messageId: 102, date: 300),
      video(messageId: 103, date: 400),
    ]);
    for (var n = 1; n <= 3; n++) {
      expect(after.byNumber(n)!.record.messageId,
          before.byNumber(n)!.record.messageId);
    }
    expect(after.byNumber(4)!.record.messageId, 103);
    expect(after.byNumber(4)!.label, '#004');
  });

  test('numberFor maps a message back to its number', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 7, date: 10),
      video(messageId: 8, date: 20),
    ]);
    expect(index.numberFor(1, 8), 2);
    expect(index.numberFor(1, 999), isNull);
    expect(index.indexFor(1, 7), 0);
  });

  test('a fileId change does not move the number', () {
    final before = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 5, date: 10),
    ]);
    final after = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 5, date: 10, fileIdOffset: 10000),
    ]);
    expect(after.byNumber(1)!.record.messageId, 5);
    expect(after.byNumber(1)!.record.fileId,
        isNot(before.byNumber(1)!.record.fileId));
    expect(after.byNumber(1)!.number, before.byNumber(1)!.number);
  });

  test('non-video rows and files without an id are not numbered', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 1, date: 10),
      video(messageId: 2, date: 20, kind: MediaKind.document),
      MediaRecord(
        chatId: 1,
        messageId: 3,
        fileId: 0,
        kind: MediaKind.video,
        messageDateUnix: 30,
      ),
    ]);
    expect(index.length, 1);
    expect(index.items.single.record.messageId, 1);
  });

  test('search jumps straight to a number', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      for (var i = 1; i <= 30; i++) video(messageId: i, date: i),
    ]);
    final hit = index.search('23');
    expect(hit.single.label, '#023');
    expect(index.search('#023').single.record.messageId, 23);
    expect(index.search('99'), isEmpty);
  });

  test('search matches captions and file names', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 1, date: 10, caption: '海边日落'),
      video(messageId: 2, date: 20, fileName: 'clip_002.mp4'),
    ]);
    expect(index.search('日落').single.label, '#001');
    expect(index.search('clip_002').single.label, '#002');
    expect(index.search('nothing'), isEmpty);
  });

  test('displayTitle never falls back to the message id', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[
      video(messageId: 41, date: 10),
      video(messageId: 42, date: 20, caption: '第一行\n第二行'),
      video(messageId: 43, date: 30, fileName: 'a.mp4'),
    ]);
    expect(index.byNumber(1)!.displayTitle, '视频 #001');
    expect(index.byNumber(2)!.displayTitle, '第一行');
    expect(index.byNumber(3)!.displayTitle, 'a.mp4');
    expect(index.byNumber(1)!.displayTitle.contains('41'), isFalse);
  });

  test('empty input yields an empty index', () {
    final index = MediaIndex.fromRecords(<MediaRecord>[]);
    expect(index.isEmpty, isTrue);
    expect(index.byNumber(1), isNull);
    expect(index.search('1'), isEmpty);
  });
}
