# 第 4 步报告：抖音式视频体验、设置页与应用锁

生成时间：2026-10-26 20:45 (GMT+8)
提交：`3cb262e`（功能，含只读守卫修复）+ `efe48f4`（测试）+ `02dbea5`（文档）
CI：run [40311608168](https://github.com/1585365426/tg-media-probe/actions/runs/40311608168) — **success，6m35s**
配套检查报告：`docs/STEP4-CI-CHECK.md`（规范 §11/§12 现状、报告格式分析、守卫清单与两类问题诊断）

---

## 0. 状态口径（互不替代）

| 状态 | 结论 |
|---|---|
| 代码已编写 | ✅ 14 个新模块 + 6 个新测试文件，共 5,606 行实现、2,522 行测试 |
| 静态检查通过 | ✅ `flutter analyze` → No issues found（本机 + CI 各一次） |
| 自动化测试通过 | ✅ 548 项：547 passed / 1 skipped（skip = 本机无 TDLib 二进制），本机与 CI 数字一致 |
| iOS 包构建成功 | ✅ Xcode 26.6 / Swift 6.3.3 / iOS SDK 26.5 |
| IPA 生成 + 哈希复核 | ✅ 19,760,196 B，sha256 `61c415cd…5820df1` |
| IPA 装到 iPhone | ❌ 未执行 |
| Face ID / 密码解锁（真机） | ❌ 未验证（仅决策层与控制器单测） |
| 横屏旋转（真机） | ❌ 未验证（Dart 层验证 + 原生桥已编译进包） |
| 100 次连续切换（真机） | ❌ 未验证（Dart 层压测通过） |
| Telegram 登录 / 频道 / 播放（真实数据） | ❌ 未验证（本机到 Telegram 不通） |

---

## 1. 新增 / 修改文件清单

### 新增：应用层（`lib/app/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `app_preferences.dart` | 230 | `ThemePreference`/`FeedDirection`/`AppPreferences`、`PreferencesStore`（Keychain slot `tg_app_prefs_v1`）、`PreferencesController`；显式不含 onlyWifi 与长按字段 |
| `app_root.dart` | 331 | `TgMediaApp` 启动顺序（偏好 → 锁 → 路径 → 会话）、`MaterialApp` 主题三档、`AppShell` 三 Tab `IndexedStack` |
| `app_session.dart` | 591 | `AppRoute` 路由纯函数、启动决策 `SessionBootPlanner`、TDLib 单实例打开、登录阶段映射、退出登录、诊断导出 |

### 新增：界面（`lib/ui/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `app_theme.dart` | 115 | §6.3 字号与间距 token：正文 15 / 次要 13 / 标题 17、`pagePadding=16`、`cardRadius=12`、`minTouchTarget=44` |
| `status_view.dart` | 261 | 五态 `StatusView`、`SettingsSection`/`SettingsRow`/`SettingsDivider`；`showChevron` 只在真有导航时出现 |
| `login_page.dart` | 352 | 按 `LoginPhase` 分支；邮箱/注册/付费等阶段明示"请在 Telegram 官方客户端完成"，不伪造输入框 |
| `settings_page.dart` | 753 | 五分组全部接真实状态；Face ID 无密码时置灰；存储盘点与清理；诊断导出前二次脱敏校验 |
| `feed_controller.dart` | 517 | `FeedController` 分页与前缀、`LatestOnlySlot` 代次校验、`shouldSwitchPage` 阈值、`FeedOverlayPlan.forOrientation` |
| `feed_page.dart` | 641 | 三层叠加（顶栏 / 底部信息区 / 控制层）、单击与双击手势（长按不绑）、横屏切换后验证实际方向 |
| `channel_pages.dart` | 444 | 频道列表（下拉刷新 + 本地搜索 + 计数）、频道详情（`MediaPager` 30 条分页 + 显式同步按钮） |

### 新增：应用锁（`lib/lock/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `unlock_controller.dart` | 330 | `UnlockPhase` 七态、`start/reloadSettings/promptBiometric/submitPasscode/onPaused/onResumed/beginRecovery`、冷却计时 |
| `lock_screens.dart` | 391 | 解锁页（自动提示一次 + 密码框常驻 + 忘记密码入口）、密码设置页、恢复确认 |

### 新增：播放与数据

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib/playback/video_source.dart` | 224 | `VideoSourceResolver`：先 `stat` 命中则零传输，否则订阅 `updateFile` 后 `start`，15 秒超时即 `cancel` 并抛 `VideoSourceTimeout` |
| `lib/data/channel_directory.dart` | 251 | `TdChatSource`（`getChats`→`getChat`→过滤频道）、本地缓存 JSON 原子写、`search()` 纯本地过滤 |

### 修改

| 文件 | 变更 |
|---|---|
| `lib/main.dart` | 收窄到 30 行以下：只做 `ensureInitialized` + `runApp` |
| `lib/security/td_readonly_guard.dart` | 136 → 195 行：新增 23 项 `readOnlyMethods` 正面清单、`isAllowed()`、未知方法拒绝分支、`TdReadOnlyViolation.reason` |
| `lib/security/lock_policy.dart` | `afterOutcome` 把 `BiometricOutcome.userFallback` 归入 `passcodeOnly`（用户点"使用应用密码"是决定，不是取消） |
| `lib/data/index_store.dart` | 新增 `countByChat({videosOnly})`，一趟 O(rows) 得到每频道视频数 |
| `lib/td/td_models.dart` | 新增 `AccountInfo`（`displayName`/`handle`/`maskedPhone`）+ `accountFromResponse()` |
| `lib/playback/player_slot.dart` | 新增 `PlayerProgress`/`PlayerVolume`/`PlayerSeek` 三个可选能力接口，不破坏既有替身 |
| `lib/playback/video_player_handle.dart` | 实现上述能力：`setVolume`/`seekTo` |

### 新增测试

`test/app_preferences_test.dart`(188) · `test/unlock_controller_test.dart`(502) · `test/feed_controller_test.dart`(663) · `test/video_source_test.dart`(195) · `test/channel_directory_test.dart`(350) · `test/security_negative_test.dart`(624)

---

## 2. 代码逻辑简述

**门禁顺序**：`TgMediaApp._bootstrap()` 依次 `preferences.load()` → `lock.start()` → `AppPaths.resolveLayout()` → `AppSession.boot()`。会话启动不被 await 阻塞，解锁页先出；`AppRoute` 由 `SessionStage` 单值决定，锁定时不构建频道标题。

**锁的决策与执行分离**：`LockEvaluator.decide()` 是纯函数（设置 + 冷启动 + 后台时长 + 传感器能力 → `LockRequirement`），`UnlockController` 只负责时序与文案。无真机时靠枚举矩阵覆盖，不靠"跑一遍看看"。

**视频源**：`resolve()` 先 `stat`，文件已在盘上则零传输直接 ready；否则订阅 `updateFile` 再 `start`，`completion.future.timeout(15s)` 超时 → `cancel` + `VideoSourceTimeout`（文案写明 15 秒上限，不吞成通用错误）。

**切换不留旧画面**：`FeedController` 每次切换自增代次，`LatestOnlySlot` 拒绝旧代次结果；`SinglePlayerController` 先 pause+dispose 旧实例再建新的，`liveCount` 恒 ≤ 1。

**横屏**：`_toggleLandscape()` 请求旋转 → 等 400ms → 用 `MediaQuery.of(context).orientation` **验证是否真转了**，没转就提示"系统方向锁已开启"，不假装成功。

**频道目录**：缓存写 `.tmp` 再 rename；刷新失败保留旧列表（错误横幅 + 旧内容优于空屏）；`videoCount == null` 显示"统计中"，绝不用 0 冒充。

---

## 3. 三 Tab 与播放叠加层结构

```
AppShell (IndexedStack + CupertinoTabBar)
├── Tab 1 频道   ChannelListPage ──> ChannelDetailPage ──> MediaPager(30/页)
├── Tab 2 抖音   FeedPage（首次访问才构建）
│     ├── 顶栏        返回 / 标题 / 搜索   ← 横屏也保留
│     ├── 底部信息区  频道名 + 描述        ← 横屏隐藏（FeedOverlayPlan.showInfo=false）
│     └── 控制层      播放暂停 / 进度 / 静音 / 转屏  ← 默认隐藏，横屏仍可调出
└── Tab 3 设置   账号 · 隐私与安全 · 存储 · 外观与播放 · 关于
```

手势只有两个：单击切控制层、双击播放/暂停。长按**没有绑定任何回访**，也不存在被其它手势抢占的路径。

---

## 4. 安全防护实现说明

**本轮修掉的真实缺陷：只读守卫只查黑名单**

- 承诺（`td_readonly_guard.dart` 旧注释）："未知方法名同样拒绝——新 TDLib 方法必须先被显式分类。"
- 实际（修复前）：只做 `type is! String || isEmpty` 与 `cloudMutatingMethods.contains(type)` 两项检查，**任何未分类方法一律放行**。
- 证明：新增回归测试 `security_negative_test.dart` 第 9 组「an unclassified method name is rejected」修复前失败（`Expected: throws … Actual: returned <null>`）。
- 最小修复：新增 23 项正面清单 `readOnlyMethods`（读 + 会话/登录所需 + 本地传输方法），`assertAllowed` 增加 `!isAllowed(type)` 分支拒绝未分类方法；`TdReadOnlyViolation` 增加 `reason`，未分类与已知写方法文案分开。
- 修复后的证明：`cloudMutatingMethods`(64) 与 `readOnlyMethods`∪`localOnlyMethods`(23+8) 交集为空（测试断言）；`deleteMessages`/`sendMessage`/`joinChat` 等逐个被拒；`someNewMethodFromAFutureTdlib` 被拒；`td_requests.dart` 里能构造的每个 `@type` 都在清单内（源码扫描，防止改完守卫把登录打挂）。

`localOnlyMethods` 新增 `downloadFile` / `cancelDownloadFile` 两项 —— 它们修复前就是放行的（黑名单不含它们），本次只是把既有行为写清楚，不是放宽。

**十个负向用例**（`test/security_negative_test.dart`，32 个断言组成 10 组）

| # | 场景 | 断言要点 |
|---|---|---|
| 1 | 越界删除 | 下载区文件、`..` 穿越、区外路径、区域根本身 → 全部 `ZoneViolation`；清理照样不删下载文件 |
| 2 | 符号链接逃逸 | 临时区内的链接指向下载区 → 链接本身被拒，目标文件仍在 |
| 3 | 未登记目录 | `tdlib_files/` 与任意新目录不在扫描范围，清理后原样存在 |
| 4 | 占用中文件 | 标记中的文件跳过，字节不计入释放；双持有者需两次 release |
| 5 | 假成功 | 删除无效的替身 → `deletedFiles=0`、`failures` 记「still present」；索引计数变化 → `integrityPreserved=false`、`succeeded=false`；未确认 → 抛 `CacheClearNotConfirmed` |
| 6 | Keychain 缺 key | 空库 → 无锁；缺失 verifier → `verifyPasscode` 返回 false；只有生物识别位无密码 → 判定不索取任何因子（不锁死用户） |
| 7 | 密码记录被改 | 翻转 1 个 hex、截断、换 scheme → 全部 false，不抛异常 |
| 8 | 诊断未脱敏 | 原始载荷触发 `mayContainSecret`；脱敏后 api_hash / dbkey / bot token / 手机号 / passcode record 全部消失，保留非敏感字段 |
| 9 | 只读守卫 | 已知写方法、未分类方法、null、空串全部拒绝 |
| 10 | 不碰受保护区 | 下载/索引/授权文件清理后逐字节仍在；用记录型 ops 证明清理从未遍历受保护区；`usage()` 默认对受保护区返回 -1（未测量） |

---

## 5. 单元测试执行结果

本机（Windows 11 / Flutter 3.47.8 / Dart 3.13.7）与 CI runner 结果一致：

```
00:50 +548 ~1: All tests passed!
```

| 测试文件 | 通过 | 覆盖点 |
|---|---|---|
| `app_preferences_test.dart` | 15 | 三档主题映射；方向两档；写失败不改内存值；重启后恢复；**断言持久化键里没有 wifi / longpress** |
| `unlock_controller_test.dart` | 39 | 冷启动/后台/自动锁四档延迟矩阵；Face ID 默认关闭；无密码不得开 Face ID；`userFallback` → 密码框；生物识别失败文案不写成"密码错误"；冷却递增与到期；忘记密码重置清锁并触发会话清理；暂停/恢复重锁；`isLocked` 只在解锁成立时变 false |
| `feed_controller_test.dart` | 31 | 首屏加载；翻页补空页；一页全是照片不当作有内容；播放/暂停/进度/静音；**100 次切换：created−disposed=1，live=1**；过期解析丢弃；超时与解码失败；生命周期释放；搜索入口状态保留；横屏隐藏信息区但保留控制层 |
| `video_source_test.dart` | 9 | 已在盘零传输；缺失则取回；`probing→fetching→ready`；超时取消且文案写明 15 秒；TDLib 错误透传；他人 file id 的更新被忽略；cancel 后迟到完成被拒；进度夹到 0..1 |
| `channel_directory_test.dart` | 23 | 成功/空/失败三态；失败保留旧列表；刷新保留计数；计数未知为 null 不显示 0；搜索大小写与用户名匹配且**零网络调用**；缓存原子写无 `.tmp` 残留；损坏缓存忽略；受保护内容标记往返 |
| `security_negative_test.dart` | 32 | 见 §4 十项 |
| 既有测试 | 399 | 与第 3 步基线一致（含 1 skip） |

合计新增 149 项，无既有用例被删除或放宽。

---

## 6. 设置 / 锁 / 视频 / 频道自测结果

| 项 | 结果 | 依据 |
|---|---|---|
| 设置持久化 | ✅ 逻辑 | 15 项；写失败不改内存值 |
| 密码验证 | ✅ 逻辑 | PBKDF2 记录自带 iterations/salt；错密码、空记录、损坏记录均 false |
| Face ID 默认关闭 | ✅ 逻辑 + 源码 | `AppLockSettings.initial.biometricEnabled=false`；设置页开关初始为关 |
| 无密码不得开启 Face ID | ✅ 逻辑 + UI | `withBiometrics()` 无密码时原样返回；设置页该行 `enabled:false` + 「请先设置应用解锁密码」 |
| 忘记密码重置 | ✅ 逻辑 / ⚠️ 真机 | 重置只改锁字段，另走 `resetThroughTelegram()` 清本地会话；真实 TDLib 登出未跑 |
| 缓存白名单 | ✅ | 四个 writer（thumb/player/partial/tdlib_files）之外的路径跳过并报告 |
| 会话状态恢复 | ✅ 逻辑 / ⚠️ 真机 | `SessionBootPlanner` 矩阵 + 频道缓存冷启动；真实 `td.binlog` 恢复未跑 |
| 视频控制 | ✅ 逻辑 / ⚠️ 真机 | 播放/暂停/seek/静音/进度；真机解码未看 |
| 搜索状态 | ✅ | 频道目录与频道选择器本地过滤；清空回到全量；零网络调用 |
| 方向状态 | ✅ 逻辑 / ⚠️ 真机 | 旋转后校验实际方向，未转则提示系统方向锁；真机未旋 |
| 生命周期 | ✅ 逻辑 | 前后台/切 Tab/内存警告均释放播放器；锁页暂停计时与恢复 |
| 10 项安全负向 | ✅ | §4 表 |
| 100 次连续切换 | ✅ 逻辑 / ⚠️ 真机 | Dart 层 live=1、峰值 1；真机未压 |

---

## 7. 现存风险与未解决问题

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 真机行为全部未验证 | Face ID、横屏、100 次真机切换、沙盒缓存清理、IPA 安装均未在 iPhone 上跑 |
| 高 | 真实 TDLib 数据链路未验证 | 本机到 Telegram 不通，频道/视频/播放只到接口层 |
| 中 | `requestGeometryUpdate` 与 `UIDevice.setValue` 分支未真机确认 | 已编译进包；iOS 16+ 走公开 API，iOS 15 走非公开键（第 3 步已记录同一风险） |
| 中 | 频道目录缓存不含计数 | 冷启动先显示"统计中"，`countByChat()` 到位后才有数字（一帧内的两段状态） |
| 中 | 抖音页首次访问才构建 | 首帧进入 Tab 2 有一次构建延迟，未在真机测量 |
| 低 | 设置页存储盘点同步遍历临时区 | 文件多时有短暂卡顿风险（未实测） |
| 低 | `FeedOverlayPlan` 只按方向判断 | 平板分屏等非常规窗口尺寸未覆盖 |

未验证清单一律没有标成通过。

---

## 附：CI 与产物

```
run 40311608168  success  6m35s（10:59:07Z → 11:05:42Z）
head  efe48f4d8e292353303868fe8ed8ab5fe8abf192
runner: macOS 26.6.2 arm64 · Xcode 26.6 (17F113) · Swift 6.3.3 · iOS SDK 26.5 · CocoaPods 1.17.0
steps:  TDLib 校验 → analyze(No issues) → test(547+1skip) → pod install → xcodebuild
        → 符号校验 → IPA 打包 → 上传产物 → 发布 ci-report 分支
IPA:    TGMediaProbe-unsigned.ipa  19,760,196 B
sha256: 61c415cdcb6efa4327ef97bd125f099469411e463b0aa0b0f03a7ceef5820df1
minos 15.2 · bundle com.tgmedia.tgMediaProbe · arm64
TDLib  1.8.69 静态链接（ar archive，无需内嵌）
本地:   flutter analyze → No issues found；flutter test → 548 passed / 1 skipped
```
