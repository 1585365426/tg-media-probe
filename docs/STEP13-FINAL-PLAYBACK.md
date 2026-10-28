# STEP13（最终修正版）：播放链路收敛

按最终架构执行：**先代码审计 + CI 全绿，只安排最后一次代表性真机测试**。

## 一、审计结论（改码前完成）

全项目搜索 `api.start(` / `startRange(` / `start(` / WHOLE_FILE：

- `api.start(`（即 `downloadFile(limit:0)` 的 WHOLE_FILE 请求）**全项目仅一处**：`video_source.dart` 的「从未有流」整文件路径，受 `DownloadAudit.wholeFileAllowed` 门与 `AUTO_FULL_DOWNLOAD_BLOCKED` 硬保护约束。
- PLAYER 正常路径全部走 `startRange(offset, limit)`；`startRange` 对 `limit<=0` 直接抛异常——窗口调用点不可能静默变成无界下载。
- fileId 修复已经按 `messageId` 重读消息（`metadata.fetch`），无任何 `4999→2221` 式硬编码。
- LOCAL_FILE 严格判定（STEP12）已在位：路径存在 + 实测长度到顶 + 字节计数到顶，三者缺一不可。

**缺口**：没有统一的 `resolvePlayableFile` 入口与 `PlaybackSession`；流失败后直接 STOP（没有任务书要求的「re-stat → 一次 FULL_DOWNLOAD → LOCAL_FILE」末级）；审计徽标叫 `FULL_DOWNLOAD` 不叫 `FULL_DOWNLOAD_FALLBACK`。

## 二、本次修改

### 新增 lib/playback/playback_session.dart

- `PlayableFile`：chatId / messageId / **fileId（解析结果，运行时句柄）** / fileUniqueId / expectedSize / localPath / **localSize（实测）** / **isComplete（实测到顶才算）** / generation。
- `PlaybackSession`：sessionId / chatId / messageId / resolvedFileId / streamingAttempted / **fullDownloadFallbackUsed（session 级）** / finalSource / playerReady。
- `spendFullDownloadFallback()`：一次性。第二次调用返回 false——把「stream 失败→下载→失败→再下载」的无限循环在结构上封死。

### lib/playback/video_source.dart

- 新增 `resolvePlayableFile(chatId, messageId, {hintFileId, generation})`：messageId → 重新获取 Message → 当前 fileId（hint 仅是起点，变化时记 `FILE_ID_REMAP`）→ `statStrict` → 实测磁盘 → `PlayableFile`。
- 新增 `downloadWhole(chatId, messageId, fileId, …)`：显式末级整文件下载（走既有修复循环 + 全部看门狗），完成后**重新 stat 并实测**，`isComplete` 由测量决定。
- WHOLE_FILE 审计徽标：`caller=FULL_DOWNLOAD_FALLBACK`（`DownloadAudit` 的 label，所有审计行自动生效）。

### lib/ui/feed_controller.dart

- 每次 `_activate` 创建新 `PlaybackSession`（旧 play 的预算/标志全部作废）。
- `_resolvePlaySource`：V2 进入即记 `streamingAttempted` / `resolvedFileId`；播放器就绪记 `finalSource` / `playerReady`。
- `_recoverFromStreamFailure` 末级按最终架构重排：
  1. re-stat 完整 → `LOCAL_FILE`；
  2. 有记录且 session 预算未花 → `spendFullDownloadFallback()` → `FULL_DOWNLOAD_FALLBACK` 一次 → 下载完成 re-stat 实测到顶 → `LOCAL_FILE`（origin=FULL_DOWNLOAD）→ AVPlayer；
  3. **无记录不 fallback**（id 未解析成功就发整文件请求 = 设备日志里 4999 白烧一次的重演）→ STOP；
  4. fallback 失败 → STOP（预算已花，无第二次）。

### 未动

V1 未重新启用（仍 V2-only）；16MB 首窗/窗口机制未动；TDLib 核心、登录、同步、UI 未动。

## 三、CI 断言（防回归，机器把关）

- **`PLAYER + WHOLE_FILE = 0`**：完整播放后断言所有 player 窗口 `limit>0`，且 WHOLE_FILE 调用者只可能是 `fullDownload`。
- **fallback 恰好一次**：V2 失败 → 恰好 1 次整文件请求 → 下载完成实测到顶 → phase=ready；V2 失败且整文件被拒 → 恰好 1 次 → error（不再循环）。
- **PlaybackSession 单测**：`spend` 两次返回 false；新 session 预算独立。
- **`resolvePlayableFile` 三条**：4999→2221 经消息重解析（含 REMAP 行断言）；`isCompleted=true` 但实测字节短 → `isComplete=false`；实测到顶 → `isComplete=true`。
- 更新到新语义的旧用例：流失败后「恰好一次」fallback 替代旧的「零次」断言；no_record 用例保持 `startCalls=0`。

## 四、结果

- `flutter analyze`：无问题。
- `flutter test`：**945 passed / 1 skipped**（净增 7 条）。
- commit + CI：见桌面 IPA 与本轮消息。

## 五、最后一次真机测试（唯一安排）

用一个从未完整缓存的大视频（500MB–1.5GB）：

1. 点击 → `SRC=RESOURCE_LOADER`，进度为真实落盘字节，无假 100%；
2. `V2_WINDOW offset=0 limit=16777216`，`V2_BYTES dataRequests>0 toPlayer>0`；
3. （可选）断网/杀 V2 会话制造流失败 → 应看到一次 `FULL_DOWNLOAD_FALLBACK`，完成后正常播放；
4. 上滑 A→E 连续 5 个视频全部正常；
5. 导出诊断核对：`WHOLE_FILE_DOWNLOADS≤1`、`UNBOUNDED` 仅含 `FULL_DOWNLOAD_FALLBACK`、`CLICKED/ACTIVE/PLAYER` 一致、`diskDownloaded` 为实测值。
