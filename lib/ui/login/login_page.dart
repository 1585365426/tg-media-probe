import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../app/app_services.dart';
import '../../security/tdlib_key.dart';
import '../../td/media_probe.dart';
import '../../td/td_client.dart';
import '../../td/td_models.dart';
import '../../util/redact.dart';

/// Telegram sign-in.
///
/// Reuses [ProbeRunner] for the TDLib handshake instead of duplicating the
/// `setTdlibParameters` / phone / code / password sequence a second time: that
/// path is the one already proven on device in step 3.
///
/// Launch-time restore ([SessionRestore]) may hand this screen a client that is
/// **already configured against the on-disk database**. In that case the only
/// thing left is the step TDLib asked for — a code, the 2FA password, or the
/// phone number when the session expired. Opening a second client here instead
/// would hit TDLib's exclusive lock on `td.binlog` and fail with
/// `error 400: Can't lock file ... already in use`.
///
/// Credentials: `api_id` / `api_hash` are typed by the user (they are not
/// shipped in the binary), written to the Keychain, and never logged. The phone
/// number and the login code are only held in controllers for the duration of
/// the flow.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.services, this.onReady});

  final AppServices services;
  final void Function(TdClient client)? onReady;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final TextEditingController _apiId = TextEditingController();
  final TextEditingController _apiHash = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();

  TdClient? _client;
  ProbeRunner? _runner;
  AuthStage _stage = AuthStage.unknown;
  bool _busy = false;
  String _status = '请填写 api_id / api_hash 后点击连接';

  /// True once `setTdlibParameters` succeeded for [_client] — either here or in
  /// the launch-time restore that handed the client over. Calling it twice
  /// against the same directory is not harmless: TDLib refuses to reconfigure a
  /// live database, and the attempt can leave the session unusable.
  bool _parametersConfigured = false;

  /// Set when [_client] was given to [AppServices]; from then on the services
  /// container owns its lifetime.
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _prefill();
    final adopted = widget.services.takeAdoptedSession();
    if (adopted != null) _attachAdopted(adopted);
  }

  /// Continues an existing session instead of starting a new one.
  void _attachAdopted(AdoptedSession adopted) {
    _client = adopted.client;
    _parametersConfigured = true;
    _runner = ProbeRunner(client: adopted.client, layout: widget.services.layout);
    _stage = adopted.stage;
    _status = switch (adopted.stage) {
      AuthStage.ready => '会话已恢复',
      AuthStage.waitPhoneNumber => '会话已失效，请重新填写手机号',
      AuthStage.waitCode => '需要登录验证码',
      AuthStage.waitPassword => '需要两步验证密码',
      AuthStage.waitOtherDeviceConfirmation => '请在另一台设备上确认登录',
      _ => '会话状态：${adopted.stage.name}',
    };
    _listen(adopted.client);
  }

  void _listen(TdClient client) {
    _updates = client.updates.listen((event) {
      if (event['@type'] != 'updateAuthorizationState') return;
      final raw = event['authorization_state'];
      if (raw is! Map) return;
      final state = AuthState.fromJson(raw.cast<String, Object?>());
      if (!mounted) return;
      setState(() => _stage = state.stage);
      if (state.stage == AuthStage.ready) {
        _runner?.markAuthorized();
        _onAuthorized();
      }
    });
  }

  @override
  void dispose() {
    _updates?.cancel();
    // A client that never made it into [AppServices] keeps TDLib's file lock on
    // td.binlog for the rest of the process, which would make the next sign-in
    // attempt fail. Release it unless ownership was transferred.
    if (!_handedOff) {
      final client = _client;
      if (client != null) {
        client.dispose();
      }
    }
    _apiId.dispose();
    _apiHash.dispose();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    try {
      final id = await _storage.read(key: 'tg_api_id');
      final hash = await _storage.read(key: 'tg_api_hash');
      if (!mounted) return;
      setState(() {
        if (id != null) _apiId.text = id;
        if (hash != null) _apiHash.text = hash;
      });
    } catch (_) {
      // Keychain unreadable: the user simply types them again.
    }
  }

  Future<void> _persistCredentials(int apiId, String apiHash) async {
    try {
      await _storage.write(key: 'tg_api_id', value: '$apiId');
      await _storage.write(key: 'tg_api_hash', value: apiHash);
    } catch (_) {
      // Not being able to remember them is not a reason to block sign-in.
    }
  }

  Future<void> _connect() async {
    if (_busy) return;

    // The launch gate already configured this client against the on-disk
    // database. Re-sending setTdlibParameters would be a no-op at best and a
    // lock conflict at worst, so jump straight to whichever step TDLib named.
    if (_client != null && _parametersConfigured) {
      setState(() {
        _status = _stage == AuthStage.waitPhoneNumber
            ? '会话已失效，请填写手机号后发送'
            : '已连接到本机会话，当前阶段：${_stage.name}';
      });
      return;
    }

    final apiId = int.tryParse(_apiId.text.trim());
    final apiHash = _apiHash.text.trim();
    if (apiId == null || apiHash.isEmpty) {
      setState(() => _status = 'api_id 必须是数字，api_hash 不能为空');
      return;
    }

    setState(() {
      _busy = true;
      _status = '正在加载 TDLib…';
    });

    try {
      final dbKey = await TdlibDatabaseKey(store: const KeychainSecretStore())
          .obtain();
      // Reuse a client that failed to configure last time rather than opening a
      // second one: one client per database directory, always.
      final client = _client ?? TdClient.open();
      final runner = ProbeRunner(client: client, layout: widget.services.layout);
      _client = client;
      _runner = runner;
      if (_updates == null) _listen(client);

      await runner.initialize(
        apiId: apiId,
        apiHash: apiHash,
        databaseEncryptionKey: dbKey,
      );
      _parametersConfigured = true;
      await _persistCredentials(apiId, apiHash);
      if (!mounted) return;
      setState(() => _status = 'TDLib 已配置（数据库加密），请发送手机号');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '连接失败：${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Held only so `dispose` can cancel it; the client's own broadcast
  /// stream keeps running for the rest of the app.
  StreamSubscription<Map<String, Object?>>? _updates;

  void _onAuthorized() {
    final client = _client;
    if (client == null) return;
    widget.services.attachClient(client);
    // Ownership just moved: dispose() must not close a client the rest of the
    // app is now using.
    _handedOff = true;
    setState(() => _status = '登录成功');
    widget.onReady?.call(client);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _submitPhone() async {
    if (_busy) return;
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _status = '请填写手机号（含国家码，例如 +8613800000000）');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在请求验证码…';
    });
    try {
      await _runner?.submitPhone(phone);
      if (!mounted) return;
      setState(() => _status = '验证码已请求，请在 Telegram 官方客户端查看');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '发送失败：${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitCode() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在校验验证码…';
    });
    try {
      await _runner?.submitCode(_code.text);
      if (!mounted) return;
      setState(() => _status = '验证码已提交');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '验证码错误：${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitPassword() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在校验两步验证密码…';
    });
    try {
      await _runner?.submitPassword(_password.text);
      if (!mounted) return;
      setState(() => _status = '两步验证已提交');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '两步验证失败：${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _client != null;

    return Scaffold(
      appBar: AppBar(title: const Text('登录 Telegram')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('接口凭据', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    '在 my.telegram.org 自建应用获取。保存在钥匙串，不会写入日志或随包分发。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _apiId,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'api_id',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _apiHash,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'api_hash',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Text(
                      _parametersConfigured
                          ? '会话已就绪（跳过初始化）'
                          : (connected ? '重新连接' : '连接并初始化 TDLib'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('登录', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: '手机号（含国家码）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      enabled: _stage == AuthStage.waitPhoneNumber ||
                          _stage == AuthStage.unknown,
                      helperText: '手机号只用于本次登录，不在本机另存',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _busy ? null : _submitPhone,
                    child: const Text('发送手机号 / 请求验证码'),
                  ),
                  if (_stage == AuthStage.waitCode) ...<Widget>[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '登录验证码',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: _busy ? null : _submitCode,
                      child: const Text('提交验证码'),
                    ),
                  ],
                  if (_stage == AuthStage.waitPassword) ...<Widget>[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '两步验证密码',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: _busy ? null : _submitPassword,
                      child: const Text('提交两步验证'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('登录阶段：${_stage.name}', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(_status, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
