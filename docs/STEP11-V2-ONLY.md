# STEP11：V2-only 流式播放

基线：`1c589f0`（STEP10）。
目的：把自动播放的传输路径收成一条，让真机日志只有一个分支可读。

## 一、改动前的三条路

| 位置 | 行为 |
|---|---|
| `lib/ui/feed_controller.dart:776` `_resolvePlaySource` | `StreamingV2.supported` 为真走 V2；任何异常落到下面的 `sources.resolveStream(...)` = V1 |
| `feed_controller.dart:955` `_recoverFromStreamFailure` | 解析失败 → 重测磁盘 → 第 2 步 `_tryV1` |
| `feed_controller.dart:1006` `_nextTransportAfter` | 播放器初始化失败 → `decideAfterTransportFailure` 返回 `httpProxy` → `_tryV1` |

也就是说：一次点击最多触发 **三次** 传输尝试（V2 → V1 → 再来一次 V1）。日志里 `v2Attempted=true / v1Attempted=true / v1Failed=true` 就是这三段。

## 二、改动（只动选择逻辑）

| 文件 | 改动 |
|---|---|
| `lib/playback/native_streaming.dart:38` | `StreamingV2.v2Only = true`，一处常量说明策略 |
| `feed_controller.dart:776-825` | V2 分支的三类异常各自记 `noteTransportAttempt('RESOURCE_LOADER', failed: true)` + `noteV2OnlyStop(...)` 后 **rethrow**，不再落到 V1 |
| `feed_controller.dart:983` | `_recoverFromStreamFailure` 第 2 步加 `!StreamingV2.v2Only` 门；V2 失败只做「磁盘完整 → LOCAL_FILE」或报错 |
| `feed_controller.dart:1036` | `decideAfterTransportFailure(..., allowProxy: !StreamingV2.v2Only)` |
| `feed_controller.dart:1075` | 终止消息与分类：V2 失败 → `PlaybackFailure.resourceLoading`，文案明确「未回退 V1，未整文件下载」 |
| `lib/playback/source_decision.dart:299,329` | 新增 `allowProxy`；为 false 时 V2 失败返回 `stop / v2_failed_no_v1`，不再返回 `httpProxy` |

未动：16 MB 首窗口、`StreamWindow`、`ResourceLoaderSession`/`ResourceSupply` 的字节逻辑、`StreamProxyServer`、文件 ID 修复（`statStrict` + `FILE_ID_REMAP`）、整文件下载保护（`forbidWholeFile` / `AUTO_FULL_DOWNLOAD_BLOCKED`）、UI 进度计算。

V1 的代码仍在仓库里、仍有测试，但**从播放路径不可达**。`StreamingV2.supported == false`（非 iOS）时 V1 仍是唯一传输——那不是"V2 失败后的回退"，是这台机器上没有 V2。

## 三、诊断：四个新读数字段

`streaming_diagnostics.dart` 新增，面板与验收报告同时输出：

```text
V2_WINDOW offset=0 limit=16777216 grew=8388608 cause="player=0"
V2_BYTES dataRequests=3 responds=3 toPlayer=4194304 dlGrew=8388608 diskDownloaded=8388608/737148928
FIRST_READ_ERROR source=supplyError code=DOWNLOAD_STALLED offset=1048576 requestId=3 served=524288 msg="…"
V2_ONLY_STOP=…            （没停下时为 -）
WHOLE_FILE_DOWNLOADS=0
```

三个字节数各有各的含义，以前被合成一个数字：

- `toPlayer` — 真正交给 `AVAssetResourceLoadingDataRequest` 的字节（播出去多少）
- `dlGrew` — V2 开的窗口让 TDLib 写下的字节（下载了多少）
- `diskDownloaded` — TDLib `local.downloaded_size` / `expected_size`（磁盘上多少）

`FIRST_READ_ERROR` 只记第一次，取自原生侧的 `supplyError` 与 `playerFailed` 两个事件，保留原始文案和 `requestId`——「读取失败」到底是 loader 供不出字节，还是字节到了 AVFoundation 拒收，这条线分开。

## 四、验收（真机）

同一个 703 MB 视频，清局部缓存后点击：

通过：

```text
playbackDecision=RESOURCE_LOADER   v2Attempted=true   v1Attempted=false
V2_WINDOW offset=0 limit=16777216
WHOLE_FILE_DOWNLOADS=0             AUTO_FULL_DOWNLOAD_BLOCKED=0
finalSource=RESOURCE_LOADER        playerSourceType=RESOURCE_LOADER
FIRST_READ_ERROR none
```

失败也可以接受，但必须是这一种：

```text
v2Attempted=true  v2Failed=true  v1Attempted=false  v1Failed=false
V2_ONLY_STOP=<原因>
WHOLE_FILE_DOWNLOADS=0
finalSource=-
```

不接受：

```text
v1Attempted=true                    （V1 被调用）
WHOLE_FILE_DOWNLOADS>0              （整文件下载）
finalSource=LOCAL_FILE 且 diskDownloaded < total
```

成功判据不是 `SRC=RESOURCE_LOADER`、也不是 `candidate=true`：要看 `V2_WINDOW` 有值、`toPlayer>0`、`firstPlayback` 出现。

## 五、CI

| 项 | 值 |
|---|---|
| run | 40633713459 |
| 提交 | `e421382` |
| 结果 | build-ipa ✓ 6m7s，analyze 无问题 |
| IPA | `TGMediaProbe-step11-v2only.ipa` 20,042,134 B |
| SHA256 | `a483a494536b62748a03c5177097ed1054df0e1fb8cf0c238be06811e43a15ff` |

`flutter test` 938 passed / 1 skipped（+6：控制器 1、决策 2、诊断 3）。
