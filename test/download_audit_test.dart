// The download audit: caller, window, and the bytes each request moved.
//
// These cases are the ones a device report depends on. "152 MB appeared" is
// an observation; "caller=PLAYER offset=0 limit=159383552 grew=159383552" is
// an answer, and it has to survive a window move that resets TDLib's counter.
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/download_audit.dart';

void main() {
  group('record', () {
    test('every call carries the caller, the window and the priority', () {
      final audit = DownloadAudit()..tag(chatId: 7, messageId: 13604, generation: 3);
      final call = audit.record(
        fileId: 4565,
        caller: DownloadCaller.resourceLoader,
        offset: 0,
        limit: 16 * 1024 * 1024,
        priority: 16,
        cause: 'player=0',
      );

      expect(call.seq, 1);
      expect(call.caller.label, 'RESOURCE_LOADER');
      expect(call.chatId, 7);
      expect(call.messageId, 13604);
      expect(call.generation, 3);
      expect(call.windowEnd, 16 * 1024 * 1024 - 1);
      expect(call.unbounded, isFalse);
      expect(call.describe(), contains('caller=RESOURCE_LOADER'));
      expect(call.describe(), contains('limit=16777216'));
    });

    test('a whole-file request is marked as such, not as a sized window', () {
      final audit = DownloadAudit();
      final call = audit.record(
        fileId: 1,
        caller: DownloadCaller.fullDownload,
        offset: 0,
        limit: 0,
        priority: 32,
      );
      expect(call.unbounded, isTrue);
      expect(call.windowEnd, -1);
      expect(audit.anyUnbounded, isTrue);
      expect(audit.unboundedCalls.single.caller, DownloadCaller.fullDownload);
    });
  });

  group('observe', () {
    test('growth inside one window is attributed to the open call', () {
      final audit = DownloadAudit();
      final call = audit.record(
        fileId: 9,
        caller: DownloadCaller.player,
        offset: 0,
        limit: 16 * 1024 * 1024,
        priority: 32,
      );

      audit.observe(fileId: 9, offset: 0, downloaded: 1024);
      audit.observe(fileId: 9, offset: 0, downloaded: 8 * 1024 * 1024);
      audit.observe(fileId: 9, offset: 0, downloaded: 16 * 1024 * 1024);

      expect(call.grew, 16 * 1024 * 1024);
      expect(call.reached, 16 * 1024 * 1024);
      expect(audit.grewBy(DownloadCaller.player), 16 * 1024 * 1024);
    });

    test('a window move is not growth — the counter resets, the file does not',
        () {
      final audit = DownloadAudit();
      final head = audit.record(
        fileId: 9,
        caller: DownloadCaller.player,
        offset: 0,
        limit: 16 * 1024 * 1024,
        priority: 32,
      );
      audit.observe(fileId: 9, offset: 0, downloaded: 16 * 1024 * 1024);

      // A tail probe replaces the window. TDLib reports offset=1.4 GB with a
      // small downloaded_size; counting that as growth is how a seek was once
      // reported as a 1.4 GB download.
      final tail = audit.record(
        fileId: 9,
        caller: DownloadCaller.resourceLoader,
        offset: 1426653184,
        limit: 16 * 1024 * 1024,
        priority: 16,
      );
      audit.observe(fileId: 9, offset: 1426653184, downloaded: 4096);

      // The move itself adds nothing to the play's tally; only bytes that
      // really arrive count, and they count for the caller that asked.
      expect(head.grew, 16 * 1024 * 1024);
      expect(tail.grew, 4096);
      expect(audit.grewBy(DownloadCaller.player), 16 * 1024 * 1024);
    });

    test('growth after the move belongs to the new call', () {
      final audit = DownloadAudit();
      audit.record(
        fileId: 9,
        caller: DownloadCaller.player,
        offset: 0,
        limit: 16 * 1024 * 1024,
        priority: 32,
      );
      final tail = audit.record(
        fileId: 9,
        caller: DownloadCaller.resourceLoader,
        offset: 1024,
        limit: 16 * 1024 * 1024,
        priority: 16,
      );
      audit.observe(fileId: 9, offset: 1024, downloaded: 1024);
      audit.observe(fileId: 9, offset: 1024, downloaded: 8192);

      expect(tail.grew, 8192);
    });

    test('an observation for a file with no recorded call is ignored', () {
      final audit = DownloadAudit();
      audit.observe(fileId: 77, offset: 0, downloaded: 4096);
      expect(audit.count, 0);
      expect(audit.transferred(77), 4096);
    });
  });

  group('summary', () {
    test('names the largest request and the callers that went unbounded', () {
      final audit = DownloadAudit();
      audit.record(
        fileId: 9,
        caller: DownloadCaller.player,
        offset: 0,
        limit: 16 * 1024 * 1024,
        priority: 32,
      );
      audit.observe(fileId: 9, offset: 0, downloaded: 159383552 - 1);
      audit.observe(fileId: 9, offset: 0, downloaded: 159383552);
      audit.record(
        fileId: 10,
        caller: DownloadCaller.preload,
        offset: 0,
        limit: 4 * 1024 * 1024,
        priority: 2,
      );

      final lines = audit.summary().join('\n');
      expect(lines, contains('DOWNLOAD AUDIT calls=2 unbounded=0'));
      expect(lines, contains('growthByCaller=PLAYER:159383552'));
      expect(lines, contains('LARGEST caller=PLAYER file=9'));
      expect(lines, contains('grew=159383552'));
      expect(audit.largest?.caller, DownloadCaller.player);
    });

    test('a whole-file request is called out by name', () {
      final audit = DownloadAudit();
      audit.record(
        fileId: 1,
        caller: DownloadCaller.fullDownload,
        offset: 0,
        limit: 0,
        priority: 32,
      );
      final lines = audit.summary().join('\n');
      expect(lines, contains('UNBOUNDED=1 callers=FULL_DOWNLOAD'));
      expect(lines, contains('limit=WHOLE_FILE'));
    });

    test('an empty audit says so instead of printing nothing', () {
      expect(DownloadAudit().summary().single, contains('no calls'));
    });
  });

  test('reset starts a new play with a clean log', () {
    final audit = DownloadAudit();
    audit.record(
      fileId: 1,
      caller: DownloadCaller.player,
      offset: 0,
      limit: 1024,
      priority: 32,
    );
    audit.observe(fileId: 1, offset: 0, downloaded: 1024);
    audit.reset();

    expect(audit.count, 0);
    expect(audit.largest, isNull);
    expect(audit.grewBy(DownloadCaller.player), 0);
    expect(audit.transferred(1), 0);
    // The sequence number restarts, so a report's `#1` is always the first
    // request of the play it describes.
    expect(
      audit
          .record(
            fileId: 1,
            caller: DownloadCaller.player,
            offset: 0,
            limit: 1024,
            priority: 32,
          )
          .seq,
      1,
    );
  });
}
