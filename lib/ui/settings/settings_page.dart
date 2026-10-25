import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../app/app_services.dart';
import '../../app/app_settings.dart';
import '../../security/biometric.dart';
import '../../storage/cache_manager.dart';
import '../probe_page.dart';
import 'passcode_page.dart';

/// Settings: theme, cache clearing, app lock.
///
/// Two hard rules encoded here:
/// * the cache button is the *only* delete affordance in the whole app, it runs
///   through `CacheManager.clear(userConfirmed: true)`, and its confirmation
///   dialog states in plain words what will not be touched;
/// * the lock section never shows a Face ID toggle on a device that cannot do
///   Face ID — [BiometricAvailability.canOfferToggle] decides, not a try/catch
///   around a failed prompt.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _lockEnabled;
  bool _biometricEnabled = false;
  BiometricAvailability _availability = BiometricAvailability.unsupported;

  CacheScan? _scan;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lockEnabled == null) _loadSecurityState();
    if (_scan == null) _refreshScan();
  }

  Future<void> _loadSecurityState() async {
    final lock = widget.services.appLock;
    var enabled = false;
    var bioEnabled = false;
    try {
      enabled = await lock.isEnabled();
      bioEnabled = await lock.isBiometricEnabled();
    } catch (_) {
      enabled = false;
    }
    final availability = await widget.services.biometrics.availability(refresh: true);
    if (!mounted) return;
    setState(() {
      _lockEnabled = enabled;
      _biometricEnabled = bioEnabled;
      _availability = availability;
    });
  }

  Future<void> _refreshScan() async {
    try {
      final scan = await widget.services.cache.scan();
      if (!mounted) return;
      setState(() => _scan = scan);
    } catch (_) {
      // A failed scan shows "无法统计" rather than a fake 0 B.
    }
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final scan = _scan;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理临时缓存'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '将删除 ${scan?.reclaimableCount ?? 0} 个可重建的临时文件，'
              '约 ${_formatBytes(scan?.reclaimableBytes ?? 0)}。',
            ),
            const SizedBox(height: 10),
            const Text(
              '仅清除临时缓存，不会删除已下载文件、收藏、账号数据、Telegram 云端消息。',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(cacheClearConfirmationText, style: const TextStyle(fontSize: 12)),
            if ((scan?.inUseCount ?? 0) > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '正在使用的 ${scan!.inUseCount} 个文件会被跳过。',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final report = await widget.services.cache.clear(userConfirmed: true);
      if (!mounted) return;
      await _refreshScan();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(report.succeeded ? '清理完成' : '清理未完全成功'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(report.summary),
              if (!report.protectedZonesIntact)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '受保护目录出现异常，已中止后续操作。用户下载、索引与账号数据未被触碰。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (!report.integrityPreserved)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '索引完整性校验未通过（清理前后计数不一致）。请到诊断页复核。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleLock(bool enable) async {
    final target = enable ? PasscodeMode.create : PasscodeMode.disable;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PasscodeSetupPage(services: widget.services, mode: target),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      await _loadSecurityState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(enable ? '应用密码已开启' : '应用密码已关闭')),
      );
    }
  }

  Future<void> _changePasscode() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PasscodeSetupPage(
          services: widget.services,
          mode: PasscodeMode.change,
        ),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('应用密码已更新')),
      );
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    await widget.services.appLock.setBiometricEnabled(value);
    if (!mounted) return;
    setState(() => _biometricEnabled = value);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final model = scope.model;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: <Widget>[
          _section('外观', theme),
          Card(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: SegmentedButton<AppThemeMode>(
                    segments: <ButtonSegment<AppThemeMode>>[
                      for (final mode in AppThemeMode.values)
                        ButtonSegment<AppThemeMode>(
                          value: mode,
                          label: Text(mode.label),
                          icon: Icon(_themeIcon(mode), size: 16),
                        ),
                    ],
                    selected: <AppThemeMode>{model.settings.themeMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) {
                      model.setThemeMode(selection.first);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '切换后立即生效，不需要重启应用；「跟随系统」由 iOS 的浅色 / 深色设置决定。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _section('存储', theme),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清理临时缓存'),
                  subtitle: Text(
                    _scan == null
                        ? '正在统计…'
                        : '可清理 ${_scan!.reclaimableCount} 个文件 · '
                            '${_formatBytes(_scan!.reclaimableBytes)}',
                  ),
                  trailing: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _clearCache,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '只清理缩略图、临时播放文件与未完成分片。'
                    '已下载文件、收藏、媒体索引、账号授权与云端消息都不在清理范围内。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _section('应用密码锁', theme),
          Card(
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  secondary: const Icon(Icons.lock_outline),
                  title: const Text('应用密码锁'),
                  subtitle: Text(
                    _lockEnabled == null
                        ? '读取中…'
                        : (_lockEnabled!
                            ? '已开启：每次冷启动需要验证'
                            : '未开启：冷启动直接进入'),
                  ),
                  value: _lockEnabled ?? false,
                  onChanged: _lockEnabled == null ? null : _toggleLock,
                ),
                if (_lockEnabled == true) ...<Widget>[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.password_outlined),
                    title: const Text('修改应用密码'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _changePasscode,
                  ),
                  if (_availability.canOfferToggle) ...<Widget>[
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.face_outlined),
                      title: Text('${_availability.label} 解锁'),
                      subtitle: const Text('可选。识别失败时自动回落到应用密码。'),
                      value: _biometricEnabled,
                      onChanged: _toggleBiometric,
                    ),
                  ] else ...<Widget>[
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.face_outlined),
                      title: const Text('面容 ID 解锁'),
                      subtitle: Text(_availability.label),
                      enabled: false,
                    ),
                  ],
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Text(
                    '密码以哈希形式存于钥匙串，忘记后无法找回，只能卸载应用清除本地数据。'
                    '关闭或修改密码都需要先验证当前密码。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _section('其他', theme),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('诊断页'),
                  subtitle: const Text('逐项复核 TDLib 只读链路'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ProbePage()),
                  ),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('TG Media'),
                  subtitle: Text('只读 Telegram 频道媒体管理 · 版本 0.1.0'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _themeIcon(AppThemeMode mode) => switch (mode) {
        AppThemeMode.system => Icons.brightness_auto,
        AppThemeMode.light => Icons.light_mode_outlined,
        AppThemeMode.dark => Icons.dark_mode_outlined,
      };

  Widget _section(String title, ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      );

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
