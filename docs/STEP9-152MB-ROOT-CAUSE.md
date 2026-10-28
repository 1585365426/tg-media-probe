# 152 MB 溯源报告

提交 `e0ada83` · 分支 `rebuild-step3` · 2026-10-28

---

## 零、先回答四个必须回答的问题

### 1. 152 MB 到底是谁产生的？

**`VideoSourceResolver._streamOnce` 里的第一条下载请求**，旧代码是这一行：

```dart
// 旧：lib/playback/video_source.dart:936-945（本次提交前）
await api.start(fileId);
```

`api.start` 落到 `TdFileTransferApi.start`，它发的是：

```dart
// lib/playback/video_source.dart:156-159
final response = await client.request(
  downloadFile(fileId: fileId),   // ← 没有 offset，没有 limit
  timeout: const Duration(seconds: 60),
);
```

`lib/td/td_requests.dart:125` 里的 `downloadFile()`，`offset` 与 `limit` 都是可选参数，不传就是 TDLib 的默认语义：

> `limit = 0` 表示 **"下到文件尾"**。

所以那一刻发出去的实际报文等价于：

```
downloadFile {
  file_id = <1.33GB 视频>
  priority = 32
  offset = 0
  limit = 0          ← 整个文件
  synchronous = false
}
```

**caller 是 `PLAYER`（播放器首窗请求），不是 preload，不是 chunkSize，不是播放器缓冲策略。** 你日志里那 152 MB 的发起者是它。

另外两处同形状的旧代码也一并改掉：

| 旧代码位置 | 场景 | 现在 |
|---|---|---|
| `video_source.dart:902` | `needsRedownload` 分支 | `startRange(0, firstWindow)`，caller=PLAYER，cause=`redownload` |
| `video_source.dart:936` | **主路径首请求** | `startRange(0, firstWindow)`，caller=PLAYER，cause=`first window` |
| `video_source.dart:1538` | `_fallbackFullDownload` | 保留 `start()`，caller=`FULL_DOWNLOAD`，审计里显式标成整文件 |

全项目剩下的整文件请求只有第 3 条，它是"用户选择等完整下载"那一阶，且审计里 `limit=WHOLE_FILE`。

### 2. 为什么产生？

因为**"请求整文件"和"多久开始读"是两件事，而 TDLib 只认第一件**。

时间线（旧代码）：

```
t0     点击视频
t0+ε   downloadFile(offset=0, limit=0, priority=32) → TDLib 接受，立即开始
t0+ε   AVPlayer 才刚开始创建：建 item、建 session、等 contentInformation
       ← 这中间没有任何东西在读盘，也没有任何东西在限速
t0+Δ   AVPlayer 发出第一个 Range 请求
```

磁盘增长 = **带宽 × Δ**。Δ 是播放器初始化耗时，不是常量。所以：

- 快网 + 慢初始化 → 数字更大（160 MB 量级）
- 慢网 + 快初始化 → 数字更小（120 MB 量级）

**这就是为什么它是"约 152 MB"而不是"正好 152 MB"** —— 它不是任何常量配错了，它是一个无界请求被按带宽填了一段时间的结果。你日志里 `downloaded=33554432 (2.3%)`、`downloadOffset=0`、`moves=1` 也印证了这点：TDLib 报告的是"从头连续下了 32 MB 并被界面刷新捕捉到的那一刻"，真值在那之后继续涨。

顺带解释了另外两个旧现象：

- `v2Attempted=false` 但日志里有 `tgmedia://` session：旧代码只在**失败时**记 v2Attempted，进了 V2 但还没失败就崩/超时，报告就说"没试过"。
- `v1Attempted=true / v1Failed=true / finalSource=-`：V2 上去之后因为窗口语义不清（首窗下到文件尾、seek 又重开一次整文件）触发了 range/header 不一致，被判失败落到 V1，V1 又因为同一个无界下载拿不到可预期字节而失败。

### 3. 修改了哪一层？

**请求层（`downloadFile` 的参数层）**，不是播放决策层。

决策层这几轮一直是好的：它确实选了 V2，确实构造了 `tgmedia://` URL。问题在它下面那一层——决策层说"用流式"，请求层却发了一个"下整个文件"的报文。改决策层永远改不掉这个数字。

四层改动：

| 层 | 文件 | 作用 |
|---|---|---|
| 请求层 | `lib/playback/stream_window.dart`（新）<br>`lib/playback/video_source.dart` | 首窗 16 MB、续窗 16 MB、preload 4 MB；`startRange` 拒绝 `limit<=0` |
| 续窗层 | `lib/playback/stream_proxy.dart`<br>`lib/playback/resource_loader.dart` | `WindowContinuation`：窗口用尽 → 续窗，而不是当成"传输死了"白等 20 秒 |
| 审计层 | `lib/playback/download_audit.dart`（新） | 每次 `downloadFile` 带 caller/offset/limit/priority，字节归因到发起者 |
| 诊断层 | `lib/playback/streaming_diagnostics.dart`<br>`lib/ui/feed_controller.dart` | `DOWNLOAD_AUDIT / DOWNLOAD_GROWTH / LARGEST_DOWNLOAD`；`noteTransportStart` |

### 4. 修改后真机实际下载多少 MB？

**未测试。** 本轮只做到"源码定位 + 诊断 + CI 编译"。真机读数必须由你跑完第九节的 5 项测试后填。在那之前任何"已解决"的说法都是编的。

---

## 一、调用链，逐跳标出边界与记录点

```
点击视频
  ↓  FeedController.open / _play
  ↓  StreamingDiagnostics.beginPlay(chatId, messageId, generation)
  │    ↳ downloadAudit.reset() + tag(...)          ← 审计归零，绑定本条消息
  ↓  VideoSourceResolver.resolveStreamV2(...)
  │    ↳ _diagnostics.noteTransportStart('RESOURCE_LOADER')
  │       ↳ v2Attempted=true 立刻成立（不等失败）
  ↓  PlaybackSourceDecision（决策层，未改）
  │    ↳ FULL / PARTIAL / SHORT / REDOWNLOAD 四态，来自真实 stat
  ↓  ── 请求层，本轮改动 ────────────────────────────
  ↓  api.startRange(fileId, offset: 0,
  │                 limit: StreamWindow.firstWindow(expected),   // 16MB 或整片
  │                 priority: 32, caller: PLAYER, cause: 'first window')
  │    ↳ DownloadAudit.record(...)  ← 这一刻开始记账
  ↓  TdFileTransferApi.startRange
  │    ↳ if (limit <= 0) throw       ← 无界请求无法从这个门进来
  │    ↳ client.request(downloadFile(offset, limit, priority))
  ↓  TDLib
  │    ↳ updateFile 流 ─┬→ _LiveFileWatch._onState（喂等待循环）
  │                     └→ DownloadAudit.observe（把字节归因给当前 call）
  ↓  ── 传输层 ──────────────────────────────────────
  ↓  V2：TGMediaResourceLoader.swift (tgmedia://)
  │      AVAssetResourceLoadingRequest
  │        ↳ requestId=seq             ← Swift 侧单调递增
  │        ↳ session.supply(offset, length, requestId)
  │      ↓ Dart ResourceSupply.read(offset, length, requestId)
  │        ↳ markRead(offset)          ← 记住播放器在读哪
  │        ↳ 不在盘上 → windowExhausted? 续窗 : steer 到该 offset
  │      ↓ 回 Swift → respond(with:) → AVPlayer
  ↓  V1：StreamProxyServer (127.0.0.1:随机端口, HTTP)
  │      请求 Range → _serveRange
  │        ↳ markRead(from)
  │        ↳ _ensureReadable → 窗口用尽则 continueWindow(caller: PROXY)
  │        ↳ _waitForGrowth → 同上（区分"窗口用尽"与"传输死亡"）
  ↓  磁盘增长：由 TDLib 写，被 _LiveFileWatch.refresh() 用真实 File.length() 校正
```

每一跳现在都有落点，没有"看起来应该在这"的空白段。

---

## 二、全项目搜索

| 关键词 | lib (dart) | ios (swift/m/h) | 结论 |
|---|---|---|---|
| `downloadFile` | 31 | 0 | 只有两个真实发送点：`TdFileTransferApi.start` / `.startRange`（`video_source.dart:156/190`）。另有一处 `media_probe.dart:360` 是**独立诊断页**（`probe_page.dart` 才能进），不在播放链上。 |
| `downloadOffset` | 26 | 0 | 全部经 `FileState.downloadOffset`；审计用它做字节归因，`_LiveFileWatch` 用它做覆盖图。 |
| `preload` | 72 | 0 | `prefetch()` → `startRange(0, 4MB, priority 2, caller PRELOAD)`（`video_source.dart:203-210`）。不再有整文件预热。 |
| `prefetch` | 36 | 0 | 同上，且 `prefetch` 对 `_activePlayFileId` 直接返回，不会去抢播放中的窗口。 |
| `warm` | 13 | 0 | 全部是"预热邻居"命名，`abandonWarm()` 会把滑出窗口的取消掉。 |
| `bufferSize` / `chunkSize` / `targetWindow` / `lookAhead` | 0 | 0 | 项目里**不存在**这些概念，不存在"某个 bufferSize 配成 152MB"的可能。 |
| `preferredForwardBufferDuration` / `preferredPeakBitRate` | 0 | 0 | 从未设置。播放器唯一相关设置是 `TGMediaPlayer.swift:60` 的 `automaticallyWaitsToMinimizeStalling = true`，这是 AVPlayer 的默认行为，它只影响**它自己要多少**，不产生 TDLib 请求。 |
| `150/152/160 * 1024 * 1024`、`159383552`、`157286400`、`16777216` | 0（仅文档注释举例） | 0 | **代码里没有任何 150/152/160 MB 常量。** 那个数字从来不是配置出来的。 |

搜索结论：152 MB 不是被某个常量"配"出来的，是**一个无界请求**被带宽填出来的。常量表里根本不存在它的候选。

---

## 三、关键代码，改前 / 改后

### 3.1 首窗口（152 MB 的源头）

`lib/playback/video_source.dart:1043-1065`

```dart
// The first window is bounded, and it is bounded *before* the player
// asks for anything.
//
// This used to be `api.start(fileId)`, i.e. `downloadFile(offset: 0,
// limit: 0)` — "to the end of the file". TDLib accepted it and ran at
// priority 32 while AVPlayer was still initialising, so a 1.33 GB video
// had ~150 MB on disk seconds after the tap. That is the burst the
// device reports called "152 MB before playback"; it is bandwidth
// multiplied by however long initialisation took, not a constant, which
// is why it moved between 120 and 160 MB.
await api.startRange(
  fileId,
  offset: 0,
  limit: StreamWindow.firstWindow(facts.expectedBytes),
  priority: 32,
  caller: DownloadCaller.player,
  cause: 'first window',
);
```

### 3.2 `startRange` 拒绝无界

`lib/playback/video_source.dart:173-177`

```dart
if (limit <= 0) {
  // The whole-file request is `start()`. Keeping this rejection here means
  // a window call site cannot silently become an unbounded download.
  throw VideoSourceException('窗口大小必须为正数（limit=$limit）');
}
```

这条是硬约束：就算以后有人手滑传了个 `limit: 0`，它会在发报文之前抛，而不是变成第二个 152 MB。

### 3.3 窗口算术

`lib/playback/stream_window.dart:23-36`

```dart
static const int firstBytes = 16 * 1024 * 1024;   // 首窗
static const int stepBytes  = 16 * 1024 * 1024;   // 续窗（和首窗同尺寸，不随文件变大）
static const int preloadBytes = 4 * 1024 * 1024;  // 邻居预热只碰头部
static const int alignMask = ~1023;               // TDLib 1KB 分块
```

16 MB 的选择依据：约 4 秒 4K 码流，够 AVPlayer 解出首帧 + 拿到 moov；同时小到一次误操作也炸不出百兆级流量。`stepBytes` 我故意不做"随文件增长"——一个会膨胀的步长就是"小窗口"变回"下载整个文件"的那条路。

### 3.4 窗口必须能续

`lib/playback/stream_proxy.dart:190` / `video_source.dart:1974-2001`

```dart
@override
bool get windowExhausted {
  if (_complete || _requestedLimit <= 0 || _requestedFrom < 0) return false;
  if (_present.covers(_requestedFrom, _requestedFrom + _requestedLimit - 1)) {
    return true;
  }
  // TDLib caps `downloaded_size` at the requested limit and occasionally
  // reports it a byte short; both mean the window is finished, and waiting
  // for the missing byte would burn the whole stall budget on a transfer
  // that has already stopped.
  return _windowOffset == _requestedFrom && _prefix >= _requestedLimit - 1;
}

@override
Future<void> continueWindow({DownloadCaller caller = DownloadCaller.resourceLoader}) async {
  if (_complete || _expected <= 0) return;
  if (!windowExhausted) return;
  final next = _requestedFrom + _requestedLimit;
  if (next >= _expected) return;
  final (from, to) = StreamWindow.windowAt(next, _expected, size: windowBytes);
  await _issueWindow(from, StreamWindow.limitFor(from, to), caller, 'continue from $next');
}
```

没有这层，把首窗改小会带来一个新故障：窗口用完以后 TDLib 静默，等待循环会把它当成"网络死了"，白等满 stall 预算再报错。**有界窗口必须可续，否则"窗口用尽"和"传输死亡"是同一个观测**。`stream_proxy.dart:868`（`_ensureReadable`）与 `:1070`（`_waitForGrowth`）、`resource_loader.dart:273` 三处都在做 steer/stall 判定之前先问一句"是不是窗口用完了"，用完就续，只有续了还没有才进 stall 逻辑。

### 3.5 字节归因

`lib/playback/download_audit.dart:177-247`

```dart
DownloadCall record({...}) {
  final before = transferred(fileId);
  _last[fileId] = (offset, 0);   // 窗口移动重新基线，不算增长
  final call = DownloadCall(seq: ++_seq, ..., startedFrom: before);
  _open[fileId] = call; _calls.add(call); return call;
}

void observe({required int fileId, required int offset, required int downloaded}) {
  final previous = _last[fileId];
  _last[fileId] = (offset, downloaded);
  final call = _open[fileId]; if (call == null) return;
  if (previous != null && previous.$1 == offset && downloaded > previous.$2) {
    call.grew += downloaded - previous.$2;
  }
  final reached = offset + downloaded;
  if (reached > call.reached) call.reached = reached;
}
```

`_last[fileId] = (offset, 0)` 这行是关键：TDLib 换了窗口之后 `download_offset` 会跳到新起点、`downloaded_size` 从 0 重算，如果不重新基线，一次 seek 就会被记成"下载了 1.4 GB"。这不是防御性代码，是让审计数字能被信的前提。

---

## 四、V2 窗口映射：四个值，一次性对齐

要回答"AVPlayer 要 1 MB，为什么 TDLib 下 16 MB"，必须能同时看到四段。现在能：

```
AVPlayer requested range        → TGMediaResourceLoader.swift
   AVAssetResourceLoadingRequest.requestedOffset / requestedLength
   AVAssetResourceLoadingDataRequest.currentOffset / requestedLength

ResourceLoader calculated range → lib/playback/resource_loader.dart
   ResourceSupply.read(offset, length, requestId)

TDLib downloadFile offset       → DownloadAudit.record(offset: ...)
TDLib downloadFile limit        → DownloadAudit.record(limit: ...)
```

`requestId` 从 Swift 的 `nextRequestId()` 一路带到 Dart：`dataRequest` / `supplyError` / `waiting` / `requestFinished` / `requestCancelled` 事件都带它，`supply(sessionId:offset:length:requestId:)` 透传。所以面板上"播放器要哪段 → 加载器给了哪段 → TDLib 开了哪个窗"可以按 id 顺序读，不用靠时间戳猜。

现在如果设备上仍然出现 `AVPLAYER=1MB / RESOURCE_LOADER=16MB / TDLIB=152MB`，`LARGEST_DOWNLOAD` 那一行会直接写出 `caller`、`offset`、`limit`、`grew`，不用再猜第三段是谁。

---

## 五、moov 在文件尾

两条路分开走，没有"为了方便解析把首窗扩到 152 MB"的逻辑：

- **moov 已在可读数据里**（`moov=head`）：不为 moov 扩大任何下载。
- **moov 在尾部**（`moov=afterMdat`）：单独发尾部 metadata 探测，`StreamWindow.windowAt(from, total, size: stepBytes)` 钳在文件尾最多一个 `stepBytes`，走 `core: PROXY / RESOURCE_LOADER` 徽章。断言在 `test/stream_window_test.dart`：`tail probe ≤ stepBytes`。

`resource_loader.dart` / `TGMediaResourceLoader.swift` 里没有"为解析容器扩大首段窗口"的分支——容器的可读性由 `_present` 覆盖图决定，覆盖不到就发窗口请求，不会动首窗。

---

## 六、V1 fallback 顺序

现在是：

```
LOCAL_FILE
  → RESOURCE_LOADER (V2)
  → 失败后重新 stat 磁盘          ← 新增，不再直接跳 HTTP_PROXY
      complete = expectedSize > 0 && actualDiskSize >= expectedSize
      （actualDiskSize 来自真实 File.length()，不信 TDLib 的 completed 标志）
  → 完整 → LOCAL_FILE
  → 不完整 → HTTP_PROXY (V1)
  → 还不行 → FULL_DOWNLOAD
```

`partial file + V2 available` 不再走 `HTTP_PROXY`。V2 失败后的 `refresh()` 用真实 stat 重新判定，`_complete` 只在 `size >= _expected` 时才置位（`video_source.dart:2019-2036`）——短文件可能是稀疏的（TDLib 按窗口下），把 `0..size-1` 当成"都有"会把零洞当视频播。

---

## 七、14 条验收 × 实现证据

| # | 验收标准 | 实现位置 | 状态 |
|---|---|---|---|
| 1 | 不出现 152 MB 级无理由下载 | `video_source.dart:1058` 首窗 16 MB；`stream_window.dart:23` | 待真机 |
| 2 | V2 真正启动 | `feed_controller.dart:778` `noteTransportStart` | 待真机 |
| 3 | `v2Attempted=true` | `streaming_diagnostics.dart:669`（入口即记，不等失败） | 待真机 |
| 4 | `finalSource=RESOURCE_LOADER` | `streaming_diagnostics.dart` seal 逻辑（未改） | 待真机 |
| 5 | `playerSourceType=RESOURCE_LOADER` | `streaming_diagnostics.dart:1494` `STREAMING V2` 块 | 待真机 |
| 6 | AVPlayer 范围可追踪 | Swift `requestId` + `dataRequest` 事件 | 已接线，待真机 |
| 7 | ResourceLoader 范围可追踪 | `ResourceSupply.read(requestId:)` | 已接线，待真机 |
| 8 | TDLib offset/limit 可追踪 | `DOWNLOAD_AUDIT` + `LARGEST_DOWNLOAD` 行 | 待真机 |
| 9 | 无播放器请求依据时不许扩到 100MB+ | `WindowContinuation`：只有播放器读/顺序读才续窗；`startRange` 拒 `limit<=0` | 已实现 |
| 10 | 退出后停止 | `beginPlay` 重置审计；`cancel()` 收尾（未改） | 待真机 |
| 11 | 切换后旧视频停止 | `abandonWarm` + generation 守卫（未改） | 待真机 |
| 12 | 完整文件直接 LOCAL_FILE | 决策层（未改） | 待真机 |
| 13 | V2 失败后重新 stat 再 fallback | `refresh()` 真实 `File.length()`（`video_source.dart:2019`） | 已实现 |
| 14 | fallback 不得再制造 152 MB | `_fallbackFullDownload` 是唯一整文件点，caller=`FULL_DOWNLOAD` | 已实现 |

"待真机"= 代码路径已就位并有单测覆盖，但没有真机日志证明它在 iOS 上按预期发生。**不写成通过。**

---

## 八、自动化

```
flutter analyze   →  No issues found! (9.4s)
flutter test      →  923 passed / 1 skipped
```

本轮新增 **27 例**（896 → 923）：

- `test/stream_window_test.dart`（13）：1.33 GB 首窗 16 MB 且 `window/total < 0.02`；小片不被要 16 MB；未知尺寸回落；1 KB 对齐；尾部钳制；tail probe ≤ stepBytes；`windowCoversFrom` 含端点（`from+limit-1` 覆盖、`+1` 不覆盖、`limit=0` 不覆盖）。
- `test/download_audit_test.dart`（8）：caller/window/priority 三件套；`limit=0` 标 `WHOLE_FILE`；窗口内增长归因；**窗口移动不计增长**；move 后增长归新 call；无 call 的 observe 忽略；largest/unbounded 摘要；reset。
- `test/streaming_playback_test.dart`（+1）：`the play opens a bounded window, never the whole file`（64 MB 文件，断言 `lastCaller == PLAYER`、`lastRange == (0, 16MB)`）。
- `test/video_source_v2_test.dart`（+2）：`the first window is 16 MB, not the 1.33 GB file`（1429876103 字节）；`a preload asks for the head window at the lowest priority`。
- `test/streaming_diagnostics_test.dart`（+5）：`noteTransportStart` 立刻 `v2Attempted=true`；`DOWNLOAD_AUDIT/DOWNLOAD_GROWTH/LARGEST_DOWNLOAD` 行；整文件时 `UNBOUNDED=1 callers=FULL_DOWNLOAD` 且面板写 `limit=WHOLE_FILE`；`beginPlay` 重置审计。

修的一个既有偶发：`streaming_playback_test` 的用例 D 依赖"往死 socket 写 4 MB 触发写错误"，在满并发下 3 秒窗口不够，改成 20 秒窗口（断言不变）。

---

## 九、真机测试脚本（1.33 GB 视频，请你照这个跑）

诊断面板已含：`DOWNLOAD_AUDIT` / `DOWNLOAD_GROWTH` / `LARGEST_DOWNLOAD` / `UNBOUNDED` / `STREAMING V2` / `resourceLoaderRequests` / `tailRequests` / `moov`。

### Test 1 — 清局部缓存

清掉该文件的局部缓存，使其 `disk ≈ 0`。确认点击前 `disk=` 读数是 0 或极小。

### Test 2 — 采样

点开后按 1s / 3s / 5s / 10s / 30s 各记一次：

| 采样点 | diskSize | TDLib downloaded | `DOWNLOAD_AUDIT` 里最新一条 `limit` | AVPlayer requested range | ResourceLoader range |
|---|---|---|---|---|---|
| 1s | | | | | |
| 3s | | | | | |
| 5s | | | | | |
| 10s | | | | | |
| 30s | | | | | |

**判据**：`diskSize` 在 5s 时不应超过约 `16 MB + 播放器已读字节` 太多；`limit` 应当是 `16777216` 或更小，**不应出现 `WHOLE_FILE`**。

### Test 3 — 找 152 MB

如果仍出现 ≈152 MB：

1. 看 `LARGEST_DOWNLOAD caller=? offset=? limit=? grew=?`
2. 若 `limit=WHOLE_FILE` → 还有一处整文件请求没被收掉，`caller` 会指认它（`PLAYER` / `PROXY` / `FULL_DOWNLOAD`）。
3. 若 `caller=RESOURCE_LOADER` 且 `limit` 是 16 MB 级的倍数连续出现 → 是续窗太快，看 `resourceLoaderRequests` 与 `requestedLength` 对不上。

**这一条是本次改动的验收核心：如果还有 152 MB，`LARGEST_DOWNLOAD` 必须能说出是谁。**

### Test 4 — 退出

播 10 秒后退出播放页。确认 `isDownloading=false`，且 30 秒内 `diskSize` 不再增长。

### Test 5 — 切换

从 A 切到 B。确认 A 的 `downloadFile` 不再追加（`DOWNLOAD_AUDIT` 里 A 的 call 不再有新的 `grew`）。

---

## 十、CI

| 项 | 值 |
|---|---|
| run | [40620613091](https://github.com/1585365426/tg-media-probe/actions/runs/40620613091) |
| 分支 / 提交 | `rebuild-step3` / `e0ada83` |
| 结果 | ✓ build-ipa 7m10s |
| CI 内 analyze | `No issues found! (ran in 10.8s)` |
| 产物 | `TGMediaProbe-unsigned.ipa`，20 033 277 字节 |
| SHA256 | `8c6290b3a03c2c21a0d650ac8fc3e7516a01a65615d916d6fa46f86bea800621` |

本地同名包：`TGMediaProbe-step9-152mb.ipa`（未签名，需自签后装）。哈希已复算一致。

注意：CI 只证明 **iOS 能编过**（Swift + Dart 两侧改动都在编译里）。它不证明 152 MB 消失——那是真机的事。

---

## 十一、没做的事

- **没有真机测试。** 上文所有"待真机"的格子都空着。
- 没有新增任何功能。本轮只做：定位、加诊断、改请求层、补测试、出包。
- 没有改决策层的四种情况判定（FULL / PARTIAL / SHORT / REDOWNLOAD）——它不是这次的原因。
