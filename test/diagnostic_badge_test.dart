/// The diagnostic badge: real numbers only, and no throughput after the transfer
/// is over.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/download/download_state.dart';
import 'package:tg_media_probe/ui/diagnostic_badge.dart';

void main() {
  Future<void> pump(WidgetTester tester, DownloadState state) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: DiagnosticBadge(label: '#023', download: state),
      ),
    ));
  }

  testWidgets('downloading shows the number, the rate and the byte counts',
      (tester) async {
    await pump(
      tester,
      const DownloadState(
        phase: DownloadPhase.downloading,
        receivedBytes: 50 * 1024 * 1024,
        totalBytes: 500 * 1024 * 1024,
        bytesPerSecond: 5.2 * 1024 * 1024,
      ),
    );
    expect(find.text('#023'), findsOneWidget);
    expect(find.textContaining('MB/s'), findsOneWidget);
    expect(find.text('50.0 MB / 500 MB'), findsOneWidget);
  });

  testWidgets('ready shows LOCAL_FILE and the size, never a speed',
      (tester) async {
    await pump(
      tester,
      const DownloadState(
        phase: DownloadPhase.ready,
        receivedBytes: 500 * 1024 * 1024,
        totalBytes: 500 * 1024 * 1024,
        bytesPerSecond: 5.2 * 1024 * 1024,
        localPath: '/tmp/a.mp4',
      ),
    );
    expect(find.text('LOCAL_FILE'), findsOneWidget);
    expect(find.text('500 MB'), findsOneWidget);
    expect(find.textContaining('/s'), findsNothing);
  });

  testWidgets('a failure says so and prints no invented numbers',
      (tester) async {
    await pump(
      tester,
      const DownloadState(
        phase: DownloadPhase.failed,
        failure: DownloadFailure.network,
      ),
    );
    expect(find.text('DOWNLOAD ERROR'), findsOneWidget);
    expect(find.textContaining('/s'), findsNothing);
  });

  testWidgets('the badge never eats a tap meant for the player', (tester) async {
    await pump(tester, const DownloadState(phase: DownloadPhase.ready));
    expect(
      find.ancestor(
        of: find.text('#023'),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });
}
