# TG Media「边下边播 V1」报告

- 分支：`rebuild-step3`
- 边下边播实现 commit：`d77d05f`（feat(step6): play-while-downloading via a local HTTP range proxy (V1)）
- 最新交付 commit：`d322f41`（图片排除，叠加在同一分支上，桌面 IPA 已同时包含两者）
- CI（边下边播）：run `40442531521`，success
- CI（最新，含图片排除）：run `40449026529`，success

---

## 一、目标

改前链路：TDLib 完整下载 → 等 `is_downloading_completed` → 本地完整文件 → AVPlayer 播放。大视频必须 0%→100% 才能看。

改后链路：

```
Telegram → TDLib 持续下载 → 本地 Range Proxy → HTTP 206 → AVPlayer
                                ↑
                  已下载字节即时返回，缺口阻塞等待（有界）
                  后台下载直到 isCompleted → 形成完整缓存
```

核心契约：**不再要求整个视频下载完成才能播放**。

## 二、调查结论（改前）

| 问题 | 结论（代码证据） |
| --- | --- |
| 哪里要求 `is_downloading_completed` | 旧 `video_source.dart:439-445`：updateFile 只有 `state.isCompleted` 才完成等待；`resolve()` 返回契约 = 完整文件路径 |
| 文件如何写盘 | TDLib 自写文件池（`Library/Caches/tgmedia/tdlib_files`），`local.path` 下载中已含 `downloaded_size` 字节；Dart 侧不写文件 |
| 能否把下载中文件直接给 AVPlayer | 不能：增长中的 file:// 会被按大小快照读取，越过末尾即 EOF/解码错误 → 必须经本地 HTTP Range Proxy |
| TDLib 范围能力 | `downloadFile(offset/limit/priority)` wire 层已支持；`updateFile` 持续给出 expected/downloaded/path/completed |
| 现有 HTTP/RANGE 层 | 无。新写 `dart:io HttpServer`，**零新增第三方依赖**，**未更换播放器**（video_player 原生支持 network URL） |

## 三、实现（模块与文件）

### 1. `lib/playback/stream_proxy.dart`（新增，本地 Range 代理）
- 仅绑定 `127.0.0.1` 随机端口，URL 携带每次播放的 32 位随机 token；未知路径直接 403。Telegram 云端 URL 永远不给 AVPlayer。
- `Range: bytes=a-b` → 从本地已下载字节立即回 206（`Content-Range: bytes a-b/total`）；缺口阻塞等待 updateFile 推进：
  - 有字节增长 → 继续等（**15 秒只是 stall 诊断阈值，不是失败条件**）；
  - `stallTimeout`（20s，生产值）无增长 → 断开连接，不给半截数据；
  - `maxWait`（90s）任务上限 → 显式错误，调用方 fallback。
- `HEAD` 探测、`bytes=a-`、`bytes=-suffix`（moov 在尾探测）均处理；total 已知，不伪造无长度流。
- 启动缓冲门（startupBuffer）：首个请求等待 `min(startupBuffer, 全量)` 字节就绪才开始喂数据；默认 **2 MB**（参数化，不写死在流程里），小视频自动取全量。

### 2. `lib/playback/video_source.dart`（新增 `resolveStream`）
三种路径按数据选择，不按希望：

| 情况 | 判定 | 行为 |
| --- | --- | --- |
| A 完整缓存 | `isCompleted && size≥expected && 文件存在` | `PlaySource.file(path)`，直接本地播放，不经 proxy |
| B 未完成 | 有 expectedSize | `downloadFile(limit:0)` 主下载照旧 → 等 startupBuffer → `PlaySource.stream(http://127.0.0.1/..., localPath)`；后台下载继续到完成 |
| C 流式不可用 | 大小未知 / 无本地路径 / proxy 起不来 / initialize 超时 | 显式异常 → 调用方**静默 fallback** 走原完整下载 `resolve()`，用户无感 |

- `_LiveFileWatch`：桥接同一 `updateFile` 流给 proxy（available/expected/complete/path）。
- `File not found` 修复循环与 `_inflight` 去重**与 `resolve()` 共享**：fileId 失效仍走 getMessage 重取 + 有限重试；同一 fileId 不重复 `downloadFile`。
- 下载完成后续（fire-and-forget）记录 `fileCompleted` 阶段。

### 3. `lib/playback/video_player_handle.dart`
- `http` 前缀源走 `VideoPlayerController.networkUrl`；本地文件仍 `VideoPlayerController.file`。
- 仅流式源加 **12 秒 initialize 超时**：moov 在尾的 MP4 会让 AVPlayer 请求远超当前下载进度的 range，超时把「无声挂起」变成「fallback 完整下载」，用户看不到错误。

### 4. `lib/ui/feed_controller.dart`
- 持有 `_activeSource`：翻页、切 tab、后台、退出播放均 `dispose()` proxy（端口不泄漏）；后台恢复时重新 resolveStream——下载若已完成则直接缓存命中。
- 流式播放中把**本地路径**（不是 URL）`markInUse('streaming')` 进 ActiveFileRegistry → 1GB 清理器不删正在播/正在下载/被 proxy 读取的文件。
- 播放失败不重置列表（`1/38` 修复保持）；WatchStore 进度照常保存。

### 5. `lib/playback/playback_trace.dart`
新增阶段：`streamingModeSelected / streamingProxyStarted / startupBufferReached / streamingFallback / fileCompleted`。
由此可测「**开始播放 X 秒 / 完整下载 Y 秒**」。`firstFrame` 保持 UI 标记，未连接 iOS readyForDisplay 前**不伪造数据**。

### 6. `ios/Runner/Info.plist`
新增 `NSAppTransportSecurity → NSAllowsLocalNetworking`，仅为回环 `http://127.0.0.1` 豁免，不开放明文网络访问。这是唯一 iOS 配置改动。

## 四、明确不做 / 不改

- 未采用「15 秒改 60 秒」；15 秒语义保持为 stall 诊断阈值。
- 未把 TDLib 部分文件直接交给播放器冒充流式。
- 未更换播放器、未新增第三方依赖、IPA 体积增量来自新模块本身（19,904,941 B vs 上一版 19,818,833 B，+86 KB）。
- 未动：Telegram 同步、索引/编号、WatchStore、沉浸式 UI（`FeedImmersivePlan` 零修改）、横竖屏、缓存目录结构、1GB 清理策略、File not found 恢复、Keychain/TDLib DB/session。

## 五、验证结果（分开报告）

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | 无问题 |
| `flutter test`（边下边播 commit 时点） | **748 passed / 1 skipped**，含新增 `streaming_playback_test` 9 例 |
| `flutter test`（当前最新代码，含图片排除） | **753 passed / 1 skipped**（连续两次全绿） |
| 新增测试覆盖 | 完整缓存直连不经 proxy；部分下载立即流式不等 completed；Range 精确服务与 Content-Range；未知路径 403；stall 断开不挂起；启动 stall 报网络判定；fileId 拒绝→消息重取→恢复；同 id 去重一次 downloadFile；proxy 停止释放占用标记 |
| CI | run `40442531521` success（d77d05f）；run `40449026529` success（d322f41） |
| IPA（边下边播版本） | 19,904,941 B，SHA-256 `00fb034f374a7fe0e59a712caec69b47130e3128f3d334039c7c2a0d5b4d0c96` |
| IPA（最新桌面版本，含图片排除） | 19,902,515 B，SHA-256 `5e1f147db1ada7d7220a875f6557a23ff75a9b68a449f52ed8620e36ecbf7e61` |
| 模拟器 | 未执行（本机 Windows，仅 Dart 层测试） |
| **真机** | **未执行。代码测试通过 ≠ 真机边下边播验证通过。** |

## 六、真机验证清单（iPhone 11 Pro / iOS 15.x）

1. **小视频（~10MB）**：快速开始，无明显等待。
2. **中视频（50–200MB）**：未下载完即开始播放，顶栏显示「正在缓冲 X%」随 TDLib 进度增长。
3. **大视频（500MB+）**：播放开始后后台继续下载，不中断，最终完整缓存；第二次播放秒开（走情况 A）。
4. **慢速网络**：显示「正在缓冲」，**不得**出现「网络不可用」。
5. **网络短暂中断**：恢复后继续；仅长时间零字节才报错。
6. **File not found**：旧 fileId 自动从消息重取并恢复。
7. **数字跳转 / 上下滑动**：不回 `1/38`，列表与编号稳定。
8. **1GB 清理**：清理后当前播放文件完好。
9. **诊断页**：`streamingModeSelected→startupBufferReached→fileCompleted` 时间线可读出「开始播放/完整下载」两个数字。

## 七、已知限制与真机风险点（如实）

- `downloadFile(offset)` 定向补拉（超前 seek 加速）V1 **未启用**：超前 range 现在依赖主下载推进，等待有界，超时走 fallback。offset 对齐要求属真机验证项。
- moov 在尾的视频：initialize 会等尾部数据，12 秒超时后自动 fallback 完整下载——功能不失败，但这类视频享受不到提前播放。
- AVPlayer 对回环 `http + 206 + Content-Range` 的实际兼容性只能真机确认。
- 播放中 seek 到未下载区域的表现（卡顿时长、转圈 UI）未做专门 UI，V1 范围外。

## 八、交付物

- 桌面：`C:\Users\Administrator\Desktop\TGMediaProbe-unsigned.ipa`（19,902,515 B，`5e1f147d…e61`，含边下边播 + 图片排除）
- 仓库报告：`tg_media_probe/docs/`（本文件）；commit `d77d05f`、`d322f41`；CI `40442531521`、`40449026529`
