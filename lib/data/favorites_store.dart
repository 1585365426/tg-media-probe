import 'dart:convert';

import 'package:path/path.dart' as p;

import '../storage/file_ops.dart';
import 'media_record.dart';

/// Favourites, stored **separately** from the media index.
///
/// Why a second file instead of a flag inside `IndexStore`:
///
/// * the index is a mirror of Telegram and is legitimately rewritten whenever a
///   channel is resynced or a local channel is dropped (`removeLocalChannel`
///   deletes every row of that chat). A favourite that lived only in that table
///   would disappear when the user cleaned up a channel — which is exactly the
///   "clear cache must not touch favourites" rule being violated by the back
///   door;
/// * `IndexStore.removeLocalChannel` is a supported operation, so favourites
///   need their own durable home that no sync path ever writes to.
///
/// Home: `<index zone>/favorites.json` — inside `StorageZone.indexDb`, which
/// `CacheManager` refuses to delete (see `StorageZoneSafety.isClearedByCacheClear`).
class FavoritesStore {
  FavoritesStore({required this.directory, required this.ops});

  final String directory;
  final FileOps ops;

  String get filePath => p.join(directory, 'favorites.json');
  String get _tmpPath => '$filePath.tmp';

  /// Keyed by `chatId:messageId`, mirroring [MediaRecord.key].
  final Map<String, MediaRecord> _byKey = <String, MediaRecord>{};
  bool _opened = false;

  bool get isOpen => _opened;
  int get count => _byKey.length;

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    try {
      await ops.createDirectory(directory);
      if (!await ops.exists(filePath)) return;
      final decoded = jsonDecode(await ops.readAsString(filePath));
      if (decoded is! Map) return;
      final items = decoded['items'];
      if (items is! List) return;
      for (final raw in items) {
        if (raw is! Map) continue;
        final record = MediaRecord.fromJson(raw.cast<String, Object?>());
        if (record != null) _byKey[record.key] = record;
      }
    } catch (_) {
      // A corrupt file loses the list but must not block startup. The file is
      // left alone so a human can still inspect it.
    }
  }

  bool isFavorite(int chatId, int messageId) =>
      _byKey.containsKey('$chatId:$messageId');

  bool containsKey(String key) => _byKey.containsKey(key);

  /// Newest first — matches the feed order the user just came from.
  List<MediaRecord> all() {
    final items = _byKey.values.toList()
      ..sort((a, b) {
        final byDate = b.messageDateUnix.compareTo(a.messageDateUnix);
        if (byDate != 0) return byDate;
        return b.messageId.compareTo(a.messageId);
      });
    return items;
  }

  /// Adds or refreshes one entry. Returns true when the set actually changed.
  Future<bool> add(MediaRecord record) async {
    await open();
    final key = record.key;
    final existed = _byKey.containsKey(key);
    _byKey[key] = record.copyWith(favorite: true);
    await _flush();
    return !existed;
  }

  /// Removes one entry. Returns true when something was removed.
  Future<bool> remove({required int chatId, required int messageId}) async {
    await open();
    final removed = _byKey.remove('$chatId:$messageId') != null;
    if (removed) await _flush();
    return removed;
  }

  Future<bool> toggle(MediaRecord record) async {
    final key = record.key;
    if (_byKey.containsKey(key)) {
      await remove(chatId: record.chatId, messageId: record.messageId);
      return false;
    }
    await add(record);
    return true;
  }

  /// Keys whose record is gone from the mirror. Used by the merge path so the
  /// favourites list keeps working even if the index was rebuilt.
  Iterable<String> get keys => _byKey.keys;

  Future<void> _flush() async {
    final payload = jsonEncode(<String, Object?>{
      'v': 1,
      'items': _byKey.values.map((r) => r.toJson()).toList(),
    });
    await ops.createDirectory(directory);
    // Atomic swap: a crash mid-write leaves the previous list, never a
    // half-written one.
    await ops.writeAsString(_tmpPath, payload);
    await ops.rename(_tmpPath, filePath);
  }
}
