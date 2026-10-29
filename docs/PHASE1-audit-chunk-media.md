# 第一阶段：架构与依赖审计

> 目标：判断"采用 Telegram-iOS 风格的分块媒体管线"在当前项目上能否真正落地，以及代价是什么。
> 本阶段只做审计与方案，未修改任何生产代码。
> 日期：2026-10-29 ｜ 分支 `rebuild-step3` ｜ HEAD `9bddda8`

---

## 0. 结论先行

| 问题 | 结论 | 证据等级 |
|---|---|---|
| 仓库里现有 Telegram-iOS / UniversalMediaPlayer 源码吗 | 没有 | 已核实（全仓 grep + 依赖清单） |
| 能把 Telegram 的 `MediaPlayer` 模块抽出来用吗 | **不能**，依赖 TelegramCore/Postbox/mtproto-engine 整条数据层 | 已核实（Bazel BUILD 依赖清单） |
| Telega-iOS 主仓库有可用许可证吗 | **没有 LICENSE 文件**（API 返回 404，顶层目录无此文件） | 已核实（GitHub API） |
| TDLib 能提供分块数据源吗 | **能，但是单区间顺序模型，不是 Telegram 的随机并发块模型** | 已核实（TDLib 源码 `FileManager.cpp`） |
| 那还能不能做成边下边播 | **能**，但不能做成 Telegram 那种任意 seek 秒开 | 推断（需真机实验确认，见 §6.2） |
| Windows 上能编译/跑 iOS 吗 | 编译：只能靠 GitHub Actions macOS runner；模拟器/真机调试：不能 | 已核实（workflow + 平台限制） |

**推荐路线：方案 A′** —— 保留 TDLib 作为唯一数据源，自研原生播放内核（MP4 demux + VideoToolbox + AVSampleBufferDisplayLayer + AVAudioEngine），**不移植 Telegram 源码，第一版不引入 FFmpeg**。

理由见 §3。这条路能实现"文件未下完就出真实画面"，代价是 seek 到未下载区必须重新缓冲。

---

## 1. 当前仓库审计

### 1.1 规模与分层

| 层 | 位置 | 规模 |
|---|---|---|
| Flutter 播放层 | `lib/playback/` | 19 个文件，10,247 行 |
| Flutter UI/控制 | `lib/ui/feed_controller.dart` 等 | 未逐一统计 |
| 原生播放 | `ios/Runner/Streaming/` | 3 个 Swift 文件，983 行 |
| TDLib FFI | `lib/td/` | 8 个文件，1,894 行 |
| 测试 | `test/` | 63 个文件，941 个 `test()` |

`lib/playback` 文件明细（行数降序）：

```
video_source.dart            2552
streaming_diagnostics.dart   2214
stream_proxy.dart            1228
resource_loader.dart          620
download_audit.dart           490
downloader.dart               483
source_decision.dart          397
native_streaming.dart         386
growing_file_reader.dart      361
playback_trace.dart           315
video_player_handle.dart      218
player_slot.dart              208
watch_store.dart              188
playback_failure.dart         159
mp4_probe.dart                118
playback_session.dart          97
playback_lifecycle.dart         87
stream_window.dart              69
media_metadata.dart             57
```

原生侧：

```
TGMediaStreamingPlugin.swift   359   MethodChannel 入口 / 事件转发
TGMediaPlayer.swift            322   video_player 封装
TGMediaResourceLoader.swift    302   AVAssetResourceLoaderDelegate + WAIT 轮询
```

### 1.2 技术栈事实

| 项 | 值 | 来源 |
|---|---|---|
| Flutter 依赖 | `video_player: ^2.9.2`（即系统 AVPlayer） | `pubspec.yaml` |
| TDLib 版本 | `1.8.69-025086e3`（Swiftgram/TDLibFramework 预编译 xcframework） | `scripts/fetch_tdlib.sh` |
| TDLib 集成方式 | 本地 pod `tdlib`，FFI 直调 tdjson | `ios/Podfile` |
| 最低系统 | iOS 15.2 | `ios/Podfile` |
| 桥接 | `MethodChannel` + `EventChannel`（`TGMediaStreamingPlugin`） | 源码 |
| 已用 TDLib 方法 | `setTdlibParameters` `getAuthorizationState` `setAuthenticationPhoneNumber` `checkAuthenticationCode` `checkAuthenticationPassword` `getChats` `getChat` `getChatHistory` `getMessage` `getFile` `downloadFile` `cancelDownloadFile` `logOut` `close` `getMe` | `lib/td/td_requests.dart` |

**没有**：Telegram-iOS 源码、UniversalMediaPlayer、FFmpeg、VideoToolbox 直接调用、AVSampleBufferDisplayLayer、自研 demuxer。

### 1.3 要标记为"旧架构"的模块

| 模块 | 行数 | 现有引用方 |
|---|---|---|
| `resource_loader.dart` | 620 | `app_root.dart` `native_streaming.dart` `video_player_handle.dart` `video_source.dart` |
| `stream_proxy.dart` | 1228 | `video_source.dart` `streaming_diagnostics.dart` |
| `growing_file_reader.dart` | 361 | `video_source.dart` |
| `native_streaming.dart` | 386 | 5 处 |
| `downloader.dart` | 483 | 6 处 |
| `streaming_diagnostics.dart` | 2214 | UI 面板 |
| `download_audit.dart` | 490 | `streaming_diagnostics.dart` |
| `mp4_probe.dart` | 118 | `video_source.dart` `streaming_diagnostics.dart` |
| `ios/Runner/Streaming/*.swift` | 983 | `TGMediaStreamingPlugin` |

这 9 处构成完整的 `GrowingFileReader → ResourceLoader → AVPlayer` 旧链路，按你的要求**本轮不删**，只登记。

---

## 2. 方案 B 评估：直接采用 Telegram-iOS 的播放器

### 2.1 源码位置（已核实）

`UniversalMediaPlayer` **不是** submodule，它在 Telegram-iOS 主仓库里：

- `submodules/MediaPlayer/Sources/`（29 个文件）
- `submodules/MediaPlayer/BUILD`
- `submodules/MediaPlayer/Package.swift`

### 2.2 依赖（`submodules/MediaPlayer/BUILD` 原文）

```python
deps = [
    "//submodules/TelegramCore:TelegramCore",
    "//submodules/Postbox:Postbox",
    "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    "//submodules/AsyncDisplayKit:AsyncDisplayKit",
    "//submodules/Display:Display",
    "//submodules/TelegramAudio:TelegramAudio",
    "//submodules/FFMpegBinding:FFMpegBinding",
    "//submodules/RingBuffer:RingBuffer",
    "//submodules/YuvConversion:YuvConversion",
    "//submodules/Utils/RangeSet:RangeSet",
    "//submodules/TextFormat:TextFormat",
    "//submodules/ManagedFile",
],
```

这 12 个依赖里，前三个是致命的：

- **`TelegramCore`** = Telegram 的消息/媒体/文件领域模型 + 引擎入口
- **`Postbox`** = Telegram 的本地数据库（消息、peer、文件引用）
- **`SwiftSignalKit`** = Telegram 的响应式/异步框架

而 `TelegramCore` 继续向下依赖 `TelegramApi`、`SyncCore`、以及 **`third-party/mtproto-engine`**（`.gitmodules` 里 URL 为 `https://github.com/TelegramMessenger/mtproto-engine.git`）。

### 2.3 `Package.swift` 不能替代

`submodules/MediaPlayer/Package.swift` 存在，但 `exclude` 列表把这 9 个核心文件**排除在 SPM target 之外**：

```
MediaPlayer.swift
MediaPlayerScrubbingNode.swift
MediaPlayerTimeTextNode.swift
MediaPlayerNode.swift
MediaPlayerAudioRenderer.swift
MediaPlayerFramePreview.swift
VideoPlayerProxy.swift
ChunkMediaPlayerV2.swift
ChunkMediaPlayerDirectFetchSourceImpl.swift
```

也就是说：这个 `Package.swift` 是给 TGUIKit（macOS）分支用的裁剪版，**恰好把你要的 `ChunkMediaPlayerV2` 和 `DirectFetchSourceImpl` 排除掉了**。想用它们必须走完整 Bazel 构建。

### 2.4 结论

想要 `ChunkMediaPlayerV2`，就必须把 `TelegramCore + Postbox + mtproto-engine` 一起搬进来。这会产生两个无法接受的问题：

1. **与现有登录态冲突**。`mtproto-engine` 需要自己的 auth key 与自己的登录流程。TDLib 的 auth key 存在其加密数据库中，**不对外导出**。要么让用户重新登录一次（且两套连接并存），要么放弃 TDLib —— 两种都违反你自己定的"保留现有 TDLib 登录和频道数据层"约束。
2. **工程量不可控**。没有可验证的中间里程碑，做到一半无法回退。

**判定：方案 B 否决。** 不是"成本高所以不建议"，是"它与你的第 3 节约束在架构上互斥"。

### 2.5 许可证事实（不可绕过）

| 仓库 / 组件 | 许可证 | 核实方式 |
|---|---|---|
| `TelegramMessenger/Telegram-iOS` | **无 LICENSE 文件** | GitHub API `/license` → 404；顶层目录文件列表无 LICENSE / COPYING / LICENSE.md |
| `TelegramMessenger/mtproto-engine` | GPL-2.0 | GitHub API `/license` |
| `tdlib/td` | BSL-1.0 | GitHub API `/license` |
| FFmpeg（Telegram 内嵌 8.1.2） | LGPL-2.1+（默认，未开 `--enable-gpl`） | 仓库内 `LICENSE.md` 原文 |

README 里写着"publish your code too in order to comply with the licences"，暗示有许可证，但**仓库里确实找不到许可证文本**。在这种状态下复制源码，法律上等于"未授权复制"，风险由你承担。

**但这不阻止借鉴架构。** 架构、模块划分、状态机设计不受版权保护；受保护的是具体代码表达。所以正确做法是：**照着这套架构自己写，不看它的实现代码**。

---

## 3. 方案 A 评估：TDLib 能提供什么数据源

这一节全部基于 TDLib 源码，不是文档推断。仓库：`tdlib/td` master，文件 `td/telegram/files/FileManager.cpp`（5,442 行）与 `FileDownloadManager.cpp`（205 行）。

### 3.1 TDLib 的下载模型：单区间

`FileManager::download()` 里对用户请求的处理（`:3095-3107`）：

```cpp
} else {
    node->set_download_offset(offset);
    node->set_download_limit(limit);
    requests.user_offset_ = offset;
    requests.user_limit_ = limit;
    ...
}
```

`set_download_offset` 直接改写 node 的起点（`:609-620`）。也就是说：

> **同一文件同时只有一个下载区间。发一次 `downloadFile(offset=X)`，起点就变成 X，上一个区间被放弃。**

这不是文档里的说法，是实现里的写法。

`offset`/`limit` 在普通文件上原样下传（`:3326-3335`）：

```cpp
auto download_offset = node->download_offset_;
auto download_limit = node->get_download_limit();
if (file_view.is_encrypted_any()) {      // 只有加密文件才归零
    download_limit += download_offset;
    download_offset = 0;
}
send_closure(file_download_manager_, &FileDownloadManager::download, ..., download_offset, download_limit, priority);
```

**所以非加密文件确实能"只下尾部那 64 KB"**，这是可用的事实，不是猜测。

### 3.2 内部有 part 位图，但对外只报前缀

`FileManager.cpp:1603-1617` 显示 TDLib 内部用位图管理分块：

```cpp
if (partial.part_size_ >= 512 * (1 << 10) || ...) { ... "too big part_size already" }
int new_part_size = 512 * (1 << 10);
...
partial.part_size_ = new_part_size;
```

- part 初始 **512 KB**，成功后翻倍增长
- `local_ready_prefix_size_ = bitmask.get_ready_prefix_size(0, part_size, size_)`（`:605`）
- `partial.ready_size_ = bitmask.get_total_size(part_size, size_)`（`:606`）—— 总就绪字节数（含不连续部分）

对外 `localFile` 字段（官方文档原文）：

> `downloaded_prefix_size`: "If is_downloading_completed is false, then only some prefix of the file starting from download_offset is ready to be read."
> `download_offset`: "Download will be started from this offset. downloaded_prefix_size is calculated from this offset."

**含义**：TDLib 知道"哪些 512KB 的 part 已经到位"，但对外只愿意承诺"从 `download_offset` 起的一段连续前缀"。判断完整性只能看你自己的范围表，不能看 `downloaded_prefix_size == size`。

这正好对应你上一轮踩过的坑（`diskSize == expectedSize` 但中间是空洞）。

### 3.3 请求已完成判定（`:3019-3026`）

```cpp
if (file_object->local_->is_downloading_completed_ ||
    (download_offset <= offset && download_offset + downloaded_size >= offset &&
     ((file_size != 0 && download_offset + downloaded_size == file_size) ||
      download_offset + downloaded_size - offset >= limit))) {
  promise.set_value(...);       // 已覆盖，立即返回
} else {
  promise.set_error(400, "File download has failed or was canceled");
}
```

这是一段**同步语义**实现：请求的区间若已覆盖立即成功，否则等。这对我们有用：可以用来发"请把 [X, X+N) 准备好"的请求，并在到位后收到回调。

### 3.4 能力清单

| 能力 | TDLib 1.8.69 | 影响 |
|---|---|---|
| 从任意 offset 开始下载 | ✅ | 可以跳着下 |
| limit 控制"下够了自动取消" | ✅ 文档原文 "before the download will automatically be canceled" | 可分块推进 |
| 多区间并发 | ❌ 单 `download_id` | 不能像 Telegram 那样同时拉头尾 |
| 读未下载区间的字节 | ❌ `readFilePart` 只读缓存，`count` 不足会报错 | 必须等下载 |
| 读已下载区间的字节 | ✅ 两种：`readFilePart` 或直接按 `file.path` POSIX read（更快） | 播放器读数据的主路径 |
| 换 offset 后旧区间仍可用吗 | ⚠️ 文件里的字节还在，但 TDLib 不再把它算作 prefix | 必须自建范围表 |
| 加密文件 | ⚠️ offset 被强制归零 | 普通视频不受影响 |

### 3.5 数据源结论

**方案 A 可行，但它的能力边界是"单区间顺序流 + 有限跳转"，不是 Telegram 的"随机并发块"。**

具体到播放体验：

| 场景 | 方案 A 的表现 |
|---|---|
| 从头连续播放 | 完全可行，边下边播成立 |
| 向前 seek 到未下载区 | 中断当前下载，从目标点重新开 → 有缓冲，但**不用从头下** |
| 向后 seek 到已下载区 | 直接读本地文件，**零等待** |
| tail-moov（索引在尾部） | 先 `downloadFile(offset=size-64KB, limit=64KB)` 抢 moov，完成后 `downloadFile(offset=0, limit=0)` 从头下。代价 ≈ 64 KB 的时间 |

最后一条是本次审计最有价值的发现：**tail-moov 在 TDLib 上是可解的，代价是一次 64 KB 的往返**，而不是现在这样"顺序爬到文件末尾"。这直接解释了为什么 Turrit 那种方案能秒开而你现在的方案会卡死——不是解码器慢，是取数顺序错了。

---

## 4. 方案 C 简述（不推荐，但要列出）

用 `mtproto-engine`（Telegram 官方开源的 MTProto 实现，GPL-2.0）自建取流层，绕开 TDLib 拿真正的随机块读取。

- 技术上可行：`upload.getFile` 支持任意 offset、最大 1 MB/次、可并发
- 实际代价：重做登录（需要自己的 auth key、自己的 2FA 流程），与现有 TDLib 登录态二选一
- 许可证：GPL-2.0 有传染性，你的整个 App 需以 GPL 发布

**判定：否决。** 除非你愿意为了 seek 体验换掉整个网络层，并且接受 GPL。

---

## 5. 推荐方案 A′：TDLib + 自研播放内核

### 5.1 为什么不引入 FFmpeg（第一版）

Telegram 用 FFmpeg 是因为它要支持 MKV/AVI/TS 等容器。你的场景是 Telegram 私人频道的视频消息，**几乎全是 MP4（H.264 / HEVC）**。

对 MP4，demux 可以自己做，而且比 FFmpeg 更适合流式：

- 需要的信息全在 `moov` 里：`stsd`(编码参数) `stts`(时间戳) `stsc`/`stco`/`stsz`(sample 偏移与大小) `stss`(关键帧)
- 拿到 `moov` 之后，播放器就知道"第 N 个 sample 在文件的哪个字节"，可以**按 sample 精确请求**，不需要顺序读
- 这正好对上 TDLib 的"从 offset 开始下载"能力：**按 sample 边界发请求，块大小天然对齐**

引入 FFmpeg 的代价：
- iOS 静态库构建（arm64 + 模拟器切片），没有官方 iOS 预编译包，`ffmpeg-kit` 已于 2025 年初停止维护
- LGPL-2.1+ 合规：iOS 上静态链接需要提供可重链接的目标文件，动态链接要单独 framework；你自签使用不涉及上架，但仍要在仓库里保留许可声明
- 二进制体积 +15~30 MB

**第一版明确不支持 MKV/WebM**，遇到这类文件回退到"整文件下载后播"（即旧行为），并在 UI 上标注。这是刻意的取舍，不是遗漏。

### 5.2 架构

```
┌──────────────────────────────────────────────────────────────┐
│ Flutter (Dart)                                               │
│   FeedController ── MethodChannel ──▶ MediaPlayerPlugin      │
│   状态模型 / 进度 / 错误码                                       │
└──────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────▼────────────────────────────────┐
│ ChunkMediaPlayer (Swift, 状态机)                               │
│  Idle → Preparing → Buffering → Playing ⇄ Paused → Ended      │
│                  ↘ Seeking ↗          ↘ Failed               │
│  时钟: MediaClock (CMTimebase, 由音频主导)                        │
└───────┬──────────────────┬──────────────────┬────────────────┘
        │                  │                  │
┌───────▼────────┐ ┌───────▼─────────┐ ┌──────▼──────────────┐
│ Mp4Demuxer     │ │ VideoDecoder    │ │ AudioRenderer       │
│ box 解析        │ │ VideoToolbox    │ │ AVAudioEngine       │
│ sample table   │ │ 硬解(HEVC/H264) │ │ AVAudioPlayerNode   │
│ 按需 sample     │ │ 失败→软解/报错   │ │ 输出 PCM → 时钟      │
└───────┬────────┘ └───────┬─────────┘ └──────┬──────────────┘
        │                  │                  │
        │        ┌─────────▼──────────┐       │
        │        │ FramePresenter     │       │
        │        │ AVSampleBuffer     │       │
        │        │ DisplayLayer       │       │
        │        └────────────────────┘       │
        │                                    │
┌───────▼────────────────────────────────────▼────────────────┐
│ ChunkDataSource (Swift)                                     │
│  RangeSet 覆盖表(512KB 对齐)  generation 隔离  取消/重试        │
│  read(offset,len) → .data / .wait / .eof / .failed           │
└───────────────────────┬─────────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────────┐
│ TDLib (tdjson FFI, 唯一数据源)                                │
│  downloadFile(offset,limit) 逐段推进                          │
│  file.path 直接 POSIX read 已覆盖区间                          │
│  updateFile 事件 → 覆盖表回写                                  │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 与旧架构的差别（为什么这次不会重蹈覆辙）

| 维度 | 旧 B+ | A′ |
|---|---|---|
| 谁管播放 | 系统 `AVPlayer` | 自己 |
| 谁管数据 | `AVAssetResourceLoader` 被动回调 | 自己按 sample 主动请求 |
| "还没数据"怎么表达 | 抛 error 给 AVPlayer（上一轮卡死的根源） | 内部状态 `wait`，解码器线程阻塞等待，不产生错误 |
| 完整性判定 | `diskSize == expectedSize`（会被空洞骗） | 自己的 RangeSet |
| 跳转 | 只能靠 AVPlayer 猜 | 按 sample table 精确重定位 |

核心变化：**"还没数据"从"错误"变成"等待"**。这是上一轮所有卡死的共同根因，换成自研播放器后这个语义问题从设计上消失，因为没人逼你把 WAIT 翻译成 error。

### 5.4 模块清单

**新建（原生，约 2,000–3,000 行 Swift）**

| 文件 | 职责 |
|---|---|
| `ios/Runner/Media/ChunkDataSource.swift` | 分块读取、RangeSet、generation、取消、重试、TDLib 交互 |
| `ios/Runner/Media/ChunkPartStore.swift` | part 状态机（未请求/请求中/就绪/失败/取消）与缓存上限 |
| `ios/Runner/Media/Mp4Demuxer.swift` | box 解析、moov 定位、sample table、按 sample 出 NALU/帧 |
| `ios/Runner/Media/VideoToolboxDecoder.swift` | 硬解能力检测、会话生命周期、H.264/HEVC、错误重建 |
| `ios/Runner/Media/FramePresenter.swift` | `AVSampleBufferDisplayLayer`、旋转、宽高比、低内存处理 |
| `ios/Runner/Media/AudioRenderer.swift` | `AVAudioEngine` + `AVAudioPlayerNode`、PCM 输出 |
| `ios/Runner/Media/MediaClock.swift` | `CMTimebase` 主导时钟、A/V 同步、暂停/seek 时间戳重建 |
| `ios/Runner/Media/ChunkMediaPlayer.swift` | 状态机、调度、事件出口 |
| `ios/Runner/Media/MediaPlayerPlugin.swift` | MethodChannel / EventChannel 桥 |
| `lib/playback2/media_player_client.dart` | Dart 侧通道客户端 + 状态模型 |

**修改**

- `lib/ui/feed_controller.dart`：播放入口换成新客户端
- `lib/app/app_root.dart`：注册新插件，移除旧 ResourceLoader 装配
- `pubspec.yaml`：去掉 `video_player`（新播放器不走它）
- `ios/Runner/AppDelegate.swift`：注册新插件

**废弃（新播放器验收通过后再删）**

- Dart：`resource_loader.dart` `stream_proxy.dart` `growing_file_reader.dart` `native_streaming.dart` `downloader.dart` `streaming_diagnostics.dart` `download_audit.dart` `source_decision.dart` `stream_window.dart` `video_player_handle.dart`
- Swift：`ios/Runner/Streaming/` 三个文件
- 测试：13 个相关测试文件中的旧链路部分

**保留**

- `lib/td/*`（登录、频道、消息、fileId remap）
- `lib/ui/*` 除播放控制外全部
- `watch_store.dart` `media_metadata.dart` `playback_trace.dart`（trace 概念可复用）
- `mp4_probe.dart` 的 box 解析思路迁到 `Mp4Demuxer`

---

## 6. 技术风险与验证办法

### 6.1 风险表

| # | 风险 | 等级 | 验证办法 |
|---|---|---|---|
| 1 | TDLib 换 offset 时下载任务重建开销大，seek 体验差 | 高 | 探针实验 E1（§6.2），量测重建耗时 |
| 2 | 自研 MP4 demux 处理不了 fragmented MP4 / edit list / B 帧重排 | 高 | 用 §6.3 样本矩阵逐个解，断言 sample 数、关键帧、时长 |
| 3 | HEVC 的 `hvcC` 参数集构造错误 → 黑屏 | 中 | 用 HEVC 样本断言首帧像素非全黑 |
| 4 | A/V 同步漂移 | 中 | 10 分钟连续播放，量测音视频时间戳差 |
| 5 | 音频不输出（只出画面就宣称"播放器完成"） | 中 | 断言 `AVAudioPlayerNode` 有非零 PCM 输出 |
| 6 | 无法在 Windows 调试，每轮只能靠 CI + 真机日志 | 高 | 设计足够详细的探针日志（沿用现有 trace 思路） |
| 7 | 参考实现无许可证，不能复制代码 | 中 | 只照架构写，代码评审时确认无逐行相似 |

### 6.2 必须先做的探针实验（E1–E4）

这四个实验决定方案 A′ 是否成立，**建议在原型第一周完成**，用现有 App 加一个隐藏调试页即可，不需要重写播放器：

| 编号 | 实验 | 量测 | 判定标准 |
|---|---|---|---|
| E1 | 同一文件连续 `downloadFile(offset=0,limit=1MB)` → `(offset=1MB,limit=1MB)` → … 共 5 次 | 每次完成耗时、`updateFile` 事件序列、`download_offset` 变化 | 单块耗时 < 1.5 × 理论网络时间即通过 |
| E2 | tail-moov 文件：`downloadFile(offset=size-64KB,limit=64KB)` | moov 落地耗时、之后 `downloadFile(offset=0,limit=0)` 是否正常接续 | 尾部 64 KB 用时 < 2 s 且不破坏后续从头下载 |
| E3 | seek 模拟：正在顺序下载时插入 `downloadFile(offset=远端点,limit=1MB)` | 旧区间是否保留、新起点是否生效、`downloaded_prefix_size` 语义 | 明确记录行为，作为 RangeSet 设计依据 |
| E4 | 直接读已覆盖区间：`file.path` POSIX read vs `readFilePart` | 吞吐、延迟 | 选快的那条 |

E1/E2 是硬门槛。E1 不过（单块开销过大），方案 A′ 的 seek 体验就没有下限，需要退回到"整文件下载 + 顺序播"。

### 6.3 测试样本矩阵（第三阶段用）

| 样本 | 用途 |
|---|---|
| 23 MB / H.264 / faststart | 基础通路 |
| 152 MB / H.264 / faststart | 中等缓冲 |
| 593 MB / HEVC / faststart | 大文件 + 硬解 |
| ~1 GB / HEVC / 任意 | 上限压测 |
| 任意大小 / moov 在尾部 | 尾部索引路径（E2 配套） |
| 有音轨 / 无音轨 | 音频分支 |
| 视频消息（圆形，短时长） | Telegram 特有点位 |

### 6.4 环境事实（必须说清）

| 能力 | Windows 本机 | GitHub Actions `macos-26` | 需要 macOS + Xcode 真机 |
|---|---|---|---|
| Dart 分析/单测 | ✅ | ✅ | — |
| Swift 编译 | ❌ | ✅（`flutter build ios --release --no-codesign`，现有 workflow 已跑通） | — |
| iOS 模拟器运行 | ❌ | ❌（CI 无 GUI 交互） | ✅ |
| 真机安装运行 | ❌ | ❌ | 或走自签工具（你现在用的 eSign 路线） |
| 真机日志采集 | ❌ | ❌ | ✅ |

**诚实结论**：本机能验证的只有 Dart 层逻辑；Swift 层只能验证"编译通过"；播放是否真的出画面，只有真机能回答。所以每轮改动必须先在 Dart 层把状态机和范围表测透，再一次性上真机，避免反复装包。

---

## 7. 依赖与许可证清单（拟）

| 依赖 | 版本 | 许可证 | 用途 | 备注 |
|---|---|---|---|---|
| TDLib | 1.8.69-025086e3 | BSL-1.0 | 唯一数据源 | 已有 |
| Flutter | 现有 | BSD-3 | UI | 已有 |
| VideoToolbox | 系统 | — | 硬解 | iOS 8+ |
| AVFoundation | 系统 | — | 渲染/音频 | iOS 8+ |
| FFmpeg | 8.1.2（可选） | LGPL-2.1+ | MKV/WebM（第二版起） | 需自建静态库 + 合规声明 |
| Telegram-iOS 源码 | — | **无许可证** | **不使用** | 只借鉴架构 |

---

## 8. 需要你确认的三个决策

在开始第二阶段原型前，这三个问题必须有明确答案，否则原型方向会错：

**D1. seek 体验的底线是什么？**
方案 A′ 里，seek 到未下载区必然要缓冲（可能 1–5 秒，取决于网络）。你能接受吗？
- 接受 → 走 A′
- 不接受，必须任意位置秒开 → 只能走方案 C（换网络层 + GPL），成本数量级上升

**D2. 是否接受第一版不支持 MKV/WebM？**
- 接受 → 第一版不引 FFmpeg，体积和构建风险大幅下降
- 不接受 → 第一版就要集成 FFmpeg，工期加 1–2 周且 CI 构建时间显著变长

**D3. 旧链路什么时候删？**
建议新播放器在 3 个样本上验收通过后再删。你希望：
- 立刻删（干净，但失去回滚点）
- 验收后删（推荐）
- 长期并存（不推荐，会回到"两套争抢"的老问题）

---

## 9. 本阶段状态

| 项 | 状态 |
|---|---|
| 代码改动 | 无（只新增本文档） |
| 自动化测试 | 未运行（本阶段不涉及代码） |
| 真机验证 | 未进行 |
| 结论可信度 | §1–§5 基于实测源码/仓库/API，可复核；§6.2 的 E1–E4 全部为**待做实验**，不是结论 |

**下一步等你确认 §8 的三个决策，再进入第二阶段（独立原生原型）。**
