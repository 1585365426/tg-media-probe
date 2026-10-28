# STEP 2–5 二次自检报告（B+ 架构）

- 仓库：`tg_media_probe`，分支 `rebuild-step3`
- HEAD：`fbf578d`（STEP 3-5：V1 is gone from the AUTO chain, not switched off）
- 自检时间：2026-10-28
- 自检对象：STEP 2 锁定的 17 条规则，在 STEP 3-5（V1 删除）之后的**实际代码状态**
- 与一次自检的区别：一次自检报「删了哪些调用点」；二次自检做的是**可达性证明** —— 代码还在的东西，是否还能被 AUTO 链走到。

---

## 一、自检方法（都是真实执行过的命令）

| 项目 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | `No issues found! (ran in 8.0s)` |
| 全量测试 | `flutter test` | **939 passed / 1 skipped / 0 failed**，`TEST_EXIT=0` |
| 下载 API 穷举 | `grep -rn "downloadFile(\|startRange(" lib/` | 见第二节 A |
| 入口穷举 | `grep -rn "resolveStream(\|resolveStreamV2(" lib/` | 见第二节 B |
| 静态门槛 | `flutter test test/architecture_scan_test.dart` | 8 条全绿 |
| 审计门槛 | `flutter test test/download_audit_test.dart` | 含 2 条 B+ 违规断言，全绿 |

环境注意：跑测试前必须 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy`，否则 flutter_tester 的本地 WebSocket 被代理劫持，全部用例加载失败。

---

## 二、可达性证明（本次自检的核心新增）

### A. 下载 API 的全部落点

| 位置 | 性质 | AUTO 可达 |
|---|---|---|
| `lib/td/td_requests.dart:125` | `downloadFile(...)` 请求构造（纯 JSON） | 是（底层，合法） |
| `lib/playback/video_source.dart:209` | 整文件 `start()` → `downloadFile(fileId)` | 是，但**只经 Downloader** |
| `lib/playback/video_source.dart:242` | 窗口 `startRange()` → `downloadFile(offset, limit)` | **否**（见下） |
| `lib/td/media_probe.dart:360` | 探针工具的独立探测调用 | 否（工具功能，不在播放链路） |

`startRange` 的三个内部落点：

| 位置 | 用途 | AUTO 可达 |
|---|---|---|
| `video_source.dart:217` | `FileTransferApi.startRange` 实现 | — |
| `video_source.dart:255` | `api.prefetch`（接口默认实现会转 startRange） | **否**：`api.prefetch` 全库零调用点 |
| `video_source.dart:2384` | `_LiveFileWatch._issueWindow` → `startRange(caller: resourceLoader)` | **否**：唯一上游是 `StreamProxyServer`（`stream_proxy.dart:953`），而 `StreamProxyServer` 只在 `_defaultProxy` 里构造 |

### B. 播放入口的全部落点

| 入口 | 调用点 | 结论 |
|---|---|---|
| `resolveStreamV2(...)` | `lib/ui/feed_controller.dart:806` —— **唯一** | AUTO 唯一通路 |
| `resolveStream(...)`（V1） | **lib 内零调用点**，只剩 `video_source.dart:851` 的定义 | 不可达 |

链路的完整形状（可执行的部分）：

```
feed_controller.dart:806  resolveStreamV2
  → video_source.dart:894  _resolveStreamTransport(transport: resourceLoader)
  → video_source.dart:1152 _streamOnce
  → video_source.dart:1332 downloader.ensureFullDownload(...)      ← 全链唯一整文件下载
  → video_source.dart:1454 _LiveProgressBridge(watch) + GrowingFileReader
  → video_source.dart:1463 _startResourceLoader(...)
  → resource_loader.dart     ResourceSupply.read(offset) → 本地回读
```

`_streamOnce` 内 `ensureFullDownload` 出现 **1 次**；`startRange(` / `_api.start(` 出现 **0 次**（静态门槛第 5 条锁住）。

### C. 因此：「代码保留但不进 AUTO」成立

V2 Range Streaming 的残留（`_LiveFileWatch.requestWindow`、`StreamProxyServer`、`api.prefetch`）全部保留在仓库里，但都在 `resolveStream`（V1）这一侧，而 V1 在 lib 内已无调用点。这与规则②「代码可保留但不得进 AUTO」一致。

---

## 三、17 条规则逐条核对

| # | 规则 | 结论 | 证据 |
|---|---|---|---|
| ① | `downloader.dart` 是 TDLib 下载唯一入口，`limit=0` 只许在此 | **PASS** | `_streamOnce` 唯一调用 `ensureFullDownload`（video_source:1332）；`network api.start` 由 Downloader 发起 |
| ② | 现有 V2 Range Streaming 不得进 AUTO | **PASS** | 见第二节；`_issueWindow` 上游只有不可达的 `StreamProxyServer` |
| ③ | AUTO 链：不完整→查磁盘→Downloader→GrowingFileReader→ResourceLoader→AVPlayer | **PASS** | 链条见第二节 B；磁盘检查在 `downloader.dart:177` |
| ④ | `requiredFreeSpace >= (expected - downloaded) × 1.5`，不足 `DISK_FULL` | **PASS** | `downloader.dart:88` `safetyFactor = 1.5`；`:177` `remaining * safetyFactor`；`:187` 置 `diskFull`；`DiskFullException`（:274）→ `feed_controller.dart:815` 记 `DISK_FULL` 决策 |
| ⑤ | GrowingFileReader 具 `safeWatermark/read/waitFor/isComplete/onComplete/invalidate`，水位 = min(TDLib, stat) | **PASS** | `growing_file_reader.dart:156-165`；stat 失败（`disk < 0`）返回 **0**，不回退 TDLib 数字 |
| ⑥ | ResourceLoader 纯本地回读，缺数据 = WAIT，绝不 startRange | **PASS** | `resource_loader.dart:216-250`；文件内无 `startRange`、无 `FileTransferApi` import |
| ⑦ | 越界未完成 → WAIT；仅水位与磁盘都到 `expectedSize` 才 EOF | **PASS** | 同上；`reader.isComplete` 先行拒绝（`:229` 注释所在分支） |
| ⑧ | `WAIT_TIMEOUT` 默认 10s；超时不 finishLoading、不再 downloadFile、下载仍在跑就继续等 | **PASS** | `growing_file_reader.dart:114` 默认 10s；`resource_loader.dart:231` 判定；超时只改 `errorCode`/`downloading`，无下载调用 |
| ⑨ | `contentLength` = `expectedSize`，非磁盘大小 | **PASS** | `ResourceSupply` 的 `total` 来自 `reader.expectedSize`；测试 `carries expectedSize as contentLength` 锁定 |
| ⑩ | `finalSource` 只许 `RESOURCE_LOADER / LOCAL_FILE / FAILED` | **PASS** | `PlaySource.file` origin=`LOCAL_FILE`（:346）、`.resourceLoader`=`RESOURCE_LOADER`（:361）、`.stream`=`HTTP_PROXY`（:353，不可达）；`feed_controller.dart:899/1044/1567` 写入 |
| ⑪ | 152MB 不得 PLAYER→downloadFile；593MB 不得 partial→HTTP_PROXY | **PASS** | 静态门槛：player 侧零下载符号；`_tryV1` 已删除，`allowProxy: false` 为唯一写法 |
| ⑫ | DownloadAudit 补 chatId/messageId/fileUniqueId/generation/diskBefore/diskAfter + `ARCHITECTURE_VIOLATION` | **PASS** | `download_audit.dart:59-64` 禁用集合、`:318-321` 违规记录；`describe()` 输出 `before=` / `grew=` |
| ⑬ | CI 全过才出 IPA | **PASS** | run `40704532414`（`fbf578d`）`build-ipa` success，IPA 才落到桌面 |
| ⑭ | 静态扫描为硬门槛（Downloader 外出现 downloadFile 即 FAIL） | **PASS** | `architecture_scan_test.dart` 8 条，见第四节 |
| ⑮ | moov 未实测不得写成已验证 | **PASS（纪律）** | 报告与汇报中 moov 一律标「未验证」 |
| ⑯ | fileId remap（4999→2221）保留 messageId 业务身份 | **PASS** | `video_source.dart:760`、`:1121` `noteFileIdRemap`；`:1178` / `:1280` 转 `_MissingFile` |
| ⑰ | STEP 2-5 期间不让用户反复装 IPA | **PASS** | 仅 STEP 2-5 收口时交付 1 次 IPA |

**合计：17 条全 PASS。**

---

## 四、静态门槛清单（`test/architecture_scan_test.dart`，8 条，全绿）

| # | 用例 | 锁住的东西 |
|---|---|---|
| 1 | `downloadFile() has exactly three legal homes` | `downloadFile(` 只许出现在 `td_requests.dart` / `video_source.dart` 传输层 / `media_probe.dart` |
| 2 | `the Downloader itself never sends a ranged window` | Downloader 不得 `startRange` |
| 3 | `the file reader cannot reach any download API` | GrowingFileReader 零下载符号 |
| 4 | `the resource loader cannot reach any download API` | ResourceLoader 零下载符号 |
| 5 | `_streamOnce never sends a request of its own` | `_streamOnce` 内禁 `startRange(` / `_api.start(` / `downloadFile(` |
| 6 | `the controller has no second streaming transport` | 控制器内禁 `_tryV1` / `allowProxy: true` / `sources.resolveStream(` / `noteTransportStart('HTTP_PROXY')`；必须见 `allowProxy: false` |
| 7 | `the transport entry is recorded after beginPlay` | `noteTransportStart` 必须在 `beginPlay` 之后，否则被重置抹掉 |
| 8 | `the player path holds no downloader reference at all` | player/proxy/session 侧零 `downloadFile` |

审计侧另有 2 条：禁止 caller 在报告里必须是 `ARCHITECTURE_VIOLATION`（且合法请求不被误伤）；`forbiddenDownloaders` 必须含 `player/resourceLoader/growingFileReader/preload`、不含 `downloader`。

---

## 五、残余风险（如实列，未修）

自检不是宣告完成，这三条是**当前结构上仍存在、但没有实际通路**的东西：

1. **`resolveStream`（V1）仍是 public 方法。** lib 内零调用点，但任何人都能加一行 `sources.resolveStream(...)` 把它复活，因为 `_resolveStreamTransport` 的 `transport` 参数默认值仍是 `httpProxy`（`video_source.dart:1084`）。静态门槛只拦控制器里的 `sources.resolveStream(`，拦不住别处。
   - 建议：把 `transport` 默认值删掉（强制显式传参），或在 `resolveStream` 里加 `assert(false, 'V1 已退出 AUTO')` 级别的护栏。

2. **`_LiveFileWatch` 仍实现 `WindowContinuation`，`requestWindow` 会发 `startRange(caller: resourceLoader)`。** 该类在 AUTO 里被创建（作为 stat 与进度观察源），只是 `_LiveProgressBridge` 只读它的 `headBytes/canDownload/progress`，没人调 `requestWindow`。属于「带枪的人在场，手没碰扳机」。
   - 建议：把 `WindowContinuation` 实现从 `_LiveFileWatch` 上摘掉，只留 `FileProgressWatch`。

3. **`api.prefetch` 保留且默认实现会转 `startRange(caller: preload)`。** 全库零调用点（resolver 的 `prefetch` 已改 stat-only），但接口方法还在，未来有人调就直接是 preload 下载。

---

## 六、数字

- `flutter analyze`：**No issues found**（8.0s）
- `flutter test`：**939 passed / 1 skipped / 0 failed**，退出码 0
- 静态门槛：8 条；审计门槛：含 2 条 B+ 断言
- HEAD `fbf578d`；CI run `40704532414` `build-ipa` success
- 桌面 IPA：`TGMediaProbe-step345-noV1.ipa`（19,973,011 B），sha256 `768b7e5f83acda839d8684ac61018634123113ab951e53a76a87eae18565804d`

---

## 七、仍未验证（不写成通过）

以下全部属于 STEP 6「真机矩阵」，本轮**未执行**，报告里不得出现「已通过」：

| 项目 | 状态 |
|---|---|
| moov 布局实测（faststart vs tail-moov）、moovPosition / startupBytes / playerReadyTime | 未测 |
| 23 MB / 152 MB / 593 MB / 1 GB 四档真机 | 未测 |
| 弱网、后台播放、Seek | 未测 |
| fileId remap 真机复现（4999→2221） | 未测 |
| 磁盘不足触发 `DISK_FULL` 的真机表现 | 未测 |
| `WAIT_TIMEOUT` 在真实弱网下的表现（10s 是否过短） | 未测 |

一句结论：**代码层 17 条全 PASS，测试与静态门槛全绿，但「能不能真的边下边播」这个问题只有真机能回答 —— 现在还没装。**
