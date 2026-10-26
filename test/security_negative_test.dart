/// Ten negative tests for the places where "it seemed to work" is the failure.
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
import 'package:tg_media_probe/storage/active_files.dart';
import 'package:tg_media_probe/storage/cache_manager.dart';
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
  late ActiveFileRegistry activeFiles;

  setUp(() async {
    sandbox = await TestSandbox.create();
    activeFiles = ActiveFileRegistry();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  CacheManager manager({FileOps? ops, Future<Map<String, int>> Function()? probe}) =>
      CacheManager(
        layout: sandbox.layout,
        ops: ops ?? sandbox.ops,
        activeFiles: activeFiles,
        integrityProbe: probe,
      );

  // ---------------------------------------------------------------- 1 ------
  group('1. 越界删除', () {
    test('a file in the downloads zone is refused', () async {
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

    test('a .. traversal into downloads is refused', () async {
      final escaped =
          p.join(sandbox.layout.tempRoot, '..', p.basename(sandbox.layout.downloadsDir), 'mine.mp4');

      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(escaped),
        throwsA(isA<ZoneViolation>()),
      );
    });

    test('a path outside every managed zone is refused', () async {
      final outside = p.join(sandbox.root.path, 'elsewhere', 'x.bin');
      await sandbox.writeBytes(outside, 4);

      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(outside),
        throwsA(isA<ZoneViolation>().having(
          (e) => e.message,
          'message',
          contains('outside every managed zone'),
        )),
      );
      expect(await sandbox.exists(outside), isTrue);
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

    test('clear() cannot be talked into deleting a download record', () async {
      final path = sandbox.downloadFile('mine.mp4');
      await sandbox.writeBytes(path, 8);

      final report = await manager().clear(userConfirmed: true);

      expect(await sandbox.exists(path), isTrue);
      expect(report.deletedFiles, 0);
    });
  });

  // ---------------------------------------------------------------- 2 ------
  group('2. 符号链接逃逸', () {
    test('a link inside the temp zone that points at a protected file '
        'never lets the protected file be deleted', () async {
      final target = sandbox.downloadFile('keep.bin');
      await sandbox.writeBytes(target, 64);
      final linkPath = p.join(sandbox.layout.thumbnailDir, 'escape.bin');

      var linked = true;
      try {
        await Link(linkPath).create(target);
      } on FileSystemException {
        // Windows without developer mode cannot create symlinks. Fall back to
        // the same canonical() code path through a `..` escape so the guard is
        // still exercised on this machine; CI on macOS runs the real link.
        linked = false;
      }

      if (!linked) {
        await expectLater(
          sandbox.layout.assertDeletableByCacheClear(p.join(
            sandbox.layout.tempRoot,
            '..',
            p.basename(sandbox.layout.downloadsDir),
            'keep.bin',
          )),
          throwsA(isA<ZoneViolation>()),
        );
        expect(await sandbox.exists(target), isTrue);
        return;
      }

      // The link names a temp path but resolves into the downloads zone.
      await expectLater(
        sandbox.layout.assertDeletableByCacheClear(linkPath),
        throwsA(isA<ZoneViolation>()),
      );

      final report = await manager().clear(userConfirmed: true);

      expect(await sandbox.exists(target), isTrue,
          reason: 'the link target lives in the protected zone');
      expect(report.deletedFiles, 0);
    });
  });

  // ---------------------------------------------------------------- 3 ------
  group('3. 未登记目录', () {
    test('scan() walks only the three registered temp kinds', () async {
      final pool = p.join(sandbox.layout.tdlibFilesDir, 'blob.bin');
      final mystery = p.join(sandbox.layout.tempRoot, 'mystery', 'x.bin');
      await sandbox.writeBytes(pool, 32);
      await sandbox.writeBytes(mystery, 16);
      final thumb = sandbox.tempFile('ok.jpg');
      await sandbox.writeBytes(thumb, 8);

      final scan = await manager().scan();

      expect(scan.entries.map((e) => e.path), <String>[thumb]);
      expect(scan.entries.any((e) => e.kind == CacheKind.unknownFromDirectory),
          isFalse);
    });

    test('clear() leaves unregistered directories alone', () async {
      final pool = p.join(sandbox.layout.tdlibFilesDir, 'blob.bin');
      final mystery = p.join(sandbox.layout.tempRoot, 'mystery', 'x.bin');
      await sandbox.writeBytes(pool, 32);
      await sandbox.writeBytes(mystery, 16);

      await manager().clear(userConfirmed: true);

      expect(await sandbox.exists(pool), isTrue);
      expect(await sandbox.exists(mystery), isTrue);
    });
  });

  // ---------------------------------------------------------------- 4 ------
  group('4. 占用中文件', () {
    test('a file in use is skipped and not counted as freed', () async {
      final busy = sandbox.tempFile('playing.mp4', kind: CacheKindName.player);
      final idle = sandbox.tempFile('stale.jpg');
      await sandbox.writeBytes(busy, 100);
      await sandbox.writeBytes(idle, 40);
      activeFiles.markInUse(busy, reason: 'player');

      final scan = await manager().scan();
      expect(scan.inUseCount, 1);
      expect(scan.reclaimableBytes, 40);

      final report = await manager().clear(userConfirmed: true);

      expect(await sandbox.exists(busy), isTrue);
      expect(await sandbox.exists(idle), isFalse);
      expect(report.skippedInUse, <String>[busy]);
      expect(report.deletedFiles, 1);
      expect(report.freedBytes, 40);
    });

    test('two owners keep the file until both release it', () async {
      final busy = sandbox.tempFile('shared.mp4', kind: CacheKindName.player);
      await sandbox.writeBytes(busy, 10);
      activeFiles.markInUse(busy, reason: 'player');
      activeFiles.markInUse(busy, reason: 'preload');

      activeFiles.release(busy);
      expect(activeFiles.isInUse(busy), isTrue);

      activeFiles.release(busy);
      expect(activeFiles.isInUse(busy), isFalse);
    });
  });

  // ---------------------------------------------------------------- 5 ------
  group('5. 假成功', () {
    test('a delete that silently does nothing is reported as failure', () async {
      final file = sandbox.tempFile('ghost.jpg');
      await sandbox.writeBytes(file, 123);

      final report =
          await manager(ops: const NoopDeleteOps()).clear(userConfirmed: true);

      expect(report.deletedFiles, 0);
      expect(report.freedBytes, 0);
      expect(report.failures.single.path, file);
      expect(report.failures.single.reason, contains('still present'));
      expect(report.succeeded, isFalse);
    });

    test('a changed integrity counter fails the run even if files were deleted',
        () async {
      final file = sandbox.tempFile('stale.jpg');
      await sandbox.writeBytes(file, 20);
      var indexRows = 10;

      final report = await manager(probe: () async => <String, int>{
            'indexRows': indexRows,
            'favourites': 3,
          }).clear(userConfirmed: true);
      // First call: before == after, so this run must be honest success.
      expect(report.integrityPreserved, isTrue);
      expect(report.succeeded, isTrue);

      await sandbox.writeBytes(file, 20);
      indexRows = 10;
      final tampered = await manager(probe: () async => <String, int>{
            'indexRows': indexRows++,
            'favourites': 3,
          }).clear(userConfirmed: true);

      expect(tampered.integrityPreserved, isFalse);
      expect(tampered.succeeded, isFalse);
      expect(tampered.summary, contains('索引完整性校验失败'));
    });

    test('clearing without confirmation throws instead of running', () async {
      final file = sandbox.tempFile('stale.jpg');
      await sandbox.writeBytes(file, 20);

      await expectLater(
        manager().clear(userConfirmed: false),
        throwsA(isA<CacheClearNotConfirmed>()),
      );
      expect(await sandbox.exists(file), isTrue);
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

  // --------------------------------------------------------------- 10 ------
  group('10. 缓存清理不碰受保护区', () {
    test('downloads, index and auth files survive a clear', () async {
      final download = sandbox.downloadFile('saved.mp4');
      final index = sandbox.indexFile('media.db');
      final auth = sandbox.authFile('td.binlog');
      final cache = sandbox.tempFile('stale.jpg');
      await sandbox.writeBytes(download, 512);
      await sandbox.writeBytes(index, 256);
      await sandbox.writeBytes(auth, 128);
      await sandbox.writeBytes(cache, 64);

      final report = await manager().clear(userConfirmed: true);

      expect(await sandbox.exists(download), isTrue);
      expect(await sandbox.exists(index), isTrue);
      expect(await sandbox.exists(auth), isTrue);
      expect(await sandbox.exists(cache), isFalse);
      expect(report.protectedZonesIntact, isTrue);
      expect(report.deletedFiles, 1);
      expect(report.freedBytes, 64);
    });

    test('the clear run never walks a protected zone', () async {
      final ops = RecordingOps();
      await sandbox.writeBytes(sandbox.downloadFile('saved.mp4'), 32);
      await sandbox.writeBytes(sandbox.tempFile('stale.jpg'), 8);

      await CacheManager(
        layout: sandbox.layout,
        ops: ops,
        activeFiles: activeFiles,
      ).clear(userConfirmed: true);

      final protectedRoots = <String>[
        sandbox.layout.downloadsDir,
        sandbox.layout.indexDir,
        sandbox.layout.authMetaDir,
      ];
      for (final walked in ops.walks) {
        for (final root in protectedRoots) {
          expect(p.isWithin(root, walked), isFalse,
              reason: 'clear() walked $walked');
        }
      }
      // The other side of the guarantee: it did walk the temp zone.
      expect(
        ops.walks.any((w) => p.isWithin(sandbox.layout.tempRoot, w)),
        isTrue,
      );
    });

    test('usage() reports protected zones as unmeasured by default', () async {
      await sandbox.writeBytes(sandbox.downloadFile('saved.mp4'), 32);

      final sizes = await manager().usage();

      expect(sizes[StorageZone.userDownloads], -1);
      expect(sizes[StorageZone.indexDb], -1);
      expect(sizes[StorageZone.authMeta], -1);
      expect(sizes[StorageZone.tempCache], isNotNull);
    });
  });
}
