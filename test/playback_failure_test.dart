/// One failure vocabulary for the whole playback layer.
///
/// The device reports that started this work all said the same thing —
/// "网络不可用" — for four different problems: a stalled download, an AVPlayer
/// item that never became ready, a file TDLib had lost, and a video whose
/// codec this phone does not have. Only the first is about the network, and
/// only the first two are worth a retry button.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/playback/playback_failure.dart';
import 'package:tg_media_probe/playback/streaming_diagnostics.dart';
import 'package:tg_media_probe/playback/video_source.dart';

void main() {
  group('classification', () {
    test('a stalled transfer is a download stall, not a generic error', () {
      final kind = classifyPlaybackFailure(
        VideoSourceStalled(const Duration(seconds: 15), downloadedBytes: 1),
      );
      expect(kind, PlaybackFailure.downloadStalled);
      expect(kind.code, 'DOWNLOAD_STALLED');
    });

    test('a spent task budget is still about the bytes', () {
      expect(
        classifyPlaybackFailure(VideoSourceTimeout(const Duration(minutes: 10))),
        PlaybackFailure.downloadStalled,
      );
    });

    test('a rejected file id is a missing file', () {
      final kind = classifyPlaybackFailure(
        VideoSourceException('TDLib error 400: FILE_ID_INVALID'),
      );
      expect(kind, PlaybackFailure.fileNotFound);
      expect(kind.retryable, isFalse, reason: '重试同一个失效 id 不会成功');
    });

    test('a TDLib error stays TDLib', () {
      expect(
        classifyPlaybackFailure(
          VideoSourceException('TDLib error 429: Too Many Requests: retry after 30'),
        ),
        PlaybackFailure.tdlibError,
      );
      expect(
        classifyPlaybackFailure(VideoSourceException('CHAT_FORBIDDEN')),
        PlaybackFailure.tdlibError,
      );
    });

    test('an item that never became ready is an init failure', () {
      expect(
        classifyPlaybackFailure(StateError('AVPlayer 20s 内未就绪（无错误信息）')),
        PlaybackFailure.playerInitFailed,
      );
    });

    test('a platform without the bridge is a resource-loading failure', () {
      expect(
        classifyPlaybackFailure(
          Exception('StreamingV2Unavailable: native bridge missing: openSession'),
        ),
        PlaybackFailure.resourceLoading,
      );
    });

    test('a decoder refusal is its own category', () {
      expect(
        classifyPlaybackMessage('此视频无法解码'),
        PlaybackFailure.decoderFailed,
      );
    });

    test('an empty message is unclassified, not "network"', () {
      expect(classifyPlaybackMessage(''), PlaybackFailure.unknown);
      expect(
        classifyPlaybackMessage('something nobody predicted'),
        PlaybackFailure.unknown,
      );
    });
  });

  group('what the user sees', () {
    test('every category has its own sentence', () {
      final messages = PlaybackFailure.values.map((e) => e.message).toSet();
      expect(messages.length, PlaybackFailure.values.length,
          reason: '两类失败共用一句话，等于没有分类');
    });

    test('only the two transport failures are retryable', () {
      expect(PlaybackFailure.downloadStalled.retryable, isTrue);
      expect(PlaybackFailure.resourceLoading.retryable, isTrue);
      expect(PlaybackFailure.decoderFailed.retryable, isFalse);
      expect(PlaybackFailure.fileNotFound.retryable, isFalse);
      expect(PlaybackFailure.requestCancelled.retryable, isFalse);
    });

    test('codes round-trip', () {
      for (final value in PlaybackFailure.values) {
        expect(PlaybackFailure.fromCode(value.code), value);
      }
      expect(PlaybackFailure.fromCode(null), PlaybackFailure.unknown);
      expect(PlaybackFailure.fromCode('NOPE'), PlaybackFailure.unknown);
    });
  });

  group('diagnostics', () {
    test('the failure is recorded once and exported', () {
      final diagnostics = StreamingDiagnostics();
      diagnostics.beginPlay(fileId: 7, streaming: true, chatId: 1, messageId: 2);

      diagnostics.noteFailure(
        PlaybackFailure.decoderFailed,
        message: '此视频无法解码',
      );

      expect(diagnostics.failureKind, PlaybackFailure.decoderFailed);
      expect(diagnostics.failureMessage, '此视频无法解码');
      final json = diagnostics.toJson();
      final failure = json['failure'] as Map<String, Object?>;
      expect(failure['kind'], 'DECODER_FAILED');
      expect(failure['retryable'], isFalse);
      expect(
        diagnostics.acceptanceLines().any((l) => l.contains('DECODER_FAILED')),
        isTrue,
      );
    });

    test('a new play starts with no failure recorded', () {
      final diagnostics = StreamingDiagnostics();
      diagnostics.beginPlay(fileId: 7, streaming: true, chatId: 1, messageId: 2);
      diagnostics.noteFailure(PlaybackFailure.downloadStalled);
      diagnostics.beginPlay(fileId: 8, streaming: true, chatId: 1, messageId: 3);
      expect(diagnostics.failureKind, isNull);
    });
  });
}
