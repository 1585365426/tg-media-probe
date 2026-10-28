/// The playback source decision, tested as a function.
///
/// Every case here comes from the 720 MB device report or from the six tests
/// the rewrite was asked for. The numbers are the report's own:
///
/// ```
/// record file=13604 msg=636485632
/// record size=756031238 B
/// tdlib total=756031238 B match=YES
/// downloaded=756031238 B (100.0%)  completed=true
/// -> STREAMING_FALLBACK / V1 proxy / 206 declared 754966576 / wrote 20496682
/// ```
///
/// The file claimed complete, the disk did not back the claim, and the
/// transport chosen was the one that cannot survive it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/source_decision.dart';
import 'package:tg_media_probe/td/td_requests.dart';

/// The report's video, with the disk size left to the caller: that is the
/// variable the old code never looked at.
SourceFacts video({int disk = 756031238, bool claimed = true, bool exists = true}) {
  return SourceFacts(
    fileId: 13604,
    claimedComplete: claimed,
    downloadedBytes: claimed ? 756031238 : 20 * 1024 * 1024,
    downloadOffset: 0,
    recordSize: 756031238,
    expectedBytes: 756031238,
    path: exists ? '/pool/13604' : '',
    pathExists: exists,
    diskSize: exists ? disk : -1,
  );
}

PlaybackDecision decide(
  SourceFacts facts, {
  bool streaming = true,
  bool force = false,
  bool v2 = true,
}) {
  return decidePlaybackSource(
    facts,
    streamingEnabled: streaming,
    forceStreaming: force,
    v2Supported: v2,
  );
}

void main() {
  group('PlaybackSourceDecision', () {
    // Test 1 from the spec: 756 MB, downloaded = total, on disk.
    test('a complete file measured on disk is LOCAL_FILE', () {
      final d = decide(video());
      expect(d.source, PlaybackSourceKind.localFile);
      expect(d.code, 'LOCAL_FILE');
      expect(d.reason, 'complete_file_on_disk');
      expect(d.isStreaming, isFalse);
      expect(d.needsRedownload, isFalse);
    });

    test('a complete file stays LOCAL_FILE even with streaming switched off',
        () {
      expect(decide(video(), streaming: false).source, PlaybackSourceKind.localFile);
    });

    // Test 2 from the spec: 20 MB of 756 MB, still downloading.
    test('a growing file is RESOURCE_LOADER, never LOCAL_FILE', () {
      final d = decide(video(disk: 20 * 1024 * 1024, claimed: false));
      expect(d.source, PlaybackSourceKind.resourceLoader);
      expect(d.code, 'RESOURCE_LOADER');
      expect(d.reason, 'partial_file');
      expect(d.isStreaming, isTrue);
      // A genuinely growing file must not be re-downloaded: TDLib is already
      // sending the missing bytes.
      expect(d.needsRedownload, isFalse);
    });

    // The report's exact state: TDLib says 100%, the disk says 20.5 MB.
    test('claimed complete but short on disk asks for a re-download', () {
      final d = decide(video(disk: 20496682));
      expect(d.source, PlaybackSourceKind.resourceLoader);
      expect(d.reason, 'short_of_claimed_size');
      expect(d.needsRedownload, isTrue);
      expect(d.facts.missingBytes, 756031238 - 20496682);
      expect(d.facts.isPlayableFromDisk, isFalse);
    });

    test('claimed complete with no file at all also asks for a re-download',
        () {
      final d = decide(video(exists: false));
      expect(d.source, PlaybackSourceKind.resourceLoader);
      expect(d.needsRedownload, isTrue);
    });

    test('no TDLib record is STREAMING_NOT_STARTED, not a download', () {
      final d = decide(const SourceFacts.missing(42));
      // The device defect: this used to be fullDownload, and the controller
      // answered it with downloadFile(limit: 0) for a 24 MB video whose tile
      // id had gone stale.
      expect(d.source, PlaybackSourceKind.streamingNotStarted);
      expect(d.code, 'STREAMING_NOT_STARTED');
      expect(d.reason, 'no_file_record');
    });

    test('an unknown size is STREAMING_NOT_STARTED, not a download', () {
      const facts = SourceFacts(
        fileId: 7,
        expectedBytes: 0,
        path: '/pool/7',
        pathExists: true,
        diskSize: 100,
      );
      expect(decide(facts).reason, 'unknown_size');
      expect(decide(facts).source, PlaybackSourceKind.streamingNotStarted);
    });

    test('without a V2 bridge a growing file falls to HTTP_PROXY', () {
      final d = decide(video(disk: 1024, claimed: false), v2: false);
      expect(d.source, PlaybackSourceKind.httpProxy);
      expect(d.code, 'HTTP_PROXY');
    });

    test('the acceptance force switch can stream a complete file, and says so',
        () {
      final d = decide(video(), force: true);
      expect(d.source, PlaybackSourceKind.resourceLoader);
      expect(d.forced, isTrue);
      expect(d.reason, 'forced_over_complete_file');
    });

    test('force never invents a stream out of an unknown size', () {
      const facts = SourceFacts(fileId: 7, expectedBytes: 0);
      expect(decide(facts, force: true).source,
          PlaybackSourceKind.streamingNotStarted);
    });

    test('a file one byte short is not complete', () {
      final d = decide(video(disk: 756031237));
      expect(d.facts.isPlayableFromDisk, isFalse);
      expect(d.needsRedownload, isTrue);
    });

    test('one byte more than expected is complete', () {
      final d = decide(video(disk: 756031238 + 1));
      expect(d.source, PlaybackSourceKind.localFile);
    });
  });

  // Test 3 from the spec: V2 failed, then the download finished.
  group('after a transport failed', () {
    test('a file that finished during the failure is LOCAL_FILE, not V1', () {
      final d = decideAfterTransportFailure(
        video(),
        failed: PlaybackSourceKind.resourceLoader,
        v2Supported: true,
      );
      expect(d.source, PlaybackSourceKind.localFile);
      expect(d.reason, 'completed_while_stream_was_failing');
      // The device bug in one assertion: the old code returned V1 here.
      expect(d.source, isNot(PlaybackSourceKind.httpProxy));
    });

    test('a file still short of its size goes to V1', () {
      final d = decideAfterTransportFailure(
        video(disk: 20 * 1024 * 1024, claimed: false),
        failed: PlaybackSourceKind.resourceLoader,
        v2Supported: true,
      );
      expect(d.source, PlaybackSourceKind.httpProxy);
      expect(d.reason, 'v2_failed_try_v1');
    });

    test('V1 failing on a short file stops the play', () {
      final d = decideAfterTransportFailure(
        video(disk: 20 * 1024 * 1024, claimed: false),
        failed: PlaybackSourceKind.httpProxy,
        v2Supported: true,
      );
      // The device report in one assertion: this used to be fullDownload, and
      // a 4.9 MB proxy stall on a 622 MB video became 593 MB downloaded.
      expect(d.source, PlaybackSourceKind.stop);
      expect(d.reason, 'v1_failed_stop');
      expect(d.code, 'STOP');
    });

    test('a local file the decoder refused is the end of the chain', () {
      final d = decideAfterTransportFailure(
        video(),
        failed: PlaybackSourceKind.localFile,
        v2Supported: true,
      );
      expect(d.source, PlaybackSourceKind.stop);
      expect(d.reason, 'local_file_refused_by_decoder');
    });

    test('a file that vanished during the failure does not become a stream',
        () {
      final d = decideAfterTransportFailure(
        video(exists: false, disk: 0),
        failed: PlaybackSourceKind.resourceLoader,
        v2Supported: true,
      );
      expect(d.source, PlaybackSourceKind.httpProxy);
      expect(d.needsRedownload, isTrue);
    });
  });

  group('SourceFacts', () {
    test('diskCoversExpected needs a measured size, not a claim', () {
      const claimed = SourceFacts(
        fileId: 1,
        claimedComplete: true,
        expectedBytes: 1000,
        path: '/pool/1',
        pathExists: true,
        diskSize: 400,
      );
      expect(claimed.claimedComplete, isTrue);
      expect(claimed.diskCoversExpected, isFalse);
    });

    test('an unreadable size is not a complete file', () {
      const unknown = SourceFacts(
        fileId: 1,
        claimedComplete: true,
        expectedBytes: 1000,
        path: '/pool/1',
        pathExists: true,
        diskSize: -1,
      );
      expect(unknown.diskCoversExpected, isFalse);
      expect(unknown.isPlayableFromDisk, isFalse);
    });

    test('summary names both numbers so a report can be read', () {
      final facts = video(disk: 20496682);
      expect(facts.summary, contains('expected=756031238'));
      expect(facts.summary, contains('disk=20496682'));
    });
  });

  // Test 4 from the spec: ACTIVE_PLAYBACK > PRELOAD, expressed where it is
  // actually enforced — the TDLib request. TDLib serves one priority queue
  // per file, so these three numbers are the whole ordering guarantee.
  group('transfer priority', () {
    test('a play outranks a blocked range, which outranks a preload', () {
      final play = downloadFile(fileId: 1);
      final range = downloadFile(fileId: 1, offset: 0, limit: 1024, priority: 16);
      final preload = downloadFile(fileId: 1, priority: 2);

      expect(play['priority'], 32);
      expect(range['priority'], 16);
      expect(preload['priority'], 2);
      expect(
        (play['priority']! as int) > (range['priority']! as int),
        isTrue,
        reason: 'ACTIVE 必须高于为播放服务的窗口请求',
      );
      expect(
        (range['priority']! as int) > (preload['priority']! as int),
        isTrue,
        reason: 'PRELOAD 永远排在播放之后',
      );
    });

    test('a preload carries no limit, so it can never shrink a play window', () {
      expect(downloadFile(fileId: 1, priority: 2)['limit'], 0);
    });
  });
}
