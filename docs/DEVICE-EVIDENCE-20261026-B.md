# 真机复测证据（第 2 轮）：A/B/C/D 修复验证

- 时间：2026-10-26 01:55（手机状态栏）
- 设备：iPhone 11 Pro（1125 × 2436 截图分辨率）
- 系统：iOS 15.x（TrollStore 侧载）
- 安装包：`TGMediaProbe-a1b-fixed.ipa`
  - 19,507,078 B
  - SHA256 `b227d4c891c2a5650b674e871f971dac04aa9e550c7a2d9d76dabc6c1b6402d0`
  - 对应 CI run [40217760668](https://github.com/1585365426/tg-media-probe/actions/runs/40217760668) success
- 上一轮基线包：`1a83e39be0c18d0d0ab403051f0f7fa1557f93affcd39f15daa62b7d8ad404ba`（19,451,233 B）

## 1. 原始证据文件

| 文件 | 尺寸 | 字节 | SHA256 |
|---|---|---|---|
| `01-list-authorization-to-player.jpg` | 1125 × 2436 | 221,074 | `71bc0c305ab26b10df0c366802456768a2704962e6d3718f7c13cbfda3af4de9` |
| `02-storage-zones.jpg` | 1022 × 800 | 101,333 | `88b16793a83e14dc15a7ae68270560740d214a63a4b631b7c45920adce117baa` |

放大裁切件（Pillow LANCZOS ×2，用于判读状态图标，不作为独立证据）：
`crop-top.png`（标题区）、`crop-step2-3.png`（key + ready）、`crop-step7-8.png`（下发 + 复制）、`crop-step9.png`（用户下载区）。

## 2. 逐字转录

`01-list-authorization-to-player.jpg`（页面已上滚，第 1 项完全滚出视口）：

```
TG Media 可行性探针
                                期输入）
✓   db=/var/mobile/Containers/Data/Application/
    25212DE5-
    C911-439B-8D12-0C471C1AE4BA/Library/
    Application Support/tgmedia/secure/tdlib/db
    （加密 key 16ae84...b46e）

✓   账号登录（验证码 / 两步验证）
    authorizationStateReady

✓   读取已授权频道
    会话 3 个，其中频道 1 个

✓   读取频道消息
    18号仓储: 50 条消息

✓   读取视频元数据
    464x848 28s 5809108B fileId=4039

    下载真实媒体文件
    5809108/5809108 B → TDLib 池 /private/
    var/mobile/Containers/Data/Application/
    25212DE5-
    C911-439B-8D12-0C471C1AE4BA/Library/
    Caches/tgmedia/tdlib_files/videos/
    bb4a413292c6.MP4

✓   复制到用户下载区（校验大小）
    5809108 B → /var/mobile/Containers/Data/
    Application/25212DE5-
    C911-439B-8D12-0C471C1AE4BA/
    Documents/TGMediaDownloads/
    c1002273572608/
    bb4a413292c6_4039.mp4

✓   播放校验（AVPlayer 初始化）
    AVPlayer 已初始化，时长=27s
```

注：第 7 项「下载真实媒体文件」的 ✓ 在裁切图 `crop-step7-8.png` 中可见——它垂直居中于整块（标题 + 6 行描述）的中间位置，与标题行错开了约 3 行，肉眼扫列表时容易读成"未打勾"。这是布局缺陷，见 §5-①。

`02-storage-zones.jpg`：

```
4. 存储落点（四区隔离）

TDLib 数据库（加密 / 受保护）
/var/mobile/Containers/Data/Application/25212DE5-
C911-439B-8D12-0C471C1AE4BA/Library/Application Support/
tgmedia/secure/tdlib/db

TDLib 文件池（可重建）
/var/mobile/Containers/Data/Application/25212DE5-
C911-439B-8D12-0C471C1AE4BA/Library/Caches/tgmedia/
tdlib_files

用户下载区（受保护）
/var/mobile/Containers/Data/Application/25212DE5-
C911-439B-8D12-0C471C1AE4BA/Documents/
TGMediaDownloads
```

容器 UUID `25212DE5-C911-439B-8D12-0C471C1AE4BA`，与上一轮的 `26962250-0153-416D-9964-C1AB62709E43` 不同——重装后容器重建，符合预期。

## 3. 九步链路逐项判定

| # | 步骤 | 回显 | 判定 | 对应修复 |
|---|---|---|---|---|
| 1 | 加载 TDLib 原生库 | 已滚出视口，无回显 | **无证据** | D 未验证 |
| 2 | 配置 TDLib 参数 | `db=.../Library/Application Support/tgmedia/secure/tdlib/db（加密 key 16ae84...b46e）` | **通过** | B |
| 3 | 账号登录 | `authorizationStateReady` + ✓ | **通过** | C |
| 4 | 读取已授权频道 | `会话 3 个，其中频道 1 个` | **通过** | — |
| 5 | 读取频道消息 | `18号仓储: 50 条消息` | **通过** | — |
| 6 | 读取视频元数据 | `464x848 28s 5809108B fileId=4039` | **通过** | — |
| 7 | 下载真实媒体文件 | `5809108/5809108 B → .../Library/Caches/tgmedia/tdlib_files/videos/bb4a413292c6.MP4` | **通过** | A 前半 |
| 8 | 复制到用户下载区 | `5809108 B → .../Documents/TGMediaDownloads/c1002273572608/bb4a413292c6_4039.mp4` | **通过** | A 后半 |
| 9 | 播放校验 | `AVPlayer 已初始化，时长=27s` | **通过** | — |

第 2 节三路径与第 2、7、8 步回显完全一致，**四区隔离在真机上首次成立**。

旁证：
- `fileId=4039`（上轮 `4357`）→ 库是新建的，印证"换 key 换路径 = 新空库"的判断，本轮确实重新走了登录。
- 加密 key 前缀 `16ae84`，与 `lib/security/tdlib_key.dart` 输出的 64 hex 截断显示格式一致；空串会早在 `setTdlibParameters` 抛 `ArgumentError`，走不到这一步，说明 B 生效。
- 文件名 `<unique_id>_<fileId>.mp4`：该条视频 Telegram 侧无 `file_name`，TDLib 用 remote unique id（`bb4a413292c6`）当池内名，`DownloadPaths` 补上 `_4039` 防冲突，最后落 `.mp4`。符合设计。

## 4. 14 项复测清单判定

| # | 内容 | 判定 |
|---|---|---|
| 1 | 安装并启动，界面完整 | 通过 |
| 2 | 第 1 项 ✓「静态链接，符号从主二进制解析」 | **未提供** |
| 3 | 第 2 项 ✓ db 在 secure 区 + 加密 key | 通过 |
| 4 | 红字「检测到旧版明文库…已保留未删除」 | **未提供** |
| 5 | 底部存储落点三段路径正确 | 通过 |
| 6 | `authorizationStateReady` 后第 3 项从 `…` 变 ✓ | 通过（C 验证点） |
| 7 | 第 4 项 会话 N / 频道 M | 通过 |
| 8 | 第 5 项 `<频道名>: N 条消息` | 通过 |
| 9 | 第 6 项 元数据 | 通过 |
| 10 | 第 7 项 池路径在 Caches/tgmedia/tdlib_files | 通过 |
| 11 | 第 8 项 用户下载区路径（A 验证点） | 通过 |
| 12 | 第 9 项 AVPlayer 初始化，画面出来 | 初始化通过；**画面/音轨/seek 未提供** |
| 13 | 冷启重进，不重收码直接 ready（key 复用） | **未提供** |
| 14 | Filza 看目录：`Documents/tdlib` 无新文件、`TGMediaDownloads/c<id>/` 有 mp4、`secure/tdlib/db` 有库 | **未提供** |

附加项（断网失败残留、重复点击复用）均**未提供**。

统计：**9 项通过，5 项无证据**。

## 5. 本轮新发现问题

### ① 步骤状态图标与标题行错位（P1，观感 + 误判）

`lib/ui/probe_page.dart:347` 的 `ListTile` 未指定 `titleAlignment`，Material 3 默认让 `leading` 在整块（title + subtitle 多行）里垂直居中。当 detail 有 6 行时（第 8 步路径），✓ 落到中间，视觉上脱离标题。

后果不只是难看：截图里第 7 项看起来像"没打勾"，用户自己都会误读成失败。

修法：`ListTile(titleAlignment: ListTileTitleAlignment.top)`，或改用 `Row(crossAxisAlignment: CrossAxisAlignment.start)` 自绘，图标加固定行高。第 4 步 UI 一并处理。

### ② detail 长路径把每一项撑成 5–6 行（P2）

`/var/mobile/Containers/Data/Application/25212DE5-C911-439B-8D12-0C471C1AE4BA/...` 这类绝对路径在 375pt 宽下必然折成 4 行，UUID 还被硬折断成 `25212DE5-` / `C911-439B-...`。

探针阶段可接受；正式 UI 应显示规划路径 + 「…」省略，或显示相对容器根的路径（`Library/Caches/tgmedia/tdlib_files/videos/bb4a413292c6.MP4`），UUID 只在日志里出现。

## 6. 结论

A（下载搬出 TDLib 池、四区隔离）、B（加密 key）、C（登录态置 success）三项**在真机上确认生效**，回显与代码路径对得上，不是推断。

D（第 1 项文案）与旧库提示条无截图证据；冷启 key 复用、Filza 目录核对、画面渲染、断网残留未提供。这 5 项未通过前，第 4 步 UI 不开工。
