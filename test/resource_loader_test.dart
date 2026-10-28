import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/growing_file_reader.dart';
import 'package:tg_media_probe/playback/native_streaming.dart'
    show StreamingV2Unavailable;
import 'package:tg_media_probe/playback/resource_loader.dart';

/// TDLib's own view of the download, scripted by the test.
///
/// The reader only ever *observes* this — there is no download authority on
/// the interface, which is the B+ boundary this file keeps proving.
class FakeProgress implements TdProgressSource {
  FakeProgress({this.reach = 0, this.completed = false});

  int reach;
  bool completed;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  int get tdlibReach => reach;

  @override
  bool get tdlibCompleted => completed;

  @override
  bool get tdlibCanDownload => !completed;

  @override
  Stream<void> get changes => _changes.stream;

  void grow(int bytes) {
    reach += bytes;
    _changes.add(null);
  }

  void finish() {
    completed = true;
    _changes.add(null);
  }
}

/// The reader plus its scripted world: TDLib reach and disk size move
/// independently, because the safe watermark is the min of the two and the
/// historical bug was trusting one of them alone.
class Fixture {
  Fixture({
    this.total = 100 * 1024 * 1024,
    int tdlibReach = 0,
    int disk = 0,
    this.waitTimeout = const Duration(seconds: 10),
  })  : progress = FakeProgress(reach: tdlibReach),
        diskSize = disk {
    reader = GrowingFileReader(
      path: '/pool/9',
      expectedSize: total,
      generation: 1,
      progress: progress,
      diskSizeOf: (_) async => diskSize,
      waitTimeout: waitTimeout,
    );
  }

  final int total;
  final FakeProgress progress;
  final Duration waitTimeout;
  late GrowingFileReader reader;

  /// What the fake "filesystem" reports for the path.
  int diskSize;

  /// Advances the disk without touching TDLib's counter.
  void writeDisk(int bytes) => diskSize = bytes;

  ResourceSupply supply({DateTime Function()? clock}) =>
      ResourceSupply(fileId: 9, reader: reader, clock: clock);
}

class FakeTransport implements NativeStreamingTransport {
  FakeTransport({this.refuse = false});

  bool refuse;
  bool supportedFlag = true;
  final List<String> opened = <String>[];
  final List<String> closed = <String>[];
  int? lastTotalBytes;
  bool? lastCompleted;

  @override
  bool get supported => supportedFlag;

  @override
  Future<Map<String, Object?>?> openSession({
    required String sessionId,
    required int fileId,
    required int chatId,
    required int messageId,
    required int generation,
    required int totalBytes,
    required bool completed,
    required String mimeType,
  }) async {
    if (refuse) throw StreamingV2Unavailable('no bridge');
    opened.add(sessionId);
    lastTotalBytes = totalBytes;
    lastCompleted = completed;
    return <String, Object?>{
      'totalBytes': totalBytes,
      'contentType': 'public.mpeg-4',
      'byteRangeAccessSupported': true,
      'entireLengthAvailableOnDemand': completed,
    };
  }

  @override
  Future<void> closeSession(String sessionId) async => closed.add(sessionId);
  @override
  Future<void> createPlayer(String sessionId) async {}
  @override
  Future<void> play(String sessionId) async {}
  @override
  Future<void> pause(String sessionId) async {}
  @override
  Future<void> seek(String sessionId, Duration position) async {}
  @override
  Future<void> setVolume(String sessionId, double volume) async {}
  @override
  Future<void> disposePlayer(String sessionId) async {}
  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();
}

GrowingFileReader readerOf(
  FakeProgress progress, {
  required int total,
  required int disk,
  Duration waitTimeout = const Duration(seconds: 10),
}) =>
    GrowingFileReader(
      path: '/pool/9',
      expectedSize: total,
      generation: 1,
      progress: progress,
      diskSizeOf: (_) async => disk,
      waitTimeout: waitTimeout,
    );

void main() {
  group('safe watermark', () {
    test('is the min of TDLib reach and the disk', () async {
      final fx = Fixture(total: 1000, tdlibReach: 800, disk: 500);
      // The reader starts blind (-1 disk, 0 reach) on purpose; the first
      // measurement is what a play does before it asks for any byte.
      await fx.reader.refresh();
      expect(fx.reader.safeWatermark, 500, reason: 'disk 是短板');
      fx.writeDisk(900);
      await fx.reader.refresh();
      expect(fx.reader.safeWatermark, 800, reason: '现在 TDLib 是短板');
    });

    test('a missing file reads as zero, never as the TDLib number', () async {
      final fx = Fixture(total: 1000, tdlibReach: 800, disk: -1);
      await fx.reader.refresh();
      expect(fx.reader.safeWatermark, 0);
    });

    test('complete requires the disk to reach the expected size', () async {
      final fx = Fixture(total: 1000, tdlibReach: 1000, disk: 999);
      expect(fx.reader.isComplete, isFalse,
          reason: 'TDLib 说完成而磁盘少 1 字节——历史假 100% 的形状');
      fx.writeDisk(1000);
      await fx.reader.refresh();
      expect(fx.reader.isComplete, isTrue);
    });

    test('expectedSize=0 is never complete on existence alone', () async {
      final fx = Fixture(total: 0, tdlibReach: 0, disk: 4096);
      expect(fx.reader.isComplete, isFalse);
    });
  });

  group('read / WAIT / EOF', () {
    test('an offset inside the watermark is served up to it', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final r = await fx.reader.read(100);
      expect(r.available, isTrue);
      expect(r.readableTo, 499);
      expect(r.completed, isFalse);
    });

    test('an offset past the watermark waits — never EOF', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final r = await fx.reader.read(600);
      expect(r.available, isFalse);
      expect(r.completed, isFalse, reason: '缺数据 ≠ EOF');
    });

    test('the byte at the watermark waits until growth arrives', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      expect((await fx.reader.read(500)).available, isFalse);
      fx.progress.grow(200);
      fx.writeDisk(700);
      final r = await fx.reader.read(500);
      expect(r.available, isTrue);
      expect(r.readableTo, 699);
    });

    test('a complete file answers any offset and says EOF only there',
        () async {
      final fx = Fixture(total: 1000, tdlibReach: 1000, disk: 1000);
      final r = await fx.reader.read(999);
      expect(r.available, isTrue);
      expect(r.readableTo, 999);
      expect(r.completed, isTrue);
    });

    test('a tail request on a short file waits instead of finishing', () async {
      const total = 700 * 1024 * 1024;
      final fx = Fixture(total: total, tdlibReach: 20 * 1024 * 1024,
          disk: 20 * 1024 * 1024);
      final r = await fx.reader.read(total - 64 * 1024);
      expect(r.completed, isFalse, reason: '尾部请求不是文件结束');
      expect(r.available, isFalse);
    });
  });

  group('wait timeout', () {
    test('WAIT_TIMEOUT after the configured wait, not an EOF', () async {
      final fx = Fixture(total: 1000, tdlibReach: 0, disk: 0);
      var now = DateTime.now();
      final supply = ResourceSupply(
        fileId: 9,
        reader: fx.reader,
        clock: () => now,
      );
      // First read: WAIT, no error.
      final first = await supply.read(500);
      expect(first.errorCode, isNull);
      expect(first.downloading, isTrue);
      // Eleven seconds of silence (the clock is faked): WAIT_TIMEOUT.
      now = now.add(const Duration(seconds: 11));
      final second = await supply.read(500);
      expect(second.errorCode, 'WAIT_TIMEOUT');
      expect(second.completed, isFalse, reason: '超时也不是 EOF');
      expect(second.downloading, isFalse);
    });

    test('growth resets the wait clock', () async {
      final fx = Fixture(total: 1000, tdlibReach: 0, disk: 0);
      var now = DateTime.now();
      final supply = ResourceSupply(
        fileId: 9,
        reader: fx.reader,
        clock: () => now,
      );
      await supply.read(500);
      // Growth arrives at +5 s; the wait clock restarts there.
      now = now.add(const Duration(seconds: 5));
      fx.progress.grow(100);
      fx.writeDisk(100);
      final mid = await supply.read(500);
      expect(mid.hasData, isFalse, reason: 'offset 500 仍在水位之外');
      expect(mid.errorCode, isNull);
      // The read above saw growth at +5 s; +6 s later still inside grace.
      now = now.add(const Duration(seconds: 6));
      final still = await supply.read(500);
      expect(still.errorCode, isNull, reason: '距上次增长只有 6 秒');
      now = now.add(const Duration(seconds: 5));
      final after = await supply.read(500);
      expect(after.errorCode, 'WAIT_TIMEOUT', reason: '距上次增长已 11 秒');
    });

    test('WAIT_TIMEOUT is carried by the session serve path', () async {
      final fx = Fixture(total: 1000, tdlibReach: 0, disk: 0);
      var now = DateTime.now();
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
        clock: () => now,
      );
      final first = await session.serve(500, 4096);
      expect(first.errorCode, isNull);
      now = now.add(const Duration(seconds: 11));
      final reading = await session.serve(500, 4096);
      expect(reading.errorCode, 'WAIT_TIMEOUT');
    });
  });

  group('content information', () {
    test('carries expectedSize as contentLength, not the disk size',
        () async {
      final fx = Fixture(total: 1000, tdlibReach: 100, disk: 100);
      final transport = FakeTransport();
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: transport,
      );
      await session.open();
      expect(transport.lastTotalBytes, 1000,
          reason: 'contentLength 必须是 expectedSize');
      expect(transport.lastCompleted, isFalse);
    });

    test('a complete file is the only one declared fully available', () async {
      final fx = Fixture(total: 1000, tdlibReach: 1000, disk: 1000);
      final transport = FakeTransport();
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: transport,
      );
      await session.open();
      expect(transport.lastCompleted, isTrue);
    });
  });

  group('session', () {
    test('a closed session refuses every byte with SESSION_CLOSED', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      await session.open();
      await session.close();
      final reading = await session.serve(0, 4096);
      expect(reading.errorCode, 'SESSION_CLOSED');
    });

    test('a superseded generation refuses the request', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      var active = 1;
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
        activeGeneration: () => active,
      );
      await session.open();
      active = 2;
      final reading = await session.serve(0, 4096);
      expect(reading.errorCode, 'STALE_GENERATION');
    });

    test('the session counts what it really served', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      await session.open();
      await session.serve(0, 4096);
      expect(session.dataRequests, 1);
      expect(session.responds, 1);
      expect(session.bytesServed, 500);
    });
  });

  group('host', () {
    test('an unknown session id is refused, never served', () async {
      final host = ResourceLoaderHost();
      final map = await host.handleSupply(<Object?, Object?>{
        'sessionId': 'nope',
        'offset': 0,
        'length': 10,
      });
      final reading = SupplyReading.fromMap(map);
      expect(reading.errorCode, 'SESSION_CLOSED');
    });

    test('the registered session answers for its own id', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final host = ResourceLoaderHost();
      final session = ResourceLoaderSession(
        sessionId: 's1',
        fileId: 9,
        chatId: 1,
        messageId: 2,
        generation: 1,
        reader: fx.reader,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      host.register(session);
      final map = await host.handleSupply(<Object?, Object?>{
        'sessionId': 's1',
        'offset': 0,
        'length': 10,
      });
      expect(SupplyReading.fromMap(map).hasData, isTrue);
    });

    test('registering a new play drops the previous session', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      final host = ResourceLoaderHost();
      ResourceLoaderSession make(String id) => ResourceLoaderSession(
            sessionId: id,
            fileId: 9,
            chatId: 1,
            messageId: 2,
            generation: 1,
            reader: fx.reader,
            mimeType: 'video/mp4',
            transport: FakeTransport(),
          );
      host.register(make('a'));
      host.register(make('b'));
      final map = await host.handleSupply(<Object?, Object?>{
        'sessionId': 'a',
        'offset': 0,
        'length': 10,
      });
      expect(SupplyReading.fromMap(map).errorCode, 'SESSION_CLOSED');
    });
  });

  group('invalidate / generation', () {
    test('an invalidated reader refuses further reads', () async {
      final fx = Fixture(total: 1000, tdlibReach: 500, disk: 500);
      fx.reader.invalidate();
      final r = await fx.reader.read(0);
      expect(r.available, isFalse, reason: '旧一代播放不得再读到一个字节');
      expect(fx.reader.isComplete, isFalse);
    });
  });
}
