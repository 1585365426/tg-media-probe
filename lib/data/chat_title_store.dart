import 'dart:convert';

import 'package:path/path.dart' as p;

import '../storage/file_ops.dart';

/// chatId → channel title, cached so the feed can print and search "频道名称"
/// without a TDLib round-trip per row.
///
/// Stored next to the index (`<index zone>/chats.json`), i.e. inside the
/// protected zone. Titles are Telegram-side metadata, not secrets, but losing
/// them would leave every category chip labelled "未知频道".
class ChatTitleStore {
  ChatTitleStore({required this.directory, required this.ops});

  final String directory;
  final FileOps ops;

  String get filePath => p.join(directory, 'chats.json');
  String get _tmpPath => '$filePath.tmp';

  final Map<int, String> _titles = <int, String>{};
  bool _opened = false;

  bool get isOpen => _opened;
  int get count => _titles.length;

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    try {
      await ops.createDirectory(directory);
      if (!await ops.exists(filePath)) return;
      final decoded = jsonDecode(await ops.readAsString(filePath));
      if (decoded is! Map) return;
      final items = decoded['items'];
      if (items is! Map) return;
      items.forEach((key, value) {
        final id = int.tryParse('$key');
        if (id != null && value is String && value.isNotEmpty) {
          _titles[id] = value;
        }
      });
    } catch (_) {
      // Corrupt cache: fall back to "未知频道" labels, rewrite on next sync.
    }
  }

  String? titleOf(int chatId) => _titles[chatId];

  /// Display label, never null so call sites do not sprinkle `?? '未知'`.
  String labelOf(int chatId) => _titles[chatId] ?? '频道 $chatId';

  /// Only channels that actually have an indexed row should appear as category
  /// chips; a channel with a title but no media would be a dead filter.
  List<({int chatId, String title})> categoriesFor(Iterable<int> chatIds) {
    final seen = <int>{};
    final result = <({int chatId, String title})>[];
    for (final id in chatIds) {
      if (!seen.add(id)) continue;
      result.add((chatId: id, title: labelOf(id)));
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return result;
  }

  Future<void> putAll(Map<int, String> titles) async {
    await open();
    var changed = false;
    titles.forEach((id, title) {
      if (title.isEmpty) return;
      if (_titles[id] != title) {
        _titles[id] = title;
        changed = true;
      }
    });
    if (!changed) return;
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await ops.createDirectory(directory);
      await ops.writeAsString(
        _tmpPath,
        jsonEncode(<String, Object?>{
          'v': 1,
          'items': _titles.map((k, v) => MapEntry('$k', v)),
        }),
      );
      await ops.rename(_tmpPath, filePath);
    } catch (_) {
      // Non-fatal: the next successful sync retries the write.
    }
  }
}
