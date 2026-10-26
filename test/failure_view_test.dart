import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/td_error_kind.dart';
import 'package:tg_media_probe/ui/status_view.dart';

/// Widget-level proof that a classified failure reaches the screen as the words
/// and buttons it deserves. The classification tests prove the mapping; these
/// prove the rendering does not quietly fall back to a generic error box.
void main() {
  Future<void> pumpView(
    WidgetTester tester,
    Widget child, {
    bool wrapInScaffold = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: wrapInScaffold ? Scaffold(body: child) : child,
    ));
    await tester.pump();
  }

  group('StatusView states', () {
    testWidgets('loading shows a spinner and the title', (tester) async {
      await pumpView(tester, const StatusView.loading(title: '正在准备视频'));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在准备视频'), findsOneWidget);
      // A loading state must never offer a retry button.
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('empty shows the title, the hint and the action',
        (tester) async {
      var tapped = 0;
      await pumpView(
        tester,
        StatusView.empty(
          title: '该频道暂无视频',
          message: '同步完成后这里会出现可播放的视频。',
          actionLabel: '刷新',
          onAction: () => tapped++,
        ),
      );

      expect(find.text('该频道暂无视频'), findsOneWidget);
      expect(find.text('同步完成后这里会出现可播放的视频。'), findsOneWidget);
      await tester.tap(find.text('刷新'));
      expect(tapped, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a generic error shows the retry button and calls back',
        (tester) async {
      var retried = 0;
      await pumpView(
        tester,
        FailureView(
          failure: RequestFailure.generic,
          detail: 'Exception: boom',
          onRetry: () => retried++,
        ),
      );

      expect(find.text('读取失败'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, 1);
    });
  });

  group('FailureView wording per failure', () {
    testWidgets('permission denied explains membership, no retry',
        (tester) async {
      await pumpView(
        tester,
        const FailureView(failure: RequestFailure.permissionDenied),
      );

      expect(find.text('没有权限读取这个内容'), findsOneWidget);
      expect(find.textContaining('不是该频道的成员'), findsOneWidget);
      // Retrying a permission error can only fail again.
      expect(find.text('重试'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('an expired session points at signing in again, no retry',
        (tester) async {
      await pumpView(
        tester,
        const FailureView(failure: RequestFailure.sessionExpired),
      );

      expect(find.text('登录已失效'), findsOneWidget);
      expect(find.textContaining('重新登录'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('offline and rate limited keep the retry button',
        (tester) async {
      for (final failure in <RequestFailure>[
        RequestFailure.offline,
        RequestFailure.rateLimited,
      ]) {
        await pumpView(tester, FailureView(failure: failure, onRetry: () {}));
        expect(find.text('重试'), findsOneWidget, reason: '$failure');
      }
    });

    testWidgets('the rate-limit copy warns that retrying hurts',
        (tester) async {
      await pumpView(
        tester,
        const FailureView(failure: RequestFailure.rateLimited),
      );

      expect(find.text('请求过于频繁'), findsOneWidget);
      expect(find.textContaining('等待'), findsOneWidget);
    });

    testWidgets('two failures do not render the same title', (tester) async {
      // A regression guard: if the wording ever collapses to one string, the
      // six-state walkthrough is a lie.
      final titles = <String>{};
      for (final failure in <RequestFailure>[
        RequestFailure.permissionDenied,
        RequestFailure.sessionExpired,
        RequestFailure.rateLimited,
        RequestFailure.offline,
        RequestFailure.generic,
      ]) {
        await pumpView(tester, FailureView(failure: failure, onRetry: () {}));
        final text = tester.widget<Text>(find.text(failureTitle(failure)));
        titles.add(text.data!);
      }
      expect(titles.length, 5);
    });
  });

  group('a retry callback that is null still renders', () {
    testWidgets('a retryable failure without a callback shows no button',
        (tester) async {
      await pumpView(
        tester,
        const FailureView(failure: RequestFailure.offline),
      );

      // isRetryable(offline) is true, but with no callback there is nothing to
      // call — the button must not appear as a dead control.
      expect(find.text('重试'), findsNothing);
      expect(find.text('网络不可用'), findsOneWidget);
    });
  });
}
