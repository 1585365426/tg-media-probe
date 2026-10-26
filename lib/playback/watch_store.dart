/// Local watch state: how far into each video the user got, and whether it was
/// finished. Local only — nothing here touches Telegram.
///
/// Design rules:
/// * the key is `(chatId, messageId)`, not the list position, so a list that
///   grew by four rows does not shift somebody else's progress onto a different
///   video;
/// * a write failure is swallowed at the call site: losing a resume point must
///   never stop playback;
/// * `completed` is a fact about the last playthrough, not a filter — finished
///   videos stay in the list and stay openable.
library;

import 'dart:convert';

import '../storage/file_ops.dart';

class WatchEntry {
  const WatchEntry({
    required this.chatId,
    required this.messageId,
    required this.positionMs,
    required this.durationMs,
    required this.completed,
    required this.updatedAtUnix,
  });

  factory WatchEntry.fromJson(Map<String, Object?> json) => WatchEntry(
        chatId: json['chat'] as int,
        messageId: json['message'] as int,
        positionMs: (json['position'] as num).toInt(),
        durationMs: (json['duration'] as num?)?.toInt() ?? 0,
        completed: json['completed'] == true,
        updatedAtUnix: (json['updated'] as num?)?.toInt() ?? 0,
      );

  final int chatId;
  final int messageId;
  final int positionMs;
  final int durationMs;
  final bool completed;
  final int updatedAtUnix;

  static String keyOf(int chatId, int messageId) => '$chatId:$messageId';

  String get key => keyOf(chatId, messageId);

  /// Where playback should start.
  ///
  /// Rules, deliberately boring: a finished video starts over; a position of a
  /// few seconds is noise and starts over; a position in the last 5% starts
  /// over (resuming three seconds before the end is a worse experience than
  /// replaying the clip); anything else resumes two seconds early so the user
  /// hears a run-up.
  int get resumePositionMs {
    if (completed) return 0;
    if (positionMs < 3000) return 0;
    if (durationMs > 0 && positionMs >= (durationMs * 0.95).round()) return 0;
    return (positionMs - 2000).clamp(0, positionMs);
  }

  /// True when the entry has nothing worth storing any more.
  bool get isPristine => positionMs == 0 && !completed;

  WatchEntry copyWith({
    int? positionMs,
    int? durationMs,
    bool? completed,
    int? updatedAtUnix,
  }) =>
      WatchEntry(
        chatId: chatId,
        messageId: messageId,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        completed: completed ?? this.completed,
        updatedAtUnix: updatedAtUnix ?? this.updatedAtUnix,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'chat': chatId,
        'message': messageId,
        'position': positionMs,
        'duration': durationMs,
        'completed': completed,
        'updated': updatedAtUnix,
      };
}

class WatchStore {
  WatchStore({
    required this.directory,
    required this.ops,
    this.fileName = 'watch.json',
  });

  final String directory;
  final FileOps ops;
  final String fileName;

  final Map<String, WatchEntry> _entries = <String, WatchEntry>{};
  bool _loaded = false;

  String get path => '$directory/$fileName';

  Map<String, WatchEntry> get entries => Map<String, WatchEntry>.unmodifiable(_entries);

  /// Reads the file once. A corrupt or missing file is an empty state, never a
  /// crash: watch history is a convenience, not data the app cannot live
  /// without.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await ops.exists(path)) return;
      final decoded = jsonDecode(await ops.readAsString(path));
      if (decoded is! Map) return;
      final records = decoded['entries'];
      if (records is! List) return;
      for (final raw in records) {
        if (raw is! Map) continue;
        try {
          final entry = WatchEntry.fromJson(raw.cast<String, Object?>());
          _entries[entry.key] = entry;
        } on Object {
          // One bad row must not drop the whole history.
          continue;
        }
      }
    } on Object {
      // Unreadable file: start empty and overwrite on the next save.
    }
  }

  WatchEntry? read(int chatId, int messageId) =>
      _entries[WatchEntry.keyOf(chatId, messageId)];

  /// Writes one entry. Throws on failure so the caller can decide; the feed
  /// deliberately ignores that error.
  Future<void> save(WatchEntry entry) async {
    await load();
    _entries[entry.key] = entry;
    await _flush();
  }

  Future<void> clear(int chatId, int messageId) async {
    await load();
    final removed = _entries.remove(WatchEntry.keyOf(chatId, messageId));
    if (removed == null) return;
    await _flush();
  }

  /// Runs an update against the existing entry (or a fresh one).
  Future<WatchEntry> upsert(
    int chatId,
    int messageId,
    WatchEntry Function(WatchEntry current, int nowUnix) update, {
    int? nowUnix,
  }) async {
    await load();
    final now = nowUnix ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final current = _entries[WatchEntry.keyOf(chatId, messageId)] ??
        WatchEntry(
          chatId: chatId,
          messageId: messageId,
          positionMs: 0,
          durationMs: 0,
          completed: false,
          updatedAtUnix: now,
        );
    final next = update(current, now);
    _entries[next.key] = next;
    await _flush();
    return next;
  }

  Future<void> _flush() async {
    // Atomic replace: write next to the target, then rename, so a crash cannot
    // leave half a JSON document behind.
    final temp = '$path.tmp';
    final payload = jsonEncode(<String, Object?>{
      'version': 1,
      'entries': _entries.values.map((e) => e.toJson()).toList(),
    });
    await ops.writeAsString(temp, payload);
    await ops.rename(temp, path);
  }
}
