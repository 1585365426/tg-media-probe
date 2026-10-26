# 第 4 步最终报告：抖音式视频体验、设置页与应用锁

生成时间：2026-10-26 21:40 (GMT+8)
提交：`3cb262e`（功能 + 只读守卫修复）· `efe48f4`（149 项测试）· `02dbea5`/`dd96a98`（文档）· `e8f59e4`（删下载 + 失败分类）· `cc4a1d7`（CI 打印精确 IPA 字节）
CI：run [40330720156](https://github.com/1585365426/tg-media-probe/actions/runs/40330720156) — **success，7m51s**
head：`cc4a1d79a5b6ef1b228d6af28731e5cef6df563a`

---

## 0. 状态口径（互不替代）

| 状态 | 结论 |
|---|---|
| 代码已编写 | ✅ 15 个新模块 + 7 个测试文件；lib 新增 5,899 行、删除 394 行（含删除 4 个下载文件），测试新增 2,746 行 |
| 静态检查通过 | ✅ 本机 `flutter analyze` → No issues found；CI step 13 Analyze success |
| 自动化测试通过 | ✅ 581 passed / 1 skipped（共 582 项；补强前为 539），本机 `00:41` 与 CI `01:05` 数字一致 |
| iOS 包构建成功 | ✅ Xcode 26.6 / Swift 6.3.3 / iOS SDK 26.5 / CocoaPods 1.17.0 |
| IPA 生成 + 哈希 | ✅ 19,780,011 B，sha256 `8604b99d…18ef2`（`wc -c` 精确值，非 `ls -lh` 的四舍五入） |
| 只读守卫缺陷修复 | ✅ 已修并推入 `3cb262e`，含 3 条新增回归用例 |
| 六态走查（代码层） | ✅ 6 个页面 × 6 状态，见 §5 |
| 下载代码清理 | ✅ 按依赖地图步骤 2 执行，步骤 3 明确不做，见 §4 |
| IPA 装到 iPhone | ❌ 未执行 |
| 真机 Face ID / 横屏 / 100 次切换 / 重启恢复 | ❌ 未验证（0 项通过，见 §8） |
| 真实 TDLib 数据链路（第 4 步 UI） | ❌ 未验证（本机到 Telegram 不通） |

---

## 1. 新增 / 修改 / 删除文件清单

### 新增（`lib/`，15 个文件）

| 文件 | 行数 | 职责 |
|---|---|---|
| `app/app_preferences.dart` | 230 | 主题三档、方向两档、静音、预加载；Keychain slot `tg_app_prefs_v1`；显式不含 onlyWifi 与长按字段 |
| `app/app_root.dart` | 331 | 启动顺序（偏好 → 锁 → 路径 → 会话）、三 Tab `IndexedStack`、路由分发 |
| `app/app_session.dart` | 591 | `AppRoute` 纯函数、`SessionBootPlanner`、TDLib 单实例、登录阶段映射、退出登录、诊断导出 |
| `data/channel_directory.dart` | 267 | `getChats`→`getChat`→过滤频道、JSON 原子缓存、本地搜索、**失败类型** |
| `lock/unlock_controller.dart` | 330 | `UnlockPhase` 七态、生物识别时序、冷却计时、恢复流程 |
| `lock/lock_screens.dart` | 391 | 解锁页、密码设置页、恢复确认 |
| `playback/video_source.dart` | 224 | `VideoSourceResolver`：先 `stat`，否则订阅后 `start`，15 秒超时即 `cancel` |
| `ui/app_theme.dart` | 115 | §6.3 字号与间距 token |
| `ui/status_view.dart` | 305 | 五态 `StatusView` + **`FailureView`**（按失败原因选文案、决定是否给重试）+ 设置页分组 |
| `ui/login_page.dart` | 352 | 按 `LoginPhase` 分支，邮箱/注册/付费明示在官方客户端完成 |
| `ui/settings_page.dart` | 753 | 五分组接真实状态；Face ID 无密码置灰；存储盘点与清理；导出前二次脱敏 |
| `ui/feed_controller.dart` | 526 | 分页、`LatestOnlySlot` 代次校验、`shouldSwitchPage` 阈值、`FeedOverlayPlan`、失败类型 |
| `ui/feed_page.dart` | 640 | 三层叠加、单击/双击手势、横屏旋转后验证实际方向 |
| `ui/channel_pages.dart` | 452 | 频道列表（刷新 + 本地搜索 + 计数）、频道详情（30 条分页 + 同步按钮） |
| `td/td_error_kind.dart` | 154 | **新增**：把 TDLib 错误码/文案分类成 permission / sessionExpired / rateLimited / offline / generic，并决定是否可重试 |

### 删除（4 个文件，第 4 步 E）

`lib/storage/download_mover.dart`（164 行）· `lib/storage/download_paths.dart`（138 行）· `test/download_mover_test.dart` · `test/download_paths_test.dart`

### 修改

| 文件 | 变更 |
|---|---|
| `lib/td/media_probe.dart` | 删 `DownloadMover`、删第 8 步、步骤 9→8、`localPath` 改为 TDLib 池内路径、加空路径与大小一致性检查 |
| `lib/ui/probe_page.dart` | 删「用户下载区（受保护）」一行与随之无用的 `_layout` 字段 |
| `lib/security/td_readonly_guard.dart` | 136 → 195 行：加 23 项正面清单、`isAllowed()`、未分类方法拒绝分支、`Violation.reason` |
| `lib/security/lock_policy.dart` | `userFallback` 归入 `passcodeOnly`（用户选「使用应用密码」是决定，不是取消） |
| `lib/storage/storage_layout.dart` | `userDownloads` 注释从「download screen」改为「Files app」 |
| `lib/data/index_store.dart` | 新增 `countByChat({videosOnly})` |
| `lib/td/td_models.dart` | 新增 `AccountInfo` + `accountFromResponse()` |
| `lib/playback/player_slot.dart` · `video_player_handle.dart` | 三个可选能力接口 + `setVolume`/`seekTo` |
| `lib/main.dart` | 收窄到 28 行 |
| `scripts/make_unsigned_ipa.sh` | 打印 `ipa_bytes`（此前报告把 artifact zip 体积当成 IPA 体积） |

---

## 2. 五项设计决策的一致性核对

三处来源逐一比对：`docs/PRODUCT-SPEC.md`（规范）↔ `docs/STEP4-REPORT.md`（本文件）↔ `lib/`（代码）。

| # | 决策 | 规范 | 代码 | 测试 | 结论 |
|---|---|---|---|---|---|
| 1 | 不加「仅 Wi-Fi 播放」开关 | §11 第 1 项「不加」；§5.4 已删该行并注明理由 | `app_preferences.dart` 持久化键里没有 wifi 字段 | `app_preferences_test` 断言键名既不含 `wifi` 也不含 `longpress` | 一致 |
| 2 | 长按无操作 | §4.2 手势表已改为「长按｜无操作」 | `feed_page.dart` 只绑 `onTap` 与 `onDoubleTap`；全文件 `grep onLongPress` 零命中 | 手势相关用例在 `feed_controller_test` 的播放/暂停组 | 一致（原报告把「回调」写成「回访」，已改） |
| 3 | 抖音页保留顶部搜索 | §11 第 3 项「保留，且为本地搜索」 | `feed_page.dart` 顶栏含搜索；`ChannelDirectory.search()` 纯本地 | `channel_directory_test` 断言搜索零网络调用 | 一致 |
| 4 | 横屏隐藏底部信息区 | §11 第 4 项「隐藏，控制层仍可调出」 | `FeedOverlayPlan.forOrientation()`：`showInfo=false`、`showControls=true` | `feed_controller_test` 横屏用例 | 一致 |
| 5 | 忘记密码重置清除本地会话 | §11 第 5 项「不允许保留会话」 | `UnlockController.beginRecovery()` + `AppSession.resetThroughTelegram()` | `unlock_controller_test` 恢复流程组 | 一致 |

**核对中改掉的三处不一致**（本轮修，不是上一轮就有）：

1. 规范 §5.4 还留着「仅 Wi-Fi 播放｜待确认（见 §11）」，与 §11 的「不加」自相矛盾 → 删行并写明不提供。
2. 规范 §12 阶段 E 原写「下载代码删除（第 3 步已完成主体）」，而 `DOWNLOAD-DEPENDENCY-MAP.md` §5 明确记录第 3 步一项都没删 → 改为第 4 步实际执行的记录。
3. 本报告 §0 原写「548 项：547 passed」，`flutter test` 的 `+548 ~1` 是 548 通过 + 1 跳过（共 549） → 已改；同段「5,606 行」实测为 5,899 行新增。

---

## 3. 只读守卫修复记录的一致性

同一件事在四个地方出现过，数字必须一致——实测一致：

| 位置 | 表述 | 实测 |
|---|---|---|
| `lib/security/td_readonly_guard.dart:178` | `assertAllowed` 三张清单：黑名单 64、只读 23、本地专用 8；未分类一律拒绝 | 一致（`:41` 64 项、`:136` 23 项、`:114` 8 项） |
| 规范 §4 | 「三张清单…未出现在任何清单里的方法一律拒绝…登录登出类是有意例外」 | 一致 |
| 规范 §10 v3 | 「§4 只读守卫补强：`assertAllowed` 增加正面清单，未分类方法一律拒绝（原先只查黑名单）」 | 一致 |
| 本报告 §6 | 修复前后行为、证明用例、最小修复范围 | 一致 |

守卫行为的三条硬约束（全部有测试）：

1. 三张清单交集为空 —— `security_negative_test` 第 9 组。
2. `someNewMethodFromAFutureTdlib` 必抛 —— 同上。
3. `td_requests.dart` 里每个 `@type` 都在白名单内 —— 同上（源码扫描，防止把登录打挂）。

`logOut` / 登录类 7 个方法会改服务端状态，列在白名单是**有意例外**：没有它们无法登录、无法退出，且只在用户显式操作时调用。规范 §4 与 `STEP4-CI-CHECK.md` §3.3 都写了这条，不藏。

---

## 4. 下载相关代码检查

按 `docs/DOWNLOAD-DEPENDENCY-MAP.md` 逐条核对，两个概念先分开：

| 概念 | TDLib 方法 / 模块 | 本轮处理 | 依据 |
|---|---|---|---|
| 播放器拉取媒体字节 | `td_requests.downloadFile`（`:133`） | **保留** | 删了就没有视频，所有条目会永远停在「正在准备视频」 |
| 用户主动保存文件 | `download_mover.promote()` → `Documents/TGMediaDownloads` | **删除** | 第 3 步已取消该功能；播放链路早已改走 `VideoSourceResolver`，不经过 Documents |
| 拉流速度测量 | `download_metrics.dart` | 保留 | 测的是 TDLib 拉流速度，与下载按钮无关 |
| 播放中文件登记 | `storage/active_files.dart` | 保留 | 防止缓存清理删掉正在播的文件 |
| 受保护区枚举 | `StorageZone.userDownloads` | **保留** | 它是安全判定的一部分（`assertDeletableByCacheClear` 与清理测试靠它验证受保护区），不是功能开关 |

删除后的五项验证（真实输出）：

```
grep -rn "download_mover|download_paths|DownloadMover" lib/ test/   → clean
grep -rn "'@type': 'downloadFile'" lib/td/td_requests.dart         → 133: '@type': 'downloadFile'
grep -rn "deleteMessages|sendMessage|editMessage" lib/             → 只命中 td_readonly_guard 黑名单字符串
flutter analyze                                                    → No issues found!
flutter test                                                       → 539 passed / 1 skipped（提交 e8f59e4 时）
```

**改播放路径这一动作不是本轮做的，但没有漏**：第 4 步的 `VideoSourceResolver` 本来就直接读 TDLib 池内路径，从不写 `Documents`。所以依赖地图里「步骤 1 必须先在真机验证播放 30 秒不被 TDLib 回收」这条前置条件，对本轮的删除不构成阻塞——被删的 `promote()` 不在播放链路上。TDLib 池被 LRU 回收的风险仍在，记在 §9。

---

## 5. 六种状态走查（6 页 × 6 态）

「重试」列写的是**按钮在什么条件下出现**，不是「有没有按钮」——权限不足与登录失效这两态故意不给重试按钮，因为按了必然再失败。

| 页面 | 加载 | 空 | 错误 | 重试 | 权限不足 | 登录失效 |
|---|---|---|---|---|---|---|
| 频道列表 | `channel_pages.dart:114`（索引未打开）、`:129`（读取中） | `:141` 账号无频道 +「刷新」；`:149` 搜索无匹配（靠清空搜索恢复，不给重试） | `:134` `FailureView` | 仅 `isRetryable` 时给按钮，`onRetry=refreshDirectory` | `failure=permissionDenied` → 锁图标 +「当前账号不是该频道的成员…」，无按钮 | `failure=sessionExpired` → `signedOut` 视图；同时路由层 `app_root.dart:176` 直接把壳换成登录页 |
| 频道详情 | `:326` | `:336`「该频道没有可播放的视频」+「同步更多」 | `:329` `FailureView` | 同上，`onRetry=_syncMore` | 分类同左 | 路由切走 |
| 抖音页 | `feed_page.dart:204` | `:206` +「刷新」 | `:213` `FailureView` | `controller.retry`，仅可重试类显示 | `VideoSourceException` 分类为 permission → 锁图标 | 路由切走 |
| 设置页 | `settings_page.dart:239`「正在盘点…」 | 不适用（分组始终有行） | `:434` 清理失败 SnackBar、`:751` 通用 SnackBar | 用户再次点按（不加独立按钮） | 不适用（只读本地状态） | 账号区显示未登录；路由切走 |
| 登录页 | `login_page.dart:114/119/243/259` | 不适用 | `:86`（会话重建失败）、`:106`、`:269` | 「重新检查」`:214/225/236`、「重试」`:106` | `:222/:233` 邮箱与注册阶段：明示须在 Telegram 官方客户端完成，不伪造输入框 | `:249` `StatusKind.signedOut` +「重新登录」 |
| 解锁页 | `UnlockPhase.checking` | 不适用 | 内联提示（`_message`，生物识别失败不写成「密码错误」） | 重新输入密码 | 不适用（锁在会话之前，读不到任何会话状态） | 不适用（同上） |

**走查中发现的真实缺口（本轮已修）**：三个数据页原本只有「加载 / 空 / 通用错误 + 重试」，`StatusKind.permission` 与 `signedOut` 只在登录页用过。也就是说频道被禁、会话被吊销时，用户看到的是「读取失败」加一个必然失败的重试按钮。修法：

- 新增 `lib/td/td_error_kind.dart`：401/`AUTH_KEY_*` → 登录失效；403/`CHAT_FORBIDDEN`/`CHANNEL_PRIVATE` → 权限不足；429/`FLOOD_WAIT` → 频率限制；超时/Socket → 离线；其余 → 通用。判定先看码再看文案（文案会随版本变）。
- 目录、频道详情、抖音控制器各带一个 `RequestFailure`；新增 `FailureView` 统一渲染，**不可重试的类型不渲染按钮**。
- 新增测试 26 项（`td_error_kind_test` 22 + 目录失败分类 4）。

**这一节能证明什么、不能证明什么**：能证明每个状态在代码里有独立分支、文案不同、按钮策略不同，且有单元测试锁住状态机。**不能**证明渲染出来的样子——没有 widget 测试、没有截图、没有真机。这一栏在 §8 计为未验证。

---

## 6. 安全负向用例（10 项，32 个断言）

| # | 场景 | 断言要点 |
|---|---|---|
| 1 | 越界删除 | 下载区文件、`..` 穿越、区外路径、区根本身 → 全部 `ZoneViolation`；清理照样不删下载文件 |
| 2 | 符号链接逃逸 | 临时区内的链接指向下载区 → 链接被拒，目标文件仍在 |
| 3 | 未登记目录 | `tdlib_files/` 与任意新目录不在扫描范围，清理后原样存在 |
| 4 | 占用中文件 | 标记中的文件跳过、字节不计入释放；双持有者需两次 release |
| 5 | 假成功 | 删除无效 → `deletedFiles=0` + `failures`；索引计数变化 → `integrityPreserved=false`；未确认 → 抛 `CacheClearNotConfirmed` |
| 6 | Keychain 缺 key | 空库 → 无锁；缺 verifier → `verifyPasscode` 返回 false；只有生物识别位无密码 → 不锁死用户 |
| 7 | 密码记录被改 | 翻转 1 个 hex / 截断 / 换 scheme → 全部 false，不抛异常 |
| 8 | 诊断未脱敏 | 原始载荷触发 `mayContainSecret`；脱敏后 api_hash / dbkey / token / 手机号全消失 |
| 9 | 只读守卫 | 已知写方法、未分类方法、`null`、空串全部拒绝；三清单交集为空；`td_requests.dart` 全部方法在册 |
| 10 | 不碰受保护区 | 下载/索引/授权文件清理后逐字节仍在；记录型 ops 证明清理从未遍历受保护区 |

---

## 7. 自动化测试执行结果

本机（Windows 11 / Flutter 3.47.8 / Dart 3.13.7）与 CI runner：

```
本机  00:41 +581 ~1: All tests passed!
CI    01:05 +581 ~1: All tests passed!
```

| 测试文件 | 通过 | 覆盖点 |
|---|---|---|
| `app_preferences_test.dart` | 15 | 三档主题、方向两档、写失败不改内存值、重启恢复、键名里没有 wifi / longpress |
| `unlock_controller_test.dart` | 39 | 冷启动/后台/自动锁矩阵；Face ID 默认关；无密码不得开；`userFallback`→密码；冷却递增；恢复清会话 |
| `feed_controller_test.dart` | 31 | 首屏、翻页补空页、全照片页不当作有内容、**100 次切换 live=1**、过期解析丢弃、超时/解码失败、生命周期、搜索与横屏 |
| `video_source_test.dart` | 9 | 已在盘零传输、取回、三阶段进度、超时取消且文案写明 15 秒、TDLib 错误透传、他人 fileId 忽略 |
| `channel_directory_test.dart` | 27 | 三态 + 失败保留旧列表 + 计数未知为 null + 搜索零网络 + 原子写 + **失败分类 4 项** |
| `td_error_kind_test.dart` | 22 | 401/403/420/429/400 分类、session 优先于 permission、Timeout/Socket→offline、可实现重试矩阵、文案非空 |
| `security_negative_test.dart` | 32 | §6 十项 |
| `readonly_guard_test.dart` | 9 | 源码零命中、单一出口、64 个写方法逐个被拒、13 个真实请求放行、坏 `@type` |
| `readonly_boundary_test.dart` | 12 | 补强新增：守卫唯一出口、假 bindings 零发送、7 个会话方法放行、近似名字被拒 |
| `failure_view_test.dart` | 9 | 补强新增：五态文案、权限/登录失效无重试按钮、可重试无回调不渲染按钮 |
| `tdlib_storage_test.dart` | 9 | 补强新增：数据库在受保护区、清理不动库、字节只计真删 |
| `no_user_download_test.dart` | 4 | 补强新增：下载回潮防护 + 播放入口仍在 |
| 其余既有测试 | 355 | 与第 3 步基线同源，无一删除、无一放宽 |

合计 581 passed / 1 skipped（1 skip = 本机无 TDLib 二进制）。数字脉络：548（第 4 步主体）→ 删 35 项下载测试、加 26 项后 539 → 验收补强新增 42 项（12+9+9+4+3+5）→ 581。

---

## 8. 真机测试记录

**本轮未执行任何真机测试。下表没有一项标为通过。**

| 项目 | 结果 | 说明 |
|---|---|---|
| IPA 安装（TrollStore） | ❌ 未执行 | 产物未下载到设备 |
| Face ID 弹窗 / 取消 / 回退密码 / 无密码置灰 | ❌ 未验证 | 只有控制器与策略层单测 |
| 横屏旋转 + 系统方向锁提示 | ❌ 未验证 | 原生桥已编译进包，未在设备上触发 |
| 100 次真机连续切换 | ❌ 未验证 | Dart 层压测 `live=1`，AVPlayer 真实释放未看 |
| 重启后锁状态与 Telegram 会话恢复 | ❌ 未验证 | 依赖 Keychain 与 `td.binlog` |
| 真实账号的频道 / 视频 / 播放 | ❌ 未验证 | 本机到 Telegram 不通 |
| 六态 × 每页的真机走查 | ❌ 未验证 | 只做了代码层走查（§5） |
| 缓存清理在真实沙盒路径下 | ❌ 未验证 | 单测用临时 sandbox 跑同一代码路径 |

**仓库里唯一的真机证据是第 2 步的**：`docs/DEVICE-EVIDENCE-20261026.md`，run `40213205595` 的 IPA（19,451,233 B，sha256 `1a83e39b…`），记录 10 项链路判定，其中 AVPlayer 初始化通过、实际出帧/音轨/seek 未证明。那个包**不含第 4 步任何代码**（无锁、无设置页、无抖音页），因此不能当作第 4 步的证据。它同时留下两条待办：TDLib `files_directory` 落在 `Documents/tdlib/files`（不在四区隔离内）、数据库加密键的空值问题——这两条在第 4 步的代码里已改为加密键 + 池路径，但**同样没有在真机上复测**。

---

## 9. 现存风险与未解决问题

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 真机零验证 | §8 全部未执行。UI 层的一切结论来自代码阅读与单元测试 |
| 高 | 真实数据链路未跑 | 频道、视频、播放只到接口层 |
| 中 | 失败分类依赖文案片段 | 分类先看 HTTP 码、再看 `CHAT_FORBIDDEN` 这类常量；TDLib 若改文案，会退化成「通用错误」，不会误判成成功。测试锁的是我们自己这层映射，锁不住 TDLib 的措辞 |
| 中 | `FailureView` 没有 widget 测试 | 分类函数与状态机有测试，渲染结果没有。截图或 widget test 都能补 |
| 中 | TDLib 池内文件可能被 LRU 回收 | 播放中未向 TDLib 保活；`ActiveFileRegistry` 只对本应用的清理生效。需真机播 30 秒以上确认 |
| 中 | iOS 15 分支走非公开 `UIDevice.setValue(forKey:)` | 第 3 步已记录；TrollStore 侧载不受审核约束 |
| 低 | 频道目录缓存不含计数 | 冷启动先显示「统计中」，`countByChat()` 到位后才有数字 |
| 低 | 设置页盘点同步遍历临时区 | 文件多时短暂卡顿（未实测） |
| 低 | 守卫单一出口 | 若有人绕过 `TdClient.sendJson` 直接调 tdjson，守卫失效。建议补一条「lib/ 下除 td_client.dart 外不得出现 tdjson 调用」的扫描用例（**建议，未实现**） |

---

## 附：CI 与产物

```
run 40338279166  success  7m50s  (14:17:32Z → 14:25:22Z)   ← 验收补强提交
head 2d918ab5d511056fd44f2f1d48dff6e1d36504c3
IPA:    TGMediaProbe-unsigned.ipa  19,780,496 B  (ipa_bytes)
sha256: cd7f90a74080c8dc580852e002ee9574dc3b8def1c04a48f68a6f1207b7cf6bf
test:   01:05 +581 ~1: All tests passed!

run 40330720156  success  7m51s  (13:27:25Z → 13:35:16Z)
head cc4a1d79a5b6ef1b228d6af28731e5cef6df563a
runner: macOS 26.6.2 arm64 · Xcode 26.6 (17F113) · Swift 6.3.3 · iOS SDK 26.5 · CocoaPods 1.17.0
steps:  TDLib 校验 → analyze(No issues) → test(581+1skip) → pod install → xcodebuild
        → 符号校验(TDLib 静态链接，四个 tdjson 符号导出) → IPA 打包 → 上传产物 → 发布 ci-report
IPA:    TGMediaProbe-unsigned.ipa  19,780,011 B  (ci-report/package.txt: ipa_bytes: 19780011)
sha256: 8604b99dfc4824a608922adcf80e09c1a0aabf6e1465374bf1d8f7c414c18ef2
minos 15.2 · bundle com.tgmedia.tgMediaProbe · arm64
本地:   flutter analyze → No issues found；flutter test → 581 passed / 1 skipped

前序 run（同一代码树的文档提交，只证明文档不破坏构建）：
  40311608168  success  6m35s  efe48f4  IPA 19,760,196 B  sha256 61c415cd…
  40323987034  success  5m01s  02dbea5
  40325142273  success  5m37s  dd96a98
  40326058147  success  —       68e864d
  40329622435  success  5m35s  e8f59e4（删下载 + 失败分类）
注意：同一份 lib/ 在不同 run 里产出的 IPA 体积差几十字节、sha256 全不相同（zip 时间戳与顺序），
sha256 只能用来核对「手里这个包是不是那一次构建的」，比对代码版本看提交 SHA。
```

---

## 停止点

第 4 步到此结束，没有开始第 5 步。等确认后再动。
