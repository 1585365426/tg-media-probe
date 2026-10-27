/// The on-device streaming badge.
///
/// Two things are asserted: it is **invisible** for a normal user (diagnostics
/// mode off, which is the default), and once armed it prints the numbers the
/// acceptance decision is made from — mode, downloaded / total, percent, the
/// HTTP status the proxy really answered, and the playhead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/ui/streaming_overlay.dart';

Widget _host(StreamingDiagnostics diagnostics) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: <Widget>[StreamingOverlay(diagnostics: diagnostics)],
        ),
      ),
    );

void main() {
  testWidgets('nothing renders while diagnostics mode is off', (tester) async {
    final diag = StreamingDiagnostics()..setEnabled(false);
    await tester.pumpWidget(_host(diag));

    expect(find.text('STREAM'), findsNothing);
    expect(find.text('STREAM?'), findsNothing);
    expect(find.text('FULL'), findsNothing);
  });

  testWidgets('an incomplete transfer shows STREAM and the real bytes',
      (tester) async {
    final diag = StreamingDiagnostics()
      ..setEnabled(true)
      ..beginPlay(fileId: 1001, streaming: true, totalBytes: 4 * 1024 * 1024);

    diag.noteRangeRequest(from: 0, to: 1023);
    diag.noteResponse(
      status: 206,
      from: 0,
      end: 1023,
      total: 4 * 1024 * 1024,
      length: 1024,
    );
    diag.updateTransfer(
      downloadedBytes: 1024 * 1024,
      totalBytes: 4 * 1024 * 1024,
      downloadOffset: 0,
      completed: false,
    );
    diag.updatePlayer(
      position: const Duration(seconds: 21),
      duration: const Duration(seconds: 600),
      isPlaying: true,
      isBuffering: false,
    );
    await tester.pumpWidget(_host(diag));

    expect(find.text('STREAM'), findsOneWidget);
    expect(find.text('1.00 MB / 4.00 MB'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
    expect(find.text('HTTP 206'), findsOneWidget);
    expect(find.text('PLAY 00:21'), findsOneWidget);
    expect(diag.verdict.code, 'STREAMING_CONFIRMED');
  });

  testWidgets('a complete file shows FULL, never a fake STREAM',
      (tester) async {
    final diag = StreamingDiagnostics()
      ..setEnabled(true)
      ..beginPlay(fileId: 1001, streaming: true, totalBytes: 2 * 1024 * 1024);

    diag.noteRangeRequest(from: 0, to: 1023);
    diag.noteResponse(
      status: 206,
      from: 0,
      end: 1023,
      total: 2 * 1024 * 1024,
      length: 1024,
    );
    diag.updateTransfer(
      downloadedBytes: 2 * 1024 * 1024,
      totalBytes: 2 * 1024 * 1024,
      downloadOffset: 0,
      completed: true,
    );
    diag.updatePlayer(
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 60),
      isPlaying: true,
      isBuffering: false,
    );
    await tester.pumpWidget(_host(diag));

    expect(find.text('FULL'), findsOneWidget);
    expect(find.text('2.00 MB / 2.00 MB'), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
    expect(diag.verdict.code, 'FULL_DOWNLOAD_BEFORE_PLAYBACK');
  });

  testWidgets('a fallback outranks the counters', (tester) async {
    final diag = StreamingDiagnostics()
      ..setEnabled(true)
      ..beginPlay(fileId: 1001, streaming: true, totalBytes: 2 * 1024 * 1024);

    diag.noteRangeRequest(from: 0, to: 1023);
    diag.noteResponse(
      status: 206,
      from: 0,
      end: 1023,
      total: 2 * 1024 * 1024,
      length: 1024,
    );
    diag.updateTransfer(
      downloadedBytes: 1024,
      totalBytes: 2 * 1024 * 1024,
      downloadOffset: 0,
      completed: false,
    );
    diag.updatePlayer(
      position: const Duration(seconds: 2),
      duration: const Duration(seconds: 60),
      isPlaying: true,
      isBuffering: false,
    );
    diag.noteFallback('代理等待超时');
    await tester.pumpWidget(_host(diag));

    expect(find.text('STREAM?'), findsOneWidget,
        reason: '回退后角标不再声称 STREAM');
    expect(diag.verdict.code, 'STREAMING_FALLBACK');
    expect(diag.fallback, isTrue);
  });
}
