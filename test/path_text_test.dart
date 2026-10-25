import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/util/path_text.dart';

void main() {
  const containerPath =
      '/var/mobile/Containers/Data/Application/25212DE5-1F3A-4C8E-9B21-77A0C4E5D912/Documents/TGMediaDownloads/c1002273572608/bb4a413292c6_4039.mp4';

  group('withPathBreaks', () {
    test('leaves an empty string alone', () {
      expect(withPathBreaks(''), '');
    });

    test('leaves short tokens alone', () {
      expect(withPathBreaks('db=/tmp/db'), 'db=/tmp/db');
    });

    test('leaves long tokens without a separator alone', () {
      const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(token.length, greaterThan(24));
      expect(withPathBreaks(token), token);
    });

    test('adds a break opportunity after every separator in a long path', () {
      final decorated = withPathBreaks(containerPath);
      expect(decorated.contains(kSoftBreak), isTrue);

      final separators = containerPath.split('/').length - 1;
      final breaks = decorated.split(kSoftBreak).length - 1;
      expect(breaks, separators);
    });

    test('never hides a visible character', () {
      expect(stripSoftBreaks(withPathBreaks(containerPath)), containerPath);
    });

    test('only decorates the path token inside surrounding prose', () {
      final mixed = 'downloaded 5809108 B -> $containerPath';
      final decorated = withPathBreaks(mixed);

      expect(decorated.startsWith('downloaded 5809108 B -> '), isTrue);
      expect(decorated.endsWith(containerPath.replaceAll('/', '/$kSoftBreak')),
          isTrue);
      expect(stripSoftBreaks(decorated), mixed);
    });

    test('keeps the container UUID unbroken when the string is wrapped', () {
      // The point of the change: the UUID must be one run of characters with no
      // break opportunity inside it, otherwise the device screenshot shows it
      // sliced across two lines.
      final decorated = withPathBreaks(containerPath);
      const uuid = '25212DE5-1F3A-4C8E-9B21-77A0C4E5D912';
      expect(decorated.contains(uuid), isTrue);
    });

    test('respects a caller-supplied threshold', () {
      const short = '/a/bb/ccc';
      expect(withPathBreaks(short, minTokenLength: 4), contains(kSoftBreak));
      expect(withPathBreaks(short), short);
    });

    test('decorates URLs the same way', () {
      const url = 'https://github.com/1585365426/tg-media-probe/actions/runs/40217760668';
      final decorated = withPathBreaks(url);
      expect(decorated.contains(kSoftBreak), isTrue);
      expect(stripSoftBreaks(decorated), url);
    });

    test('is idempotent in the sense that stripping twice is still a no-op', () {
      final once = stripSoftBreaks(withPathBreaks(containerPath));
      expect(stripSoftBreaks(once), containerPath);
    });
  });

  group('stripSoftBreaks', () {
    test('returns the input when there is nothing to strip', () {
      expect(stripSoftBreaks('/tmp/db'), '/tmp/db');
    });

    test('removes every soft break', () {
      expect(stripSoftBreaks('a\u200Bb\u200Bc'), 'abc');
    });
  });
}
