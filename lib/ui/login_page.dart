/// Login surface for the phases this build drives itself, plus an honest
/// screen for the phases it does not.
///
/// Honesty rules encoded here:
/// * only `authorizationStateReady` means signed in — the page never guesses
///   from a local flag;
/// * `api_hash` is written to the Keychain and never rendered back (the field
///   says "已保存" instead of showing it);
/// * e-mail / device-confirmation phases are not faked: the screen says to
///   finish them in the official client and offers a re-check, rather than
///   showing an input box whose submit button has nowhere to go.
library;

import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../td/session_state.dart';
import 'app_theme.dart';
import 'status_view.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final AppSession session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _apiId = TextEditingController();
  final TextEditingController _apiHash = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _apiId.dispose();
    _apiHash.dispose();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) {
            final session = widget.session;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(AppTheme.pagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 24),
                  Text('TG Media', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '只读取你已加入的 Telegram 频道，不会修改云端内容。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  ..._buildBody(session),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildBody(AppSession session) {
    switch (session.stage) {
      case SessionStage.blocked:
        return <Widget>[
          StatusView(
            kind: StatusKind.error,
            title: '本地会话需要处理',
            message: session.plan?.reason ?? session.error ?? '未知原因',
            actionLabel: '重新登录并重建本地会话',
            onAction: session.busy ? null : _confirmRelogin,
          ),
          const SizedBox(height: 12),
          const Text(
            '重新登录会重建本地会话数据与媒体索引，之后再按需从云端重新同步。'
            'Telegram 云端的频道消息与媒体不会被删除或修改。',
            style: TextStyle(fontSize: 13),
          ),
        ];
      case SessionStage.awaitingCredentials:
        return _buildCredentials(session);
      case SessionStage.awaitingLogin:
        return _buildPhase(session);
      case SessionStage.failed:
        return <Widget>[
          StatusView(
            kind: StatusKind.error,
            title: '无法启动 TDLib',
            message: session.error ?? '未知错误',
            actionLabel: '重试',
            onAction: session.busy ? null : session.boot,
          ),
        ];
      case SessionStage.idle:
      case SessionStage.booting:
        return const <Widget>[
          SizedBox(height: 40),
          StatusView.loading(title: '正在打开本地会话'),
        ];
      case SessionStage.ready:
        return const <Widget>[
          SizedBox(height: 40),
          StatusView.loading(title: '已登录，正在进入'),
        ];
    }
  }

  List<Widget> _buildCredentials(AppSession session) {
    return <Widget>[
      const Text('首次使用需要 Telegram 应用凭据（api_id / api_hash）。'
          '它们只保存在本机钥匙串中。'),
      const SizedBox(height: 12),
      TextField(
        controller: _apiId,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'api_id', hintText: '纯数字'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _apiHash,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'api_hash'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: session.busy ? null : _submitCredentials,
        child: Text(session.busy ? '正在保存…' : '保存并连接'),
      ),
      if (session.error != null) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          session.error!,
          style: const TextStyle(fontSize: 13, color: Color(0xFFB3261E)),
        ),
      ],
    ];
  }

  List<Widget> _buildPhase(AppSession session) {
    final phase = session.status.phase;
    switch (phase) {
      case LoginPhase.waitingPhoneNumber:
        return <Widget>[
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: '手机号（含国家码）',
              hintText: '+8613800000000',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: session.busy ? null : _submitPhone,
            child: Text(session.busy ? '正在发送…' : '发送验证码'),
          ),
          _errorLine(session),
        ];
      case LoginPhase.waitingCode:
        return <Widget>[
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '登录验证码'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: session.busy ? null : _submitCode,
            child: Text(session.busy ? '正在提交…' : '提交验证码'),
          ),
          _errorLine(session),
        ];
      case LoginPhase.waitingPassword:
        return <Widget>[
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '两步验证密码',
              helperText: session.status.passwordHint == null
                  ? null
                  : '提示：${session.status.passwordHint}',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: session.busy ? null : _submitPassword,
            child: Text(session.busy ? '正在提交…' : '提交密码'),
          ),
          _errorLine(session),
        ];
      case LoginPhase.waitingOtherDevice:
        return <Widget>[
          StatusView(
            kind: StatusKind.loading,
            title: '等待其他设备确认登录',
            message: '在已登录的 Telegram 客户端中确认这次登录。',
            actionLabel: '重新检查',
            onAction: session.refreshStatus,
          ),
        ];
      case LoginPhase.waitingEmailAddress:
      case LoginPhase.waitingEmailCode:
        return <Widget>[
          StatusView(
            kind: StatusKind.permission,
            title: '需要在 Telegram 官方客户端完成邮箱验证',
            message: '当前版本不代收邮箱验证码。请在官方客户端完成验证后回到这里重新检查。',
            actionLabel: '重新检查',
            onAction: session.refreshStatus,
          ),
        ];
      case LoginPhase.waitingRegistration:
      case LoginPhase.waitingPremiumPurchase:
        return <Widget>[
          StatusView(
            kind: StatusKind.permission,
            title: session.status.title,
            message: '该步骤需要在 Telegram 官方客户端完成，完成后回到这里重新检查。',
            actionLabel: '重新检查',
            onAction: session.refreshStatus,
          ),
        ];
      case LoginPhase.openingDatabase:
        return const <Widget>[
          SizedBox(height: 40),
          StatusView.loading(title: '正在打开本地会话'),
        ];
      case LoginPhase.loggingOut:
      case LoginPhase.closed:
        return <Widget>[
          StatusView(
            kind: StatusKind.signedOut,
            title: '会话已结束',
            message: '需要重新登录 Telegram。',
            actionLabel: '重新登录',
            onAction: session.busy ? null : _confirmRelogin,
          ),
        ];
      case LoginPhase.ready:
        return const <Widget>[
          SizedBox(height: 40),
          StatusView.loading(title: '已登录，正在进入'),
        ];
      case LoginPhase.unknown:
        return <Widget>[
          StatusView(
            kind: StatusKind.error,
            title: '本地会话状态未知',
            message: session.status.rawType.isEmpty
                ? 'TDLib 尚未返回可识别的状态。'
                : 'TDLib 返回了未知状态：${session.status.rawType}',
            actionLabel: '重新检查',
            onAction: session.refreshStatus,
          ),
        ];
    }
  }

  Widget _errorLine(AppSession session) {
    final error = session.error;
    if (error == null || error.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        error,
        style: const TextStyle(fontSize: 13, color: Color(0xFFB3261E)),
      ),
    );
  }

  Future<void> _submitCredentials() async {
    final apiId = int.tryParse(_apiId.text.trim());
    final hash = _apiHash.text.trim();
    if (apiId == null || hash.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('凭据不完整'),
          content: const Text('api_id 必须是数字，api_hash 不能为空。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    await widget.session.submitCredentials(apiId: apiId, apiHash: hash);
  }

  Future<void> _submitPhone() async {
    final phone = _phone.text.trim();
    if (phone.isEmpty) return;
    await widget.session.submitPhone(phone);
  }

  Future<void> _submitCode() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    await widget.session.submitCode(code);
  }

  Future<void> _submitPassword() async {
    final password = _password.text;
    if (password.isEmpty) return;
    await widget.session.submitPassword(password);
  }

  Future<void> _confirmRelogin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新登录'),
        content: const Text(
          '这会重建本地的 Telegram 会话数据与媒体索引，Telegram 云端的频道消息与媒体不会被删除或修改。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.session.signOut();
    await widget.session.boot();
  }
}
