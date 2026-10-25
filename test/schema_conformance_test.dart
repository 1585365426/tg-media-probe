import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/td_models.dart';
import 'package:tg_media_probe/td/td_requests.dart';

/// Parses td_api.tl into `type/function -> parameter names`.
///
/// This is the real schema shipped with TDLib, so a passing test means the
/// request maps match the binary that will be linked into the app instead of
/// matching someone's memory of the API.
Map<String, Set<String>> parseSchema(String source) {
  final entries = <String, Set<String>>{};
  final lineRe = RegExp(r'^([a-zA-Z][A-Za-z0-9_]*)\s+(.*?)=\s*([A-Za-z0-9_]+);\s*$');
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//')) continue;
    final match = lineRe.firstMatch(line);
    if (match == null) continue;
    final name = match.group(1)!;
    final params = <String>{};
    for (final token in match.group(2)!.split(RegExp(r'\s+'))) {
      final idx = token.indexOf(':');
      if (idx <= 0) continue;
      params.add(token.substring(0, idx));
    }
    entries[name] = params;
  }
  return entries;
}

/// Fixed 64-hex database key for tests. The device generates its own and
/// keeps it in the Keychain; nothing here is ever used on a real run.
const String testDbKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  final fixture = File('test/fixtures/td_api.tl');
  final schema =
      fixture.existsSync() ? parseSchema(fixture.readAsStringSync()) : <String, Set<String>>{};

  final skipReason = fixture.existsSync()
      ? null
      : 'td_api.tl 未下载：curl -sL -o test/fixtures/td_api.tl '
          'https://raw.githubusercontent.com/tdlib/td/master/td/generate/scheme/td_api.tl';

  group('schema fixture', () {
    test('td_api.tl is present and parsed', () {
      expect(schema.length, greaterThan(1000));
    });
  }, skip: skipReason);

  group('requests conform to td_api.tl', skip: skipReason, () {
    final requests = <Map<String, Object?>>[
      getAuthorizationState(),
      setTdlibParameters(
          apiId: 1,
          apiHash: 'h',
          databaseDirectory: '/d',
          filesDirectory: '/f',
          databaseEncryptionKey: testDbKey),
      setAuthenticationPhoneNumber('+1'),
      checkAuthenticationCode('1'),
      checkAuthenticationPassword('x'),
      getChats(),
      getChat(1),
      getChatHistory(chatId: 1),
      getMessage(chatId: 1, messageId: 2),
      getFile(1),
      downloadFile(fileId: 1),
      cancelDownloadFile(fileId: 1),
      logOut(),
      close(),
      getMe(),
      chatListMain(),
    ];

    for (final request in requests) {
      final type = request['@type'] as String;
      test('$type exists with the fields we send', () {
        expect(schema.containsKey(type), isTrue, reason: '$type not in td_api.tl');
        final allowed = schema[type]!;
        final sent = request.keys
            .where((k) => k != '@type' && k != '@extra')
            .toSet();
        final unknown = sent.difference(allowed);
        expect(unknown, isEmpty,
            reason: '$type sends fields absent from schema: $unknown');
        final missing = allowed.difference(sent);
        expect(missing, isEmpty,
            reason: '$type omits required fields: $missing');
      });
    }
  });

  group('parsed constructors match the schema', skip: skipReason, () {
    test('video exposes size/duration but no rotation field', () {
      final video = schema['video']!;
      expect(video.containsAll(<String>{'duration', 'width', 'height', 'video'}),
          isTrue);
      // Documents a real limitation: rotation must come from the media file.
      expect(video.contains('rotation'), isFalse);
    });

    test('file/localFile carry the download state we read', () {
      expect(schema['file']!.containsAll(<String>{'id', 'size', 'expected_size', 'local'}),
          isTrue);
      expect(
          schema['localFile']!.containsAll(<String>{
            'path',
            'is_downloading_completed',
            'downloaded_size',
            'can_be_downloaded',
          }),
          isTrue);
    });

    test('chat/chatTypeSupergroup carry channel flags we read', () {
      expect(schema['chat']!.containsAll(<String>{'id', 'title', 'type'}),
          isTrue);
      expect(
          schema['chatTypeSupergroup']!.containsAll(<String>{'is_channel'}), isTrue);
    });
  });

  group('model parsing on real schema shape', () {
    final message = <String, Object?>{
      'id': 9001,
      'chat_id': 555,
      'content': <String, Object?>{
        '@type': 'messageVideo',
        'video': <String, Object?>{
          'duration': 93,
          'width': 1920,
          'height': 1080,
          'file_name': 'clip.mp4',
          'mime_type': 'video/mp4',
          'supports_streaming': true,
          'video': <String, Object?>{
            'id': 4242,
            'size': 18000000,
            'expected_size': 18000000,
            'local': <String, Object?>{
              'path': '/data/tgmedia/clip.mp4',
              'is_downloading_completed': true,
              'downloaded_size': 18000000,
            },
          },
        },
      },
    };

    test('VideoMeta reads the fields the chain depends on', () {
      final meta = VideoMeta.fromMessage(message)!;
      expect(meta.width, 1920);
      expect(meta.height, 1080);
      expect(meta.durationSeconds, 93);
      expect(meta.fileId, 4242);
      expect(meta.expectedSize, 18000000);
      expect(meta.isDownloaded, isTrue);
      expect(meta.localPath, '/data/tgmedia/clip.mp4');
      expect(meta.hasRotationInfo, isFalse);
    });

    test('non-video messages yield null instead of throwing', () {
      expect(VideoMeta.fromMessage(<String, Object?>{'content': <String, Object?>{'@type': 'messageText'}}),
          isNull);
    });

    test('auth state raw type round-trips', () {
      final state = AuthState.fromJson(<String, Object?>{
        '@type': 'authorizationStateReady',
      });
      expect(state.stage, AuthStage.ready);
      expect(state.rawType, 'authorizationStateReady');
      expect(
        AuthState.fromJson(<String, Object?>{'@type': 'somethingNew'}).stage,
        AuthStage.unknown,
      );
    });

    test('error responses surface code and message', () {
      final text = errorText(<String, Object?>{
        '@type': 'error',
        'code': 400,
        'message': 'PHONE_NUMBER_INVALID',
      });
      expect(text, contains('400'));
      expect(text, contains('PHONE_NUMBER_INVALID'));
    });
  });
}
