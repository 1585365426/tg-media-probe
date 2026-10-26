/// Channel list (tab 1) and the message list inside one channel.
///
/// Both pages render real data or an explicit state — never a placeholder row.
/// The list is capped by the index, not by memory: the detail page pages the
/// local mirror 30 at a time and pulls more history only when asked.
library;

import 'package:flutter/material.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../data/channel_directory.dart';
import '../data/channel_sync.dart';
import '../data/media_record.dart';
import '../storage/active_files.dart';
import '../util/byte_format.dart';
import 'app_theme.dart';
import 'feed_page.dart';
import '../td/td_error_kind.dart';
import 'status_view.dart';

class ChannelListPage extends StatefulWidget {
  const ChannelListPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.activeFiles,
  });

  final AppSession session;
  final AppPreferences preferences;
  final ActiveFileRegistry activeFiles;

  @override
  State<ChannelListPage> createState() => _ChannelListPageState();
}

class _ChannelListPageState extends State<ChannelListPage> {
  final TextEditingController _query = TextEditingController();
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  void _ensureLoaded() {
    if (_requested) return;
    final directory = widget.session.directory;
    if (directory == null) return;
    _requested = true;
    if (directory.state == DirectoryState.idle) {
      widget.session.refreshDirectory();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('频道'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新频道',
            icon: const Icon(Icons.refresh),
            onPressed: widget.session.busy ? null : widget.session.refreshDirectory,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.pagePadding,
              0,
              AppTheme.pagePadding,
              8,
            ),
            child: TextField(
              controller: _query,
              decoration: InputDecoration(
                isDense: true,
                hintText: '按名称搜索频道（本地）',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _query.clear();
                          setState(() {});
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final directory = widget.session.directory;
          if (directory == null) {
            return const StatusView.loading(title: '正在打开本地索引');
          }
          return ListenableBuilder(
            listenable: directory,
            builder: (context, _) => _buildBody(directory),
          );
        },
      ),
    );
  }

  Widget _buildBody(ChannelDirectory directory) {
    final entries = directory.search(_query.text);

    if (directory.state == DirectoryState.loading && directory.entries.isEmpty) {
      return const StatusView.loading(title: '正在读取频道列表');
    }
    if (directory.state == DirectoryState.error && directory.entries.isEmpty) {
      // Permission and dead-session failures get their own wording and lose the
      // retry button: pressing it would fail the same way every time.
      return FailureView(
        failure: directory.failure,
        detail: directory.error,
        onRetry: widget.session.refreshDirectory,
      );
    }
    if (directory.entries.isEmpty) {
      return StatusView.empty(
        title: '账号未加入任何频道',
        message: '在 Telegram 中加入频道后回到这里刷新。',
        actionLabel: '刷新',
        onAction: widget.session.refreshDirectory,
      );
    }
    if (entries.isEmpty) {
      return const StatusView.empty(
        title: '没有匹配的频道',
        message: '换个关键词试试。',
      );
    }

    return RefreshIndicator(
      onRefresh: widget.session.refreshDirectory,
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) => _ChannelRow(
          entry: entries[index],
          onTap: () => _openChannel(entries[index]),
        ),
      ),
    );
  }

  Future<void> _openChannel(ChannelEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelDetailPage(
          session: widget.session,
          preferences: widget.preferences,
          activeFiles: widget.activeFiles,
          chatId: entry.id,
          title: entry.title,
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.entry, required this.onTap});

  final ChannelEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = entry.videoCount;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: Text(
          entry.title.isEmpty ? '?' : entry.title.characters.first,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        // §3: never show a confident 0 before the count is known.
        count == null ? '统计中' : '$count 个视频',
        style: theme.textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
    );
  }
}

/// Media list inside one channel: paged from the local mirror, with an explicit
/// "sync more" action instead of an endless background walk.
class ChannelDetailPage extends StatefulWidget {
  const ChannelDetailPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.activeFiles,
    required this.chatId,
    required this.title,
  });

  final AppSession session;
  final AppPreferences preferences;
  final ActiveFileRegistry activeFiles;
  final int chatId;
  final String title;

  @override
  State<ChannelDetailPage> createState() => _ChannelDetailPageState();
}

class _ChannelDetailPageState extends State<ChannelDetailPage> {
  final List<MediaRecord> _items = <MediaRecord>[];
  MediaPager? _pager;
  String? _error;
  RequestFailure _failure = RequestFailure.none;
  bool _loading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final store = widget.session.index;
    if (store == null) {
      setState(() {
        _loading = false;
        _error = '本地索引尚未打开';
        // Nothing has been read from Telegram yet; this is a local problem.
        _failure = RequestFailure.generic;
      });
      return;
    }
    _pager = MediaPager(store: store, chatId: widget.chatId, pageSize: 30);
    await _loadMore();
    // Pull a bounded slice of history in the background; the list above is
    // already usable from the mirror, so this never blocks the first paint.
    await _syncMore();
  }

  Future<void> _loadMore() async {
    final pager = _pager;
    if (pager == null) return;
    setState(() => _loading = true);
    try {
      final page = await pager.next();
      setState(() {
        _items.addAll(page.items);
        _error = null;
        _failure = RequestFailure.none;
      });
    } on Object catch (e) {
      setState(() {
        _error = '$e';
        _failure = classifyFailure(e);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncMore() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await widget.session.syncChannel(widget.chatId);
      await _loadMore();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final videos = _items.where((r) => r.kind == MediaKind.video).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: '播放该频道视频',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _items.isEmpty ? null : _playChannel,
          ),
        ],
      ),
      body: _buildBody(videos),
    );
  }

  Widget _buildBody(int videoCount) {
    if (_loading && _items.isEmpty) {
      return const StatusView.loading(title: '正在读取消息');
    }
    if (_error != null && _items.isEmpty) {
      return FailureView(
        failure: _failure,
        detail: _error,
        onRetry: _syncMore,
      );
    }
    if (_items.isEmpty) {
      return StatusView.empty(
        title: '该频道没有可播放的视频',
        message: '可能是最近消息里没有视频，或尚未同步。',
        actionLabel: '同步更多',
        onAction: _syncing ? null : _syncMore,
      );
    }
    return RefreshIndicator(
      onRefresh: _syncMore,
      child: ListView.separated(
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          if (index == _items.length) return _buildFooter(videoCount);
          return _MediaRow(record: _items[index]);
        },
      ),
    );
  }

  Widget _buildFooter(int videoCount) {
    final hasMore = _pager?.hasMore ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: AppTheme.pagePadding),
      child: Column(
        children: <Widget>[
          Text(
            '已加载 ${_items.length} 条，其中视频 $videoCount 条',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              if (hasMore)
                Expanded(
                  child: OutlinedButton(
                    onPressed: _loading ? null : _loadMore,
                    child: const Text('加载更多（本地）'),
                  ),
                ),
              if (hasMore) const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _syncing ? null : _syncMore,
                  child: Text(_syncing ? '正在同步…' : '从 Telegram 同步 2 页'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _playChannel() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FeedPage(
          session: widget.session,
          preferences: widget.preferences,
          activeFiles: widget.activeFiles,
          initialChatId: widget.chatId,
          showBackButton: true,
        ),
      ),
    );
  }
}

class _MediaRow extends StatelessWidget {
  const _MediaRow({required this.record});

  final MediaRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = record.messageDateUnix <= 0
        ? '日期未知'
        : _formatDate(record.messageDateUnix);
    final icon = switch (record.kind) {
      MediaKind.video => Icons.videocam_outlined,
      MediaKind.photo => Icons.image_outlined,
      MediaKind.animation => Icons.gif_box_outlined,
      MediaKind.document => Icons.insert_drive_file_outlined,
      MediaKind.unknown => Icons.help_outline,
    };
    final details = <String>[
      if (record.durationSeconds != null) '${record.durationSeconds}s',
      if (record.sizeBytes > 0) formatBytes(record.sizeBytes),
      date,
    ];
    return ListTile(
      leading: Icon(icon, size: 22),
      title: Text(
        record.fileName ?? record.kind.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(details.join(' · '), style: theme.textTheme.bodySmall),
      trailing: record.hasProtectedContent
          ? const Tooltip(
              message: '该内容受保护，不提供导出',
              child: Icon(Icons.lock_outline, size: 18),
            )
          : null,
    );
  }

  static String _formatDate(int unixSeconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
