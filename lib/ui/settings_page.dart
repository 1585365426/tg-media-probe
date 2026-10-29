/// Settings (tab 3): five groups, every row wired to real state.
///
/// The rule this screen follows: a control that cannot change anything is not
/// rendered at all. There is no "only Wi-Fi" switch because the confirmed
/// decision is not to restrict by network, and no download row because the
/// download feature is cancelled — not disabled, absent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../data/media_record.dart';
import '../td/td_models.dart';
import '../lock/lock_screens.dart';
import '../lock/unlock_controller.dart';
import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../playback/streaming_diagnostics.dart';
import '../storage/cache_budget.dart';
import '../storage/cache_manager.dart';
import '../storage/storage_layout.dart';
import '../storage/temp_zone_report.dart';
import '../util/byte_format.dart';
import '../util/redact.dart';
import 'app_theme.dart';
import 'chunk_probe_panel.dart';
import 'status_view.dart';
import 'streaming_overlay.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.lock,
    required this.lockStore,
    required this.storageReport,
  });

  final AppSession session;
  final PreferencesController preferences;
  final UnlockController lock;
  final AppLockStore lockStore;
  final TempZoneReport storageReport;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _version = '0.1.0 (1)';

  Map<StorageZone, ZoneInventory>? _inventory;
  TempCleanReport? _cleanReport;
  bool _scanning = false;
  bool _clearing = false;
  String? _storageError;
  AutoCleanResult? _lastAutoClean;

  /// Biggest indexed videos, offered as the acceptance target.
  List<MediaRecord> _largestVideos = const <MediaRecord>[];

  @override
  void initState() {
    super.initState();
    _refreshInventory();
    _refreshLargestVideos();
  }

  /// Reads the biggest videos straight from the mirror.
  ///
  /// Only used to *choose* a target — the acceptance verdict never reads this
  /// list, it reads the live transfer counters.
  Future<void> _refreshLargestVideos() async {
    final store = widget.session.feedStore;
    if (store == null) return;
    try {
      final page = await store.page(limit: 500, videosOnly: true);
      final videos = page.items.toList()
        ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      if (!mounted) return;
      setState(() => _largestVideos = videos.take(3).toList(growable: false));
    } on Object {
      // The mirror may still be booting; the section stays empty.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 32),
        children: <Widget>[
          _accountSection(),
          _securitySection(),
          _storageSection(),
          _appearanceSection(),
          _playbackDiagnosticsSection(),
          _probeSection(),
          _aboutSection(),
        ],
      ),
    );
  }

  // ---- 5.1 账号 -------------------------------------------------------

  Widget _accountSection() {
    final session = widget.session;
    final account = session.account;
    final status = session.status;
    return SettingsSection(
      title: '账号',
      footnote: 'TG Media 只读取你已加入频道的消息与媒体，不修改云端内容。',
      children: <Widget>[
        SettingsRow(
          title: account?.displayName ?? '未登录',
          subtitle: _accountSubtitle(account),
          leading: const Icon(Icons.person_outline),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '登录状态',
          subtitle: status.rawType.isEmpty
              ? status.title
              : '${status.title}（${status.rawType}）',
          leading: const Icon(Icons.verified_user_outlined),
          trailing: Icon(
            status.isAuthorized ? Icons.check_circle : Icons.error_outline,
            size: 20,
            color: status.isAuthorized
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
        ),
        if (session.needsUserInput) ...<Widget>[
          const SettingsDivider(),
          SettingsRow(
            title: '重新登录',
            subtitle: 'TDLib 要求重新验证：${status.title}',
            leading: const Icon(Icons.login),
            showChevron: true,
            onTap: () => session.refreshStatus(),
          ),
        ],
        const SettingsDivider(),
        SettingsRow(
          title: '退出登录',
          subtitle: '清除本地会话与媒体索引，Telegram 云端消息不受影响',
          leading: const Icon(Icons.logout),
          showChevron: true,
          onTap: session.busy ? null : _confirmSignOut,
        ),
      ],
    );
  }

  String _accountSubtitle(AccountInfo? account) {
    if (account == null) return '尚未读取到账号信息';
    final phone = account.maskedPhone;
    if (phone == null) return account.handle;
    return '${account.handle} · $phone';
  }

  // ---- 5.2 隐私与安全 -------------------------------------------------

  Widget _securitySection() {
    final lock = widget.lock;
    final settings = lock.settings;
    final capability = lock.capability;
    final canEnableFaceId = settings.passcodeEnabled;

    return SettingsSection(
      title: '隐私与安全',
      footnote: '当前锁状态：${describeLockState(settings, capability)}。'
          '生物识别只用于解锁本应用，不是 Telegram 凭据，也不参与数据库密钥。',
      children: <Widget>[
        SettingsRow(
          title: capability.label,
          subtitle: settings.biometricEnabled
              ? (capability.canAuthenticate ? '已开启' : capability.unavailableReason ?? '已开启')
              : (canEnableFaceId ? '关闭' : faceIdNeedsPasscodeText),
          leading: const Icon(Icons.face_retouching_natural),
          trailing: Switch(
            value: settings.biometricEnabled,
            onChanged: (value) => _setBiometric(value),
          ),
          enabled: canEnableFaceId,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '应用解锁密码',
          subtitle: settings.passcodeEnabled ? '已设置' : '未设置',
          leading: const Icon(Icons.password),
          showChevron: true,
          onTap: _managePasscode,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '自动锁定',
          subtitle: settings.autoLockDelay.label,
          leading: const Icon(Icons.timer_outlined),
          showChevron: true,
          enabled: settings.passcodeEnabled,
          onTap: () => _chooseAutoLock(),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '启动时要求解锁',
          subtitle: '冷启动即使未超过自动锁定时长也要求解锁',
          leading: const Icon(Icons.power_settings_new),
          trailing: Switch(
            value: settings.lockOnColdStart,
            onChanged: settings.passcodeEnabled
                ? (value) => _saveLock(settings.copyWith(lockOnColdStart: value))
                : null,
          ),
          enabled: settings.passcodeEnabled,
        ),
        if (settings.hint != null) ...<Widget>[
          const SettingsDivider(),
          SettingsRow(
            title: '密码提示词',
            subtitle: settings.hint,
            leading: const Icon(Icons.lightbulb_outline),
          ),
        ],
        const SettingsDivider(),
        SettingsRow(
          title: '忘记密码',
          subtitle: '只能通过重新验证 Telegram 账号来重置',
          leading: const Icon(Icons.help_outline),
          showChevron: true,
          onTap: settings.lockEnabled ? _recoverLock : null,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '立即锁定',
          subtitle: 'LockEvaluator 会立即要求解锁',
          leading: const Icon(Icons.lock_clock),
          enabled: settings.lockEnabled,
          onTap: lock.lockNow,
        ),
      ],
    );
  }

  // ---- 5.3 存储 -------------------------------------------------------

  Widget _storageSection() {
    final prefs = widget.preferences.value;
    final inventory = _inventory;
    final clean = _cleanReport;
    final temp = inventory?[StorageZone.tempCache];
    final reclaimable = temp?.reclaimableBytes;
    final unknown = temp?.unknownCount ?? 0;

    return SettingsSection(
      title: '存储',
      footnote: '清理不会删除 Telegram 频道消息、媒体索引、账号授权或你自己保存的文件。'
          '归属不明的文件会被跳过并列出，不会被猜着删掉。',
      children: <Widget>[
        SettingsRow(
          title: '缓存占用',
          subtitle: _scanning
              ? '正在盘点…'
              : (temp == null
                  ? (_storageError ?? '尚未盘点')
                  : '${temp.fileCount} 个文件 · ${formatBytes(temp.bytes)}'),
          leading: const Icon(Icons.folder_outlined),
          trailing: _scanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: '重新盘点',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _refreshInventory,
                ),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '可清理空间',
          subtitle: reclaimable == null
              ? '尚未盘点'
              : formatBytes(reclaimable),
          leading: const Icon(Icons.cleaning_services_outlined),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '缓存上限',
          subtitle: '当前上限 ${CacheBudget.format(prefs.cacheLimitBytes)}；'
              '超过后自动清理到约 ${CacheBudget.format(CacheBudget.targetBytesFor(prefs.cacheLimitBytes))}',
          leading: const Icon(Icons.data_usage_outlined),
          showChevron: true,
          onTap: () => _chooseCacheLimit(prefs.cacheLimitBytes),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '本次运行的上次自动清理',
          subtitle: _lastAutoClean?.summary() ??
              '尚未触发（启动或回到前台时检查，去重后单次清理）',
          leading: const Icon(Icons.auto_delete_outlined),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '清除缓存',
          subtitle: _clearing ? '正在清理…' : '只清理已登记的缓存目录',
          leading: const Icon(Icons.delete_sweep_outlined),
          showChevron: true,
          enabled: !_clearing,
          onTap: _clearCache,
        ),
        if (unknown > 0) ...<Widget>[
          const SettingsDivider(),
          SettingsRow(
            title: '未识别文件',
            subtitle: '$unknown 个 · ${formatBytes(temp?.unknownBytes ?? 0)}，已被跳过',
            leading: const Icon(Icons.report_gmailerrorred_outlined),
            showChevron: temp != null,
            onTap: () => _showUnknownFiles(temp!),
          ),
        ],
        if (clean != null) ...<Widget>[
          const SettingsDivider(),
          SettingsRow(
            title: clean.succeeded ? '上次清理完成' : '上次清理未完全成功',
            subtitle: clean.summary,
            leading: Icon(
              clean.succeeded ? Icons.check_circle_outline : Icons.error_outline,
            ),
          ),
        ],
      ],
    );
  }

  /// Cache ceiling picker: four presets plus a validated custom value.
  Future<void> _chooseCacheLimit(int current) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('缓存上限', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final preset in CacheBudget.presets)
              ListTile(
                title: Text(CacheBudget.format(preset)),
                trailing: preset == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(preset),
              ),
            ListTile(
              title: const Text('自定义…'),
              subtitle: Text(
                  '${CacheBudget.format(CacheBudget.minLimit)} – '
                  '${CacheBudget.format(CacheBudget.maxLimit)}'),
              onTap: () => Navigator.of(context).pop(-1),
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('恢复默认 1 GB'),
              onTap: () => Navigator.of(context).pop(CacheBudget.defaultLimit),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == -1) {
      await _customCacheLimit(current);
      return;
    }
    await _applyCacheLimit(choice);
  }

  Future<void> _customCacheLimit(int current) async {
    final field = TextEditingController(
        text: (current / CacheBudget.mb).round().toString());
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义缓存上限（MB）'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            helperText: '${CacheBudget.minLimit ~/ CacheBudget.mb} – '
                '${CacheBudget.maxLimit ~/ CacheBudget.mb} MB',
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    field.dispose();
    if (!mounted || input == null) return;
    final mb = int.tryParse(input.trim());
    if (mb == null) {
      _showMessage('请输入数字（MB）');
      return;
    }
    final bytes = mb * CacheBudget.mb;
    if (!CacheBudget.isAllowed(bytes)) {
      _showMessage('上限需在 ${CacheBudget.format(CacheBudget.minLimit)} – '
          '${CacheBudget.format(CacheBudget.maxLimit)} 之间，未保存');
      return;
    }
    await _applyCacheLimit(bytes);
  }

  Future<void> _applyCacheLimit(int bytes) async {
    final ok = await widget.preferences.setCacheLimit(bytes);
    if (!mounted) return;
    _showMessage(ok
        ? '缓存上限已设为 ${CacheBudget.format(bytes)}'
        : '数值超出允许范围，未保存');
  }

  // ---- 5.4 外观与播放 -------------------------------------------------

  Widget _appearanceSection() {
    return ListenableBuilder(
      listenable: widget.preferences,
      builder: (context, _) {
        final prefs = widget.preferences.value;
        return SettingsSection(
          title: '外观与播放',
          children: <Widget>[
            SettingsRow(
              title: '主题',
              subtitle: prefs.theme.label,
              leading: const Icon(Icons.brightness_6_outlined),
              showChevron: true,
              onTap: () => _chooseTheme(prefs.theme),
            ),
            const SettingsDivider(),
            SettingsRow(
              title: '播放方向',
              subtitle: prefs.feedDirection.label,
              leading: const Icon(Icons.screen_rotation),
              showChevron: true,
              onTap: () => _chooseDirection(prefs.feedDirection),
            ),
            const SettingsDivider(),
            SettingsRow(
              title: '默认静音',
              subtitle: '进入视频页时不自动外放',
              leading: const Icon(Icons.volume_off_outlined),
              trailing: Switch(
                value: prefs.defaultMuted,
                onChanged: widget.preferences.setDefaultMuted,
              ),
            ),
            const SettingsDivider(),
            SettingsRow(
              title: '相邻视频预加载数量',
              // The wording has to match the implementation: forward only, and
              // one transfer at a time so the current video keeps priority.
              subtitle: '向后预加载 ${prefs.preloadCount} 条（0–'
                  '${AppPreferences.maxPreloadCount}，逐个预取，不并发）',
              leading: const Icon(Icons.downloading_outlined),
              trailing: TextButton(
                onPressed: () => _editPreloadCount(prefs.preloadCount),
                child: Text('${prefs.preloadCount} 条'),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Number editor for the preload window.
  ///
  /// Rejects anything outside 0–[AppPreferences.maxPreloadCount] with a visible
  /// message; it never silently clamps, because a silent clamp looks like the
  /// setting "saved" while the player behaves differently.
  Future<void> _editPreloadCount(int current) async {
    final field = TextEditingController(text: '$current');
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('相邻视频预加载数量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                helperText: '0 = 关闭；最多 ${AppPreferences.maxPreloadCount} 条',
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            const SizedBox(height: 8),
            const Text(
              '只向后预加载，逐条进行；当前视频始终优先。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    field.dispose();
    if (!mounted || input == null) return;
    final trimmed = input.trim();
    final value = int.tryParse(trimmed);
    if (value == null || trimmed.isEmpty) {
      _showMessage('请输入 0 – ${AppPreferences.maxPreloadCount} 之间的数字');
      return;
    }
    final ok = await widget.preferences.setPreloadCount(value);
    if (!mounted) return;
    if (!ok) {
      _showMessage('数量需在 0 – ${AppPreferences.maxPreloadCount} 之间，未保存');
      return;
    }
    _showMessage('预加载数量已设为 $value 条');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- 播放诊断（边下边播真机验收）------------------------------------

  /// Streaming evidence, live.
  ///
  /// The point of this section is to make the claim falsifiable: a play is
  /// only reported as 边下边播 when the player was running while TDLib still
  /// had bytes to fetch and the proxy really answered `206`. A full download
  /// followed by playback says so, and a run that never produced the data
  /// says 无法判定 instead of assuming.
  // ---- E1 分块下载实验 ------------------------------------------------

  /// The panel borrows `session.client`, the one TdClient this process may
  /// have: a second instance on the same `database_directory` fails with
  /// "Can't lock file", and the point of the probe is to measure the very
  /// client the product uses.
  Widget _probeSection() {
    final session = widget.session;
    return SettingsSection(
      title: '下载实验（E1）',
      footnote: '对同一个真实文件依次请求 1 MB 的连续区间，'
          '每块用直接读文件和 readFilePart 两条路校验。'
          '结果写到 Documents/probes/，可整段复制。',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
          child: ChunkProbePanel(
            client: session.client,
            ready: session.status.isAuthorized,
          ),
        ),
      ],
    );
  }

  Widget _playbackDiagnosticsSection() {
    return ListenableBuilder(
      listenable: widget.preferences,
      builder: (context, _) {
        final prefs = widget.preferences.value;
        return ListenableBuilder(
          listenable: StreamingDiagnostics.instance,
          builder: (context, _) {
            final diag = StreamingDiagnostics.instance;
            return SettingsSection(
              title: '播放诊断',
              footnote: '角标与下面的数字全部来自真实运行数据：TDLib updateFile、'
                  '代理实际写回的 HTTP 状态、AVPlayer 自己的播放状态。'
                  '只有“开始播放时文件还不完整 + 至少一次 206”才会判定为边下边播。',
              children: <Widget>[
                SettingsRow(
                  title: '边下边播诊断模式',
                  subtitle: '在视频右上角显示实时角标（STREAM / FULL）',
                  leading: const Icon(Icons.analytics_outlined),
                  trailing: Switch(
                    value: prefs.streamingDiagnostics,
                    onChanged: (value) {
                      StreamingDiagnostics.instance.setEnabled(value);
                      unawaited(
                        widget.preferences.setStreamingDiagnostics(value),
                      );
                    },
                  ),
                ),
                const SettingsDivider(),
                SettingsRow(
                  title: diag.acceptanceRunning
                      ? '结束验收（强制 Streaming 运行中）'
                      : '开始边下边播验收（强制 Streaming）',
                  subtitle: diag.acceptanceRunning
                      ? (diag.verdict == StreamingVerdict.unknown
                          ? '验收进行中：请打开一个大视频（建议 500MB–1GB）开始播放'
                          : '验收完成，结论见下方')
                      : '开启 FORCE_STREAMING_TEST、清零证据，然后播放一个大视频',
                  leading: const Icon(Icons.play_circle_outline),
                  showChevron: true,
                  onTap: diag.acceptanceRunning ? _stopAcceptance : _startAcceptance,
                ),
                const SettingsDivider(),
                SettingsRow(
                  title: '复制播放诊断',
                  subtitle: '把当前证据与验收结论复制到剪贴板',
                  leading: const Icon(Icons.copy_all_outlined),
                  showChevron: true,
                  onTap: _copyPlaybackDiagnostics,
                ),
                const SettingsDivider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.pagePadding,
                    vertical: 12,
                  ),
                  child: const StreamingDiagnosticsSection(),
                ),
                // Acceptance target: a video that is definitely not cached
                // yet. Without this the run proves nothing, because a cached
                // video plays instantly for the wrong reason.
                if (_largestVideos.isNotEmpty) ...<Widget>[
                  const SettingsDivider(),
                  SettingsRow(
                    title: '验收用：体积最大的视频',
                    subtitle: '播放其中一个，回来查看结论',
                    leading: const Icon(Icons.video_library_outlined),
                  ),
                  for (final record in _largestVideos)
                    SettingsRow(
                      title: formatBytes(record.sizeBytes),
                      subtitle: '${_chatTitle(record.chatId)} · '
                          'msg=${record.messageId}',
                      leading: const Icon(Icons.play_arrow, size: 18),
                    ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  String _chatTitle(int chatId) =>
      widget.session.directory?.titles[chatId] ?? '频道 $chatId';

  /// Clears the previous run, arms the acceptance recorder and turns
  /// FORCE_STREAMING_TEST on.
  ///
  /// Forced mode is the point of this button: while it runs, the feed ignores
  /// the prefetch cache, starts no background prefetch, and every play enters
  /// `resolveStream` — a full download before playback now reports
  /// STREAMING_TEST_FAILED instead of hiding behind a cached path.
  Future<void> _startAcceptance() async {
    StreamingDiagnostics.instance.setForceStreamingTest(true);
    StreamingDiagnostics.instance.startAcceptance();
    // Persist the flag too: a restart between arming and playing must not
    // drop the forced mode without a trace.
    await widget.preferences.setForceStreamingTest(true);
    _showMessage('强制 Streaming 已开启，证据已清零。请打开一个大视频'
        '（500MB–1GB）开始播放；播放后回到本页查看结论。');
  }

  /// Ends the run. The evidence stays on screen until the next one; only the
  /// "armed" flag is cleared, so a later play cannot overwrite the result.
  /// FORCE_STREAMING_TEST goes off with it — normal user behaviour resumes.
  Future<void> _stopAcceptance() async {
    StreamingDiagnostics.instance.setForceStreamingTest(false);
    StreamingDiagnostics.instance.stopAcceptance();
    await widget.preferences.setForceStreamingTest(false);
    final verdict = StreamingDiagnostics.instance.verdict;
    _showMessage(verdict == StreamingVerdict.unknown
        ? '验收已结束：本次没有产生足够数据，结论仍为无法判定'
        : '验收已结束：${verdict.code}');
  }

  Future<void> _copyPlaybackDiagnostics() async {
    final diag = StreamingDiagnostics.instance;
    final lines = <String>[
      ...diag.diagnosticLines(),
      'acceptance:',
      ...diag.acceptanceLines(),
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    _showMessage('播放诊断已复制到剪贴板');
  }

  // ---- 5.5 关于 -------------------------------------------------------

  Widget _aboutSection() {
    return SettingsSection(
      title: '关于',
      children: <Widget>[
        SettingsRow(
          title: '版本',
          subtitle: _version,
          leading: const Icon(Icons.info_outline),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '隐私说明',
          subtitle: '数据只在本机处理，不上传服务器',
          leading: const Icon(Icons.privacy_tip_outlined),
          showChevron: true,
          onTap: _showPrivacy,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '导出诊断信息',
          subtitle: '导出前自动脱敏，仍含敏感内容则拒绝导出',
          leading: const Icon(Icons.bug_report_outlined),
          showChevron: true,
          onTap: _exportDiagnostics,
        ),
      ],
    );
  }

  // ---- actions -------------------------------------------------------

  Future<void> _refreshInventory() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _storageError = null;
    });
    try {
      final all = await widget.storageReport.inventoryAll();
      if (!mounted) return;
      setState(() => _inventory = all);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _storageError = '盘点失败：$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text(cacheClearConfirmationText),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      final report = await widget.storageReport.cleanTempZone(userConfirmed: true);
      if (!mounted) return;
      setState(() => _cleanReport = report);
      await _refreshInventory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(report.summary)),
      );
    } on TempCleanNotConfirmed {
      // Cannot happen: the dialog above is the confirmation.
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _showUnknownFiles(ZoneInventory temp) async {
    final names = temp.entries
        .where((entry) => !entry.known)
        .take(30)
        .map((entry) => entry.relativePath)
        .toList();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('未识别文件（${temp.unknownCount} 个）'),
        content: SingleChildScrollView(
          child: Text(
            names.isEmpty
                ? '没有未识别文件。'
                : '${names.join('\n')}\n\n这些文件不会被删除。',
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _setBiometric(bool value) async {
    final lock = widget.lock;
    if (value && !lock.settings.passcodeEnabled) {
      _toast(faceIdNeedsPasscodeText);
      return;
    }
    final ok = await lock.setBiometricEnabled(value);
    if (!ok) {
      _toast(faceIdNeedsPasscodeText);
      return;
    }
    await lock.reloadSettings();
    if (value) {
      // Ask once so the user sees the system prompt while they are still in the
      // settings screen; a cancelled prompt keeps the toggle on, because the
      // setting is about the next unlock, not about this tap.
      final outcome = await lock.gate.authenticate(reason: '开启面容 ID 解锁');
      if (!mounted) return;
      if (outcome.requiresFallback) {
        _toast(outcome.message);
        await lock.setBiometricEnabled(false);
        await lock.reloadSettings();
      }
    }
  }

  Future<void> _managePasscode() async {
    final settings = widget.lock.settings;
    if (!settings.passcodeEnabled) {
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PasscodeSetupScreen(store: widget.lockStore),
        ),
      );
      if (created == true) await widget.lock.reloadSettings();
      if (created == true) setState(() {});
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('应用解锁密码'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('change'),
            child: const Text('修改密码'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('clear'),
            child: const Text('关闭应用锁（清除密码与生物识别）'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'change') {
      final verified = await confirmWithPasscode(context, widget.lockStore);
      if (!verified || !mounted) return;
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PasscodeSetupScreen(
            store: widget.lockStore,
            title: '修改应用解锁密码',
          ),
        ),
      );
      if (changed == true) await widget.lock.reloadSettings();
      setState(() {});
      return;
    }

    final verified = await confirmWithPasscode(context, widget.lockStore);
    if (!verified || !mounted) return;
    await widget.lockStore.clearPasscode();
    await widget.lock.reloadSettings();
    setState(() {});
  }

  Future<void> _chooseAutoLock() async {
    final settings = widget.lock.settings;
    final picked = await _choose<AutoLockDelay>(
      title: '自动锁定',
      options: AutoLockDelay.values,
      labelOf: (value) => value.label,
      current: settings.autoLockDelay,
    );
    if (picked == null) return;
    await _saveLock(settings.copyWith(autoLockDelay: picked));
  }

  Future<void> _chooseTheme(ThemePreference current) async {
    final picked = await _choose<ThemePreference>(
      title: '主题',
      options: ThemePreference.values,
      labelOf: (value) => value.label,
      current: current,
    );
    if (picked == null) return;
    await widget.preferences.setTheme(picked);
  }

  Future<void> _chooseDirection(FeedDirection current) async {
    final picked = await _choose<FeedDirection>(
      title: '播放方向',
      options: FeedDirection.values,
      labelOf: (value) => value.label,
      current: current,
    );
    if (picked == null) return;
    await widget.preferences.setFeedDirection(picked);
  }

  Future<T?> _choose<T>({
    required String title,
    required List<T> options,
    required String Function(T value) labelOf,
    required T current,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: <Widget>[
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option),
              child: Row(
                children: <Widget>[
                  Icon(
                    option == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(labelOf(option)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _saveLock(AppLockSettings next) async {
    await widget.lockStore.save(next);
    await widget.lock.reloadSettings();
    if (mounted) setState(() {});
  }

  Future<void> _recoverLock() async {
    final confirmed = await confirmRecoveryReset(context);
    if (!confirmed || !mounted) return;
    // §8.6 + confirmed decision #5: the reset clears the local Telegram session
    // too, so the mirrored content is not left readable behind a removed lock.
    await widget.session.resetThroughTelegram();
    await widget.lock.completeRecovery();
    if (!mounted) return;
    _toast('应用锁已重置，请重新设置应用解锁密码');
    await widget.session.boot();
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
          '本地会话与媒体索引会被清除，下次需要重新输入手机号与验证码。'
          'Telegram 云端的频道消息与媒体不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.session.signOut();
    await widget.session.boot();
  }

  Future<void> _showPrivacy() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('隐私说明'),
        content: const Text(
          'TG Media 只在你的设备上读取并与 Telegram 同步频道消息与媒体元数据。'
          '应用不含统计 SDK，不把浏览记录、账号信息或媒体内容发送到任何第三方服务器。\n\n'
          '应用锁使用 iOS 的生物识别与本地 PBKDF2 密码校验，人脸与指纹模板始终留在 Secure Enclave，'
          '不会进入应用的任何代码路径。\n\n'
          '导出诊断信息时会自动脱敏；若脱敏后仍检测到敏感内容，导出会被拒绝。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// Builds the diagnostics payload, redacts it, refuses when the redaction did
  /// not catch everything, and copies it to the clipboard.
  Future<void> _exportDiagnostics() async {
    final payload = <String, Object?>{
      'version': _version,
      'session': widget.session.diagnostics(),
      'lock': <String, Object?>{
        'enabled': widget.lock.settings.lockEnabled,
        'passcode': widget.lock.settings.passcodeEnabled,
        'biometric': widget.lock.settings.biometricEnabled,
        'autoLock': widget.lock.settings.autoLockDelay.name,
        'phase': widget.lock.phase.name,
      },
      'preferences': widget.preferences.value.toJson(),
      'storage': <String, Object?>{
        for (final entry in (_inventory ?? <StorageZone, ZoneInventory>{}).entries)
          entry.key.name: <String, Object?>{
            'files': entry.value.fileCount,
            'bytes': entry.value.bytes,
            'unknown': entry.value.unknownCount,
            'readable': entry.value.readable,
          },
      },
    };

    final redacted = redactDiagnostics(payload);
    final text = const JsonEncoder.withIndent('  ').convert(redacted);

    if (mayContainSecret(text)) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('拒绝导出'),
          content: const Text('脱敏后仍检测到疑似敏感内容，已拒绝导出。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('诊断信息已复制'),
        content: SingleChildScrollView(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
