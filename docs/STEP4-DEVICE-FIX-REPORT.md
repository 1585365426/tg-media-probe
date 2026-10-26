# 第 4 步真机故障修复报告

生成时间：2026-10-26 23:45 (GMT+8)
分支：`rebuild-step3`
修复提交：`e17adaa`（四个故障）+ `1df3365`（CI 修正）
CI：run [40349026024](https://github.com/1585365426/tg-media-probe/actions/runs/40349026024) — **success，12m25s**（含排队）
head：`1df3365cf788af185c3f1372809373468a7c6f4e`
产物：`TGMediaProbe-unsigned.ipa` **19,781,152 B**，sha256 `6247d6a3cfafb00edc0702d25b2cdde55f963373efc1790a722339b6d1f4cd5c`
桌面副本：`C:\Users\Administrator\Desktop\TGMediaProbe-unsigned-fix.ipa`（哈希与上一致，已本地复算）

**本轮没有在 iPhone 上验证任何一条。** 下面凡是"已修"都指代码与自动化测试层面，真机一栏见 §6。

---

## 0. 基线

| 项 | 值 |
|---|---|
| 修复前 HEAD | `0397371`（验收补强文档） |
| 工作区 | 干净，未覆盖任何本地改动 |
| 修复前测试 | 581 passed / 1 skipped |
| 修复后测试 | **603 passed / 1 skipped** +22 |

---

## 1. 故障 D / C 的共同根因：历史游标用的是视频 id，不是消息 id

### 1.1 现场

用户报告"视频页固定 38 条，触底不加载"。38 不是阈值，是**第一次同步写进索引的视频数**。之后每一轮同步都在读同一批消息，插入 0 条。

### 1.2 根因（`lib/data/channel_sync.dart`）

```dart
// 修复前
final nextCursor = page.messages.isEmpty
    ? null
    : (records.isNotEmpty ? records.last.messageId : null);
```

`records` 是**过滤后的媒体列表**。假设一批 100 条消息里只有 1 条视频、且它是这批里最新的：

- `records.last.messageId` = 1000（那条视频）
- 下一次请求 `from_message_id = 1000` → TDLib 返回"比 1000 更旧"的消息 → **还是同一批**
- `hasMore` 因为这一批是满页而恒为 true

结果：游标原地打转，索引永远停在 38 条。这正是用户禁止的"把 38 写成固定数量"——它是 bug 的症状，不是配置。

### 1.3 修复

```dart
// 修复后：游标只认原始批次里最老的消息 id
final rawCursor = rawLowestId;
final advanced = rawCursor != null && (cursor == null || rawCursor < cursor);
final hasMore = filledPage && advanced;
final nextCursor = hasMore ? rawCursor : null;
```

外加两条约束：

1. **游标不前进就结束本轮**，不进入无限重复请求（测试 `a source that ignores the cursor is cut off after one repeat` 用"永远返回同一批"的恶意源验证）。
2. 水位线（`oldestMessageId` / `newestMessageId`）仍用媒体 id，因为那是"我们存了什么"，与"走到哪"是两件事。

`PageLoadResult` 与 `SyncCycleReport` 新增 `reachedEnd`，把四种状态分开：

| 状态 | 判据 | UI |
|---|---|---|
| 本批没有视频 | `records` 空、`rawMessageCount == limit` | 继续走下一页 |
| 已到历史末尾 | 短页（`rawMessageCount < limit`） | 页脚显示「已到历史末尾」，按钮置灰 |
| 请求失败 | `isError` | 错误态 + 重试可用 |
| 仍在进行 | 未返回 | 加载态 |

### 1.4 触底没有回调（第二个独立缺陷）

`ChannelDetailPage` 的页脚有「加载更多」「从 Telegram 同步 2 页」两个按钮，但 **ListView 没有 `ScrollController`，滚动到顶也不会触发任何东西**，而且要先把列表滚到底才能看到按钮。已补：

- `_onScroll`：距底部 240 px 内触发 `_loadFurther()`；
- `_loadFurther()`：先本地索引分页，本地没了再同步 Telegram，`_reachedEnd` 后不再自动请求；
- `_autoLoading` / `_loading` / `_syncing` 三重互斥，一次滑动不会发出两个请求。

### 1.5 点击没反应（第三个独立缺陷）

`_MediaRow` 是纯 `ListTile`，**没有 `onTap`**。"频道视频列表点击无响应"不是手势被透明层吃掉，是根本没有回调。

修复：`_MediaRow(onTap:)` → `_openRecord(record)` → 打开 `FeedPage(initialChatId, initialMessageId)`。新增 `FeedController.goToMessage(chatId, messageId)`：先在已加载列表里找，找不到就继续分页（最多 5 页），到不了就返回 false 并停在当前项，不会留一个空播放器。

### 1.6 回归测试（`test/feed_paging_regression_test.dart`，10 项）

| # | 用例 | 断言 |
|---|---|---|
| 1 | 只有最新一条是视频的批次 | `nextCursor == 91`（原始最老 id），不是 100 |
| 2 | 38 条已索引 → 再同步两页 | `count > 38`，请求游标 `[0, 89]` |
| 3 | 下一批全是已有视频 | `inserted == 0` 但游标仍前进 |
| 4 | 短页 | `reachedEnd == true`、`hasMore == false` |
| 5 | 满页但无视频 | `reachedEnd == false`、`hasMore == true` |
| 6 | 请求失败 | `isError`，不是空成功 |
| 7 | 失败后重试 | 第二次成功并推进游标 |
| 8 | 恶意源（游标不生效） | 第二轮 `hasMore == false`，不死循环 |
| 9 | 两个频道 | 互不覆盖水位与行数 |
| 10 | 旧频道结果 | 按 `(chatId, messageId)` 落库，无法写进别的频道 |

`test/feed_controller_test.dart` 另加 3 项覆盖行点击：首页命中不额外请求、跨页能到、找不到返回 false。

---

## 2. 故障 B：自动横屏且切不回竖屏

### 2.1 根因

整个应用**没有任何一处持有竖屏**：

- `AppShell`（频道 / 抖音 / 设置三个 Tab 的容器）没有方向 scope；
- `PageOrientationScope.dispose()` 恢复的是 `followSystem`，而 `Info.plist` 允许横屏；
- 于是手机横着拿，整个 UI 就转过去；离开抖音页后仍然横着，"切回竖屏"的按钮只在抖音页里，回到列表就再也点不到。

### 2.2 修复

1. `AppShell` 持有 `lockedPortrait`（三个 Tab 都在竖屏里）。
2. `PageOrientationScope.dispose()` → `resetToPortrait()`（`setMode(portrait)` + `reset`），不再是 followSystem。
3. 抖音页进入时仍是 `lockedPortrait`，只有用户点转屏按钮才进 `forcedLandscape`；离开时自动回竖屏。
4. `_toggleLandscape` 原有逻辑保留：请求 → 等 400 ms → 用 `MediaQuery.orientation` **验证真转了**，没转提示「系统方向锁已开启，无法自动旋转」，不假报成功；`_rotationHintBusy` 防重复点击。

### 2.3 测试（`test/orientation_test.dart`）

- 既有「dispose 只 reset 一次」改为更严的契约：**调用顺序必须是 `setMode(portrait)` → `reset`，最终状态是 lockedPortrait**（旧断言是 followSystem，那正是 bug 本身）；
- 新增 `resetToPortrait applies portrait before telling the system to reset`；
- 新增 `the shell holds portrait while the feed borrows landscape`：壳竖屏 → 视频页横屏 → 退出视频页 → 回竖屏。

### 2.4 CI 抓到的错误（必须记）

第一次修复在 iOS 15 分支加了 `setNeedsUpdateOfSupportedInterfaceOrientations()`，它是 **iOS 16+ API**，而该分支在 `#available(iOS 16)` 的 `else` 里。run `40347900020` 因此编译失败：

```
Swift Compiler Error: 'setNeedsUpdateOfSupportedInterfaceOrientations()' is only available in iOS 16.0 or newer
```

已移除（iOS 15 只剩 KVC 写方向 + `attemptRotationToDeviceOrientation()`），`1df3365` 后构建通过。和第 3 步 `override` 那次同类：**Swift 侧无法在本机编译，只能靠 CI 抓**。

---

## 3. 故障 A：开启 Face ID 后反复进出无法进入

### 3.1 根因（两条叠加）

1. **系统弹窗本身触发重锁。** Face ID 弹窗会让 iOS 发 `inactive`，验证完发 `resumed`。`didChangeAppLifecycleState` 把 `inactive` 当"离开前台"，`onResumed()` 于是按"立即锁定"重新判定 → `_phase` 从 `unlocked` 被打回 `requestingBiometric`。
2. **回到 `requestingBiometric` 后没人再弹。** 自动弹窗只在 `initState` 跑一次（`_autoPrompted`），而按钮在该 phase 是 disabled（显示"正在请求 Face ID…"）→ 界面卡在"正在请求"，按钮点不动。

两条合起来就是用户看到的：开了 Face ID，退出再进，进不去。

### 3.2 修复

| 改动 | 位置 |
|---|---|
| `inactive` 不再算离开前台（只有 `paused/hidden/detached` 才记后台时间） | `app_root.dart` |
| 弹窗在飞行中时，`onResumed()` 直接返回，不重新判定 | `unlock_controller.dart` |
| `promptBiometric()` 用 `_promptInFlight` 防重入，第二次点击不会开第二个系统弹窗 | 同上 |
| 看门狗：弹窗 12 秒无结果 → 回落 `needsPasscode`，提示「生物识别没有响应，请用应用密码解锁」（**不解除锁定**） | 同上 + 解锁页 1 s ticker |
| 解锁页监听 phase 变化：重新进入 `requestingBiometric` 且当前没有弹窗时**重新弹一次**（每个锁定周期一次，不循环） | `lock_screens.dart` |
| 任何非成功结果都落到 `passcodeOnly`，不再返回"再问一次" | `lock_policy.dart` |

最后一条同时修掉了"取消后立刻又弹"的死循环：原来 `userCancel → biometricThenPasscode`，而解锁页必须在该 phase 重新弹（否则重锁不再提示），两者相加就是无限弹窗。

### 3.3 测试（`test/unlock_controller_test.dart` +6）

用一个**会挂起**的 `DeferredBiometricGate`（真实系统弹窗就是这样：不扫就不返回）：

1. 弹窗期间 `paused/resumed` 不会撤销解锁；
2. 弹窗永不返回 → 12 秒后回落密码，**仍在锁定状态**；
3. 回落之后还能再次请求 Face ID（证明不卡死）；
4. 取消后密码可用、传感器仍可点；
5. 第二次点击不会开第二个弹窗（`authenticateCount == 1`）；
6. 真后台仍然会重锁（证明 `inactive` 豁免没把自动锁一起关掉）。

`test/lock_policy_test.dart`：原「取消保留可点」改为断言落 `passcodeOnly`，并新增 6 种非成功结果统一断言。

---

## 4. 修改文件

| 文件 | 改动 |
|---|---|
| `lib/data/channel_sync.dart` | 游标/水位改用原始消息 id；`advanced` 守卫；`PageLoadResult.reachedEnd`；`SyncCycleReport.reachedEnd/lastError`；`drainChannel` 同步语义 |
| `lib/ui/channel_pages.dart` | 滚动触底 `_onScroll` + `_loadFurther`；`_reachedEnd` 页脚；行 `onTap` → 打开指定消息；同步失败文案分类 |
| `lib/ui/feed_controller.dart` | 新增 `goToMessage(chatId, messageId)`（跨页查找，有界） |
| `lib/ui/feed_page.dart` | 新增 `initialMessageId`；加载后跳到该条 |
| `lib/platform/orientation_controller.dart` | 新增 `resetToPortrait()`；scope dispose 改回竖屏 |
| `lib/app/app_root.dart` | `AppShell` 持有竖屏；`inactive` 不算离开 |
| `lib/lock/unlock_controller.dart` | `_promptInFlight`、`awaitingBiometric`、`tickBiometricWatchdog`、resume 保护 |
| `lib/lock/lock_screens.dart` | phase 变化重新武装弹窗；ticker 驱动看门狗 |
| `lib/security/lock_policy.dart` | 非成功结果统一 `passcodeOnly` |
| `ios/Runner/AppDelegate.swift` | 修正 iOS 15 分支误用 iOS 16 API（CI 抓出） |

新增测试：`test/feed_paging_regression_test.dart`(10)；改动：`unlock_controller_test`(+6)、`feed_controller_test`(+3)、`orientation_test`(改 1 加 2)、`lock_policy_test`(改 1 加 1)。

**没有做的事**：没改 `TdReadOnlyGuard`；没删/迁移 TDLib 数据库；没让缓存清理碰受保护目录；没删除 `tdlib_files/`；没重新引入用户下载；没加假数据；没把 Face ID 默认关掉。

---

## 5. 自动化结果

```
flutter analyze  → No issues found
flutter test     → 603 passed / 1 skipped（本机 00:54，CI 00:59）
skip 1 项        → tdjson_load_test：TDJSON_PATH 未设，本机无二进制，运行时加载未验证
```

| CI | 结论 |
|---|---|
| `40347900020`（`e17adaa`） | **failure**：iOS 15 分支误用 iOS 16 API，Swift 编译失败 |
| `40349026024`（`1df3365`） | **success**，12m25s（含排队），测试 `00:59 +603 ~1`，TDLib 四个符号导出 |

产物：`TGMediaProbe-unsigned.ipa` **19,781,152 B**，sha256 `6247d6a3cfafb00edc0702d25b2cdde55f963373efc1790a722339b6d1f4cd5c`，bundle `com.tgmedia.tgMediaProbe`，minos 15.2。

---

## 6. 真机验证：0 项通过

以下全部**未执行**。没有 iPhone 访问、没有安装，也没有 Telegram 网络。修复只能算"代码层已改、自动化已覆盖"。

### 6.1 故障 D —— 触底加载（必须记录数字）

| 步骤 | 需要记录 | 结果 |
|---|---|---|
| 进入频道详情，记录初始条数 | 条数（修复前用户看到 38） | 未执行 |
| 滑到底部 | 是否自动触发；触发了几次请求 | 未执行 |
| 第一次同步请求 | `chat_id` / `from_message_id` / `limit` | 未执行 |
| 同步返回 | 原始消息数 / 新增视频数 / 新游标 | 未执行 |
| 连续触底 3 次 | 条数是否持续增长；游标是否单调下降 | 未执行 |
| 一直到底 | 是否出现「已到历史末尾」而不是无限加载 | 未执行 |
| 飞行模式下触底 | 是否显示错误并保留重试按钮 | 未执行 |
| 快速连续滑动 | 是否出现并发重复请求（看日志） | 未执行 |

### 6.2 故障 C —— 点击

| 步骤 | 结果 |
|---|---|
| 点列表任意一行 | 未执行（预期：打开该条视频，且是**这一条**，不是频道第一条） |
| 点一条不在本地索引的 | 未执行（预期：翻页找到后打开，或明确提示找不到） |
| 点底部「加载更多」 | 未执行 |
| 点底部「从 Telegram 同步 2 页」 | 未执行 |

### 6.3 故障 B —— 方向

| 步骤 | 结果 |
|---|---|
| 竖屏进入抖音页 | 未执行（预期：竖屏，不自动横） |
| 点转屏 | 未执行（预期：横屏，信息区隐藏，搜索仍在） |
| 再点转回 | 未执行（预期：竖屏，且设备方向与 UI 一致） |
| 开系统方向锁后点转屏 | 未执行（预期：提示「系统方向锁已开启，无法自动旋转」，不反复重试） |
| 横屏时返回列表 | 未执行（预期：立即竖屏） |
| 横屏时切到后台再回来 | 未执行 |

### 6.4 故障 A —— Face ID

| 步骤 | 结果 |
|---|---|
| 设密码 + 开 Face ID | 未执行 |
| 冷启动验证成功 | 未执行（预期：直接进入，不闪回锁屏） |
| 验证成功后立刻退到后台再回来 | 未执行（预期：要求重新解锁，且**能进去**） |
| 弹窗里点取消 | 未执行（预期：落到密码框，按钮可再点，不自动重弹） |
| 取消后连点 Face ID 两次 | 未执行（预期：只弹一次系统弹窗） |
| 遮住脸连续失败 | 未执行（预期：回密码，冷却递增） |
| 弹窗卡住 12 秒 | 未执行（预期：自动回密码并提示"没有响应"） |
| 忘记密码重置 | 未执行（预期：清本地会话 + 重新登录，锁不放宽） |

---

## 7. 剩余风险

| 级别 | 风险 | 说明 |
|---|---|---|
| 高 | 四个修复都未真机验证 | 尤其方向与 Face ID，只有本机能跑的部分被覆盖 |
| 中 | 池文件回收策略仍未定 | 见 `STEP4-ACCEPTANCE-GAP-REPORT.md` §3.3，本轮未动 |
| 中 | 触底阈值 240 px | 短列表可能一进页面就触发一次自动同步；未真机观感 |
| 中 | 自动同步力度 | 每触底一次最多 2 页（`syncChannel` 默认），大频道要多次；是否改成"直到填满一屏"需真机手感决定 |
| 低 | `goToMessage` 最多翻 5 页 | 目标消息更靠后时返回 false，界面停在当前条（不假装成功） |
| 低 | iOS 15 方向路径仍依赖非公开 KVC | 第 3 步已记录，本轮无新增风险 |

---

## 8. 下一步

1. 装桌面上的 `TGMediaProbe-unsigned-fix.ipa`，先做 §6.4（锁：锁坏了别的都测不了），再做 §6.1（记录触底三次的数字）。
2. 触底仍不增长时，抓 `from_message_id` 序列与 `rawMessageCount`：若游标单调下降而条数不变，说明是筛选条件问题；若游标不动，说明 TDLib 侧语义与假设不同。
3. 方向若仍异常，先确认 `AppDelegate.supportedInterfaceOrientationsFor` 是否被调用（加日志或断点），再判断是 Dart 层还是 UIKit 层。
4. 第 5 步不动。
