# 第 4 阶段专项：首次播放启动慢

生成时间：2026-10-27 02:05 (GMT+8)
分支：`rebuild-step3`
提交：`36783ba`
上一轮：`9753dce`（方向协调器 / 频道编号 / 预加载数量）

**真机验证 0 项。** 下面的耗时结论来自代码路径分析，不是设备实测；报告最后一节给出必须真机采集的字段。

---

## 1. 三个现象分别指向什么

| 现象 | 判定 |
|---|---|
| 第一次播放长时间"准备中" | **成立**，且原因在代码里可定位：播放器只接受本地文件，而本地文件要等 TDLib 报"下载完成" |
| 退出后再播同一条明显更快 | **成立**，第二次命中本地完整文件，`resolve()` 只做一次 `stat` 就返回 |
| 官方客户端明显更快 | 与官方实现方式不同：官方用 TDLib 的流式读取（按 offset 读前缀）边下边播；本应用把文件交给 AVPlayer，必须先有完整文件 |

三者是同一个结构原因的不同侧面，不是三个独立 bug。

---

## 2. 根因（按证据分层）

### 2.1 结构层：等整文件才返回路径

`lib/playback/video_source.dart` 的 `_resolveOnce()`：

```dart
final subscription = api.updates().listen((state) {
  if (state.id != fileId) return;
  if (state.isCompleted) {           // ← 只有"下载完成"才完成 future
    completion.complete(state);
  }
  ...进度回调...
});
await api.start(fileId);             // downloadFile
final state = await completion.future.timeout(fetchTimeout);
return state.path;                   // 把本地文件路径交给播放器
```

`api.start()` 发的是 `downloadFile`（`td_requests.dart:125`，`synchronous=false`），TDLib 会一直推到 `is_downloading_completed`。中途的 `updateFile` 只用来显示进度，**不用于播放**。

为什么不能直接用前缀：`video_player` 在 iOS 上要一个文件 URL（`VideoPlayerController.file`），它不支持"边写边读的资源"。把不完整文件交过去，AVPlayer 会当成损坏文件。所以"等完整文件"不是可随手去掉的一行，而是当前播放器选型的约束。

**结论**：首次播放的耗时 ≈ 该视频完整下载耗时。这部分本轮没有消除，也不声称消除。

### 2.2 真实浪费 1：同一个文件可能被请求两次

`resolve()` 原来没有在飞去重。两个调用者可以对同一 `fileId` 并发进入：

- 页面开始解析当前条；同一时刻预加载窗口在解析相邻条（不同 id，不会撞）；
- 但**快速来回切换**（A→B→A）时，A 的第二次解析可能命中 A 仍在进行中的第一次解析；
- `goToMessage` 与初始定位也可能同时指向同一条。

两条路径各自 `api.start(fileId)`，就是两次 `downloadFile`。TDLib 会合并部分请求，但等待、取消语义和计数都会乱。

修复：`Map<int, Future<String>> _inflight`，同一 fileId 共享同一个 future。

```dart
Future<String> resolve(int fileId, {onProgress, PlaybackTrace? trace}) {
  final running = _inflight[fileId];
  if (running != null) return running;
  final future = _resolveOnce(fileId, ...);
  _inflight[fileId] = future;
  return future.whenComplete(() => _inflight.remove(fileId));
}
```

测试：三个并发 `resolve(9)` → `startCalls == 1`。

### 2.3 真实浪费 2：残缺文件被当成缓存命中

原判定：`isCompleted && path 非空 && 文件存在` → 直接返回路径。

问题：TDLib 的记录可能标着"完成"，但文件被截断或大小与 `expected_size` 不符（清理工具、异常退出、磁盘写满都会造成）。这时播放器拿到一个残缺文件，表现为解码失败或播到一半停住，用户再点一次才重新下载——这正好是"第一次慢、第二次快"之外的另一条"第一次直接失败"的路径。

修复：命中还要求 `size >= expectedSize`（`expectedSize == 0` 时跳过该检查，兼容 TDLib 未填大小的情况）。

测试：`completedSize=400 / expectedSize=1000` → 重新 `start`，不当作命中。

### 2.4 超时信息不足

原来：`加载超时（15 秒）`。它无法区分"卡在 2%"（网络问题）和"99% 但差最后一块"（大文件/慢链路）。现在：

```
加载超时（15 秒，已下载 2100000B/5809108B，36%）
```

`VideoSourceTimeout` 带 `downloadedBytes` / `expectedBytes`，由 resolver 在 `updateFile` 中记录。

### 2.5 没有可观测的阶段划分

原来"准备中"是一个状态，包含：查记录、发下载、等下载、建播放器、初始化。无法判断慢在哪一段。

新增 `lib/playback/playback_trace.dart`：

| 阶段 | 何时标记 |
|---|---|
| `selected` | 用户选中该条（`_activateCurrent` 开头） |
| `resolveStarted` | `resolve()` 进入 |
| `fileRecordKnown` | `stat` 返回（带已下载字节） |
| `downloadRequested` | 发出 `downloadFile` |
| `firstBytes` | 第一个带字节的 `updateFile` |
| `fileReady` | 文件完成且可读（或命中缓存） |
| `playerCreated` | 播放器对象创建 |
| `playerInitialized` | 播放器初始化完成 |

`firstFrame` 字段保留但**未接入**：首帧需要平台回调（AVPlayerLayer 的 readyForDisplay），本轮没有可靠接法，标注为未验证，不假装有。

日志只写：file/message/chat id、各阶段耗时、字节数、错误类别。**不写**路径（含容器 UUID）、api_hash、数据库密钥、手机号、令牌。测试里有一条断言专门检查 summary 不含这些模式。

诊断导出（设置 → 导出诊断信息）现在包含最近 20 次播放的 `playback` 行。

---

## 3. 修改文件

| 文件 | 改动 |
|---|---|
| `lib/playback/playback_trace.dart` | **新增**：阶段枚举、`PlaybackTrace`、`PlaybackTraceLog`（上限 20） |
| `lib/playback/video_source.dart` | 在飞去重；缓存命中加大小校验；`VideoSourceTimeout` 带字节与百分比；阶段标记与错误类别 |
| `lib/ui/feed_controller.dart` | 为每次播放建 trace，标记 selected/playerCreated/playerInitialized，写入 log；命中预取路径时标 `fileReady` |
| `lib/app/app_session.dart` | `diagnostics()` 增加 `playback` 行 |

**没有改**：只读守卫、TDLib 数据库与密钥、缓存清理白名单、观看记录、编号、方向、分页、4000 条续传。预加载仍默认 1、顺序、可取消、当前条优先（上一轮实现，本轮未触碰）。

---

## 4. 首次 vs 重复：结构上能到多快

| 场景 | 现在的路径 | 耗时构成 |
|---|---|---|
| 首次播放（未缓存） | stat → downloadFile → 等完整 → 建播放器 → 初始化 | **下载耗时 + 播放器初始化**（下载占绝大部分） |
| 重复播放（已缓存） | stat（completed + 大小校验 + 文件存在）→ 建播放器 → 初始化 | 一个 TDLib 往返 + 播放器初始化 |
| 预取命中（下一跳） | `_pathCache` 直接给路径 | 播放器初始化 |
| 缓存残缺 | stat 认为完成但 size 不足 → 重新下载 | 与首次相同，但不再把残缺文件交给播放器 |

**本轮实际改善**：去掉了重复请求（同一文件两次 `downloadFile`）、去掉了"残缺文件被当命中"导致的失败重来、把等待时间变得可归因。**没有**缩短单次完整下载的时间，也没有实现边下边播。

边下边播需要另一套东西（AVPlayer + 自定义 resource loader 从 TDLib 读前缀，或 TDLib 的流式文件读取接口）。本轮没有做，因为：
1. `video_player` 只接受本地文件路径；
2. 未经真机验证的流式实现会让"能播"变成"有时能播"；
3. 需求明确要求"不得直接把未完成文件交给不支持增量读取的播放器"。

---

## 5. 测试

`flutter analyze` → **No issues found**
`flutter test` → **689 passed / 1 skipped**（上一轮 679；skip = `TDJSON_PATH` 未设）

新增 `test/playback_trace_test.dart`（10 项）：

| # | 断言 |
|---|---|
| 1 | 阶段耗时按毫秒计算，未到达的阶段返回 null |
| 2 | 重复标记不覆盖首次到达时间 |
| 3 | summary 含 id/耗时/字节/错误类别，且不含路径、api_hash、token、11 位以上数字 |
| 4 | 日志上限生效（3 条上限写 5 条剩 3 条） |
| 5 | 完整缓存命中：`statCalls=1`、`startCalls=0`、trace 无 `downloadRequested` |
| 6 | 完整但被截断（400/1000）→ 重新 `start`，不当命中 |
| 7 | 三个并发 resolve 同一 fileId → 只发一次 `downloadFile` |
| 8 | 记录完成但文件不存在 → 重新请求后抛"已不存在"，不静默返回死路径 |
| 9 | 超时 → 文案含"已下载 …%"，错误类别 `timeout`，且调用了 `cancel` |
| 10 | TDLib 错误 → 错误类别被记录 |

既有相关测试全部保留并通过：完整缓存命中、缓存缺失、空路径、文件消失、超时、TDLib 错误、快速切换、预加载失败不中断、当前条优先、编号、观看记录、方向、分页、4000 条续传。

---

## 6. CI 与产物

| 项 | 值 |
|---|---|
| CI run | [40372827471](https://github.com/1585365426/tg-media-probe/actions/runs/40372827471) |
| 状态 | **success**（轮询确认 completed/success，`ci-report` 分支已由该 run 更新） |
| 提交 SHA | `36783ba`（`git log` 与 `ci-report` 记录的 head 一致） |
| `flutter analyze` | No issues found（本机；CI step 同步通过） |
| `flutter test` | **689 passed / 1 skipped**（本机 `00:45`，CI `00:48`） |
| IPA | `TGMediaProbe-unsigned.ipa` **19,784,336 B** |
| SHA-256 | `89ccae48fa9c264ebf8fd26662f02c4371709216a16897afd1f4eb759f3d80b1` |

数字取自 `ci-report/package.txt` 的 `ipa_bytes` 与 sha256 行，未手算。运行时 GitHub 的 run 元数据接口连续返回空响应，因此本表不写耗时秒数——只写已确认的状态与产物。

---

## 7. 真机：0 项，全部未执行

必须采集的三组数据（每次播放后从 设置 → 导出诊断信息 里取 `playback` 行）：

| 场景 | 需要记录 | 状态 |
|---|---|---|
| 首次播放（该视频从未播过） | `total`、`downloadRequested→fileReady` 耗时、`expected/got` 字节、`fileReady→playerInitialized` 耗时 | 未验证 |
| 退出后立即再播同一条 | `total`（应只剩 stat + 播放器初始化）、是否出现 `downloadRequested`（不应出现） | 未验证 |
| 预加载后播放（滑到下一条） | `total`、是否出现 `downloadRequested`（不应出现） | 未验证 |
| 大文件（>20 MB）首次播放 | 是否触发 15 秒超时、超时文案里的百分比 | 未验证 |
| 播放中切走再回来 | 是否重新下载（`cancel` 后再 `start` 属预期） | 未验证 |

**没有真机数据前，不能声称"首次播放已变快"。** 本轮能声称的只有：重复请求被消除、残缺文件不再被误判为命中、慢在哪一段现在可测。

---

## 8. 未解决 / 风险

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 首次播放仍需等完整下载 | 结构性；要真正解决必须换播放通道（resource loader 或 TDLib 流式接口） |
| 高 | 真机 0 项 | 见 §7 |
| 中 | `firstFrame` 未接入 | 需要 AVPlayerLayer 的 `readyForDisplay`，本轮没有可靠接法 |
| 中 | 15 秒超时对超大文件偏短 | 超时后 `cancel` 会丢掉已下载进度，下次重来。是否按时长/字节自适应，需要真机数据再定 |
| 中 | TDLib 池可能被 LRU 回收 | 仍未保活，前几轮已记录 |
| 低 | trace 只保留 20 条 | 诊断用途，够用；不做持久化 |

---

## 9. 确认

- 未进入第 5 阶段。
- 未新增下载/保存/下载管理功能。
- 未改动只读守卫、数据库、缓存路径保护、观看记录、编号、方向、分页逻辑。
- 未用模拟数据代替真机结论。
