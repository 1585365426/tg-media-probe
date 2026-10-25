# 第 3 步报告：稳定性与数据安全

生成时间：2026-10-26 00:55 (GMT+8)
提交：`79c0543`（功能）+ `900ccbf`（CI 修复）
CI：run [40213205595](https://github.com/1585365426/tg-media-probe/actions/runs/40213205595) — **success，4m53s**

---

## 0. 状态口径（互不替代）

| 状态 | 结论 |
|---|---|
| 代码已编写 | ✅ 15 个新模块 + 6 个新测试文件，共 2518 行实现、1410 行测试 |
| 静态检查通过 | ✅ `flutter analyze` → No issues found（本机 + CI 各一次） |
| 自动化测试通过 | ✅ 118 项：117 passed / 1 skipped（skip = 本机无 TDLib 二进制） |
| iOS 包构建成功 | ✅ Xcode 26.6 / Swift 6.3.3 / iOS SDK 26.5 |
| IPA 生成 + 哈希复核 | ✅ 19,451,233 B，sha256 `1a83e39b…d404ba` |
| IPA 装到 iPhone | ❌ 未执行 |
| Telegram 登录 / 频道 / 播放 / 下载 | ❌ 未验证（本机到 Telegram 不通，需真机） |
| 横竖屏 / 旋转读取 / 播放器释放（真机） | ❌ 未验证（仅 Dart 层单测通过） |

---

## 1. 新增 / 修改文件清单

### 新增：存储与缓存（`lib/storage/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `storage_layout.dart` | 196 | 四区枚举 `StorageZone`、`StorageLayout`、`ZoneViolation`；分区互斥校验、路径归属判定、`assertDeletableByCacheClear` |
| `cache_manager.dart` | 354 | `CacheManager.scan()/clear()/usage()`、`CacheScan`、`CacheClearReport`、确认文案常量 |
| `file_ops.dart` | 138 | `FileOps` 抽象 + `IoFileOps` 实现；`realPath` 逐级解析符号链接 |
| `active_files.dart` | 42 | `ActiveFileRegistry` 引用计数，标记正在播放/下载的文件 |
| `app_paths.dart` | 31 | 用 `path_provider` 解析真实沙盒根，构造 `StorageLayout` |

### 新增：只读防护（`lib/security/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `td_readonly_guard.dart` | 136 | 64 个云端写方法黑名单、本地专用方法白名单、`assertAllowed` |

### 新增：数据层（`lib/data/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `media_record.dart` | 256 | 索引行模型 + 从 TDLib `message` 对象抽取（video/photo/document/animation/videoNote） |
| `index_store.dart` | 423 | 追加式 journal + 快照压缩、keyset 分页、收藏、水位线、本地删除 |
| `history_source.dart` | 65 | `HistorySource` 抽象 + `TdHistorySource`（只调 `getChatHistory`） |
| `channel_sync.dart` | 360 | `ChannelSyncEngine`（分页限幅、去重、取消）、`SyncCancelToken`、`MediaPager` |

### 新增：播放器（`lib/playback/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `player_slot.dart` | 140 | `PlayerHandle`/`PlayerFactory` 抽象 + `SinglePlayerController` 单实例槽 |
| `playback_lifecycle.dart` | 87 | `PlaybackLifecycleBinder` + `PlaybackLifecycleObserver`（前后台/内存警告/Tab 切换） |
| `video_player_handle.dart` | 105 | `video_player` 真实实现，四步释放 |

### 新增：原生桥（`lib/platform/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `orientation_controller.dart` | 113 | `ScreenOrientationMode` 三模式、`OrientationBridge`、`PageOrientationScope` |
| `video_rotation.dart` | 72 | `VideoRotationReader`（AVFoundation 旋转角）+ 显示尺寸换算 |

### 修改

| 文件 | 变更 |
|---|---|
| `lib/td/td_client.dart` | +5 行：`request()` 开头插入 `TdReadOnlyGuard.assertAllowed`，作为唯一出口的强制检查 |
| `ios/Runner/AppDelegate.swift` | 12 → 178 行：注册两个 MethodChannel（`tgmedia/orientation`、`tgmedia/video_meta`），实现 `supportedInterfaceOrientationsFor` |
| `pubspec.yaml` | 新增直接依赖 `path: ^1.9.0` |
| `test/readonly_guard_test.dart` | 重写为源码扫描 + 运行时断言 + 分层隔离三组 |

### 新增测试

`test/storage_zones_test.dart`(165) · `test/cache_clear_test.dart`(219) · `test/index_store_test.dart`(224) · `test/chat_sync_test.dart`(225) · `test/player_slot_test.dart`(210) · `test/orientation_test.dart`(167) · `test/support/sandbox.dart`(58)

---

## 2. 代码逻辑简述

**只读闸门**：`TdClient.request()` 是唯一把请求交给 `tdjson` 的地方。守卫检查放在 `sendJson` 之前，因此任何新增调用者都无法绕过。未知方法名同样拒绝——新 TDLib 方法必须先被显式分类。

**索引**：`media_journal.jsonl` 追加 op（`m` 更新 / `f` 收藏 / `w` 水位 / `rm` 本地删除），累计到阈值写 `media_snapshot.json`（先写 `.tmp` 再 rename 覆盖，之后才截断 journal）。损坏行跳过并计数，不抛异常。

**同步**：`loadPage` 一次只发一个 `getChatHistory`，`limit` 强制夹到 1–100；`syncCycle` 每频道最多 N 页；每条消息按 `(chatId, messageId)` upsert。`MediaPager` 只在本地索引上翻页，没有"取全部"接口。

**播放器**：`activate()` 先自增代次、拆掉旧实例，再建新实例；`load()` 返回后代次已变则直接销毁新实例，不安装。

**方向**：Dart 侧只管模式与生命周期，实际旋转由原生 `OrientationChannel` 执行；`PageOrientationScope.dispose()` 幂等回到 `system`。

---

## 3. 缓存隔离目录结构

```
<sandbox>/
├── Library/Caches/                     ← iOS 可回收区
│   └── tgmedia/                        [Zone.tempCache] 唯一可被"清空缓存"触碰
│       ├── thumb/                        缩略图
│       ├── player/                       临时播放文件
│       └── partial/                      未完成分片
├── Documents/
│   └── TGMediaDownloads/               [Zone.userDownloads] 受保护，永不进入清理流程
└── Library/Application Support/
    └── tgmedia/
        ├── index/                      [Zone.indexDb] 受保护
        │   ├── media_journal.jsonl
        │   └── media_snapshot.json
        └── secure/                     [Zone.authMeta] 受保护（真正的密钥在 Keychain）
```

构造时校验四区两两不重叠（`_assertDisjoint`），重叠直接 `ArgumentError`。

---

## 4. 安全防护实现说明

**不会误删云端消息**

1. 运行时：`TdClient.request` 的守卫拒绝 64 个写方法（含 `deleteMessages` / `deleteChatHistory` / `deleteChat` / `deleteSupergroup` / `editMessage*` / `forwardMessages` / `sendMessage*` / `leaveChat` / `joinChat` / `pinChatMessage` 等）。
2. 编译期：`readonly_guard_test` 用词边界正则扫描 `lib/**/*.dart`，除守卫文件外任何文件出现这些名字即测试失败。已推 CI，测试不过 CI 不过。
3. 结构隔离：`lib/storage/**` 不允许出现 `TdClient` / `TdReadOnlyGuard` / `td/` 导入（测试断言）。清理代码在物理上无法调用 TDLib。
4. 本地删除 `removeLocalChannel` 只发 journal op `rm`，同文件无任何 TDLib 引用。

**不会删除用户下载 / 收藏 / 索引 / 授权**

| 防线 | 实现 |
|---|---|
| 扫描范围 | `scan()` 只遍历 `thumb/ player/ partial/` 三个子目录，受保护根只用 `exists()` 探测 |
| 删除前复检 | 每次删除前调 `assertDeletableByCacheClear`：路径必须归属 tempCache，且符号链接解析后仍在根内 |
| 占用跳过 | `ActiveFileRegistry` 标记中的文件跳过 |
| 计数诚实 | 文件确认消失后才累加字节数；删除抛异常记入 `failures` |
| 事后校验 | 受保护区存在性前后对比 + 注入的完整性探针（索引行数 / 收藏数 / 下载记录）前后对比，任一变化即 `succeeded=false` |
| 确认 | `clear(userConfirmed: false)` 直接抛 `CacheClearNotConfirmed`；不存在启动时静默清理的路径 |

越权路径测试覆盖：`..` 穿越、同级前缀目录（`tgmedia_evil`）、区域根目录本身、符号链接外指、完全在区外的路径——全部抛 `ZoneViolation`。

---

## 5. 单元测试执行结果

本机（Windows 11 / Flutter 3.47.8 / Dart 3.13.7）与 CI runner 结果一致：

```
00:07 +117 ~1: All tests passed!
```

| 测试文件 | 通过 | 覆盖点 |
|---|---|---|
| `readonly_guard_test.dart` | 9 | 源码零命中黑名单；`request()` 守卫在 `sendJson` 之前；storage 层无 TDLib 引用；64 个方法逐个被拒；13 个实际请求全部放行；`deleteFile` 本地专用白名单 |
| `storage_zones_test.dart` | 12 | 四区互斥；重叠构造抛错；下载/索引/授权区拒删；`..` 逃逸；前缀陷阱；区根；符号链接外指；区外路径 |
| `cache_clear_test.dart` | 13 | 只扫三类缓存；不遍历受保护区；未确认拒绝执行；真实清理后三类受保护文件全部存在；二次清理幂等；占用文件跳过；删除失败如实上报且不计字节；受保护区被破坏时判失败；完整性回归时判失败；确认文案与行为一致 |
| `index_store_test.dart` | 13 | 重复 upsert 不增行；收藏跨 resync 保留；重开恢复；自动压缩 + 显式压缩；损坏行跳过；120 行 50/50/20 翻页无重复；收藏/频道过滤；坏游标不崩 |
| `chat_sync_test.dart` | 12 | 超限请求夹到 100；单页单请求；1200 条 25 页拉完；游标单调回退；连拉 3 次不增行；水位线正确；TDLib 错误不伪装成空成功；取消保留已索引部分；周期限页；`MediaPager` 定长翻页 + 并发去重 |
| `player_slot_test.dart` | 10 | 100 次切换：created=100 / disposed=99 / live=1 / 同时播放峰值=1；慢加载迟到被丢弃；释放与登记对称；释放幂等；解码失败不泄漏；暂停保留实例；前后台/内存警告/Tab 切换四类释放 |
| `orientation_test.dart` | 13 | 三模式线值；dispose 只发一次 reset；未 enter 也 reset；无插件平台不抛；旋转角 90/-90→270/45→null/缺失→null/平台异常→null；空路径不发请求；四值归一化；半圈换宽高 |
| 既有测试 | 36 | schema 24 / redact 5 / td_requests 6 / tdjson 1(skip) |

**两个由测试自己抓出的实现 bug（已修）**：

1. `CacheClearReport.integrityPreserved` 用 `==` 比较两个 Map，Dart 的 Map 是引用相等 → 永远判失败。改为逐键比较。
2. 压缩触发条件 `_journalOps > threshold + _records.length` 在"全是新行"场景下永不成立——这本身是对的（新行不产生浪费），但原测试断言它会压缩。改测试为"重复 upsert 同一批行触发压缩"，并新增"纯新增不压缩"用例。

**CI 抓出的真实错误**：首跑 `40212780128` 失败于 `AppDelegate.swift:28 — Overriding declaration requires an 'override' keyword`。`FlutterAppDelegate` 实际声明了 `supportedInterfaceOrientationsFor`，我在框架头文件里没搜到就写了无 `override` 版本。补 `override` 后 `40213205595` 通过。这条说明"本地无法编译 Swift"确实是盲区，不是可以被静态检查替代的。

---

## 6. 分页 / 横竖屏 / 播放器自测结果

| 项 | 结果 | 依据 |
|---|---|---|
| 分页上限 | ✅ | `pageSize=10000` → 实际请求 `limit=100`；1200 条频道 25 次请求（24 满页 + 1 次空页收尾） |
| 禁止全量拉取 | ✅ | `loadPage` 单请求；`syncCycle` 限页；`MediaPager` 无"取全部"入口 |
| 游标 | ✅ | `from_message_id` 逐页递减，无重复页 |
| 横竖屏三模式 | ⚠️ 逻辑通过 / 真机未验证 | Dart 层 13 项通过；iOS 侧 `requestGeometryUpdate`（16+）/ `UIDevice.setValue`（15）分支已编译进包，实际旋转效果未在 iPhone 上跑 |
| 页面销毁复位 | ✅ 逻辑 | `PageOrientationScope.dispose()` 幂等，连调 3 次只发 1 次 `reset` |
| AVFoundation 旋转读取 | ⚠️ 逻辑通过 / 真机未验证 | 通道与归一化逻辑 8 项通过；`AVAssetTrack.preferredTransform` 实际返回值未在真机取过 |
| 播放器单实例 | ✅ | 100 次切换同时播放峰值 = 1，live 恒为 1 |
| 迟到结果不覆盖 | ✅ | 慢加载完成后代次不符 → 自毁，不安装 |
| 资源释放四步 | ✅ 逻辑 / ⚠️ 真机 | `disposePlayer` 暂停 → `removeListener` → 置空引用 → `controller.dispose()`；真实 AVPlayer 释放只能真机看 |
| 内存警告 / 后台释放 | ✅ 逻辑 | Binder 三入口均触发 `releaseAll()` |

---

## 7. 现存风险与未解决问题

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 真机行为全部未验证 | 方向桥、旋转读取、AVPlayer 释放、沙盒路径下的缓存清理，都只在 Dart 层用替身验证过。装包后需逐项实测 |
| 高 | `UIDevice.setValue(forKey:"orientation")` 属非公开行为 | iOS 15 无 `requestGeometryUpdate`，只能走这条路。TrollStore 侧载不受审核约束，但若将来上架 App Store 会被拒 |
| 中 | 索引全量驻留内存 | 纯 Dart 实现换取"测试与线上同一条代码路径"。按每行约 300–500 B 估算，10 万条约 30–50 MB（**估算，未实测**）。个人频道量级可用，超大频道需换成 SQLite |
| 中 | journal 追加未做 fsync | `writeAsString(flush: true)` 只 flush 到 OS 缓冲。掉电可能丢最后几行（不影响已压缩的快照） |
| 中 | 数据库未加密 | 第 4 步 PIN 与密钥管理落地前，索引文件是明文 JSON。当前不含消息正文，只有元数据 |
| 中 | Flutter 3.47 最低 iOS 15.0 | 目标 15.2 余量 0.2 个次版本，Flutter 必须锁 3.47.8 |
| 低 | 压缩后 journal 为空但快照可能较大 | 快照是全量 JSON，若记录数极大，单次写盘会有秒级停顿（未实测） |
| 低 | `usage(includeProtected: true)` 会遍历受保护区 | 仅用于设置页展示，与删除路径完全分离，但确实违反"不遍历"的字面表述——默认值为 `false`，调用方需显式开启 |

未验证清单一律没有标成通过。等真机 IPA 落地后才能补测第 3、6 项标注 ⚠️ 的内容。

---

## 附：CI 与产物

```
run 40213205595  success  4m53s
runner: macOS 26.6.2 arm64 · Xcode 26.6 (17F113) · Swift 6.3.3 · iOS SDK 26.5 · CocoaPods 1.17.0
steps:  TDLib 校验 → analyze → test(117+1skip) → xcodebuild → 符号校验 → IPA 打包 → 上传产物
IPA:    TGMediaProbe-unsigned.ipa  19,451,233 B
sha256: 1a83e39be0c18d0d0ab403051f0f7fa1557f93affcd39f15daa62b7d8ad404ba（本机重算一致）
minos 15.2 · bundle com.tgmedia.tgMediaProbe · orientations: portrait + landscapeL/R
TDLib  静态链接进 Runner，四个 tdjson 符号全部导出（inspect 步骤通过）
```
