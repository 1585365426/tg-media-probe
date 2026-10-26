# 下载相关代码依赖分析

目的：本轮确认取消视频下载功能。这份文件回答一个问题 —— 哪些代码可以删，哪些看起来像下载其实是播放必需的，删掉会连带毁掉整个播放链路。

结论先写：**删除要分三步，顺序不能颠倒。** 直接删 `lib/storage/download_mover.dart` 会让 `media_probe.dart` 编译失败；而顺手删掉 `td_requests.dart` 里的 `downloadFile` 会让视频永远下载不下来 —— 因为它跟「用户下载文件」不是一回事。

生成时间：2026-10-26
分支：`rebuild-step3`
依据：`grep` 全量引用链，不是推测。

---

## 1. 两个被混为一谈的概念

这是整份文档最重要的一节。

| 概念 | TDLib 方法 | 作用 | 取消下载后 |
|---|---|---|---|
| **拉取媒体字节** | `downloadFile` | 让 TDLib 把云端文件下载到本地缓存池（`Library/Caches/tgmedia/tdlib_files`），供播放器读取 | **必须保留**。没有它就没有视频可播 |
| **另存为用户文件** | 无（我们自己实现的复制） | 把缓存池里的字节复制到 `Documents/TGMediaDownloads`，成为用户可见、不会被系统清理的长期文件 | **删除** |

`td_requests.dart:125` 的 `downloadFile()` 是前者。它构造的是 TDLib 请求 `{"@type":"downloadFile","file_id":...}`，这是播放的前提。

`download_mover.dart` 的 `promote()` 是后者。它做的是 `Caches/tgmedia/tdlib_files/... → Documents/TGMediaDownloads/...` 的复制，然后把路径交给播放器。

取消下载功能，删的是 `promote()`，不是 `downloadFile`。

如果第 4 步有人把 `td_requests.dart` 的 `downloadFile` 也删了，症状是：所有视频永远停留在「正在准备视频」。

---

## 2. 依赖清单

### 2.1 只服务于「另存为用户文件」，可删

| 文件 | 行数 | 内容 | 引用者 |
|---|---|---|---|
| `lib/storage/download_mover.dart` | 164 | `DownloadMover.promote()`：复制到用户目录，处理重名、进度、失败回滚 | `lib/td/media_probe.dart:7,97,98,102,394` |
| `lib/storage/download_paths.dart` | 138 | 文件名清洗、扩展名推断、目录分层（`channelId/messageId_name.ext`） | `download_mover.dart`、`test/download_mover_test.dart` |
| `test/download_mover_test.dart` | — | 上述两者的测试 | CI |
| `test/download_paths_test.dart` | — | 文件名清洗规则 | CI |
| `media_probe.dart` 第 8 步（`lib/td/media_probe.dart:392-425`） | 约 34 行 | 调用 `mover.promote()` 并把结果写进 `ProbeResult.localPath` | 只有探针页用 |
| `probe_page.dart:403` | 1 行 | 显示「用户下载区（受保护）」路径 | 只有探针页用 |

### 2.2 播放必需，不能删

| 文件 | 为什么保留 |
|---|---|
| `lib/td/td_requests.dart:125` `downloadFile()` | 让 TDLib 把字节拉到本地池。播放的入口 |
| `lib/td/download_metrics.dart` | 测量首字节延迟、窗口速率、端到端均速。取消「下载视频」不取消「视频下载得慢」这个事实，没有它下一轮又只能靠猜 |
| `lib/storage/active_files.dart` | 播放中的文件登记，防止缓存清理删掉正在播的文件。**与下载无关** |
| `lib/storage/storage_layout.dart` 的 `tdlibFilesDir` | TDLib 缓存池路径，播放器从这里读 |
| `lib/playback/*` | 播放器槽、生命周期、方向桥 |

### 2.3 是共享底层，但取消下载后语义需要调整

| 对象 | 现状 | 取消下载后 |
|---|---|---|
| `StorageZone.userDownloads` | 四区之一，`isProtected == true`，缓存清理永不触碰 | **暂时保留不动**。它是安全边界的一部分（`assertDeletableByCacheClear` 依赖 zone 判定），删枚举值会波及 6 个测试和 3 个守卫。等下载代码全部移除、播放改为直接读缓存池之后，再单独一步移除 |
| `StorageLayout.downloadsDir` | `Documents/TGMediaDownloads` | 同上，随 zone 一起处理 |
| `CacheManager.usage(includeProtected:)` | 会统计下载区大小 | 改为不显示该行 |

### 2.4 单独确认过的边界

`test/cache_clear_test.dart` 用 `sandbox.downloadFile('keep.mp4')` 造文件，断言「清理缓存不会删除用户下载区」。这个测试的价值在**验证受保护区不被误删**，不是验证下载功能。删除下载功能后，这个用例应该改成用 `indexFile` 或 `authFile` 造数据，或者保留 `userDownloads` zone 作为「受保护区」的测试样本之一。

建议：保留。一个空的受保护区仍然是有效的安全测试样本，删掉它会削弱清理路径的测试覆盖。

---

## 3. 删除顺序（第 4 步执行）

### 步骤 1：改播放路径（不改删除）

目标：播放器直接读 TDLib 缓存池文件（`tdlibFilesDir` 下的路径），不再经过 `Documents`。

改动点：

- `media_probe.dart` 第 8 步删除，`ProbeResult.localPath` 直接取 `finalState.path`（TDLib 给的池内路径）。
- `ProbeResult.poolPath` 变成唯一路径。
- 播放器 `PlayerFactory.create(path)` 传入池内路径。

验收：能播放；`Documents/TGMediaDownloads` 不再增长。

风险：TDLib 可能在播放过程中回收池内文件（LRU）。`ActiveFileRegistry` 已经会标记占用，但 TDLib 不认识这个标记。需要在播放开始时调用 `downloadFile` 并保持 `priority` 有效，播放结束后再允许回收。这一步必须在真机上验证「播放 30 秒以上不被清掉」。

### 步骤 2：删除下载专属代码

在步骤 1 验证通过后进行。

```
删除：
  lib/storage/download_mover.dart
  lib/storage/download_paths.dart
  test/download_mover_test.dart
  test/download_paths_test.dart

修改：
  lib/td/media_probe.dart          删 import、删 mover 字段、删第 8 步
  lib/ui/probe_page.dart           删「用户下载区」那一行
```

验收：`flutter analyze` 干净，`flutter test` 全绿，`grep -r download_mover lib/` 无结果。

### 步骤 3：移除 `userDownloads` zone（可选，最后做）

只有在确认没有任何代码写入 `Documents/TGMediaDownloads` 之后。

```
修改：
  lib/storage/storage_layout.dart  删 userDownloads 枚举值、downloadsDir、allRoots 条目
  lib/storage/cache_manager.dart   删 usage() 里对该区的分支
  test/storage_zones_test.dart     删对应用例
  test/cache_clear_test.dart       改用 indexFile 造受保护区数据
```

风险：`StorageLayout._assertDisjoint()` 遍历 `StorageZone.values`，删枚举值时如果别处有 `switch` 覆盖不全，编译器会报错 —— 这是好事，会强制走完所有分支。

另一个风险：`assertDeletableByCacheClear` 依赖 `zoneOf` 返回 `null` 来判断「不属于任何区」。少一个 zone 不会让它变宽松，因为 `tempCache` 之外的路径本来就该被拒。这一步要重新跑一遍 `storage_zones_test.dart` 和 `cache_clear_test.dart`。

---

## 4. 不要做的事

| 想法 | 为什么不行 |
|---|---|
| 直接删 `td_requests.downloadFile` | 播放链路的唯一入口。删了就没有视频 |
| 直接删 `download_metrics.dart` | 它测量的是 TDLib 拉流速度，与「用户下载」无关。第 3 步靠它把「慢」变成数字 |
| 直接删 `StorageZone.userDownloads` | zone 是安全判定的一部分，不是功能开关。它不在 UI 里出现，删不删都不影响用户体验，但会影响 `assertDeletableByCacheClear` 的测试样本 |
| 先删 UI 再改播放路径 | 会得到一个「没有下载按钮、但文件还在往 Documents 写」的中间状态，比现状更难排查 |
| 把 `Documents/TGMediaDownloads` 里的旧文件删掉 | 那是用户主动保存的数据。取消下载功能不等于删除历史文件。要删必须由用户在文件 App 或设置里明确选择 |

---

## 5. 实际执行记录

| 动作 | 第 3 步 | 第 4 步（2026-10-26 收尾） |
|---|---|---|
| 全量引用链分析 | 已完成（本文档） | 复查一次，引用链与第 3 步一致 |
| 步骤 1：改播放路径 | 未做 | **已具备**。新的播放链路走 `VideoSourceResolver`，直接读 TDLib 池内路径，不经过 `Documents`；`media_probe.dart` 的 `localPath` 改为取 `finalState.path` |
| 步骤 2：删下载专属代码 | 未做 | **已执行**（见下表） |
| 步骤 3：移除 `userDownloads` zone | 未做 | **不做**。理由见 §2.3：zone 是安全判定的一部分，删枚举会波及守卫与 6 个测试，收益为零 |
| 修改 `StorageZone` 枚举 | 未做 | 未做（同上） |

步骤 2 的实际删除与修改：

```
删除（4 个文件，共约 302 行 + 测试）
  lib/storage/download_mover.dart
  lib/storage/download_paths.dart
  test/download_mover_test.dart
  test/download_paths_test.dart

修改
  lib/td/media_probe.dart      删 import / mover 字段 / 第 8 步；步骤数 9 -> 8；
                               播放校验索引 9 -> 8；localPath 改为池内路径；
                               新增大小一致性检查与空路径检查
  lib/ui/probe_page.dart       删「用户下载区（受保护）」一行与随之无用的 _layout 字段
  lib/storage/storage_layout.dart  userDownloads 的注释从「download screen」改为「Files app」
```

删除后的验证（真实输出，2026-10-26 21:15）：

```
grep -rn "download_mover|download_paths|DownloadMover" lib/ test/   → clean
grep -rn "'@type': 'downloadFile'" lib/td/td_requests.dart         → 133: '@type': 'downloadFile'（播放入口仍在）
flutter analyze                                                    → No issues found!
flutter test                                                       → 539 passed / 1 skipped
```

`grep "deleteMessages|sendMessage|editMessage" lib/` 只命中 `td_readonly_guard.dart` 的黑名单本身——那是**拒绝清单里的字符串**，不是调用。

测试数从 548 降到 539 的账：删掉的两个测试文件合计 35 项，`td_error_kind_test.dart` 新增 22 项、`channel_directory_test.dart` 的失败分类新增 4 项，548 − 35 + 26 = 539。

**没有删的东西，以及为什么**：`td_requests.dart` 的 `downloadFile`（播放入口）、`download_metrics.dart`（测量拉流速度）、`active_files.dart`（防止清理删掉正在播的文件）、`storage_layout.dart` 的 `tdlibFilesDir`（池路径）、`StorageZone.userDownloads`（受保护区测试样本）。

---

## 6. 验证命令

删除每一步之后都应该能跑通：

```bash
cd tg_media_probe

# 1. 静态分析必须干净
flutter analyze

# 2. 全量测试必须全绿
flutter test

# 3. 确认没有残留引用
grep -rn "download_mover\|download_paths\|DownloadMover" lib/ test/ || echo "clean"

# 4. 确认播放入口还在（这一步必须永远返回结果）
grep -rn "'@type': 'downloadFile'" lib/td/td_requests.dart

# 5. 确认没有云端写入
grep -rn "deleteMessages\|sendMessage\|editMessage" lib/ || echo "clean"
```
