# `no_file_record` 与 4999 → 2221

提交 `1c589f0` · 分支 `rebuild-step3` · 2026-10-28

---

## 零、一句话结论

**4999 → 2221 不是映射错乱，是 TDLib 拒绝了 4999 这个 id，而代码把"拒绝"当成了"还没有记录"。**

`TdFileTransferApi.stat` 对两种情况都返回 `null`：

```dart
// 改前 lib/playback/video_source.dart:130-138
final response = await client.request(getFile(fileId), ...);
if (errorText(response) != null) return null;   // ← 拒绝 和 还没有记录 都是 null
return fileFromResponse(response);
```

`null` 被喂给 `SourceFacts.missing()` → `hasRecord=false` → `decidePlaybackSource` 返回 `fullDownload / no_file_record`。

所以日志里那三行不是互相矛盾的三件事，而是**同一件事的三个阶段**：

```
record file=4999      ← 镜像里的 tile 记录（旧 id）
candidateReason=no_file_record   ← TDLib 拒绝 4999，被读成"没记录"
#1 file=4999 grew=0   ← 整文件请求打在死 id 上，一个字节都没动
#2 file=2221 grew=24316497       ← 修好 id 之后，把 24MB 全下了
```

---

## 一、完整调用链

### 1.1 到 `no_file_record` 为止

```
FeedController._activate(record)
  record.fileId    = 4999          ← 镜像 tile 里的 id（诊断打印的就是它）
  record.messageId = 9431941120
  record.sizeBytes = 24316497
    ↓
_diagnostics.noteRecordSnapshot(fileId: 4999, ...)     ← RECORD 那一行的来源
    ↓
_resolvePlaySource → sources.resolveStreamV2(4999)
    ↓
_streamWithRepair(activeId = 4999)
    ↓
_streamOnce(4999)
    ↓
api.stat(4999)                          ← ★ 第一处
  TdFileTransferApi.stat → getFile(4999) → TDLib error
    → return null                        ← 错误被吞掉，与"没有记录"不可区分
    ↓
_factsFor(null, 4999) → SourceFacts.missing(4999) → hasRecord = false
    ↓
decidePlaybackSource(...)
    ↓
PlaybackDecision(source: fullDownload, reason: 'no_file_record')
    ↓
_streamOnce 抛 VideoSourceException('流式播放不可用（no_file_record）')
```

关键点：这里抛的是**普通** `VideoSourceException`，不是 `_MissingFile`。`_streamWithRepair` 的修复分支只认 `_MissingFile`，所以**流式路径的 id 修复从来没有执行过**。

### 1.2 从抛异常到 2221

```
_activate 的 catch
    ↓
（改前）_fallbackFullDownload(record, trace, e, generation)
    ↓
sources.resolve(4999) → _resolveWithRepair(activeId = 4999)
    ↓
_resolveOnce(4999)
    ↓
api.stat(4999)  → null（第二次吞掉）
    ↓
api.start(4999) = downloadFile(file_id=4999, offset=0, limit=0, priority=32)
    ↓                                   ← ★ 审计 #1：file=4999 grew=0
TDLib 回 400: FILE_ID_INVALID / FILE NOT FOUND
    ↓
_looksMissing() == true → throw _MissingFile(...)      （video_source.dart:1767）
    ↓
_resolveWithRepair 的 `on _MissingFile` 分支
    ↓
metadata.fetch(chatId, 9431941120) → getMessage → video.file.id = 2221
    ↓                                   ← ★ 2221 在这里出现
onRecordRefreshed(fresh) → _absorbRefreshed → 镜像里的 tile 被换成 2221
    ↓
activeId = 2221 → continue
    ↓
_resolveOnce(2221) → api.start(2221) = downloadFile(2221, limit=0)
    ↓                                   ← ★ 审计 #2：file=2221 grew=24316497
24,316,497 B 全部落盘 → PlaySource.file(path)
    ↓
（改前）noteFinalSource(source.isStreaming ? ... : 'LOCAL_FILE')
    ↓
finalSource=LOCAL_FILE
```

**所以 2221 是消息里当前真实的 `file.id`，4999 是镜像里过期的那个。** 换 id 的动作发生在 `_resolveWithRepair` 的 `_MissingFile` 分支，因为那是唯一会去 `getMessage` 再取 id 的地方。

### 1.3 为什么 `finalSource=LOCAL_FILE` 同时 `localFileExists=false`

`localFileExists` / `localFileSize` 来自决策层那一刻的 `stat`，那是**对 4999** 做的、且**在修复之前**：没有 path、没有 size。而 `finalSource` 来自播放器最后打开的东西，那是**对 2221** 做的、**在 24MB 全部下载之后**。两个字段描述的是不同的文件、不同的时刻——这正是它必须分开记录的原因。

---

## 二、改了哪些文件

| 文件 | 改动 |
|---|---|
| `lib/playback/video_source.dart` | 新增 `statStrict`（拒绝 ≠ 无记录）、`StreamingNotStarted`；`_streamOnce` / `_resolveOnce` 改用 `_statStrict`；`_streamOnce` 遇 `no_file_record` 先抛 `_MissingFile` 走修复；`PlaySource.origin`；两处 `FILE_ID_REMAP` 记录 |
| `lib/playback/source_decision.dart` | 新增 `PlaybackSourceKind.streamingNotStarted`（`code = STREAMING_NOT_STARTED`）；`no_file_record` / `unknown_size` 不再返回 `fullDownload`；`decideAfterTransportFailure` 的死路一律 `stop` |
| `lib/playback/download_audit.dart` | `forbidWholeFile` / `allowWholeFile`（per-play，不受 `reset` 影响）、`noteBlockedWholeFile`、`AUTO_FULL_DOWNLOAD_BLOCKED` 行 |
| `lib/playback/streaming_diagnostics.dart` | `FILE_ID_RESOLVE` / `FILE_ID_REMAP`、`FINAL_SOURCE_INCONSISTENT`、`AUTO_FULL_DOWNLOAD_BLOCKED=n`、`forbidWholeFile` / `allowWholeFile` |
| `lib/ui/feed_controller.dart` | 删除 `_fallbackFullDownload`；失败路径改为「重测磁盘 → 试 V1 → 报错」；`_activate` 每次开一次整文件门；`noteFinalSource(source.origin)` |
| `lib/playback/stream_proxy.dart` | stall 消息带窗口读写（`窗口 from+limit 已尽=`），V1 卡死可读性 |

**16MB 首窗口、`StreamWindow`、V2 `ResourceLoader`、V1 `StreamProxyServer` 的核心逻辑一行未动。**

---

## 三、现在的行为

### 3.1 正常路径

```
点击
 ↓
_streamOnce(4999) → _statStrict(4999) → TDLib 拒绝
 ↓
throw _MissingFile            ← 不再走 "no_file_record → fullDownload"
 ↓
_streamWithRepair → metadata.fetch(messageId) → 2221
 ↓
FILE_ID_REMAP old=4999 new=2221 reason=tabled_id_rejected_re_read_message
 ↓
_streamOnce(2221) → stat 有记录、有大小
 ↓
candidate=true → RESOURCE_LOADER（或 V1）
 ↓
首窗口 16MB，caller=PLAYER
```

修复发生在**流式路径内部**，`v2Attempted=true`，且 **`downloadFile(4999)` 一次都不会发**——改前它会白扔一发（`#1 grew=0`）。

### 3.2 修不回来时

```
_streamOnce(4999) → TDLib 拒绝 → 修复 → 仍无记录 / 无大小
 ↓
playbackDecision=STREAMING_NOT_STARTED  reason=no_file_record
 ↓
throw StreamingNotStarted        ← 不是 fallback，没有任何下载动作
 ↓
控制台：播放失败（明确错误）
```

---

## 四、硬保护

`TdFileTransferApi.start()` 第一段：

```dart
if (!audit.wholeFileAllowed) {
  audit.noteBlockedWholeFile(fileId: fileId, caller: caller, cause: cause);
  throw VideoSourceException('AUTO_FULL_DOWNLOAD_BLOCKED（…）');
}
```

- 门在 `_activate` 开头打开一次（`_diagnostics.allowWholeFile()`）
- 一进入流式传输（`_streamOnce` 做出 streaming 决策之后）立刻关闭
- `reset()` **不**重开门——`beginPlay` 每次 `_streamOnce` 重试都会调 `reset()`，如果在那里开门，一次重试就会把保护抹掉
- 唯一让门一直开着的是「用户在设置里关掉流式」——那是指令，不是 fallback

现在播放路径**没有任何** `FULL_DOWNLOAD`：

- `no_file_record` → `STREAMING_NOT_STARTED`
- V2/V1 都失败 → 报错
- 播放中解码失败 → 重新 stat，够大就用本地文件，否则报错
- 传输阶梯的终点是错误页

---

## 五、诊断新增

设备上现在会看到：

```
FILE_ID_RESOLVE: clickedFileId=4999 recordFileId=4999 resolvedFileId=4999 tdlibFileId=0 fileUniqueId=- messageId=9431941120 generation=3
FILE_ID_REMAP old=4999 new=2221 reason=tabled_id_rejected_re_read_message
AUTO_FULL_DOWNLOAD_BLOCKED=0 wholeFileAllowed=false revokedBy=streaming:V2
DOWNLOAD_AUDIT calls=1 unbounded=0
LARGEST_DOWNLOAD caller=PLAYER file=2221 offset=0 limit=16777216 grew=...
```

`tdlibFileId=0` + `FILE_ID_REMAP` 这两行合起来，就是这次问题的指纹：**记录里的 id 和 TDLib 认的 id 不是同一个**。

---

## 六、自动化

```
flutter analyze  →  No issues found!
flutter test     →  932 passed / 1 skipped        （改前 923）
```

本轮新增 **9 例**：

- `video_source_test`（+2）
  - `a stale file id is repaired from the message before anything is downloaded`：`stat` 顺序必须是 `[4999, 2221]`，`api.started` 必须为空，`FILE_ID_REMAP` 必须记下 `old=4999 new=2221`
  - `a stale file id with no message to re-read stops as STREAMING_NOT_STARTED`：抛 `StreamingNotStarted`、零下载、报告里不得出现 `playbackDecision=FULL_DOWNLOAD`
- `source_decision_test`（改 3，语义反转）
  - `no TDLib record is STREAMING_NOT_STARTED, not a download`
  - `an unknown size is STREAMING_NOT_STARTED, not a download`
  - `force never invents a stream out of an unknown size`
  - `V1 failing on a short file stops the play`（原 `…sends a short file to the full download`）
- `download_audit_test`（+3）：门只在控制器打开、`reset` 不重开、被拒请求带 caller 落进 `AUTO_FULL_DOWNLOAD_BLOCKED`
- `feed_controller_test`（+3）：`no_file_record` 不进整文件、流被拒后 `startCalls == 0`、stall 后 `startCalls == 0`
- `streaming_diagnostics_test`（+1）：`AUTO_FULL_DOWNLOAD_BLOCKED` / `wholeFileAllowed` / `revokedBy` 三行

---

## 七、CI

| 项 | 值 |
|---|---|
| run | [40630084144](https://github.com/1585365426/tg-media-probe/actions/runs/40630084144) |
| 提交 | `1c589f0` · `rebuild-step3` |
| 结果 | ✓ build-ipa 9m16s |
| CI 内 analyze | `No issues found! (ran in 13.2s)` |
| 产物 | 20 038 433 B |
| SHA256 | `120ee8c9085067cd178dea404d0190c8d66e853b4e6e71f5dfe254198e61f840` |

桌面包：`TGMediaProbe-step10-norecord.ipa`（未签名）+ 同名 `.sha256`，复算一致。

---

## 八、真机待验证（当前未测）

用 `file=4999 / msg=9431941120 / size=24316497` 重测，清局部缓存后点开。

**情况 A（id 可修复，预期）**

```
candidate=true
playbackDecision=RESOURCE_LOADER
v2Attempted=true   v1Attempted=false
playerSourceType=RESOURCE_LOADER
FULL_DOWNLOAD=0
UNBOUNDED=0
DOWNLOAD_GROWTH PLAYER:16777216
FILE_ID_REMAP old=4999 new=2221 ...
finalSource=RESOURCE_LOADER
```

**情况 B（id 修不回来，也可接受）**

```
candidate=false  candidateReason=no_file_record
playbackDecision=STREAMING_NOT_STARTED  playbackDecisionReason=no_file_record
v2Attempted=false  v1Attempted=false
FULL_DOWNLOAD=0  UNBOUNDED=0
finalSource=-
```

**情况 C（不接受）**

```
no_file_record → FULL_DOWNLOAD → WHOLE_FILE
localFileExists=false / localFileSize=-1 → finalSource=LOCAL_FILE
```

这份日志出来之前，任何"已修复"的说法都不成立。

---

## 九、没做的事

- 没改 16MB 首窗口，没改 V2/V1 核心，没扩大窗口，没删 transport。
- 没新增功能。
- 没做真机测试（第八节全部空着）。
- V1 的 stall（上一轮记录的第二个问题）只加了窗口读数到报错文本，没有改逻辑——按你的要求，这一轮不动它。
