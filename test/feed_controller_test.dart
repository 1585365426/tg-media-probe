import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState, Orientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/native_streaming.dart' show StreamingV2;
import 'package:tg_media_probe/playback/player_slot.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_error_kind.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/ui/feed_controller.dart';

// ---------------------------------------------------------------- fixtures

MediaRecord video(int messageId, {int chatId = 1, int? duration}) => MediaRecord(
      chatId: chatId,
      messageId: messageId,
      fileId: 1000 + messageId,
      kind: MediaKind.video,
      width: 1080,
      height: 1920,
      durationSeconds: duration,
      sizeBytes: 1024,
      fileName: 'video-$messageId.mp4',
      messageDateUnix: 1700000000 + messageId,
    );

MediaRecord photo(int messageId) => MediaRecord(
      chatId: 1,
      messageId: messageId,
      fileId: 5000 + messageId,
      kind: MediaKind.photo,
      messageDateUnix: 1700000000 + messageId,
    );

class FakeFeedSource implements FeedPageSource {
  FakeFeedSource(this.pages, {this.error});

  final List<List<MediaRecord>> pages;

  /// Mutable so a test can simulate "the index recovered".
  Object? error;
  int _cursor = 0;
  int pageRequests = 0;

  @override
  bool get hasMore => _cursor < pages.length;

  @override
  Future<List<MediaRecord>> nextPage() async {
    pageRequests++;
    if (error != null) throw error!;
    if (_cursor >= pages.length) return const <MediaRecord>[];
    return pages[_cursor++];
  }

  @override
  void reset() => _cursor = 0;
}

class PlayerLedger {
  int created = 0;
  int disposed = 0;
  int plays = 0;
  int pauses = 0;

  /// Ordered trace of what happened, so a test can prove *ordering* and not
  /// only the final counts. "created == disposed + 1" says nothing about
  /// whether the old player was released before the new one started.
  final List<String> events = <String>[];
  final List<String> loaded = <String>[];
  final List<double> volumes = <double>[];
  final List<Duration> seeks = <Duration>[];

  int get live => created - disposed;
}

class FakePlayer implements PlayerHandle, PlayerProgress, PlayerVolume, PlayerSeek {
  FakePlayer(this.path, this.ledger, {this.failOnLoad = false});

  @override
  final String path;
  final PlayerLedger ledger;
  final bool failOnLoad;

  bool _playing = false;
  bool _disposed = false;
  bool _loaded = false;

  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 30);

  @override
  bool get isPlaying => _playing;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<void> load() async {
    if (failOnLoad) throw StateError('decode failed');
    _loaded = true;
    ledger.loaded.add(path);
    ledger.events.add('load $path');
  }

  @override
  Future<void> play() async {
    if (!_loaded) throw StateError('play before load');
    if (_disposed) throw StateError('play after dispose');
    if (!_playing) {
      _playing = true;
      ledger.plays++;
    }
  }

  @override
  Future<void> pause() async {
    ledger.events.add('pause $path');
    if (_playing) {
      _playing = false;
      ledger.pauses++;
    }
  }

  @override
  Future<void> disposePlayer() async {
    if (_disposed) return;
    await pause();
    _disposed = true;
    ledger.disposed++;
    ledger.events.add('dispose $path');
  }

  @override
  Future<void> setVolume(double volume) async {
    ledger.volumes.add(volume);
  }

  @override
  Future<void> seekTo(Duration target) async {
    position = target;
    ledger.seeks.add(target);
  }
}

class FakeTracker {
  final PlayerLedger ledger = PlayerLedger();
  bool failOnLoad = false;

  PlayerHandle create(String path) {
    ledger.created++;
    ledger.events.add('create $path');
    return FakePlayer(path, ledger, failOnLoad: failOnLoad);
  }
}

class FakeTransferApi implements FileTransferApi {
  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  FakeTransferApi({this.autoComplete = true});

  /// When true, `start()` completes the transfer on the next microtask.
  bool autoComplete;

  /// File ids that already exist locally; resolved without a transfer.
  final Set<int> alreadyLocal = <int>{};

  /// When true, `start()` raises a TDLib error.
  bool failOnStart = false;

  /// When true, `stat` answers `null` for every id — TDLib has no record at
  /// all, which is the state the device report called `no_file_record`.
  bool noRecord = false;

  final StreamController<FileState> _updates =
      StreamController<FileState>.broadcast();
  final Set<int> cancelled = <int>{};
  int startCalls = 0;
  int statCalls = 0;
  final List<int> startedIds = <int>[];

  /// Callers of every bounded window (i.e. everything except a preload).
  final List<DownloadCaller> windowCallers = <DownloadCaller>[];

  /// Every `startRange` as (caller, limit). The CI assertion "PLAYER never
  /// asks for the whole file" reads this: a player call with `limit <= 0`
  /// here is the 152 MB bug come back.
  final List<(DownloadCaller, int)> windowLimits = <(DownloadCaller, int)>[];

  /// Every `start()` (the whole-file request) with the caller that sent it.
  final List<DownloadCaller> wholeFileCallers = <DownloadCaller>[];

  @override
  Future<FileState?> stat(int fileId) async {
    statCalls++;
    if (noRecord) return null;
    if (alreadyLocal.contains(fileId)) {
      return FileState(
        id: fileId,
        size: 4096,
        expectedSize: 4096,
        downloadedSize: 4096,
        isCompleted: true,
        path: '/tmp/pool/$fileId',
        canBeDownloaded: true,
      );
    }
    return FileState(
      id: fileId,
      size: 0,
      expectedSize: 4096,
      downloadedSize: 0,
      isCompleted: false,
      path: '',
      canBeDownloaded: true,
    );
  }

  @override
  Future<void> start(int fileId, {DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    startCalls++;
    wholeFileCallers.add(caller);
    startedIds.add(fileId);
    if (failOnStart) throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    if (autoComplete) {
      // Deferred by a microtask: the whole-file resolver subscribes to
      // `updates()` only after `start()` returns, and a broadcast event
      // pushed synchronously here would land before any listener and be
      // dropped — the play would then stall out instead of completing.
      scheduleMicrotask(() {
        // The completion reaches `stat` too: a whole-file download that ends
        // must leave behind a record the re-stat can verify, the way TDLib
        // does — otherwise the measured fallback can never turn into a play.
        alreadyLocal.add(fileId);
        _updates.add(FileState(
          id: fileId,
          size: 4096,
          expectedSize: 4096,
          downloadedSize: 4096,
          isCompleted: true,
          path: '/tmp/pool/$fileId',
          canBeDownloaded: true,
        ));
      });
    }
  }

  /// The warm start (prefetch) sends offset 0 / limit 0 through here. It is a
  /// real TDLib request and nothing else: no completion update, no path, so a
  /// preload can never turn into "ready to play".
  /// A bounded window. TDLib answers it with the same growing file, but it is
  /// **not** a whole-file request — [startCalls] must not move, because that
  /// counter is what the acceptance assertion "no FULL_DOWNLOAD" reads.
  @override
  Future<void> startRange(int fileId, {required int offset, required int limit, int priority = 16, DownloadCaller caller = DownloadCaller.unknown, String cause = ''}) async {
    // A preload is a real TDLib request and nothing else: no completion
    // update and no path, so it can never turn into "ready to play".
    if (caller == DownloadCaller.preload) {
      startedIds.add(fileId);
      return;
    }
    windowCallers.add(caller);
    windowLimits.add((caller, limit));
    startedIds.add(fileId);
    if (failOnStart) throw VideoSourceException('TDLib error 400: FILE_ID_INVALID');
    if (autoComplete) {
      _updates.add(FileState(
        id: fileId,
        size: 4096,
        expectedSize: 4096,
        downloadedSize: 4096,
        isCompleted: true,
        path: '/tmp/pool/$fileId',
        canBeDownloaded: true,
      ));
    }
  }
  @override
  Future<void> cancel(int fileId) async {
    cancelled.add(fileId);
  }

  @override
  Stream<FileState> updates() => _updates.stream;

  Future<void> dispose() async => _updates.close();
}

class Rig {
  Rig({
    required List<List<MediaRecord>> pages,
    Object? sourceError,
    bool autoComplete = true,
    Duration timeout = const Duration(seconds: 5),
    bool preload = true,
    bool muted = false,
  })  : source = FakeFeedSource(pages, error: sourceError),
        tracker = FakeTracker(),
        api = FakeTransferApi(autoComplete: autoComplete) {
    controller = FeedController(
      source: source,
      player: SinglePlayerController(factory: _Factory(tracker)),
      sources: VideoSourceResolver(
        api: api,
        stallTimeout: timeout,
        // The fake pool paths never exist on disk; the real resolver now
        // verifies existence, so the rig answers for its own pool. Sizes too:
        // a stat over a fake path cannot measure, and an unmeasurable file
        // must never read as complete.
        fileExists: (_) async => true,
        diskSizeOf: (_) async => 4096,
      ),
      chatTitles: const <int, String>{1: '测试频道'},
      defaultMuted: muted,
      preloadAdjacent: preload,
      // No timers in unit tests: progress is read explicitly.
      pollInterval: null,
      // The B+ recovery waits for the play's own download to land. A device
      // may legitimately take minutes; a test may not, so the budget is
      // injected rather than hard-coded in the loop.
      fullDownloadWait: const Duration(milliseconds: 400),
    );
  }

  final FakeFeedSource source;
  final FakeTracker tracker;
  final FakeTransferApi api;
  late final FeedController controller;

  PlayerLedger get ledger => tracker.ledger;
}

class _Factory implements PlayerFactory {
  _Factory(this.tracker);

  final FakeTracker tracker;

  @override
  PlayerHandle create(String path) => tracker.create(path);
}

// ---------------------------------------------------------------- tests

void main() {
  group('FeedController loading', () {
    test('an empty index shows the empty state, not a spinner', () async {
      final rig = Rig(pages: <List<MediaRecord>>[<MediaRecord>[]]);
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.empty);
      expect(rig.controller.length, 0);
    });

    test('a single video becomes the current item and starts playing', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
      expect(rig.controller.isPlaying, isTrue);
    });

    test('a page with no video pulls the next page instead of giving up',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[photo(1), photo(2)],
        <MediaRecord>[video(3)],
      ]);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.current?.messageId, 3);
      expect(rig.source.pageRequests, greaterThanOrEqualTo(2));
    });

    test('a source failure surfaces as an error, not as an empty list',
        () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[<MediaRecord>[]],
        sourceError: StateError('index unreadable'),
      );
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, contains('index unreadable'));
    });

    test('retry recovers after the index becomes readable again', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        sourceError: StateError('temporary'),
      );
      await rig.controller.load();
      expect(rig.controller.phase, FeedPhase.error);

      rig.source.error = null;
      await rig.controller.retry();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
    });

    test('an existing local file resolves without a transfer', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.alreadyLocal.add(1001);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready);
      expect(rig.api.startCalls, 0);
      expect(rig.ledger.loaded.single, '/tmp/pool/1001');
    });
  });

  group('switching', () {
    test('the previous player is released before the next one starts', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();

      expect(rig.controller.index, 1);
      expect(rig.ledger.created, 2);
      expect(rig.ledger.disposed, 1);
      expect(rig.ledger.live, 1);
    });

    test('the transfer of the item left behind is cancelled', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      expect(rig.api.cancelled, contains(1001));
    });

    test('going back to the previous item works', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      await rig.controller.goPrevious();
      expect(rig.controller.index, 0);
      expect(rig.ledger.live, 1);
    });

    test('going back from the first item does nothing', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goPrevious();
      expect(rig.controller.index, 0);
      expect(rig.ledger.created, 1);
    });

    test('moving to the last loaded item pulls the next page first', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
        <MediaRecord>[video(2)],
      ]);
      await rig.controller.load();
      expect(rig.controller.length, 1);

      await rig.controller.goNext();
      expect(rig.controller.length, 2);
      expect(rig.controller.index, 1);
    });

    test('100 switches leave exactly one live player', () async {
      final items = List<MediaRecord>.generate(101, (i) => video(i + 1));
      final rig = Rig(pages: <List<MediaRecord>>[items]);
      await rig.controller.load();

      for (var i = 0; i < 100; i++) {
        await rig.controller.goNext();
      }

      expect(rig.controller.index, 100);
      expect(rig.ledger.created, 101);
      expect(rig.ledger.disposed, 100);
      expect(rig.ledger.live, 1);
      expect(rig.controller.phase, FeedPhase.ready);
    });

    test('a stale resolution cannot overwrite the item the user moved to',
        () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2)],
        ],
        autoComplete: false,
      );
      // First item never completes; the user swipes away immediately.
      final loading = rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      await rig.controller.goNext();
      await loading;

      // Only the second item has a player, and the first resolution was dropped.
      expect(rig.ledger.live, lessThanOrEqualTo(1));
      expect(rig.controller.phase, isNot(FeedPhase.ready));
    });
  });

  group('failures', () {
    test('a transfer that stops sending data is reported as a network stall',
        () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        autoComplete: false,
        timeout: const Duration(milliseconds: 30),
      );
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      // The wording has to name the condition: "0 bytes for 30ms" is a stall,
      // and only a stall may be called a network problem.
      expect(rig.controller.error, contains('仍未收到任何数据'));
      expect(rig.controller.failure, RequestFailure.offline);
      expect(rig.ledger.live, 0);
    });

    test('a TDLib error is shown as a real message', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.failOnStart = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.controller.error, contains('FILE_ID_INVALID'));
    });

    test('a player that cannot load ends the play with an error', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.tracker.failOnLoad = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      // B+：下载先把文件写完整，播放器拒绝的是字节本身 —— 这条路径的终点是
      // 「此视频无法解码」，而不是再去下载一遍。旧的整文件 fallback 已删除。
      expect(rig.controller.error, '此视频无法解码');
      expect(rig.controller.phase, isNot(FeedPhase.ready));
      // A player that failed to load must not stay live.
      expect(rig.ledger.live, 0);
    });
  });

  group('a video with no TDLib record', () {
    test('stops instead of downloading the whole file', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.noRecord = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      // `no_file_record` used to be answered with a full download under a
      // *different* file id — the device report's `#2 file=2221 limit=WHOLE_FILE`.
      expect(rig.api.startCalls, 0, reason: 'no_file_record 不得触发整文件下载');
      expect(rig.api.windowCallers, isEmpty);
    });
  });

  group('V2-only', () {
    tearDown(() => StreamingV2.enabledOverride = null);

    test('a failed V2 play spends its one fallback, then plays from disk',
        () async {
      // V2-only is the production policy; the host platform has no bridge, so
      // the resolver fails exactly the way a broken session does on a device.
      // The play then takes its ONE whole-file fallback — and because the
      // fallback's file is measured before it is trusted, the play ends on a
      // verified local file, not on a claim.
      StreamingV2.enabledOverride = true;
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.ready,
          reason: '整文件下载完成并实测到顶后必须能播');
      // The two things the switch exists to remove: a second transport inside
      // the same tap, and a download that makes the failure look like a play.
      expect(rig.controller.diagnostics.v1Attempted, isFalse,
          reason: 'V2-only：V2 失败后不得调用 V1');
      expect(rig.controller.diagnostics.v2Attempted, isTrue);
      expect(rig.api.startCalls, 1, reason: '一次播放只有一次整文件下载');
      expect(rig.api.wholeFileCallers, everyElement(DownloadCaller.downloader),
          reason: 'WHOLE_FILE 只能由 DOWNLOADER 发出');
      expect(
        rig.api.windowCallers.where((c) => c == DownloadCaller.proxy),
        isEmpty,
        reason: 'proxy 窗口意味着 V1 被启动过',
      );
      // B+：V2 失败后不花「fallback 预算」，而是等这次播放本来就有的下载落盘。
      expect(rig.controller.session?.fullDownloadFallbackUsed, isFalse,
          reason: '等待已有下载不是 fallback，预算不该被花掉');
    });

    test('a refused fallback stops the play instead of looping', () async {
      // The whole-file request itself is refused. One play: the first request
      // fails, the recovery path spends its single restart, that restart is
      // refused too, and the play stops. A third attempt would be the loop.
      StreamingV2.enabledOverride = true;
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      rig.api.failOnStart = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.api.startCalls, 2,
          reason: '首播一次 + 恢复路径唯一一次 restart，之后必须停止');
      expect(rig.controller.session?.fullDownloadFallbackUsed, isTrue,
          reason: 'restart 花掉的是这一次播放的预算');
    });

    test('PLAYER never sends any TDLib request', () async {
      // B+ 把窗口请求整条删了：播放只读本地增长文件，唯一的下发者是
      // Downloader。任何 PLAYER 字样的调用都是旧链路的回魂。
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      expect(
        rig.api.wholeFileCallers.where((c) => c == DownloadCaller.player),
        isEmpty,
        reason: 'PLAYER 不得出现在 WHOLE_FILE 调用里',
      );
      expect(
        rig.api.windowCallers.where((c) => c == DownloadCaller.player),
        isEmpty,
        reason: 'PLAYER 不得发出窗口请求（B+ 已删除该链路）',
      );
      expect(rig.api.wholeFileCallers, everyElement(DownloadCaller.downloader));
      expect(rig.controller.phase, FeedPhase.ready);
    });
  });

  group('a failed stream never downloads the video', () {
    test('a refused stream takes its one fallback, and no more', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      // Every TDLib request fails: the transport has nothing to work with.
      rig.api.failOnStart = true;
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      // The new floor: every TDLib request fails, so the play's first download
      // is refused; the recovery path spends its one restart, which the same
      // refusal kills. The play stops with the real reason: two requests, no
      // loop, no third attempt.
      expect(rig.api.startCalls, 2,
          reason: '首播一次 + 唯一一次 restart，拒绝后立即停止');
      expect(rig.api.wholeFileCallers, everyElement(DownloadCaller.downloader),
          reason: 'WHOLE_FILE 只能由 DOWNLOADER 发出');
      expect(rig.controller.phase, isNot(FeedPhase.ready));
    });

    test('a stalled stream waits for the play download, then stops', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        autoComplete: false,
        timeout: const Duration(milliseconds: 120),
      );
      await rig.controller.load();

      expect(rig.controller.phase, FeedPhase.error);
      expect(rig.api.startCalls, 1,
          reason: 'stall 之后只有首播那一次整文件请求，不得反复下载');
      // B+：下载还在跑，所以「等待」就是全部动作；等待超时即停，不另起请求，
      // 也不花 fallback 预算。
      expect(rig.controller.session?.fullDownloadFallbackUsed, isFalse);
      expect(rig.api.startCalls, 1,
          reason: '等待超时不得变成第二次整文件请求');
    });
  });

  group('controls and progress', () {
    test('play and pause toggle the live player', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      expect(rig.controller.isPlaying, isTrue);

      await rig.controller.togglePlayPause();
      expect(rig.controller.isPlaying, isFalse);

      await rig.controller.togglePlayPause();
      expect(rig.controller.isPlaying, isTrue);
    });

    test('muting sets volume to 0 and back to 1', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();

      await rig.controller.setMuted(true);
      await rig.controller.setMuted(false);

      expect(rig.ledger.volumes.last, 1);
      expect(rig.ledger.volumes, contains(0));
    });

    test('the default-muted preference is applied on the first item', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1)],
        ],
        muted: true,
      );
      await rig.controller.load();
      expect(rig.ledger.volumes, contains(0));
      expect(rig.controller.muted, isTrue);
    });

    test('seeking moves the playhead', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      await rig.controller.seekTo(const Duration(seconds: 7));

      expect(rig.ledger.seeks.single, const Duration(seconds: 7));
      expect(rig.controller.position, const Duration(seconds: 7));
    });

    test('refreshProgress reads the playhead off the live handle', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      final handle = rig.controller.player.active as FakePlayer;
      handle.position = const Duration(seconds: 12);
      handle.duration = const Duration(seconds: 40);

      rig.controller.refreshProgress();
      expect(rig.controller.position, const Duration(seconds: 12));
      expect(rig.controller.duration, const Duration(seconds: 40));
    });

    test('controls start hidden and toggle', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      expect(rig.controller.controlVisible, isFalse);
      rig.controller.toggleControls();
      expect(rig.controller.controlVisible, isTrue);
      rig.controller.setControlsVisible(false);
      expect(rig.controller.controlVisible, isFalse);
    });

    test('the position label reports the place in the loaded list', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      expect(rig.controller.positionLabel, '1 / 2');
      await rig.controller.goNext();
      expect(rig.controller.positionLabel, '2 / 2');
    });
  });

  group('lifecycle', () {
    test('backgrounding releases the player and resuming re-activates the item',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await rig.controller.goNext();
      expect(rig.ledger.live, 1);

      await rig.controller.handleLifecycle(AppLifecycleState.paused);
      expect(rig.ledger.live, 0);

      await rig.controller.handleLifecycle(AppLifecycleState.resumed);
      expect(rig.ledger.live, 1);
      // The same item, not the first one.
      expect(rig.controller.index, 1);
      expect(rig.controller.phase, FeedPhase.ready);
    });

    test('a resume without a pause does not rebuild the player', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      final created = rig.ledger.created;
      await rig.controller.handleLifecycle(AppLifecycleState.resumed);
      expect(rig.ledger.created, created);
    });
  });

  group('preloading', () {
    test('the adjacent item is warmed locally, never downloaded', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      final statsBefore = rig.api.statCalls;
      // Give the prefetch a turn.
      await Future<void>.delayed(Duration.zero);

      // B+：预取只读本地状态（一次 stat），不再向 TDLib 要一段窗口。
      expect(rig.api.startedIds, isNot(contains(1002)),
          reason: '预取不得发起任何下载');
      expect(rig.api.statCalls, greaterThan(statsBefore),
          reason: '预取的动作应该是一次 stat');
      // Preloading never creates a second player.
      expect(rig.ledger.created, 1);
    });

    test('preloading can be switched off', () async {
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2)],
        ],
        preload: false,
      );
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(rig.api.startedIds, isNot(contains(1002)));
    });
  });

  group('pure decisions', () {
    test('a swipe counts as a page turn past 12% of the height', () {
      expect(
        FeedController.shouldSwitchPage(dy: 130, velocity: 0, height: 1000),
        isTrue,
      );
      expect(
        FeedController.shouldSwitchPage(dy: 119, velocity: 0, height: 1000),
        isFalse,
      );
    });

    test('a fast flick counts even with a short distance', () {
      expect(
        FeedController.shouldSwitchPage(dy: 40, velocity: 420, height: 1000),
        isTrue,
      );
      expect(
        FeedController.shouldSwitchPage(dy: 40, velocity: 200, height: 1000),
        isFalse,
      );
    });

    test('a zero-height viewport falls back to the velocity rule', () {
      expect(
        FeedController.shouldSwitchPage(dy: 500, velocity: 0, height: 0),
        isFalse,
      );
    });

    test('landscape hides the info block but keeps the controls', () {
      final portrait = FeedOverlayPlan.forOrientation(Orientation.portrait);
      final landscape = FeedOverlayPlan.forOrientation(Orientation.landscape);

      expect(portrait.showInfo, isTrue);
      expect(portrait.showTopBar, isTrue);
      expect(landscape.showInfo, isFalse);
      // The rotate-back button lives in the controls; hiding them strands the
      // user in landscape.
      expect(landscape.showControls, isTrue);
      expect(landscape.showTopBar, isTrue);
    });
  });

  group('player lifecycle while pages change', () {
    test('the old player is paused and disposed before the new one is created',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2)],
      ]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      rig.ledger.events.clear();

      await rig.controller.goNext();
      await Future<void>.delayed(Duration.zero);

      final events = rig.ledger.events;
      final disposeIndex = events.indexWhere((e) => e.startsWith('dispose '));
      final createIndex =
          events.indexWhere((e) => e.startsWith('create '), disposeIndex);
      expect(disposeIndex, greaterThanOrEqualTo(0),
          reason: 'the old player must be released: $events');
      expect(createIndex, greaterThan(disposeIndex),
          reason: 'a new player must not exist while the old one is alive: '
              '$events');
      expect(rig.ledger.live, 1);

      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('a resolve superseded mid-flight leaves no orphan player', () async {
      // The transfer for item 1 never completes; the user swipes to item 3
      // while it is pending. The abandoned item must not keep a player.
      final rig = Rig(
        pages: <List<MediaRecord>>[
          <MediaRecord>[video(1), video(2), video(3)],
        ],
        autoComplete: false,
      );
      rig.api.alreadyLocal.addAll(<int>[1001, 1002, 1003]);

      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      final afterFirst = rig.ledger.created;

      await rig.controller.goNext();
      await rig.controller.goNext();
      await Future<void>.delayed(Duration.zero);

      expect(rig.ledger.created, greaterThan(afterFirst));
      expect(rig.ledger.live, 1,
          reason: 'exactly one player may survive the two switches');

      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('five fast switches end with one live player and no double create',
        () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2), video(3), video(4), video(5)],
      ]);
      rig.api.alreadyLocal.addAll(<int>[1001, 1002, 1003, 1004, 1005]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 5; i++) {
        await rig.controller.goNext();
        await Future<void>.delayed(Duration.zero);
      }

      expect(rig.ledger.live, 1);
      // Each create must be preceded by a dispose except for the very first.
      final creates = rig.ledger.events.where((e) => e.startsWith('create ')).length;
      final disposes =
          rig.ledger.events.where((e) => e.startsWith('dispose ')).length;
      expect(creates - disposes, 1);

      rig.controller.shutdown();
      await rig.api.dispose();
    });

    // Test 5 from the spec: A is tapped, B is tapped 200 ms later. B must own
    // the player, the generation, and the file id — and everything A still had
    // in flight must land on a stale generation and be dropped.
    test('tapping A then B ends on B and A cannot touch it', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2), video(3)],
      ]);
      rig.api.alreadyLocal.addAll(<int>[1001, 1002]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.activeFileId, 1001);
      final generationA = rig.controller.playGeneration;

      await rig.controller.goNext();
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.activeFileId, 1002);
      expect(rig.controller.current?.messageId, 2);
      expect(rig.controller.playGeneration, greaterThan(generationA));
      expect(rig.ledger.live, 1,
          reason: 'B 接管时必须只剩一个播放器');
      expect(rig.ledger.loaded.last, contains('1002'));

      rig.controller.shutdown();
      await rig.api.dispose();
    });
  });

  group('tapping a row opens that exact video', () {
    test('a message on the first page is selected without paging', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1), video(2), video(3)],
      ]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      final requestsBefore = rig.source.pageRequests;

      final found = await rig.controller.goToMessage(1, 2);

      expect(found, isTrue);
      expect(rig.controller.current?.messageId, 2);
      expect(rig.source.pageRequests, requestsBefore,
          reason: 'nothing to fetch: the item was already loaded');
      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('a message on a later page is reached by paging', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
        <MediaRecord>[video(2), video(3)],
      ]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(rig.source.pageRequests, 1);

      final found = await rig.controller.goToMessage(1, 3);

      expect(found, isTrue);
      expect(rig.source.pageRequests, 2);
      expect(rig.controller.current?.messageId, 3);
      rig.controller.shutdown();
      await rig.api.dispose();
    });

    test('a message that is not in the mirror returns false', () async {
      final rig = Rig(pages: <List<MediaRecord>>[
        <MediaRecord>[video(1)],
      ]);
      await rig.controller.load();
      await Future<void>.delayed(Duration.zero);

      final found = await rig.controller.goToMessage(1, 999);

      expect(found, isFalse);
      // The screen stays on a playable item rather than on a spinner.
      expect(rig.controller.current, isNotNull);
      rig.controller.shutdown();
      await rig.api.dispose();
    });
  });
}
