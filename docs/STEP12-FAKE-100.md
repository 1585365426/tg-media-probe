# STEP12：修复「假 100%」与「不完整文件进入 LOCAL_FILE」

对应真机现象（iPhone 11 Pro，1.19 GB / 809 MB 视频）：

- 现象 A：视频刚点进去就显示 `FULL 1.19 GB / 1.19 GB · 100.0%`，实际远未下载完。
- 现象 B：809 MB 视频只落盘 989 KB，却显示 `SRC LOCAL_FILE`，随后「读取失败 / 此视频无法解码」。
- 现象 C：上滑切换后连续多个视频读取失败。

## 一、根因

### 假 100%（现象 A）

`streaming_diagnostics.dart` 的 `noteCompleted()` 把 TDLib 的声明直接抄进字节计数：

```dart
_isDownloadingCompleted = true;
_downloadedBytes = _totalBytes;   // 声明被写成了测量
```

`noteCompleted` 由 `video_source.dart` 的完成监听在 TDLib `is_downloading_completed=true` 时调用——它从头到尾没有 stat 过一次磁盘。徽标与百分比读的就是这些字段，于是「TDLib 说了完成」被渲染成 `1.19 GB / 1.19 GB · 100.0%`。

已排除的可能：不是上个视频的状态复用（`beginPlay` 每次重置 `_totalBytes/_downloadedBytes/_isDownloadingCompleted`，且 `SRC` 在重置之后才写入）；ResourceLoader 没有自己的字节计数器，不参与这个数字。

### 不完整文件进入 LOCAL_FILE（现象 B）

`video_source.dart` 的 `_factsFor` 用 `state.size`（TDLib 声明的总大小）作为磁盘字节的起点：一旦 stat 失败或没跑，声明值就顶替了实测值，`diskCoversExpected` 恒真，989 KB 的文件被当成完整 `LOCAL_FILE` 交给播放器，解码器读到空洞即「无法解码」。

### 上滑后连续失败（现象 C）

逐层检查了 FeedController / Player 生命周期 / ResourceLoader session / fileId 切换 / CLICKED-ACTIVE-PLAYER 一致性诊断，**没有发现新的状态污染根因**：既有的生命周期守卫与一致性诊断在位（`feed_controller_test.dart` 的 `tapping A then B ends on B and A cannot touch it` 等用例通过）。现象 C 的直接来源是现象 B——不完整文件被当作 LOCAL_FILE 后解码失败，表现为「切换后接连失败」。修掉现象 B 后 C 的这条路径关闭。

## 二、修改内容

原则：最小修改。三个文件改逻辑，两个文件改 UI 判据，测试替身补语义。V2 窗口机制、TDLib 核心、V1、UI 结构均未动。

### lib/playback/source_decision.dart

- 新增 `countCoversExpected`：`downloadOffset == 0 && downloadedBytes >= expectedBytes`。`downloaded_size` 是 TDLib 唯一的**计数**（其余是声明），完整性必须有它。
- `isPlayableFromDisk` 现在要求四样同时成立：真实路径 + 文件存在 + **长度到顶**（`diskCoversExpected`）+ **计数到顶**（`countCoversExpected`）。809 MB @ 989 KB 在计数一关就被拦下。

### lib/playback/video_source.dart

- `_factsFor`：`diskSize` 从 -1（未知）起步，只信实测。stat 失败 = 未知 = 永不完整，声明值不再顶替测量值。
- 磁盘测量抽为可注入的 `diskSizeOf`（设备上是 `File.length()`），与既有 `fileExists` 注入并列。
- `_LiveFileWatch` 不再凭 `isCompleted` 声明把 `0..expected-1` 标为可读范围；`refresh()` 只在实测长度与计数都到顶时才把文件标为完整。

### lib/playback/streaming_diagnostics.dart

- 新增 `_diskBytes`（实测落盘长度，-1 = 未测量）与 `diskCoversTotal`。
- `noteCompleted(totalBytes, diskBytes, generation)`：磁盘实测长度到不了总数时**拒绝完成声明**，记 `completion refused: claimed_complete disk=X total=Y`，进度数字停在真实位置；到顶才允许 `_isDownloadingCompleted=true`。原 `_downloadedBytes = _totalBytes` 一行删除。
- `updateTransfer`：`completed` 只作为传输状态记录，不再设置完成标志、不再抄写字节。
- `beginPlay` 重置 `_diskBytes`；决策落点记录 `_decisionDiskCovers`。
- 诊断行：`V2_BYTES diskDownloaded=<实测>/<总数>`、`disk=<n> B FULL|PARTIAL`、`CLICKED/ACTIVE/PLAYER` 一致性行保留；`diskBytes`/`diskCoversTotal` 进导出 JSON。

### lib/ui/streaming_overlay.dart

- FULL 徽标判据从 `isDownloadingCompleted || downloadedBytes >= totalBytes` 改为 **`isDownloadingCompleted && diskCoversTotal`**——声明与测量缺一不可。未到顶时按真实进度显示 `STREAM?/STREAM n KB / 809 MB 0.1%`。

### 测试（5 个文件）

- 替身按 TDLib 真实语义补齐：完整记录同时带长度与计数（`preload_count_test` / `feed_controller_test` / `streaming_playback_test`）。
- `streaming_overlay_test`：FULL 用例改为走 `noteCompleted(totalBytes, diskBytes)`。
- 原有「假完成声明被拒绝」「不完整文件不进 LOCAL_FILE」断言全部保留并通过。

## 三、未修改的模块

- V1 未重新启用（V2-only 保持，`StreamingV2.v2Only=true` 未动）。
- TDLib 核心下载逻辑、登录、频道同步、数据库结构未动。
- 16 MB 首窗口与窗口推进未动；整文件下载硬保护（`AUTO_FULL_DOWNLOAD_BLOCKED`）未动。
- 视频列表 UI、密码、主题未动。

## 四、自动化结果

- `flutter analyze`：No issues found。
- `flutter test`：**938 passed / 1 skipped**。
- CI（ios-probe，未签名 IPA）：run 40639644289。

## 五、真机验收（未测试——本机无法真机验证）

必须用一个**从未完整缓存**的大视频（500 MB～1.5 GB）：

1. 首次点击：进度显示真实落盘字节（如 `12 MB / 809 MB · 1.5%`），**不允许** `809/809 · 100%`；只有 TDLib 确认完成且磁盘实测到顶才允许 FULL。
2. `SRC=RESOURCE_LOADER`（downloaded < total 时禁止 LOCAL_FILE）。
3. `V2_BYTES dataRequests>0 responds>0 toPlayer>0`，`downloadedAtFirstPlayback < total`。
4. A→B→C→D→E 连续上滑 5 个视频均正常。
5. 若仍失败：不要继续改码，先导出诊断，重点看 `diskDownloaded=`、`disk=... FULL|PARTIAL`、`completion refused`、`CLICKED/ACTIVE/PLAYER` 三行是否一致。
