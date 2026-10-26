# 第 4 步验收补强报告

生成时间：2026-10-26 22:30 (GMT+8)
分支：`rebuild-step3`
补强提交：`2d918ab5d511056fd44f2f1d48dff6e1d36504c3`
CI：run [40338279166](https://github.com/1585365426/tg-media-probe/actions/runs/40338279166) — **success，7m50s**
产物：`TGMediaProbe-unsigned.ipa` **19,780,496 B**，sha256 `cd7f90a74080c8dc580852e002ee9574dc3b8def1c04a48f68a6f1207b7cf6bf`

本轮只做补强：加测试、修被测试抓出的边界问题、记录事实。没有重新开发功能，没有开始第 5 步，没有新增用户下载功能，没有删除或放宽任何既有断言。

---

## 0. 基线核对

| 项 | 指令给的 | 实际 | 处理 |
|---|---|---|---|
| 分支 | — | `rebuild-step3` | 一致 |
| 基线提交 | `cc4a1d7` | `08dfb3a`（比基线多一个文档提交 `docs(step4): final report…`） | **报告差异，未回退**。指令给出的 `cc4a1d7` 是"精确 IPA 字节"那次构建；`08dfb3a` 只改 `docs/`，不含代码差异 |
| 工作区 | — | 干净（`git status` 无输出） | 未覆盖任何用户改动 |
| 最新 CI（开始时） | — | run `40332228087` success（`08dfb3a`） | 记录在案 |

---

## 1. 阶段 A：安全边界测试

### 1.1 守卫位置（源码 + 行为双重证据）

改造后 `lib/td/td_client.dart` 只剩**一个**把字节交给 tdjson 的地方：

```dart
void _send(Map<String, Object?> request) {
  TdReadOnlyGuard.assertAllowed(request['@type'], source: 'TdClient._send');
  _bindings.sendJson(_clientId, jsonEncode(request));
}
```

`request()` 里也先查一次（拒绝时不留副作用：不消耗 `@extra`、不登记 completer）。

### 1.2 本轮发现并修掉的两个真实缺口

| # | 缺口 | 证据 | 修法 |
|---|---|---|---|
| 1 | `dispose()` 直接调 `_bindings.sendJson(close)`，绕过 `assertAllowed` | 修改前 `td_client.dart:127` 是独立发送点；`readonly_guard_test.dart:44` 的 `indexOf` 只比较了第一处，测不到第二处 | 收拢到 `_send()`，守卫写进函数体内；`close` 本就在白名单内，行为不变，但结构上不再有第二个门 |
| 2 | `TdJsonBindings.executeJson()`（`td_execute`）完全绕开守卫，可同步执行任意方法 | `tdjson_ffi.dart` 原样绑定 `td_execute`，无任何调用前检查 | 保留绑定（被既有 `tdjson_load_test` 用于读 version），但新增源码扫描断言：**`lib/` 下除 `tdjson_ffi.dart` 外任何文件出现 `executeJson(` 即失败**；并在文件头写明"要用它必须先过守卫" |

### 1.3 新增回归测试 `test/readonly_boundary_test.dart`（12 项）

不再只靠"grep 源码里有没有写方法"，而是让假的 bindings 记录**真的发出去的东西**（`TdClient.withBindings` + `testingBindings`）：

| 用例 | 断言 |
|---|---|
| 源码扫描：其他文件不得出现任何 tdjson 符号 | `TdJsonBindings`/`DynamicLibrary`/`td_send`/`td_receive`/`td_execute`/`td_create_client_id`/`sendJson(`/`receiveJson(`/`executeJson(` → 除 `td_client.dart` 与 `tdjson_ffi.dart` 外零命中 |
| 只有 td_client 能 import FFI 层 | 其余文件出现 `tdjson_ffi.dart` 即失败 |
| 发送语句恰好一条 | `_bindings.sendJson(` 出现次数 == 1 |
| 守卫与被守卫语句在同一函数内且在前 | 以 `void _send(` 为界定位，守卫索引 < 发送索引 |
| `executeJson` 不得被调用 | 除 `tdjson_ffi.dart` 外零命中 |
| 写方法被拒且一个字节都没发出 | `request(sendMessage)` 抛 `TdReadOnlyViolation`，`sent` 为空 |
| 未分类方法默认拒绝 | `someFutureTdlibMethod` 抛异常，`reason` 含 `allowlist` |
| 缺 `@type` 拒绝且不发送 | 同上 |
| 允许的读请求真的发出去了 | `getChats` → `sent` 有 1 条且带 `@extra`；因假 bindings 不回应而超时，这恰好证明已发送 |
| `dispose` 的 `close` 过守卫 | `sent` 含 `close` |
| 7 个会话/登录方法全部放行 | `setTdlibParameters`/`getAuthorizationState`/`setAuthenticationPhoneNumber`/`checkAuthenticationCode`/`checkAuthenticationPassword`/`logOut`/`getMe` 逐个确认到达 tdjson |
| 近似名字仍然被拒 | `sendMessageAlbum`/`forwardMessages`/`deleteChatHistory`/`setChatTitle`/`someNewMethodFromAFutureTdlib` 全部拒且零发送 |

### 1.4 既有守卫测试

`test/readonly_guard_test.dart` 9 项**一行未改**，全部仍通过（64 个写方法逐个被拒、13 个真实请求放行、坏 `@type` 被拒、源码零命中、storage 层摸不到 TDLib）。

---

## 2. 阶段 B：界面与播放器

### 2.1 `FailureView` widget 测试（`test/failure_view_test.dart`，9 项）

| 状态 | 断言 |
|---|---|
| 加载 | 有 `CircularProgressIndicator`、有标题、**没有**按钮 |
| 空内容 | 标题 + 说明 + 动作按钮，点击回调触发一次，无进度圈 |
| 一般错误 | 「读取失败」、详情文本可见、「重试」可点且回调触发 |
| 权限不足 | 「没有权限读取这个内容」+ 成员/限制说明，**无重试按钮** |
| 登录失效 | 「登录已失效」+ 引导重新登录，**无重试按钮** |
| 离线 / 限流 | 两种都保留「重试」 |
| 限流文案 | 含「等待」，明说连点会更糟 |
| 五种失败标题互不相同 | 防止文案塌成一个字符串（塌了六态走查就是假的） |
| 可重试但没有回调 | 不渲染按钮（不留死控件） |

### 2.2 播放器切页生命周期（`test/feed_controller_test.dart` 新增 3 项，总 34）

给 `PlayerLedger` 加了有序事件流（`create` / `load` / `pause` / `dispose`），补的是"只看计数看不出顺序"这个盲区：

1. 切页时**旧播放器先 pause+dispose，之后才 create 新的**（按事件索引断言，不只看 `live==1`）。
2. 解析被抢跑：两次连续切换后 `live == 1`，不留孤儿播放器。
3. 5 次快速切换：`creates - disposes == 1`。

既有的「100 次切换 live=1」「过期解析不得覆盖当前项」「离开的项取消传输」三条未改动，仍通过。

### 2.3 `VideoSourceResolver` 审查结果

| 检查项 | 结论 |
|---|---|
| 超时 | 15 s 到点即 `cancel` 并抛 `VideoSourceTimeout`，文案写明秒数（既有 2 项覆盖） |
| 取消 | `_cancelled` 记录后拒绝迟到的完成（既有 1 项） |
| TDLib 错误透传 | `VideoSourceException` 原样抛出，不吞成通用错误（既有 1 项） |
| 空路径 | **原来会空转到 15 s 超时**。已改：`isCompleted` 即完成 future，路径为空立刻抛「TDLib 报告下载完成但没有返回本地路径」（新增 1 项） |
| 文件已消失 | **原来直接把不存在的路径交给播放器**。已改：交给播放器前先确认文件存在；记录说完成但文件没了 → 抛「本地文件已不存在（可能被系统或清理工具删除）」（新增 3 项） |

`fileExists` 做成可注入参数（默认 `File(path).exists()`），测试里用替身，线上用真实文件系统。

### 2.4 下载相关（保留读、禁止写）

`test/no_user_download_test.dart`（4 项）把"删除"这件事钉死：

- `lib/` 代码里不得出现 `DownloadMover` / `download_mover` / `download_paths` / `promote(`（注释豁免，只扫代码）；
- 除 `storage_layout.dart`（定义分区）与 `app_paths.dart`（装配分区）外，任何文件不得引用 `downloadsDir` / `TGMediaDownloads`；
- 设置页不得出现「下载管理 / 下载记录 / 保存到相册 / 保存到文件 / 下载历史」；
- **同时断言 `downloadFile` / `cancelDownloadFile` 仍在** `td_requests.dart` —— 删了它所有视频永远停在「正在准备视频」。

### 2.5 TDLib 池内文件可能被 LRU 回收：现状与最小风险方案

**现状（读代码得出，未在真机观察）**：

1. 播放路径是 `getFile` → `downloadFile`（`td_requests.dart:125`）→ `updateFile` 到 `is_downloading_completed` → 把 `file.path` 交给 AVPlayer。
2. 我们没有向 TDLib 声明"这个文件正在使用"。`ActiveFileRegistry` 只对本应用的缓存清理生效，TDLib 不认识它。
3. 因此 TDLib 若做存储优化（`optimizeStorage`，本应用从未调用），或 iOS 在磁盘压力下清理 `Library/Caches`，文件可能在播放中被删掉。
4. **没有证据表明播放器已被保活，本报告不作此声明。** 现有代码既没有调用 `optimizeStorage`，也没有在播放期间重复调 `downloadFile` 刷新优先级。

**最小风险方案（建议，未实施——需真机验证后再决定）**：

- 方案 1（首选，代价最低）：播放开始时记录 `fileId → path` 并用 `ActiveFileRegistry` 标记；切页/退出时释放。仅解决"我们自己删"的问题，已实现。
- 方案 2：播放期间按 `downloadFile` 的 `priority` 参数周期性重发（例如每 10 s，`priority = 32`），把池内该文件标成高优先级。TDLib 侧才会尊重它。需要真机确认是否真能阻止回收。
- 方案 3：把当前播放的单个文件复制到 `Library/Caches/tgmedia/player/`（我们自己的可清理区），播放器读自己的副本。代价是每个视频多占一份磁盘、多一次复制，且退出时要清。这是唯一能完全切断"TDLib 回收"影响的方案，但和第 4 步"取消用户下载"的边界容易混淆，需产品确认。
- 方案 4：完全依赖 TDLib（现状），只保留本轮新增的"文件不存在时给出明确错误 + 重试"。**当前采用的就是方案 4 + 方案 1**。

真机上必须测的一条：连续播放 ≥ 30 秒，观察文件是否被回收（§5 清单第 7 项）。

---

## 3. 阶段 C：数据路径与缓存安全

### 3.1 TDLib 数据库与密钥

| 事实 | 值 | 证据 |
|---|---|---|
| 数据库目录 | `Library/Application Support/tgmedia/secure/tdlib/db` | `storage_layout.dart:107` |
| 所属分区 | `authMeta`（**绝不清理**） | `zoneOf()` 判定，本轮新增测试断言 |
| 密钥生成 | 32 字节，`Random.secure()`，转 64 位小写十六进制 | `tdlib_key.dart` `generate()` |
| 密钥持久化 | Keychain，slot `tg_tdlib_db_key_v1`，`first_unlock_this_device` | `KeychainSecretStore` |
| 密钥缺失（首次启动） | 现场生成并写入，再交给 TDLib | `obtain()` |
| 密钥格式非法 | **抛异常，不覆盖**（覆盖会让现有库彻底打不开） | `obtain()` + `TdlibKeyException` |
| 有库无密钥 | 启动计划判 `blockedNeedsDecision`，让用户决定重新登录，不静默重建 | `session_state.dart:219` |
| 密钥丢失后重新登录 | 会重建本地会话数据；Telegram 云端消息不受影响 | 计划文案 |

`test/tdlib_key_test.dart` 11 项覆盖生成/持久化/格式校验/不覆盖；`test/session_state_test.dart` 有 3 项覆盖"有库无密钥"与"密钥非法"分支。

### 3.2 `files_directory` 与四个可清理目录的对照

| 目录 | 实际路径 | 分区 | 清理是否会碰 |
|---|---|---|---|
| `files_directory`（TDLib 池） | `Library/Caches/tgmedia/tdlib_files` | `tempCache` | **不碰**（见 3.3） |
| `thumb/` | `Library/Caches/tgmedia/thumb` | `tempCache` | 会删 |
| `player/` | `Library/Caches/tgmedia/player` | `tempCache` | 会删 |
| `partial/` | `Library/Caches/tgmedia/partial` | `tempCache` | 会删 |
| 用户下载区 | `Documents/TGMediaDownloads` | `userDownloads` | 不碰（受保护） |
| 索引 | `.../Application Support/tgmedia/index` | `indexDb` | 不碰 |
| 授权/数据库 | `.../Application Support/tgmedia/secure` | `authMeta` | 不碰 |

### 3.3 本轮发现的规范与实现不一致（**未擅自改规范**）

`docs/PRODUCT-SPEC.md` §9.2 把 `tdlib_files/` 列为"可清理（白名单）"，但 `CacheManager.scan()/clear()` 只扫 `thumb` / `player` / `partial` 三类，**从不扫 `tdlib_files`**。

实测证据（新增测试）：真实布局下放 4 KB 池文件 + 512 B 缩略图，执行清理后 `freedBytes == 512`，池文件仍在。

**这不是实现漏了一个循环，而是分层约束**：
- `readonly_guard_test.dart` 里有一条既存测试要求 storage 层**完全不能引用 TDLib**，所以 `CacheManager` 不可能调 `deleteFile` 去让 TDLib 自己也删掉记录；
- 直接在文件系统层面删池文件会让 TDLib 的文件数据库仍认为"已完成"，下次 `getFile` 返回一条指向不存在文件的记录（本轮已在解析器侧加了兜底错误）；
- 要正确地回收池，需要一个"TDLib 感知层"：遍历已下载 file id → `deleteFile`（本地专用、在白名单内）→ 让 TDLib 自己清记录。

**两种收敛方式，需要产品/架构决策（本轮不做）**：
- A：把 §9.2 的 `tdlib_files/` 从"可清理"改为"由 TDLib 管理，应用不直接清"，并新增一个"清理 TDLib 池"的独立动作走 `deleteFile`。
- B：保持 §9.2 不变，在设置页清理流程里加 TDLib 感知的第二步。

在这条决策落地前，设置页只报 `thumb/player/partial` 三个目录的体积（本轮测试断言扫描结果里不含池文件），不会出现"报了能清、点了没清"的假按钮。

### 3.4 清理不删受保护文件 / 只统计真删掉的字节

`test/tdlib_storage_test.dart`（9 项）新增的断言：

1. 数据库目录属 `authMeta`，`assertDeletableByCacheClear` 必抛；
2. 池目录属 `tempCache`，判定放行；
3. 两个目录互不包含（防止将来路径拼接写错导致库被当成池）；
4. 真实布局下清理一次：`td.binlog` 与 `db.sqlite` 逐字节仍在，`freedBytes` 恰好等于被删掉的 512 B；
5. 扫描结果不含池文件（不承诺做不到的回收）；
6. 占用中的缩略图被跳过且不计字节（`freedBytes == 0`）；
7. 连续清理两次，第二次 `freedBytes == 0`、`deletedFiles == 0`；
8. `binlog` 路径判定为 `authMeta` 并拒绝删除；
9. `..` 从 temp 穿越到 secure/tdlib/db 被拒。

既有 `cache_clear_test` 13 项、`storage_zones_test` 12 项、`security_negative_test` 32 项均未改动，仍通过。

---

## 4. 阶段 D：验证结果

| 项 | 结果 |
|---|---|
| `flutter analyze` | ✅ No issues found（本机；CI step 13 同步通过） |
| `flutter test` | ✅ **581 passed / 1 skipped**（本机 `00:41`，CI `01:05`，数字一致） |
| 跳过项 | 1 个：`tdjson_load_test` —— `TDJSON_PATH` 未设置，本机无 TDLib 二进制，**运行时加载未验证** |
| 失败项 | 0 |
| CI 构建 | ✅ run `40338279166` success，7m50s，head `2d918ab`（与本地 HEAD 一致） |
| IPA 字节 | **19,780,496 B**（`ci-report/package.txt` 的 `ipa_bytes`，非 `ls -lh` 四舍五入） |
| IPA SHA-256 | `cd7f90a74080c8dc580852e002ee9574dc3b8def1c04a48f68a6f1207b7cf6bf` |
| 构建核验 | TDLib 静态链接进 Runner，四个 tdjson 符号全部导出；bundle `com.tgmedia.tgMediaProbe`，minos 15.2 |

**CI 成功只等于"能构建"，不等于"装过、跑过"。** 本报告不把它算作任何功能验证。

---

## 5. 分类清单

### 5.1 已验证（有可复现证据）

| 结论 | 证据 |
|---|---|
| 守卫在唯一发送点内，且先于发送 | 源码结构 + `readonly_boundary_test` 4 项源码断言 + 1 项顺序断言 |
| 写方法/未分类方法/坏 `@type` 会被拒，且零字节发出 | 假 bindings 的 `sent` 为空 |
| 登录、验证码、2FA、登出、`getMe` 仍可用 | 7 项逐个断言到达 tdjson |
| `dispose` 的 `close` 也过守卫 | `sent` 含 `close` |
| 除两个文件外，`lib/` 无人能碰 tdjson；`executeJson` 无调用 | 源码扫描 |
| 失败态文案与按钮策略符合设计 | 9 项 widget 测试 |
| 切页时旧播放器先释放 | 有序事件流断言 |
| 池文件/空路径/文件消失三类异常有明确文案 | 4 项 resolver 测试 |
| 数据库目录受保护、清理逐字节不动它 | 真实临时布局跑同一代码路径 |
| 清理只统计真删掉的字节 | `freedBytes == 512`、二次清理为 0 |
| 下载功能未回潮，播放入口仍在 | 4 项扫描断言 |

### 5.2 自动化验证（逻辑成立，但只在 Dart 层）

| 结论 | 边界 |
|---|---|
| 100 次切换 `live == 1` | 替身播放器，不是 AVPlayer |
| 横屏隐藏信息区、控制层保留 | `FeedOverlayPlan` 纯函数 |
| 锁的四种策略路径 | `LockEvaluator` 纯函数 + 控制器时序 |
| 会话状态恢复矩阵 | `SessionBootPlanner` 纯函数 |
| 失败分类（401/403/420/429/超时） | 分类函数 + 目录/控制器传播 |
| 缓存清理的受保护区不被遍历 | 记录型 `FileOps` 替身 |

### 5.3 未验证（本轮没有执行，一律不标通过）

| 项目 | 为什么 |
|---|---|
| IPA 安装与首次启动 | 无设备访问，未安装 |
| 应用密码 / Face ID / 取消 / 回退密码 / 无密码置灰 | 需真机系统弹窗 |
| 横屏旋转与"系统方向锁已开启"提示 | 需真机 + 系统方向锁 |
| 连续 100 次真机切换与播放器释放 | 需真机观察内存与画面 |
| 重启后应用锁与 Telegram 会话恢复 | 需真机 + Keychain + `td.binlog` |
| 真实频道/视频/出帧/音轨/seek | 本机到 Telegram 不通 |
| 连续播放 ≥ 30 秒是否被回收 | 需真机 |
| 缓存清理在真实沙盒路径下 | 单测用临时 sandbox |
| 各页面六种状态的真机观感 | 只有代码层走查 + widget 测试 |

### 5.4 阻塞项

| # | 阻塞 | 影响 | 需要谁 |
|---|---|---|---|
| 1 | 无 iPhone 11 Pro 访问 / 无 TrollStore 安装条件 | §5.3 全部无法推进 | 用户 |
| 2 | 无签名环境，只能用未签名 IPA + TrollStore | 无法走正常安装路径 | 用户 |
| 3 | 本机到 Telegram 不通 | 真实数据链路无法验证 | 用户网络环境 |
| 4 | 规范 §9.2 与实现不一致（池是否可清） | 设置页回收能力受限于此 | 产品/架构决策（§3.3） |
| 5 | TDLib 池保活方案未定 | 长篇播放可能被回收 | 需真机数据后决策（§2.5） |

---

## 6. 真机测试清单（按步骤执行，未执行）

> 说明：以下每一条都**没有执行**。执行时请逐条记录实际现象，失败的写失败，不要写"应该没问题"。

| # | 步骤 | 观察点 | 预期 | 结果 |
|---|---|---|---|---|
| 1 | 用 TrollStore 安装 `TGMediaProbe-unsigned.ipa`（19,780,496 B） | 能否安装、图标是否出现 | 安装成功、图标正常 | 未执行 |
| 2 | 首次启动 | 是否闪退、是否先出解锁页再出登录页 | 不闪退；无锁时直接到登录/壳 | 未执行 |
| 3 | 设置 → 隐私与安全 → 设置应用密码 | 6 位密码设置成功、重启后要求输入 | 输入正确密码进入 | 未执行 |
| 4 | 设置 Face ID 开关（有密码后） | 开关可开；无密码时该行置灰且提示「请先设置应用解锁密码」 | 与描述一致 | 未执行 |
| 5 | 冷启动触发 Face ID | 系统弹窗出现；取消后回到密码框 | 取消不报"密码错误" | 未执行 |
| 6 | Face ID 失败后点"使用应用密码" | 直接落到密码框 | 不再重复弹窗 | 未执行 |
| 7 | 抖音页连播 ≥ 30 秒 | 画面是否卡死、文件是否被回收（可看设置页缓存大小变化） | 30 秒内不出错；若被回收应出现「本地文件已不存在」而不是黑屏 | 未执行 |
| 8 | 抖音页连续切换 100 次 | 是否崩溃、是否出现两个声音同时播放、内存是否持续上涨 | 不崩、不叠音 | 未执行 |
| 9 | 竖屏 → 点转屏按钮 | 是否真的旋转；打开系统方向锁后再点，是否提示「系统方向锁已开启，无法自动旋转」 | 与描述一致 | 未执行 |
| 10 | 横屏状态下看底部信息区 | 信息区隐藏、顶栏搜索仍在、控制层可调出 | 与描述一致 | 未执行 |
| 11 | 长按视频 | 不应有任何反应 | 无反馈、不暂停、不弹菜单 | 未执行 |
| 12 | 冷重启 App | 应用锁是否要求重开；Telegram 会话是否免登录恢复 | 锁要求重开，会话恢复 | 未执行 |
| 13 | 设置 → 忘记应用密码 → 重置 | 是否清除本地会话并要求重新登录 Telegram | 与描述一致 | 未执行 |
| 14 | 频道列表 / 详情页 | 加载、空、错误（开飞行模式）、重试、被禁频道（权限不足）、登出后（登录失效） | 六态文案各不相同；权限与登出**没有**重试按钮 | 未执行 |
| 15 | 真实频道播放 | 出帧、有声音、seek 可用、进度条跟手 | 全部正常 | 未执行 |
| 16 | 设置 → 存储 → 盘点 + 清理 | 盘点数字合理；清理后缩略图目录变小；`Documents/TGMediaDownloads`、索引、登录态均不受影响 | 与描述一致 | 未执行 |
| 17 | 清理时正在播放 | 正在播的文件不被删 | 播放不中断 | 未执行 |
| 18 | 卸载前检查 | 池文件增长情况（判断是否需要 §3.3 的回收动作） | 记录数字 | 未执行 |

---

## 7. 剩余风险

| 级别 | 风险 | 说明 |
|---|---|---|
| 高 | 真机零验证 | §5.3 全部；UI 结论只到 widget 测试 |
| 高 | 池文件回收路径未打通 | §3.3 需决策；当前只能报错，不能自动恢复 |
| 中 | TDLib 池保活缺失 | §2.5，方案 2/3 未实施 |
| 中 | `executeJson` 仍是可绕过的能力 | 已用扫描测试封住调用，但绑定本身还在；若将来有人加调用，测试会红——这是有意为之 |
| 中 | 失败分类依赖 TDLib 文案片段 | 码优先，文案兜底；措辞变了会退化成通用错误 |
| 低 | 1 个跳过用例 | `tdjson_load_test` 依赖 `TDJSON_PATH`，CI 里也不设，长期跳过 |

---

## 8. 下一步建议

1. 先做 §3.3 的决策（池是否可清），再决定设置页是否加"清理 TDLib 池"动作。
2. 装包后按 §6 顺序跑，第 7、8、9 三条最关键（池回收、切换、旋转）。
3. 拿到第 7 条结果后再决定 §2.5 走方案 2 还是方案 3。
4. 第 5 步不要在本报告的任何未验证项上开工。
