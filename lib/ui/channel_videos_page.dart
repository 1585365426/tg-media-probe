/// The videos of one channel, in numbering order: #001 is the oldest.
///
/// The list is built from the local mirror, so it opens instantly and works
/// with the network down. Numbers come from [MediaIndex] and are the same
/// numbers the player shows in its top-right corner.
library;

import 'package:flutter/material.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../data/media_index.dart';
import '../data/media_record.dart';
import '../download/download_manager.dart';
import '../download/download_state.dart';
import '../util/byte_format.dart';
import 'app_theme.dart';
import 'status_view.dart';
import 'video_player_page.dart';

class ChannelVideosPage extends StatefulWidget {
  const ChannelVideosPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.downloads,
    required this.chatId,
    required this.title,
  });

  final AppSession session;
  final PreferencesController preferences;
  final DownloadManager downloads;
  final int chatId;
  final String title;

  @override
  State<ChannelVideosPage> createState() => _ChannelVideosPageState();
}

class _ChannelVideosPageState extends State<ChannelVideosPage> {
  static const double _rowHeight = 76;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  MediaIndex _index = MediaIndex.empty;
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    // One bounded history slice per open: the mirror is the source of truth and
    // the walk-back continues where the last visit stopped.
    _sync();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.session.index;
    if (store == null) {
      setState(() {
        _loading = false;
        _error = '本地索引尚未打开';
      });
      return;
    }
    final records = store.recordsForChannel(widget.chatId);
    final index = MediaIndex.fromRecords(records);
    if (!mounted) return;
    setState(() {
      _index = index;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await widget.session.syncChannel(widget.chatId, pagesPerChannel: 4);
      await _load();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _jump() async {
    final field = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('按编号跳转'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '例如 23',
            prefixText: '#',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    field.dispose();
    if (!mounted || input == null) return;

    final number = parseMediaNumber(input);
    if (number == null) {
      _message('请输入 1 – $kMaxMediaNumber 之间的编号');
      return;
    }
    final item = _index.byNumber(number);
    if (item == null) {
      _message('未找到 ${formatMediaNumber(number)}（当前共 ${_index.length} 条）');
      return;
    }
    _query = '';
    _search.clear();
    setState(() {});
    _scrollToIndex(number - 1);
    _message('已定位到 ${item.label}');
  }

  void _scrollToIndex(int index) {
    if (!_scroll.hasClients) return;
    final target = (index * _rowHeight)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _open(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          items: _index.items,
          initialIndex: index,
          downloads: widget.downloads,
          preferences: widget.preferences,
          channelTitle: widget.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _query.isEmpty ? _index.items : _index.search(_query);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: '按编号跳转',
            icon: const Icon(Icons.tag),
            onPressed: _index.isEmpty ? null : _jump,
          ),
          IconButton(
            tooltip: '同步更多历史',
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _syncing ? null : _sync,
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
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索编号、标题或说明',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                ),
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
        ),
      ),
      body: _buildBody(visible),
    );
  }

  Widget _buildBody(List<NumberedMedia> visible) {
    if (_loading) {
      return const StatusView.loading(title: '正在读取本地索引');
    }
    if (_index.isEmpty) {
      return StatusView.empty(
        title: _error ?? '该频道没有可播放的视频',
        message: _syncing ? '正在同步频道历史…' : '下拉或点右上角同步可继续拉取历史。',
        actionLabel: '重新同步',
        onAction: _sync,
      );
    }
    if (visible.isEmpty) {
      return StatusView.empty(
        title: '没有匹配的视频',
        message: '没有编号或文字匹配“$_query”。',
      );
    }

    return RefreshIndicator(
      onRefresh: _sync,
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _rowHeight,
        itemCount: visible.length,
        itemBuilder: (context, i) => _VideoRow(
          item: visible[i],
          downloads: widget.downloads,
          onTap: () => _open(_index.items.indexOf(visible[i])),
        ),
      ),
    );
  }
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.item,
    required this.downloads,
    required this.onTap,
  });

  final NumberedMedia item;
  final DownloadManager downloads;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = item.record;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            Container(
              width: 56,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                item.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(record),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.play_circle_outline, size: 22),
          ],
        ),
      ),
    );
  }

  String _subtitle(MediaRecord record) {
    final parts = <String>[];
    if (record.sizeBytes > 0) parts.add(formatBytes(record.sizeBytes));
    final duration = record.durationSeconds;
    if (duration != null && duration > 0) {
      final minutes = duration ~/ 60;
      final seconds = duration % 60;
      parts.add('$minutes:${seconds.toString().padLeft(2, '0')}');
    }
    final active = downloads.activeFileId;
    if (active != null && active == record.fileId) {
      final state = downloads.state;
      if (state.phase == DownloadPhase.downloading) {
        parts.add('下载中 ${(state.progress * 100).toStringAsFixed(0)}%');
      } else if (state.phase == DownloadPhase.ready) {
        parts.add('已缓存');
      }
    }
    return parts.isEmpty ? '视频' : parts.join(' · ');
  }
}
