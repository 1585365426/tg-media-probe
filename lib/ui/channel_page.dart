/// Channel list — the first of the two tabs.
///
/// Every row is a real Telegram channel the signed-in account can read. Nothing
/// is invented: an unknown video count renders as 统计中, an empty account
/// renders as an explicit empty state, and a failed load renders the classified
/// failure with a retry that actually retries.
library;

import 'package:flutter/material.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../data/channel_directory.dart';
import '../download/download_manager.dart';
import '../download/media_cache.dart';
import 'app_theme.dart';
import 'channel_videos_page.dart';
import 'status_view.dart';

class ChannelPage extends StatefulWidget {
  const ChannelPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.downloads,
    required this.cache,
  });

  final AppSession session;
  final PreferencesController preferences;
  final DownloadManager downloads;
  final MediaCache cache;

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
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

  Future<void> _resync() async {
    await widget.session.refreshDirectory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('频道'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新同步频道',
            icon: const Icon(Icons.refresh),
            onPressed: widget.session.busy ? null : _resync,
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
                hintText: '搜索频道',
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
    switch (directory.state) {
      case DirectoryState.idle:
        return const StatusView.loading(title: '正在读取 Telegram 频道');
      case DirectoryState.loading:
        if (directory.entries.isEmpty) {
          return const StatusView.loading(title: '正在同步频道');
        }
        break;
      case DirectoryState.error:
        return FailureView(
          failure: directory.failure,
          detail: directory.error,
          onRetry: _resync,
        );
      case DirectoryState.empty:
        return StatusView.empty(
          title: '没有可访问的频道',
          message: '当前 Telegram 账号没有已加入的频道。加入频道后点“重新同步”。',
          actionLabel: '重新同步',
          onAction: _resync,
        );
      case DirectoryState.ready:
        break;
    }

    final needle = _query.text.trim().toLowerCase();
    final entries = needle.isEmpty
        ? directory.entries
        : directory.entries
            .where((e) => e.title.toLowerCase().contains(needle))
            .toList(growable: false);

    if (entries.isEmpty) {
      return StatusView.empty(
        title: '没有匹配的频道',
        message: '没有名称包含“${_query.text.trim()}”的频道。',
      );
    }

    return RefreshIndicator(
      onRefresh: _resync,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(
            leading: _ChannelAvatar(title: entry.title),
            title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_subtitle(entry)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _openChannel(entry),
          );
        },
      ),
    );
  }

  String _subtitle(ChannelEntry entry) {
    final count = entry.videoCount;
    if (count == null) return '统计中';
    if (count == 0) return '该频道没有可播放的视频';
    return '$count 个视频';
  }

  Future<void> _openChannel(ChannelEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelVideosPage(
          session: widget.session,
          preferences: widget.preferences,
          downloads: widget.downloads,
          chatId: entry.id,
          title: entry.title,
        ),
      ),
    );
  }
}

class _ChannelAvatar extends StatelessWidget {
  const _ChannelAvatar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = title.trim();
    final letter = trimmed.isEmpty
        ? '#'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
    return CircleAvatar(
      radius: 20,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 16),
      ),
    );
  }
}
