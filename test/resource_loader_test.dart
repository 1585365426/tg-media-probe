import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/mp4_probe.dart' show Mp4Probe, MoovPosition;
import 'package:tg_media_probe/playback/native_streaming.dart'
    show StreamingV2Unavailable;
import 'package:tg_media_probe/playback/resource_loader.dart';
import 'package:tg_media_probe/playback/stream_proxy.dart' show FileProgressWatch;
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';

/// A growing file with a steerable TDLib window — same model as the real
/// watcher, driven by the test instead of by `updateFile`.
class FakeWatch implements FileProgressWatch {
  FakeWatch({
    this.path = '/pool/9',
    this.total = 100 * 1024 * 1024,
    this.prefix = 0,
    this.windowOffset = 0,
    this.complete = false,
  });

  /// The file the loader reads. [localPath] is the interface's name for it;
  /// the fake keeps a mutable field so a test can drop the path mid-play.
  String path;

  int total;
  int prefix;
  int windowOffset;
  bool complete;

  final List<List<int>> windows = <List<int>>[];
  int resumes = 0;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  int get headBytes => windowOffset == 0 ? prefix : 0;

  @override
  int get expectedBytes => total;

  @override
  bool get isComplete => complete;

  @override
  String get localPath => path;

  @override
  Stream<void> get progress => _changes.stream;

  @override
  int readableEndFrom(int from) {
    if (complete) return total - 1;
    if (from >= windowOffset && from < windowOffset + prefix) {
      return windowOffset + prefix - 1;
    }
    return -1;
  }

  @override
  bool covers(int from, int end) {
    if (complete) return true;
    if (end < from) return true;
    return from >= windowOffset && end <= windowOffset + prefix - 1;
  }

  @override
  Future<void> requestWindow(int from, int end) async {
    windows.add(<int>[from, end]);
    windowOffset = from;
    prefix = 0;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> resumeSequential() async {
    resumes++;
    windowOffset = 0;
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Appends bytes at the current window, as TDLib would.
  void grow(int bytes) {
    prefix += bytes;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}

class FakeTransport implements NativeStreamingTransport {
  FakeTransport({this.refuse = false});

  bool refuse;
  bool supportedFlag = true;
  final List<String> opened = <String>[];
  final List<String> closed = <String>[];

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
  Stream<Map<String, Object?>> events() => const Stream<Map<String, Object?>>.empty();
}

void main() {
  group('content information', () {
    test('carries total, completeness and a UTI content type', () async {
      final watch = FakeWatch(total: 659667830, prefix: 2097152);
      final transport = FakeTransport();
      final session = ResourceLoaderSession(
        sessionId: '1_1',
        fileId: 1,
        chatId: 2,
        messageId: 3,
        generation: 1,
        watch: watch,
        mimeType: 'video/mp4',
        transport: transport,
      );
      await session.open();

      expect(transport.opened, <String>['1_1']);
      expect(session.url, 'tgmedia://video/1_1');
      expect(session.isClosed, isFalse);
    });

    test('a complete file is the only one declared fully available', () async {
      final transport = FakeTransport();
      final partial = ResourceLoaderSession(
        sessionId: 'a',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(total: 1000, prefix: 500),
        mimeType: 'video/mp4',
        transport: transport,
      );
      await partial.open();
      // The reply records what AVFoundation will be told; a growing file is
      // never "available on demand".
      expect(partial.isClosed, isFalse);
    });
  });

  group('data request', () {
    late FakeWatch watch;
    late ResourceSupply supply;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 1, 1);
      watch = FakeWatch(total: 100 * 1024 * 1024, prefix: 2 * 1024 * 1024);
      supply = ResourceSupply(
        fileId: 9,
        watch: watch,
        clock: () => now,
      );
    });

    test('an offset inside the downloaded prefix is served in full', () async {
      final reading = await supply.read(0);
      expect(reading.hasData, isTrue);
      expect(reading.from, 0);
      expect(reading.to, 2 * 1024 * 1024 - 1);
      expect(reading.total, 100 * 1024 * 1024);
      expect(reading.completed, isFalse);
      expect(reading.errorCode, isNull, reason: 'not downloaded yet is not an error');
    });

    test('the last byte before EOF is served', () async {
      final reading = await supply.read(2 * 1024 * 1024 - 1);
      expect(reading.from, 2 * 1024 * 1024 - 1);
      expect(reading.to, 2 * 1024 * 1024 - 1);
    });

    test('an offset exactly at EOF waits instead of failing', () async {
      final reading = await supply.read(2 * 1024 * 1024);
      expect(reading.hasData, isFalse);
      expect(reading.downloading, isTrue);
      expect(reading.errorCode, isNull);
      // The cursor sits on the edge the sequential download is about to reach:
      // stealing the window here would make linear playback a chase.
      expect(watch.windows, isEmpty);
    });

    test('the same request answers again after the file grows', () async {
      // One AVAssetResourceLoadingDataRequest, several respond() calls:
      // first the 2 MB that exist, then the next 1 MB.
      final first = await supply.read(0);
      expect(first.to, 2 * 1024 * 1024 - 1);

      watch.grow(1024 * 1024);
      final second = await supply.read(2 * 1024 * 1024);
      expect(second.hasData, isTrue);
      expect(second.from, 2 * 1024 * 1024);
      expect(second.to, 3 * 1024 * 1024 - 1);
    });

    test('a complete file answers any offset up to the end', () async {
      watch.complete = true;
      final tail = await supply.read(watch.total - 1);
      expect(tail.hasData, isTrue);
      expect(tail.to, watch.total - 1);
      expect(tail.completed, isTrue);
      expect(tail.downloading, isFalse);
    });

    test('a tail request steers the window at the requested range', () async {
      // moov after mdat: the player asks for the end of a 100 MB file while
      // 2 MB exist.
      const tailOffset = 90 * 1024 * 1024;
      await supply.read(tailOffset);
      expect(watch.windows, hasLength(1));
      expect(watch.windows.single[0], tailOffset & ~1023);
      expect(watch.windows.single[1], greaterThan(watch.windows.single[0]));
    });

    test('a request at the head does not steal the window', () async {
      await supply.read(0);
      expect(watch.windows, isEmpty,
          reason: 'the sequential download is already filling the head');
      expect(watch.resumes, 0);
    });

    test('a head request after a tail steer restores the sequential download',
        () async {
      await supply.read(90 * 1024 * 1024); // tail steer
      watch.windowOffset = 90 * 1024 * 1024;
      watch.prefix = 0;
      await supply.read(0); // the player wants the first frames now
      expect(watch.resumes, greaterThanOrEqualTo(1));
    });

    test('the same tail asked twice only steers once', () async {
      const tailOffset = 90 * 1024 * 1024;
      await supply.read(tailOffset);
      await supply.read(tailOffset + 4096);
      expect(watch.windows, hasLength(1),
          reason: 'AVPlayer repeats a range; each repeat must not restart TDLib');
    });

    test('no growth for the grace window is reported as a stall', () async {
      // First call steers the window (which itself counts as a change), the
      // second establishes the baseline; then the clock moves and nothing
      // arrives.
      await supply.read(50 * 1024 * 1024);
      await supply.read(50 * 1024 * 1024);
      now = now.add(const Duration(seconds: 25));
      final reading = await supply.read(50 * 1024 * 1024);
      expect(reading.hasData, isFalse);
      expect(reading.errorCode, 'DOWNLOAD_STALLED');
      expect(reading.downloading, isFalse);
    });

    test('growth inside the grace window is not a stall', () async {
      now = now.add(const Duration(seconds: 5));
      watch.grow(1024);
      final reading = await supply.read(50 * 1024 * 1024);
      expect(reading.errorCode, isNull);
      expect(reading.downloading, isTrue);
    });
  });

  group('session', () {
    test('a closed session refuses every byte with SESSION_CLOSED', () async {
      final transport = FakeTransport();
      final session = ResourceLoaderSession(
        sessionId: 's',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(prefix: 4096),
        mimeType: 'video/mp4',
        transport: transport,
      );
      await session.open();
      await session.close();
      final reading = await session.serve(0, 4096);
      expect(reading.errorCode, 'SESSION_CLOSED');
      expect(reading.hasData, isFalse);
      expect(transport.closed, <String>['s']);
    });

    test('a superseded generation refuses the request', () async {
      final session = ResourceLoaderSession(
        sessionId: 'old',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(prefix: 4096),
        mimeType: 'video/mp4',
        transport: FakeTransport(),
        activeGeneration: () => 2,
      );
      await session.open();
      final reading = await session.serve(0, 4096);
      expect(reading.errorCode, 'STALE_GENERATION');
    });

    test('the current generation is served', () async {
      final session = ResourceLoaderSession(
        sessionId: 'live',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 2,
        watch: FakeWatch(prefix: 4096),
        mimeType: 'video/mp4',
        transport: FakeTransport(),
        activeGeneration: () => 2,
      );
      await session.open();
      final reading = await session.serve(0, 4096);
      expect(reading.hasData, isTrue);
      expect(session.responds, 1);
    });

    test('the session counts what it really served', () async {
      final session = ResourceLoaderSession(
        sessionId: 'count',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(prefix: 8192),
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      await session.open();
      await session.serve(0, 4096);
      await session.serve(4096, 4096);
      expect(session.dataRequests, 2);
      expect(session.responds, 2);
      expect(session.bytesServed, greaterThan(0));
    });
  });

  group('host', () {
    test('an unknown session id is refused, never served', () async {
      final host = ResourceLoaderHost();
      final reply = await host.handleSupply(<Object?, Object?>{
        'sessionId': 'ghost',
        'offset': 0,
        'length': 1024,
      });
      expect(reply['errorCode'], 'SESSION_CLOSED');
    });

    test('the registered session answers for its own id', () async {
      final host = ResourceLoaderHost();
      final session = ResourceLoaderSession(
        sessionId: 'live',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(prefix: 4096),
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      await session.open();
      host.register(session);

      final reply = await host.handleSupply(<Object?, Object?>{
        'sessionId': 'live',
        'offset': 0,
        'length': 1024,
      });
      expect(reply['from'], 0);
      expect(reply['to'], 4095);
      expect(reply['total'], 100 * 1024 * 1024);
      expect(reply['errorCode'], isNull);
    });

    test('registering a new play drops the previous session', () async {
      final host = ResourceLoaderHost();
      ResourceLoaderSession make(String id) => ResourceLoaderSession(
            sessionId: id,
            fileId: 1,
            chatId: 1,
            messageId: 1,
            generation: 1,
            watch: FakeWatch(prefix: 4096),
            mimeType: 'video/mp4',
            transport: FakeTransport(),
          );
      final first = make('first');
      final second = make('second');
      await first.open();
      await second.open();
      host.register(first);
      host.register(second);

      final old = await host.handleSupply(<Object?, Object?>{
        'sessionId': 'first',
        'offset': 0,
        'length': 10,
      });
      expect(old['errorCode'], 'SESSION_CLOSED');
    });

    test('closing a session removes it from the host', () async {
      final host = ResourceLoaderHost();
      final session = ResourceLoaderSession(
        sessionId: 'gone',
        fileId: 1,
        chatId: 1,
        messageId: 1,
        generation: 1,
        watch: FakeWatch(prefix: 4096),
        mimeType: 'video/mp4',
        transport: FakeTransport(),
      );
      await session.open();
      host.register(session);
      await session.close();
      expect(host.active, isNull);
    });
  });

  // The diagnostics log the acceptance report reads. The requirement is not
  // "some logging happened" but named events, each stamped with the play it
  // belongs to — a leftover request from the previous video must be visible as
  // a different file/generation, not blended into the current numbers.
  group('diagnostics events', () {
    late StreamingDiagnostics diagnostics;
    late FakeWatch watch;
    late ResourceLoaderSession session;

    setUp(() {
      diagnostics = StreamingDiagnostics();
      diagnostics.beginPlay(fileId: 9, streaming: true, chatId: 4, messageId: 5);
      watch = FakeWatch(total: 100 * 1024 * 1024, prefix: 2 * 1024 * 1024);
      session = ResourceLoaderSession(
        sessionId: '9_gen',
        fileId: 9,
        chatId: 4,
        messageId: 5,
        generation: diagnostics.generation,
        watch: watch,
        mimeType: 'video/mp4',
        transport: FakeTransport(),
        diagnostics: diagnostics,
      );
    });

    test('opening names the session, the content info request and its answer',
        () async {
      await session.open();
      final names = diagnostics.resourceLoaderLog.map((e) => e.name).toList();
      expect(names, containsAllInOrder(<String>[
        'resourceLoaderCreated',
        'contentInfoRequested',
        'contentInfoReady',
      ]));
      final ready = diagnostics.resourceLoaderLog
          .firstWhere((e) => e.name == 'contentInfoReady');
      expect(ready['contentType'], 'public.mpeg-4');
      expect(ready['totalBytes'], 100 * 1024 * 1024);
      expect(ready['byteRangeAccessSupported'], isTrue);
      expect(ready['entireLengthAvailableOnDemand'], isFalse);
    });

    test('a served request logs offset, length and the respond', () async {
      await session.open();
      await session.serve(0, 512 * 1024);

      final created = diagnostics.resourceLoaderLog
          .firstWhere((e) => e.name == 'dataRequestCreated');
      expect(created['requestedOffset'], 0);
      expect(created['requestedLength'], 512 * 1024);
      expect(created['availableBytes'], 2 * 1024 * 1024);

      final respond =
          diagnostics.resourceLoaderLog.firstWhere((e) => e.name == 'respond');
      expect(respond['respondCount'], 1);
      expect(respond['respondBytes'], 512 * 1024);
    });

    test('waiting on a growing file is logged, not invented as a failure',
        () async {
      await session.open();
      await session.serve(50 * 1024 * 1024, 64 * 1024);

      final waiting = diagnostics.resourceLoaderLog
          .where((e) => e.name == 'waitingForGrowth')
          .toList();
      expect(waiting, isNotEmpty);
      expect(waiting.first['offset'], 50 * 1024 * 1024);
      expect(waiting.first['stalled'], isFalse);
      // The window move that makes the wait finite is logged too.
      final targeted = diagnostics.resourceLoaderLog
          .where((e) => e.name == 'targetedDownloadRequested')
          .toList();
      expect(targeted, isNotEmpty);
    });

    test('every entry carries the identity of the play', () async {
      await session.open();
      await session.serve(0, 1024);
      for (final event in diagnostics.resourceLoaderLog) {
        expect(event.chatId, 4);
        expect(event.messageId, 5);
        expect(event.fileId, 9);
        expect(event.generation, diagnostics.generation);
      }
    });

    test('the log is exported with the report', () async {
      await session.open();
      await session.serve(0, 1024);
      final json = diagnostics.toJson();
      final rl = json['resourceLoader'] as Map<String, Object?>;
      final events = rl['events'] as List<Object?>;
      expect(events, isNotEmpty);
      final first = events.first as Map<String, Object?>;
      expect(first['name'], 'resourceLoaderCreated');
      expect(first['file'], 9);
      expect(first['generation'], diagnostics.generation);
    });

    test('a new play starts with an empty log', () async {
      await session.open();
      expect(diagnostics.resourceLoaderLog, isNotEmpty);
      diagnostics.beginPlay(fileId: 10, streaming: true, chatId: 4, messageId: 6);
      expect(diagnostics.resourceLoaderLog, isEmpty);
    });
  });

  // The download states the acceptance matrix walks through, answered by the
  // same supply. The rule every row obeys: bytes that exist are served, bytes
  // that do not exist wait — and "not yet" is never reported as an error or as
  // the end of the file.
  group('tdlib progress', () {
    const total = 200 * 1024 * 1024;

    Future<void> check(String label, int prefix, bool complete) async {
      final watch = FakeWatch(total: total, prefix: prefix, complete: complete);
      final supply = ResourceSupply(fileId: 9, watch: watch);

      final head = await supply.read(0);
      if (prefix > 0 || complete) {
        expect(head.hasData, isTrue, reason: '$label: 已下载的字节必须能读');
        expect(head.from, 0, reason: label);
        expect(head.errorCode, isNull, reason: label);
      } else {
        expect(head.hasData, isFalse, reason: '$label: 还没有字节');
        expect(head.downloading, isTrue, reason: label);
        expect(head.errorCode, isNull, reason: '$label: 没下载不算失败');
      }
      expect(head.completed, complete, reason: label);
      expect(head.total, total, reason: label);
    }

    test('downloaded=0 waits without an error', () => check('0', 0, false));
    test('downloaded=1MB serves the first megabyte',
        () => check('1MB', 1024 * 1024, false));
    test('downloaded=20MB serves the prefix',
        () => check('20MB', 20 * 1024 * 1024, false));
    test('downloaded=100MB (50%) serves the prefix',
        () => check('50%', 100 * 1024 * 1024, false));
    test('downloaded=99% is still not complete',
        () => check('99%', 198 * 1024 * 1024, false));
    test('complete serves any offset and says so',
        () => check('complete', total, true));

    test('a complete file answers the last byte', () async {
      final watch = FakeWatch(total: total, prefix: total, complete: true);
      final supply = ResourceSupply(fileId: 9, watch: watch);
      final reading = await supply.read(total - 1);
      expect(reading.hasData, isTrue);
      expect(reading.to, total - 1);
      expect(reading.completed, isTrue);
    });
  });

  // The two MP4 layouts the acceptance matrix calls out. The probe decides
  // which, and the supply has to act on it: `moov` at the head is a linear
  // play, `moov` after `mdat` is a tail probe on a file that is still being
  // written. Both are simulated from real box headers, not from a flag.
  group('moov layout', () {
    /// One 32-bit MP4 box: size + four-character type + payload.
    List<int> box(String type, int payloadBytes) {
      final size = 8 + payloadBytes;
      return <int>[
        (size >> 24) & 0xFF,
        (size >> 16) & 0xFF,
        (size >> 8) & 0xFF,
        size & 0xFF,
        ...type.codeUnits,
        ...List<int>.filled(payloadBytes, 0),
      ];
    }

    test('moov at the head is served without moving the window', () async {
      final header = <int>[
        ...box('ftyp', 16),
        ...box('moov', 64),
      ];
      expect(Mp4Probe.locate(header), MoovPosition.head);

      final watch = FakeWatch(total: 20 * 1024 * 1024, prefix: 1024 * 1024);
      final supply = ResourceSupply(fileId: 9, watch: watch);

      // Linear play: the first request is offset 0 and the sequential
      // download is already there.
      final reading = await supply.read(0);
      expect(reading.hasData, isTrue);
      expect(reading.to, 1024 * 1024 - 1);
      expect(watch.windows, isEmpty, reason: 'moov=head 时不得抢下载窗口');
      expect(watch.resumes, 0);
    });

    test('moov after mdat asks for the tail and gets it', () async {
      final header = <int>[
        ...box('ftyp', 16),
        ...box('mdat', 8),
      ];
      expect(Mp4Probe.locate(header), MoovPosition.afterMdat);

      // 700 MB file, 20 MB on disk, moov at the end: AVFoundation asks for the
      // tail long before the sequential download could ever reach it.
      const total = 700 * 1024 * 1024;
      final watch = FakeWatch(total: total, prefix: 20 * 1024 * 1024);
      final supply = ResourceSupply(fileId: 9, watch: watch);

      final tailOffset = total - 64 * 1024;
      final first = await supply.read(tailOffset);
      expect(watch.windows, hasLength(1),
          reason: 'moov=afterMdat 必须把窗口切到尾部');
      expect(watch.windows.single[0], tailOffset & ~1023);
      expect(first.hasData, isFalse, reason: '窗口刚切，字节还没到');
      expect(first.downloading, isTrue);
      expect(first.errorCode, isNull, reason: '没到不是失败');

      // TDLib delivers the window; the same request now has data.
      watch.grow(64 * 1024);
      final second = await supply.read(tailOffset);
      expect(second.hasData, isTrue);
      expect(second.from, tailOffset);
      expect(second.to, greaterThan(tailOffset));
      expect(second.total, total);
    });

    test('the tail request is not answered as the end of the file', () async {
      const total = 700 * 1024 * 1024;
      final watch = FakeWatch(total: total, prefix: 20 * 1024 * 1024);
      final supply = ResourceSupply(fileId: 9, watch: watch);

      // The player asked for everything from the tail on; the supply reports
      // only what is readable and keeps `completed` false, so the loader waits
      // instead of calling finishLoading() on a short body.
      final reading = await supply.read(total - 32 * 1024);
      expect(reading.completed, isFalse);
      expect(reading.downloading, isTrue);
      expect(reading.to, lessThan(total - 1));
    });
  });
}
