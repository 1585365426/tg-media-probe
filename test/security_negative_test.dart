/// Nine negative tests for the places where "it seemed to work" is the failure.
///
/// Every case here asserts that a *refusal* happens: a delete that must not
/// run, a lock that must not open, an export that must not ship. They are the
/// counterpart to the happy-path tests — without them, "cache cleared" can
/// mean "cache cleared plus three downloads" and nothing catches it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/security/biometric.dart';
import 'package:tg_media_probe/security/lock_policy.dart';
import 'package:tg_media_probe/security/passcode.dart';
import 'package:tg_media_probe/security/td_readonly_guard.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/storage/file_ops.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';
import 'package:tg_media_probe/util/redact.dart';

import 'support/sandbox.dart';

/// Reports success and deletes nothing — the "fake success" shape.
class NoopDeleteOps extends IoFileOps {
  const NoopDeleteOps();

  @override
  Future<void> deleteFile(String path) async {
    // Intentionally empty: the caller must not trust it.
  }
}

/// Hand-rolled JSON in the exact shape [AppLockStore] reads, so a test can
/// write a tampered blob without touching private encoders.
String encodeLock({bool biometric = false, String? record}) =>
    '{"biometricEnabled":$biometric,"autoLockDelay":"immediately",'
    '"lockOnColdStart":true,"passcodeRecord":'
    '${record == null ? 'null' : '"${record.replaceAll('"', r'\"')}"'},'
    '"hint":null}';

/// Records which directories a clear run walked.
class RecordingOps extends IoFileOps {
  RecordingOps();

  final List<String> walks = <String>[];

  @override
  Future<List<String>> listFilesRecursive(String path) async {
    walks.add(path);
    return super.listFilesRecursive(path);
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

  // ---------------------------------------------------------------- 1 ------
  group('1. 越界删除', () {
    test('a clear never deletes outside the media root', () async {
      final download = sandbox.downloadFile('mine.mp4');
      final index = sandbox.indexFile('media.db');
      final auth = sandbox.authFile('td.binlog');
      final media = p.join(sandbox.layout.mediaRoot, 'tdlib', 'blob.mp4');
      for (final path in <String>[download, index, auth, media]) {
        await sandbox.writeBytes(path, 8);
      }

      final wipe = await MediaCache(layout: sandbox.layout).clearLocal();

      expect(await sandbox.exists(download), isTrue);
      expect(await sandbox.exists(index), isTrue);
      expect(await sandbox.exists(auth), isTrue);
      expect(await sandbox.exists(media), isFalse);
      expect(wipe.deletedFiles, 1);
      expect(wipe.freedBytes, 8);
    });

    test('a file in the downloads zone is refused by the layout guard',
        () async {
      final path = sandbox.downloadFile('mine.mp4');
      await sandbox.writeBytes(path, 8);

      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(path),
        throwsA(isA<ZoneViolation>().having(
          (e) => e.message,
          'message',
          contains('protected'),
        )),
      );
      expect(await sandbox.exists(path), isTrue);
    });

    test('the media pool is outside the temp zone on purpose', () async {
      // iOS may purge Library/Caches at any time; the pool must not live there
      // or "downloaded once, plays offline" would be a lie.
      expect(
        p.isWithin(sandbox.layout.tempRoot, sandbox.layout.tdlibFilesDir),
        isFalse,
      );
      expect(await sandbox.layout.zoneOf(sandbox.layout.tdlibFilesDir), isNull);
    });

    test('a .. traversal out of the media root is refused', () async {
      final escaped = p.join(sandbox.layout.mediaRoot, '..',
          p.basename(sandbox.layout.downloadsDir), 'mine.mp4');
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(escaped),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('the temp zone root itself is refused', () async {
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(sandbox.layout.tempRoot),
        throwsA(isA<ZoneViolation>().having(
          (e) => e.message,
          'message',
          contains('zone root itself'),
        )),
      );
    });
  });

  // ---------------------------------------------------------------- 2 ------
  group('2. 符号链接逃逸', () {
    test('a link inside the media root never lets its target be deleted',
        () async {
      final target = sandbox.downloadFile('keep.bin');
      await sandbox.writeBytes(target, 64);
      final linkPath = p.join(sandbox.layout.mediaRoot, 'escape.bin');

      try {
        await Link(linkPath).create(target);
      } on FileSystemException {
        // Windows without developer mode cannot create symlinks; CI runs the
        // real link on macOS. The lexical refusal is still asserted below.
        final escaped = p.join(sandbox.layout.mediaRoot, '..',
            p.basename(sandbox.layout.downloadsDir), 'keep.bin');
        await expectLater(
          sandbox.layout.assertDeletableByCacheClear(escaped),
          throwsA(isA<ZoneViolation>()),
        );
        expect(await sandbox.exists(target), isTrue);
        return;
      }

      final wipe = await MediaCache(layout: sandbox.layout).clearLocal();

      expect(await sandbox.exists(target), isTrue,
          reason: 'the link target lives in the protected downloads zone');
      // The walk only reports regular files (`followLinks: false`), so a link
      // is never followed to its target — the target's bytes are untouchable.
      expect(wipe.deletedFiles, 0);
      expect(wipe.errors, isEmpty);
    });
  });

  // ---------------------------------------------------------------- 3 ------
  group('3. 只清自己的目录', () {
    test('a clear walks the media root and nothing else', () async {
      final ops = RecordingOps();
      await sandbox.writeBytes(sandbox.downloadFile('saved.mp4'), 32);
      await sandbox.writeBytes(sandbox.tempFile('stale.jpg'), 8);
      await sandbox.writeBytes(
          p.join(sandbox.layout.mediaRoot, 'tdlib', 'blob.mp4'), 8);

      await MediaCache(layout: sandbox.layout, ops: ops).clearLocal();

      final protectedRoots = <String>[
        sandbox.layout.downloadsDir,
        sandbox.layout.indexDir,
        sandbox.layout.authMetaDir,
        sandbox.layout.tempRoot,
      ];
      for (final walked in ops.walks) {
        for (final root in protectedRoots) {
          expect(p.isWithin(root, walked), isFalse,
              reason: 'clearLocal() walked $walked');
        }
      }
      expect(ops.walks, <String>[sandbox.layout.mediaRoot]);
    });
  });

  // ---------------------------------------------------------------- 4 ------
  group('4. 占用中文件', () {
    test('the file the player has open is kept and not counted as freed',
        () async {
      final busy = p.join(sandbox.layout.mediaRoot, 'tdlib', 'playing.mp4');
      final idle = p.join(sandbox.layout.mediaRoot, 'tdlib', 'stale.mp4');
      await sandbox.writeBytes(busy, 100);
      await sandbox.writeBytes(idle, 40);

      final wipe = await MediaCache(layout: sandbox.layout)
          .clearLocal(keep: <String>{busy});

      expect(await sandbox.exists(busy), isTrue);
      expect(await sandbox.exists(idle), isFalse);
      expect(wipe.skipped, <String>[busy]);
      expect(wipe.deletedFiles, 1);
      expect(wipe.freedBytes, 40);
    });
  });

  // ---------------------------------------------------------------- 5 ------
  group('5. 假成功', () {
    test('a delete that silently does nothing is reported as failure', () async {
      final file = p.join(sandbox.layout.mediaRoot, 'tdlib', 'ghost.mp4');
      await sandbox.writeBytes(file, 123);

      final wipe = await MediaCache(
        layout: sandbox.layout,
        ops: const NoopDeleteOps(),
      ).clearLocal();

      expect(wipe.deletedFiles, 0);
      expect(wipe.freedBytes, 0);
      expect(wipe.errors.single, contains('still present'));
      expect(wipe.changedAnything, isFalse);
    });
  });

  // ---------------------------------------------------------------- 6 ------
  group('6. Keychain 缺 key', () {
    test('an empty keychain reports no lock instead of a broken one', () async {
      final store = AppLockStore(store: MemorySecretStore(), iterations: 1000);

      final settings = await store.load();

      expect(settings.passcodeEnabled, isFalse);
      expect(settings.biometricEnabled, isFalse);
      expect(settings.lockEnabled, isFalse);
    });

    test('verifying against a missing verifier returns false, never true',
        () async {
      final store = AppLockStore(store: MemorySecretStore(), iterations: 1000);

      expect(await store.verifyPasscode('135790'), isFalse);
    });

    test('a biometric flag without a passcode cannot stand as the only factor',
        () async {
      // Tampered or half-migrated state: biometrics on, no verifier. Written
      // through the real encoder shape so the store decodes it as intended.
      final secrets = MemorySecretStore(<String, String>{
        AppLockStore.storageKey: encodeLock(biometric: true),
      });
      final store = AppLockStore(store: secrets, iterations: 1000);
      final settings = await store.load();

      expect(settings.biometricEnabled, isTrue);
      expect(settings.passcodeEnabled, isFalse);
      // Nothing verifiable exists, so nothing may be demanded: the evaluator
      // refuses to lock the user out over a hand-edited preference.
      expect(
        LockEvaluator.decide(
          settings: settings,
          coldStart: true,
          sinceBackground: null,
          capability: const BiometricCapability.unavailable(),
        ),
        LockRequirement.none,
      );
      expect(await store.verifyPasscode('135790'), isFalse);
      // And the write path refuses to produce that state in the first place.
      expect(settings.withBiometrics(true).biometricEnabled, isTrue);
      expect(AppLockSettings.initial.withBiometrics(true).biometricEnabled,
          isFalse);
    });

    test('an unrelated keychain slot does not unlock anything', () async {
      final secrets = MemorySecretStore(<String, String>{
        'tg_app_prefs_v1': '{}',
        'tg_tdlib_key_v1': 'a' * 64,
      });
      final store = AppLockStore(store: secrets, iterations: 1000);

      expect((await store.load()).lockEnabled, isFalse);
      expect(await store.verifyPasscode('135790'), isFalse);
    });
  });

  // ---------------------------------------------------------------- 7 ------
  group('7. 密码记录被改', () {
    late MemorySecretStore secrets;
    late AppLockStore store;
    const passcode = '135790';

    setUp(() async {
      secrets = MemorySecretStore();
      store = AppLockStore(store: secrets, iterations: 1000);
      expect(await store.setPasscode(passcode), isNull);
    });

    test('one flipped hex character in the hash is rejected', () async {
      final settings = await store.load();
      final record = PasscodeRecord.tryDecode(settings.passcodeRecord!)!;
      final flipped = record.hashHex.startsWith('a')
          ? 'b${record.hashHex.substring(1)}'
          : 'a${record.hashHex.substring(1)}';
      final tampered = PasscodeRecord(
        iterations: record.iterations,
        saltHex: record.saltHex,
        hashHex: flipped,
        keyLength: record.keyLength,
      ).encode();
      await secrets.write(AppLockStore.storageKey, encodeLock(record: tampered));

      expect(await store.verifyPasscode(passcode), isFalse);
    });

    test('a truncated record fails closed instead of throwing', () async {
      final settings = await store.load();
      final truncated = settings.passcodeRecord!.substring(
          0, settings.passcodeRecord!.length - 8);
      await secrets.write(
          AppLockStore.storageKey, encodeLock(record: truncated));

      expect(await store.verifyPasscode(passcode), isFalse);
    });

    test('a record claiming a different scheme is ignored', () async {
      final settings = await store.load();
      final other = settings.passcodeRecord!.replaceFirst('pbkdf2-sha256', 'md5');
      await secrets.write(AppLockStore.storageKey, encodeLock(record: other));

      expect(await store.verifyPasscode(passcode), isFalse);
    });

    test('a wrong passcode is rejected and the right one still works', () async {
      expect(await store.verifyPasscode('000000'), isFalse);
      expect(await store.verifyPasscode(passcode), isTrue);
    });
  });

  // ---------------------------------------------------------------- 8 ------
  group('8. 诊断未脱敏', () {
    const apiHash = '0123456789abcdef0123456789abcdef';
    final dbKey = 'f' * 64;
    const botToken = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw';
    const phone = '+8613800138000';

    test('the raw payload trips the pre-flight check', () {
      final raw = jsonEncode(<String, Object?>{
        'api_hash': apiHash,
        'database_key': dbKey,
        'token': botToken,
        'phone': phone,
        'error': 'code=12345 rejected for $phone with $apiHash',
      });

      expect(mayContainSecret(raw), isTrue);
    });

    test('after redaction nothing secret survives', () {
      final redacted = redactDiagnostics(<String, Object?>{
        'api_hash': apiHash,
        'token': botToken,
        'phone': phone,
        'database_encryption_key': dbKey,
        'passcode_record': 'pbkdf2-sha256\$v=1\$i=1000\$l=32\$s=${'a' * 32}\$h=${'b' * 64}',
        'error': 'code=12345 rejected for $phone with $apiHash and $dbKey',
        'nested': <String, Object?>{'api_hash': apiHash, 'note': dbKey},
      });
      final text = jsonEncode(redacted);

      expect(text.contains(apiHash), isFalse);
      expect(text.contains(dbKey), isFalse);
      expect(text.contains(botToken), isFalse);
      expect(text.contains('13800138000'), isFalse);
      expect(text.contains('pbkdf2-sha256'), isFalse);
      expect(mayContainSecret(text), isFalse,
          reason: 'a payload that still trips this must not be exported');
      // Keys are kept so the export still says what was removed.
      expect(text, contains('api_hash'));
    });

    test('a redacted payload keeps non-secret diagnostics readable', () {
      final redacted = redactDiagnostics(<String, Object?>{
        'tdlibVersion': '1.8.0',
        'chatCount': 42,
        'indexRows': 1234,
      });

      expect(redacted['tdlibVersion'], '1.8.0');
      expect(redacted['chatCount'], 42);
      expect(redacted['indexRows'], 1234);
    });
  });

  // ---------------------------------------------------------------- 9 ------
  group('9. 只读守卫', () {
    test('cloud-mutating methods are rejected', () {
      for (final method in <String>[
        'deleteMessages',
        'sendMessage',
        'editMessageText',
        'forwardMessages',
        'joinChat',
        'leaveChat',
        'deleteChatHistory',
      ]) {
        expect(
          () => TdReadOnlyGuard.assertAllowed(method),
          throwsA(isA<TdReadOnlyViolation>()),
          reason: method,
        );
      }
    });

    test('an unclassified method name is rejected, not assumed safe', () {
      expect(
        () => TdReadOnlyGuard.assertAllowed('someNewMethodFromAFutureTdlib'),
        throwsA(isA<TdReadOnlyViolation>()),
      );
      expect(
        () => TdReadOnlyGuard.assertAllowed(null),
        throwsA(isA<TdReadOnlyViolation>()),
      );
      expect(
        () => TdReadOnlyGuard.assertAllowed(''),
        throwsA(isA<TdReadOnlyViolation>()),
      );
    });

    test('no method is both allowed and cloud-mutating', () {
      final overlap = <String>{
        ...TdReadOnlyGuard.readOnlyMethods,
        ...TdReadOnlyGuard.localOnlyMethods,
      }.intersection(TdReadOnlyGuard.cloudMutatingMethods);

      expect(overlap, isEmpty);
      expect(TdReadOnlyGuard.readOnlyMethods.length, greaterThan(10));
    });

    test('every method td_requests.dart can build is on the allowlist', () {
      // A builder that is not allowlisted throws at runtime, and the only
      // moment anyone notices is a broken login screen. This test moves that
      // discovery to the test run.
      final source = File('lib/td/td_requests.dart').readAsStringSync();
      final found = RegExp(r"'@type':\s*'([A-Za-z]+)'")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      // Nested payload objects share the file but are never sent on their own.
      const nestedPayloadTypes = <String>{
        'chatListMain',
        'phoneNumberAuthenticationSettings',
      };
      final requests = found.difference(nestedPayloadTypes);

      expect(requests, isNotEmpty);
      for (final method in requests) {
        expect(() => TdReadOnlyGuard.assertAllowed(method), returnsNormally,
            reason: '$method is built by td_requests.dart but not allowlisted');
      }
    });

    test('reads and local-only maintenance passes', () {
      for (final method in <String>[
        'getChats',
        'getChat',
        'getChatHistory',
        'getFile',
        'searchChats',
        'deleteFile',
      ]) {
        expect(() => TdReadOnlyGuard.assertAllowed(method), returnsNormally,
            reason: method);
      }
    });
  });

}
