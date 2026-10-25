# TG Media 第 4 步报告：界面与功能

- 时间：2026-10-26 02:40（Windows 开发机）
- 提交：`c5a3372`（未推送，见 §7-①）
- 前置：第 3 步 A/B/C 已真机确认，D 项于本轮截图补证（`tdjson 已加载（静态链接，符号从主二进制解析）`）
- 状态口径：本报告只写**已在本机真实执行**的结果。真机、Face ID 硬件、真实 Telegram 数据一律标「未验证」，不折算为通过。

---

## 1. 文件清单

### 1.1 新增（25 个 Dart 文件 + 5 个测试 + 1 个 plist 项）

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib/app/app_settings.dart` | 226 | 主题 / 静音 / 分类 / 时长筛选的持久化，含冷启动静音覆盖 |
| `lib/app/app_services.dart` | 155 | 组合根：存储布局、索引、收藏、缓存、播放器槽、锁、生物识别 |
| `lib/app/app_model.dart` | 168 | UI 状态（设置、登录态、频道、收藏集合、搜索态）+ `AppScope` |
| `lib/security/app_lock.dart` | 296 | PBKDF2-HMAC-SHA256、密码策略、失败计数与冷却、改/关密码 |
| `lib/security/biometric.dart` | 176 | Face ID 可用性判定与认证封装，含测试替身 |
| `lib/data/favorites_store.dart` | 119 | 收藏独立存储（`index/favorites.json`） |
| `lib/data/video_query.dart` | 126 | 搜索 / 分类 / 时长的纯过滤规则 |
| `lib/data/chat_title_store.dart` | 96 | chatId → 频道名缓存（`index/chats.json`） |
| `lib/data/channel_loader.dart` | 96 | `getChats` + `getChat` 只读频道发现 |
| `lib/data/media_resolver.dart` | 177 | 下载到 TDLib 池 → 提升到用户下载区 → 返回可播放路径 |
| `lib/ui/app_shell.dart` | 115 | 三 Tab 外壳、Tab 切换释放播放器 |
| `lib/ui/channels/channel_page.dart` | 265 | 登录引导、频道列表、同步 |
| `lib/ui/video/video_feed_page.dart` | 599 | 垂直 PageView、搜索、筛选、分页、单播放器调度、静音、方向 |
| `lib/ui/video/video_tile.dart` | 260 | 单页渲染 + 右侧 收藏/静音/横竖屏 按钮 |
| `lib/ui/video/single_video_page.dart` | 159 | 收藏页进入的单片播放 |
| `lib/ui/favorites/favorites_page.dart` | 151 | 收藏列表 |
| `lib/ui/settings/settings_page.dart` | 395 | 主题、清理缓存、应用锁、关于 |
| `lib/ui/settings/passcode_page.dart` | 184 | 设置 / 修改 / 关闭密码 |
| `lib/ui/lock/lock_screen.dart` | 251 | 冷启动解锁、错误提示、冷却倒计时、Face ID 回落 |
| `lib/ui/login/login_page.dart` | 349 | 凭据 + 手机号 + 验证码 + 两步验证（复用 `ProbeRunner`） |
| `lib/ui/tools/tools_page.dart` | 205 | 设置/收藏/诊断入口、四区用量、只读声明 |
| `test/app_lock_test.dart` | 272 | 29 项：PBKDF2 官方向量、策略、锁定流程、生物识别降级 |
| `test/video_query_test.dart` | 265 | 20 项：搜索、分类、时长边界、组合、caption 提取 |
| `test/app_settings_test.dart` | 142 | 16 项：默认值、持久化、冷启动静音、损坏回退 |
| `test/favorites_isolation_test.dart` | 218 | 12 项：收藏增删、持久化、删频道/清缓存不影响收藏 |
| `test/app_shell_smoke_test.dart` | 209 | 6 项：三 Tab、未登录引导、功能页入口、主题实时切换、搜索空态 |

### 1.2 修改

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | 重写：启动引导、主题随 `AppModel` 实时切换、`LockGate` 冷启动验密、引导失败可读错误页 |
| `lib/data/media_record.dart` | 新增 `caption` 字段（小写、512 字符上限）+ JSON 往返 + `_captionOf` 提取 |
| `lib/storage/storage_layout.dart` | 新增 `settingsDir`（`secure/app`，受保护区）+ `ensureCreated` 建目录 |
| `lib/playback/player_slot.dart` | `PlayerHandle` 增加 `setVolume` |
| `lib/playback/video_player_handle.dart` | 实现 `setVolume` |
| `pubspec.yaml` | 新增 `crypto ^3.0.6`、`local_auth ^2.3.0` |
| `ios/Runner/Info.plist` | 新增 `NSFaceIDUsageDescription` |
| `test/player_slot_test.dart` | 替身实现 `setVolume` |

---

## 2. 功能实现

### 2.1 顶部三 Tab

`AppShell` 用 `TabController` + `IndexedStack`，不是 `TabBarView`。

原因：视频页必须保留分页游标与已加载窗口。`TabBarView` 会把离屏子页销毁重建，每次切回都要重读索引。

Tab 切换时若离开视频 Tab，调用 `PlaybackLifecycleBinder.handleTabChanged` → `SinglePlayerController.releaseAll()`（暂停 + 移除监听 + `controller.dispose()`）。`VideoFeedPage.didUpdateWidget` 里还有一条同样幂等的释放路径，两边谁先到都行。

页面隔离：三个 Tab 各自持有独立状态对象，视频页通过 `active` 布尔受外壳控制，非激活时不下载、不激活播放器。

### 2.2 设置入口与设置页

入口在「功能」页第一张卡。设置页分四块：

- **外观**：`SegmentedButton` 三选一（跟随系统 / 亮色 / 暗色）。`AppModel.setThemeMode` 改 `_settings` 后 `notifyListeners()`，`main.dart` 的 `AnimatedBuilder` 重建 `MaterialApp`，`themeMode` 变化即生效，不重启。
- **存储**：显示「可清理 N 个文件 · X MB」，点击进入二次确认弹窗。
- **应用密码锁**：开关 + 修改密码 + Face ID 开关。
- **其他**：诊断页入口、版本、只读声明。

### 2.3 视频页

- **上下滑**：`PageView.builder(scrollDirection: Axis.vertical)`。
- **单播放器**：`SinglePlayerController.activate()` 内部先 `_disposeActive()` 再建新句柄；`_activationToken` 保证慢加载完成后不覆盖已经切走的页面。
- **静音**：`PlayerHandle.setVolume`，每次 `activate` 后显式 `setVolume(muted ? 0 : 1)`。AVPlayer 每个 item 的音量独立，不显式设置就会出现「切下一条突然有声」。
- **冷启动静音**：`AppSettingsStore.load()` 返回值强制 `muted = true`；若磁盘是 `false`，立即回写 `true`，让文件与运行时一致。
- **循环重播**：`VideoPlayerController` 监听器判 `isCompleted || position >= duration - 150ms`，`seekTo(0)` 后 `play()`，`_seekingBack` 防抖。列表头不循环（`PageView` 在 index 0 自然夹住）。
- **分页**：`MediaPager` 从本地索引读 40 条一页；`onPageChanged` 到 `length - 2` 触发下一页。
- **筛选**：两行横向 Chip，上行时长四档，下行「全部频道」+ 各频道。条件写入 `AppSettingsStore`，重启保留。
- **搜索**：右上角图标 → `AppModel.toggleSearch` → 视频页顶部出现搜索框（220ms 防抖）。匹配 caption、频道名、文件名，多词 AND。清空即回到原列表。
- **横竖屏**：`OrientationBridge.setMode`，iOS 16+ 走 `requestGeometryUpdate`，iOS 15 走 `UIDevice.setValue`；离开页面 `resetToSystem()`。
- **旋转角**：`VideoRotationReader.readRotationDegrees()` 读 AVFoundation track transform，只接受 0/90/180/270，读不到就是 null（UI 显示「旋转」字段缺省，不写 0）。`displaySize()` 按 90/270 交换宽高后算显示比例。

### 2.4 收藏

星标按钮在视频页右侧与单片播放页。`FavoritesStore.toggle()` 写 `index/favorites.json`（`.tmp` + rename 原子替换）。功能页入口显示实时数量，进入后点击播放、点星取消。

### 2.5 密码锁

- 冷启动：`LockGate` 查 `AppLock.isEnabled()`，开启则显示 `LockScreen`。
- 设置/修改/关闭：`PasscodeSetupPage` 三种模式。关闭与修改都必须先过 `changePasscode`/`disable` 的当前密码校验，校验失败返回 `false`，页面显示「当前密码不正确」。
- 错误提示：每次错误计数 +1；达 5 次后 `AppLock.delaySecondsFor` 返回 5/10/15…（上限 30 秒），UI 显示倒计时并禁用输入；`AppLock.verify` 自身在冷却期直接返回 `lockedOutTemporarily`，脚本直接调用也绕不过。
- Face ID：`BiometricService.availability()` 返回 `faceId` / `touchIdOnly` / `notEnrolled` / `unsupported`。只有前两者 `canOfferToggle == true`，其余设置页显示一行禁用说明（`此设备不支持面容 ID` / `尚未在系统设置中录入面容 ID`）。冷启动时若已开启生物识别，自动尝试一次；失败/取消/不可用一律显示「请改用应用密码」，密码框始终可用。

---

## 3. 安全校验

### 3.1 清理缓存

链路：`SettingsPage._clearCache` → 弹窗确认 → `CacheManager.clear(userConfirmed: true)`。

六道闸门（沿用第 3 步实现，本轮接入真实 UI）：

1. 不传 `userConfirmed: true` 直接抛 `CacheClearNotConfirmed`；
2. `scan()` 只走 `thumb/` `player/` `partial/` 三个子目录，受保护区只做 `exists()` 检查；
3. 每个待删路径在删除前**重新**过 `assertDeletableByCacheClear`（`zoneOf` + `assertInside` 两道，跟随软链接）；
4. `ActiveFileRegistry` 里登记的文件跳过；
5. 字节数只在确认文件已消失后累加；
6. 清理前后 integrity 计数（索引条数、收藏数、频道数、频道名缓存数）不一致 → `integrityPreserved = false` → `succeeded = false`，弹窗标题变成「清理未完全成功」。

弹窗文案（`settings_page.dart`）：

> 仅清除临时缓存，不会删除已下载文件、收藏、账号数据、Telegram 云端消息。

下附 `cacheClearConfirmationText` 全文，再下一行是「正在使用的 N 个文件会被跳过」。

### 3.2 收藏数据隔离

收藏不在媒体索引里，是 `index/favorites.json` 独立文件。原因写在 `favorites_store.dart:9-21`：`IndexStore.removeLocalChannel()` 是受支持操作，会把该频道所有行删掉；收藏若只存在索引表里，删频道就会连带清掉收藏。

`test/favorites_isolation_test.dart` 直接验证：

- `removeLocalChannel(1)` 删掉 2 条镜像行后，重开 `favorites.json` 仍有 1 条；
- 真实建 3 个临时文件 + 1 个下载文件 + 2 条收藏 + 1 条索引，跑 `clear(userConfirmed: true)`：临时文件全删（3 个 / 1200 B），`keep.mp4` 与 `favorites.json` 都在，收藏仍 2 条、索引仍 1 条。

### 3.3 密码加密存储

- 算法：PBKDF2-HMAC-SHA256，100,000 轮，16 字节 `Random.secure` 盐，32 字节输出。
- 存储格式：`pbkdf2-sha256$<iter>$<saltB64Url>$<hashB64Url>`，写入 Keychain（`KeychainSecretStore`，`first_unlock_this_device`），不进 plist、不进 JSON、不进 `SharedPreferences`。
- 校验：`constantTimeEquals` 逐字节 XOR 累加，不提前返回。
- KDF 在 `Isolate.run` 里跑，不卡 UI。
- 服务端无副本，无法找回；唯一出路是卸载。

验证方式：`test/app_lock_test.dart` 用三组公开向量（c=1 / c=2 / c=4096，P=`password`，S=`salt`，dkLen=32）比对十六进制输出，全部命中。这条最关键——自写 KDF 只有对得上公开向量才谈得上「加密存储」而不是「存了个错的东西」。

### 3.4 Face ID 权限与降级

- `Info.plist`：`NSFaceIDUsageDescription = 用于解锁 TG Media 的应用密码锁。面容数据由 iOS 处理，应用不会读取或保存。`
- `local_auth` 调用带 `AuthenticationOptions(biometricOnly: true, stickyAuth: true)`。`biometricOnly` 是硬要求：不加它，iOS 会在系统弹窗里提供「输入设备密码」的兜底，等于用系统密码绕过了应用自己的密码。
- 降级：`BiometricService.authenticate` 把 `false` 与异常都归一为 `failed`/`unavailable`，UI 只显示提示并把焦点留在密码框，不存在「Face ID 失败后无路可走」的状态。
- 设备无硬件 / 未录入：设置页不出现开关，显示禁用说明；`LockScreen` 不显示 Face ID 按钮。

### 3.5 搜索与过滤

`VideoQueryEngine.matches` 是纯函数，顺序：时长 → 分类 → 关键词。关键词命中字段为 caption、频道名、文件名，全部小写后 `contains`，多词 AND。

`test/video_query_test.dart` 覆盖：空查询全通过、纯空白视为无搜索、caption/频道名/文件名分别命中、多词 AND、无匹配返回空、分类单选、三条件组合、时长边界 59/60/299/300、未知时长只进「全部」、每条记录只落一个桶。

---

## 4. 自测结果

### 4.1 本机真实执行

| 项 | 命令 | 结果 |
|---|---|---|
| 静态检查 | `flutter analyze` | `No issues found!`（14.6 s） |
| 单元 + Widget 测试 | `flutter test` | **243 passed / 1 skipped**（12 s），从 164 增至 243，新增 79 |
| 跳过项 | `tdjson_load_test` | 本机无 TDLib 二进制，`skip`（与之前一致） |

### 4.2 逐项对照

| # | 自测项 | 结果 | 依据 |
|---|---|---|---|
| 1 | Tab 切换 | **已测** | `app_shell_smoke_test`：三 Tab 文本存在；点视频 Tab 显示未登录引导；点功能 Tab 显示设置/收藏/只读声明 |
| 2 | 主题切换 | **已测** | 同上：`setThemeMode(dark)` → `themeMode == dark`，`light` → `light`，`MaterialApp.themeMode` 读到新值 |
| 3 | 分类筛选 | **已测（逻辑层）** | `video_query_test`：只保留选中 chat；UI 层 Chip 点击路径未做 widget 测试 |
| 4 | 时长筛选 | **已测（逻辑层）** | 四个边界 + 未知时长 + 唯一归属 |
| 5 | 搜索 | **已测** | 三字段命中、AND、空态文案「没有匹配的视频」+「清空条件」按钮 |
| 6 | 收藏增删查看 | **已测（存储层）** | `favorites_isolation_test` 12 项；列表页 UI 未做 widget 测试 |
| 7 | 设置页各项 | **部分已测** | 入口存在性已测；主题三态已测；清缓存与锁的交互需点击 + 平台通道，未做 widget 测试 |
| 8 | App 密码锁 | **已测（逻辑层）** | 29 项：设置、拒绝二次设置、错误计数、5 次后冷却、冷却期拒绝、改密码需原密码、关闭需原密码、生物识别开关独立 |
| 9 | Face ID 解锁 | **仅逻辑层** | 可用性判定（4 态）、失败返回 failed、异常降级、缓存与刷新。真实弹窗**未验证**（需真机） |
| 10 | 上下滑视频切换 | **未测** | 需真机视频文件与 `video_player` 平台通道 |
| 11 | 播放器静音逻辑 | **部分已测** | `setVolume` 契约与调用点已实现；冷启动静音由 `app_settings_test` 两项覆盖；真实音轨静音**未验证** |

### 4.3 本轮抓到的实现缺陷

| # | 现象 | 定位 | 处理 |
|---|---|---|---|
| G | `VideoFeedPage.dispose()` 调 `_releasePlayer()` → `setState` 抛 `_lifecycleState != defunct` assert | `video_feed_page.dart:290` | `mounted` 在 `dispose` 期间仍为 true，加 `_disposed` 标志守卫。**真机上退出视频页同样会触发**，由 `app_shell_smoke_test` 抓出 |

---

## 5. UI 异常、交互 bug、兼容性

### 5.1 已知 UI 缺陷（第 3 步 E/F，本轮未修）

| # | 问题 | 位置 |
|---|---|---|
| E | 探针页步骤图标在多行 detail 里垂直居中，脱离标题行；第 8 项 6 行路径时 ✓ 落在中间，肉眼读成「未打勾」 | `probe_page.dart:347` `ListTile` 缺 `titleAlignment` |
| F | 探针页 detail 显示容器绝对路径，375pt 下折 4–5 行，UUID 被硬断成 `25212DE5-` / `C911-…` | 同上 |

这两项只影响诊断页，不影响三 Tab 主流程。是否修由你定；我倾向在第 5 步一起带着改，因为改完要重新出包。

### 5.2 交互取舍（不是 bug，但要知道）

| # | 行为 | 说明 |
|---|---|---|
| a | 从后台回前台不重新验密 | 需求写的是「打开 App 时进行身份校验」，我按字面实现为冷启动验密。每次切出去看通知再回来都要输密码会毁掉视频流体验。要加可以，一行开关 |
| b | 分类 Chip 只列「已加载页里出现过的频道」 | 首屏只读 40 条，频道多时可能只看到 1–2 个。点频道页的频道进入会自动带上该频道分类 |
| c | 搜索只搜本地已同步的记录 | 结果为空且索引还有下一页时自动再取最多 8 页；再没有就显示空态。不做云端搜索（只读约束下没有搜索 API 可用） |
| d | 每个视频首次播放需等整段下载完成 | `downloadFile` + `promote` 后才播，不做流式。5.8 MB 样本在真机上秒级；长视频会明显等待，UI 显示百分比进度条 |
| e | 横竖屏按钮只在视频页有效 | 离开视频页 `dispose` 时 `resetToSystem()` |
| f | 探针页保留在「功能」与「设置」里 | 它是第 2/3 步的真机自检工具，删掉会失去后续回归手段 |

### 5.3 兼容性

- `local_auth 2.3.0` 依赖 `local_auth_darwin 1.6.1`，podspec 最低 iOS 12.0，不抬高 15.2 地板。
- `crypto 3.0.6` 纯 Dart，无原生依赖。
- 新增 8 个传递依赖（`intl`、`local_auth_*`、`objective_c` 等），`pubspec.lock` 已更新。
- `RadioListTile` 在 Flutter 3.47 已弃用 `groupValue`/`onChanged`，改用 `SegmentedButton`，避免 analyze 出 info。

---

## 6. 风险与未解决

| # | 问题 | 影响 | 计划 |
|---|---|---|---|
| ① | **代码已提交但未推送，CI 未跑，没有新 IPA** | 第 5 步才能出包，未确认前进不构建 | 你确认本报告后推 `main` 触发 `macos-26` 构建 |
| ② | 第 3 步遗留 5 项真机未验：第 1 项文案已有截图（D 通过），剩余旧库红字提示条、冷启 key 复用（#13）、Filza 目录核对（#14）、画面/音轨/seek | 数据安全结论仍缺 3 条 | 装第 4 步包时一并复测，清单见 §7 |
| ③ | 所有 UI 交互均未真机验证 | Tab、滑动手感、Face ID 弹窗、横竖屏、72 小时稳定性全未测 | 第 6 步 |
| ④ | `MediaRecord.caption` 是新字段 | 旧 journal 行没有 `cap`，升级后搜索对这些旧记录无效，要等一次重新同步 | 首次同步会 `upsertAll` 覆盖旧行并写入 caption；报告如实说明 |
| ⑤ | `IndexStore` 的 `favorite` 字段与 `FavoritesStore` 并存 | 两套收藏标记，UI 只认 `FavoritesStore`。索引里的旧标记不清除但不生效 | 可接受；若后续要清理，加一次一次性迁移 |
| ⑥ | `_widenForSearch()` 在 model 每次变化时触发且不 await | 快速连打关键词可能并发多轮补页 | 补页自身有 `_loadingPage` 互斥，最坏是白读一页，不会出错 |
| ⑦ | PBKDF2 100k 轮在旧设备上可能 1–1.5 s | 解锁时有可感知延迟（无进度条） | 可加转圈；不建议降轮数 |
| ⑧ | Face ID 只在 `biometricOnly` 模式下测过枚举值 | iPhone 11 Pro / iOS 15.2 上 `getAvailableBiometrics()` 是否返回 `BiometricType.face` 需真机确认 | 第 6 步重点项 |
| ⑨ | 视频页不做预加载 | 滑到下一屏才开始下载，首次会看到 loading | 可加「下一条预取」，但会占用带宽与缓存，先按需求做 |

---

## 7. 需要你确认/配合的

1. **是否推送并出包**。确认第 4 步报告后我推 `main`，CI 出新的 unsigned IPA（第 5 步）。
2. **真机复测清单**（第 6 步用，装包后按顺序）：

| # | 动作 | 期望 |
|---|---|---|
| 1 | 冷启动 | 若已设密码 → 锁屏；未设 → 直接进频道页 |
| 2 | 三 Tab 互切 | 顶部 Tab 高亮跟随；切走视频页后无声音、无后台音频 |
| 3 | 功能 → 设置 → 切暗色 | 立即变暗，不重启；杀进程重开仍是暗色 |
| 4 | 设置 → 清理缓存 | 弹窗含「仅清除临时缓存，不会删除已下载文件、收藏、账号数据、Telegram 云端消息」；确认后报告 `删除 N 个文件` |
| 5 | 清缓存后看 Filza | `TGMediaDownloads/` 里的 mp4 还在；`favorites.json` 还在 |
| 6 | 视频页滑 3 条 | 上一条立即停；新一条从 0 开始播；**全程无声**（冷启动默认静音） |
| 7 | 点喇叭 → 滑下一条 | 下一条仍有声（继承）；杀进程重开 → 又静音 |
| 8 | 视频播完 | 自动从头重播，不跳到下一条 |
| 9 | 搜索频道名 | 结果只剩该频道；清空恢复 |
| 10 | 时长筛「1 分钟以内」 | 列表只剩短于 60 秒的；杀进程重开筛选仍在 |
| 11 | 星标收藏 → 功能 → 我的收藏 | 能看到；点进去能播 |
| 12 | 设置 → 开启密码锁（6 位） | 成功；杀进程重开要求输入 |
| 13 | 输错密码 5 次 | 出现「请等待 N 秒」倒计时，输入框禁用 |
| 14 | 设置 → 开启面容 ID → 杀进程重开 | 自动弹面容；**遮住脸**让识别失败 → 提示「请改用应用密码」并停在密码框 |
| 15 | 关闭密码锁 | 必须先输当前密码；输错不放行 |
| 16 | 视频页点横竖屏 | 画面转横；返回竖屏；切 Tab 后恢复竖屏 |
| 17 | 第 3 步遗留：冷启不重收码 | 直接 `authorizationStateReady` |
| 18 | 第 3 步遗留：Filza 看三目录 | `Documents/tdlib` 无新文件；`TGMediaDownloads/c<id>/` 有 mp4；`secure/tdlib/db` 有库 |

3. **UI 缺陷 E/F 是否一并修**（探针页图标对齐、路径换行）。修的话第 5 步出包前改，不修就维持现状。
