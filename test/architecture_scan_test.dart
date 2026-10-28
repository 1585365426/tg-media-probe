/// The B+ architecture as a hard gate.
///
/// These are not behaviour tests. They read the source and fail when a module
/// that must not download grows a path to TDLib's download API. A green suite
/// here is what makes "the player never downloads" a checked fact instead of a
/// review comment.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strips `//` line comments so prose about `downloadFile` cannot fail a scan
/// that is only about code.
String _code(String source) {
  final buffer = StringBuffer();
  for (final line in source.split('\n')) {
    final index = line.indexOf('//');
    buffer.writeln(index < 0 ? line : line.substring(0, index));
  }
  return buffer.toString();
}

/// The body of one top-level class member, from its signature to the closing
/// brace that starts at the same indentation.
String _memberBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '找不到 $signature —— 架构改了就要改这条断言');
  final rest = source.substring(start);
  final lines = rest.split('\n');
  final indent = lines.first.length - lines.first.trimLeft().length;
  final buffer = StringBuffer()..writeln(lines.first);
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    final isClosing = line.trim() == '}' &&
        (line.length - line.trimLeft().length) == indent;
    if (isClosing) {
      buffer.writeln(line);
      break;
    }
    buffer.writeln(line);
  }
  return buffer.toString();
}

Iterable<File> _sources(String root) => Directory('$root/lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  final root = Directory.current.path;

  group('only the Downloader may ask for the whole file', () {
    test('downloadFile() has exactly three legal homes', () {
      // The request builder, the transport that sends it, and the message
      // probe (which resolves a file id, not a play). Anything else is a new
      // door into the download API.
      const allowed = <String>{
        'lib/td/td_requests.dart',
        'lib/playback/video_source.dart',
        'lib/td/media_probe.dart',
      };
      final offenders = <String>[];
      for (final file in _sources(root)) {
        final relative = file.path
            .replaceAll('\\', '/')
            .split('/lib/')
            .last;
        final code = _code(file.readAsStringSync());
        if (!code.contains('downloadFile(')) continue;
        if (!allowed.contains('lib/$relative')) {
          offenders.add('lib/$relative');
        }
      }
      expect(offenders, isEmpty,
          reason: '这些文件直接调用了 downloadFile()，B+ 只允许 Downloader 经 '
              'FileTransferApi 请求整文件：$offenders');
    });

    test('the Downloader itself never sends a ranged window', () {
      final code = _code(
        File('$root/lib/playback/downloader.dart').readAsStringSync(),
      );
      expect(code.contains('startRange('), isFalse,
          reason: 'Downloader 只发 limit=0 的整文件请求，窗口属于已删除的 V2 链路');
      expect(code.contains('DownloadCaller.player'), isFalse);
      expect(code.contains('DownloadCaller.resourceLoader'), isFalse);
    });

    test('the file reader cannot reach any download API', () {
      final code = _code(
        File('$root/lib/playback/growing_file_reader.dart').readAsStringSync(),
      );
      for (final forbidden in <String>[
        'downloadFile',
        'startRange',
        'FileTransferApi',
        'Downloader',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: 'GrowingFileReader 必须只观察，出现「$forbidden」即架构违规');
      }
    });

    test('the resource loader cannot reach any download API', () {
      final code = _code(
        File('$root/lib/playback/resource_loader.dart').readAsStringSync(),
      );
      for (final forbidden in <String>[
        'downloadFile',
        'startRange',
        'FileTransferApi',
        'continueWindow',
        'WindowContinuation',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: 'ResourceLoader 必须只回读本地文件，出现「$forbidden」即架构违规');
      }
    });
  });

  group('the AUTO chain', () {
    test('_streamOnce never sends a request of its own', () {
      final source = File('$root/lib/playback/video_source.dart')
          .readAsStringSync();
      final body = _code(_memberBody(source, 'Future<PlaySource> _streamOnce('));
      for (final forbidden in <String>[
        'startRange(',
        '_api.start(',
        'downloadFile(',
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: 'AUTO 链出现在「$forbidden」：播放路径不得自己发起下载');
      }
      // The one call it is allowed to make: ask the Downloader to ensure the
      // transfer exists.
      expect(body.contains('ensureFullDownload'), isTrue);
    });

    test('the controller has no second streaming transport', () {
      // V1 (loopback HTTP) is not "switched off" in the feed controller — it
      // is gone. No `_tryV1`, no `allowProxy: true`, and no call to the
      // resolver's proxy entry point. A flag can be flipped back by someone in
      // a hurry; a missing call site cannot.
      final code = _code(
        File('$root/lib/ui/feed_controller.dart').readAsStringSync(),
      );
      for (final gone in <String>[
        '_tryV1',
        'allowProxy: true',
        'sources.resolveStream(',
        "noteTransportStart('HTTP_PROXY')",
      ]) {
        expect(code.contains(gone), isFalse,
            reason: 'AUTO 链只剩一条流式通路，控制器里出现了「$gone」');
      }
      expect(code.contains('allowProxy: false'), isTrue,
          reason: 'decideAfterTransportFailure 必须显式关掉 proxy 选项');
    });

    test('the transport entry is recorded after beginPlay', () {
      // `beginPlay` opens a fresh evidence block and clears the attempt flags.
      // A transport named before it is a transport the report forgets.
      final source = File('$root/lib/playback/video_source.dart')
          .readAsStringSync();
      final begin = source.indexOf('final generation = _diagnostics.beginPlay(');
      final attempt = source.indexOf('_diagnostics.noteTransportStart(');
      expect(begin, isNot(-1));
      expect(attempt, isNot(-1), reason: '没有任何地方记录 transport 进入');
      expect(attempt, greaterThan(begin),
          reason: 'noteTransportStart 在 beginPlay 之前 —— 会被重置抹掉');
    });

    test('the native loader waits out a WAIT_TIMEOUT instead of failing', () {
      // §8 says a timeout is a report, not a verdict. The Swift pump used to
      // treat any `errorCode` as terminal: a moov-at-end file legitimately
      // waits for the whole sequential download, so at 10 s the request was
      // finished with an error and the player went black. These three facts
      // together are the fix, and none of them may be relaxed alone.
      final swift = File(
        '$root/ios/Runner/Streaming/TGMediaResourceLoader.swift',
      ).readAsStringSync();
      expect(swift.contains('waitTimeoutCode = "WAIT_TIMEOUT"'), isTrue,
          reason: 'native 侧必须认识这个码，否则判断失效');

      const guard =
          'if code == TGMediaResourceLoader.waitTimeoutCode, reading.downloading {';
      final at = swift.indexOf(guard);
      expect(at, isNot(-1),
          reason: 'WAIT_TIMEOUT 分支必须同时检查 downloading —— '
              '「下载还在跑」不能当成「请求失败」');

      final branchEnd = swift.indexOf('host?.emit(type: "supplyError"', at);
      expect(branchEnd, isNot(-1));
      final branch = swift.substring(at, branchEnd);
      expect(branch.contains('continue'), isTrue,
          reason: 'WAIT_TIMEOUT 且下载在跑时必须继续轮询');
      expect(branch.contains('finishLoading'), isFalse,
          reason: 'WAIT_TIMEOUT 分支里出现 finishLoading，等于把等待判死');

      // And the Dart side has to tell the truth for that branch to work:
      // `downloading` is the transfer state, not the wait outcome.
      final loader = _code(
        File('$root/lib/playback/resource_loader.dart').readAsStringSync(),
      );
      expect(loader.contains('downloading: !timedOut'), isFalse,
          reason: 'downloading 被写成了「是否超时」，超时的活下载会被报成已死');
      expect(loader.contains('reader.isDownloading'), isTrue,
          reason: 'downloading 必须取自 reader 的下载状态');
    });

    test('the player path holds no downloader reference at all', () {
      // Player-facing modules: the player itself, the proxy, sessions.
      for (final relative in <String>[
        'lib/playback/player_slot.dart',
        'lib/playback/playback_session.dart',
        'lib/playback/stream_proxy.dart',
      ]) {
        final file = File('$root/$relative');
        if (!file.existsSync()) continue;
        final code = _code(file.readAsStringSync());
        expect(code.contains('downloadFile('), isFalse,
            reason: '$relative 直接调用了 downloadFile()');
        expect(code.contains('DownloadCaller.player'), isFalse,
            reason: '$relative 还在以 PLAYER 名义发请求');
      }
    });
  });

  group('the verdict is computed from evidence something actually writes', () {
    // The device report printed `req=0 resp=0 bytes=0` and
    // STREAMING_NOT_STARTED over a video that had just played 43 s, because the
    // V2 counters were incremented by two methods no production path called.
    // A counter the panel reads must be written from the event stream; a
    // second writer is how the first one silently dies.
    final diag = File('$root/lib/playback/streaming_diagnostics.dart');
    final body = _code(diag.readAsStringSync());

    test('V2 counters are written in exactly one place', () {
      int count(String needle) =>
          needle.allMatches(body).length;
      expect(count('_rlRequests++'), 1,
          reason: '_rlRequests 只能在一个地方自增，否则会有一路永远为 0');
      expect(count('_rlResponds++'), 1,
          reason: '_rlResponds 只能在一个地方自增');
      expect(count('_rlBytes +=') <= 1, isTrue,
          reason: '_rlBytes 只能在一个地方累加');
      // …and that place is the event handler both producers write to.
      expect(body.contains('_countV2Event(name, fields)'), isTrue,
          reason: 'V2 计数必须由 noteResourceLoaderEvent 统一驱动');
    });

    test('the resource-loader evidence counts as "attempted"', () {
      // V2 has no port to bind, so `proxyStartedMillis` is never set on a
      // resource-loader play. Reading only that marker made every V2 run look
      // unstarted.
      final verdict = _memberBody(
        File('$root/lib/playback/streaming_diagnostics.dart')
            .readAsStringSync(),
        '  StreamingVerdict get verdict {',
      );
      expect(verdict.contains('_v2StartedMillis'), isTrue,
          reason: 'verdict 的 attempted 必须含 V2 的启动证据');
      expect(verdict.contains('_rlResponds'), isTrue,
          reason: 'verdict 必须认 responds —— 那是真正交给播放器的字节');
    });

    test('the panel never prints disk FULL next to completed=false', () {
      // The three-way `completed` (TDLIB / DISK / NONE) is what keeps
      // `disk=162308586 B FULL` and `completed=false` from appearing together.
      expect(body.contains('evidence=\$completionEvidence'), isTrue,
          reason: 'completed 必须带证据来源，不能只回一个布尔');
      expect(body.contains('completed=\${_isDownloadingCompleted ?'), isFalse,
          reason: 'completed 只看 TDLib 的 claim，会把已完整的文件报成未完成');
    });
  });

  group('a stuck play must still produce a verdict', () {
    // Two device runs ended with a frozen screen and no report. Both were the
    // same shape: some await that never completes, and no deadline anywhere
    // above it. These gates keep the deadlines in place.
    test('the player load has a deadline', () {
      final code = _code(
        File('$root/lib/playback/player_slot.dart').readAsStringSync(),
      );
      expect(code.contains('await handle.load().timeout('), isTrue,
          reason: 'handle.load() 没有超时：AVPlayer 等不到字节就永远不返回，'
              '整场播放既无首帧也无错误');
      expect(code.contains('loadTimeout'), isTrue,
          reason: '超时值必须可配置，测试才能不等 25 秒');
    });

    test('waiting for the whole file stops when the download is dead', () {
      final body = _code(
        _memberBody(
          File('$root/lib/ui/feed_controller.dart').readAsStringSync(),
          '  Future<PlaySource?> _waitForFullDownload(',
        ),
      );
      expect(body.contains('FullDownloadState.failed'), isTrue,
          reason: '_waitForFullDownload 必须读取 Downloader 的失败裁决，'
              '否则一个死掉的传输会让它空等 30 分钟');
    });

    test('the downloader watches for silence', () {
      final code = _code(
        File('$root/lib/playback/downloader.dart').readAsStringSync(),
      );
      expect(code.contains('DOWNLOAD_STALL'), isTrue,
          reason: '没有停滞检测，TDLib 停下之后没有任何层知道');
      expect(code.contains('_api.stat('), isTrue,
          reason: '判定停滞前必须向 TDLib 复核一次，否则会重启一条健康的传输');
      // And it still may not send a ranged window — that stays the player's
      // deletion, not the download authority's new toy.
      expect(code.contains('startRange('), isFalse,
          reason: 'Downloader 仍然只发整文件请求');
    });
  });
}
