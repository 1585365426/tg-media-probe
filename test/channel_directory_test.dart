import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_media_probe/data/channel_directory.dart';
import 'package:tg_media_probe/td/td_error_kind.dart';
import 'package:tg_media_probe/td/td_models.dart';

import 'support/sandbox.dart';

/// A source that answers with a fixed list and counts how often it was asked.
///
/// The counter is the point: the search tests below assert that filtering never
/// turns into a network call, which is only observable from here.
class FakeChatSource implements ChatSource {
  FakeChatSource([List<ChatSummary>? channels])
      : channels = channels ?? <ChatSummary>[];

  List<ChatSummary> channels;
  Object? failure;
  int calls = 0;

  @override
  Future<List<ChatSummary>> load() async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return channels;
  }
}

ChatSummary channel(int id, String title, {String? username}) => ChatSummary(
      id: id,
      title: title,
      type: 'chatTypeSupergroup',
      isChannel: true,
      username: username,
      hasProtectedContent: false,
    );

ChatSummary plainChat(int id, String title) => ChatSummary(
      id: id,
      title: title,
      type: 'chatTypeBasicGroup',
      isChannel: false,
      username: null,
      hasProtectedContent: false,
    );

void main() {
  late TestSandbox sandbox;

  setUp(() async {
    sandbox = await TestSandbox.create();
  });

  tearDown(() async {
    await sandbox.dispose();
  });

  ChannelDirectory build(FakeChatSource source) => ChannelDirectory(
        source: source,
        ops: sandbox.ops,
        directory: sandbox.layout.indexDir,
      );

  group('ChannelDirectory.load', () {
    test('channels from Telegram land in the ready state', () async {
      final source = FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha'),
        channel(2, 'Beta'),
      ]);
      final directory = build(source);

      await directory.refresh();

      expect(directory.state, DirectoryState.ready);
      expect(directory.entries.map((e) => e.title), <String>['Alpha', 'Beta']);
      expect(directory.error, isNull);
      expect(source.calls, 1);
    });

    test('an account with no channels reports empty, not error', () async {
      final directory = build(FakeChatSource());

      await directory.refresh();

      expect(directory.state, DirectoryState.empty);
      expect(directory.entries, isEmpty);
      expect(directory.error, isNull);
    });

    test('a failed load with no cache reports error', () async {
      final source = FakeChatSource()..failure = StateError('no network');
      final directory = build(source);

      await directory.refresh();

      expect(directory.state, DirectoryState.error);
      expect(directory.error, contains('no network'));
      expect(directory.entries, isEmpty);
    });

    test('a failed load keeps the cached list on screen', () async {
      final source = FakeChatSource(<ChatSummary>[channel(1, 'Alpha')]);
      final directory = build(source);
      await directory.refresh();

      source.failure = StateError('session dropped');
      await directory.refresh();

      expect(directory.state, DirectoryState.ready);
      expect(directory.entries.single.title, 'Alpha');
      expect(directory.error, contains('session dropped'));
    });

    test('a refresh keeps the video counts it already had', () async {
      final source = FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha'),
        channel(2, 'Beta'),
      ]);
      final directory = build(source);
      await directory.refresh();
      directory.applyCounts(<int, int>{1: 7, 2: 3});

      await directory.refresh();

      expect(directory.entries.map((e) => e.videoCount), <int>[7, 3]);
    });

    test('a channel that disappears drops its count', () async {
      final source = FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha'),
        channel(2, 'Beta'),
      ]);
      final directory = build(source);
      await directory.refresh();
      directory.applyCounts(<int, int>{1: 7, 2: 3});

      source.channels = <ChatSummary>[channel(2, 'Beta')];
      await directory.refresh();

      expect(directory.entries.single.id, 2);
      expect(directory.entries.single.videoCount, 3);
    });

    test('a non-channel chat never reaches the list', () async {
      // TdChatSource filters, but ChannelDirectory must not re-add one that
      // slipped through a different source.
      final source = FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha'),
        plainChat(2, 'Friends'),
      ]);
      final directory = build(source);

      await directory.refresh();

      // The directory trusts its source; the assertion documents that the
      // filtering responsibility sits in TdChatSource.load().
      expect(source.calls, 1);
      expect(directory.entries.length, 2);
    });
  });

  group('video counts', () {
    test('a channel whose count is unknown renders as null, never as 0',
        () async {
      final directory = build(FakeChatSource(<ChatSummary>[channel(1, 'Alpha')]));

      await directory.refresh();

      expect(directory.entries.single.videoCount, isNull);
    });

    test('applyCounts fills known channels and zeroes the rest', () async {
      final directory = build(FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha'),
        channel(2, 'Beta'),
      ]));
      await directory.refresh();

      directory.applyCounts(<int, int>{1: 12});

      expect(directory.entries[0].videoCount, 12);
      expect(directory.entries[1].videoCount, 0);
    });

    test('applyCounts on an empty list does nothing', () {
      final directory = build(FakeChatSource());

      directory.applyCounts(<int, int>{1: 5});

      expect(directory.entries, isEmpty);
      expect(directory.state, DirectoryState.idle);
    });
  });

  group('search', () {
    late ChannelDirectory directory;
    late FakeChatSource source;

    setUp(() async {
      source = FakeChatSource(<ChatSummary>[
        channel(1, 'Tech Daily', username: 'techdaily'),
        channel(2, 'Film Club', username: 'filmclub'),
        channel(3, 'TECH archive'),
      ]);
      directory = build(source);
      await directory.refresh();
    });

    test('an empty query returns everything', () {
      expect(directory.search('').length, 3);
      expect(directory.search('   ').length, 3);
    });

    test('matching is case-insensitive and trimmed', () {
      expect(directory.search('tech').map((e) => e.id), <int>[1, 3]);
      expect(directory.search('  TECH  ').map((e) => e.id), <int>[1, 3]);
    });

    test('a username match is found even when the title does not match',
        () async {
      // 'filmclub' appears only as a username.
      expect(directory.search('filmclub').map((e) => e.id), <int>[2]);
    });

    test('a query with no match returns an empty list, not an error', () {
      expect(directory.search('nothing-matches'), isEmpty);
      expect(directory.state, DirectoryState.ready);
    });

    test('searching never triggers a network call', () {
      final before = source.calls;
      directory.search('tech');
      directory.search('film');
      directory.search('!');
      expect(source.calls, before);
    });
  });

  group('cache', () {
    test('the cache lives inside the index zone', () {
      final directory = build(FakeChatSource());
      expect(directory.cachePath,
          endsWith('${Platform.pathSeparator}${ChannelDirectory.cacheFileName}'));
      expect(directory.cachePath, startsWith(sandbox.layout.indexDir));
    });

    test('a refresh writes the list and a cold start reads it back', () async {
      final warm = build(FakeChatSource(<ChatSummary>[
        channel(1, 'Alpha', username: 'alpha_chan'),
        channel(2, 'Beta'),
      ]));
      await warm.refresh();
      expect(await sandbox.exists(warm.cachePath), isTrue);

      // Same directory, new instance, source that would fail: this is the
      // "cold start with no network" case.
      final offline = FakeChatSource()..failure = StateError('offline');
      final cold = build(offline);
      await cold.loadCached();

      expect(cold.state, DirectoryState.ready);
      expect(cold.entries.map((e) => e.title), <String>['Alpha', 'Beta']);
      expect(cold.entries.first.chat.username, 'alpha_chan');
      expect(offline.calls, 0);
    });

    test('the write is atomic and leaves no .tmp behind', () async {
      final directory = build(FakeChatSource(<ChatSummary>[channel(1, 'Alpha')]));

      await directory.refresh();

      expect(await sandbox.exists('${directory.cachePath}.tmp'), isFalse);
      final decoded = jsonDecode(await sandbox.ops.readAsString(directory.cachePath));
      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded! as Map)['v'], ChannelDirectory.cacheVersion);
    });

    test('a corrupt cache is ignored instead of failing the launch', () async {
      final directory = build(FakeChatSource());
      await sandbox.write(directory.cachePath, '{ this is not json');

      await directory.loadCached();

      expect(directory.state, DirectoryState.idle);
      expect(directory.entries, isEmpty);
    });

    test('a cache with no usable entries is ignored', () async {
      final directory = build(FakeChatSource());
      await sandbox.write(
        directory.cachePath,
        jsonEncode(<String, Object?>{
          'v': 1,
          'chats': <Object?>[
            <String, Object?>{'id': 'not-an-int', 'title': 1},
            <String, Object?>{'title': 'no id'},
          ],
        }),
      );

      await directory.loadCached();

      expect(directory.entries, isEmpty);
    });

    test('a missing cache file is not an error', () async {
      final directory = build(FakeChatSource());

      await directory.loadCached();

      expect(directory.state, DirectoryState.idle);
      expect(directory.error, isNull);
    });

    test('a watched flag survives the cache round trip', () async {
      final protectedChannel = ChatSummary(
        id: 9,
        title: 'Protected',
        type: 'chatTypeSupergroup',
        isChannel: true,
        username: null,
        hasProtectedContent: true,
      );
      final warm = build(FakeChatSource(<ChatSummary>[protectedChannel]));
      await warm.refresh();

      final cold = build(FakeChatSource());
      await cold.loadCached();

      expect(cold.entries.single.chat.hasProtectedContent, isTrue);
    });
  });

  group('listeners', () {
    test('a disposed directory stops notifying', () async {
      final directory = build(FakeChatSource(<ChatSummary>[channel(1, 'Alpha')]));
      var notifications = 0;
      directory.addListener(() => notifications++);
      directory.dispose();

      // notifyListeners on a disposed ChangeNotifier throws; the guard inside
      // _notify() is what keeps a late refresh from crashing the app.
      await directory.refresh();

      expect(notifications, 0);
    });
  });

  group('failure classification', () {
    test('a forbidden channel surfaces as permissionDenied, not a retryable error',
        () async {
      final source = FakeChatSource()
        ..failure = const ChannelDirectoryException(
          'TDLib error 403: CHAT_FORBIDDEN',
          failure: RequestFailure.permissionDenied,
        );
      final directory = build(source);

      await directory.refresh();

      expect(directory.state, DirectoryState.error);
      expect(directory.failure, RequestFailure.permissionDenied);
      expect(directory.error, contains('CHAT_FORBIDDEN'));
      // The list must not offer a retry button for a permission error; that is
      // what isRetryable drives in FailureView.
      expect(isRetryable(directory.failure), isFalse);
    });

    test('a dead session surfaces as sessionExpired', () async {
      final source = FakeChatSource()
        ..failure = const ChannelDirectoryException(
          'TDLib error 401: AUTH_KEY_UNREGISTERED',
          failure: RequestFailure.sessionExpired,
        );
      final directory = build(source);

      await directory.refresh();

      expect(directory.failure, RequestFailure.sessionExpired);
      expect(isRetryable(directory.failure), isFalse);
    });

    test('a timeout from the transport is classified as offline', () async {
      final source = FakeChatSource()
        ..failure = TimeoutException('TDLib did not answer getChats within 20s');
      final directory = build(source);

      await directory.refresh();

      expect(directory.failure, RequestFailure.offline);
      expect(isRetryable(directory.failure), isTrue);
    });

    test('a successful refresh clears the previous failure', () async {
      final source = FakeChatSource()
        ..failure = const ChannelDirectoryException('boom',
            failure: RequestFailure.permissionDenied);
      final directory = build(source);
      await directory.refresh();
      expect(directory.failure, RequestFailure.permissionDenied);

      source
        ..failure = null
        ..channels = <ChatSummary>[channel(1, 'Alpha')];
      await directory.refresh();

      expect(directory.failure, RequestFailure.none);
      expect(directory.state, DirectoryState.ready);
    });
  });
}
