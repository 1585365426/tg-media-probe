import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/session_state.dart';

Map<String, Object?> stateJson(String type, [Map<String, Object?> extra = const {}]) {
  return <String, Object?>{'@type': type, ...extra};
}

void main() {
  group('SessionStatus.fromJson', () {
    test('maps every authorization state this build knows', () {
      const cases = <String, LoginPhase>{
        'authorizationStateWaitTdlibParameters': LoginPhase.openingDatabase,
        'authorizationStateWaitPhoneNumber': LoginPhase.waitingPhoneNumber,
        'authorizationStateWaitCode': LoginPhase.waitingCode,
        'authorizationStateWaitPassword': LoginPhase.waitingPassword,
        'authorizationStateWaitEmailAddress': LoginPhase.waitingEmailAddress,
        'authorizationStateWaitEmailCode': LoginPhase.waitingEmailCode,
        'authorizationStateWaitRegistration': LoginPhase.waitingRegistration,
        'authorizationStateWaitOtherDeviceConfirmation':
            LoginPhase.waitingOtherDevice,
        'authorizationStateWaitPremiumPurchase':
            LoginPhase.waitingPremiumPurchase,
        'authorizationStateReady': LoginPhase.ready,
        'authorizationStateLoggingOut': LoginPhase.loggingOut,
        'authorizationStateClosed': LoginPhase.closed,
        'authorizationStateSomethingNew': LoginPhase.unknown,
      };
      cases.forEach((type, expected) {
        expect(SessionStatus.fromJson(stateJson(type)).phase, expected,
            reason: type);
      });
    });

    test('a missing @type is unknown, not ready', () {
      expect(SessionStatus.fromJson(const <String, Object?>{}).phase,
          LoginPhase.unknown);
    });

    test('only authorizationStateReady counts as authorized', () {
      for (final phase in LoginPhase.values) {
        final status = SessionStatus(phase: phase);
        expect(status.isAuthorized, phase == LoginPhase.ready,
            reason: phase.name);
      }
    });

    test('opening the database is not a logout', () {
      final status = SessionStatus.fromJson(
        stateJson('authorizationStateWaitTdlibParameters'),
      );
      expect(status.isAuthorized, isFalse);
      expect(status.awaitsUserInput, isFalse);
      expect(status.isDecidable, isFalse);
    });

    test('the 2FA hint is surfaced when Telegram sends one', () {
      final status = SessionStatus.fromJson(stateJson(
        'authorizationStateWaitPassword',
        <String, Object?>{
          'password_hint': '常用词',
          'has_recovery_email_address': true,
        },
      ));
      expect(status.phase, LoginPhase.waitingPassword);
      expect(status.passwordHint, '常用词');
      expect(status.hasRecoveryEmail, isTrue);
    });

    test('an empty hint is treated as absent', () {
      final status = SessionStatus.fromJson(stateJson(
        'authorizationStateWaitPassword',
        <String, Object?>{'password_hint': ''},
      ));
      expect(status.passwordHint, isNull);
    });

    test('a non-boolean recovery flag does not throw', () {
      final status = SessionStatus.fromJson(stateJson(
        'authorizationStateWaitPassword',
        <String, Object?>{'has_recovery_email_address': 'yes'},
      ));
      expect(status.hasRecoveryEmail, isFalse);
    });

    test('the raw type is preserved for diagnostics', () {
      final status = SessionStatus.fromJson(
        stateJson('authorizationStateWaitCode'),
      );
      expect(status.rawType, 'authorizationStateWaitCode');
    });
  });

  group('needsUserActionFor', () {
    test('input-taking phases need the login screen', () {
      for (final phase in <LoginPhase>[
        LoginPhase.waitingPhoneNumber,
        LoginPhase.waitingCode,
        LoginPhase.waitingPassword,
        LoginPhase.waitingEmailAddress,
        LoginPhase.waitingEmailCode,
        LoginPhase.waitingRegistration,
        LoginPhase.waitingOtherDevice,
        LoginPhase.waitingPremiumPurchase,
      ]) {
        expect(needsUserActionFor(phase), isTrue, reason: phase.name);
      }
    });

    test('non-input phases do not', () {
      for (final phase in <LoginPhase>[
        LoginPhase.openingDatabase,
        LoginPhase.ready,
        LoginPhase.loggingOut,
        LoginPhase.closed,
        LoginPhase.unknown,
      ]) {
        expect(needsUserActionFor(phase), isFalse, reason: phase.name);
      }
    });

    test('every phase has a label', () {
      for (final phase in LoginPhase.values) {
        expect(describeLoginPhase(phase).trim(), isNotEmpty,
            reason: phase.name);
      }
    });

    test('labels do not claim success for a non-ready phase', () {
      expect(describeLoginPhase(LoginPhase.ready), '已登录');
      for (final phase in LoginPhase.values) {
        if (phase == LoginPhase.ready) continue;
        expect(describeLoginPhase(phase).contains('已登录'), isFalse,
            reason: phase.name);
      }
    });
  });

  group('SessionBootPlanner', () {
    SessionBootPlan plan({
      bool keyPresent = true,
      bool keyValid = true,
      bool databaseExists = true,
      LoginPhase phase = LoginPhase.openingDatabase,
    }) {
      return SessionBootPlanner.plan(
        keyPresent: keyPresent,
        keyValid: keyValid,
        databaseExists: databaseExists,
        phase: phase,
      );
    }

    test('first launch with nothing on disk routes to login', () {
      final result = plan(keyPresent: false, databaseExists: false);
      expect(result.action, SessionBootAction.routeToLogin);
      expect(result.needsUserConfirmation, isFalse);
      expect(result.reason, contains('首次'));
    });

    test('an authorized session resumes without asking anything', () {
      final result = plan(phase: LoginPhase.ready);
      expect(result.action, SessionBootAction.resumeSilently);
      expect(result.reason, contains('authorizationStateReady'));
    });

    test('a database that is still opening does not route to login', () {
      // The regression this file exists for: WaitTdlibParameters arrives before
      // the database is open, so treating it as a logout asks for a phone
      // number even though the session is intact.
      final result = plan(phase: LoginPhase.openingDatabase);
      expect(result.action, SessionBootAction.resumeSilently);
      expect(result.needsUserConfirmation, isFalse);
    });

    test('an input-taking phase routes to login with the real reason', () {
      final result = plan(phase: LoginPhase.waitingCode);
      expect(result.action, SessionBootAction.routeToLogin);
      expect(result.reason, contains('验证码'));
    });

    test('waiting for another device explains itself', () {
      final result = plan(phase: LoginPhase.waitingOtherDevice);
      expect(result.action, SessionBootAction.routeToLogin);
      expect(result.reason, contains('其他设备'));
    });

    test('a closed session routes to login', () {
      expect(plan(phase: LoginPhase.closed).action,
          SessionBootAction.routeToLogin);
    });

    test('a session being logged out routes to login', () {
      expect(plan(phase: LoginPhase.loggingOut).action,
          SessionBootAction.routeToLogin);
    });

    test('an unknown phase waits instead of prompting', () {
      final result = plan(phase: LoginPhase.unknown);
      expect(result.action, SessionBootAction.resumeSilently);
      expect(result.reason, contains('未知'));
    });

    test('a malformed key blocks and needs a decision', () {
      final result = plan(keyValid: false);
      expect(result.action, SessionBootAction.blockedNeedsDecision);
      expect(result.needsUserConfirmation, isTrue);
      expect(result.reason, contains('密钥'));
    });

    test('a database without a key blocks instead of overwriting', () {
      final result = plan(keyPresent: false, databaseExists: true);
      expect(result.action, SessionBootAction.blockedNeedsDecision);
      expect(result.needsUserConfirmation, isTrue);
      expect(result.reason, contains('缺少对应的密钥'));
    });

    test('a blocked plan never silently regenerates the key', () {
      // Stated as a test so a future "just make it work" patch fails here: the
      // only blocked outcomes are the two that require the user to choose.
      final outcomes = <SessionBootPlan>[
        plan(keyValid: false),
        plan(keyPresent: false, databaseExists: true),
      ];
      for (final outcome in outcomes) {
        expect(outcome.action, isNot(SessionBootAction.resumeSilently));
        expect(outcome.action, isNot(SessionBootAction.routeToLogin));
        expect(outcome.needsUserConfirmation, isTrue);
      }
    });

    test('every plan carries a reason', () {
      for (final phase in LoginPhase.values) {
        for (final keyPresent in <bool>[true, false]) {
          for (final databaseExists in <bool>[true, false]) {
            final result = plan(
              keyPresent: keyPresent,
              databaseExists: databaseExists,
              phase: phase,
            );
            expect(result.reason.trim(), isNotEmpty,
                reason: '$phase key=$keyPresent db=$databaseExists');
          }
        }
      }
    });
  });

  group('ReloginConsent', () {
    test('the prompt says the cloud copy is untouched', () {
      const consent = ReloginConsent.prompt;
      expect(consent.confirmed, isFalse);
      expect(consent.discardsLocalDatabase, isTrue);
      expect(consent.keepsCloudData, isTrue);
      expect(consent.summary, contains('不会被删除'));
    });
  });
}
