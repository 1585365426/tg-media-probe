import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

class ScriptedApi implements FileTransferApi {
  ScriptedApi({this.local = false, this.failOnStart = false, this.neverFinishes = false});

  bool local;
  bool failOnStart;
  bool neverFinishes;

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
  Future<void> start(int fileId) async {
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
      path: '/pool/$fileId',
      canBeDownloaded: true,
    ));
  }

  @override
  Future<void> cancel(int fileId) async {
    cancelled.add(fileId);
  }

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> close() => _updates.close();
}

void main() {
  group('VideoSourceResolver', () {
    test('a file already on disk resolves without starting a transfer',
        () async {
      final api = ScriptedApi(local: true);
      final resolver = VideoSourceResolver(api: api);

      final path = await resolver.resolve(7);

      expect(path, '/pool/7');
      expect(api.started, isEmpty);
    });

    test('a missing file is fetched and the completed path returned', () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(api: api);

      final path = await resolver.resolve(7);

      expect(path, '/pool/7');
      expect(api.started, <int>[7]);
    });

    test('progress goes probing -> fetching -> ready', () async {
      final api = ScriptedApi();
      final resolver = VideoSourceResolver(api: api);
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
        fetchTimeout: const Duration(milliseconds: 40),
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
        fetchTimeout: const Duration(seconds: 15),
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
      final resolver = VideoSourceResolver(api: api);

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
        fetchTimeout: const Duration(milliseconds: 60),
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
      final resolver = VideoSourceResolver(api: api);

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
}
