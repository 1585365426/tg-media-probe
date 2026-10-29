/// Playback controller: a video only opens after a verified file exists, one
/// player at a time, and a hundred switches do not leave a hundred players.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_index.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/download/cache_validator.dart';
import 'package:tg_media_probe/download/download_manager.dart';
import 'package:tg_media_probe/download/media_cache.dart';
import 'package:tg_media_probe/platform/disk_space.dart';
import 'package:tg_media_probe/playback/playback_controller.dart';
import 'package:tg_media_probe/storage/storage_layout.dart';

import 'support/fake_player.dart';
import 'support/fake_transport.dart';

void main() {
  late Directory dir;
  late StorageLayout layout;
  late FakeTdTransport transport;
  late Map<int, String> paths;

  const int count = 6;
  const int size = 2048;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgmedia_pb_');
    layout = StorageLayout.forSandbox(dir.path);
    await layout.ensureCreated();
    await Directory(layout.tdlibFilesDir).create(recursive: true);
    transport = FakeTdTransport();
    paths = <int, String>{};
    for (var i = 0; i < count; i++) {
      final file = File('${layout.tdlibFilesDir}/v$i.mp4');
      await file.writeAsBytes(List<int>.filled(size, i));
      paths[100 + i] = file.path;
    }
    transport.handlers['getFile'] = (request) {
      final id = request['file_id'] as int;
      return FakeTdTransport.fileJson(
        fileId: id,
        downloadedSize: size,
        size: size,
        completed: true,
        path: paths[id] ?? '',
      );
    };
    PlaybackController.resetLivePlayerCountForTest();
  });

  tearDown(() async {
    await transport.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<NumberedMedia> items() => MediaIndex.fromRecords(<MediaRecord>[
        for (var i = 0; i < count; i++)
          MediaRecord(
            chatId: 1,
            messageId: i + 1,
            fileId: 100 + i,
            kind: MediaKind.video,
            sizeBytes: size,
            messageDateUnix: 1000 + i,
          ),
      ]).items;

  DownloadManager downloads({int free = 1 << 30}) => DownloadManager(
        transport: transport,
        validator: const CacheValidator(),
        cache: MediaCache(layout: layout, diskSpace: FixedDiskSpace(free)),
        pollInterval: const Duration(milliseconds: 20),
      );

  test('start opens the verified local file and plays it', () async {
    final factory = RecordingPlayerFactory();
    final manager = downloads();
    final controller = PlaybackController(
      items: items(),
      downloads: manager,
      initialIndex: 0,
      playerFactory: factory.call,
      playbackSpeed: 1.5,
    );

    await controller.start();
    expect(controller.phase, PlaybackPhase.ready);
    expect(factory.created, hasLength(1));
    expect(factory.last.path, paths[100]);
    expect(factory.last.playing, isTrue);
    expect(factory.last.speed, 1.5);
    expect(controller.current!.label, '#001');
    expect(PlaybackController.livePlayerCount, 1);

    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(PlaybackController.livePlayerCount, 0);
  });

  test('there is never more than one live player', () async {
    final factory = RecordingPlayerFactory();
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: factory.call,
    );
    await controller.start();

    await controller.next();
    expect(factory.created, hasLength(2));
    // The old instance was disposed before the new one was created.
    expect(factory.created.first.disposed, isTrue);
    expect(factory.created.last.disposed, isFalse);
    expect(PlaybackController.livePlayerCount, 1);
    expect(controller.current!.label, '#002');

    await controller.previous();
    expect(controller.current!.label, '#001');
    expect(PlaybackController.livePlayerCount, 1);

    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(PlaybackController.livePlayerCount, 0);
  });

  test('next stops at the last video', () async {
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: count - 1,
      playerFactory: RecordingPlayerFactory().call,
    );
    await controller.start();
    expect(controller.hasNext, isFalse);
    await controller.next();
    expect(controller.index, count - 1);
    controller.dispose();
  });

  test('a download failure is reported with its own message', () async {
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(free: 0),
      initialIndex: 0,
      playerFactory: RecordingPlayerFactory().call,
    );
    // Space is only checked when the file is not already valid, so make the
    // cache miss by pointing the file id at a path that does not exist.
    transport.handlers['getFile'] = (request) => FakeTdTransport.fileJson(
          fileId: request['file_id'] as int,
          downloadedSize: 0,
          size: size,
          completed: false,
          path: '',
        );
    await controller.start();
    expect(controller.phase, PlaybackPhase.failed);
    expect(controller.errorMessage, '磁盘空间不足，请清理空间后重试');
    expect(PlaybackController.livePlayerCount, 0);
    controller.dispose();
  });

  test('a player that cannot open is reported and released', () async {
    final factory = RecordingPlayerFactory(failOpen: true);
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: factory.call,
    );
    await controller.start();
    expect(controller.phase, PlaybackPhase.failed);
    expect(controller.errorMessage, '视频无法播放，请重试');
    expect(factory.last.disposed, isTrue);
    expect(PlaybackController.livePlayerCount, 0);
    controller.dispose();
  });

  test('a superseded load does not leave its player behind', () async {
    final factory = RecordingPlayerFactory(
      openDelay: const Duration(milliseconds: 40),
    );
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: factory.call,
    );
    final first = controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await controller.goTo(2);
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.index, 2);
    expect(PlaybackController.livePlayerCount, 1);
    // Everything created except the current one must be disposed.
    final alive = factory.created.where((p) => !p.disposed).toList();
    expect(alive, hasLength(1));
    controller.dispose();
  });

  test('100 switches leave exactly one player and no crashes', () async {
    final factory = RecordingPlayerFactory();
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: factory.call,
    );
    await controller.start();

    for (var i = 0; i < 100; i++) {
      if (i.isEven) {
        if (controller.hasNext) await controller.next();
      } else {
        if (controller.hasPrevious) await controller.previous();
      }
      expect(PlaybackController.livePlayerCount, lessThanOrEqualTo(1));
      expect(controller.phase, PlaybackPhase.ready);
      expect(controller.current!.number, controller.index + 1);
    }

    expect(PlaybackController.livePlayerCount, 1);
    expect(factory.created.length, greaterThan(1));
    expect(factory.created.where((p) => !p.disposed), hasLength(1));

    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(PlaybackController.livePlayerCount, 0);
  });

  test('speed changes reach the live player', () async {
    final factory = RecordingPlayerFactory();
    final controller = PlaybackController(
      items: items(),
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: factory.call,
    );
    await controller.start();
    await controller.setSpeed(0.5);
    expect(factory.last.speed, 0.5);
    controller.dispose();
  });

  test('an empty channel fails honestly instead of showing a player', () async {
    final controller = PlaybackController(
      items: const <NumberedMedia>[],
      downloads: downloads(),
      initialIndex: 0,
      playerFactory: RecordingPlayerFactory().call,
    );
    await controller.start();
    expect(controller.phase, PlaybackPhase.failed);
    expect(controller.errorMessage, '该频道没有可播放的视频');
    controller.dispose();
  });
}
