# 设备报告 5626：播放是好的，报告在撒谎

一份 155 MB / 64 秒视频（`file=5626`，`chat=-1002273572608`，`msg=9435086848`）的诊断导出。

结论先说：**这次播放没有故障。** `player=43s/64s status=playing started=true`，155 MB
全在磁盘上（`disk=162308586 FULL`，`tdlib total` 两者相等），ResourceLoader 把
133,169,154 字节交给了 AVPlayer。报告里那三行红色结论是**统计链路断了**，不是播放链路。

## 报告里的四处自相矛盾

| 行 | 报告说什么 | 事实 |
| --- | --- | --- |
| `v2 sessions=1 req=0 resp=0 bytes=0` | 一个请求都没发生 | 同一份日志的 `events=` 里是 `respondCount=275 respondBytes=524288`，`sessionClosed … requests=275 responds=275 bytes=133169154` |
| `V2_BYTES dataRequests=0 responds=0 toPlayer=0` | 一个字节都没给播放器 | 275 × 512 KB |
| `isDownloading=false completed=false`，同时 `disk=… FULL`、`downloaded=100.0%` | 文件没下完 | 162,308,586 / 162,308,586 |
| `verdict=STREAMING_NOT_STARTED` + `STREAMING_TEST_FAILED` | 流式没启动 | 播放器在 43 秒处播放中 |

## 根因一：V2 计数器有两个入口，生产路径只用了没人写的那个

`StreamingDiagnostics` 里有两套写入方式：

- `noteResourceLoaderRequest()` / `noteResourceLoaderRespond()` —— 自增
  `_rlRequests/_rlResponds/_rlBytes`。**全仓库零调用点。**
- `noteResourceLoaderEvent('dataRequestCreated' / 'respond', …)` —— 真正在跑的：
  Swift 每个 `AVAssetResourceLoadingRequest` 发一次，Dart `ResourceLoaderSession.serve()`
  每喂一块发一次。它只写事件日志，不碰计数器。

于是 `verdict` 里的

```dart
final servedV2 = _rlRequests > 0 && _rlBytes > 0;
```

恒为 false，`attempted` 也恒为 false → 强制测试分支直接返回
`streamingNotStarted`。面板上那三行 `req=0 resp=0 bytes=0` 是同一个原因。

**修法**：删掉那两个没人调的方法，计数器改为由 `noteResourceLoaderEvent` 统一驱动
（`_countV2Event`）。同一份读取会被两个生产者各报一次（Swift 一次、Dart 每块一次），
所以按 `(requestId, offset)` 去重，只计一次。`_v2StartedMillis` 在第一条
`dataRequestCreated` 上打点，作为 V2 的"传输真的起来了"证据 —— V2 没有端口可 bind，
`proxyStartedMillis` 在 V2 上永远是 `-`。

## 根因二：完整文件被重新要了一次下载

`DOWNLOAD AUDIT #1 caller=DOWNLOADER offset=0 limit=WHOLE_FILE grew=0
cause="b+ auto full download"` —— 文件早已 100% 在盘上，`ensureFullDownload()` 仍然发了
`downloadFile`。TDLib 收下这次请求会重新打开该文件的传输，并在复核期间报
`is_downloading_completed=false`；而 `_isDownloadingCompleted` 只有 `noteCompleted()`
（要求一次带 stat 的完成事件）才会置真，这次事件没再来过 —— `completed=false` 就是这么来的。

**修法**：`ensureFullDownload()` 在测完磁盘后先判断
`expectedSize > 0 && diskSize >= expectedSize`，成立则直接把 job 标成 `completed`、
`shortcut='already_on_disk'`，一次 TDLib 调用都不发。完整文件的播放因此是
`DOWNLOAD AUDIT: no calls`，而不是一条 `WHOLE_FILE`。

## 根因三：`completed` 只有一个来源，而它可能永远不来

面板的 `completed` 只看 TDLib 的 claim。文件在播放开始前就是完整的，
`updateFile` 不会再为它发一条完成事件，于是"磁盘满、进度 100%、completed=false"
三条同时成立。

**修法**：`completed` 改成三态，并带上证据来源：

```
isDownloading=false completed=true evidence=DISK
```

`TDLIB` = 完成事件 + stat 双证；`DISK` = 实测长度达到 expected；`NONE` = 都没有。
`completedAt` 同样补一态：播放开始前就已完整时输出 `before_play`，而不是 `-`。

## 根因四：`WHOLE_FILE_DOWNLOADS=1` 在 B+ 下是本来的设计

B+ 的播放**就是**一次整文件下载，属于 Downloader。报告把它和"播放窗口偷偷要整片"
印成同一个数字，于是一次完全正常的播放读起来像违规。

**修法**：拆成 `WHOLE_FILE_DOWNLOADS=1 byDownloader=1 byOther=0`；
`byOther > 0` 时额外打一行 `WHOLE_FILE_BY_OTHER: PLAYER file=…`，那才是需要看的东西。

## 验收标记：这次运行不能算"失败"，只能算"无效"

`fileComplete=true` + `downloadedAtFirstPlayback=155 MB` 说明：文件在点开之前就下完了。
ResourceLoader 确实服务了它，播放器确实播了，但这两个事实都证明不了"边下边播"。

所以强制测试的结论从

```
STREAMING_NOT_STARTED
STREAMING_TEST_FAILED: STREAMING_NOT_STARTED
```

改成

```
FULL_DOWNLOAD_BEFORE_PLAYBACK
STREAMING_TEST_INVALID: file_complete_before_play
```

`INVALID` 与 `FAILED` 是两句话：前者是"这次没什么可测的"，后者是"管道坏了"。
要拿到有效的强制测试，得挑一个**不在缓存池里**的视频（或先清池）。

## 改了什么

| 文件 | 改动 |
| --- | --- |
| `lib/playback/streaming_diagnostics.dart` | V2 计数改由 `noteResourceLoaderEvent` 驱动（`_countV2Event`，按 `(requestId, offset)` 去重）；删 `noteResourceLoaderRequest/Respond`；`_v2StartedMillis`；`transferCompleted`/`completionEvidence`；`completedAt=before_play`；`WHOLE_FILE_*` 按 caller 拆分；`STREAMING_TEST_INVALID` |
| `lib/playback/downloader.dart` | 文件已完整时跳过 `downloadFile`（`shortcut='already_on_disk'`） |
| `lib/playback/download_audit.dart` | `unboundedCallsByDownloader` / `unboundedCallsByOther` |
| `test/downloader_test.dart` | 新增 5 条：完整文件零调用、短文件仍发、未知大小不发呆、磁盘不足不发、start 抛错不留 running |
| `test/streaming_diagnostics_test.dart` | 新增 5 条：事件驱动计数、双生产者去重、完整文件不再 NOT_STARTED、Downloader 整文件是设计、PLAYER 整文件被点名 |
| `test/architecture_scan_test.dart` | 新增 3 条硬门槛：`_rlRequests++` 只能有一处；verdict 必须认 `_v2StartedMillis`/`_rlResponds`；`completed` 必须带证据来源 |

`flutter analyze` 0 issue；`flutter test` 954 passed / 1 skipped。

## 仍未验证

- 真机装新 IPA 后，同一份日志应读成 `req=275 resp=275 bytes=133169154`、
  `verdict=FULL_DOWNLOAD_BEFORE_PLAYBACK`、`STREAMING_TEST_INVALID: file_complete_before_play`。
  **未实测。**
- 有效（非完整文件）的强制测试：完整文件 → 起播的时序，仍未在真机上取到。
- 23 MB / 152 MB / 593 MB / 1 GB、弱网、后台、Seek、`DISK_FULL`、10 s `WAIT_TIMEOUT`
  是否偏短：STEP 6 矩阵全部未测。
