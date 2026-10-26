# 第 4 步 CI 期检查报告：规范、报告格式与只读守卫缺陷

生成时间：2026-10-26 20:45 (GMT+8)
提交：`efe48f4`（第 4 步代码 + 守卫修复 + 149 项测试）、`02dbea5`（文档）

> 本文件是 20:45 那一刻的快照，数字按当时实测记录。此后 `e8f59e4` 删掉了下载专属代码与两个测试文件、新增失败分类测试，测试总数从 548 通过变为 539 通过；阶段 E 的收尾结论以 `docs/STEP4-REPORT.md` 为准，本文件不再回头改写。
CI：run [40311608168](https://github.com/1585365426/tg-media-probe/actions/runs/40311608168) — **success，6m35s**
后续 run [40323987034](https://github.com/1585365426/tg-media-probe/actions/runs/40323987034) — **success，5m01s**（文档提交 `02dbea5`，只证明文档提交没破坏构建）

---

## 0. 状态口径（互不替代）

| 状态 | 结论 |
|---|---|
| 代码已编写 | ✅ 第 4 步 14 个新模块（5431 行）+ 修改 7 个既有模块；本轮新增 6 个测试文件（2522 行） |
| 静态检查通过 | ✅ 本机 `flutter analyze` → No issues found；CI step 13 Analyze success |
| 自动化测试通过 | ✅ 本机 548 passed / 1 skipped；CI run `40311608168` 记录 `00:50 +548 ~1: All tests passed!` |
| 只读守卫缺陷修复 | ✅ 已修并推入 `efe48f4`，含 3 条新增回归用例 |
| iOS 包构建成功 | ✅ run `40311608168` step 16 xcodebuild success |
| IPA 生成 + 哈希复核 | ✅ 19,760,196 B，sha256 `61c415cd…5820df1` |
| 文档已更新 | ✅ `docs/STEP4-REPORT.md` 新建；`docs/PRODUCT-SPEC.md` §10/§11/§12/§4.2/§9.5 修改 |
| IPA 装到 iPhone | ❌ 未执行 |
| 真机 Face ID / 横竖屏 / 100 次切换 / 重启恢复 | ❌ 未验证 |
| 真实 TDLib 数据链路（频道 / 视频 / 播放） | ❌ 未验证 |
| run `40323987034` 结论 | ✅ completed / success，5m01s（20:42 GMT+8 完成，只覆盖文档提交） |

---

## 1. 规范第 11、12 节现状

### 1.1 文件路径

正式规范只有一份：`docs/PRODUCT-SPEC.md`，共 640 行。仓库内其余 `docs/STEP*-REPORT.md` 是交付报告，`docs/DOWNLOAD-DEPENDENCY-MAP.md` 是施工映射，均不是规范。

### 1.2 第 11 节（原文行 542–557）

标题：`## 11. 待确认`。修改后的原文如下（本轮改过，改动见 §5）：

```markdown
## 11. 待确认

第 4 步开始时本节共 6 项。其中 5 项已由用户任务书明确，1 项仍未确认。未确认项按「不做」处理，不实现也不留占位按钮。

| # | 原条款 | 结论 | 依据 | 落地位置 |
|---|---|---|---|---|
| 1 | 是否加「仅 Wi-Fi 播放」开关 | **不加**。不提供该开关，不引入网络类型监听 | 用户第 4 步任务书 | `app_preferences.dart`（持久化键里没有 wifi 字段，有测试守护） |
| 2 | 长按视频的默认行为（暂停 / 菜单 / 无） | **无**。长按不绑任何手势 | 同上 | `feed_page.dart`（只绑 `onTap` 与 `onDoubleTap`） |
| 3 | 抖音页顶部是否要保留搜索入口 | **保留**。顶部保留搜索，且为本地搜索 | 同上 | `feed_page.dart` 顶栏 + `ChannelDirectory.search()` |
| 4 | 横屏时是否隐藏底部信息区（更沉浸） | **隐藏**。横屏隐藏信息区，控制层仍可调出 | 同上 | `FeedOverlayPlan.forOrientation()`（`showInfo=false`、`showControls=true`） |
| 5 | 忘记密码重置时，是否允许保留当前 Telegram 会话 | **不允许**。执行安全重置并清除本地 Telegram 会话 | 同上 | `UnlockController.beginRecovery()` + `AppSession.resetThroughTelegram()` |
| 6 | 频道页是否需要「仅显示有视频的频道」筛选 | **仍未确认**，按「不做」处理 | 未获用户确认 | 无实现，无占位按钮 |

第 5 项与 §8.6 的强度取舍关系：本项选择的是「更严」一侧——重置后必须重新登录 Telegram，锁的恢复成本不可能低于会话的恢复成本。
```

原约束（保留未删）：**未确认项按「不做」处理，不实现也不留占位按钮**。第 6 项仍适用这条。

### 1.3 第 12 节（原文行 559–622）

标题：`## 12. 第 4 步实施计划`。结构：`阶段状态（表）` → 阶段 A/B/C/D/E 各带 4–7 条编号条目与一条「验收」→ `依赖关系` 代码块（`A→B→C`、`A/D→E`、`C 和 D 可并行，E 必须最后`）。

新增的阶段状态表只记录事实，未改任何原验收条目：

| 阶段 | 实施 | 自动化验收 | 真机验收 |
|---|---|---|---|
| A 壳与导航 | 已实现 | ✅ `app_preferences_test` 15 项 | ❌ 未执行 |
| B 频道页 | 已实现 | ✅ `channel_directory_test` 23 项 | ❌ 未执行 |
| C 抖音页 | 已实现 | ✅ `feed_controller_test` 31 项（含 100 次切换）+ `video_source_test` 9 项 | ❌ 未执行 |
| D 设置页 | 已实现 | ✅ `unlock_controller_test` 39 项 + `security_negative_test` 32 项 | ❌ 未执行 |
| E 收尾 | 部分完成 | 报告已出 | ❌ 状态矩阵走查与真机记录未做 |

### 1.4 与测试、白名单、未知方法、报告格式、验收条件有关的条款

| 条款 | 位置 | 内容 | 证据 |
|---|---|---|---|
| 只读原则 | 行 40 附近 | 云端写入由 `td_readonly_guard.dart` 在请求发出前强制 | 代码 `lib/td/td_client.dart:108`；测试 `readonly_guard_test.dart:39` |
| §9.5 安全测试 | 行 508–514 | 只删临时区、不动三个受保护区、跳过占用中文件、跳过未识别文件、拒绝符号链接越界、字节只计真删、空区幂等、保护区消失判失败；本轮追加 10 项负向清单 | 测试 `security_negative_test.dart` 10 个 group |
| §13 明确不做 | 行 624 起 | 云端写入一律不做 | 同 §4 |
| 报告格式 | — | **§11、§12 里没有任何一条规定报告格式**；格式唯一来源是 `docs/STEP3-REPORT.md` | 全文 grep `报告` 仅命中 §5 报告段落，不涉及格式 |
| 方法白名单 | — | **§11、§12 里没有任何一条提到方法白名单或未知方法处理** | 守卫的行为约定只写在 `td_readonly_guard.dart` 的 doc comment 里 |

### 1.5 冲突判定

| 冲突点 | 冲突内容 | 处理 |
|---|---|---|
| §4.2 手势表 | 原文「长按（可选）｜暂停并显示『继续播放』」与已确认的「长按无操作」直接冲突 | 已改为「长按｜无操作。不绑定任何手势」，并注明依据 |
| §11 第 1 项 | 原文是待确认，用户已明确不加 | 已把结论写进表格，原条款列保留 |
| §11 第 2–5 项 | 同上，已确认 | 同上 |
| §9.5 | 原清单只有 8 项，任务书要求 10 项负向 | 追加 10 项，原文 8 项未删 |
| §12 | 原计划无状态列，无法看出哪阶段验收到哪 | 加状态表，原验收条目一字未改 |

无冲突但需说明：§4 与 §13 的只读约束，本轮发现实现**弱于**注释承诺（见 §3），属实现缺陷，不是规范冲突。

### 1.6 证据强度分级

- 有源码证据：§1.2/§1.3 的原文（直接读取）、§1.5 各条（代码位置已核对）。
- 有测试证据：§9.5 十项对应 `security_negative_test.dart` 的十个 group，本机 32 项全绿。
- 仍需验证：§12 表里全部「真机验收 ❌」；阶段 E 的六态矩阵走查（未执行，无记录）。

---

## 2. 第三份报告的格式分析

### 2.1 定位

文件：`docs/STEP3-REPORT.md`，标题 `# 第 3 步报告：稳定性与数据安全`，214 行。搜索范围：`docs/` 全目录 + `git log --all --diff-filter=A -- docs/`。仓库内共三份报告（STEP2、STEP3、STEP4），STEP3 是任务书所指的「第三份」，存在且可读。

### 2.2 章节顺序（固定 9 段）

```
头部元信息（生成时间 / 提交 SHA / CI run 链接 + 结论 + 耗时）
0. 状态口径（互不替代）        ← 表格，7–8 行
1. 新增 / 修改文件清单          ← 按目录分小节，每文件 行数 + 职责
2. 代码逻辑简述
3. 缓存隔离目录结构
4. 安全防护实现说明
5. 单元测试执行结果            ← 原始输出一行 + 文件/通过数/覆盖点 表
6. 分页 / 横竖屏 / 播放器自测结果 ← 项 / 结果 / 依据 表
7. 现存风险与未解决问题        ← 级别 / 问题 / 说明 表
附：CI 与产物                  ← 代码块，纯文本
```

### 2.3 测试结果呈现方式

先贴**一行未加工的原始输出**（`00:07 +117 ~1: All tests passed!`），再给 `测试文件 / 通过 / 覆盖点` 三列表。覆盖点写的是**断言了什么**，不是「测试了某功能」。

### 2.4 缺陷、风险、证据、未完成项

- 缺陷：在 §5 里**单独成段**，标题为「两个由测试自己抓出的实现 bug（已修）」与「CI 抓出的真实错误」。每段含：现象 → 根因 → 修法。归因明确区分「测试写错」与「实现错了」。
- 风险：§7 表格，四列 `级别 / 问题 / 说明`，级别用高/中/低。估算类数据必须标「**估算，未实测**」。
- 证据：每条结论后面跟依据（文件名、行号、用例名），不写「已验证」而不给来源。
- 未完成项：一律 `❌ 未执行` 或 `⚠️ 逻辑通过 / 真机未验证`，不写「基本可用」。

### 2.5 必须保留的字段

| 字段 | 为什么必须保留 |
|---|---|
| 状态口径表（代码/静态/测试/构建/IPA/装机/真机 分行互不替代） | 防止「编译成功」被当成「功能可用」 |
| 提交 SHA（功能 + 修复分开列） | 报告必须能指回具体代码 |
| CI run 号 + 结论 + 耗时 | 结论可被第三方复核 |
| runner 工具链四件套（macOS / Xcode / Swift / iOS SDK）+ CocoaPods | 构建可复现的前提 |
| IPA 体积 + sha256 | 产物唯一性 |
| minos / bundle id / 支持方向 | 装机前的静态核验 |
| 每个未验证项的 ❌ | 未验证不得写成通过 |

### 2.6 适合补充的字段（本轮已补，标为新建议）

1. 「本轮改动是否触碰安全约束」一行——第 4 步改了守卫，需要显式说明是收紧还是放宽。
2. 「测试总数变化」——548 vs 上一轮 399，增幅本身就是工作量证据。
3. 「规范哪些条目被改、为什么」——避免报告与规范互相矛盾。
4. 「CI 首跑失败 → 修复 → 复跑」的完整链路——STEP3 已有，STEP4 沿用。

---

## 3. `assertAllowed` 的真实方法清单与既有测试约束

### 3.1 定义位置与完整实现

文件 `lib/security/td_readonly_guard.dart`，类 `TdReadOnlyGuard`。

- `assertAllowed`：行 178–196
- `isAllowed`：行 166–167
- `isCloudMutating`：行 169–170
- `isLocalOnly`：行 172
- `TdReadOnlyViolation`：行 13–38

修复后的完整实现：

```dart
static bool isAllowed(String type) =>
    readOnlyMethods.contains(type) || localOnlyMethods.contains(type);

static bool isCloudMutating(Object? type) =>
    type is String && cloudMutatingMethods.contains(type);

static bool isLocalOnly(String type) => localOnlyMethods.contains(type);

/// Throws [TdReadOnlyViolation] for anything that is not a read.
///
/// Unknown method names are rejected as well: a new TDLib method has to be
/// classified deliberately before it can be used.
static void assertAllowed(Object? type, {String? source}) {
  if (type is! String || type.isEmpty) {
    throw TdReadOnlyViolation(type, source: source);
  }
  if (cloudMutatingMethods.contains(type)) {
    throw TdReadOnlyViolation(type, source: source);
  }
  if (!isAllowed(type)) {
    throw TdReadOnlyViolation(type,
        source: source, reason: 'is not on the read-only allowlist');
  }
}
```

### 3.2 设计目的与实际调用方

目的：TG Media 只读，任何云端写入在请求离开进程前就要失败，而不是靠调用点自觉。

调用方只有一处：`lib/td/td_client.dart:108`，位于 `sendJson` 之前。全仓库 `grep assertAllowed` 在 `lib/` 下除定义文件外只此一处——这既是它的强度（单一出口），也是它的盲区（守卫本身错了没人会碰到第二个检查点）。

### 3.3 三张清单

| 清单 | 定义行 | 条数 | 匹配规则 | 来源 |
|---|---|---|---|---|
| `cloudMutatingMethods` | 41 | 64 | `Set<String>.contains`，精确匹配 | 第 3 步按 TDLib 文档手工分类 |
| `localOnlyMethods` | 114 | 8 | 同上 | 名字含删除但只动本地数据：`deleteFile`、`removeFileFromDownloads`、`removeTopChat`、`removeSavedAnimation`、`removeFavoriteSticker`、`removeRecentlyFoundChat`、`downloadFile`、`cancelDownloadFile` |
| `readOnlyMethods` | 136 | 23 | 同上 | 本轮新增。分三组：读类 16（`getMe` `getChats` `getChat` `getChatHistory` `getMessage` `getFile` `getRemoteFile` `getOption` `getUser` `getSupergroup` `getBasicGroup` `getStorageStatistics` `getNetworkStatistics` `loadChats` `searchChats` `searchChatMessages`）、会话/鉴权 7（`setTdlibParameters` `getAuthorizationState` `setAuthenticationPhoneNumber` `checkAuthenticationCode` `checkAuthenticationPassword` `logOut` `close`） |

`isAllowed()` = `readOnlyMethods ∪ localOnlyMethods`。三张清单互不重叠，由用例 `no method is both allowed and cloud-mutating` 守护（行 513）。

**关于「只读」与 `logOut` / 登录类方法**：这 7 个方法确实会改服务端状态（建会话、结束会话），严格按字面不属于「读」。列进白名单是**有意的例外**：没有它们就无法登录、无法退出登录，而两者都是用户在设置页显式触发的动作，且不在任何自动流程里重试调用。审查时若认为「只读」应排除登录登出，需要先改产品定义，而不是只删这几行——删掉会直接把登录页废掉。这一点按事实写在报告里，不隐藏。

`downloadFile` / `cancelDownloadFile` 补进 `localOnlyMethods`：修复前它们不在黑名单里，因此**本来就被放行**；写进白名单是把既有行为显式化，不是放宽。

### 3.4 既有测试的约束

`test/readonly_guard_test.dart`，9 项：

| 行 | 用例 | 约束 |
|---|---|---|
| 23 | no source file names a cloud-mutating TDLib method | `lib/` 全源码零命中 64 个写方法名 |
| 39 | TdClient enforces the guard at its single request choke point | 守卫必须在 `sendJson` 之前 |
| 50 | the storage layer cannot reach Telegram at all | storage 层无 TDLib 引用 |
| 71 | the cache manager has no network dependency | 缓存不触网 |
| 79 | rejects every cloud-mutating method | 64 个写方法逐个必抛 |
| 90 | the core deletions from the task book are covered | 任务书点名的删除方法在名单内 |
| 105 | allows every request the app actually builds | 13 个真实请求必须放行 |
| 134 | deleteFile is documented as local-only and allowed | 本地删除放行 |
| 139 | rejects a missing or non-string @type | `null` / `42` / `''` 必抛 |

**关键结论：修复前没有任何一条用例约束过「未知方法」。** 64 个写方法、13 个真实请求、3 种坏入参，全部覆盖的是「已知」，未知一律落到「都不匹配 → 放行」的默认分支。漏洞能活到第 4 步，原因就在这里。

### 3.5 当前实现是否真的缺少未知方法拒绝检查

是。修复前（`3cb262e` 之前的版本）只有两个分支：

```dart
if (type is! String || type.isEmpty) throw ...;
if (cloudMutatingMethods.contains(type)) throw ...;
// ← 到此结束，未分类方法直接放行
```

doc comment 写的却是「Unknown method names are rejected as well」。注释与实现不一致，实现更宽松。

### 3.6 边界条件核查

| 边界 | 是否可绕过 | 依据 |
|---|---|---|
| 前缀匹配 | 否 | 三处都是 `Set.contains`，纯精确匹配，无 `startsWith` / 正则 / 大小写折叠 |
| 大小写 | 否 | `deleteMessages` 与 `DeleteMessages` 是两个不同 key，后者落到未分类 → 拒绝 |
| 非字符串 `@type` | 否 | 首分支 `type is! String` 先拦 |
| 空串 | 否 | `type.isEmpty` 拦 |
| 缺 `@type` 键 | 否 | 取到 `null` → 首分支拦 |
| 嵌套 payload 对象 | 需注意 | `chatListMain`、`phoneNumberAuthenticationSettings` 这类只在 payload 里出现、不单独发送，源码扫描用例已排除，见 §5 |
| writer ID / 缓存归属 | 无关 | `CacheOwnership.writers` 是另一个模块（`lib/storage/cache_ownership.dart`），与守卫无调用关系，grep 交叉为零 |
| 绕过单一出口 | 部分 | 若将来有人在 `td_client.dart` 之外直接调 tdjson，守卫失效。现有用例 `the storage layer cannot reach Telegram at all` 只覆盖 storage 层，这一点仍是结构性风险 |

### 3.7 两处失败的对应

| 失败 | 测试文件 | 断言 | 根因 | 归类 |
|---|---|---|---|---|
| 锁 JSON 读不到 | `test/security_negative_test.dart:328` | `expect(settings.passcodeEnabled, isFalse)` / `lockEnabled` | 测试手写的 JSON 键名与真实编码不一致 | A 测试自身 |
| 未知方法不抛 | `test/security_negative_test.dart:498` | `expect(() => assertAllowed('someNewMethodFromAFutureTdlib'), throwsA(...))` 实测 `returned <null>` | 实现缺未知方法分支 | B 库真实缺陷 |

---

## 4. 两类问题的分别诊断

### A. 测试自身问题（键名）

- **错误键名**：我手写的 `{"biometric":…, "passcode":…, "autoLock":…}`。
- **真实键名**：`biometricEnabled` / `passcodeRecord` / `autoLockDelay` / `lockOnColdStart`。来源 `lib/security/lock_policy.dart:48-51`（构造函数）、`:58-61`（默认值）、`:347-378`（`_encode` / `_decode`）。同文件既有测试 `test/lock_policy_test.dart:368-372` 用的也是这套真键名。
- **为什么错**：`_decode` 读不到键就回落默认值，默认是「无密码、生物识别关」，于是 `lockEnabled` 为 false，断言全红。测试写错时不会报「键名不存在」，只会报一个看似功能坏了的断言——这类错误的危险在于容易诱导人改实现去迎合测试。
- **修正后强度**：没有降低。改为通过 `encodeLock()` 按真实键名造数据，同时补了 `LockEvaluator.decide` 与 `withBiometrics()` 两条断言，比原来只查两个 bool 更强。
- **是否仍验证原需求**：是。「无密码不得开启 Face ID」仍由三处共同守护——UI 行 `enabled:false`、`AppLockStore.withBiometrics()` 抛错、本条存储层断言。

### B. 库的真实缺陷（未知方法）

- **注释承诺**：`Unknown method names are rejected as well: a new TDLib method has to be classified deliberately before it can be used.`
- **实现实际**：只查黑名单与 `@type` 合法性，未分类方法放行。
- **证明缺陷的用例**：`security_negative_test.dart:498`「an unclassified method name is rejected, not assumed safe」。修复前输出 `Expected: throws <TdReadOnlyViolation> Actual: returned <null>`。**既有测试无法证明**——§3.4 的九项里没有一项覆盖未知方法，这也是这条缺陷长期存在的原因，已如实记在报告里，不粉饰。
- **最小安全修复**：
  1. 新增 `readOnlyMethods`（23 项）作正面清单；
  2. `assertAllowed` 加 `if (!isAllowed(type)) throw`；
  3. `TdReadOnlyViolation` 加 `reason` 字段，把「写方法」与「未分类」两种拒绝原因分开，否则日志会把一次读取报成「cloud-mutating」，误导排查。
  改动 3 个位置、未删任何黑名单、未改精确匹配语义，是收紧。
- **修复后的三条证明**：
  1. `no method is both allowed and cloud-mutating` —— 三张清单交集为空，且 `readOnlyMethods.length > 10`。
  2. `an unclassified method name is rejected` —— `someNewMethodFromAFutureTdlib` 必抛。
  3. `every method td_requests.dart can build is on the allowlist` —— 直接扫 `lib/td/td_requests.dart` 的 `'@type': 'X'`，每个 X 必须被 `assertAllowed` 放行。这一条是防「修复把登录流程写死」的护栏：新增请求构造器若忘了分类，测试立刻红，而不是等到登录页白屏。

---

## 5. 文档修改清单与原因

| 文件 | 位置 | 改动 | 原因 |
|---|---|---|---|
| `docs/PRODUCT-SPEC.md` | §10 修订记录 | 新增 v3 块 | 第 4 步需要可追溯的规范版本 |
| 同上 | §11 | 6 条原条款保留，加结论/依据/落地位置三列 | 用户已确认 5 项，第 6 项仍按「不做」；不删原条款是任务书明令 |
| 同上 | §12 | 加阶段状态表，原 A–E 条目与依赖图一字未改 | 让验收进度可见，同时不动验收标准 |
| 同上 | §4.2 手势表 | 「长按（可选）｜暂停并显示继续播放」→「长按｜无操作」 | 与已确认决策冲突，规范必须与实现一致 |
| 同上 | §9.5 | 追加 10 项负向清单 | 任务书要求 10 项，原文 8 项未删 |
| `docs/STEP4-REPORT.md` | 新建 212 行 | 按 STEP3 的 9 段结构 | 报告格式唯一来源是 STEP3 |
| `docs/STEP4-CI-CHECK.md` | 新建（本文件） | 7 项检查结论 | 本轮任务书要求 |

未做的文档改动：§13「明确不做」未动；`DOWNLOAD-DEPENDENCY-MAP.md` 未动（阶段 E 才处理）。

---

## 6. CI 最新真实状态

### run `40311608168`（提交 `efe48f4`）

```
status: completed   conclusion: success   时长 6m35s
runner: macOS 26.6.2 arm64 · Xcode 26.6 (17F113) · Swift 6.3.3 · iOS SDK 26.5 · CocoaPods 1.17.0
steps:  21 步全部 success（含 Analyze、Unit tests、xcodebuild、符号校验、IPA 打包、上传产物）
test:   00:50 +548 ~1: All tests passed!
IPA:    TGMediaProbe-unsigned.ipa  19,760,196 B
sha256: 61c415cdcb6efa4327ef97bd125f099469411e463b0aa0b0f03a7ceef5820df1
```

### run `40323987034`（提交 `02dbea5`，文档提交）

首次查询（2026-10-26 20:45 GMT+8）为 `in_progress`，step 16 xcodebuild 进行中；复查询时已完成：

```
status: completed   conclusion: success   5m01s（12:37:40Z → 12:42:41Z）
step  1–21  全部 success
test:   00:44 +548 ~1: All tests passed!（取自 ci-report 分支 7e9a03b）
IPA:    TGMediaProbe-unsigned.ipa  19,760,188 B
sha256: a24b84f400ab242bb9e9f2e30652c702700c7fd2d6d1dfe00f4784f24d1c493c
bundle: com.tgmedia.tgMediaProbe · minos 15.2
inspect: TDLib 静态链接进 Runner，四个 tdjson 符号全部导出
```

**与 `40311608168` 的产物差异：同一个代码树（文档提交不改代码），两次 IPA 体积差 8 B、sha256 不同**（19,760,196 / `61c415cd…` vs 19,760,188 / `a24b84f4…`）。zip 打包时间戳与文件顺序导致，属构建非确定性；**不能把 sha256 当成代码指纹**，比对代码要看提交 SHA。

本次 run 的结论只证明「文档提交没破坏构建」，不产生新的功能证据。功能证据仍以 `40311608168` 为准。

### 三个 run 的产物体积漂移

| run | 提交 | 结论 | 耗时 | IPA 字节 | sha256 前 8 位 |
|---|---|---|---|---|---|
| 40311608168 | `efe48f4` | success | 6m35s | 19,760,196 | `61c415cd` |
| 40323987034 | `02dbea5` | success | 5m01s | 19,760,188 | `a24b84f4` |
| 40325142273 | `dd96a98` | success | 5m37s | 19,760,170 | `ee441473` |

三个提交的 `lib/` 完全相同（`02dbea5`、`dd96a98` 只改 `docs/`），IPA 体积却相差 26 B，哈希全不相同。结论：**sha256 不是代码指纹**，只能用来核对「手里这个包是不是那一次跑出来的」；比对代码版本一律看提交 SHA。每次文档提交都会再触发一个 run，上表只收录已有结论的 run。

---

## 7. 未验证项与后续建议

| 级别 | 未验证项 | 说明 |
|---|---|---|
| 高 | 真机 Face ID 四条路径 | 冷启动弹窗、取消、回退密码、无密码时行置灰。Dart 层 39 项通过，系统弹窗交互未跑 |
| 高 | 真机横屏旋转 | 打开系统方向锁后应看到「系统方向锁已开启，无法自动旋转」。iOS 15 分支走 `UIDevice.setValue(forKey:)`，属非公开行为 |
| 高 | 100 次真机切换 | Dart 层压测 `liveCount` 恒为 1；AVPlayer 真实释放只能真机看 |
| 高 | 真实 TDLib 数据链路 | 频道列表、`getChatHistory` 分页、视频播放，本机到 Telegram 不通 |
| 中 | 重启后会话与锁状态恢复 | 依赖 Keychain 与 `td.binlog`，只有装机可验 |
| 中 | IPA 安装 | 无签名，需 TrollStore / 自签 |
| 中 | 阶段 E 六态矩阵走查 | 未执行，无记录 |
| 中 | 守卫单一出口的结构性风险 | 若将来绕过 `TdClient.sendJson` 直接调 tdjson，守卫失效；建议补一条「lib/ 下除 td_client.dart 外不得出现 tdjson 调用」的源码扫描用例（**建议，未实现**） |
| 低 | `readOnlyMethods` 手工维护 | 23 项由人工分类，TDLib 升级后需重跑 `every method td_requests.dart can build is on the allowlist`；建议再加一条「td_requests.dart 里每个 `@type` 都能从 TDLib 文档找到」的外部校验（**建议，未实现**） |

后续顺序建议：装 IPA → 先测锁的四条路径（锁在最前，锁坏了后面都没意义）→ 再测旋转失败提示 → 再测 100 次真机切换 → 最后接真实账号跑数据链路。每一步的结果回填 `docs/STEP4-REPORT.md` §6，不新开文件。

---

## 附：本轮命令与产物

```
flutter analyze                     → No issues found
flutter test                        → 00:40 +548 ~1: All tests passed!
flutter test test/readonly_guard_test.dart test/security_negative_test.dart
                                    → 00:03 +41: All tests passed!
git log  3cb262e → efe48f4 → 02dbea5 → 本文件所在文档提交
CI       40311608168  success  6m35s   efe48f4   19,760,196 B  sha256 61c415cd…
         40323987034  success  5m01s   02dbea5   19,760,188 B  sha256 a24b84f4…
         40325142273  success  5m37s   dd96a98   19,760,170 B  sha256 ee441473…
```

本机：Windows 11 / Flutter 3.47.8（`/c/flutter-sdk`）/ Dart 3.13.7。
运行测试必须剥掉代理变量，否则 `flutter_tester` 把 `HTTP_PROXY` 当代理，25 个测试文件全部加载失败：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY=127.0.0.1,localhost /c/flutter-sdk/bin/flutter test
```
