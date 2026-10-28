# 首个真机样本：卡死原因分析

- 样本：`5600848aa8ab1b3e2a618227a73f4c6f.mp4`
- 大小：3,748,018 B（3.57 MiB）
- sha256 前缀：`3a6eb14d53e557bdf75b1349a39d3b52`
- 分析工具：`tools/mp4_layout.py` + 深度 box 解析（本轮新增，已用合成样本验证过）

## 一、文件结构（实测）

| 项 | 值 |
|---|---|
| 顶层 box | `ftyp`(0-28) → **`moov`(28-63,336)** → `mdat`(63,336-3,748,018) |
| 布局 | **FASTSTART**（moov 在 mdat 之前） |
| moov 大小 | 63,308 B = 文件的 **1.7%** |
| 时长 | 102.27 s（timescale 44100） |
| 视频编码 | **`hvc1`（HEVC/H.265）**，592×1280 竖屏 |
| hvcC | profile_idc=1(Main)、level_idc=150(Level 5.0)、8-bit、VPS/SPS/PPS 各 1 个齐全 |
| 色彩 | `colr` = nclx |
| 视频样本 | 2,973 帧，34 个关键帧（每 90 帧 ≈ 3 s），首帧 17,057 B |
| 音频编码 | `mp4a`，44,100 Hz，4,404 个样本 |
| 分片 | 无 `moof`（不是 fMP4/CMAF） |
| 视频首 chunk | 63,700（紧贴 mdat 开头） |

**结论：这不是 tail-moov 文件。** 我原来的第一假设（索引在尾部 → 顺序下载永远等不到）被数据否定了。

## 二、那为什么会卡死

即使是 faststart，**AVPlayer 建 track 也必须先拿到完整的 63,308 字节 moov**。启动瞬间：

1. AVPlayer 发起 `bytes=0-` 请求（越过 moov 到文件尾，共 3.75 MB）；
2. ResourceLoader 的 `ResourceSupply.read(0)` 看到 `safeWatermark = min(TDLib reach, stat)`；
3. TDLib 是 `downloadFile(offset:0, limit:0)` 顺序下载，此刻水位还在 0~几 KB；
4. 水位 < 63,336 → **WAIT**（正确行为）；
5. native 侧每 0.1 s 轮询一次；
6. **旧代码**：Dart 侧 10 s 后返回 `WAIT_TIMEOUT`，Swift 的 pump 把任何 `errorCode` 都当终止 → `finishLoading(with: NSError)`；
7. AVPlayer 收到错误，asset 无法加载 → **黑屏、无声、一直转圈 = 用户说的「卡死」**。

也就是说：**跟 moov 在不在头部无关，只要那 63 KB 在 10 秒内没下完，旧代码必然把请求判死。** 网络稍慢（TG 服务器 + 代理）就稳定触发。

## 三、本轮修复（commit `c07a989`，CI run 40709969739 success）

| 层 | 改动 |
|---|---|
| Dart `resource_loader.dart` | `SupplyReading.downloading` 改为 `reader.isDownloading`（真实下载状态），不再用 `!timedOut` |
| Dart `growing_file_reader.dart` | 新增 `isDownloading`；`TdProgressSource.tdlibDownloading` |
| Dart `video_source.dart` | `_LiveProgressBridge` 改为问 `downloader.isRunning(fileId)`，而不是问文件记录（记录在下载死掉后仍是 "canBeDownloaded"） |
| Swift `TGMediaResourceLoader.swift` | `WAIT_TIMEOUT` + `downloading == true` → 发 `waitTimeoutStillWaiting` 事件并**继续轮询**；只有「没有东西在写字节」或其它错误码才 `finishLoading(error)` |
| 静态门槛 | 第 9 条：native 必须在该分支 `continue` 且不得 `finishLoading`；Dart 不得再把 `downloading` 写成 `!timedOut` |

`flutter analyze` 0 issue；`flutter test` 941 passed / 1 skipped。

## 四、仍未排除的两点

1. **音频轨样本只有 4 字节/帧**（4,404 个样本合计约 17.6 KB / 102 s ≈ 1.4 kbps）。这不像正常 AAC。若播放起来「有画面没声音」或音频轨让 AVPlayer 拒绝，需要另查这个文件的音频构造。
2. **每 0.1 s 一次 MethodChannel IPC**（`TGMediaResourceLoader.pollSeconds`）。3 个并发请求 ≈ 30 次/秒跨平台调用。若换版后仍是「界面卡住但能返回」，优先把这个节奏放宽到 0.2~0.25 s，或改成 Dart 侧 growth 事件推送。

## 五、验证方式

装 `TGMediaProbe-step6-waitfix.ipa`，播这个 3.57 MB 视频：

- 期望：**静止 1~3 秒后起播**（等 63 KB moov 落地），而不是黑屏不变；
- 若仍是黑屏：看日志里是否出现 `waitTimeoutStillWaiting`（说明在正确等待）还是直接 `supplyError`（说明下载已死，属 Downloader 层问题）；
- 若起播了但卡顿：查第四节第 2 点（IPC 频次）。
