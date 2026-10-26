import 'dart:convert';

import 'package:path/path.dart' as p;

import '../storage/file_ops.dart';
import 'media_record.dart';

/// Per-channel sync bookmark. `newest` is the highest message id ever indexed,
/// `oldest` the lowest — together they define the window covered by the mirror
/// so incremental sync knows where to resume instead of re-pulling history.
class ChannelWatermark {
  const ChannelWatermark({
    required this.chatId,
    this.newestMessageId,
    this.oldestMessageId,
    this.updatedAtUnix = 0,
  });

  final int chatId;
  final int? newestMessageId;
  final int? oldestMessageId;
  final int updatedAtUnix;

  Map<String, Object?> toJson() => <String, Object?>{
        'chat': chatId,
        if (newestMessageId != null) 'newest': newestMessageId,
        if (oldestMessageId != null) 'oldest': oldestMessageId,
        if (updatedAtUnix != 0) 'at': updatedAtUnix,
      };

  static ChannelWatermark fromJson(Map<String, Object?> json) {
    final chat = json['chat'];
    return ChannelWatermark(
      chatId: chat is int ? chat : int.tryParse('$chat') ?? 0,
      newestMessageId: json['newest'] is int ? json['newest']! as int : null,
      oldestMessageId: json['oldest'] is int ? json['oldest']! as int : null,
      updatedAtUnix: json['at'] is int ? json['at']! as int : 0,
    );
  }

  @override
  String toString() =>
      'ChannelWatermark(chat=$chatId newest=$newestMessageId oldest=$oldestMessageId)';
}

class IndexPage {
  const IndexPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<MediaRecord> items;
  final String? nextCursor;
  final bool hasMore;

  static const IndexPage empty =
      IndexPage(items: <MediaRecord>[], nextCursor: null, hasMore: false);
}

/// Append-only local mirror of Telegram media metadata.
///
/// Storage format is a line-delimited journal plus a periodic snapshot:
///
/// * `media_journal.jsonl` — one JSON op per line (`m` upsert, `f` favourite,
///   `w` watermark, `rm` local removal). Appends are O(1).
/// * `media_snapshot.json` — compacted state. Written to `.tmp` and renamed
///   over the live file, then the journal is truncated, so a crash mid-compact
///   leaves either the old snapshot+journal or the new snapshot.
///
/// Deliberately not SQLite: a single implementation that runs identically in
/// unit tests and on device, with no plugin and no native code in the safety
/// path. Complexity is O(1) per append, O(n log n) for the first sort after a
/// change, O(log n + page) per keyset page.
class IndexStore {
  IndexStore({
    required this.directory,
    required this.ops,
    this.compactionThreshold = 2000,
  });

  final String directory;
  final FileOps ops;
  final int compactionThreshold;

  static const int schemaVersion = 1;

  final Map<String, MediaRecord> _records = <String, MediaRecord>{};
  final Map<int, ChannelWatermark> _watermarks = <int, ChannelWatermark>{};
  List<MediaRecord> _sorted = <MediaRecord>[];
  bool _sortDirty = true;
  int _journalOps = 0;
  bool _opened = false;
  int _droppedJournalLines = 0;

  String get journalPath => p.join(directory, 'media_journal.jsonl');
  String get snapshotPath => p.join(directory, 'media_snapshot.json');

  int get count => _records.length;
  int get favoriteCount => _records.values.where((r) => r.favorite).length;
  int get channelCount => _watermarks.length;
  bool get isOpen => _opened;

  /// Journal lines that could not be parsed during replay. Non-zero means the
  /// file was damaged; the app keeps working with what it could read.
  int get droppedJournalLines => _droppedJournalLines;

  Future<void> open() async {
    if (_opened) return;
    await ops.createDirectory(directory);
    await _loadSnapshot();
    await _replayJournal();
    _sortDirty = true;
    _opened = true;
  }

  Future<void> _loadSnapshot() async {
    if (!await ops.exists(snapshotPath)) return;
    try {
      final decoded = jsonDecode(await ops.readAsString(snapshotPath));
      if (decoded is! Map) return;
      final records = decoded['records'];
      if (records is List) {
        for (final raw in records) {
          if (raw is! Map) continue;
          final record = MediaRecord.fromJson(raw.cast<String, Object?>());
          if (record != null) _records[record.key] = record;
        }
      }
      final watermarks = decoded['watermarks'];
      if (watermarks is List) {
        for (final raw in watermarks) {
          if (raw is! Map) continue;
          final watermark =
              ChannelWatermark.fromJson(raw.cast<String, Object?>());
          _watermarks[watermark.chatId] = watermark;
        }
      }
    } catch (_) {
      // A corrupt snapshot must not brick the app: fall back to the journal and
      // let the next sync repopulate.
    }
  }

  Future<void> _replayJournal() async {
    if (!await ops.exists(journalPath)) return;
    final content = await ops.readAsString(journalPath);
    for (final line in const LineSplitter().convert(content)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          _applyOp(decoded.cast<String, Object?>());
          _journalOps++;
        } else {
          _droppedJournalLines++;
        }
      } catch (_) {
        _droppedJournalLines++;
      }
    }
  }

  void _applyOp(Map<String, Object?> op) {
    switch (op['op']) {
      case 'm':
        final raw = op['r'];
        if (raw is Map) {
          final record = MediaRecord.fromJson(raw.cast<String, Object?>());
          if (record != null) {
            final existing = _records[record.key];
            _records[record.key] = existing != null && existing.favorite
                ? record.copyWith(favorite: true)
                : record;
            _sortDirty = true;
          }
        }
      case 'f':
        final key = op['k'];
        final value = op['v'];
        if (key is String && value is bool) {
          final existing = _records[key];
          if (existing != null) _records[key] = existing.copyWith(favorite: value);
        }
      case 'w':
        final watermark = ChannelWatermark.fromJson(op);
        final existing = _watermarks[watermark.chatId];
        _watermarks[watermark.chatId] = ChannelWatermark(
          chatId: watermark.chatId,
          newestMessageId:
              watermark.newestMessageId ?? existing?.newestMessageId,
          oldestMessageId:
              watermark.oldestMessageId ?? existing?.oldestMessageId,
          updatedAtUnix: watermark.updatedAtUnix,
        );
      case 'rm':
        final chat = op['chat'];
        if (chat is int) {
          _records.removeWhere((_, record) => record.chatId == chat);
          _sortDirty = true;
        }
    }
  }

  /// Inserts or refreshes records. Returns how many keys were new.
  ///
  /// Existing local favourite flags are preserved: a resync must never silently
  /// un-favourite something the user starred.
  Future<int> upsertAll(Iterable<MediaRecord> records) async {
    final buffer = StringBuffer();
    var inserted = 0;
    for (final record in records) {
      final existing = _records[record.key];
      if (existing == null) {
        inserted++;
      }
      final toStore = existing != null && existing.favorite
          ? record.copyWith(favorite: true)
          : record;
      _records[record.key] = toStore;
      buffer.writeln(jsonEncode(<String, Object?>{
        'op': 'm',
        'r': toStore.toJson(),
      }));
      _journalOps++;
      _sortDirty = true;
    }
    if (buffer.isEmpty) return 0;
    await ops.appendAsString(journalPath, buffer.toString());
    await _maybeCompact();
    return inserted;
  }

  Future<bool> setFavorite({
    required int chatId,
    required int messageId,
    required bool value,
  }) async {
    final key = '$chatId:$messageId';
    final existing = _records[key];
    if (existing == null) return false;
    _records[key] = existing.copyWith(favorite: value);
    await ops.appendAsString(
      journalPath,
      '${jsonEncode(<String, Object?>{'op': 'f', 'k': key, 'v': value})}\n',
    );
    _journalOps++;
    await _maybeCompact();
    return true;
  }

  Future<void> setWatermark({
    required int chatId,
    int? newestMessageId,
    int? oldestMessageId,
    int nowUnix = 0,
  }) async {
    final existing = _watermarks[chatId];
    final merged = ChannelWatermark(
      chatId: chatId,
      newestMessageId: newestMessageId ?? existing?.newestMessageId,
      oldestMessageId: oldestMessageId ?? existing?.oldestMessageId,
      updatedAtUnix: nowUnix,
    );
    _watermarks[chatId] = merged;
    await ops.appendAsString(
      journalPath,
      '${jsonEncode(<String, Object?>{'op': 'w', ...merged.toJson()})}\n',
    );
    _journalOps++;
    await _maybeCompact();
  }

  ChannelWatermark? watermark(int chatId) => _watermarks[chatId];

  /// Removes a channel's rows from the **local mirror only**.
  ///
  /// Nothing here talks to Telegram; there is no TDLib dependency in this file
  /// at all, which is asserted by a test.
  Future<int> removeLocalChannel(int chatId) async {
    final before = _records.length;
    _records.removeWhere((_, record) => record.chatId == chatId);
    _watermarks.remove(chatId);
    _sortDirty = true;
    final removed = before - _records.length;
    if (removed > 0) {
      await ops.appendAsString(
        journalPath,
        '${jsonEncode(<String, Object?>{'op': 'rm', 'chat': chatId})}\n',
      );
      _journalOps++;
      await _maybeCompact();
    }
    return removed;
  }

  /// Keyset pagination, newest first.
  ///
  /// The cursor is opaque to callers; it encodes `(messageDate, messageId)` so
  /// the next page continues exactly where the previous one stopped, without
  /// re-reading the rows already shown.
  Future<IndexPage> page({
    int limit = 50,
    String? cursor,
    bool favoritesOnly = false,
    int? chatId,
  }) async {
    final size = limit.clamp(1, 500);
    _ensureSorted();
    var index = 0;
    if (cursor != null) {
      final parsed = _parseCursor(cursor);
      if (parsed != null) index = _firstIndexBefore(parsed.$1, parsed.$2);
    }

    final items = <MediaRecord>[];
    var hasMore = false;
    var i = index;
    while (i < _sorted.length) {
      final record = _sorted[i];
      i++;
      if (chatId != null && record.chatId != chatId) continue;
      if (favoritesOnly && !record.favorite) continue;
      if (items.length < size) {
        items.add(record);
        continue;
      }
      hasMore = true;
      break;
    }

    return IndexPage(
      items: items,
      nextCursor: hasMore && items.isNotEmpty ? _encodeCursor(items.last) : null,
      hasMore: hasMore,
    );
  }

  /// True when a message id is already mirrored for [chatId].
  bool contains(int chatId, int messageId) =>
      _records.containsKey('$chatId:$messageId');

  /// Rows per channel in **one pass**.
  ///
  /// The channel list needs "N 个视频" for every row; computing that by paging
  /// the store once per channel would be O(channels x rows). One pass is O(rows)
  /// no matter how many channels there are.
  Map<int, int> countByChat({bool videosOnly = true}) {
    final counts = <int, int>{};
    for (final record in _records.values) {
      if (videosOnly && record.kind != MediaKind.video) continue;
      counts[record.chatId] = (counts[record.chatId] ?? 0) + 1;
    }
    return counts;
  }

  /// Counters that must be identical before and after a cache clear.
  Future<Map<String, int>> integritySnapshot() async => <String, int>{
        'index': count,
        'favorites': favoriteCount,
        'channels': channelCount,
      };

  Future<void> compact() async {
    await ops.createDirectory(directory);
    final payload = jsonEncode(<String, Object?>{
      'v': schemaVersion,
      'records': _records.values.map((r) => r.toJson()).toList(),
      'watermarks': _watermarks.values.map((w) => w.toJson()).toList(),
    });
    final tmp = '$snapshotPath.tmp';
    await ops.writeAsString(tmp, payload);
    // Swap, then truncate the journal. If the process dies between these two
    // steps the journal is replayed on top of an identical snapshot, so the
    // worst case is duplicated work, never lost rows.
    await ops.rename(tmp, snapshotPath);
    await ops.writeAsString(journalPath, '');
    _journalOps = 0;
  }

  Future<void> close() async {
    _opened = false;
  }

  Future<void> _maybeCompact() async {
    if (_journalOps <= compactionThreshold + _records.length) return;
    await compact();
  }

  void _ensureSorted() {
    if (!_sortDirty) return;
    _sorted = _records.values.toList()
      ..sort((a, b) {
        final byDate = b.messageDateUnix.compareTo(a.messageDateUnix);
        if (byDate != 0) return byDate;
        return b.messageId.compareTo(a.messageId);
      });
    _sortDirty = false;
  }

  static bool _isOlder(int date, int id, int cursorDate, int cursorId) =>
      date < cursorDate || (date == cursorDate && id < cursorId);

  int _firstIndexBefore(int cursorDate, int cursorId) {
    var low = 0;
    var high = _sorted.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      final record = _sorted[mid];
      if (_isOlder(record.messageDateUnix, record.messageId, cursorDate,
          cursorId)) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }

  static String _encodeCursor(MediaRecord record) => base64Url
      .encode(utf8.encode('${record.messageDateUnix}|${record.messageId}'));

  static (int, int)? _parseCursor(String cursor) {
    try {
      final raw = utf8.decode(base64Url.decode(cursor));
      final parts = raw.split('|');
      if (parts.length != 2) return null;
      final date = int.tryParse(parts[0]);
      final id = int.tryParse(parts[1]);
      if (date == null || id == null) return null;
      return (date, id);
    } catch (_) {
      return null;
    }
  }
}
