# 真机运行证据（iPhone 11 Pro / iOS 15.x / TrollStore）

记录时间：2026-10-26 01:19（GMT+8）
证据来源：用户于 2026-10-26 01:14 提供两张屏幕截图（1440×3120 视口，状态栏时间 1:13）
构建产物：`TGMediaProbe-unsigned.ipa`，19,451,233 B，SHA256 `1a83e39be0c18d0d0ab403051f0f7fa1557f93affcd39f15daa62b7d8ad404ba`（CI run 40213205595，含第 3 步代码）

> 截图原文件在本地副本已不可得（桌面清空），本文件为逐字转录。所有判定只依据屏幕上可见的文本，不做补推。

## 1. 屏幕文本转录

### 截图 1（上半屏，标题区 + 只读链路段）

```
TG Media 可行性探针
[发送手机号 / 请求验证码]

3. 只读链路
[频道 → 消息 → 元数据 → 下载 → 播放]

✓  加载 TDLib 原生库
   tdjson 已加载（动态库符号解析成功）

✓  配置 TDLib 参数（api_id / api_hash 运行期输入）
   database=/var/mobile/Containers/Data/Application/26962250-0153-416D-9964-C1AB62709E43/Documents/tdlib/db

…  账号登录（验证码 / 两步验证）
   等待 Telegram 下发验证码

   读取已授权频道
```

### 截图 2（下半屏，频道到播放）

```
✓  读取已授权频道
   会话 3 个，其中频道 1 个

✓  读取频道消息
   18号仓储: 50 条消息

✓  读取视频元数据
   464x848 28s 5809108B fileId=4357

   下载真实媒体文件
   5809108/5809108 B → /private/var/mobile/Containers/Data/Application/
   26962250-0153-416D-9964-C1AB62709E43/Documents/tdlib/files/videos/bb4a413292c6.MP4

✓  校验本地文件（存在性 / 大小）
   5809108 B 与 TDLib 报告一致

✓  播放校验（AVPlayer 初始化）
   AVPlayer 已初始化，时长=27s
```

## 2. 逐项判定

| # | 检查项 | 判定 | 依据（屏幕原文） |
|---|---|---|---|
| 1 | TrollStore 安装 + App 启动 | **通过** | 进程在真机前台渲染出完整 UI |
| 2 | TDLib 原生符号解析 | **通过** | `tdjson 已加载（动态库符号解析成功）` |
| 3 | `setTdlibParameters` | **通过** | 回显真实容器 UUID 路径 `.../26962250-0153-416D-9964-C1AB62709E43/Documents/tdlib/db` |
| 4 | 验证码登录 → 授权态 ready | **通过（有 UI 缺陷）** | 后续能读频道即证明已 ready，但第 4 项文案仍停在「等待 Telegram 下发验证码」 |
| 5 | `getChats` + `is_channel` 过滤 | **通过** | `会话 3 个，其中频道 1 个` |
| 6 | `getChatHistory` 取消息 | **通过** | `18号仓储: 50 条消息` |
| 7 | messageVideo 元数据 | **通过** | `464x848 28s 5809108B fileId=4357`（TDLib 原始字段直出） |
| 8 | `downloadFile` 真实下载 | **通过（有 UI 缺陷）** | `5809108/5809108 B`，落盘 `bb4a413292c6.MP4` |
| 9 | 本地文件存在性 + 大小校验 | **通过** | `5809108 B 与 TDLib 报告一致`（说明代码走了 `exists()` + `length()` 双检查，不是只看进度条） |
| 10 | AVPlayer 初始化 | **通过** | `AVPlayer 已初始化，时长=27s` |

**结论：第 2 步定义的五段链路（频道 → 消息 → 元数据 → 下载 → 播放）在真机上全部打通，数据全部来自真实 Telegram 账号与真实频道，无一处模拟。**

## 3. 未验证（不计入通过）

| 项目 | 为什么还不算 |
|---|---|
| 实际画面渲染 / 音轨 / seek | 只证明 `AVPlayer` 构造成功并读到时长，没证明出帧、没证明有声 |
| 横竖屏切换 | 两张截图均为竖屏，无旋转证据；`AppDelegate.supportedInterfaceOrientationsFor` 在真机未触发过 |
| 分页翻页（offset） | 单次取 50 条即结束，`pageSize` clamp 与 keyset 逻辑未被真实触发 |
| 下载中断续传 | 5.5 MB 一次下完，未制造断网 |
| 退出重进后登录态保持 | 未做冷启 |
| 缓存清理安全性 | 第 3 步的四区隔离尚未接进探针，无可清理对象 |
| 多频道 / 大文件 / 长视频 | 样本只有 1 个频道、1 条 5.5 MB 28 秒视频 |

## 4. 证据暴露的真实问题

### A. 下载落在 TDLib file store，不在四区隔离内

屏幕路径：`Documents/tdlib/files/videos/bb4a413292c6.MP4`

代码位置 `lib/td/media_probe.dart:104-113`：

```dart
final root = Directory('${docs.path}/tdlib');
final dbDir = Directory('${root.path}/db');
final filesDir = Directory('${root.path}/files');
```

`files_directory` 指向 `Documents/tdlib/files`，这是 TDLib 自己管理的 file store。而 `lib/storage/storage_layout.dart` 定义的用户下载区是 `Documents/TGMediaDownloads`，临时缓存区是 `Library/Caches/tgmedia`。两者没有任何交集 —— 也就是说**第 3 步设计的分区在探针里根本没生效**，现在下载的文件躺在 TDLib 的池子里，被 TDLib 的引用计数和 `deleteFile` 逻辑管着。

后果：
- 清缓存时若按 `Documents/tdlib` 整目录删，会连 `db/`（TDLib 数据 + 会话）一起删掉，用户要重新验证码登录 —— 这违反第 3 步「不得误删登录授权」。
- 用户下载的文件混在 TDLib 缓存里，TDLib 认为它是可回收的，后续做 `optimizeStorage` 时可能被清掉，与「用户下载不可自动删除」冲突。

修法（第 4 步前必须做）：`files_directory` 移到 `Library/Caches/tgmedia/tdlib_files`（可重建），下载完成后由应用自己 `copy` 到 `Documents/TGMediaDownloads/<chatId>/<fileId>.mp4` 并写索引。TDLib 的池子只做中转，用户文件只认自建区。

### B. TDLib 数据库未加密

`lib/td/td_requests.dart:26`：

```dart
'database_encryption_key': '',
```

空串 = TDLib 用空 key 建库，本地 `tdlib/db` 里消息文本、频道标题、文件元数据全部明文可读。iOS 沙箱 + 设备加密能挡远程，挡不住拿到设备或越狱环境下的直接读取。TrollStore 场景恰恰是越狱/半越狱环境。

修法：key 用 `flutter_secure_storage`（Keychain）生成并保存的 32 字节随机值，首次启动生成、后续读取；key 丢失即视为需要重新登录，不做降级。

### C. 两处状态未刷新（UI 缺陷）

1. 截图 1 第 4 项（账号登录）图标是 `…`、文案「等待 Telegram 下发验证码」，但下面频道已经读到了 —— 登录成功路径没有把该步置 `success`，`ProbeStepState` 停在 running。
2. 截图 2 「下载真实媒体文件」左侧无勾，但下一项校验已成功 —— 下载完成（`is_downloading_completed` 且大小一致）后没有把第 7 步置 `success`。

两处都属于 `lib/td/media_probe.dart` 里 `_set()` 调用漏写，不影响功能，但会让人误判进度。第 4 步做正式 UI 时必须修掉，否则进度条永远停在 90%。

### D. 文案与实现不符

「tdjson 已加载（**动态库**符号解析成功）」—— 实际 TDLib 是**静态归档**链进主二进制（第 2 步已验证 `!<arch>` + 四个 `-Wl,-u` 符号），运行时用的是 `DynamicLibrary.process()` 查主镜像符号，没有独立动态库。文案应改为「符号已从主二进制解析」。

### E. 时长 28s vs 27s

TDLib `video.duration = 28`（整数秒），AVPlayer 报 27s（`CMTime` 截断到整秒）。同一段素材，取整方式不同，**不是缺陷**。正式 UI 统一以 TDLib 的整数秒为准做列表，播放器内部用 `CMTimeGetSeconds` 的 double 值时不要再取整。

## 5. 这一步的净结论

第 2 步链路验证成立，第 3 步的安全设计**尚未在真机上生效**（A、B 两项）。按流程下一个动作不是进第 4 步做 UI，而是先把 A、B 补上并在真机复测——否则 UI 做完了，底下仍是把用户文件塞进 TDLib 缓存池、数据库明文落盘。
