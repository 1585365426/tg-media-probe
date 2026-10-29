# STEP 1 审计：把播放链收敛到 LOCAL_FILE

> 本文件是 STEP 1 的唯一交付物。**没有改任何代码**（`git status` 干净，`flutter analyze` 见 §1）。
> 目的：在做任何重构之前，把"现在这条链到底由哪些文件组成、谁调谁、哪些能留"钉成事实。

日期：2026-10-29 ｜ 分支 `rebuild-step3` ｜ HEAD `deb13c7`

---

## 0. 这一阶段做了什么、没做什么

做了：读代码、读历史报告、读 E1 设备结果、跑静态分析、把每一层的入口和依赖关系摊开。

没做（按任务书 §29 STEP 1 的边界）：没改代码，没删旧链路，没写 DownloadManager，
没写播放器，没动 `ios/Runner/Streaming/`，没引 FFmpeg，没碰 AVAssetResourceLoader。

---

## 1. 基线

| 项 | 实测值 | 取法 |
|---|---|---|
| 提交 | `deb13c7 docs(probes): record E1 as NOT TESTED…` | `git log -1` |
| 工作区 | 干净 | `git status --short` |
| lib 规模 | 72 个 Dart 文件 / 28,149 行 | `find lib -name '*.dart' \| wc -l`、`wc -l` |
| test 规模 | 64 个文件 / 19,579 行 / 984 处 `test(` | `ls test/*.dart \| wc -l`、`grep -c` |
| 静态分析 | **No issues found!（9.5s）** | `flutter analyze`（本轮现跑） |
| 全量测试 | 1003 passed / 1 skipped | 上一次 CI run `40805271881`（本轮未重跑） |
| iOS 构建 | `CI BUILD PASS`（macOS runner，未签名 IPA） | 同上 |
| 真机 | iPhone 11 Pro / iOS 15.3.1，E1 设备报告已回传 | 用户提供 |
| 原生代码 | `ios/Runner/` 下 4 个 Swift 文件 / 1,431 行，全部是流式与控制通道 | `wc -l ios/Runner/**/*.swift` |

结论：基线是绿的。后面所有"要改"都发生在绿的基础上，因此每一步都必须保持绿。

---

## 2. E1 的收口：`E1 = FAIL`（已接受，不再尝试边下边播）

用户回传的设备结果（原文摘录）：

```text
device=iOS 15.3.1   TDLib=1.8.69   fileId=4376   fileSize=2362816   E1=FAIL
chunk #0 [0,1048576)          POSIX=1048576  readFilePart=1048576
chunk #1 [1048576,2097152)    POSIX=0        readFilePart=0
                              TDLib error 400: There is not enough downloaded bytes in the file to read
chunk #2 [2097152,3145728)    POSIX=0        readFilePart=0
```

三条事实可以直接从这组数字读出来，不需要推理：

1. **chunk#0 能读** —— 文件开头 1 MB 是连续可读的。所以"文件已存在、路径有效"不是问题。
2. **chunk#1 在同一个文件、同一时刻读不到任何字节**，而且 `readFilePart` 回的是 TDLib 自己的
   400 错误，不是空 buffer。也就是说：这不是"我读文件的姿势不对"，而是 **TDLib 认为那段
   区间没有可用字节**。
3. **chunk#2 同样为 0**。三个区间里只有一个成功，且唯一成功的那个是**从 0 开始的区间**。

这与仓库里已钉住的 schema 语义完全一致（`test/fixtures/td_api.tl`）：
`downloadFile` 一次只有一个活动区间，`downloaded_prefix_size` 是相对 `download_offset`
的前缀长度。**TDLib 的公开下载 API 没有"随机 RangeSet"这个能力**，把一个真实播放器的
随机读请求映射到它上面，只能靠一层自造的窗口调度——而那层调度的每一个失败模式都已经在
前两次设备报告里出现过（`PROXY_STALL`、`RANGE_TRUNCATED`、`HTTP_BODY_INCOMPLETE`、
`player_load_timeout`、593 MB 下载 162 秒才出首帧）。

因此本轮**正式接受 `E1 = FAIL`**，并把它写成架构级结论：

> 播放器需要的是任意区间可读；TDLib 提供的是单一连续前缀。
> 两者之间不存在可靠的映射，任何"边下边播"都是在为这个不存在的东西写补丁。

### 需要如实标注的部分

| 项 | 状态 | 说明 |
|---|---|---|
| 小文件（2.36 MB）分块读取 | **FAIL**（实测） | 决定性证据 |
| 23 MB / 152 MB / 593 MB 档位 | **NOT TESTED** | 回传样本实际是 2,362,816 B，不是 ≈23 MB。档位表从此无意义 |
| Q3「换 offset 后旧块物理数据是否还在」 | 部分观察（数据仍在，但当前可读窗口不等于整个文件） | 结论不依赖它 |
| Q4/Q5「是否重建 task / 是否有 cancel 事件」 | **NOT TESTED** | 结论不依赖它 |

档位表从这一刻起作废，不是因为不想测，是因为**测了也不改变结论**：chunk#1 都读不到，
更大文件只会更差。

---

## 3. 当前链路逐层审计

### 3.1 播放器入口 —— 点一条视频之后实际发生了什么

入口只有一个：`ChannelDetailPage._openRecord` / `_playChannel` / `_openMessageAt`
（`lib/ui/channel_pages.dart:556-599`）push 一个 `FeedPage`，另外底部"抖音"Tab 直接内嵌
同一个 `FeedPage`（`lib/app/app_root.dart:428-437`）。

`FeedPage.initState` → `_rebuildController()`（`lib/ui/feed_page.dart:126-185`）构造四件东西：

```text
IndexFeedSource(store, chatId)          → 只从本地索引翻页，不联网
SinglePlayerController(VideoPlayerFactory) → 一实例播放器槽
VideoSourceResolver(api: TdFileTransferApi(client)) → 解析"该放什么"
FeedController(...)                      → 状态机
```

然后 `FeedController.load()` → `_activateCurrent()` → `_activate()`（`lib/ui/feed_controller.dart:624`），
这是整条链的核心。它的实际顺序：

```text
_activate(record, generation)
 ├─ _diagnostics.allowWholeFile()                        打开"整文件"闸门
 ├─ new PlaybackSession(...)                             一次点击一个 session
 ├─ _fetchNameIfMissing(record)                          补文件名（1 次 getMessage）
 ├─ trace.mark(selected)
 ├─ _gate.run(_resolvePlaySource)                        ← 关键分支
 │    └─ if (StreamingV2.supported) sources.resolveStreamV2(...)   iOS 恒真
 │         → VideoSourceResolver._streamWithRepair → _streamOnce
 │            → decidePlaybackSource(facts, streamingEnabled: true, …)
 │            → 三条路：complete → LOCAL_FILE；否则 → RESOURCE_LOADER
 ├─ 失败 → _recoverFromStreamFailure(...)                重测文件 / 等整文件下载 / 重启一次
 │    └─ _waitForFullDownload(...)                       最多 30 分钟轮询
 ├─ while(true) _installPlayer(current)                  装不上就 _nextTransportAfter 下一档
 └─ phase = ready → _startPolling → _restoreProgress → _prefetchNext
```

要点：

* **默认走的是 ResourceLoader**。`StreamingV2.supported` 在 iOS 上恒为 `true`
  （`lib/playback/native_streaming.dart:29-33`），`_resolvePlaySource` 的第一行就是它
  （`lib/ui/feed_controller.dart:799`）。
* `AppRoot.initState` 里 `ResourceLoaderHost.instance.install()` 在**第一个播放器创建之前**
  就把字节通道装好了（`lib/app/app_root.dart:126-128`）。
* `player.activate(source.url)` 里 `url` 可能是路径、`http://127.0.0.1/...` 或 `tgmedia://...`；
  `VideoPlayerFactory.create` 按前缀分三种 handle（`lib/playback/video_player_handle.dart:38-56`）。
  **只有纯路径走 `VideoPlayerController.file`**，其余两种分别是网络播放与原生 AVPlayerLayer。
* 播放阶段仍在轮询 `player.active`（250 ms，`pollInterval`），并把播放器自身状态喂给
  `StreamingDiagnostics`（`VideoPlayerHandle.reportValue`）。

一句话：现在的"播放"不是一条链，是**三条链 + 一个降级阶梯**，而且默认落在最难的那条上。

### 3.2 下载入口

只有一个合法入口，这是上一轮 B+ 重构留下的、**应当保留**的成果：

```text
TelegramMediaDownloader.ensureFullDownload   (lib/playback/downloader.dart:326)
   └─ TdFileTransferApi.start                (lib/playback/video_source.dart:177)
        └─ downloadFile(offset: 0, limit: 0)
```

它已经具备的能力（这些不是设计意图，是代码里读得到的）：

| 能力 | 位置 | 现状 |
|---|---|---|
| 同一 file 幂等（不会发第二个请求） | `downloader.dart:334-335` | 有 |
| 已完整则短路，不发请求 | `downloader.dart:355-368`（`shortcut=already_on_disk`） | 有 |
| 磁盘余量检查（剩余 ×1.5） | `downloader.dart:370-396` | **有代码，真机不生效**（见 §3.3） |
| 停滞看门狗（15 s 静默 → stat 复核 → cancel+重启，最多 3 次） | `downloader.dart:232-302` | 有 |
| 失败裁决 `FullDownloadState.failed` | `downloader.dart:270-278` | 有 |
| 取消 | `downloader.dart:467-470` | 有（但无人调用） |
| 速度统计 | `lib/td/download_metrics.dart` | 有算法（3 s 尾窗），**未接线到 UI** |
| 一次只允许一个任务 | —— | **没有**。`_jobs` 是 per-file 映射，天然允许并行 |
| 下载状态广播给 UI | —— | **没有**。只有内部 job 对象，没有 `ChangeNotifier` / `Stream` |

静态门槛把它钉住了：全库 `downloadFile(` 只允许出现在 4 个文件
（`test/architecture_scan_test.dart:63-68`）：请求构造、传输层、消息探针、E1 探针。

### 3.3 缓存入口

四个互不重叠的存储区（`lib/storage/storage_layout.dart:19`）：

| 区 | 路径 | 里面是什么 | 谁可以删 |
|---|---|---|---|
| `tempCache` | `Library/Caches/tgmedia` | thumb / player / partial / **tdlib_files** | 只有"清除缓存" |
| `userDownloads` | `Documents/TGMediaDownloads` | 用户主动保存 | 用户（Files App） |
| `indexDb` | `Application Support/tgmedia/index` | 媒体索引（journal + snapshot） | 永不 |
| `authMeta` | `Application Support/tgmedia/secure` | TDLib DB + Keychain 引用 | 永不 |

**已下载的视频字节在哪：`Library/Caches/tgmedia/tdlib_files`**
（`storage_layout.dart:117`，由 `setTdlibParameters(filesDirectory: ...)` 指定，
`lib/app/app_session.dart:267-283`）。路径本身由 TDLib 决定，通过 `file.local.path` 读出来。

三个必须写进报告的实情：

1. **"清除缓存"现在清不掉视频。** `CacheManager.scan()` 只走
   `thumb` / `player` / `partial` 三个子目录（`lib/storage/cache_manager.dart:169-190`），
   `tdlib_files` 明确不在其中（注释见 `storage_layout.dart:110-116`）。
   也就是说：用户点"清除缓存"，已下载的 593 MB 视频一个字节都不会少。
2. **磁盘余量检查在真机上被短路。** `VideoSourceResolver` 的 `freeBytes` 默认是
   `_defaultFreeBytes` → 恒返回 `-1`（`lib/playback/video_source.dart:549`）；而
   `FeedPage` 构造 resolver 时**没有传** `freeBytes`（`lib/ui/feed_page.dart:153-164`）。
   全库 grep `freeBytes` 只有两处定义、零处生产接线。`ensureFullDownload` 拿到 `-1` 时
   按"未知"放行（`downloader.dart:394-396`）。→ §24 的存储空间保护目前**只是一段没接电的代码**。
   同时：iOS 侧没有任何取剩余空间的接口（`grep volumeAvailableCapacity|freeSpace|diskSpace` 为空），
   补它必须新增一个原生通道。
3. **池子在 `Library/Caches`，iOS 可以在存储压力下把它清掉**，而 TDLib 的数据库仍然记着
   `is_downloading_completed=true`。现有的兜底是 `SourceFacts.isPlayableFromDisk` 要求
   `pathExists`（`lib/playback/source_decision.dart:137-141`），能识别"记录说完成、文件没了"。
   但在当前链路上，这个 `false` 会被读成"那就流式播吧"，而不是"重新下载"。

`ActiveFileRegistry`（`lib/storage/active_files.dart`）是引用计数的占用登记，播放器
`activate` 时 `markInUse`、`_releaseHandle` 时 `release`（`lib/playback/player_slot.dart:142,205`），
清理器会跳过占用中的文件。这套**保留**。

### 3.4 频道列表

两级：

* `ChannelListPage`（`lib/ui/channel_pages.dart:25`）—— 头像（**目前是标题首字母的
  `CircleAvatar`**，不是真实照片，`:199-206`）、标题、`N 个视频`（未知时显示"统计中"）、
  本地搜索、下拉刷新、失败态与重试。
* `ChannelDetailPage`（`:225`）—— 分页 30 条、滚动到底自动加载、显式"从 Telegram 同步 2 页"、
  底部计数与"已到历史末尾"、右上角两个入口（编号跳转、播放本频道）。

数据源：`IndexStore`（本地镜像，`lib/data/index_store.dart`）+ `ChannelDirectory`（频道目录缓存）
+ `ChannelSyncEngine`（增量同步，`lib/data/channel_sync.dart`）。同步发生在
`AppRoot._runMaintenance()`（`lib/app/app_root.dart:207-230`）与频道页打开时；
`HistoryBackfill` 是一个**前台循环**（`:212-215`），每次 resume 重新 start，幂等。

编号相关的现状（这是本次最大的缺口，见 §8）：

* 列表行**完全不显示编号**，只有文件名 + `时长 · 大小 · 日期`（`channel_pages.dart:602-646`）。
* 播放页信息行显示的是 **Telegram 的 messageId**，格式 `#${record.messageId}`
  （`lib/ui/feed_page.dart:648`）；`FeedController.titleOf` 在缺文件名时同样拼
  `$channel · #${record.messageId}`（`lib/ui/feed_controller.dart:262-266`）。
* 真正的"视频序号"只在两处存在：`VideoNumberLookup.find`（全表扫描，`lib/data/video_number_lookup.dart:53-91`）
  与 `FeedController.openNumber / currentNumber`（`feed_controller.dart:478-509`）。
  两者口径一致（都过滤 `kind==video && fileId!=0`），但**是两套实现靠约定对齐**，没有断言守着。

排序：`IndexStore._ensureSorted` 按 `messageDate` 降序、`messageId` 降序
（`index_store.dart:423-432`）——**最新在最前**。这决定了"#001 是谁"。

### 3.5 导航

`AppShell`（`lib/app/app_root.dart:353-483`）是 `CupertinoTabBar` + `IndexedStack`，三个 Tab：

| index | label | 页面 |
|---|---|---|
| 0 | 频道 | `ChannelListPage` |
| 1 | **抖音** | `FeedPage`（首次点击才构建，`:395-403`） |
| 2 | 设置 | `SettingsPage` |

`_feedImmersive`（`ValueNotifier<bool>`）在播放时把整个 TabBar 藏起来（`:447-480`），
`FeedPage` 离场时清标志。`FeedImmersivePlan.tabBarHidden` 是这条逻辑的纯函数版本
（`feed_controller.dart:1721-1726`）。

删掉"抖音"的影响面：`AppShell` 的三个字段（`_feedBuilt`、`_feedImmersive`、`_exitFeed`）、
`FeedPage.isActive / playbackImmersive / onExitPlayback` 三个参数、以及 3 条依赖它们的测试。
`FeedPage` 作为**push 路由**的路径已经完整存在（`showBackButton: true`），所以删 Tab 不需要
重写播放页。

### 3.6 设置

`lib/ui/settings_page.dart` 的 7 个分区（`:96-110`）：

```text
账号        账号信息 / 退出登录
安全        App 密码 / 修改 / 关闭 / 密码提示 / Face ID / 自动锁定 / 启动时解锁
存储        缓存上限 / 自定义 / 恢复默认 / 清理缓存 / 未识别文件
外观        主题 / 相邻视频预加载数量(0-3)
播放诊断    StreamingDiagnosticsSection（流式判定、计数器、时间线）
下载实验(E1) ChunkProbePanel（扫描样本 / 三档位 / 复制报告）
关于        版本 / TDLib 版本 / 诊断信息 / 隐私说明
```

目标结构（任务书 §21）是 账号 / 安全 / 播放 / 缓存 / 关于。差异：
"外观"要并入"播放"；"播放诊断"与"下载实验"要么删除、要么收进隐藏开发页；
"实时诊断角标"是**新开关**（现有 `streamingDiagnostics` 语义不同，见 §6）。

---

## 4. 哪些代码属于旧 B+ Streaming

判定标准：**它存在的唯一理由是"播放器可以在文件没下载完时拿到字节"**。按这个标准逐文件过：

| 文件 | 行数 | 引用它的 lib 文件 | 性质 |
|---|---|---|---|
| `lib/playback/stream_proxy.dart` | 1,228 | 4 | V1 回环 HTTP Range 代理。**整文件作废** |
| `lib/playback/resource_loader.dart` | 620 | 8 | V2 `AVAssetResourceLoader` 的 Dart 侧字节供给。**整文件作废** |
| `lib/playback/growing_file_reader.dart` | 361 | 4 | 安全水位（min(TDLib reach, stat)）+ WAIT 机制。**整文件作废** |
| `lib/playback/native_streaming.dart` | 386 | 8 | V2 的 MethodChannel 桥 + `NativePlayerView`。**整文件作废** |
| `lib/playback/stream_window.dart` | 69 | 2 | 下载窗口（1 MB 步进）常量。**整文件作废** |
| `lib/playback/source_decision.dart` | 397 | 5 | 传输决策表（localFile / resourceLoader / httpProxy / fullDownload / stop）。**大部分作废**，只留 "完整→本地" 与 "损坏→重下" 两条判定 |
| `lib/playback/streaming_diagnostics.dart` | 2,214 | 18 | 流式判定 + 计数器 + 验收对账 + 下载审计。**判定部分作废**，`DownloadAudit` 可留（490 行，`download_audit.dart` 独立） |
| `lib/ui/streaming_overlay.dart` | 194 | — | 流式角标（FULL/STREAM/HTTP/SRC/PLAY）+ 设置页诊断块。**整文件作废** |
| `ios/Runner/Streaming/TGMediaResourceLoader.swift` | 302 | — | `AVAssetResourceLoaderDelegate`。**整文件作废** |
| `ios/Runner/Streaming/TGMediaPlayer.swift` | 322 | — | 原生 AVPlayerLayer + 播放控制。**随 V2 作废** |
| `ios/Runner/Streaming/TGMediaStreamingPlugin.swift` | 359 | — | 三条通道的注册与事件泵。**随 V2 作废** |

`video_source.dart`（2,552 行）是混合体：`FileTransferApi` + `TdFileTransferApi`（保留）、
`PlaySource`（要瘦成只有 file）、`VideoSourceResolver` 的流式部分（`_streamOnce`、
`startResourceLoader`、`_waitForPath`、`_probeMoov`、`_waitForStartup`、`_LiveFileWatch`
的窗口逻辑、`_LiveProgressBridge`）全部作废；`_resolveWithRepair` / `_statStrict` /
`_factsFor` / `inspect` 保留。

---

## 5. 可以保留（不动或只做小改）

| 模块 | 为什么留 |
|---|---|
| `lib/td/tdjson_ffi.dart` / `td_client.dart` / `td_requests.dart` / `td_models.dart` | TDLib 总线，与播放方式无关。`downloadFile` / `getFile` / `deleteFile` 都在 |
| `lib/app/app_session.dart` | 单 `TdClient`、Keychain、`authorizationStateReady`、启动恢复 —— 全部符合 §20，**一个字都不要改** |
| `lib/security/*` | 只读白名单、生物识别、密码、锁策略。Face ID 默认 `false` 已符合 §20 |
| `lib/data/index_store.dart` | 本地镜像（journal + snapshot）。要加的是"取排名"能力，不是替换 |
| `lib/data/channel_sync.dart` / `channel_directory.dart` / `history_source.dart` | 真实的 TDLib 频道同步，符合 §9 |
| `lib/storage/storage_layout.dart` / `file_ops.dart` / `active_files.dart` | 分区与越界保护是这套代码里最扎实的部分 |
| `lib/playback/player_slot.dart` | 单实例播放器 + `liveCount`（100 次切换的泄漏断言就靠它）+ 25 s load 超时 |
| `lib/playback/video_player_handle.dart` | `VideoPlayerController.file` 已经就是 LOCAL_FILE 播放器；只需删掉 `http`/`tgmedia://` 两个分支 |
| `lib/playback/downloader.dart` | 整文件下载的判据、短路、看门狗都对。要被 `DownloadManager` **包一层**，不是重写 |
| `lib/playback/download_audit.dart` | 调用审计（谁在什么时候要了哪个文件）在 LOCAL_FILE 下仍然有用 |
| `lib/util/*`、`lib/ui/status_view.dart`、`app_theme.dart` | 工具与失败态渲染 |
| `lib/lock/*`、`lib/platform/*` | 锁与方向 |

---

## 6. 需要修改（含冲突点，逐条给证据）

| # | 位置 | 现状 | 目标 | 冲突性质 |
|---|---|---|---|---|
| M1 | `feed_controller.dart:780-863` `_resolvePlaySource` | V2 优先，`StreamingV2.supported` 恒真 | 只认 `LOCAL_FILE_READY` | 结构性 |
| M2 | `feed_controller.dart:950-1171` `_recoverFromStreamFailure` / `_waitForFullDownload` / `_nextTransportAfter` | 三层降级阶梯，含 30 分钟等待 | 不存在这条路径：失败就是失败，给"重试下载" | 结构性 |
| M3 | `feed_controller.dart:1211-1254` `_prefetchNext` | 预取"相邻项的下载/完整性" | 与"一次只允许一个下载任务"直接矛盾 | 需要决定 |
| M4 | `app_root.dart:126-128` | 启动即装 `ResourceLoaderHost` | 不装 | 删除 |
| M5 | `app_root.dart:353-483` `AppShell` | 3 Tab，含"抖音" | 2 Tab：频道 / 设置 | 删除 |
| M6 | `feed_page.dart:648` | 信息行显示 `#${messageId}` | `#${编号}`，且不得出现 messageId | 违规显示 |
| M7 | `feed_controller.dart:262-266` `titleOf` | 缺文件名时拼 `#${messageId}` | 不得把 messageId 当编号 | 违规显示 |
| M8 | `channel_pages.dart:602-646` `_MediaRow` | 无编号 | 每行显示 `#001` 并支持点击 | 缺失功能 |
| M9 | `feed_controller.dart:478-509` `openNumber` | 在**已加载窗口**里按 `index+1` 定位 | 按**频道全局排名**定位，且能翻页到任意编号 | 语义不同 |
| M10 | `video_number_lookup.dart:53-91` | 全表扫描 O(n)，每页 40 条 | 排名查询（O(log n) 或一次性缓存） | 性能 |
| M11 | `source_decision.dart:137-141` `isPlayableFromDisk` | 长度 + counter 覆盖即放行，**不读 `is_downloading_completed`** | §15 要求 TDLib completed + 可读 + 大小合理 | 判据缺一项 |
| M12 | `cache_manager.dart:169-190` `scan()` | 不扫 `tdlib_files` | "清除缓存"必须能清掉已下载视频 | 功能缺失 |
| M13 | `video_source.dart:549` + `feed_page.dart:153-164` | `freeBytes` 恒 `-1`，无原生接口 | §24 下载前必须检查剩余空间 | 未接线 |
| M14 | `settings_page.dart:96-110` | 7 分区，"外观"独立，"播放诊断"+"下载实验" | 账号/安全/播放/缓存/关于 + 实时诊断角标开关 | 重组 |
| M15 | `streaming_overlay.dart:19-44` | 流式角标（FULL/STREAM/HTTP…） | `#023 / 5.2 MB/s / 50/500 MB / 状态` | 重写 |
| M16 | `app_preferences.dart:120` | `streamingDiagnostics` 同时控制角标与设置面板 | 新开关 `diagnosticsBadge`，默认 OFF，与内部日志解耦 | 语义拆分 |
| M17 | `app_preferences.dart:131` | `streamingPlayback` 默认 `true` | 字段废除（没有边下边播可开关） | 删除 |
| M18 | `index_store.dart:423-432` | 排序最新在前 → 新视频插入头部，**全表编号整体 +1** | 编号必须稳定 | 见 §10 D1 |
| M19 | `architecture_scan_test.dart:54-345` | 11 条门槛守着"不要引入第二条流式链" | 反过来守"不得再出现流式" | 重写 |
| M20 | `feed_page.dart:151-160` `VideoSourceResolver(...)` | 无 `freeBytes`、无 `diagnostics` | 由 `DownloadManager` 取代 | 结构性 |

---

## 7. 最终删除（前置条件：LOCAL_FILE 真机验收通过）

顺序很重要，先删依赖方，再删被依赖方，每一步都要 analyze + test 绿。

1. `ios/Runner/Streaming/`（3 个 Swift，983 行）+ `AppDelegate` 里对应的注册。
2. `lib/ui/streaming_overlay.dart`（已被 M15 的新角标取代）。
3. `lib/playback/native_streaming.dart`（`NativePlayerView` 与 `MethodChannelStreamingTransport`）。
4. `lib/playback/resource_loader.dart`。
5. `lib/playback/stream_proxy.dart`。
6. `lib/playback/growing_file_reader.dart`、`lib/playback/stream_window.dart`。
7. `lib/playback/streaming_diagnostics.dart` 的流式判定与计数器部分（2,214 行里约 1,800 行）。
8. `lib/playback/source_decision.dart` 的 `resourceLoader` / `httpProxy` / `fullDownload` 分支。
9. `lib/playback/video_player_handle.dart` 的 `networkUrl` 与 `tgmedia://` 分支。
10. `video_source.dart` 的流式半区（约 1,400 行）。
11. 测试：`resource_loader_test`、`stream_window_test`、`streaming_playback_test`、
    `video_source_v2_test`、`streaming_overlay_test`、`source_decision_test`、
    `streaming_diagnostics_test` 全部重写或删除。

**删除前提必须被真机证明的东西**（否则不许删）：
23 MB / 152 MB / 593 MB 各下载一次 → 播放完整 → 退出重进直接播 → 断网仍能播 → 清缓存后重下。

---

## 8. 与目标架构的逐条差距

任务书 §30 的验收清单，对照代码的实测状态（`有` / `缺` / `冲突`）：

| 验收项 | 现状 | 证据 |
|---|---|---|
| E1 FAIL 已接受 | 本轮文档收口 | §2 |
| 不再用 ResourceLoader | **冲突**：默认就在用 | `feed_controller.dart:799` |
| 不再用 HTTP Proxy 播放 | 冲突：代码仍在（无调用点但可被 `resolveStream` 唤起） | `video_source.dart:851-869` |
| 不再用 GrowingFileReader | 冲突：V2 供给链仍在用 | `resource_loader.dart` |
| 只播完整本地文件 | **冲突**：默认不完整也开播 | `decidePlaybackSource:290-303` |
| 下载完成状态准确 | 部分：靠长度+counter，未读 `is_downloading_completed` | M11 |
| 不出现假完成 | 有：`already_on_disk` 短路 + 实测长度 | `downloader.dart:355` |
| 下载速度真实 | **缺**：算法有（3 s 尾窗），UI 无接线 | `download_metrics.dart` |
| 速度角标可关闭 / 默认 OFF | **缺**：现角标是流式诊断，语义不同 | M15/M16 |
| 右上角 `#编号` | **冲突**：显示的是 messageId | M6 |
| 频道每个视频都有编号 | **缺**：列表无编号 | M8 |
| 编号与实际视频一致 | 部分：两套实现靠约定对齐 | M9/M10 |
| 可跳转编号 | 有（`openNumber` + 频道页跳转） | `feed_controller.dart:478` |
| 上下切换编号正确 | 有（`currentNumber` = index+1） | 同上 |
| 删"抖音"导航 | **缺**：还在 | M5 |
| 底部只有频道/设置 | 缺 | M5 |
| 缓存命中直接播 | 有（LOCAL_FILE 分支已被实现过） | `decidePlaybackSource:270` |
| 断网可播已缓存 | 部分：路径存在即可，但 Caches 会被系统回收 | §3.3 |
| 大视频不进 RAM | 有：`VideoPlayerController.file` 由 AVPlayer 自己读 | `video_player_handle.dart:75` |
| 100 次切换无泄漏 | **工具已有**（`switch_stress_test` + `liveCount`），未在真机跑 | `player_slot.dart:128` |
| 登录/密码/Face ID 不被破坏 | 有 | `app_session.dart`、`lock_policy.dart` |
| 缓存清理只删本地 | 有（分区 + 越界检查），但清不到视频 | M12 |
| analyze / test 通过 | 有（绿） | §1 |

---

## 9. 目标链路与现状链路的对照

```text
目标（LOCAL_FILE）                          现状（B+ / V2）
─────────────────────────────────          ─────────────────────────────────
点击 #023                                   点击一条
  ↓                                           ↓
查本地缓存（完整？）                          _resolvePlaySource
  ├─ 是 → 直接播                                └─ StreamingV2.supported == true
  └─ 否 → DownloadManager 建任务                     ↓
             ↓                                  resolveStreamV2 → _streamOnce
        downloadFile(0, 0)                        ↓
             ↓                                  ResourceLoaderHost（字节通道已装好）
        等 is_downloading_completed + 本地校验      ↓
             ↓                                  AVPlayer 开 tgmedia:// → 随机 Range
        LOCAL_FILE_READY                          ↓
             ↓                                  先凑够 2 MB 再开播
        AVPlayer(file://)                         ↓
             ↓                                  播放途中等 TDLib 吐字节（WAIT）
        播放（不再碰网络）                          ↓
                                              失败 → 重测文件 → 等整文件（≤30 min）
                                                  → 或重启一次下载 → 或报错
```

右边那条链的每一段都已经被设备报告命中过至少一次。左边那条链目前**只有骨架**
（`PlaySource.file` + `isPlayableFromDisk` + `downloader`），缺的是"任务化 + 状态 + 速度 + 缓存"。

---

## 10. 必须由你拍板的问题

这些问题会影响 STEP 2/3/4 的接口形状，现在定，后面不用返工。

**D1 — 编号的方向。** 现在是"最新 = #001"（`index_store.dart:423` 降序）。
这样新视频一进来，**所有编号整体 +1**，"稳定编号"就不成立。
如果改成"最旧 = #001"（历史正序），编号永不位移，新视频永远追加在末尾，
但 #001 是最老的视频，向下滑是"更新"。
任务书 §11 写的 `#023 ↓ #024` 暗示向下递增——两种方向都能满足它，但只有正序能让编号稳定。

**D2 — 缓存池的位置。** TDLib 文件池现在在 `Library/Caches`（`storage_layout.dart:117`），
iOS 可以在存储压力下直接清掉它，"断网也能播"会因此失效。
移到 `Application Support` 可以保证不被系统回收，代价是磁盘由用户自己管理（清理缓存会真的删掉）。
移目录会导致升级后已有缓存的视频需要重下一次。

**D3 — 预加载怎么办。** 现在有"相邻视频预加载 0-3 条"（`app_preferences.dart:110`），
B+ 之后它只做完整性检查、不下载。在 LOCAL_FILE 模型下，"预取"等于"提前下载下一集"，
和"一次只允许一个下载任务"直接冲突。三选一：完全关闭（默认 0，设置项删除）／
保留但只查本地（不下载）／允许一个低优先级的后续下载。

**D4 — 频道头像。** 现在是标题首字母的圆形色块（`channel_pages.dart:199-206`）。
真实头像需要额外下载 `chat.photo.small`（一次 image 文件下载，与视频下载无关）。
要做真头像就得给下载层加一个"非视频小文件"通道；不做就保持字母块。

**D5 — 播放页的入口。** 删掉"抖音"Tab 之后，播放页只能从"频道 → 视频列表 → 点一条"进入。
是否允许"频道页直接点封面就进播放"（跳过列表）？现在列表是唯一入口。

**D6 — 旧链路的删除时机。** 我按任务书 §16 理解为：LOCAL_FILE 链路**真机验收通过后**再删。
如果你希望更早（比如 STEP 3 就把 Swift 流式代码删掉，只保留 Dart 侧不被调用），
请明确，因为这决定 STEP 3 的验收标准里要不要包含"删完还能构建"。

---

## 11. STEP 2 的边界（下一阶段做什么，现在不写代码）

只做下载与缓存状态，不碰播放器：

```text
lib/download/
  download_state.dart     一个任务的状态机：idle → running → completed / failed / cancelled / diskFull
  download_speed.dart     滑动窗口速率（500–1500 ms）+ 平滑 + 归零规则，纯函数，可单测
  download_task.dart      一个 fileId 的任务：进度、速度、完成判据、取消、错误
  download_manager.dart   唯一任务队列（同时只有一个 running）、ChangeNotifier、缓存命中快查
  cache_manager.dart      池子的用量统计与清理（必须覆盖 tdlib_files）
  cache_validator.dart    "这个路径能不能直接给播放器"——长度 + completed + 可读
```

不变量（STEP 2 的自动化测试要钉住它们）：

1. 任意时刻 `running` 的任务数 ≤ 1。
2. `completed` 必须同时满足：TDLib `is_downloading_completed` **且** 文件存在
   **且** `File.length() == expected_size` **且** 可读一次首字节。
3. `downloadFile` 的调用只出现在 `download_manager`（静态扫描门槛，沿用现有做法）。
4. 速度只由真实 `updateFile` 增量算出；没有增量时不许显示非零值。
5. 取消后状态是 `cancelled`，永远不可能是 `completed`。
6. 磁盘不足时**不发** `downloadFile`，状态直接 `diskFull`。

STEP 2 不引入：播放器改动、UI 角标、编号、导航。

---

## 12. 结语（这一阶段的事实，不是计划）

* 播放链路目前**默认**落在 V2 ResourceLoader 上，这与本轮的目标相反。
* 需要保留的东西比需要删除的东西少得多，但保留的那部分（TDLib 总线、会话、索引、存储分区、
  单播放器槽、整文件下载器）**已经是对的**。
* 缺口集中在四处：编号（列表没有、播放页显示了错误的 id）、下载任务化（有余量检查但没接线、
  没有速度、没有单任务约束）、缓存（清不到视频、池子会被系统回收）、UI（3 Tab、7 个设置分区、
  一个语义不对的角标）。
* E1 = FAIL 已写入架构结论，不再有"再试一次边下边播"的选项。

**本章结束。STEP 1 到此停止，等你确认 D1–D6 与是否进入 STEP 2。**
