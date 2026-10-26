import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:video_player/video_player.dart';

import '../security/tdlib_key.dart';
import '../storage/active_files.dart';
import '../storage/app_paths.dart';
import '../storage/file_ops.dart';
import '../storage/storage_layout.dart';
import '../storage/temp_zone_report.dart';
import '../td/media_probe.dart';
import '../td/td_client.dart';
import '../td/td_models.dart';
import '../util/redact.dart';
import 'storage_panel.dart';

/// Minimal verification UI. It is deliberately not the product UI: the only
/// job is to prove each step of the chain with real Telegram data and real
/// device capabilities.
class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final _apiId = TextEditingController();
  final _apiHash = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();

  TdClient? _client;
  ProbeRunner? _runner;
  VideoPlayerController? _video;
  AuthStage _stage = AuthStage.unknown;
  String _status = '未初始化 TDLib';
  bool _busy = false;
  bool _credentialsSaved = false;
  StorageLayout? _layout;
  ProbeInitInfo? _initInfo;
  TempZoneReport? _storageReport;

  /// Files the player currently holds open. Registered so a cache clear can
  /// skip them instead of pulling a file out from under the decoder.
  final ActiveFileRegistry _activeFiles = ActiveFileRegistry();
  String? _playingPath;

  @override
  void initState() {
    super.initState();
    _restoreCredentials();
  }

  @override
  void dispose() {
    _releasePlayingPath();
    _video?.dispose();
    _client?.dispose();
    _apiId.dispose();
    _apiHash.dispose();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _restoreCredentials() async {
    final id = await _storage.read(key: 'tg_api_id');
    final hash = await _storage.read(key: 'tg_api_hash');
    if (!mounted) return;
    setState(() {
      if (id != null) _apiId.text = id;
      // The hash is never rendered back; only its presence is shown.
      _credentialsSaved = hash != null;
    });
  }

  Future<void> _saveCredentials() async {
    final id = int.tryParse(_apiId.text.trim());
    final hash = _apiHash.text.trim();
    if (id == null || hash.isEmpty) {
      setState(() => _status = 'api_id 必须是数字，api_hash 不能为空');
      return;
    }
    await _storage.write(key: 'tg_api_id', value: id.toString());
    await _storage.write(key: 'tg_api_hash', value: hash);
    if (!mounted) return;
    setState(() {
      _credentialsSaved = true;
      _status = '凭据已写入 Keychain（不回显 api_hash）';
    });
  }

  Future<String?> _readHash() async {
    final current = _apiHash.text.trim();
    if (current.isNotEmpty) return current;
    return _storage.read(key: 'tg_api_hash');
  }

  Future<void> _initTdlib() async {
    setState(() {
      _busy = true;
      _status = '正在加载 TDLib 原生库…';
    });
    try {
      final apiId = int.tryParse(_apiId.text.trim());
      final apiHash = await _readHash();
      if (apiId == null || apiHash == null) {
        throw StateError('缺少 api_id 或 api_hash');
      }

      final layout = await AppPaths.resolveLayout();
      await layout.ensureCreated();

      // The database key never leaves the Keychain; only its masked form is
      // ever rendered.
      final dbKey = await TdlibDatabaseKey(store: const KeychainSecretStore())
          .obtain();

      final client = TdClient.open();
      final runner = ProbeRunner(client: client, layout: layout)
        ..onChanged = () {
          if (mounted) setState(() {});
        };
      runner.markLibraryLoaded(
          'tdjson 已加载（静态链接，符号从主二进制解析）');

      _client = client;
      _runner = runner;
      client.updates.listen((event) {
        if (event['@type'] != 'updateAuthorizationState') return;
        final raw = event['authorization_state'];
        if (raw is! Map) return;
        final state = AuthState.fromJson(raw.cast<String, Object?>());
        if (!mounted) return;
        setState(() => _stage = state.stage);
        // TDLib reaching authorizationStateReady is the only proof of a
        // completed login. Without this the login step stays "running"
        // forever even though the chain below already works.
        if (state.stage == AuthStage.ready) {
          runner.markAuthorized();
        }
      });

      final info = await runner.initialize(
        apiId: apiId,
        apiHash: apiHash,
        databaseEncryptionKey: dbKey,
      );
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _initInfo = info;
        // Built here, not in build(): the report holds the file-system surface
        // and the in-use registry, both of which must survive a rebuild.
        _storageReport = TempZoneReport(
          layout: layout,
          ops: const IoFileOps(),
          activeFiles: _activeFiles,
        );
        _status = 'TDLib 已配置（数据库已加密），等待手机号';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '初始化失败: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPhone() async {
    setState(() => _busy = true);
    try {
      await _runner?.submitPhone(_phone.text);
      if (!mounted) return;
      setState(() => _status = '验证码已请求，请查看 Telegram 官方客户端/短信');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '发送手机号失败: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    setState(() => _busy = true);
    try {
      await _runner?.submitCode(_code.text);
      if (!mounted) return;
      setState(() => _status = '验证码已提交');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '验证码失败: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPassword() async {
    setState(() => _busy = true);
    try {
      await _runner?.submitPassword(_password.text);
      if (!mounted) return;
      setState(() => _status = '两步验证密码已提交');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '两步验证失败: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runChain() async {
    final runner = _runner;
    if (runner == null) return;
    setState(() {
      _busy = true;
      _status = '正在跑链路探针…';
    });
    try {
      final result = await runner.runChain();
      if (!mounted) return;
      setState(() => _status = result.ok ? result.message : '失败: ${result.message}');
      if (result.ok && result.localPath != null) {
        await _playVideo(result.localPath!, runner);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '探针异常: ${redactText(e.toString())}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playVideo(String path, ProbeRunner runner) async {
    await _releaseVideo();
    // Register before handing the file to AVPlayer, so a cache clear that lands
    // mid-playback skips it rather than deleting the bytes being decoded.
    _activeFiles.markInUse(path, reason: 'playing');
    _playingPath = path;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.play();
      _video = controller;
      runner.reportPlayback(
        initialized: true,
        duration: controller.value.duration,
      );
    } catch (e) {
      await controller.dispose();
      _releasePlayingPath();
      runner.reportPlayback(initialized: false, error: e.toString());
    }
    if (mounted) setState(() {});
  }

  void _releasePlayingPath() {
    final path = _playingPath;
    if (path == null) return;
    _activeFiles.release(path);
    _playingPath = null;
  }

  Future<void> _releaseVideo() async {
    _releasePlayingPath();
    await _video?.dispose();
    _video = null;
  }

  @override
  Widget build(BuildContext context) {
    final runner = _runner;
    return Scaffold(
      appBar: AppBar(title: const Text('TG Media 可行性探针')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _section('1. 凭据（运行期输入，Keychain 存储）'),
          TextField(
            controller: _apiId,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'api_id'),
          ),
          TextField(
            controller: _apiHash,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'api_hash',
              hintText: _credentialsSaved ? '已保存于 Keychain，留空表示复用' : null,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: _busy ? null : _saveCredentials,
                child: const Text('保存到 Keychain'),
              ),
              FilledButton(
                onPressed: _busy ? null : _initTdlib,
                child: const Text('初始化 TDLib'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('登录阶段: ${_stage.name}', style: Theme.of(context).textTheme.bodySmall),
          Text('状态: $_status', style: Theme.of(context).textTheme.bodySmall),
          const Divider(height: 32),

          _section('2. 登录'),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: '手机号（含国家码）',
              hintText: '+8613800000000',
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '登录验证码'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _busy ? null : _sendCode,
                child: const Text('提交验证码'),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '两步验证密码（如启用）'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _busy ? null : _sendPassword,
                child: const Text('提交密码'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _sendPhone,
            child: const Text('发送手机号 / 请求验证码'),
          ),
          const Divider(height: 32),

          _section('3. 只读链路'),
          FilledButton(
            onPressed: (_busy || _stage != AuthStage.ready) ? null : _runChain,
            child: const Text('频道 → 消息 → 元数据 → 下载 → 播放'),
          ),
          if (_stage != AuthStage.ready)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('需先完成真实登录（authorizationStateReady）'),
            ),
          const SizedBox(height: 12),
          if (runner != null)
            ...runner.steps.map(
              (step) => ListTile(
                dense: true,
                leading: Text(step.symbol,
                    style: const TextStyle(fontSize: 18, fontFamily: 'monospace')),
                title: Text(step.title),
                subtitle: step.detail.isEmpty ? null : Text(step.detail),
              ),
            ),
          const SizedBox(height: 12),
          if (_video != null && _video!.value.isInitialized)
            AspectRatio(
              aspectRatio: _video!.value.aspectRatio,
              child: VideoPlayer(_video!),
            ),
          if (_initInfo != null) ...<Widget>[
            const Divider(height: 32),
            _section('4. 存储落点（四区隔离）'),
            _pathLine('TDLib 数据库（加密 / 受保护）', _initInfo!.databaseDir),
            _pathLine('TDLib 文件池（可重建）', _initInfo!.filesDir),
            if (_layout != null)
              _pathLine('用户下载区（受保护）', _layout!.downloadsDir),
            if (_initInfo!.legacyPlaintextDb)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '检测到旧版明文库 Documents/tdlib/db，已保留未删除。'
                  '新版本改用加密库，需重新登录一次。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB3261E)),
                ),
              ),
          ],
          if (_storageReport != null) ...<Widget>[
            const Divider(height: 32),
            StoragePanel(report: _storageReport!),
          ],
        ],
      ),
    );
  }

  Widget _pathLine(String label, String path) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            SelectableText(
              path,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ],
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}
