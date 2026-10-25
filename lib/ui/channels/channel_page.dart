import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../data/channel_loader.dart';
import '../../td/td_models.dart';
import '../login/login_page.dart';

/// Channel tab: sign-in entry point, channel discovery, and the local mirror
/// sync that feeds the video tab.
///
/// Nothing on this page writes to Telegram. Discovery is `getChats` +
/// `getChat`; the sync is `getChatHistory` one bounded page at a time.
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key, this.onOpenVideos});

  /// Called when the user taps a channel: filter the video tab to it and
  /// switch tabs. Owned by the shell.
  final void Function(ChatSummary channel)? onOpenVideos;

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  bool _busy = false;
  String? _error;

  Future<void> _openLogin() async {
    final scope = AppScope.read(context);
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LoginPage(services: scope.services),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      scope.model.markSignedIn(true);
      await _sync();
    }
  }

  Future<void> _sync() async {
    final scope = AppScope.read(context);
    final services = scope.services;
    final model = scope.model;

    if (!services.hasClient) {
      await _openLogin();
      return;
    }
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    model.setSyncing(true, status: '正在读取频道列表…');

    try {
      final loader = ChannelLoader(services.client!);
      final result = await loader.load();
      if (!mounted) return;

      if (result.isFatal) {
        setState(() => _error = result.error);
        model.setSyncing(false, status: '读取频道失败：${result.error}');
        return;
      }

      model.setChannels(result.channels);
      await services.chatTitles.putAll(result.titles);
      if (!mounted) return;

      if (result.channels.isEmpty) {
        model.setSyncing(false,
            status: '扫描 ${result.scannedChats} 个会话，没有找到频道');
        return;
      }

      model.setSyncing(true,
          status: '正在同步 ${result.channels.length} 个频道的历史消息…');
      final report = await services.sync.syncCycle(
        chatIds: result.channels.map((c) => c.id).toList(growable: false),
        pagesPerChannel: 2,
      );
      if (!mounted) return;

      final parts = <String>[
        '同步完成：${report.pages} 页',
        '新增 ${report.insertedRecords} 条',
        '索引共 ${services.index.count} 条',
        if (result.failedChats > 0) '${result.failedChats} 个会话读取失败',
        if (report.errors.isNotEmpty) '${report.errors.length} 个错误',
      ];
      model.setSyncing(false, status: parts.join(' · '));
      if (report.errors.isNotEmpty) {
        setState(() => _error = report.errors.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      model.setSyncing(false, status: '同步中断：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context).model;
    final theme = Theme.of(context);

    if (!model.signedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.lock_clock, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('尚未登录 Telegram', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '登录后可读取你已加入的频道媒体。应用不会发送、编辑或删除任何消息。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _openLogin,
                icon: const Icon(Icons.login),
                label: const Text('登录 Telegram'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _sync,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: <Widget>[
          _statusCard(model, theme),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
          if (model.channels.isEmpty)
            _emptyChannels(theme)
          else
            ...model.channels.map((chat) => _channelTile(chat, theme)),
        ],
      ),
    );
  }

  Widget _statusCard(AppModel model, ThemeData theme) {
    final status = model.syncStatus ?? '尚未同步，下拉或点右下角按钮开始';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.sync, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('本地索引', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (model.syncing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(status, style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                _metric('频道', '${model.channels.length}', theme),
                _metric('索引', '${AppScope.read(context).services.index.count}', theme),
                _metric('收藏',
                    '${AppScope.read(context).services.favorites.count}', theme),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : _sync,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(_busy ? '同步中…' : '同步频道与消息'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, ThemeData theme) => Padding(
        padding: const EdgeInsets.only(right: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value, style: theme.textTheme.titleMedium),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      );

  Widget _emptyChannels(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: <Widget>[
            Icon(Icons.forum_outlined, size: 40, color: theme.disabledColor),
            const SizedBox(height: 10),
            Text('还没有频道数据', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              '点击「同步频道与消息」读取你已加入的频道',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );

  Widget _channelTile(ChatSummary chat, ThemeData theme) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              chat.title.isEmpty ? '?' : chat.title.characters.first,
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
          ),
          title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            <String>[
              'id ${chat.id}',
              if (chat.username != null) '@${chat.username}',
              if (chat.hasProtectedContent) '受保护内容',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onOpenVideos == null
              ? null
              : () => widget.onOpenVideos!(chat),
        ),
      );
}
