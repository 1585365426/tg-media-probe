import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/td_error_kind.dart';

/// Every case here is a real shape this app produces. The point of the file is
/// that "出错了" stops being the only thing a screen can say.
void main() {
  group('classifyTdError', () {
    test('no code and no message means no failure', () {
      expect(classifyTdError(), RequestFailure.none);
    });

    test('403 is permissionDenied regardless of wording', () {
      expect(classifyTdError(code: 403, message: 'Forbidden'),
          RequestFailure.permissionDenied);
    });

    test('CHAT_FORBIDDEN is permissionDenied even under code 400', () {
      // TDLib sends a lot of permission failures as 400 with a specific text.
      expect(
        classifyTdError(code: 400, message: 'CHAT_FORBIDDEN'),
        RequestFailure.permissionDenied,
      );
    });

    test('CHANNEL_PRIVATE is permissionDenied', () {
      expect(
        classifyTdError(code: 400, message: 'CHANNEL_PRIVATE'),
        RequestFailure.permissionDenied,
      );
    });

    test('401 is sessionExpired', () {
      expect(classifyTdError(code: 401, message: 'Unauthorized'),
          RequestFailure.sessionExpired);
    });

    test('AUTH_KEY_UNREGISTERED is sessionExpired even under code 400', () {
      expect(
        classifyTdError(code: 400, message: 'AUTH_KEY_UNREGISTERED'),
        RequestFailure.sessionExpired,
      );
    });

    test('420 with FLOOD_WAIT is rateLimited, not a generic error', () {
      expect(
        classifyTdError(code: 420, message: 'FLOOD_WAIT_23'),
        RequestFailure.rateLimited,
      );
    });

    test('429 is rateLimited', () {
      expect(classifyTdError(code: 429, message: 'Too Many Requests'),
          RequestFailure.rateLimited);
    });

    test('400 with no known fragment stays generic', () {
      expect(classifyTdError(code: 400, message: 'CHAT_NOT_FOUND'),
          RequestFailure.generic);
    });

    test('a null code with a known fragment still classifies', () {
      expect(classifyTdError(message: 'FLOOD_WAIT_5'),
          RequestFailure.rateLimited);
    });

    test('the session check runs before the permission check', () {
      // A message that mentions both must not be reported as a permission
      // problem, because the fix (sign in again) is different.
      expect(
        classifyTdError(code: 400, message: 'AUTH_KEY_UNREGISTERED CHAT_FORBIDDEN'),
        RequestFailure.sessionExpired,
      );
    });
  });

  group('classifyFailure', () {
    test('a raw TDLib response map is classified by its code', () {
      expect(
        classifyFailure(<String, Object?>{
          '@type': 'error',
          'code': 403,
          'message': 'CHANNEL_PRIVATE',
        }),
        RequestFailure.permissionDenied,
      );
    });

    test('a map with a stringified code still works', () {
      expect(
        classifyFailure(<String, Object?>{'code': '401', 'message': ''}),
        RequestFailure.sessionExpired,
      );
    });

    test('a TimeoutException is offline', () {
      expect(classifyFailure(TimeoutException('no answer')),
          RequestFailure.offline);
    });

    test('a SocketException is offline', () {
      expect(
        classifyFailure(const SocketException('Connection refused')),
        RequestFailure.offline,
      );
    });

    test('an exception whose text carries a TDLib code is classified', () {
      expect(
        classifyFailure(Exception('TDLib error 403: CHAT_FORBIDDEN')),
        RequestFailure.permissionDenied,
      );
      expect(
        classifyFailure(Exception('TDLib error 401: AUTH_KEY_UNREGISTERED')),
        RequestFailure.sessionExpired,
      );
    });

    test('an unknown exception falls back to generic, never to none', () {
      expect(classifyFailure(Exception('something odd')),
          RequestFailure.generic);
    });
  });

  group('wording and retry policy', () {
    test('every failure has a title and a hint', () {
      for (final failure in RequestFailure.values) {
        if (failure == RequestFailure.none) {
          expect(failureTitle(failure), isEmpty);
          expect(failureHint(failure), isEmpty);
          continue;
        }
        expect(failureTitle(failure), isNotEmpty, reason: '$failure');
        expect(failureHint(failure), isNotEmpty, reason: '$failure');
      }
    });

    test('permission and expired session are not retryable', () {
      expect(isRetryable(RequestFailure.permissionDenied), isFalse);
      expect(isRetryable(RequestFailure.sessionExpired), isFalse);
    });

    test('offline, rate limited and generic are retryable', () {
      expect(isRetryable(RequestFailure.offline), isTrue);
      expect(isRetryable(RequestFailure.rateLimited), isTrue);
      expect(isRetryable(RequestFailure.generic), isTrue);
    });

    test('the expired-session hint tells the user to sign in again', () {
      expect(failureHint(RequestFailure.sessionExpired), contains('登录'));
    });

    test('the rate-limit hint warns that retrying makes it worse', () {
      expect(failureHint(RequestFailure.rateLimited), contains('等待'));
    });
  });
}
