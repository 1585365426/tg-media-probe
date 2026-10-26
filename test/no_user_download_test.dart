/// Keeps the removed download feature from creeping back.
///
/// Two different things are easy to confuse here, and the app only wants one of
/// them: `downloadFile` moves bytes into TDLib's own pool so they can be
/// played. Copying those bytes into Documents and listing them for the user is
/// the feature that was cut in step 4. These assertions fail if the second one
/// returns.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;


List<File> _sources(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => File(p.normalize(f.path)))
    .toList();

String _rel(File f) =>
    p.relative(f.path, from: Directory.current.path).replaceAll('\\', '/');

/// Drops `//` line comments and `/* */` blocks so a comment that *explains*
/// the removal does not count as a reference to it.
String _codeOnly(String source) {
  final withoutBlock = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return withoutBlock
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index >= 0 ? line.substring(0, index) : line;
      })
      .join('\n');
}

void main() {
  group('no user-facing download feature', () {
    test('nothing copies media into the user documents zone', () {
      final offenders = <String>[];
      for (final file in _sources('lib')) {
        final relative = _rel(file);
        final source = _codeOnly(file.readAsStringSync());
        for (final needle in <String>[
          'DownloadMover',
          'download_mover',
          'download_paths',
          'promote(',
        ]) {
          if (source.contains(needle)) offenders.add('$relative: $needle');
        }
      }
      expect(offenders, isEmpty,
          reason: 'the download feature was removed; these references are '
              'leftovers:\n${offenders.join('\n')}');
    });

    test('no production file writes into the downloads zone by path', () {
      final offenders = <String>[];
      for (final file in _sources('lib')) {
        final relative = _rel(file);
        // storage_layout defines the zone; the guard tests reference it.
        if (relative == 'lib/storage/storage_layout.dart') continue;
        // app_paths wires the zone into the layout; nothing may *use* it.
        if (relative == 'lib/storage/app_paths.dart') continue;
        final source = _codeOnly(file.readAsStringSync());
        if (source.contains('downloadsDir') || source.contains('TGMediaDownloads')) {
          offenders.add(relative);
        }
      }
      expect(offenders, isEmpty,
          reason: 'nothing should target the user downloads zone:\n'
              '${offenders.join('\n')}');
    });

    test('the settings screen does not advertise download management', () {
      final source = File(p.normalize('lib/ui/settings_page.dart'))
          .readAsStringSync();
      for (final phrase in <String>[
        '下载管理',
        '下载记录',
        '保存到相册',
        '保存到文件',
        '下载历史',
      ]) {
        expect(source.contains(phrase), isFalse,
            reason: 'settings must not offer "$phrase"');
      }
    });

    test('the media read path is still present', () {
      // The flip side: downloadFile is what makes playback possible at all.
      final requests =
          File(p.normalize('lib/td/td_requests.dart')).readAsStringSync();
      expect(requests.contains("'@type': 'downloadFile'"), isTrue,
          reason: 'removing this stops every video from ever playing');
      expect(requests.contains('cancelDownloadFile'), isTrue);
    });
  });
}
