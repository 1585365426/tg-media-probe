/// Guards the boundary itself, not just the method list.
///
/// readonly_guard_test.dart proves "we never name a write method". This file
/// proves the harder half: nobody can open a second door to tdjson, and the
/// single door really does refuse a bad payload instead of merely looking like
/// it would.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/security/td_readonly_guard.dart';
import 'package:tg_media_probe/td/td_client.dart';
import 'package:tg_media_probe/td/td_requests.dart';
import 'package:tg_media_probe/td/tdjson_ffi.dart';

List<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => File(p.normalize(f.path)))
    .toList();

String _read(String path) => File(p.normalize(path)).readAsStringSync();

/// The only two files allowed to touch the native surface, and why:
/// * `tdjson_ffi.dart` is the binding layer itself (dynamic symbol lookups);
/// * `td_client.dart` is the guarded call site that uses it.
const Set<String> _ffiOwners = <String>{
  'lib/td/tdjson_ffi.dart',
  'lib/td/td_client.dart',
};

/// Symbols that only make sense next to the native library.
const List<String> _nativeSymbols = <String>[
  'TdJsonBindings',
  'DynamicLibrary',
  'td_send',
  'td_receive',
  'td_execute',
  'td_create_client_id',
  'sendJson(',
  'receiveJson(',
  'executeJson(',
];

/// A bindings double that records every payload handed to tdjson.
class SendRecorder {
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  TdJsonBindings get bindings => testingBindings(
        createClientId: () => 7,
        onSend: (clientId, json) =>
            sent.add(jsonDecode(json) as Map<String, Object?>),
        // No events: the receive pump is not started for a test client, and
        // returning null keeps a stray pump from spinning.
        onReceive: () => null,
      );
}

void main() {
  group('native surface is reachable from exactly two files', () {
    test('no other lib/ file mentions a tdjson symbol', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        final relative = p.relative(file.path, from: Directory.current.path);
        final normalized = relative.replaceAll('\\', '/');
        if (_ffiOwners.contains(normalized)) continue;
        final source = file.readAsStringSync();
        for (final symbol in _nativeSymbols) {
          if (source.contains(symbol)) {
            offenders.add('$normalized: $symbol');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'tdjson has one guarded door (lib/td/td_client.dart). '
              'Found other references:\n${offenders.join('\n')}');
    });

    test('only td_client.dart imports the FFI layer', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        final relative =
            p.relative(file.path, from: Directory.current.path).replaceAll('\\', '/');
        if (relative == 'lib/td/tdjson_ffi.dart' ||
            relative == 'lib/td/td_client.dart') {
          continue;
        }
        final source = file.readAsStringSync();
        if (source.contains('tdjson_ffi.dart')) offenders.add(relative);
      }
      expect(offenders, isEmpty,
          reason: 'only the guarded client may use the bindings:\n'
              '${offenders.join('\n')}');
    });

    test('td_client.dart sends through exactly one statement', () {
      final source = _read('lib/td/td_client.dart');
      final sends = RegExp(r'_bindings\.sendJson\(').allMatches(source).length;
      expect(sends, 1,
          reason: 'every tdjson send must sit in the guarded _send() helper; '
              'a second sendJson call is a second door');
    });

    test('the guard runs inside the function that calls sendJson', () {
      final source = _read('lib/td/td_client.dart');
      final sendIndex = source.indexOf('_bindings.sendJson');
      final bodyStart = source.lastIndexOf('void _send(', sendIndex);
      expect(bodyStart, greaterThan(0),
          reason: 'sendJson must live inside _send()');
      final guardIndex =
          source.indexOf('TdReadOnlyGuard.assertAllowed', bodyStart);
      expect(guardIndex, greaterThan(bodyStart));
      expect(guardIndex, lessThan(sendIndex),
          reason: 'the guard has to run before the bytes leave the process');
    });

    test('executeJson is not called anywhere in lib/', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        final relative =
            p.relative(file.path, from: Directory.current.path).replaceAll('\\', '/');
        // The binding layer defines it; nothing else may call it, because
        // td_execute bypasses the read-only guard entirely.
        if (relative == 'lib/td/tdjson_ffi.dart') continue;
        if (file.readAsStringSync().contains('executeJson(')) {
          offenders.add(relative);
        }
      }
      expect(offenders, isEmpty,
          reason: 'td_execute skips the guard; callers must use '
              'TdClient.request instead:\n${offenders.join('\n')}');
    });
  });

  group('the guarded door refuses before sending', () {
    test('a cloud-mutating method throws and never reaches tdjson', () async {
      final recorder = SendRecorder();
      final client = TdClient.withBindings(recorder.bindings, clientId: 7);

      // request() rejects synchronously, before any Future exists — that is
      // the point: no @extra is consumed, no completer is registered.
      expect(
        () => client.request(<String, Object?>{'@type': 'sendMessage', 'chat_id': 1}),
        throwsA(isA<TdReadOnlyViolation>()),
      );
      expect(recorder.sent, isEmpty);

      await client.dispose();
    });

    test('an unclassified method throws instead of being assumed safe',
        () async {
      final recorder = SendRecorder();
      final client = TdClient.withBindings(recorder.bindings, clientId: 7);

      expect(
        () => client.request(<String, Object?>{'@type': 'someFutureTdlibMethod'}),
        throwsA(isA<TdReadOnlyViolation>().having(
          (e) => e.reason,
          'reason',
          contains('allowlist'),
        )),
      );
      expect(recorder.sent, isEmpty);

      await client.dispose();
    });

    test('a payload without @type throws and sends nothing', () async {
      final recorder = SendRecorder();
      final client = TdClient.withBindings(recorder.bindings, clientId: 7);

      expect(
        () => client.request(<String, Object?>{'chat_id': 1}),
        throwsA(isA<TdReadOnlyViolation>()),
      );
      expect(recorder.sent, isEmpty);

      await client.dispose();
    });

    test('an allowed read does reach tdjson, with an @extra tag', () async {
      final recorder = SendRecorder();
      final client = TdClient.withBindings(recorder.bindings, clientId: 7);

      // Nothing answers in the fake, so the request times out — the timeout is
      // the proof that the payload was actually handed over.
      await expectLater(
        client.request(getChats(limit: 5),
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expect(recorder.sent, hasLength(1));
      expect(recorder.sent.single['@type'], 'getChats');
      expect(recorder.sent.single['@extra'], isA<int>());

      await client.dispose();
    });

    test('dispose sends close and it passes the guard', () async {
      final recorder = SendRecorder();
      final client = TdClient.withBindings(recorder.bindings, clientId: 7);

      await client.dispose();

      expect(recorder.sent.map((e) => e['@type']), contains('close'));
    });
  });

  group('session and login calls stay allowed', () {
    // These are the documented exceptions: without them the app cannot sign in
    // or out. Each one must get past the guard, which is visible as a timeout
    // (the fake never answers) rather than a TdReadOnlyViolation.
    final allowed = <String, Map<String, Object?>>{
      'setTdlibParameters': setTdlibParameters(
        databaseDirectory: '/tmp/db',
        filesDirectory: '/tmp/files',
        databaseEncryptionKey: 'a' * 64,
        apiId: 1,
        apiHash: 'hash',
      ),
      'getAuthorizationState': getAuthorizationState(),
      'setAuthenticationPhoneNumber':
          setAuthenticationPhoneNumber('+8613000000000'),
      'checkAuthenticationCode': checkAuthenticationCode('12345'),
      'checkAuthenticationPassword': checkAuthenticationPassword('secret'),
      'logOut': logOut(),
      'getMe': getMe(),
    };

    test('every session method passes the guard', () async {
      for (final entry in allowed.entries) {
        final recorder = SendRecorder();
        final client = TdClient.withBindings(recorder.bindings, clientId: 7);
        await expectLater(
          client.request(entry.value,
              timeout: const Duration(milliseconds: 10)),
          throwsA(isA<TimeoutException>()),
          reason: '${entry.key} must be sendable',
        );
        expect(recorder.sent.single['@type'], entry.key,
            reason: '${entry.key} should have reached tdjson');
        await client.dispose();
      }
    });

    test('a write method that differs by one word is still refused', () async {
      // Sanity check that the allowlist is exact, not prefix based: these are
      // plausible future names that must not slip through.
      for (final name in <String>[
        'sendMessageAlbum',
        'forwardMessages',
        'deleteChatHistory',
        'setChatTitle',
        'someNewMethodFromAFutureTdlib',
      ]) {
        final recorder = SendRecorder();
        final client = TdClient.withBindings(recorder.bindings, clientId: 7);
        expect(
          () => client.request(<String, Object?>{'@type': name}),
          throwsA(isA<TdReadOnlyViolation>()),
          reason: '$name must not be allowed',
        );
        expect(recorder.sent, isEmpty, reason: '$name reached tdjson');
        await client.dispose();
      }
    });
  });
}
