import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../playback/playback_timeline.dart';
import '../../storage/storage_layout.dart';
import '../favorites/favorites_page.dart';
import '../probe_page.dart';
import '../settings/settings_page.dart';

/// Tools tab: entry points plus a storage summary.
///
/// The storage card intentionally labels the protected zones as "受保护" instead
/// of showing a delete affordance: cache clearing lives behind one button in
/// 设置, and nothing on this page can remove a user file.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  Map<StorageZone, int>? _usage;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_usage == null && !_loading) _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    final services = AppScope.read(context).services;
    setState(() => _loading = true);
    try {
      final usage = await services.cache.usage(includeProtected: true);
      if (!mounted) return;
      setState(() => _usage = usage);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final model = scope.model;
    final services = scope.services;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
      children: <Widget>[
        Card(
          child: Column(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                subtitle: const Text('主题、缓存清理、应用密码锁'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(services: services),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('我的收藏'),
                subtitle: Text('${services.favorites.count} 个视频 · 清理缓存不会影响收藏'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FavoritesPage(services: services, model: model),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: const Text('诊断页（只读链路自检）'),
                subtitle: const Text('逐项验证 TDLib 加载、登录、读取、下载、播放'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    // Hand over the live client when one exists: TDLib locks its
                    // database per client, so a second instance would die with
                    // error 400. Null means not signed in yet, and the probe
                    // then opens its own without contention.
                    builder: (_) => ProbePage(reuseClient: services.client),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.sd_storage_outlined,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('存储占用（四区隔离）', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    IconButton(
                      onPressed: _loading ? null : _refreshUsage,
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: '重新统计',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ..._zoneRows(theme),
                const SizedBox(height: 8),
                Text(
                  '只有「临时运行缓存」会被清理按钮删除；下载文件、媒体索引、账号与会话数据永不参与清理。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.timer_outlined,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('最近播放耗时', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        PlaybackTimelineLog.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear_all, size: 18),
                      tooltip: '清空记录',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ..._timelineRows(theme),
                const SizedBox(height: 8),
                Text(
                  '每次点开视频记录一段：stream-url 是本地流地址发布耗时，'
                  'player-load 是播放器就绪耗时，download 是整段下载耗时。'
                  '走流式播放时没有 download 一段。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('只读声明', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  '本应用仅调用 TDLib 的读取接口：读取会话、读取历史、读取文件元数据、下载文件到本机。'
                  '不包含发送消息、编辑消息、删除消息、退出频道等任何写操作。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _timelineRows(ThemeData theme) {
    final recent = PlaybackTimelineLog.recent;
    if (recent.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('还没有播放记录', style: theme.textTheme.bodySmall),
        ),
      ];
    }
    final outcomeLabel = <String, String>{
      'stream': '流式播放',
      'file': '本地文件',
      'failed': '失败',
      'pending': '未完成',
    };
    return <Widget>[
      for (final timeline in recent.take(5))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${timeline.recordKey} · ${outcomeLabel[timeline.outcome] ?? timeline.outcome}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              Text(
                timeline.summary(),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _zoneRows(ThemeData theme) {
    final usage = _usage;
    if (usage == null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('正在统计…', style: theme.textTheme.bodySmall),
        ),
      ];
    }
    return <Widget>[
      for (final zone in StorageZone.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  zone.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: zone.isClearedByCacheClear
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              Text(
                _formatBytes(usage[zone] ?? -1),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: zone.isClearedByCacheClear
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  zone.isClearedByCacheClear ? '可清理' : '受保护',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
    ];
  }

  static String _formatBytes(int bytes) {
    if (bytes < 0) return '未统计';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
