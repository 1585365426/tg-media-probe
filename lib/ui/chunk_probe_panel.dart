import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../td/chunk_probe.dart';
import '../td/td_client.dart';
import '../util/redact.dart';

/// E1 panel: sequential bounded-range download against real TDLib.
///
/// Deliberately a probe and not a feature. Its job is to produce evidence —
/// per-chunk timings, the `updateFile` sequence, two independent reads of every
/// window — and to hand that evidence back as text, because the phone is the
/// only place TDLib actually runs.
class ChunkProbePanel extends StatefulWidget {
  const ChunkProbePanel({
    super.key,
    required this.client,
    required this.ready,
  });

  final TdClient? client;

  /// True only after `authorizationStateReady`; every call below needs it.
  final bool ready;

  @override
  State<ChunkProbePanel> createState() => _ChunkProbePanelState();
}

class _ChunkProbePanelState extends State<ChunkProbePanel> {
  static const List<int> _chunkSizes = <int>[
    512 * 1024,
    1 << 20,
    4 << 20,
  ];

  final List<String> _lines = <String>[];

  int _chunkBytes = 1 << 20;
  int _maxChunks = 5;
  bool _purgeFirst = true;
  bool _synchronousProbe = true;

  bool _busy = false;
  String _status = '未运行';

  List<ProbeVideo> _videos = const <ProbeVideo>[];
  ProbeVideo? _selected;
  ChunkProbeResult? _result;

  void _append(String line) {
    _lines.add(line);
    if (_lines.length > 400) _lines.removeRange(0, _lines.length - 400);
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    final client = widget.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _status = '扫描频道视频…';
      _lines.clear();
      _result = null;
    });
    try {
      final runner = ChunkProbeRunner(client: client, onLog: _append);
      final videos = await runner.scanVideos();
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _selected = videos.isEmpty ? null : videos.first;
        _status = videos.isEmpty ? '没有找到视频' : '找到 ${videos.length} 个视频';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '扫描失败: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    final client = widget.client;
    final video = _selected;
    if (client == null || video == null) return;
    setState(() {
      _busy = true;
      _status = 'E1 运行中…';
      _lines.clear();
      _result = null;
    });
    final runner = ChunkProbeRunner(
      client: client,
      onLog: _append,
      onProgress: (line) => setState(() => _status = line),
    );
    try {
      final result = await runner.runE1(
        video: video,
        tdlibVersion: kTdlibBuildVersion,
        deviceLabel: '${Platform.operatingSystem} '
            '${Platform.operatingSystemVersion}',
        chunkBytes: _chunkBytes,
        maxChunks: _maxChunks,
        purgeFirst: _purgeFirst,
        synchronousProbe: _synchronousProbe,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _status = 'E1 = ${result.verdict.status}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'E1 异常: ${redactText(e.toString())}');
    } finally {
      await runner.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${text.length} 字符')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canRun = !_busy && widget.ready && widget.client != null;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('E1 连续分块下载（真实 TDLib）',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '对同一个真实文件依次请求 [0,1MB) [1MB,2MB) …，'
          '每块用 POSIX 与 readFilePart 双读校验。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.tonal(
              onPressed: canRun ? _scan : null,
              child: const Text('扫描频道视频'),
            ),
            DropdownButton<int>(
              value: _chunkBytes,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _chunkBytes = v ?? _chunkBytes),
              items: _chunkSizes
                  .map((b) => DropdownMenuItem<int>(
                        value: b,
                        child: Text('块 ${b >> 10} KB'),
                      ))
                  .toList(),
            ),
            DropdownButton<int>(
              value: _maxChunks,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _maxChunks = v ?? _maxChunks),
              items: const <int>[3, 5, 8]
                  .map((n) => DropdownMenuItem<int>(
                        value: n,
                        child: Text('$n 块'),
                      ))
                  .toList(),
            ),
            FilterChip(
              label: const Text('先 deleteFile'),
              selected: _purgeFirst,
              onSelected: _busy
                  ? null
                  : (v) => setState(() => _purgeFirst = v),
            ),
            FilterChip(
              label: const Text('同步请求计时'),
              selected: _synchronousProbe,
              onSelected: _busy
                  ? null
                  : (v) => setState(() => _synchronousProbe = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_videos.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final target in kSampleTargets)
                ActionChip(
                  label: Text('≈${target >> 20} MB'),
                  onPressed: _busy
                      ? null
                      : () => setState(() =>
                          _selected = pickClosest(_videos, target) ?? _selected),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (_videos.isNotEmpty)
          DropdownButtonFormField<ProbeVideo>(
            initialValue: _selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '测试文件'),
            items: _videos
                .take(40)
                .map((v) => DropdownMenuItem<ProbeVideo>(
                      value: v,
                      child: Text(
                        '${v.sizeLabel} · ${v.width}x${v.height} · '
                        '${v.durationSeconds}s · fileId=${v.fileId}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: _busy ? null : (v) => setState(() => _selected = v),
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: canRun && _selected != null ? _run : null,
          child: const Text('运行 E1'),
        ),
        if (!widget.ready)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('需先完成真实登录（authorizationStateReady）'),
          ),
        const SizedBox(height: 8),
        Text('状态: $_status',
            style: Theme.of(context).textTheme.bodySmall),
        if (_lines.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            height: 180,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                _lines.join('\n'),
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
        if (result != null) ...<Widget>[
          const SizedBox(height: 12),
          Text('E1 = ${result.verdict.status}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final reason in result.verdict.reasons)
            Text('• $reason',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: () => _copy(result.markdown),
                child: const Text('复制报告 (Markdown)'),
              ),
              OutlinedButton(
                onPressed: () async {
                  // Resolved before the awaits: a BuildContext captured after
                  // them may belong to a page that is already gone.
                  final messenger = ScaffoldMessenger.of(context);
                  final file = File(result.jsonlPath);
                  if (!await file.exists()) return;
                  final text = await file.readAsString();
                  if (!mounted) return;
                  if (text.length > 2 * 1024 * 1024) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('JSONL 超过 2 MB，请从 Documents/probes 取文件'),
                      ),
                    );
                    return;
                  }
                  await _copy(text);
                },
                child: const Text('复制 JSONL 事件流'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            'jsonl: ${result.jsonlPath}\nmd: ${result.markdownPath}',
            style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
          ),
        ],
      ],
    );
  }
}
