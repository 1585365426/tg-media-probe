import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/storage/download_paths.dart';

void main() {
  group('sanitizeFileName', () {
    test('strips POSIX path traversal', () {
      final name = sanitizeFileName('../../Library/Preferences/x.plist');
      expect(name.contains('/'), isFalse);
      expect(name.contains('..'), isFalse);
      expect(name, 'x.plist');
    });

    test('strips Windows path separators too', () {
      final name = sanitizeFileName(r'..\..\Windows\System32\evil.dll');
      expect(name.contains(r'\'), isFalse);
      expect(name.contains('/'), isFalse);
      expect(name, 'evil.dll');
    });

    test('removes a leading dot so the file is never hidden', () {
      expect(sanitizeFileName('.hidden.mp4'), 'hidden.mp4');
      expect(sanitizeFileName('....mp4'), 'mp4');
    });

    test('replaces characters that are illegal on some filesystems', () {
      // `?` and `#` are covered by the query-string test: they truncate the
      // name instead of being rewritten, because they mean "URL", not "name".
      final name = sanitizeFileName('a<b>c:d"e|f*g.mp4');
      for (final ch in <String>['<', '>', ':', '"', '|', '*']) {
        expect(name.contains(ch), isFalse, reason: 'kept $ch');
      }
      expect(name.endsWith('.mp4'), isTrue);
    });

    test('collapses whitespace', () {
      expect(sanitizeFileName('my    video   clip.mp4'), 'my_video_clip.mp4');
    });

    test('falls back to "file" when nothing usable is left', () {
      expect(sanitizeFileName(''), 'file');
      expect(sanitizeFileName('...'), 'file');
      expect(sanitizeFileName('   '), 'file');
      expect(sanitizeFileName(null), 'file');
      expect(sanitizeFileName('/'), 'file');
    });

    test('keeps ordinary names untouched', () {
      expect(sanitizeFileName('VID_20250101_120000.mp4'),
          'VID_20250101_120000.mp4');
    });

    test('truncates a huge stem but keeps the extension', () {
      final name = sanitizeFileName('${'a' * 500}.mp4');
      expect(name.endsWith('.mp4'), isTrue);
      expect(name.length, lessThanOrEqualTo(84));
    });

    test('drops a query-string style fake extension', () {
      final name = sanitizeFileName('clip.MP4?token=1');
      expect(name.contains('?'), isFalse);
      expect(name.contains('token'), isFalse);
    });
  });

  group('extension inference', () {
    test('takes the extension from the file name first', () {
      expect(extensionFor(fileName: 'a.MOV', mimeType: 'video/mp4'), '.mov');
    });

    test('falls back to the mime type', () {
      expect(extensionFor(fileName: null, mimeType: 'video/mp4'), '.mp4');
      expect(extensionFor(fileName: 'noext', mimeType: 'image/jpeg'), '.jpg');
    });

    test('returns empty when nothing is known', () {
      expect(extensionFor(fileName: null, mimeType: null), '');
      expect(extensionFor(fileName: null, mimeType: 'application/x-unknown'),
          '');
    });
  });

  group('downloadFileName', () {
    test('appends the file id so equal names cannot collide', () {
      final a = downloadFileName(fileId: 1, fileName: 'video.mp4');
      final b = downloadFileName(fileId: 2, fileName: 'video.mp4');

      expect(a, 'video_1.mp4');
      expect(b, 'video_2.mp4');
      expect(a, isNot(b));
    });

    test('is stable for the same file id', () {
      expect(
        downloadFileName(fileId: 9, fileName: 'x.mp4'),
        downloadFileName(fileId: 9, fileName: 'x.mp4'),
      );
    });

    test('supplies an extension from the mime type', () {
      expect(downloadFileName(fileId: 3, fileName: null, mimeType: 'video/mp4'),
          'file_3.mp4');
    });

    test('works when Telegram sends no name at all', () {
      expect(downloadFileName(fileId: 4), 'file_4');
    });
  });

  group('chatFolderName', () {
    test('keeps a positive id readable', () {
      expect(chatFolderName(123456), 'c123456');
    });

    test('drops the sign so the folder is not read as a flag', () {
      expect(chatFolderName(-1001234567890), 'c1001234567890');
    });
  });

  group('userDownloadPath', () {
    const root = '/sandbox/Documents/TGMediaDownloads';

    test('lands in a per-chat folder', () {
      final path = userDownloadPath(
          downloadsRoot: root, chatId: 42, fileId: 7, fileName: 'v.mp4');
      expect(p.dirname(path), p.join(root, 'c42'));
    });

    test('cannot escape the download root, even with a hostile name', () {
      final path = userDownloadPath(
        downloadsRoot: root,
        chatId: 42,
        fileId: 7,
        fileName: '../../../../Library/Preferences/com.apple.x.plist',
      );
      expect(p.isWithin(root, path), isTrue,
          reason: 'resolved to $path');
    });

    test('an absolute-looking name stays relative', () {
      final path = userDownloadPath(
        downloadsRoot: root,
        chatId: 1,
        fileId: 2,
        fileName: '/etc/passwd',
      );
      expect(p.isWithin(root, path), isTrue);
      expect(path.contains('/etc/'), isFalse);
    });
  });
}
