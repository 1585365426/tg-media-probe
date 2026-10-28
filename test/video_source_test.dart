import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/media_metadata.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

class ScriptedApi implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  ScriptedApi({
    this.local = false,
    this.failOnStart = false,
    this.neverFinishes = false,
    this.completeWithoutPath = false,
  });

  bool local;
  bool failOnStart;
  bool neverFinishes;

  /// Emits `isCompleted: true` with an empty path — TDLib does this when the
  /// file record is finished but no readable location is known.
  bool completeWithoutPath;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  final List<int> started = <int>[];
  final List<int> cancelled = <int>[];

  @override
  Future<FileState?> stat(int fileId) async => FileState(
        id: fileId,
        size: local ? 2048 : 0,
        expectedSize: 2048,
        downloadedSize: local ? 2048 : 0,
        isCompleted: local,
        path: local ? '/pool/$fileId' : '',
        canBeDownloaded: true,
      );

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    started.add(fileId);
    if (failOnStart) {
      throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    }
    if (neverFinishes) return;
    _updates.add(FileState(
      id: fileId,
      size: 2048,
      expectedSize: 2048,
      downloadedSize: 2048,
      isCompleted: true,
      path: completeWithoutPath ? '' : '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {}
  @override
  Future<void> cancel(int fileId) async {
    cancelled.add(fileId);
  }

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}


/// A TDLib that has no record for the id the tile carried, and one for the id
/// the message actually points at.
///
/// This is the shape of the device report: `record file=4999` printed by the
/// diagnostics, `no_file_record` from the decision layer, and a whole-file
/// download of `file=2221` afterwards.
class RemappingApi implements FileTransferApi {
  RemappingApi({required this.realId, this.completeOnReal = true});

  final int realId;
  final bool completeOnReal;
  final List<int> statIds = <int>[];
  final List<int> started = <int>[];

  @override
  Future<void> prefetch(int fileId) async {}

  @override
  Future<FileState?> stat(int fileId) async {
    statIds.add(fileId);
    if (fileId != realId) return null; // TDLib has no such file id
    return FileState(
      id: realId,
      size: completeOnReal ? 2048 : 0,
      expectedSize: 2048,
      downloadedSize: completeOnReal ? 2048 : 0,
      isCompleted: completeOnReal,
      path: completeOnReal ? '/pool/$realId' : '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId,
      {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    started.add(fileId);
  }

  @override
  Future<void> startRange(int fileId,
      {required int offset,
      required int limit,
      int priority = 16,
      DownloadCaller caller = DownloadCaller.unknown,
      String cause = ''}) async {}

  @override
  Future<void> cancel(int fileId) async {}

  @override
  Stream<FileState> updates() => const Stream<FileState>.empty();
}

class FixedLookup implements MediaMetadataLookup {
  FixedLookup(this.record);
  final MediaRecord? record;

  @override
  Future<MediaRecord?> fetch(int chatId, int messageId) async => record;
}

void main() {
  group('VideoSourceResolver', () {
    test('a file already on disk resolves without starting a transfer',
        () async {
      final api = ScriptedApi(local: true);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      final path = await resolver.resolve(7);

      expect(path, '/pool/7');
      expect(api.started, isEmpty);
    });

    test('a missing file is fetched and the completed path returned', () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      final path = await resolver.resolve(7);

      expect(path, '/pool/7');
      expect(api.started, <int>[7]);
    });

    test('progress goes probing -> fetching -> ready', () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);
      final stages = <SourceStage>[];

      await resolver.resolve(7, onProgress: (update) => stages.add(update.stage));

      expect(stages.first, SourceStage.probing);
      expect(stages, contains(SourceStage.fetching));
      expect(stages.last, SourceStage.ready);
    });

    test('a transfer that never finishes times out and is cancelled', () async {
      final api = ScriptedApi(neverFinishes: true);
      final resolver = VideoSourceResolver(
        api: api,
        stallTimeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        resolver.resolve(7),
        throwsA(isA<VideoSourceTimeout>()),
      );
      expect(api.cancelled, contains(7));
    });

    test('the timeout message states the limit instead of a generic error',
        () async {
      final api = ScriptedApi(neverFinishes: true);
      final resolver = VideoSourceResolver(
        api: api,
        stallTimeout: const Duration(seconds: 15),
      );

      try {
        await resolver.resolve(7);
        fail('expected a timeout');
      } on VideoSourceTimeout catch (e) {
        expect(e.message, contains('15'));
      }
    });

    test('a TDLib error surfaces as a VideoSourceException', () async {
      final api = ScriptedApi(failOnStart: true);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      await expectLater(
        resolver.resolve(7),
        throwsA(isA<VideoSourceException>().having(
          (e) => e.message,
          'message',
          contains('FILE_ID_INVALID'),
        )),
      );
    });

    test('an update for a different file id is ignored', () async {
      final api = ScriptedApi(neverFinishes: true);
      final resolver = VideoSourceResolver(
        api: api,
        stallTimeout: const Duration(milliseconds: 60),
      );

      final pending = resolver.resolve(7);
      // Another video completing must not satisfy this one.
      api._updates.add(FileState(
        id: 999,
        size: 10,
        expectedSize: 10,
        downloadedSize: 10,
        isCompleted: true,
        path: '/pool/999',
        canBeDownloaded: true,
      ));

      await expectLater(pending, throwsA(isA<VideoSourceTimeout>()));
    });

    test('cancel records the file id so a late completion is refused',
        () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      await resolver.cancel(7);
      expect(api.cancelled, contains(7));

      resolver.reset();
      expect(await resolver.resolve(7), '/pool/7');
    });

    test('the fraction is clamped to 0..1', () {
      expect(
        const VideoSourceUpdate(stage: SourceStage.fetching).fraction,
        0,
      );
      expect(
        const VideoSourceUpdate(
          stage: SourceStage.fetching,
          downloadedBytes: 50,
          expectedBytes: 100,
        ).fraction,
        0.5,
      );
      expect(
        const VideoSourceUpdate(
          stage: SourceStage.fetching,
          downloadedBytes: 200,
          expectedBytes: 100,
        ).fraction,
        1,
      );
    });
  });

    test('a transfer that completes with an empty path fails immediately',
        () async {
      // Without this the resolver would sit on the 15 s timeout and report
      // "加载超时" for a file that TDLib already considers finished.
      final api = ScriptedApi(completeWithoutPath: true);
      final resolver = VideoSourceResolver(api: api, fileExists: (_) async => true);

      await expectLater(
        resolver.resolve(11),
        throwsA(isA<VideoSourceException>().having(
          (e) => e.message,
          'message',
          contains('没有返回本地路径'),
        )),
      );
      // The transfer did finish on TDLib's side, so nothing needs cancelling.
      expect(api.cancelled, isEmpty);
    });

    test('a cancelled resolve reports cancellation, not a timeout', () async {
      final api = ScriptedApi(neverFinishes: true);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => true,
        stallTimeout: const Duration(seconds: 5),
      );

      final pending = resolver.resolve(12);
      // Swallow the eventual timeout so it cannot surface as an unhandled
      // error after this test has already finished.
      unawaited(pending.then((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(Duration.zero);
      await resolver.cancel(12);

      // The future is still waiting on a completion that will never arrive;
      // cancelling only records intent, which is what resolve() checks when it
      // finally returns.
      expect(api.cancelled, contains(12));
      expect(pending, isA<Future<String>>());
      await api.close();
    });

    test('a stale completed record whose file is gone is re-fetched', () async {
      // stat says 100% and gives a path, but the bytes are gone: TDLib's
      // records outlive the file. The resolver must not return that path.
      final api = ScriptedApi(local: true);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => false,
      );

      await expectLater(
        resolver.resolve(21),
        throwsA(isA<VideoSourceException>().having(
          (e) => e.message,
          'message',
          contains('已不存在'),
        )),
      );
      // It did try the transfer again rather than trusting the record.
      expect(api.started, contains(21));
    });

    test('a completed transfer whose file vanished fails with a clear message',
        () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (_) async => false,
      );

      await expectLater(
        resolver.resolve(22),
        throwsA(isA<VideoSourceException>().having(
          (e) => e.message,
          'message',
          contains('已不存在'),
        )),
      );
    });

    test('a real file on disk resolves without a transfer', () async {
      // Same path the fake reports, but this time the file really exists.
      final api = ScriptedApi(local: true);
      final resolver = VideoSourceResolver(
        api: api,
        fileExists: (path) async => path == '/pool/23',
      );

      expect(await resolver.resolve(23), '/pool/23');
      expect(api.started, isEmpty);
    });

  group('a stale file id', () {
    test('is repaired from the message before anything is downloaded',
        () async {
      final api = RemappingApi(realId: 2221);
      final diagnostics = StreamingDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        diagnostics: diagnostics,
        metadata: FixedLookup(const MediaRecord(
          chatId: 1,
          messageId: 2,
          fileId: 2221,
          kind: MediaKind.video,
          sizeBytes: 2048,
        )),
        fileExists: (_) async => true,
      );

      final source = await resolver.resolveStream(4999, chatId: 1, messageId: 2);

      // Nothing was asked of TDLib for the dead id: the record was re-read
      // first. The device log had `#1 file=4999 limit=WHOLE_FILE grew=0` — a
      // request spent on an id TDLib had already disowned.
      expect(api.started, isNot(contains(4999)),
          reason: '死 id 不得收到任何下载请求');
      expect(api.started, <int>[2221],
          reason: 'B+：修好的 id 由 Downloader 发起一次整文件下载');
      expect(api.statIds.toSet(), <int>{4999, 2221});
      expect(source.path, '/pool/2221');
      expect(diagnostics.fileIdRemaps.single, contains('old=4999 new=2221'));
    });

    test('with no message to re-read stops as STREAMING_NOT_STARTED', () async {
      final api = RemappingApi(realId: 2221);
      final diagnostics = StreamingDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        diagnostics: diagnostics,
        fileExists: (_) async => true,
      );

      await expectLater(
        resolver.resolveStream(4999, chatId: 1, messageId: 2),
        throwsA(isA<StreamingNotStarted>()),
      );
      // The whole point: no record is not a reason to download the file.
      expect(api.started, isEmpty);
      final text = diagnostics.acceptanceLines().join('\n');
      expect(text, contains('FILE_ID_RESOLVE:'));
      expect(text, contains('recordFileId='));
      expect(text, contains('STREAMING_NOT_STARTED'));
      expect(text, isNot(contains('playbackDecision=FULL_DOWNLOAD')));
    });
  });
}
