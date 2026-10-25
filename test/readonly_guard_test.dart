import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/security/td_readonly_guard.dart';
import 'package:tg_media_probe/td/td_requests.dart';

List<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

const String _guardFile = 'lib/security/td_readonly_guard.dart';

/// Fixed 64-hex database key for tests. The device generates its own and
/// keeps it in the Keychain; nothing here is ever used on a real run.
const String testDbKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('static guard', () {
    test('no source file names a cloud-mutating TDLib method', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        if (p.normalize(file.path) == p.normalize(_guardFile)) continue;
        final source = file.readAsStringSync();
        for (final name in TdReadOnlyGuard.scanPatterns) {
          if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(source)) {
            offenders.add('${file.path}: $name');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'TG Media is read-only towards Telegram. Offending '
              'references:\n${offenders.join('\n')}');
    });

    test('TdClient enforces the guard at its single request choke point', () {
      final source = File('lib/td/td_client.dart').readAsStringSync();
      expect(source, contains('TdReadOnlyGuard.assertAllowed'));
      // The guard call has to happen before the payload is handed to tdjson.
      final guardIndex = source.indexOf('TdReadOnlyGuard.assertAllowed');
      final sendIndex = source.indexOf('_bindings.sendJson');
      expect(guardIndex, greaterThan(0));
      expect(sendIndex, greaterThan(guardIndex),
          reason: 'guard must run before sendJson');
    });

    test('the storage layer cannot reach Telegram at all', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        if (!p.normalize(file.path).contains(p.normalize('lib/storage'))) {
          continue;
        }
        final source = file.readAsStringSync();
        for (final needle in <String>[
          'TdClient',
          'TdReadOnlyGuard',
          "'../td/",
          "package:tg_media_probe/td/",
        ]) {
          if (source.contains(needle)) offenders.add('${file.path}: $needle');
        }
      }
      expect(offenders, isEmpty,
          reason: 'cache code must not be able to call TDLib:\n'
              '${offenders.join('\n')}');
    });

    test('the cache manager has no network dependency', () {
      final source = File('lib/storage/cache_manager.dart').readAsStringSync();
      expect(source.contains('HttpClient'), isFalse);
      expect(source.contains('Socket'), isFalse);
    });
  });

  group('runtime guard', () {
    test('rejects every cloud-mutating method', () {
      expect(TdReadOnlyGuard.cloudMutatingMethods.length, greaterThan(40));
      for (final method in TdReadOnlyGuard.cloudMutatingMethods) {
        expect(
          () => TdReadOnlyGuard.assertAllowed(method),
          throwsA(isA<TdReadOnlyViolation>()),
          reason: '$method must be rejected',
        );
      }
    });

    test('the core deletions from the task book are covered', () {
      for (final method in <String>[
        'deleteMessages',
        'deleteChatHistory',
        'deleteChat',
        'deleteSupergroup',
        'forwardMessages',
        'sendMessage',
        'editMessageText',
      ]) {
        expect(TdReadOnlyGuard.isCloudMutating(method), isTrue,
            reason: '$method must be classified as a cloud write');
      }
    });

    test('allows every request the app actually builds', () {
      final payloads = <Map<String, Object?>>[
        setTdlibParameters(
          apiId: 1,
          apiHash: 'hash',
          databaseDirectory: '/tmp/db',
          filesDirectory: '/tmp/files',
          databaseEncryptionKey: testDbKey,
        ),
        getAuthorizationState(),
        setAuthenticationPhoneNumber('+10000000000'),
        checkAuthenticationCode('12345'),
        checkAuthenticationPassword('pw'),
        getChats(),
        getChat(1),
        getChatHistory(chatId: 1),
        getMessage(chatId: 1, messageId: 2),
        getFile(3),
        downloadFile(fileId: 4),
        cancelDownloadFile(fileId: 4),
        getMe(),
      ];
      for (final payload in payloads) {
        expect(() => TdReadOnlyGuard.assertAllowed(payload['@type']),
            returnsNormally,
            reason: '${payload['@type']} must stay usable');
      }
    });

    test('deleteFile is documented as local-only and allowed', () {
      expect(TdReadOnlyGuard.isLocalOnly('deleteFile'), isTrue);
      expect(() => TdReadOnlyGuard.assertAllowed('deleteFile'), returnsNormally);
    });

    test('rejects a missing or non-string @type', () {
      expect(() => TdReadOnlyGuard.assertAllowed(null),
          throwsA(isA<TdReadOnlyViolation>()));
      expect(() => TdReadOnlyGuard.assertAllowed(42),
          throwsA(isA<TdReadOnlyViolation>()));
      expect(() => TdReadOnlyGuard.assertAllowed(''),
          throwsA(isA<TdReadOnlyViolation>()));
    });
  });
}
