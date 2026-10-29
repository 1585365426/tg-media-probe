/// The player page: the number on screen is the number of the video playing,
/// the badge shows real state and nothing else, and a failure offers a retry.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/app/app_preferences.dart';
import 'package:tg_media_probe/data/media_index.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/download/download_state.dart';
import 'package:tg_media_probe/playback/local_media_player.dart';
import 'package:tg_media_probe/security/tdlib_key.dart';
import 'package:tg_media_probe/ui/diagnostic_badge.dart';
import 'package:tg_media_probe/ui/video_player_page.dart';

import 'support/fake_player.dart';
import 'support/fake_preparer.dart';

void main() {
  List<NumberedMedia> items() => MediaIndex.fromRecords(<MediaRecord>[
        MediaRecord(
          chatId: 1,
          messageId: 1,
          fileId: 77,
          kind: MediaKind.video,
          sizeBytes: 4096,
          messageDateUnix: 1000,
          caption: '第一个视频',
        ),
        MediaRecord(
          chatId: 1,
          messageId: 2,
          fileId: 78,
          kind: MediaKind.video,
          sizeBytes: 4096,
          messageDateUnix: 2000,
          caption: '第二个视频',
        ),
      ]).items;

  Future<PreferencesController> prefs({bool badge = false}) async {
    final controller = PreferencesController(
        store: PreferencesStore(store: MemorySecretStore()));
    await controller.load();
    await controller.setDiagnosticBadge(badge);
    return controller;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required PreferencesController preferences,
    MediaPreparer? preparer,
    MediaPlayerFactory? factory,
    int initialIndex = 0,
    bool settle = true,
  }) async {
    // The player is a phone app: keep the test surface portrait, otherwise the
    // page legitimately hides its bottom sheet and the landscape badge wording
    // is what gets asserted.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: VideoPlayerPage(
        items: items(),
        initialIndex: initialIndex,
        downloads: preparer ?? FakePreparer(),
        preferences: preferences,
        channelTitle: '测试频道',
        playerFactory: factory ?? RecordingPlayerFactory().call,
      ),
    ));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('the bottom sheet shows the number and the caption',
      (tester) async {
    await pumpPage(tester, preferences: await prefs());
    expect(find.text('#001'), findsWidgets);
    expect(find.text('第一个视频'), findsOneWidget);
    expect(find.text('测试频道'), findsOneWidget);
  });

  testWidgets('the badge is absent when the setting is off', (tester) async {
    await pumpPage(tester, preferences: await prefs(badge: false));
    expect(find.text('LOCAL_FILE'), findsNothing);
  });

  testWidgets('the badge shows LOCAL_FILE and a real size when on',
      (tester) async {
    await pumpPage(tester, preferences: await prefs(badge: true));
    expect(find.text('LOCAL_FILE'), findsOneWidget);
    expect(find.text('4.00 KB'), findsOneWidget);
    // No fake throughput after the transfer is over.
    expect(find.textContaining('MB/s'), findsNothing);
  });

  testWidgets('a downloading badge shows the measured rate and byte counts',
      (tester) async {
    const transfer = DownloadState(
      phase: DownloadPhase.downloading,
      receivedBytes: 50 * 1024 * 1024,
      totalBytes: 500 * 1024 * 1024,
      bytesPerSecond: 5.2 * 1024 * 1024,
    );
    final preparer = FakePreparer(inFlight: transfer);
    await pumpPage(
      tester,
      preferences: await prefs(badge: true),
      preparer: preparer,
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('#001'), findsWidgets);
    final badge = find.byType(DiagnosticBadge);
    expect(badge, findsOneWidget);
    // The badge carries the measured rate; the preparing screen has its own
    // progress line, so match inside the badge only.
    expect(
      find.descendant(of: badge, matching: find.textContaining('MB/s')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badge, matching: find.textContaining('50.0 MB')),
      findsOneWidget,
    );
    expect(find.text('LOCAL_FILE'), findsNothing);

    preparer.release();
    await tester.pumpAndSettle();
  });

  testWidgets('starting on the second video shows #002', (tester) async {
    await pumpPage(tester, preferences: await prefs(), initialIndex: 1);
    expect(find.text('#002'), findsWidgets);
    expect(find.text('第二个视频'), findsOneWidget);
  });

  testWidgets('a download failure shows its own message and a retry',
      (tester) async {
    await pumpPage(
      tester,
      preferences: await prefs(),
      preparer: FakePreparer(failure: DownloadFailure.network),
    );
    expect(find.text('视频下载失败'), findsOneWidget);
    expect(find.text('网络连接失败，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('an out-of-space failure gets its own wording', (tester) async {
    await pumpPage(
      tester,
      preferences: await prefs(),
      preparer: FakePreparer(failure: DownloadFailure.insufficientSpace),
    );
    expect(find.text('磁盘空间不足'), findsOneWidget);
  });

  testWidgets('a player that cannot open shows the player error',
      (tester) async {
    await pumpPage(
      tester,
      preferences: await prefs(),
      factory: RecordingPlayerFactory(failOpen: true).call,
    );
    expect(find.text('视频无法播放'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('swiping up moves to the next video and the number follows',
      (tester) async {
    await pumpPage(tester, preferences: await prefs());
    await tester.drag(find.byType(PageView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('#002'), findsWidgets);
    expect(find.text('第二个视频'), findsOneWidget);
  });

  testWidgets('a single tap toggles the controls', (tester) async {
    await pumpPage(tester, preferences: await prefs());
    double? controlsOpacity() {
      final finder = find.byKey(const Key('player-controls'));
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<AnimatedOpacity>(finder).opacity;
    }

    expect(controlsOpacity(), 1);
    await tester.tapAt(const Offset(195, 300));
    // A tap only resolves once the double-tap window closed.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controlsOpacity(), 0);
    expect(find.text('第一个视频'), findsOneWidget);

    // Second tap brings them back.
    await tester.tapAt(const Offset(195, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controlsOpacity(), 1);
  });
}
