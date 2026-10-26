import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../app/app_services.dart';
import '../../data/media_record.dart';
import '../../platform/orientation_controller.dart';
import '../video/single_video_page.dart';

/// Favourites list.
///
/// Reads straight from [FavoritesStore] (`favorites.json`, inside the protected
/// index zone) and never from the media mirror: dropping a channel from the
/// mirror must not empty this screen.
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({
    super.key,
    required this.services,
    required this.model,
  });

  final AppServices services;
  final AppModel model;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<MediaRecord> _items = const <MediaRecord>[];

  /// This is a portrait list. Locking it explicitly means it stays upright even
  /// if some earlier page left the native side in landscape — and, unlike
  /// relying on that page's own reset, it also covers the device being held
  /// sideways when the list is opened.
  final OrientationBridge _orientation = OrientationBridge();

  @override
  void initState() {
    super.initState();
    _orientation.setMode(ScreenOrientationMode.lockedPortrait);
    _reload();
  }

  @override
  void dispose() {
    _orientation.resetToSystem();
    super.dispose();
  }

  void _reload() {
    setState(() => _items = widget.services.favorites.all());
  }

  Future<void> _remove(MediaRecord record) async {
    await widget.services.favorites.remove(
      chatId: record.chatId,
      messageId: record.messageId,
    );
    widget.model.hydrateFavorites();
    _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已取消收藏')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('我的收藏（${_items.length}）'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.star_border, size: 46, color: theme.disabledColor),
                    const SizedBox(height: 12),
                    Text('还没有收藏', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      '在视频页点右侧的星标即可收藏。收藏独立保存，清理缓存不会删除。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final record = _items[index];
                final title = widget.services.chatTitles.labelOf(record.chatId);
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(
                        Icons.play_arrow,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: Text(
                      (record.caption ?? '').isNotEmpty
                          ? record.caption!
                          : '$title · 消息 ${record.messageId}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      <String>[
                        title,
                        _duration(record.durationSeconds),
                        if (record.width != null && record.height != null)
                          '${record.width}x${record.height}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      tooltip: '取消收藏',
                      icon: const Icon(Icons.star, color: Colors.amber),
                      onPressed: () => _remove(record),
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SingleVideoPage(
                            services: widget.services,
                            model: widget.model,
                            record: record,
                          ),
                        ),
                      );
                      if (mounted) _reload();
                    },
                  ),
                );
              },
            ),
    );
  }

  static String _duration(int? seconds) {
    if (seconds == null) return '时长未知';
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
  }
}
