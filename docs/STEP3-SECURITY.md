# 第 3 步安全与稳定性工作报告

分支：`rebuild-step3`
基线：`3480894`（第 3 步真机通过点）
本轮提交：`0d236b1`
生成时间：2026-10-26

---

## 1. 本轮范围

第 3 步「稳定性与数据安全」。只做底层与设计，不做 UI。

按需求书 §五列的 8 项，逐项对应：

| # | 要求 | 本轮交付 |
|---|---|---|
| 1 | 敏感信息与日志脱敏 | `lib/util/redact.dart` 扩充至 9 类模式 + 诊断导出脱敏 |
| 2 | 登录持久化的安全设计与必要基础 | `lib/td/session_state.dart`（启动决策表可测） |
| 3 | Face ID 的安全设计、状态管理、可测接口 | `lib/security/biometric.dart` + `lock_policy.dart` + `passcode.dart` + 原生通道 |
| 4 | 播放器生命周期、异步取消、资源释放 | `lib/util/latest_only.dart` + 100/1000 次切换压测 |
| 5 | 缓存清理安全边界与白名单 | `lib/storage/cache_ownership.dart` + `temp_zone_report.dart` 改造 |
| 6 | 数据库、索引、下载记录、账号授权保护 | 已有 zone 守卫复核；`session_state.dart` 的密钥缺失分支 |
| 7 | 只读检查 | 已有 `TdReadOnlyGuard` 复核 + 源码扫描测试 |
| 8 | 自动化测试与 iOS CI 回归 | 399 通过 / 1 跳过；CI 见 §5 |

---

## 2. 修改文件清单

### 2.1 新增

| 文件 | 行数 | 用途 |
|---|---|---|
| `lib/util/sha256.dart` | 235 | SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 纯 Dart 实现，附恒定时间比较 |
| `lib/security/passcode.dart` | 226 | 应用密码的 PBKDF2 验证器、记录编解码、失败退避曲线 |
| `lib/security/biometric.dart` | 266 | 生物识别能力快照、结果枚举、`BiometricGate` 接口、MethodChannel 实现、可编排测试替身 |
| `lib/security/lock_policy.dart` | 419 | 应用锁设置、解锁判定、结果后处理、忘记密码恢复方案、Keychain 持久化 |
| `lib/td/session_state.dart` | 306 | 授权阶段映射、启动决策表、重新登录同意书 |
| `lib/storage/cache_ownership.dart` | 126 | 缓存写入方白名单与路径归类 |
| `lib/util/latest_only.dart` | 112 | 代次判定、`LatestOnlySlot`、`InFlightRegistry` |
| `docs/PRODUCT-SPEC.md` | — | 产品规格 v2（含本轮全部修订） |
| `docs/DOWNLOAD-DEPENDENCY-MAP.md` | — | 下载代码依赖分析与三步删除顺序 |
| `docs/STEP3-SECURITY.md` | — | 本文件 |

### 2.2 修改

| 文件 | 改了什么，为什么 |
|---|---|
| `lib/util/redact.dart` | 新增 64 位库密钥、JWT、bot token、Bearer、query 参数、邮箱、PBKDF2 记录六类模式；新增 `redactDiagnostics` 与 `mayContainSecret`。原因：原来只覆盖 32 位 hash 与 E.164 手机号，库密钥（64 位 hex）会漏网 |
| `lib/storage/temp_zone_report.dart` | 删除规则从「临时区内所有文件」改为「白名单目录内的文件」；新增 `skippedUnknown` / `unknownBytes` / `reclaimableBytes`。原因：需求明确要求未知文件跳过，原实现会删掉未登记目录 |
| `ios/Runner/AppDelegate.swift` | 新增 `BiometricChannel`（`LocalAuthentication`），注册到隐式引擎。原因：Face ID 需要原生能力，且 iOS 侧要负责把 `LAError` 映射成稳定字符串 |
| `ios/Runner/Info.plist` | 新增 `NSFaceIDUsageDescription`。原因：缺少该键时 `evaluatePolicy` 直接失败 |
| `test/temp_zone_report_test.dart` | 用例「reaches a nested directory that no cache kind knows about」改为「跳过并报告」；新增「散落文件跳过」「已登记写入方仍会清理」；inventory 用例补未知文件断言。原因：旧用例断言的正是本轮被推翻的行为 |

### 2.3 未改动（有意）

| 对象 | 为什么不动 |
|---|---|
| `lib/storage/download_mover.dart`、`download_paths.dart` | 取消下载功能后它们多余，但播放器当前读的是它们复制出来的文件。先删会让播放链路断掉。删除顺序见 `docs/DOWNLOAD-DEPENDENCY-MAP.md` §3 |
| `StorageZone.userDownloads` 枚举值 | 它是 `assertDeletableByCacheClear` 的安全边界的一部分，不是功能开关。随下载代码一起在最后一步移除 |
| `lib/td/td_models.dart` 的 `AuthStage` | 与新增的 `LoginPhase` 有重叠。本轮不合并，避免改动已验证的探针页。第 4 步统一到 `LoginPhase`，见 §9 遗留风险 |
| 依赖版本 | 未新增任何 pub 依赖，未修改 `pubspec.yaml` |

---

## 3. 自动化测试

### 3.1 新增测试

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/sha256_test.dart` | 23 | FIPS 180-4 报文向量（含 55/56 字节填充边界、百万个 a）、RFC 4231 HMAC 向量、PBKDF2 已知向量（1/2/4096 迭代）、恒定时间比较、hex 往返 |
| `test/passcode_test.dart` | 31 | 确定性、盐变化、低迭代记录在默认强度提升后仍可验证、篡改一位、损坏记录 fail closed、非 ASCII 密码、记录编解码、退避曲线 |
| `test/biometric_test.dart` | 21 | 能力判定（无硬件时不能认证）、传感器名称不假定 Face ID、结果分类（失败需回退 / 取消不回退）、MethodChannel 映射、异常不变成成功 |
| `test/lock_policy_test.dart` | 39 | 默认 Face ID 关闭、无密码不能开生物识别、解锁判定全矩阵（冷启动 / 后台时长 / 自动锁定四档）、传感器锁定时回退、手动改坏的存储不锁死、持久化往返（含含引号换行的提示词）、损坏 JSON 回退 |
| `test/session_state_test.dart` | 25 | 13 个授权状态映射、只有 Ready 算已登录、打开数据库阶段不算登出、启动决策表全组合、密钥缺失时阻塞而非重建 |
| `test/cache_ownership_test.dart` | 13 | 白名单 id 与 `StorageLayout` 目录名一致、前缀相似目录不被接受（`thumb_old`）、根目录散落文件不认领、路径穿越拒绝 |
| `test/switch_stress_test.dart` | 21 | 100 次与 1000 次顺序切换、100 个 activate 并发、慢加载被丢弃、失败混入不累积、后台与内存告警交错、`LatestOnly` 过期结果丢弃、`InFlightRegistry` 去重与上限 |
| `test/redact_extended_test.dart` | 18 | 六类新凭据形状、不误伤 11 位消息 id 与文件大小、幂等、诊断导出两级脱敏、`mayContainSecret` 正反例 |

### 3.2 运行结果

```
$ flutter analyze
No issues found! (ran in 8.7s)

$ flutter test
00:23 +399 ~1: All tests passed!
```

399 通过，1 跳过（TDLib 原生库在桌面测试环境不可加载，用例本意如此），基线 204 → 新增 195。

### 3.3 反向验证（确认测试能抓 bug）

做了四次注入，每次都能让对应用例变红，之后还原：

| 注入的缺陷 | 变红的用例 |
|---|---|
| `CacheOwnership.classify` 把未登记目录当作已登记 | `clean leaves a directory no cache writer claims alone, and names it`、`inventory counts unknown files but excludes them from reclaimable space` |
| `isKnown` 退化为「在临时区内即算已知」 | `classify a path that only looks like a known writer is rejected` |
| `LockEvaluator.decide` 允许无密码时要求生物识别 | `a hand-edited store with biometrics but no passcode does not lock out` |
| `needsUserActionFor(openingDatabase)` 返回 true | `opening the database is not a logout`、`non-input phases do not` |

第三条和第四条对应的是历史上真实发生过的两个故障：锁死用户、每次冷启动都要手机号。

---

## 4. 设计说明

### 4.1 登录持久化

**现状**：TDLib 数据库在 `Library/Application Support/tgmedia/secure/tdlib/db`（持久），密钥在 Keychain（`tg_tdlib_db_key_v1`，32 字节，`first_unlock_this_device`）。TDLib 自己会在重开后恢复授权，不需要应用重新登录。

**本轮补的是「决策」**：以前没有任何代码回答「重开时要不要显示登录页」。`SessionBootPlanner` 把这件事变成一张可测试的表：

| 密钥 | 数据库 | 阶段 | 动作 |
|---|---|---|---|
| 有合法 | 有 | Ready | 直接进 |
| 有合法 | 有 | WaitTdlibParameters | **等待**（不是登出） |
| 有合法 | 有 | 任一需输入阶段 | 进登录页，复用同一 client |
| 有合法 | 有 | Closed / LoggingOut | 进登录页 |
| 有合法 | 有 | 未知 | 等待 |
| 非法 | 任意 | 任意 | 阻塞，要用户决定 |
| 无 | 有 | 任意 | 阻塞，要用户决定 |
| 无 | 无 | 任意 | 首次登录 |

**风险 1**：`WaitTdlibParameters` 的正确处理要求「等待」而不是「判断」。实现时如果为了消除首屏等待而提前读 Keychain 判断，就会重新引入每次要手机号的问题。这条写成测试钉住了。

**风险 2**：`AuthorizationState` 的未知值。TDLib 升级可能引入新的 `authorizationStateXxx`。当前处理是「未知 → 等待，不弹登录页」，代价是如果真出现需要用户输入的新阶段，界面会停在等待。选择这个方向的理由：误弹登录页会让已登录用户重新验证，误等待只是慢一拍。

**风险 3**：`td.binlog` 文件锁。同目录第二个实例会失败（`Can't lock file`）。当前设计是全 App 一个 client；第 4 步加锁屏页时，锁屏必须复用同一个 client，不能新建。

### 4.2 Face ID

**分层**：

```
LockEvaluator.decide()      什么时候该锁（纯函数，39 个用例）
        ↓
BiometricGate.authenticate() 有没有通过（接口，测试用 ScriptedBiometricGate）
        ↓
BiometricChannel (Swift)     LAContext.evaluatePolicy
```

**几条刻意的选择**：

1. **默认关闭，且没有密码就不给开。** 生物识别单独存在等于「传感器一旦失效就永久进不去」。`withBiometrics(true)` 在无密码时返回原对象，调用方必须提示先设密码。
2. **只用 `.deviceOwnerAuthenticationWithBiometrics`。** 不用 `.deviceOwnerAuthentication`，因为后者会自动接受设备密码 —— 那意味着知道手机密码的人就能进应用，应用锁形同虚设。
3. **结果用字符串传，不用 `LAError` 数字。** 数字码在 iOS 版本间会变，`biometryLockout` 被误读成 `error` 的后果是「识别人脸失败」被显示成「识别不可用」，用户会去重设面容而不是重试。
4. **PBKDF2 记录自带迭代次数。** 提高强度不影响旧记录。测试钉住了「100 次迭代的旧记录在默认 120000 时仍可验证」。
5. **密码是恒定时间比较。** 早期退出的比较会泄露前几位匹配了几个字节。

**风险 1**：120000 次 PBKDF2 在 A7 级核心上约 0.1–0.3 秒。必须放到 `Isolate.run` 里，否则解锁页会掉帧。这一条本轮只写进注释，未实测耗时 —— 属于待真机验证。

**风险 2**：`AppLockStore` 的 JSON 是手写编解码（避免把 `dart:convert` 拉进冷启动路径）。手写解析器的边界条件是转义序列，已有测试覆盖引号、反斜杠、换行。但如果将来加字段，解析器要同步改 —— 加字段时必须补测试。

**风险 3**：忘记密码只能靠 Telegram 重新验证。这是唯一既不弱化也不锁死的方案，但它把「重置应用锁」的强度绑到了 Telegram 账号上。**这一条需要你确认**（见 §10 第 5 项）。

### 4.3 缓存清理

**两层判定，缺一不可**：

1. **区域**：文件必须解析到 `Library/Caches/tgmedia` 内部（跟符号链接）。这是原有的守卫。
2. **归属**：必须有登记过的写入方认领。这是本轮新增的。

原来的实现只有第 1 层，注释里写的理由是「新加一个写入目录不需要改这个文件」。这个理由在「多加一个缓存目录」时成立，在「删除一个来路不明的文件」时不成立。需求明确要求未知文件跳过，所以改成白名单。

**代价**：将来新增缓存目录要先登记，否则文件不会被回收。这是有意的取舍 —— 忘记登记的代价是占空间，删错的代价是丢数据。

**报告口径**：`bytes`（占用）与 `reclaimableBytes`（可承诺释放）分开。以前两者是同一个数，导致「清理完还剩 200MB」看起来像 bug。

### 4.4 只读

`TdReadOnlyGuard` 在 `TdClient.request` 里拦截，不是 UI 约定。`readonly_guard_test.dart` 扫 `lib/` 下全部源码找禁止的方法名，出现即失败。

本轮新增代码里没有任何 TDLib 请求，只读约束自然满足。`downloadFile` 属于白名单（本地下载，不写云端）。

---

## 5. CI

| 项 | 值 |
|---|---|
| 运行 | 40303635700 |
| 分支 | `rebuild-step3` |
| 提交 | `0d236b1` |
| 结果 | 见下方补充 |

构建包含：`analyze`、`unit tests`、TDLib xcframework 校验、`xcodebuild` 未签名构建、TDLib 符号检查、IPA 打包。

CI 结果与 IPA 指纹在本文件末尾补记（写入时运行尚未完成）。

---

## 6. 功能状态矩阵

严格按五种状态标注。**没有任何一项声称真机验证通过。**

### 6.1 已实现 + 自动测试通过

| 功能 | 覆盖 |
|---|---|
| 应用密码哈希与校验 | 31 用例 |
| 失败退避曲线 | 4 用例 |
| 生物识别能力判定与结果分类 | 21 用例 |
| 解锁判定（冷启动 / 后台 / 自动锁定 / 传感器状态） | 39 用例 |
| 忘记密码恢复方案 | 3 用例 |
| 授权阶段映射与启动决策 | 25 用例 |
| 缓存写入方白名单 | 13 用例 |
| 未识别文件跳过与报告 | 4 用例 |
| 100 / 1000 次切换无泄漏 | 21 用例 |
| 过期结果丢弃、缩略图去重 | 6 用例 |
| 日志脱敏（9 类模式） | 18 + 5 用例 |
| 诊断导出脱敏 | 3 用例 |

### 6.2 已实现，自动测试只能覆盖到边界

| 功能 | 说明 |
|---|---|
| `BiometricChannel`（Swift） | Dart 侧用 MockChannel 测了协议；Swift 侧没有测试目标，只能靠编译 + 真机 |
| Keychain 读写 | `KeychainSecretStore` 走 `flutter_secure_storage`，桌面测试用 `MemorySecretStore` 替代 |

### 6.3 未实现（第 4 步）

| 功能 | 原因 |
|---|---|
| 三 Tab 壳 | UI 属于第 4 步 |
| 频道列表与同步 | 同上 |
| 抖音式视频页（全屏、手势、控制层） | 同上 |
| 横屏切换的 UI 入口 | 原生通道已就绪，UI 入口待建 |
| 设置页五个分组 | 同上 |
| 解锁页 / 密码输入页 | 同上 |
| 主题切换（`ThemeMode`） | 同上 |
| 下载功能代码移除 | 需先改播放路径，见 `DOWNLOAD-DEPENDENCY-MAP.md` |
| 收藏功能移除 | **本分支无收藏代码**，无需移除 |
| 时长筛选移除 | **本分支无筛选代码**，无需移除 |

### 6.4 未验证（需要在 iPhone 11 Pro 上跑）

| 项 | 为什么必须真机 |
|---|---|
| Face ID 启用 / 成功 / 失败 / 取消 / 备用 | 需要传感器 |
| 面容被系统锁定后的表现 | 需要连续失败 |
| 系统设置里删除面容后 App 的表现 | 需要改系统设置 |
| 后台 30 分钟后自动锁定 | 需要真实前后台切换 |
| 设备重启后解锁恢复 | 需要重启 |
| PBKDF2 120000 次的实际耗时 | 需要在 A13 上测 |
| 关闭 Face ID 后 Telegram 仍在线 | 需要真实登录态 |
| TDLib 会话在重开后恢复 | 需要真实登录态 |
| 缓存清理与真实 TDLib 池 | 需要真实下载产生的文件 |
| 真机 100 次切换 | 需要真实解码器 |

### 6.5 明确没做

- 没有用假数据、假进度、假成功做过任何验证。
- 没有运行过真机测试，因此本文件不包含任何真机结论。
- 没有执行任何 TDLib 云端写操作。

---

## 7. 与现有代码的冲突检查

需求本轮有两处推翻前版，逐条记录冲突与处理。

### 7.1 「保留下载功能」→「取消下载功能」

**冲突**：第 3 步已验证的链路是「TDLib 池 → 复制到 Documents → 播放器读 Documents」。取消下载后第 8 步（`media_probe.dart:392-425`）多余。

**处理**：本轮不动代码。原因：播放器现在读的正是复制出来的文件，直接删除会让播放断掉。删除必须分三步（改播放路径 → 删复制代码 → 删 zone），已在 `DOWNLOAD-DEPENDENCY-MAP.md` 写明，并标出「不要删 `td_requests.downloadFile`」—— 那个是拉流入口，不是下载功能。

**已生效的部分**：设置页规格不再有下载记录 / 下载管理；`docs/PRODUCT-SPEC.md` §5.3 只留缓存。

### 7.2 「未知文件跳过」与上一轮的「整区清理」

**直接冲突**。上一轮 `cleanTempZone` 删除 `tempRoot` 下全部文件，注释明确写着「新加一个写入目录不需要改这个文件」。本轮需求要求未知文件跳过。

**处理**：已改为白名单。原测试 `reaches a nested directory that no cache kind knows about` 断言「能删未知目录」，与需求相反，已改写为「跳过并报告」。这是本轮唯一一处推翻既有测试的地方，原因是需求变了，不是测试写错了。

### 7.3 「抖音右侧操作区」→「不采用」

**冲突**：参考截图 1 和 3 都有右侧竖排操作区。旧任务书 §B 的视觉要求没有明确禁止。

**处理**：`PRODUCT-SPEC.md` §4.1 明确「不设右侧竖排操作区」，§6.1 列出参考图的「取」与「不取」清单，把右侧栏放进了「不取」。第 4 步按新规格做。

### 7.4 收藏与时长筛选

**无冲突**：本分支（第 3 步基线）没有收藏代码、没有时长筛选、没有三 Tab。这些是第 4-8 步的东西，随 v1 归档在 `main`。当前分支无需移除。

### 7.5 两套授权阶段枚举

**已知重复**：`td_models.dart` 的 `AuthStage`（8 个值，探针页在用）与新增的 `LoginPhase`（13 个值）。

**处理**：不合并。`AuthStage` 被已验证的探针页引用，动它有回归风险。第 4 步统一到 `LoginPhase` 并删除 `AuthStage`。记在 §9。

---

## 8. 交付

| 项 | 内容 |
|---|---|
| 修改文件 | §2（7 个新增 lib 文件、5 个修改、3 个新增文档） |
| 自动化测试 | §3（8 个新测试文件，195 个新用例） |
| 静态分析 | `No issues found!` |
| 测试结果 | 399 通过 / 1 跳过 |
| 反向验证 | 4 处注入缺陷全部被抓出 |
| CI | §5 |
| 功能清单 | §6（分五档，无真机结论） |
| 设计说明与风险 | §4 |
| 第 4 步计划 | `docs/PRODUCT-SPEC.md` §12 |
| 待确认 | §10 |

---

## 9. 遗留风险

| # | 风险 | 影响 | 建议 |
|---|---|---|---|
| 1 | 两套授权枚举并存（`AuthStage` / `LoginPhase`） | 第 4 步如果继续用 `AuthStage`，13 个阶段里有 5 个（邮箱、注册、其他设备、premium）会被归到 `unknown` | 第 4 步阶段 B 统一到 `LoginPhase` |
| 2 | PBKDF2 未做 isolate 化 | 解锁时可能卡 0.1–0.3 秒 | 接 UI 时用 `Isolate.run`，并实测 |
| 3 | 忘记密码依赖 Telegram 重新验证 | 重置强度绑到 Telegram 账号 | 需要确认 |
| 4 | 播放器读的是复制出来的文件 | 取消下载后播放路径要改，改之前 TDLib 池里的文件可能被 LRU 回收 | 第 4 步阶段 E 第一步先验证「直接读池 30 秒不丢」 |
| 5 | `AppLockStore` 手写 JSON | 加字段时解析器要同步改 | 加字段必须补测试 |
| 6 | `BiometricChannel` 无 Swift 单测 | 只能靠编译与真机 | 保持映射表简单，不加重试逻辑 |

---

## 10. 需要确认

| # | 事项 | 需要你决定 |
|---|---|---|
| 1 | 「仅 Wi-Fi 播放」是否要 | 需要网络类型监听与一个原生依赖 |
| 2 | 长按视频的行为（暂停 / 菜单 / 无） | 影响手势冲突处理 |
| 3 | 抖音页顶部是否保留搜索入口 | 影响顶部安全区布局 |
| 4 | 横屏时是否隐藏底部信息区 | 影响横屏沉浸度 |
| 5 | 忘记密码重置时，是否允许保留当前 Telegram 会话（不重新登录） | 允许 = 强度降低（拿到手机的人可绕过应用锁）；不允许 = 当前设计 |
| 6 | 频道页是否需要「仅显示有视频的频道」筛选 | 影响 `getChats` 后的本地过滤 |

未确认前一律按「不做」处理。

---

## 11. 停止

第 3 步到此。第 4 步不自动开始，等确认。
