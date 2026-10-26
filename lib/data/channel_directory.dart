/// The channel list the first tab shows.
///
/// Two sources of truth are merged here and nowhere else:
/// * Telegram, through [ChatSource] — which channels the account can see;
/// * the local mirror, through a per-channel video count.
///
/// The list is cached as JSON inside the index zone so the first tab still has
/// titles when the network is down. A cache read never overwrites a live load,
/// and a failed live load keeps whatever was cached.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/file_ops.dart';
import '../td/td_client.dart';
import '../td/td_error_kind.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';

/// Where the channel list comes from. Abstracted for tests.
abstract class ChatSource {
  Future<List<ChatSummary>> load();
}

/// Read-only implementation: `getChats` then `getChat` per id.
///
/// TDLib's `getChats` returns ids only, and the channel flag lives on the chat
/// object, so one `getChat` per id is unavoidable. The count is capped so a
/// 500-chat account cannot turn the first tab into a thousand requests.
class TdChatSource implements ChatSource {
  TdChatSource(
    this.client, {
    this.limit = 100,
    this.timeout = const Duration(seconds: 20),
  });

  final TdClient client;
  final int limit;
  final Duration timeout;

  @override
  Future<List<ChatSummary>> load() async {
    final response = await client.request(getChats(limit: limit), timeout: timeout);
    final error = errorText(response);
    if (error != null) {
      throw ChannelDirectoryException(error,
          failure: classifyFailure(response));
    }

    final ids = chatIdsFromResponse(response);
    final channels = <ChatSummary>[];
    for (final id in ids) {
      try {
        final chatResponse =
            await client.request(getChat(id), timeout: timeout);
        final chat = chatFromResponse(chatResponse);
        if (chat != null && chat.isChannel) channels.add(chat);
      } on Object {
        // One unreadable chat must not blank the whole list; the rest still
        // deserve to be shown.
        continue;
      }
    }
    return channels;
  }
}

class ChannelDirectoryException implements Exception {
  const ChannelDirectoryException(this.message, {this.failure = RequestFailure.generic});

  final String message;

  /// What kind of failure this is, so the list can show "没有权限" instead of a
  /// generic error with a retry button that can only fail again.
  final RequestFailure failure;

  @override
  String toString() => 'ChannelDirectoryException: $message';
}

enum DirectoryState { idle, loading, ready, empty, error }

class ChannelEntry {
  const ChannelEntry({
    required this.chat,
    this.videoCount,
  });

  final ChatSummary chat;

  /// Videos indexed for this channel, or null when the count is not known yet.
  /// The UI shows "统计中" for null and never renders a confident 0 (§3).
  final int? videoCount;

  int get id => chat.id;
  String get title => chat.title;

  ChannelEntry copyWith({int? videoCount}) =>
      ChannelEntry(chat: chat, videoCount: videoCount ?? this.videoCount);
}

class ChannelDirectory extends ChangeNotifier {
  ChannelDirectory({
    required this.source,
    required this.ops,
    required this.directory,
  });

  static const String cacheFileName = 'channels.json';
  static const int cacheVersion = 1;

  final ChatSource source;
  final FileOps ops;

  /// The index zone. Protected: nothing in the cache-clear path can reach it.
  final String directory;

  final List<ChannelEntry> _entries = <ChannelEntry>[];
  DirectoryState _state = DirectoryState.idle;
  String? _error;
  RequestFailure _failure = RequestFailure.none;
  bool _disposed = false;

  List<ChannelEntry> get entries => List<ChannelEntry>.unmodifiable(_entries);
  DirectoryState get state => _state;
  String? get error => _error;

  /// Why the last refresh failed. [RequestFailure.none] when it did not.
  RequestFailure get failure => _failure;
  bool get isEmpty => _entries.isEmpty;

  String get cachePath => p.join(directory, cacheFileName);

  Map<int, String> get titles => <int, String>{
        for (final entry in _entries) entry.id: entry.title,
      };

  /// Reads the cached list. Safe to call before [refresh] so the first tab
  /// paints something immediately.
  Future<void> loadCached() async {
    try {
      if (!await ops.exists(cachePath)) return;
      final decoded = jsonDecode(await ops.readAsString(cachePath));
      if (decoded is! Map) return;
      final chats = decoded['chats'];
      if (chats is! List) return;
      final restored = <ChannelEntry>[];
      for (final raw in chats) {
        if (raw is! Map) continue;
        final map = raw.cast<String, Object?>();
        final id = map['id'];
        final title = map['title'];
        if (id is! int || title is! String) continue;
        restored.add(ChannelEntry(
          chat: ChatSummary(
            id: id,
            title: title,
            type: map['type'] is String ? map['type']! as String : 'chatTypeSupergroup',
            isChannel: true,
            username: map['username'] is String ? map['username']! as String : null,
            hasProtectedContent: map['protected'] == true,
          ),
        ));
      }
      if (restored.isEmpty) return;
      _entries
        ..clear()
        ..addAll(restored);
      _state = DirectoryState.ready;
      _notify();
    } on Object {
      // A corrupt cache is not an error state: the live load will replace it.
    }
  }

  Future<void> refresh() async {
    _state = DirectoryState.loading;
    _error = null;
    _failure = RequestFailure.none;
    _notify();
    try {
      final channels = await source.load();
      final previous = <int, int?>{
        for (final entry in _entries) entry.id: entry.videoCount,
      };
      _entries
        ..clear()
        ..addAll(channels.map((chat) => ChannelEntry(
              chat: chat,
              videoCount: previous[chat.id],
            )));
      _state = _entries.isEmpty ? DirectoryState.empty : DirectoryState.ready;
      await _writeCache();
    } on Object catch (e) {
      _error = e is ChannelDirectoryException ? e.message : '$e';
      _failure = e is ChannelDirectoryException
          ? e.failure
          : classifyFailure(e);
      // Cached content is kept on purpose: an error banner over a stale list is
      // more useful than an empty screen.
      _state = _entries.isEmpty ? DirectoryState.error : DirectoryState.ready;
    }
    _notify();
  }

  /// Attaches per-channel video counts (from `IndexStore.countByChat()`).
  void applyCounts(Map<int, int> counts) {
    if (_entries.isEmpty) return;
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      _entries[i] = entry.copyWith(videoCount: counts[entry.id] ?? 0);
    }
    _notify();
  }

  /// Local name filter. Never triggers a cloud search — the spec forbids it and
  /// there is no TDLib call in this method to forget about.
  List<ChannelEntry> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return entries;
    return _entries.where((entry) {
      if (entry.title.toLowerCase().contains(needle)) return true;
      final username = entry.chat.username;
      return username != null && username.toLowerCase().contains(needle);
    }).toList();
  }

  Future<void> _writeCache() async {
    try {
      await ops.createDirectory(directory);
      final payload = jsonEncode(<String, Object?>{
        'v': cacheVersion,
        'chats': <Map<String, Object?>>[
          for (final entry in _entries)
            <String, Object?>{
              'id': entry.id,
              'title': entry.title,
              'type': entry.chat.type,
              if (entry.chat.username != null) 'username': entry.chat.username,
              if (entry.chat.hasProtectedContent) 'protected': true,
            },
        ],
      });
      final tmp = '$cachePath.tmp';
      await ops.writeAsString(tmp, payload);
      // Atomic swap: a crash mid-write leaves the previous file intact instead
      // of a truncated JSON the next launch cannot read.
      await ops.rename(tmp, cachePath);
    } on Object {
      // Caching is best-effort; failing to cache must not fail the refresh.
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
