import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/media_record.dart';
import 'package:tg_media_probe/playback/media_metadata.dart';
import 'package:tg_media_probe/playback/playback_session.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

/// What the message carries. The tile's file id is only where the lookup
/// starts; this object owns the live one.
class _MessageSays implements MediaMetadataLookup {
  _MessageSays(this.byId);

  final Map<int, MediaRecord> byId;

  @override
  Future<MediaRecord?> fetch(int chatId, int messageId) async =>
      byId[messageId];
}

/// A TDLib that only answers `stat`, and answers it from a script.
class _Api implements FileTransferApi {
  _Api(this.byStat);

  final Map<int, FileState> byStat;
  final List<int> wholeFileCalls = <int>[];
  final List<(int, int, int)> rangeCalls = <(int, int, int)>[];

  @override
  Future<FileState?> stat(int fileId) async => byStat[fileId];

  @override
  Future<void> start(int fileId,
      {DownloadCaller caller = DownloadCaller.unknown,
      String cause = ''}) async {
    wholeFileCalls.add(fileId);
  }

  @override
  Future<void> startRange(int fileId,
      {required int offset,
      required int limit,
      int priority = 16,
      DownloadCaller caller = DownloadCaller.unknown,
      String cause = ''}) async {
    rangeCalls.add((fileId, offset, limit));
  }

  @override
  Future<void> prefetch(int fileId) =>
      startRange(fileId, offset: 0, limit: 0);

  @override
  Future<void> cancel(int fileId) async {}

  @override
  Stream<FileState> updates() => const Stream<FileState>.empty();
}

MediaRecord _record(int messageId, int fileId) => MediaRecord(
      chatId: 7,
      messageId: messageId,
      fileId: fileId,
      kind: MediaKind.video,
    );

void main() {
  group('PlaybackSession', () {
    test('one whole-file fallback per session, never a loop', () {
      final session = PlaybackSession(chatId: 1, messageId: 2);
      expect(session.canUseFullDownloadFallback, isTrue);
      expect(session.spendFullDownloadFallback(), isTrue);
      expect(session.fullDownloadFallbackUsed, isTrue);
      // The second ask is the infinite loop the device report described:
      // stream → download → fail → download → fail → download.
      expect(session.spendFullDownloadFallback(), isFalse);
      expect(session.canUseFullDownloadFallback, isFalse);
    });

    test('sessions are independent', () {
      final a = PlaybackSession(chatId: 1, messageId: 2)
        ..spendFullDownloadFallback();
      final b = PlaybackSession(chatId: 1, messageId: 3);
      expect(b.canUseFullDownloadFallback, isTrue,
          reason: '下一次播放的预算不能被上一次花掉');
      expect(a.sessionId, isNot(b.sessionId));
    });
  });

  group('resolvePlayableFile', () {
    late TestSandbox sandbox;

    setUp(() async {
      sandbox = await TestSandbox.create();
    });

    tearDown(() async {
      await sandbox.dispose();
    });

    test('resolves through the message, never through a hard-coded id',
        () async {
      // The device log: the tile carried 4999, TDLib's live record sat at
      // 2221. The message is the identity; the id is a runtime handle.
      final api = _Api(<int, FileState>{
        2221: FileState(
          id: 2221,
          size: 0,
          expectedSize: 4096,
          downloadedSize: 0,
          isCompleted: false,
          path: '',
          canBeDownloaded: true,
        ),
      });
      final diag = StreamingDiagnostics();
      final resolver = VideoSourceResolver(
        api: api,
        metadata: _MessageSays(<int, MediaRecord>{91: _record(91, 2221)}),
        diagnostics: diag,
      );

      final playable = await resolver.resolvePlayableFile(
        7,
        91,
        hintFileId: 4999,
      );

      expect(playable.fileId, 2221,
          reason: '必须用消息里的活 id，不能用 4999 也不得写死 2221');
      expect(playable.chatId, 7);
      expect(playable.messageId, 91);
      expect(playable.isComplete, isFalse, reason: '磁盘上没有字节');
      // The swap is printed, not hidden: a play that downloads a different
      // file than the one tapped has to say so.
      expect(diag.fileIdRemaps.join('\n'), contains('old=4999 new=2221'));
    });

    test('isComplete needs measured bytes, not a completed claim', () async {
      // A record that says done, a path that exists, and fewer bytes behind
      // it than the total: the exact shape the device called `LOCAL_FILE` at
      // 989 KB of an 809 MB film.
      final path = sandbox.tempFile('short.bin');
      final short = 4096 - 1000;
      await File(path).writeAsBytes(List<int>.filled(short, 1));
      final api = _Api(<int, FileState>{
        2221: FileState(
          id: 2221,
          size: 4096,
          expectedSize: 4096,
          downloadedSize: 4096,
          isCompleted: true,
          path: path,
          canBeDownloaded: true,
        ),
      });
      final resolver = VideoSourceResolver(
        api: api,
        metadata: _MessageSays(<int, MediaRecord>{91: _record(91, 2221)}),
        diagnostics: StreamingDiagnostics(),
      );

      final playable = await resolver.resolvePlayableFile(
        7,
        91,
        hintFileId: 4999,
      );

      expect(playable.localSize, short, reason: 'localSize 是实测，不是声明');
      expect(playable.isComplete, isFalse,
          reason: '实测字节不到总数，绝不报完整');
    });

    test('a genuinely complete file reads complete', () async {
      final path = sandbox.tempFile('whole.bin');
      await File(path).writeAsBytes(List<int>.filled(4096, 1));
      final api = _Api(<int, FileState>{
        2221: FileState(
          id: 2221,
          size: 4096,
          expectedSize: 4096,
          downloadedSize: 4096,
          isCompleted: true,
          path: path,
          canBeDownloaded: true,
        ),
      });
      final resolver = VideoSourceResolver(
        api: api,
        metadata: _MessageSays(<int, MediaRecord>{91: _record(91, 2221)}),
        diagnostics: StreamingDiagnostics(),
      );

      final playable = await resolver.resolvePlayableFile(
        7,
        91,
        hintFileId: 4999,
      );

      expect(playable.localSize, 4096);
      expect(playable.isComplete, isTrue);
      expect(playable.localPath, path);
    });
  });
}
