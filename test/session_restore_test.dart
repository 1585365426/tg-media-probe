import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/td/session_restore.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

/// The rule that makes "keep me signed in" work is small and easy to break:
/// `authorizationStateWaitTdlibParameters` arrives **before** TDLib has opened
/// the database, so it must not be read as "logged out". Everything else here
/// follows from that.
void main() {
  group('AuthStageTracker', () {
    test('the pre-configuration state decides nothing', () {
      final tracker = AuthStageTracker();
      expect(tracker.accept('authorizationStateWaitTdlibParameters'), isNull);
      expect(tracker.decision, isNull);
    });

    test('ready is the answer when the stored session is still valid', () {
      final tracker = AuthStageTracker();
      tracker.accept('authorizationStateWaitTdlibParameters');
      expect(tracker.accept('authorizationStateReady'), AuthStage.ready);
    });

    test('the first real decision is latched', () {
      final tracker = AuthStageTracker();
      expect(tracker.accept('authorizationStateReady'), AuthStage.ready);
      // TDLib reconnects and replays the pre-configuration state; that must not
      // undo a decision that already put the user inside the app.
      expect(
        tracker.accept('authorizationStateWaitTdlibParameters'),
        AuthStage.ready,
      );
      expect(tracker.accept('authorizationStateWaitPhoneNumber'),
          AuthStage.ready);
    });

    test('a revoked session reports the phone-number stage', () {
      final tracker = AuthStageTracker();
      expect(tracker.accept('authorizationStateWaitPhoneNumber'),
          AuthStage.waitPhoneNumber);
    });

    test('an unfinished handshake is reported with its exact stage', () {
      for (final raw in <String>[
        'authorizationStateWaitCode',
        'authorizationStateWaitPassword',
        'authorizationStateWaitOtherDeviceConfirmation',
      ]) {
        final tracker = AuthStageTracker();
        expect(tracker.accept(raw), isNot(isNull), reason: raw);
        expect(tracker.accept(raw), isNot(AuthStage.ready), reason: raw);
      }
    });

    test('an unknown state keeps waiting instead of guessing', () {
      final tracker = AuthStageTracker();
      expect(tracker.accept('authorizationStateSomethingNew'), isNull);
      expect(tracker.decision, isNull);
    });
  });

  group('outcome mapping', () {
    test('ready means the app can skip the sign-in screen entirely', () {
      expect(AuthStageTracker.outcomeFor(AuthStage.ready),
          RestoreOutcome.restored);
    });

    test('a live client with one step left is not "log in again"', () {
      // Told apart from needsLogin so the sign-in screen can continue on the
      // same client instead of opening a second one against the same database.
      for (final stage in <AuthStage>[
        AuthStage.waitCode,
        AuthStage.waitPassword,
        AuthStage.waitOtherDeviceConfirmation,
      ]) {
        expect(AuthStageTracker.outcomeFor(stage),
            RestoreOutcome.needsInteraction, reason: stage.name);
      }
    });

    test('everything else is a fresh sign-in', () {
      for (final stage in <AuthStage>[
        AuthStage.waitPhoneNumber,
        AuthStage.loggingOut,
        AuthStage.closed,
      ]) {
        expect(AuthStageTracker.outcomeFor(stage),
            RestoreOutcome.needsLogin, reason: stage.name);
      }
    });
  });

  group('planRestore', () {
    test('a device that never signed in cannot restore', () {
      expect(
        planRestore(apiId: null, apiHash: null, hasSessionFiles: false),
        RestoreRefusal.noCredentials,
      );
    });

    test('a non-numeric api_id is a corrupt keychain entry, not a first run',
        () {
      expect(
        planRestore(apiId: 'abc', apiHash: 'ff', hasSessionFiles: true),
        RestoreRefusal.malformedCredentials,
      );
    });

    test('credentials without a database mean sign in again', () {
      expect(
        planRestore(apiId: '1', apiHash: 'ff', hasSessionFiles: false),
        RestoreRefusal.noSessionFiles,
      );
    });

    test('valid credentials plus files is the only green path', () {
      expect(
        planRestore(apiId: '1', apiHash: 'ff', hasSessionFiles: true),
        isNull,
      );
    });
  });

  group('hasSessionFiles', () {
    late TestSandbox sandbox;

    setUp(() async => sandbox = await TestSandbox.create());
    tearDown(() async => sandbox.dispose());

    SessionRestore restore() => SessionRestore(
          layout: sandbox.layout,
          secrets: MemorySecretStore(),
          ops: sandbox.ops,
        );

    test('an empty database directory is not a session', () async {
      expect(await restore().hasSessionFiles(), isFalse);
    });

    test('any file under the database directory counts', () async {
      // Deliberately not tied to the name `td.binlog`: TDLib has renamed that
      // file across versions, and pinning the name would report "no session"
      // after an upgrade — the exact failure this whole file exists to avoid.
      await sandbox.writeBytes(
        p.join(sandbox.layout.tdlibDatabaseDir, 'td.binlog'),
        32,
      );
      expect(await restore().hasSessionFiles(), isTrue);
    });

    test('a side file also counts, so a renamed binlog still restores',
        () async {
      await sandbox.writeBytes(
        p.join(sandbox.layout.tdlibDatabaseDir, 'database_v2'),
        32,
      );
      expect(await restore().hasSessionFiles(), isTrue);
    });
  });

  group('restore refuses before opening a client', () {
    late TestSandbox sandbox;

    setUp(() async => sandbox = await TestSandbox.create());
    tearDown(() async => sandbox.dispose());

    test('a malformed stored key is reported, never replaced', () async {
      await sandbox.writeBytes(
        p.join(sandbox.layout.tdlibDatabaseDir, 'td.binlog'),
        32,
      );
      final secrets = MemorySecretStore(<String, String>{
        SessionRestore.apiIdKey: '1',
        SessionRestore.apiHashKey: 'ff',
        // Wrong shape for a 32-byte hex key. Regenerating it would make the
        // existing database unreadable, so restore must stop here.
        TdlibDatabaseKey.keyName: 'short',
      });

      final result = await SessionRestore(
        layout: sandbox.layout,
        secrets: secrets,
        ops: sandbox.ops,
      ).run();

      expect(result.outcome, RestoreOutcome.unavailable);
      expect(result.session, isNull);
      expect(await secrets.read(TdlibDatabaseKey.keyName), 'short');
    });
  });
}
