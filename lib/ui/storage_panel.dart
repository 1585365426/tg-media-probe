import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/storage_layout.dart';
import '../storage/temp_zone_report.dart';
import '../util/byte_format.dart';

/// Progress snapshot for the clear dialog. Immutable so the notifier fires on
/// every update: [ValueListenableBuilder] compares with `==`, and mutating a
/// shared object in place would never repaint the dialog.
class _CleanProgress {
  const _CleanProgress(this.done, this.total, this.current);

  final int done;
  final int total;
  final String current;

  double? get fraction => total > 0 ? done / total : null;

  @override
  bool operator ==(Object other) =>
      other is _CleanProgress &&
      other.done == done &&
      other.total == total &&
      other.current == current;

  @override
  int get hashCode => Object.hash(done, total, current);
}

/// Storage evidence panel for the probe screen.
///
/// Rule this widget follows: never show a number it did not measure. No cached
/// "last known size", no optimistic decrement after a delete — every value
/// comes from a [ZoneInventory] produced by an actual directory walk, and a
/// zone that failed to read is labelled as such instead of being drawn as 0 B.
class StoragePanel extends StatefulWidget {
  const StoragePanel({super.key, required this.report});

  final TempZoneReport report;

  @override
  State<StoragePanel> createState() => _StoragePanelState();
}

class _StoragePanelState extends State<StoragePanel> {
  Map<StorageZone, ZoneInventory>? _inventory;
  TempCleanReport? _lastClean;
  bool _busy = false;
  String _status = '尚未盘点';

  Future<void> _inventoryAll() async {
    setState(() {
      _busy = true;
      _status = '正在遍历四个存储区…';
    });
    final result = await widget.report.inventoryAll();
    if (!mounted) return;
    setState(() {
      _inventory = result;
      _busy = false;
      final temp = result[StorageZone.tempCache]!;
      _status = temp.readable
          ? '临时缓存 ${temp.fileCount} 个文件 · ${formatBytes(temp.bytes)}'
          : '临时缓存读取失败：${temp.error}';
    });
  }

  Future<void> _cleanTemp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理临时缓存'),
        content: const Text(
          '只删除 Library/Caches/tgmedia 下可重新获取的文件。'
          '不删除 Telegram 频道消息、用户下载、媒体索引或登录授权。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = '正在清理…';
    });

    // Non-dismissible progress dialog. The delete loop over a real blob pool
    // takes long enough that a frozen button reads as "nothing happened" —
    // which is exactly the report this screen exists to disprove.
    final progress = ValueNotifier<_CleanProgress>(
      const _CleanProgress(0, 0, ''),
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('正在清理临时缓存'),
        content: ValueListenableBuilder<_CleanProgress>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(value.total > 0 ? '${value.done} / ${value.total}' : '正在扫描…'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: value.fraction),
              const SizedBox(height: 12),
              Text(
                value.current.isEmpty ? ' ' : value.current,
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    ));

    TempCleanReport? report;
    String? error;
    try {
      report = await widget.report.cleanTempZone(
        userConfirmed: true,
        onProgress: (done, total, current) {
          progress.value = _CleanProgress(done, total, current);
        },
      );
    } catch (e) {
      error = e.toString();
    }

    if (mounted) navigator.pop();
    progress.dispose();

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _busy = false;
        _status = '清理失败：$error';
      });
      return;
    }

    // Re-inventory after the delete instead of subtracting from the old
    // numbers: the disk is the only source of truth.
    final after = await widget.report.inventoryAll();
    if (!mounted) return;
    setState(() {
      _inventory = after;
      _lastClean = report;
      _busy = false;
      _status = report!.summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inventory = _inventory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('4. 存储四区（真实盘点）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '数字来自递归列目录 + 每个文件 stat；读不到的区标注失败，不显示成 0 B。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _inventoryAll,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('盘点存储'),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _cleanTemp,
              icon: const Icon(Icons.cleaning_services, size: 18),
              label: const Text('清理临时缓存'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('状态: $_status', style: theme.textTheme.bodySmall),
        if (_lastClean != null) ...<Widget>[
          const SizedBox(height: 6),
          _reportBox(theme, _lastClean!),
        ],
        if (inventory != null) ...<Widget>[
          const SizedBox(height: 12),
          for (final zone in StorageZone.values) ...<Widget>[
            _zoneCard(theme, inventory[zone]!),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  Widget _reportBox(ThemeData theme, TempCleanReport report) {
    final ok = report.succeeded;
    final color = ok ? const Color(0xFF1B6B3A) : const Color(0xFFB3261E);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            ok ? '清理完成' : '清理未完全成功',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(report.summary, style: theme.textTheme.bodySmall),
          if (report.refusedByGuard.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            for (final line in report.refusedByGuard.take(5))
              Text('拒绝: $line', style: theme.textTheme.bodySmall),
          ],
          if (report.failures.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            for (final failure in report.failures.take(5))
              Text(
                '失败: ${failure.key.split('/').last} — ${failure.value}',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }

  Widget _zoneCard(ThemeData theme, ZoneInventory zone) {
    final isTemp = zone.zone == StorageZone.tempCache;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${zone.zone.label}${isTemp ? '（可清理）' : '（受保护）'}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                zone.readable ? zone.line : '读取失败',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: zone.readable ? null : const Color(0xFFB3261E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            zone.root,
            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
          ),
          if (zone.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                zone.error!,
                style: const TextStyle(fontSize: 11, color: Color(0xFFB3261E)),
              ),
            ),
          if (zone.entries.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            for (final entry in zone.entries)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        entry.relativePath,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatBytes(entry.bytes),
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (entry.inUse)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text(
                          '占用中',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8A6D00),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (zone.fileCount > zone.entries.length)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '…仅列出最大的 ${zone.entries.length} 个，共 ${zone.fileCount} 个',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
