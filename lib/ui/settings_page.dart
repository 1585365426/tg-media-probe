/// Settings — the second of the two tabs.
///
/// Five groups, every row wired to real state. The rule this screen follows: a
/// control that cannot change anything is not rendered at all. There is no
/// download-management page, no favourites, no duration filter and no streaming
/// diagnostics panel, because none of those features exist any more.
library;

import 'package:flutter/material.dart';

import '../app/app_preferences.dart';
import '../app/app_session.dart';
import '../download/download_manager.dart';
import '../download/media_cache.dart';
import '../lock/lock_screens.dart';
import '../lock/unlock_controller.dart';
import '../security/biometric.dart';
import '../security/lock_policy.dart';
import '../td/td_models.dart';
import '../td/td_requests.dart';
import '../util/byte_format.dart';
import 'status_view.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.preferences,
    required this.lock,
    required this.lockStore,
    required this.cache,
    required this.downloads,
  });

  final AppSession session;
  final PreferencesController preferences;
  final UnlockController lock;
  final AppLockStore lockStore;
  final MediaCache cache;
  final DownloadManager downloads;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _version = '1.0.0 (1)';

  int? _cacheBytes;
  int? _freeBytes;
  bool _scanning = false;
  bool _clearing = false;
  String? _tdVersion;

  @override
  void initState() {
    super.initState();
    _refreshCache();
    _loadTdVersion();
  }

  Future<void> _refreshCache() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final used = await widget.cache.usedBytes();
      final free = await widget.cache.freeBytes();
      if (!mounted) return;
      setState(() {
        _cacheBytes = used;
        _freeBytes = free;
      });
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _loadTdVersion() async {
    final client = widget.session.client;
    if (client == null) return;
    try {
      final response = await client.request(
        getOption('version'),
        timeout: const Duration(seconds: 8),
      );
      final value = response['value'];
      if (!mounted) return;
      setState(() => _tdVersion = value is String ? value : '$value');
    } on Object {
      // Left null; the row shows "—" instead of a pinned number.
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text(
          '$cacheClearConfirmationText\n\n'
          '只删除本机已下载的视频文件。Telegram 频道与云端媒体不受影响，'
          '再次播放时会重新下载。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      // The file the player has open must survive its own cache clear.
      final keep = <String>{};
      final path = widget.downloads.state.localPath;
      if (widget.downloads.state.isReady && path != null) keep.add(path);
      final wipe = await widget.cache.clearLocal(keep: keep);
      await _refreshCache();
      if (!mounted) return;
      _toast(wipe.changedAnything
          ? '已清理 ${wipe.deletedFiles} 个文件，释放 ${formatBytes(wipe.freedBytes)}'
          : '没有可清理的缓存文件');
    } on Object catch (e) {
      if (!mounted) return;
      _toast('清理失败：$e');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _accountSection(),
          _securitySection(),
          _playbackSection(),
          _cacheSection(),
          _aboutSection(),
        ],
      ),
    );
  }

  // ---- 账户 -----------------------------------------------------------

  Widget _accountSection() {
    final session = widget.session;
    final account = session.account;
    final status = session.status;
    return SettingsSection(
      title: '账户',
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
            onTap: session.refreshStatus,
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

  // ---- 安全 -----------------------------------------------------------

  Widget _securitySection() {
    final lock = widget.lock;
    final settings = lock.settings;
    final capability = lock.capability;
    final canEnableFaceId = settings.passcodeEnabled;

    return SettingsSection(
      title: '安全',
      footnote: '当前锁状态：${describeLockState(settings, capability)}。'
          '生物识别只用于解锁本应用，不是 Telegram 凭据，也不参与数据库密钥。',
      children: <Widget>[
        SettingsRow(
          title: '应用密码',
          subtitle: settings.passcodeEnabled ? '已设置' : '未设置',
          leading: const Icon(Icons.password),
          showChevron: true,
          onTap: _managePasscode,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '密码提示',
          subtitle: settings.hint ?? '未设置提示词',
          leading: const Icon(Icons.lightbulb_outline),
          showChevron: settings.passcodeEnabled,
          enabled: settings.passcodeEnabled,
          onTap: settings.passcodeEnabled ? _editHint : null,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: capability.label,
          subtitle: settings.biometricEnabled
              ? (capability.canAuthenticate
                  ? '已开启'
                  : capability.unavailableReason ?? '已开启')
              : (canEnableFaceId ? '关闭' : faceIdNeedsPasscodeText),
          leading: const Icon(Icons.face_retouching_natural),
          trailing: Switch(
            value: settings.biometricEnabled,
            onChanged: canEnableFaceId ? _setBiometric : null,
          ),
          enabled: canEnableFaceId,
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
        const SettingsDivider(),
        SettingsRow(
          title: '自动锁定',
          subtitle: settings.autoLockDelay.label,
          leading: const Icon(Icons.timer_outlined),
          showChevron: true,
          enabled: settings.passcodeEnabled,
          onTap: settings.passcodeEnabled ? _chooseAutoLock : null,
        ),
        if (settings.lockEnabled) ...<Widget>[
          const SettingsDivider(),
          SettingsRow(
            title: '立即锁定',
            subtitle: '马上要求解锁',
            leading: const Icon(Icons.lock_clock),
            onTap: lock.lockNow,
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
      ],
    );
  }

  // ---- 播放 -----------------------------------------------------------

  Widget _playbackSection() {
    return ListenableBuilder(
      listenable: widget.preferences,
      builder: (context, _) {
        final prefs = widget.preferences.value;
        return SettingsSection(
          title: '播放',
          children: <Widget>[
            SettingsRow(
              title: '播放速度',
              subtitle: formatPlaybackSpeed(prefs.playbackSpeed),
              leading: const Icon(Icons.speed),
              showChevron: true,
              onTap: () => _chooseSpeed(prefs.playbackSpeed),
            ),
            const SettingsDivider(),
            SettingsRow(
              title: '主题',
              subtitle: prefs.theme.label,
              leading: const Icon(Icons.brightness_6_outlined),
              showChevron: true,
              onTap: () => _chooseTheme(prefs.theme),
            ),
            const SettingsDivider(),
            SettingsRow(
              title: '实时诊断角标',
              subtitle: prefs.diagnosticBadge
                  ? '播放页右上角显示编号与真实下载状态'
                  : '关闭',
              leading: const Icon(Icons.info_outline),
              trailing: Switch(
                key: const Key('switch-diagnostic-badge'),
                value: prefs.diagnosticBadge,
                onChanged: widget.preferences.setDiagnosticBadge,
              ),
            ),
          ],
        );
      },
    );
  }

  // ---- 缓存 -----------------------------------------------------------

  Widget _cacheSection() {
    final used = _cacheBytes;
    final free = _freeBytes;
    return SettingsSection(
      title: '缓存',
      footnote: '清理只会删除本机已下载的视频文件。'
          'Telegram 频道、消息与云端媒体永远不会被删除。',
      children: <Widget>[
        SettingsRow(
          title: '缓存大小',
          subtitle: used == null
              ? '统计中'
              : '${formatBytes(used)}${_scanning ? '（刷新中）' : ''}',
          leading: const Icon(Icons.sd_storage_outlined),
          showChevron: true,
          onTap: _refreshCache,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '清理缓存',
          subtitle: _clearing ? '正在清理…' : '删除本机已下载的视频',
          leading: const Icon(Icons.cleaning_services_outlined),
          showChevron: true,
          enabled: !_clearing,
          onTap: _clearing ? null : _clearCache,
        ),
        const SettingsDivider(),
        SettingsRow(
          title: '磁盘空间',
          subtitle: free == null
              ? '统计中'
              : (free < 0 ? '系统未提供可用空间' : '可用 ${formatBytes(free)}'),
          leading: const Icon(Icons.storage_outlined),
          showChevron: true,
          onTap: _refreshCache,
        ),
      ],
    );
  }

  // ---- 关于 -----------------------------------------------------------

  Widget _aboutSection() {
    return SettingsSection(
      title: '关于',
      children: <Widget>[
        SettingsRow(
          title: 'App 版本',
          subtitle: _version,
          leading: const Icon(Icons.apps),
        ),
        const SettingsDivider(),
        SettingsRow(
          title: 'TDLib 版本',
          subtitle: _tdVersion ?? '—',
          leading: const Icon(Icons.memory),
        ),
      ],
    );
  }

  // ---- actions --------------------------------------------------------

  Future<void> _editHint() async {
    final settings = widget.lock.settings;
    final field = TextEditingController(text: settings.hint ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('密码提示'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '留空表示不显示提示',
            helperText: '提示会在解锁页显示，不要写字面密码',
          ),
          onSubmitted: (text) => Navigator.of(context).pop(text),
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
    if (!mounted || value == null) return;
    await _saveLock(settings.copyWith(hint: value.trim().isEmpty ? null : value.trim()));
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
      // Ask once so the system prompt appears while the user is still on this
      // screen. A cancelled prompt turns the switch back off, because a Face ID
      // that never succeeded must not be advertised as enabled.
      final outcome = await lock.gate.authenticate(reason: '开启面容 ID 解锁');
      if (!mounted) return;
      if (outcome.requiresFallback) {
        _toast(outcome.message);
        await lock.setBiometricEnabled(false);
        await lock.reloadSettings();
      }
    }
    if (mounted) setState(() {});
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
      if (created == true && mounted) setState(() {});
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('应用密码'),
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
            title: '修改应用密码',
          ),
        ),
      );
      if (changed == true) await widget.lock.reloadSettings();
      if (mounted) setState(() {});
      return;
    }

    final verified = await confirmWithPasscode(context, widget.lockStore);
    if (!verified || !mounted) return;
    await widget.lockStore.clearPasscode();
    await widget.lock.reloadSettings();
    if (mounted) setState(() {});
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

  Future<void> _chooseSpeed(double current) async {
    final picked = await _choose<double>(
      title: '播放速度',
      options: kPlaybackSpeeds,
      labelOf: formatPlaybackSpeed,
      current: current,
    );
    if (picked == null) return;
    final ok = await widget.preferences.setPlaybackSpeed(picked);
    if (!ok) {
      _toast('该倍速不受支持');
      return;
    }
    _toast('播放速度已设为 ${formatPlaybackSpeed(picked)}');
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
    // The reset clears the local Telegram session too, so the mirrored content
    // is not left readable behind a removed lock.
    await widget.session.resetThroughTelegram();
    await widget.lock.completeRecovery();
    if (!mounted) return;
    _toast('应用锁已重置，请重新设置应用密码');
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
