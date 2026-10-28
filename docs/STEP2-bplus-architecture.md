# STEP 2 报告：B+ 架构落地（Downloader 成为唯一下载入口）

日期：2026-10-28
分支：`rebuild-step3`
提交：`8cbd00e`（主体）、`89cd286`（finalSource 收敛）

---

## 一、新文件

### 1. `lib/playback/downloader.dart`

TDLib `downloadFile` 的唯一入口。

- `TelegramMediaDownloader`：`ensureFullDownload` / `restart` / `cancel` / `isRunning` / `observeTransfer`。
- `FullDownloadJob` + `FullDownloadState`（`idle / running / completed / diskFull / failed`）。
- `DiskFullException extends VideoSourceException`。
- 磁盘规则：`requiredFreeSpace >= (expectedSize - diskSize) × 1.5`（`safetyFactor = 1.5`，写死在该层，不接受外部 10%/20% margin）。
- 幂等：同一 `fileId` 已有 running job 时直接返回，不重复下发。

### 2. `lib/playback/growing_file_reader.dart`

- `safeWatermark = min(TDLib reach, filesystem stat)`；**stat 失败（`disk < 0`）时返回 0**，绝不回退到 TDLib 数字。
- `read(offset) → {available, readableTo, watermark, completed}`。
- `waitFor(offset, {timeout, generation}) → WaitOutcome{arrived, completed, timeout, invalidated}`。
- `isComplete` 要求 `expectedSize > 0 && diskSize >= expectedSize`。
- `onComplete(listener)`、`invalidate()`（同步，非 Future）。
- `TdProgressSource` 抽象：`tdlibReach / tdlibCompleted / tdlibCanDownload / changes`，纯观察，无下载权限。

---

## 二、被删除 / 切断的调用

| 位置 | 旧行为 | 现状 |
|---|---|---|
| `video_source._streamOnce` | `startRange(offset:0, limit:firstWindow, caller:PLAYER)` 首窗 | 已删除 |
| `video_source._streamOnce` | `needsRedownload` 分支里再发 `startRange` | 改为 `downloader.restart` |
| `resource_loader` | `WindowContinuation → _LiveFileWatch → startRange` | 整条删除，文件不再引用 `FileTransferApi` |
| `feed_controller._fullDownloadFallback` | 流式失败 → 整文件下载 | 删除；改为「等这次播放本来就在跑的下载」+ 一次 restart 预算 |
| `VideoSourceResolver.prefetch` | `api.prefetch`（TDLib 窗口） | 改为 `stat` + 磁盘测量，纯本地 |

`_streamOnce` 里现在只有一处下载相关调用：`downloader.ensureFullDownload(...)`。

---

## 三、AUTO 链（唯一路径）

```
stat(fileId)
  → 磁盘测量（diskSize vs expectedSize）
  → downloader.ensureFullDownload(offset=0, limit=0)
  → _LiveFileWatch（观察，seed 一次 stat）
  → GrowingFileReader（safeWatermark）
  → ResourceLoaderSession（纯本地回读）
  → AVPlayer
```

---

## 四、Player / Preload 是否还能触达 TDLib

不能，且有静态门槛：

- `_streamOnce` 函数体内禁止出现 `startRange(` / `_api.start(` / `downloadFile(`，只允许 `ensureFullDownload`。
- `GrowingFileReader`、`ResourceLoaderSession` 禁止出现 `downloadFile` / `startRange` / `FileTransferApi` / `Downloader` / `WindowContinuation`。
- `player_slot` / `playback_session` / `stream_proxy` 禁止 `downloadFile(` 与 `DownloadCaller.player`。
- `downloadFile(` 只允许出现在三处：`td_requests.dart`（请求构造）、`video_source.dart`（`TdFileTransferApi` 传输层实现）、`media_probe.dart`（消息探测）。

---

## 五、WAIT / EOF

- `requestedRange > safeWatermark && 未完成` → WAIT（`errorCode == null`，`downloading == true`）。
- 仅当 `safeWatermark >= expectedSize` 且磁盘实测达到，才 `completed = true` → EOF。
- `contentLength` 恒等于 `expectedSize`，不是磁盘大小。

## 六、WAIT_TIMEOUT

- 默认 10 秒（`VideoSourceResolver.waitTimeout = 10s`，`GrowingFileReader.waitTimeout = 10s`）。
- 超时返回 `errorCode = 'WAIT_TIMEOUT'`、`completed = false`、`downloading = false`；不 `finishLoading`、不 `downloadFile`。
- 下载仍在跑时继续等，不升级成失败；水位或完成状态变化会重置等待时钟。

## 七、DownloadAudit

- `DownloadCaller` 新增 `downloader`（label `DOWNLOADER`）与 `growingFileReader`。
- `forbiddenDownloaders = {player, resourceLoader, growingFileReader, preload}`，命中即写 `ARCHITECTURE_VIOLATION`（`FORBIDDEN_DOWNLOADER ...`）。
- `proxy` 单独处置：V1 代理是历史兼容代码，由 transport 链管控而非 audit 集合。
- `DownloadCall` 携带 `diskBefore`（startedFrom）/ `diskAfter`（grew）语义；`tag({chatId, messageId, generation})`。

## 八、finalSource

收敛为三值：`RESOURCE_LOADER` / `LOCAL_FILE` / `FAILED`。
「用户主动关闭流式」那条路径原写 `FULL_DOWNLOAD`，已改为 `LOCAL_FILE`（原因由 decision 行表达，不再新增第四个来源名）。

## 九、fileId remap

`4999 → 2221` 的重解析路径保留：`_streamWithRepair` 捕获 `_MissingFile` → 重读 message → `noteFileIdRemap(old, new)` → 用新 id 重试。
补了一处遗漏：`ensureFullDownload` 抛出的 TDLib「File not found」此前不会转成 `_MissingFile`，导致修复链失效；现已转换。

---

## 十、本次修掉的真实缺陷（非测试让步）

1. `downloader.observeTransfer` 从未被调用 → job 永远 `running`，恢复路径死等。改由 `_LiveFileWatch.onState` 回写。
2. `ensureFullDownload` 中 `start` 抛错后 job 仍 `running` → 「下载还在跑」误判。抛错时置 `failed` 并 rethrow。
3. `_LiveFileWatch` 订阅晚于第一条 `updateFile` → 广播流丢事件 → 播放卡在 0 字节直到 stall。新增 `seed()`：订阅后主动 stat 一次。
4. `safeWatermark` 在 stat 失败时回退到 TDLib 数字，与「缺失文件读 0」冲突。改为返回 0。
5. `ResourceLoaderSession.open()` 未测磁盘就报 `completed` → 完整文件被当成增长中。open 前 `reader.refresh()`。
6. `FeedController` 的下载等待上限（30 分钟）此前写死在循环里 → 改为构造参数 `fullDownloadWait`（默认 30 分钟，测试注入 400ms）。

---

## 十一、测试

```
flutter analyze      → No issues found
flutter test         → 935 passed, 1 skipped, 0 failed
```

新增 `test/architecture_scan_test.dart`（6 条静态断言），作为 CI 硬门槛。

语义迁移（B+）后的关键断言：

| 断言 | 内容 |
|---|---|
| 整文件唯一入口 | `wholeFileCallers == everyElement(DOWNLOADER)` |
| 零窗口 | `rangeCalls == 0`（播放路径不发任何范围请求） |
| 预取不下发 | `preload` caller 永不出现；prefetch 只增加 `statCalls` |
| 等待不花预算 | 流式失败但下载仍在跑 → `fullDownloadFallbackUsed == false` |
| restart 一次 | 下载已死 → 首播 1 次 + restart 1 次，之后停止 |
| 超时不循环 | `autoComplete=false` 且等待超时 → `startCalls == 1` |

---

## 十二、未验证项

- 真机 moov 布局（faststart vs tail-moov）、`moovPosition` / `startupBytes` / `playerReadyTime`：**未实测**，代码里只保留记录点，不作为已验证结论。
- 152MB / 593MB / 1GB 真机矩阵：**未执行**（属 STEP 6）。
- 后台 / 弱网 / Seek / remap 真机行为：**未执行**。

---

# STEP 3-5：V1 从 AUTO 链中删除

## STEP 3：WAIT / EOF / watermark / generation 的回归覆盖

`test/resource_loader_test.dart`（26 条）锁定的规则：

| 用例 | 锁住的语义 |
|---|---|
| `is the min of TDLib reach and the disk` | `safeWatermark = min(reach, disk)` |
| `a missing file reads as zero` | stat 失败 → 0，不回退 TDLib 数字 |
| `an offset past the watermark waits — never EOF` | 越界未完成 = WAIT，`errorCode == null` |
| `a complete file answers any offset and says EOF only there` | EOF 只在磁盘到 `expectedSize` |
| `WAIT_TIMEOUT after the configured wait, not an EOF` | 10 s 无增长 → `WAIT_TIMEOUT`，`completed=false` |
| `growth resets the wait clock` | 水位一动，等待时钟清零 |
| `carries expectedSize as contentLength` | contentLength 是文件总长，不是磁盘字节 |
| `a superseded generation refuses the request` | `STALE_GENERATION` |
| `a closed session refuses every byte` | `SESSION_CLOSED` |
| `an invalidated reader refuses further reads` | `invalidate()` 之后零读取 |

## STEP 4：控制器里没有第二条流式通路

删除的东西（不是注释掉、不是加开关）：

1. `FeedController._tryV1` —— 整个方法删除。AUTO 里再没有任何 `sources.resolveStream(...)` 调用点。
2. `_nextTransportAfter` 的 `PlaybackSourceKind.httpProxy` 分支 —— 删除。`decideAfterTransportFailure(... allowProxy: false)` 成为唯一写法。
3. `_recoverFromStreamFailure` 第 2 步（V2 失败 → 试 V1）—— 删除，恢复链只剩：本地完整 → 等这次播放自己的下载 → 花唯一一次 restart → 停止。
4. `_resolvePlaySource` 底部的平台兜底（无桥 → 走 proxy）—— 改为显式失败 `此设备不支持流式播放（缺少原生播放桥）`，并记 `decision: STOP / no_streaming_transport`。
5. `StreamingV2.v2Only` 常量 —— 删除。原来它只是「挡住」V1，现在 V1 已无调用点，开关留着反而给人一个改回头的错觉。

`test/feed_controller_test.dart` 的 Rig 因此改跑设备上的真实链路：`StreamingV2.enabledOverride = true` + `FakeStreamingTransport`（只有 `openSession` 有实质内容，字节请求本来就在原生侧）。44 条控制器用例现在验证的是 V2 链路，而不是一台没有原生桥的机器。

## STEP 5：静态门槛与审计

`test/architecture_scan_test.dart` 从 6 条扩到 8 条，新增：

| 断言 | 内容 |
|---|---|
| `the controller has no second streaming transport` | 控制器源码里不得出现 `_tryV1` / `allowProxy: true` / `sources.resolveStream(` / `noteTransportStart('HTTP_PROXY')`；必须出现 `allowProxy: false` |
| `the transport entry is recorded after beginPlay` | `noteTransportStart` 必须在 `beginPlay` 之后 —— 否则被 `beginPlay` 的重置抹掉（本次修到的真实缺陷） |

`test/download_audit_test.dart` 新增 2 条：禁止调用的 caller 在报告里必须是 `ARCHITECTURE_VIOLATION`（且合法请求不被误伤）；`forbiddenDownloaders` 必须含 `player / resourceLoader / growingFileReader / preload`，且不含 `downloader`。

## 本轮修掉的真实缺陷

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | 控制器在 `beginPlay` 之前记 `noteTransportStart` | `beginPlay` 重置 attempt 标志 → 报告里 `v2Attempted=false`，一次成功的 V2 播放被记成「没走过 V2」 |
| 2 | 等待本地路径超时抛的是 `VideoSourceException`（文案「下载未产生本地文件」） | 一次「一个字节都没来」的失败被分类成缓存缺失而不是网络 stall，`RequestFailure` 也不是 `offline`。改为 `VideoSourceStalled`，文案与分类都指向网络 |
| 3 | 无原生桥平台仍在 `_resolvePlaySource` 里静默落到 V1 | AUTO 链名义上 V2-only，实际还能走 proxy |

## 数字

- `flutter analyze`：0 issue
- `flutter test`：**939 passed / 1 skipped / 0 failed**（STEP 2 结束时是 935）
- 静态门槛：8 条

## 仍未验证（不写成通过）

真机 moov 布局、152MB / 593MB / 1GB 矩阵、后台 / 弱网 / Seek / remap 行为 —— 属 STEP 6，未执行。
