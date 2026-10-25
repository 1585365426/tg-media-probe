# A / B / C / D 修复报告

修复提交：`3480894`（`main`）
CI：run [40217760668](https://github.com/1585365426/tg-media-probe/actions/runs/40217760668) — success，3m53s
产物：`TGMediaProbe-unsigned.ipa`，19,507,078 B，SHA256 `b227d4c891c2a5650b674e871f971dac04aa9e550c7a2d9d76dabc6c1b6402d0`

对比修复前的包（`1a83e39b…`，19,451,233 B），`App.framework/App` 从 5,153,488 B 变为 5,269,072 B，SHA256 `95a514a3…` → `05933573…`，且新包内含 `tg_tdlib_db_key_v1`、`tdlib_files` 两个只在本次修复里出现的字符串，旧包为 0 命中。

---

## A. 下载不再落进 TDLib 的池子

### 目录改动

| 用途 | 修复前 | 修复后 | 归属区 |
|---|---|---|---|
| TDLib 数据库 | `Documents/tdlib/db` | `Library/Application Support/tgmedia/secure/tdlib/db` | authMeta（受保护） |
| TDLib 文件池 | `Documents/tdlib/files` | `Library/Caches/tgmedia/tdlib_files` | tempCache（可重建） |
| 用户下载 | 无（混在池子里） | `Documents/TGMediaDownloads/<c chatId>/<name>_<fileId><ext>` | userDownloads（受保护） |

`StorageLayout` 新增两个派生目录（`lib/storage/storage_layout.dart`）：

```dart
String get tdlibDatabaseDir => p.join(authRoot, 'tdlib', 'db');
String get tdlibFilesDir => p.join(tempRoot, 'tdlib_files');
```

数据库放进 authRoot 之下，`zoneOf()` 对它返回 `authMeta`，`assertDeletableByCacheClear()` 直接拒删 —— 清缓存再也碰不到登录态。文件池放进 tempRoot，但**不是** `CacheManager.scan()` 走的三个子目录（`thumb` / `player` / `partial`），所以"清空缓存"目前不会连带删它，池子的回收交给后续设置页的专用清理器。

### 新增搬运层

`lib/storage/download_paths.dart` — 名字规则：
- `\` 和 `/` 都当分隔符，只取 basename
- `?` `#` 处截断（那是 URL，不是文件名）
- 删掉 `< > : " | * ?` 与控制字符
- 去掉所有前导点（`..`、隐藏文件都不成立）
- stem 上限 80 字符，扩展名保留；伪扩展名（`clip.MP4?x=1`）丢弃
- 最终名 `<stem>_<fileId><ext>`，fileId 保证同 chat 内不覆盖
- chat 目录 `c<abs(chatId)>`，负 id 不会变成命令行 flag

`lib/storage/download_mover.dart` — 搬运流程：
1. 源不存在 → `DownloadPromoteException[source]`
2. 源大小 ≠ TDLib 报的 size → 拒搬（不搬运坏文件）
3. 目标路径过 `assertInside(userDownloads)`，命名规则万一退化也写不出去
4. 目标已存在且大小一致 → `reused: true`，幂等
5. 目标存在但大小不对 → 删掉重搬（那是自己的残留）
6. `copy → <target>.part` → 校验 `.part` 大小 → `rename` 到最终名 → 再校验一次
7. 任何一步抛错都清掉 `.part`，不留半截文件

`FileOps` 增加 `copyFile`（不 `rename`，因为 TDLib 池要保留自己的副本，否则 TDLib 的 file 记录失配、下次重新下载）。

### 链路里的落地

`lib/td/media_probe.dart` 第 7 步只负责 TDLib 池下载完成，第 8 步改为搬运 + 校验：

```
7. 下载真实媒体文件       5809108/5809108 B → TDLib 池 .../Caches/tgmedia/tdlib_files/videos/xxx.MP4
8. 复制到用户下载区（校验大小）  5809108 B → .../Documents/TGMediaDownloads/c123/video_4357.mp4
```

播放器打开的是第 8 步的路径（用户区），不再是池子里的临时副本。`ProbeResult` 同时返回 `localPath`（用户区）和 `poolPath`（池子，仅诊断）。

## B. TDLib 数据库加密

`lib/security/tdlib_key.dart`：
- 32 字节 `Random.secure()` → 64 位小写 hex
- 存 Keychain，`KeychainAccessibility.first_unlock_this_device`（不进 iCloud Keychain，重启后首次解锁前不可读）
- 存储名 `tg_tdlib_db_key_v1`（带版本，将来换长度不会误读旧值）
- 已存在的 key 格式不对 → 抛 `TdlibKeyException`，**不覆盖**（旧值可能仍能打开现有库）
- 提供 `SecretStore` 抽象，`MemorySecretStore` 供测试，Keychain 不参与单测

`lib/td/td_requests.dart`：`databaseEncryptionKey` 改为必填，空串直接 `ArgumentError` —— 这是防止明文落盘的最后一道闸，任何调用方忘记传值都会在构造请求时炸掉，而不是静默写明文库。

`lib/ui/probe_page.dart`：初始化时 `obtain()` 拿 key，界面上只显示 `mask()` 后的前 6 + 后 4 位。

### 升级副作用（真机复测时必须知道）

第 3 步那次验证用的是空 key 建的库，位置在 `Documents/tdlib/db`。TDLib 不支持给已有库改 key，所以新版本用的是**另一个路径 + 另一个 key**，等于一个全新的空库 —— **必须重新收一次验证码登录**。

旧库 `Documents/tdlib/db` 原样保留，没有删除。初始化时会检测它是否存在，存在就在界面上打一行红字提示。删不删由用户自己决定，程序不代劳。

## C. 步骤状态不再卡在 running

根因：`ProbeRunner.markAuthorized()` 写好了但从来没人调用。`updateAuthorizationState` 收到 `authorizationStateReady` 时只更新了页面自己的 `_stage`，没有通知 runner 第 3 步（账号登录）结束，于是它永远停在 `…` 和"等待 Telegram 下发验证码"。

修复 `lib/ui/probe_page.dart`：

```dart
if (state.stage == AuthStage.ready) {
  runner.markAuthorized();
}
```

下载那一步（第 7 项）代码里本来就在成功分支调了 `_set(7, success)`，截图里没勾是抓帧时机（detail 已显示 `…B → 路径`，说明 success 分支执行过）。为稳妥，第 7 步的 success 现在显式带上"→ TDLib 池"字样，与第 8 步的"→ 用户下载区"区分开，避免两行 detail 长得像。

## D. 文案

`tdjson 已加载（动态库符号解析成功）` → `tdjson 已加载（静态链接，符号从主二进制解析）`。

TDLib 是 `.a` 静态归档，靠四个 `-Wl,-u,_td_*` 强制保留符号，运行时 `DynamicLibrary.process()` 从主镜像查。没有独立动态库。

---

## 测试

```
flutter analyze   No issues found!
flutter test      164 passed, 1 skipped
```

对比修复前：118 项 → 164 项，新增 46 项。skip 的那 1 项是 `tdjson_load_test`（本机无 TDLib 二进制，运行时加载需真机验证）。

新增测试文件：

| 文件 | 覆盖 |
|---|---|
| `test/tdlib_key_test.dart` | 64 hex 格式、重启复用同一 key、两个新装不同 key、坏 key 不覆盖、peek 不创建、mask 只留两端 |
| `test/download_paths_test.dart` | POSIX/Windows 路径穿越、隐藏文件、非法字符、URL 截断、空白折叠、超长截断、mime 推扩展名、同名不同 fileId 不冲突、负 chatId、hostile 名字不越界 |
| `test/download_mover_test.dart` | 正常搬运、池子副本保留、幂等、半截文件被替换、大小不符拒搬、源缺失、恶意名字不越界、无 `.part` 残留、同 chat 同名共存、池子在 temp 区、库在 auth 区、清缓存碰不到库 |

关键回归断言（`test/download_mover_test.dart`）：

```dart
test('cache clearing can never touch the database', () async {
  await expectLater(
    box.layout.assertDeletableByCacheClear(
        p.join(box.layout.tdlibDatabaseDir, 'db.sqlite')),
    throwsA(isA<ZoneViolation>()),
  );
});
```

## 改动文件

新增 6 个：
```
lib/storage/download_paths.dart
lib/storage/download_mover.dart
lib/security/tdlib_key.dart
test/download_paths_test.dart
test/download_mover_test.dart
test/tdlib_key_test.dart
```

修改 8 个：
```
lib/storage/file_ops.dart          + copyFile
lib/storage/storage_layout.dart    + tdlibDatabaseDir / tdlibFilesDir / ensureCreated
lib/td/td_requests.dart            databaseEncryptionKey 必填且非空
lib/td/media_probe.dart            目录改道 + 搬运 + ProbeInitInfo + 步骤标题
lib/ui/probe_page.dart             layout/key 装配 + markAuthorized + 路径显示 + 文案
test/schema_conformance_test.dart  补 key 参数
test/td_requests_test.dart         补 key 参数 + 空 key 拒绝
test/readonly_guard_test.dart      补 key 参数
```

---

## 真机复测清单

装 `TGMediaProbe-a1b-fixed.ipa`（SHA256 `b227d4c8…`）。按顺序看屏幕文字，每项都要与"预期"一致才算过。

| # | 操作 | 预期屏幕文字 |
|---|---|---|
| 1 | TrollStore 安装启动 | 界面完整，无崩溃 |
| 2 | 填 api_id / api_hash → 点"初始化 TDLib" | 第 1 项 ✓ `tdjson 已加载（静态链接，符号从主二进制解析）` |
| 3 | 同上 | 第 2 项 ✓ `db=/var/mobile/.../Library/Application Support/tgmedia/secure/tdlib/db（加密 key xxxxxx…xxxx）` |
| 4 | 同上 | 若之前登过：出现红字"检测到旧版明文库 Documents/tdlib/db，已保留未删除…" |
| 5 | 同上 | 页面底部"4. 存储落点"三段路径，`TDLib 文件池` 显示 `Library/Caches/tgmedia/tdlib_files`，`用户下载区` 显示 `Documents/TGMediaDownloads` |
| 6 | 输手机号 → 收码 → 提交验证码 | 第 3 项从 `…` 变 ✓ `authorizationStateReady`（**这是 C 的复测点**） |
| 7 | 点"频道 → 消息 → 元数据 → 下载 → 播放" | 第 4 项 ✓ 会话 N 个 / 频道 M 个 |
| 8 | 同上 | 第 5 项 ✓ `<频道名>: N 条消息` |
| 9 | 同上 | 第 6 项 ✓ `<w>x<h> <s>s <size>B fileId=<id>` |
| 10 | 同上 | 第 7 项 ✓ `<size>/<size> B → TDLib 池 /var/mobile/.../Library/Caches/tgmedia/tdlib_files/...` |
| 11 | 同上 | 第 8 项 ✓ `<size> B → /var/mobile/.../Documents/TGMediaDownloads/c<id>/<name>_<fileId>.mp4`（**这是 A 的复测点**） |
| 12 | 同上 | 第 9 项 ✓ `AVPlayer 已初始化，时长=<n>s`，视频出画面 |
| 13 | 冷启 App 再走一次 | 不需重新收验证码，直接 ready（key 复用生效） |
| 14 | 用 Filza / 文件 App 看目录 | `Documents/tdlib` 不再有新文件；`Documents/TGMediaDownloads/c<id>/` 下有 mp4；`Library/Application Support/tgmedia/secure/tdlib/db` 有库文件 |

第 6、11、13、14 项是这次修复的验证重点。第 1–5、7–10、12 是回归，确认没改坏。

### 还要额外确认的

- 断网重跑链路：第 7 项应显示失败原因，第 8 项不应出现半截文件
- 重复点链路按钮两次：第 8 项第二次应显示"（复用已有文件）"，文件不重复增长

## 仍未验证

- 上述 14 项全部依赖真机，本次只做到"CI 构建成功 + 二进制内容核对"
- 加密库的 key 在 TDLib 里是否被正确接受（空 key 报错是已知的，非空 key 首次建库要到真机才知道）
- `first_unlock_this_device` 在 TrollStore 环境下 Keychain 是否可读（TrollStore 走的是正规签名以外的路径，Keychain 访问通常正常，但没有实测记录）
