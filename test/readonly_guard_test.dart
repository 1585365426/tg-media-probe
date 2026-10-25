import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guard: the app must stay read-only towards Telegram cloud data.
///
/// A UI that merely hides a button is not a guarantee. This test fails the
/// build if any source file under lib/ so much as names a cloud-mutating
/// TDLib method, which makes "accidentally shipping a delete path" impossible
/// without deliberately editing this test.
void main() {
  const forbidden = <String>[
    'deleteMessages',
    'deleteChatHistory',
    'deleteChat',
    'deleteMessage',
    'leaveChat',
    'sendMessage',
    'forwardMessages',
    'sendVideo',
    'sendPhoto',
    'sendDocument',
    'editMessageText',
    'editMessageCaption',
    'editMessageMedia',
    'editMessageReplyMarkup',
  ];

  test('lib/ contains no cloud-mutating TDLib calls', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue);

    final offenders = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final name in forbidden) {
        if (source.contains(name)) {
          offenders.add('${entity.path}: $name');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'read-only violation:\n${offenders.join('\n')}');
  });

  test('cache or download code never references Telegram deletion APIs', () {
    // The probe has no cache layer yet; this asserts the invariant holds for
    // any file that mentions cache/temp handling so step 3 inherits it.
    final hits = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync().toLowerCase();
      if (!source.contains('cache') && !source.contains('temp')) continue;
      if (source.contains('delete')) {
        hits.add(entity.path);
      }
    }
    expect(hits, isEmpty, reason: 'review deletion logic in: $hits');
  });
}
