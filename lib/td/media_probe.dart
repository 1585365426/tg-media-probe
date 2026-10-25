import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../security/tdlib_key.dart';
import '../storage/download_mover.dart';
import '../storage/storage_layout.dart';
import '../util/redact.dart';
import 'td_client.dart';
import 'td_models.dart';
import 'td_requests.dart';

enum ProbeStepState { pending, running, success, failed, skipped }

class ProbeStep {
  ProbeStep(this.title, {this.state = ProbeStepState.pending, this.detail = ''});

  final String title;
  ProbeStepState state;
  String detail;

  String get symbol {
    switch (state) {
      case ProbeStepState.pending:
        return '·';
      case ProbeStepState.running:
        return '…';
      case ProbeStepState.success:
        return '✓';
      case ProbeStepState.failed:
        return '✗';
      case ProbeStepState.skipped:
        return '–';
    }
  }
}

class ProbeResult {
  const ProbeResult({
    required this.ok,
    required this.message,
    this.chatId,
    this.messageId,
    this.video,
    this.localPath,
    this.poolPath,
  });

  final bool ok;
  final String message;
  final int? chatId;
  final int? messageId;
  final VideoMeta? video;

  /// File the player should open: the copy inside the user download zone.
  final String? localPath;

  /// TDLib's own copy inside the rebuildable pool, kept for diagnostics.
  final String? poolPath;
}

/// What [ProbeRunner.initialize] actually configured, so the UI can show the
/// real paths instead of assuming them.
class ProbeInitInfo {
  const ProbeInitInfo({
    required this.databaseDir,
    required this.filesDir,
    required this.keyMask,
    required this.legacyPlaintextDb,
  });

  final String databaseDir;
  final String filesDir;
  final String keyMask;

  /// True when a pre-encryption database from an earlier build is still on
  /// disk. It is left untouched, but the user has to log in again because the
  /// new database lives elsewhere and uses a different key.
  final bool legacyPlaintextDb;
}

/// Runs the minimal real-data chain:
/// login -> authorised channels -> channel messages -> video metadata ->
/// download -> local file verification. Playback is verified by the UI layer
/// because it needs AVPlayer; the UI reports back via [reportPlayback].
class ProbeRunner {
  ProbeRunner({
    required this.client,
    required this.layout,
    DownloadMover? mover,
  }) : mover = mover ?? DownloadMover(layout: layout);

  final TdClient client;
  final StorageLayout layout;
  final DownloadMover mover;

  final List<ProbeStep> steps = <ProbeStep>[
    ProbeStep('加载 TDLib 原生库'),
    ProbeStep('配置 TDLib 参数（api_id / api_hash 运行期输入）'),
    ProbeStep('账号登录（验证码 / 两步验证）'),
    ProbeStep('读取已授权频道'),
    ProbeStep('读取频道消息'),
    ProbeStep('读取视频元数据'),
    ProbeStep('下载真实媒体文件'),
    ProbeStep('复制到用户下载区（校验大小）'),
    ProbeStep('播放校验（AVPlayer 初始化）'),
  ];

  VoidCallback? onChanged;

  VideoMeta? lastVideo;
  int? lastChatId;
  int? lastMessageId;
  String? lastLocalPath;

  ProbeStep step(int index) => steps[index - 1];

  void _set(int index, ProbeStepState state, [String detail = '']) {
    final s = step(index);
    s.state = state;
    s.detail = redactText(detail);
    onChanged?.call();
  }

  void markLibraryLoaded(String path) => _set(1, ProbeStepState.success, path);

  /// Configures TDLib against the four storage zones.
  ///
  /// The database goes into the protected auth zone (it *is* the session) and
  /// the blob pool goes into the purgeable temp zone. Neither is under
  /// `Documents`, which is what the previous build did and what made a
  /// whole-directory cleanup able to wipe the login.
  Future<ProbeInitInfo> initialize({
    required int apiId,
    required String apiHash,
    required String databaseEncryptionKey,
  }) async {
    _set(2, ProbeStepState.running);
    try {
      await layout.ensureCreated();
      final dbDir = Directory(layout.tdlibDatabaseDir);
      final filesDir = Directory(layout.tdlibFilesDir);
      await dbDir.create(recursive: true);
      await filesDir.create(recursive: true);

      // Detect the plaintext database written by the previous build. It is not
      // deleted here — that would be destroying user data to fix a bug.
      bool legacy = false;
      try {
        final docs = await getApplicationDocumentsDirectory();
        legacy = await Directory('${docs.path}/tdlib/db').exists();
      } catch (_) {
        legacy = false;
      }

      final response = await client.request(
        setTdlibParameters(
          apiId: apiId,
          apiHash: apiHash,
          databaseDirectory: dbDir.path,
          filesDirectory: filesDir.path,
          databaseEncryptionKey: databaseEncryptionKey,
          systemVersion: Platform.operatingSystemVersion,
        ),
        timeout: const Duration(seconds: 60),
      );
      final err = errorText(response);
      if (err != null) {
        _set(2, ProbeStepState.failed, err);
        throw StateError(err);
      }
      _set(2, ProbeStepState.success,
          'db=${dbDir.path}（加密 key ${TdlibDatabaseKey.mask(databaseEncryptionKey)}）');
      return ProbeInitInfo(
        databaseDir: dbDir.path,
        filesDir: filesDir.path,
        keyMask: TdlibDatabaseKey.mask(databaseEncryptionKey),
        legacyPlaintextDb: legacy,
      );
    } catch (e) {
      _set(2, ProbeStepState.failed, e.toString());
      rethrow;
    }
  }

  Future<void> submitPhone(String phone) async {
    _set(3, ProbeStepState.running, '等待 Telegram 下发验证码');
    final response =
        await client.request(setAuthenticationPhoneNumber(phone.trim()));
    final err = errorText(response);
    if (err != null) {
      _set(3, ProbeStepState.failed, err);
      throw StateError(err);
    }
  }

  Future<void> submitCode(String code) async {
    final response = await client.request(checkAuthenticationCode(code.trim()));
    final err = errorText(response);
    if (err != null) {
      _set(3, ProbeStepState.failed, err);
      throw StateError(err);
    }
  }

  Future<void> submitPassword(String password) async {
    final response =
        await client.request(checkAuthenticationPassword(password));
    final err = errorText(response);
    if (err != null) {
      _set(3, ProbeStepState.failed, err);
      throw StateError(err);
    }
  }

  void markAuthorized() => _set(3, ProbeStepState.success, 'authorizationStateReady');

  /// Full read-only chain against real Telegram data.
  Future<ProbeResult> runChain({
    int? preferChatId,
    int historyLimit = 50,
    Duration downloadTimeout = const Duration(minutes: 5),
  }) async {
    try {
      // ---- 4. channels -------------------------------------------------
      _set(4, ProbeStepState.running);
      final chatsResponse = await client.request(getChats(limit: 200));
      final chatIds = chatIdsFromResponse(chatsResponse);
      if (chatIds.isEmpty) {
        _set(4, ProbeStepState.failed, 'getChats 返回 0 个会话');
        return const ProbeResult(ok: false, message: '没有可访问的会话');
      }

      final channels = <ChatSummary>[];
      for (final id in chatIds) {
        final chatResponse = await client.request(getChat(id));
        final chat = chatFromResponse(chatResponse);
        if (chat != null && chat.isChannel) channels.add(chat);
      }
      _set(4, ProbeStepState.success,
          '会话 ${chatIds.length} 个，其中频道 ${channels.length} 个');
      if (channels.isEmpty) {
        return const ProbeResult(ok: false, message: '账号未加入任何频道');
      }

      final chat = preferChatId != null
          ? channels.firstWhere((c) => c.id == preferChatId,
              orElse: () => channels.first)
          : channels.first;
      lastChatId = chat.id;

      // ---- 5. messages -------------------------------------------------
      _set(5, ProbeStepState.running, chat.title);
      final historyResponse = await client.request(
        getChatHistory(chatId: chat.id, limit: historyLimit),
      );
      final messages = messagesFromResponse(historyResponse);
      _set(5, messages.isEmpty ? ProbeStepState.failed : ProbeStepState.success,
          '${chat.title}: ${messages.length} 条消息');
      if (messages.isEmpty) {
        return ProbeResult(
            ok: false, message: '频道 ${chat.title} 在最近 $historyLimit 条内无消息');
      }

      // ---- 6. metadata -------------------------------------------------
      _set(6, ProbeStepState.running);
      Map<String, Object?>? videoMessage;
      VideoMeta? video;
      for (final message in messages) {
        final meta = VideoMeta.fromMessage(message);
        if (meta != null) {
          videoMessage = message;
          video = meta;
          break;
        }
      }
      if (video == null || videoMessage == null) {
        _set(6, ProbeStepState.failed, '最近 $historyLimit 条消息中没有 messageVideo');
        return ProbeResult(
            ok: false, message: '未找到视频消息，无法继续验证播放与下载');
      }
      lastVideo = video;
      lastMessageId = (videoMessage['id'] as num?)?.toInt();
      _set(
        6,
        ProbeStepState.success,
        '${video.width}x${video.height} ${video.durationSeconds}s '
        '${video.expectedSize}B fileId=${video.fileId}',
      );

      if (video.fileId == 0) {
        _set(7, ProbeStepState.failed, 'video.file.id 为空');
        return ProbeResult(ok: false, message: '媒体文件标识为空');
      }

      // ---- 7. download -------------------------------------------------
      _set(7, ProbeStepState.running, '请求 downloadFile');
      final completion = Completer<FileState>();
      late final StreamSubscription<Map<String, Object?>> sub;
      sub = client.fileUpdates.listen((file) {
        final state = FileState.fromJson(file);
        if (state.id != video!.fileId) return;
        if (state.isCompleted) {
          if (!completion.isCompleted) completion.complete(state);
        } else {
          _set(7, ProbeStepState.running,
              '${state.downloadedSize}/${state.expectedSize} B');
        }
      });

      final downloadResponse =
          await client.request(downloadFile(fileId: video.fileId));
      final downloadErr = errorText(downloadResponse);
      if (downloadErr != null) {
        await sub.cancel();
        _set(7, ProbeStepState.failed, downloadErr);
        return ProbeResult(ok: false, message: downloadErr);
      }

      FileState finalState;
      try {
        finalState = await completion.future.timeout(downloadTimeout);
      } on TimeoutException {
        await sub.cancel();
        _set(7, ProbeStepState.failed,
            '下载超时（${downloadTimeout.inMinutes} 分钟内未完成）');
        return ProbeResult(ok: false, message: '下载超时');
      }
      await sub.cancel();
      final expected =
          finalState.size > 0 ? finalState.size : finalState.expectedSize;
      _set(
        7,
        ProbeStepState.success,
        '${finalState.downloadedSize}/${finalState.expectedSize} B '
        '→ TDLib 池 ${finalState.path}',
      );

      // ---- 8. promote into the user download zone -----------------------
      _set(8, ProbeStepState.running);
      final DownloadMoveResult promoted;
      try {
        promoted = await mover.promote(
          sourcePath: finalState.path,
          chatId: chat.id,
          fileId: video.fileId,
          expectedBytes: expected,
          fileName: video.fileName,
          mimeType: video.mimeType,
        );
      } on DownloadPromoteException catch (e) {
        _set(8, ProbeStepState.failed, e.toString());
        return ProbeResult(ok: false, message: e.message);
      }
      lastLocalPath = promoted.path;
      _set(
        8,
        ProbeStepState.success,
        '${promoted.bytes} B → ${promoted.path}'
        '${promoted.reused ? '（复用已有文件）' : ''}',
      );

      return ProbeResult(
        ok: true,
        message: '链路完成：频道 ${chat.title}，视频 ${video.width}x${video.height}',
        chatId: chat.id,
        messageId: lastMessageId,
        video: video,
        localPath: promoted.path,
        poolPath: finalState.path,
      );
    } catch (e) {
      final text = redactText(e.toString());
      for (var i = 1; i <= steps.length; i++) {
        if (steps[i - 1].state == ProbeStepState.running) {
          _set(i, ProbeStepState.failed, text);
        }
      }
      return ProbeResult(ok: false, message: text);
    }
  }

  void reportPlayback({
    required bool initialized,
    Duration? duration,
    String? error,
  }) {
    if (initialized) {
      _set(9, ProbeStepState.success,
          'AVPlayer 已初始化，时长=${duration?.inSeconds ?? '?'}s');
    } else {
      _set(9, ProbeStepState.failed, error ?? '播放器初始化失败');
    }
  }
}

typedef VoidCallback = void Function();
