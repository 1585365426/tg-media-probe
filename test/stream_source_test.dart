import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/data/media_streamer.dart';
import 'package:tg_media_probe/data/td_stream_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

MediaRecord _record({
  int fileId = 42,
  int sizeBytes = 1024,
  bool protected = false,
}) =>
    MediaRecord(
      chatId: 1,
      messageId: 2,
      fileId: fileId,
      kind: MediaKind.video,
      sizeBytes: sizeBytes,
      hasProtectedContent: protected,
    );

void main() {
  group('canStream', () {
    test('accepts a normal video', () {
      expect(canStream(_record()), isTrue);
    });

    test('refuses a record with no file id', () {
      expect(canStream(_record(fileId: 0)), isFalse);
    });

    test('refuses protected content', () {
      expect(canStream(_record(protected: true)), isFalse);
    });

    test('refuses an unknown size, because ranges need a total', () {
      expect(canStream(_record(sizeBytes: 0)), isFalse);
      expect(canStream(_record(sizeBytes: -1)), isFalse);
    });
  });

  group('windowOf', () {
    FileState state({
      String path = '/pool/aa/bb/blob',
      int expectedSize = 1000,
      int prefix = 400,
      int offset = 0,
      bool completed = false,
    }) =>
        FileState(
          id: 42,
          size: expectedSize,
          expectedSize: expectedSize,
          downloadedSize: prefix,
          isCompleted: completed,
          path: path,
          canBeDownloaded: true,
          downloadOffset: offset,
          downloadedPrefixSize: prefix,
        );

    test('reports exactly the contiguous prefix', () {
      final window = windowOf(state())!;
      expect(window.path, '/pool/aa/bb/blob');
      expect(window.offset, 0);
      expect(window.prefixSize, 400);
      expect(window.covers(0, 1), isTrue);
      expect(window.covers(399, 1), isTrue);
      expect(window.covers(400, 1), isFalse);
      // downloaded_size is 400 here but it counts bytes *anywhere*; the reader
      // must never treat the missing tail as present.
      expect(window.covers(0, 401), isFalse);
    });

    test('carries a non-zero download offset through', () {
      final window = windowOf(state(offset: 200, prefix: 300))!;
      expect(window.offset, 200);
      expect(window.physicalOffset(200), 0);
      expect(window.covers(199, 1), isFalse);
      expect(window.covers(200, 1), isTrue);
      expect(window.covers(499, 1), isTrue);
      expect(window.covers(500, 1), isFalse);
    });

    test('a completed file with no prefix counter is fully readable', () {
      // Older TDLib builds leave downloaded_prefix_size at 0 even when the file
      // is done; refusing to serve it would break playback for no reason.
      final window = windowOf(state(prefix: 0, completed: true))!;
      expect(window.prefixSize, 1000);
      expect(window.covers(999, 1), isTrue);
    });

    test('a file with no path is not readable yet', () {
      expect(windowOf(state(path: '', prefix: 100)), isNull);
      expect(windowOf(null), isNull);
    });

    test('a zero prefix on an incomplete file is not readable', () {
      expect(windowOf(state(prefix: 0, completed: false)), isNull);
    });
  });

  group('FileState', () {
    test('totalSize prefers expected_size and falls back to size', () {
      expect(
        const FileState(
          id: 1,
          size: 10,
          expectedSize: 99,
          downloadedSize: 0,
          isCompleted: false,
          path: '',
          canBeDownloaded: true,
        ).totalSize,
        99,
      );
      expect(
        const FileState(
          id: 1,
          size: 10,
          expectedSize: 0,
          downloadedSize: 0,
          isCompleted: false,
          path: '',
          canBeDownloaded: true,
        ).totalSize,
        10,
      );
    });

    test('parses the streaming fields out of a real updateFile payload', () {
      final state = FileState.fromJson(<String, Object?>{
        'id': 7,
        'size': 5000,
        'expected_size': 9000,
        'local': <String, Object?>{
          'path': '/pool/x',
          'can_be_downloaded': true,
          'is_downloading_active': true,
          'is_downloading_completed': false,
          'download_offset': 1024,
          'downloaded_prefix_size': 2048,
          'downloaded_size': 4096,
        },
      });
      expect(state.downloadOffset, 1024);
      expect(state.downloadedPrefixSize, 2048);
      expect(state.totalSize, 9000);
      expect(state.isFullyLocal, isFalse);
      expect(windowOf(state)!.prefixSize, 2048);
    });
  });
}
