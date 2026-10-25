import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/td/td_requests.dart';

void main() {
  group('TDLib request builders', () {
    test('setTdlibParameters carries every required field', () {
      final request = setTdlibParameters(
        apiId: 12345,
        apiHash: 'hash',
        databaseDirectory: '/db',
        filesDirectory: '/files',
      );
      expect(request['@type'], 'setTdlibParameters');
      expect(request['api_id'], 12345);
      expect(request['api_hash'], 'hash');
      expect(request['use_test_dc'], isFalse);
      expect(request['use_file_database'], isTrue);
      expect(request['use_message_database'], isTrue);
      expect(request['database_directory'], '/db');
      expect(request['files_directory'], '/files');
    });

    test('getChats uses chatListMain and an explicit limit', () {
      final request = getChats(limit: 200);
      expect(request['@type'], 'getChats');
      expect(request['limit'], 200);
      expect((request['chat_list'] as Map)['@type'], 'chatListMain');
    });

    test('getChatHistory default starts from the newest message', () {
      final request = getChatHistory(chatId: 42);
      expect(request['chat_id'], 42);
      expect(request['from_message_id'], 0);
      expect(request['offset'], 0);
      expect(request['limit'], 50);
      expect(request['only_local'], isFalse);
    });

    test('downloadFile asks for the whole file from offset 0', () {
      final request = downloadFile(fileId: 7);
      expect(request['file_id'], 7);
      expect(request['offset'], 0);
      expect(request['limit'], 0);
      expect(request['synchronous'], isFalse);
    });

    test('auth builders pass the raw user input untouched', () {
      expect(setAuthenticationPhoneNumber('+8613800000000')['phone_number'],
          '+8613800000000');
      expect(checkAuthenticationCode('12345')['code'], '12345');
      expect(checkAuthenticationPassword('p')['password'], 'p');
      expect(
        ((setAuthenticationPhoneNumber('+1')['settings']) as Map)['@type'],
        'phoneNumberAuthenticationSettings',
      );
    });

    test('no builder asks TDLib to mutate cloud data', () {
      final all = <Map<String, Object?>>[
        setTdlibParameters(
            apiId: 1,
            apiHash: 'h',
            databaseDirectory: '/d',
            filesDirectory: '/f'),
        getAuthorizationState(),
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
      ];
      const mutating = <String>{
        'deleteMessages',
        'deleteChatHistory',
        'deleteChat',
        'deleteMessage',
        'leaveChat',
        'sendMessage',
        'forwardMessages',
        'sendVideo',
        'sendPhoto',
        'editMessageText',
        'editMessageCaption',
        'editMessageMedia',
        'editMessageReplyMarkup',
      };
      for (final request in all) {
        expect(mutating.contains(request['@type']), isFalse,
            reason: '${request['@type']} is a cloud write and must not exist');
      }
    });
  });
}
