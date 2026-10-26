# 第 4 阶段修复报告：全局竖屏、频道编号直达、可配置预加载

生成时间：2026-10-27 01:50 (GMT+8)
分支：`rebuild-step3`
提交：`9753dce`
上一轮：`837c1f8`（分页/身份/观看记录/4000 条续传）

**真机验证 0 项。** 本报告所有"已修"均指代码与自动化测试；真机项见 §7。

---

## 1. 根因：从播放页返回后频道仍横屏

### 1.1 调用链

```
FeedPage.dispose()
  → PageOrientationScope.dispose()
    → OrientationBridge.resetToPortrait()
      → setMode(lockedPortrait)        // 正确：原生收到 portrait
      → _invokeReset()                 // 致命：原生再收到 reset
        → Swift apply(mode: "system")
          → mask = .allButUpsideDown   // 放开所有方向
          → forceRotation(to: .allButUpsideDown)
            → iOS 15 分支：mask != .portrait，
              且 scene.interfaceOrientation.isLandscape 为真
              → target = 当前横屏方向
              → UIDevice.setValue(landscape)  // 结果：继续横屏
```

两点叠加：

1. **`reset` 的语义是"允许一切方向"，不是"回竖屏"**。它在横屏时还会把旋转目标算成 landscape，所以不仅没恢复，反而把"允许横屏"这条也打开了。
2. **恢复只尝试了一次，而且发生在正在销毁的页面上**。`AppShell` 那个 holder 只在 `initState` 里 `enter()` 过一次，之后没有任何代码重新断言竖屏；`_PortraitHost` 同理。于是 pop 回频道列表后，没有任何一方再要求竖屏。

### 1.2 为什么之前的修法没解决

上一轮把 `dispose` 从 `resetToSystem` 改成 `resetToPortrait`，但 `resetToPortrait` 内部仍然调 `reset`，等于把 bug 从"放开一切"改成"先竖屏再放开一切"。这轮把 `reset` 从正常流程里彻底摘掉。

### 1.3 修复：单一方向栈

新增 `lib/platform/orientation_coordinator.dart`：

| 机制 | 作用 |
|---|---|
| owner 栈（`app` / `feed`） | 栈顶决定方向；**移除 feed 就自动回到 app 的 portrait**，不需要"pop 后再确认一次" |
| `nonPlaybackPortrait` / `playbackPortrait` / `playbackLandscape` | 三种意图，分别对应"非播放页""播放页未全屏""用户点了全屏" |
| 串行 + 序号 | 同一时刻只有一个原生请求在飞；迟到的 landscape 应答因序号过期被丢弃，不会覆盖新的 portrait |
| `OrientationStatus`（applied / failed / unsupported） | 失败可观察，UI 能说"方向切换失败：xxx"而不是假装成功 |
| 不再调用 `reset` | 正常流程只发 `portrait` / `landscape`，`reset` 仅保留给诊断 |

接入点：

- `app_root.dart`：`_PortraitHost` 在 `initState` 注册 `app → nonPlaybackPortrait`，覆盖登录、解锁、启动、壳、设置所有非播放路由；
- `AppShell`：**删除了它的第二个 holder**（这正是两个持有者互相覆盖的来源）；
- `feed_page.dart`：进入注册 `feed → playbackPortrait`；`_toggleLandscape()` 是**唯一**一处 `playbackLandscape`；退出全屏回 `playbackPortrait`；`dispose` 调 `clear(feed)`，栈顶回落即竖屏；
- 全屏请求失败（桥接报错）时提示"方向切换失败：…"，并立刻把意图降回 `playbackPortrait`，不让状态机继续声称横屏。

---

## 2. 频道右上角：视频编号直达

### 2.1 语义（唯一）

**编号 = 当前频道中可播放视频按展示顺序的第 N 个，从 1 开始。** 不是 message_id、不是 file_id、不是数组下标。

两个入口必须同义，所以只留一份实现：`lib/data/video_number_lookup.dart`。

```dart
VideoNumberLookup.find(store, chatId, number, pageSize: 40)
  → 逐页 store.page(chatId: chatId)
  → 过滤 kind == video && fileId != 0   // 与 feed 完全相同的过滤
  → 第 number 个命中即返回 (chatId, messageId)
  → 短页结束 → notFound + 实际视频数
  → number < 1 或 > 100000 → invalid
```

### 2.2 入口放置（报告要求说明）

- **频道详情页**：AppBar 右侧新增 `#` 按钮（与"播放该频道"并列）——这是唯一合理位置，因为编号必须有频道上下文；频道列表页没有"当前频道"，硬放会变成"先选频道再输编号"的两步流程。
- **视频页**：保留上一轮的 `#` 入口，内部走 `FeedController.openNumber()`，编号语义与该频道详情一致（列表顺序 = 同一份索引顺序）。

### 2.3 行为

| 输入 | 结果 |
|---|---|
| `38` | 定位到本频道第 38 个视频并打开（`initialMessageId` 传真实 message id） |
| 超出范围 | 「未找到编号 N（本频道共 M 条视频）」，M 是**实际扫描到的视频数**，不跳回第一条 |
| `0` / 负数 / 非数字 / 空 | 「请输入 1 以上的数字编号」 |
| 查找中 | `_jumpBusy` 保护，重复点击不会并发跳转 |
| 另一个频道的同号 | 查不到（`chatId` 限定），不是"跳到别人的第 38 条" |

查找全程只读本地索引，**没有任何 TDLib 调用**（`VideoNumberLookup` 的参数里根本没有 client）。

---

## 3. 设置页：相邻视频预加载数量

### 3.1 语义与边界（报告要求）

| 项 | 值 |
|---|---|
| 含义 | **向后**预加载 N 条（当前视频之后的 N 个），不含前面 |
| 默认 | `1` —— 与旧开关"预取下一条"等价，行为不退化 |
| 范围 | `0`–`3`（`0` = 关闭） |
| 上限依据 | 每个额外项都是一次 TDLib 传输，会与正在播放的那条抢带宽；且路径缓存上限 3 条，超过 3 没有意义 |
| 并发 | **逐个**预取，不并发；当前视频先解析，成功后才开始预取 |
| 取消 | 序号 token：切换/离开时旧窗口的剩余预取立即作废；`shutdown` 后不再继续 |

### 3.2 实现

- `AppPreferences.preloadCount`（int）+ 旧 `preloadAdjacent` 保持同步（`count > 0`），旧存档能读、新存档能回写；
- 非法值（-1、4、999）**拒绝保存**并提示，不静默 clamp；手改存档里的越界值才 clamp（读路径容错）；
- 设置页那一行从 Switch 改为数字编辑（`0–3`），文案写明"向后预加载 N 条（逐个预取，不并发）"；
- `FeedController.preloadCount` 驱动 `_prefetchNext()`：`for offset in 1..count`，每步检查 generation，成功后写 `_pathCache`（上限 3），失败只累加 `prefetchFailed`，不影响当前播放；
- 计数：`prefetchCompleted` / `prefetchFailed` 可读，用于报告真机数据。

---

## 4. 修改文件

| 文件 | 改动 |
|---|---|
| `lib/platform/orientation_coordinator.dart` | **新增**（owner 栈、串行、序号、状态） |
| `lib/app/app_root.dart` | `_PortraitHost` 改用 coordinator；删除 AppShell 的第二个方向 holder |
| `lib/ui/feed_page.dart` | 方向改走 coordinator；toggle 失败文案区分桥接失败/系统锁；`preloadCount` 传入控制器 |
| `lib/data/video_number_lookup.dart` | **新增**（编号查找唯一实现） |
| `lib/ui/channel_pages.dart` | AppBar 编号入口、`_jumpBusy`、notFound 显示真实数量 |
| `lib/app/app_preferences.dart` | `preloadCount`（0–3，默认 1）、兼容旧布尔、`setPreloadCount` 越界拒绝 |
| `lib/ui/settings_page.dart` | 预加载数量数字编辑（替换开关） |
| `lib/ui/feed_controller.dart` | `preloadCount` 驱动顺序预取 + generation 取消 + 计数；`currentNumber`；编号上限复用共享常量 |

**没有动**：只读守卫、TDLib 数据库与加密键、缓存清理白名单、观看记录、4000 条续传、分页游标、编号上限以外的分页逻辑。

---

## 5. 测试

`flutter analyze` → **No issues found**
`flutter test` → **679 passed / 1 skipped**（上一轮 643；skip = `TDJSON_PATH` 未设，本机无 TDLib 二进制）

| 新增文件 | 项数 | 覆盖 |
|---|---|---|
| `test/orientation_coordinator_test.dart` | 14 | 启动即竖屏；进播放页仍竖屏；播放/切条不请求横屏；只有全屏请求横屏；退出全屏回竖屏；关闭播放页回落到 app portrait；切换 Tab 回竖屏；**在飞的 landscape 应答不得覆盖 portrait**；快速 10 次切换最后一次生效；桥接抛错 → 可观察失败；无桥接 → unsupported；`_toggleLandscape` 不碰控制器（不重置进度/身份） |
| `test/video_number_lookup_test.dart` | 9 | 第 38 条正确（跳过 2 张图片）；同号跨频道不串；超范围报真实数量；0/负/超大 invalid；空频道 0 条；跨页仍能找到；追加旧数据后编号不变；**无网络客户端也能查到**；只有图片的频道视频数为 0 |
| `test/preload_count_test.dart` | 13 | 默认 1；改 2 后重启仍 2；0 关闭并记住；-1/4/999 被拒且不覆盖旧值；旧布尔存档可读；手改越界读时 clamp；count 0 不预取；count 2 恰好预取 2 条；count 99 被夹到 3；切换后旧窗口不再继续；预取失败不影响播放（仍 ready）；当前条先解析；shutdown 后停止 |

改动既有测试 3 处（`test/orientation_test.dart` 的源码断言）：从"页面上有 `PageOrientationScope`"改为"host 注册 `nonPlaybackPortrait`、feed 只在 toggle 里请求 landscape、shell 不再持有方向"。断言数量从 3 条变为 4 条且更严格（含"全页面只允许一处 landscape 请求"）。

---

## 6. CI 与产物

| 项 | 值 |
|---|---|
| CI run | [40369973675](https://github.com/1585365426/tg-media-probe/actions/runs/40369973675) |
| 最终状态 | **success**，9m48s（17:35:02Z → 17:44:50Z） |
| 提交 SHA | `9753dce9c72a1fbe3cf5ce7a5d4ac38df493bfb7` |
| `flutter analyze` | No issues found（本机；CI step 13 同步通过） |
| `flutter test` | **679 passed / 1 skipped**（本机 `00:50`，CI `01:04`） |
| IPA | `TGMediaProbe-unsigned.ipa` **19,779,742 B** |
| SHA-256 | `e6511d8341266d66febdc80252b14d6850d5e5e994a7c4ebdb6a88ed6370b1d7` |
| 静态核验 | TDLib 静态链接，四个 tdjson 符号导出；bundle `com.tgmedia.tgMediaProbe`，minos 15.2 |

数字取自 CI 的 `ci-report/package.txt`（`ipa_bytes` 与 sha256 行），未手算。

---

## 7. 真机验证：0 项，全部未执行

| # | 项目 | 状态 |
|---|---|---|
| 1 | 从频道进视频再返回，频道仍是竖屏 | 未执行 |
| 2 | 点全屏才横屏，退出全屏回竖屏 | 未执行 |
| 3 | 系统方向锁开启时点全屏，出现明确提示 | 未执行 |
| 4 | 快速连点全屏按钮，不出现方向抖动/卡死 | 未执行 |
| 5 | 切到设置 Tab、后台再回来，仍竖屏 | 未执行 |
| 6 | 频道详情点 `#` 输 38，打开该频道第 38 条 | 未执行 |
| 7 | 输 9999，提示"未找到编号 9999（本频道共 N 条视频）" | 未执行 |
| 8 | 设置里把预加载改成 0/1/3，重启后仍生效 | 未执行 |
| 9 | 预加载 3 条时播放是否卡顿、首帧是否受影响 | 未执行 |
| 10 | 观看进度、分页、4000 条续传在真机上未回归 | 未执行 |

---

## 8. 未解决 / 风险

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 全部真机项 | 方向最终由 UIKit 决定，Dart 层测试只能证明"请求了什么" |
| 中 | 编号随同步变化 | 编号是"当前展示顺序"，头部插入新视频会让同号指向另一条；跳转有 `(chatId, messageId)` 身份校验，不会误播，但"38 永远是同一条"需要另立规则 |
| 中 | 预加载只向后 | 需求允许"前后各 N"或"总共 N"，本轮采用"向后 N 条"并在 UI 写明；向前预加载会在用户回滑时受益，但成本翻倍，未做 |
| 中 | TDLib 池可能被 LRU 回收 | 仍未保活；不宣称已解决。长时间播放需真机观察 |
| 低 | 预加载失败静默 | 只累加 `prefetchFailed`，不打扰用户；真机需要时可通过诊断导出看到 |
| 低 | iOS 15 走 KVC `UIDevice.setValue` | 非公开键，第 3 步已记录，本轮无新增风险 |

---

## 9. 确认

- 未开始第 5 阶段。
- 未新增用户主动下载、下载管理、下载历史。
- 只读守卫、数据库加密、缓存路径保护均未改动。
- 观看记录、4000 条续传、分页游标逻辑未改动（测试全量通过）。
