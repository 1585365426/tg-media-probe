# TG Media 第 2 步：技术可行性验证状态

最后更新：2026-10-26 10:25（Windows 开发机）
仓库：https://github.com/1585365426/tg-media-probe （public，`main`，源码与脚本已推送）

## 1. 已验证（真实执行过，可复现）

| 项目 | 命令 | 结果 |
|---|---|---|
| Flutter 工具链 | `flutter --version` | Flutter 3.47.8 stable / Dart 3.13.7 / engine dfd2e6cb7d |
| 依赖解析 | `flutter pub get` | 成功，45 个依赖 |
| 静态检查 | `flutter analyze` | `No issues found!` |
| 自动化测试 | `flutter test` | 当前 **288 passed, 1 skipped**（native 加载用 skip）；第 2 步当时为 37 |
| TDLib 请求与官方 schema 一致性 | `test/schema_conformance_test.dart` | 16 个请求字段名/必填项全部对得上 `td_api.tl`（3365 行，上游 master） |
| 只读约束 | `test/readonly_guard_test.dart` | `lib/` 下无任何云端写入/删除方法名 |
| 日志脱敏 | `test/redact_test.dart` | api_hash / 手机号 / 验证码 / 密码全部脱敏 |
| TDLib 二进制下载 | `curl -C -` 分 3 段续传 | **371,840,147 字节 = 354.6 MB，完整** |
| TDLib SHA256 | `sha256sum TDLibFramework.zip` | `65758175da552aabee45463698c6fb4553d614612df0cbd49c07d550eed46a41`，与上游 Package.swift 声明一致 |
| xcframework 结构 | 解析 zip 目录 | `TDLibFramework.xcframework/{ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64, tvos-*, watchos-*, xros-*}`，共 133 项 |
| ios-arm64 切片形态 | 读取二进制前 8 字节 | `!<arch>\n` → **静态归档（.a）**，不是 dylib；因此无需 embed、无需签名动态库 |
| 切片最低系统 | PlistBuddy 等价解析 Info.plist | `MinimumOSVersion = 12.0`，`CFBundleIdentifier = app.swiftgram.tdlibframework.iOS`，版本 1.8.69 |
| 公开头文件符号 | `Headers/td_json_client.h` | `td_create_client_id / td_send / td_receive / td_execute` 四个入口齐全，含 `Modules/module.modulemap`（umbrella `td.h`） |
| shell 脚本语法 | `bash -n scripts/*.sh` | 4 个脚本全部 OK |
| CI YAML 结构 | `yaml.safe_load` | 解析成功，1 job / **19 steps** |
| 换行符完整性 | `git ls-files --eol` | 索引内 `.sh / Podfile / podspec / .yml` 全为 `i/lf`（Windows 的 `core.autocrlf=true` 曾把 CRLF 写进 blob，已用 `.gitattributes` + `--renormalize` 修正，commit `f339b1c`） |

### iOS 最低版本核对（三方交叉）

| 来源 | 值 | 结论 |
|---|---|---|
| Flutter 3.47 的 pbxproj 迁移逻辑（`ios_deployment_target_migration.dart:118`） | 低于 15.0 一律改写为 `15.0` | Flutter 地板 = 15.0 |
| `video_player_avfoundation 2.12.3` podspec | `s.ios.deployment_target = '15.0'` | 插件地板 = 15.0 |
| `flutter_secure_storage 9.2.4` podspec | `9.0` | 无约束 |
| TDLibFramework ios-arm64 | `MinimumOSVersion 12.0` | 无约束 |
| 本工程 | pbxproj 3 处 `IPHONEOS_DEPLOYMENT_TARGET = 15.2`（0 处 15.0）+ `Podfile platform :ios, '15.2'` + podspec `15.2` | 覆盖目标 15.2–15.4.1 |

结论：**源码层面 15.2 满足全部依赖下限，仅剩 0.2 个次版本余量，Flutter 必须锁 3.47.8。**

## 2. 真机已验证（2026-10-26，iPhone 11 Pro / iOS 15.x / TrollStore）

两轮：第一轮 `1a83e39b…d404ba`（证据 `docs/DEVICE-EVIDENCE-20261026.md`），第二轮 `b227d4c8…6402d0`（证据 `docs/DEVICE-EVIDENCE-20261026-B.md`）。下表为第一轮基线。

| 项目 | 真机回显 |
|---|---|
| TrollStore 安装 + 启动 | UI 完整渲染 |
| TDLib 符号解析 | `tdjson 已加载` |
| `setTdlibParameters` | `database=.../26962250-0153-416D-9964-C1AB62709E43/Documents/tdlib/db` |
| 验证码登录 → ready | 后续读取成功（UI 状态文案未刷新，见证据文档 §4-C） |
| `getChats` + 频道过滤 | `会话 3 个，其中频道 1 个` |
| `getChatHistory` | `18号仓储: 50 条消息` |
| 视频元数据 | `464x848 28s 5809108B fileId=4357` |
| `downloadFile` | `5809108/5809108 B` → `Documents/tdlib/files/videos/bb4a413292c6.MP4` |
| 本地文件校验 | `5809108 B 与 TDLib 报告一致` |
| AVPlayer 初始化 | `AVPlayer 已初始化，时长=27s` |

### 2.1 第二轮真机（2026-10-26 01:55，修复包 `b227d4c8…6402d0`）

证据 `docs/DEVICE-EVIDENCE-20261026-B.md`（含原始 jpg 与 SHA256）。9 步链路回显：

| # | 步骤 | 真机回显 | 判定 |
|---|---|---|---|
| 1 | 加载 TDLib 原生库 | 滚出视口，无回显 | 无证据 |
| 2 | 配置 TDLib 参数 | `db=.../Library/Application Support/tgmedia/secure/tdlib/db（加密 key 16ae84...b46e）` | 通过（B） |
| 3 | 账号登录 | `authorizationStateReady` | 通过（C） |
| 4 | 读取频道 | `会话 3 个，其中频道 1 个` | 通过 |
| 5 | 读取消息 | `18号仓储: 50 条消息` | 通过 |
| 6 | 视频元数据 | `464x848 28s 5809108B fileId=4039` | 通过 |
| 7 | 下载 | `...→ Library/Caches/tgmedia/tdlib_files/videos/bb4a413292c6.MP4` | 通过（A 前半） |
| 8 | 复制到用户区 | `...→ Documents/TGMediaDownloads/c1002273572608/bb4a413292c6_4039.mp4` | 通过（A 后半） |
| 9 | 播放校验 | `AVPlayer 已初始化，时长=27s` | 通过 |

`fileId` 由 `4357` 变为 `4039`，容器 UUID 变为 `25212DE5-…`，印证"换路径换 key ⇒ 新建库 ⇒ 重收一次验证码"，与升级副作用预判一致。**四区隔离首次在真机成立。**

未取得证据的复测项：第 1 项文案（D）、旧库红字提示条、冷启 key 复用、Filza 目录核对、画面/音轨/seek、断网残留、重复点击复用。

### 2.2 本轮新发现

| # | 问题 | 位置 |
|---|---|---|
| E | 步骤状态图标在多行 detail 里垂直居中，脱离标题行；第 8 步 6 行路径时 ✓ 落到中间，肉眼读成"未打勾" | `lib/ui/probe_page.dart:347` `ListTile` 缺 `titleAlignment` |
| F | detail 显示容器绝对路径，375pt 宽下折 4–5 行，UUID 被硬断成 `25212DE5-` / `C911-…` | 同上，`step.detail` 构造处 |

E、F 均为观感与可读性问题，归入第 4 步 UI 一并处理。

## 3. 未验证（不计入通过）

| 项目 | 原因 |
|---|---|
| 实际画面渲染 / 音轨 / seek | 只证明 AVPlayer 构造成功并读到时长 |
| 横竖屏切换 | 现有截图均为竖屏，无旋转证据 |
| 分页翻页（offset / keyset） | 单次 50 条取完，未触发 |
| 下载中断续传 | 5.5 MB 一次下完，未制造断网 |
| 冷启后登录态保持 | 未做退出重进 |
| 缓存清理安全行为 | 四区隔离已于第二轮真机生效，但清理动作本身尚未在真机执行 |
| 多频道 / 大文件 / 长视频 | 样本仅 1 频道 1 条 28 秒视频 |

### 真机证据暴露的待修项（第二轮真机已确认 A/B/C 生效）

| # | 问题 | 状态 | 位置（修复后） |
|---|---|---|---|
| A | 下载落进 TDLib file store，四区隔离未生效；整目录清理会连带删授权 | **已修 + 真机确认** | `lib/storage/download_mover.dart`、`lib/storage/download_paths.dart`、`lib/storage/storage_layout.dart` |
| B | `database_encryption_key` 为空串，TDLib 本地库明文 | **已修 + 真机确认** | `lib/security/tdlib_key.dart`、`lib/td/td_requests.dart` |
| C | 登录成功状态未置 success（`markAuthorized` 从未被调用） | **已修 + 真机确认** | `lib/ui/probe_page.dart` |
| D | 「动态库符号解析」措辞不准 | 已修，**截图未覆盖该项** | `lib/ui/probe_page.dart` |

修复细节、测试与真机复测清单见 `docs/FIX-A1B-REPORT.md`。

| 当前构建 | 值 |
|---|---|
| CI run | [40217760668](https://github.com/1585365426/tg-media-probe/actions/runs/40217760668) success，3m53s |
| IPA | `TGMediaProbe-unsigned.ipa` 19,507,078 B |
| SHA256 | `b227d4c891c2a5650b674e871f971dac04aa9e550c7a2d9d76dabc6c1b6402d0` |
| 测试 | 164 passed / 1 skipped |
| analyze | No issues found! |
| 二进制核对 | `tg_tdlib_db_key_v1` / `tdlib_files` / `TGMediaDownloads` 在新包 `App.framework/App` 内命中，旧包 0 命中 |

**升级副作用**：加密库换了路径与 key，TDLib 不支持给已有库改 key，因此本次装入后**需要重新收一次验证码**。旧明文库 `Documents/tdlib/db` 保留未删，界面会提示。

> iOS 编译、CocoaPods 装配、TDLib 静态链接、IPA 打包已在 GitHub Actions 真实跑通，历史见 `docs/CI-RUN-REPORT.md`：run [40198573231](https://github.com/1585365426/tg-media-probe/actions/runs/40198573231) success。

## 4. 关键实测结论

1. **TDLib 的 `video` 对象没有旋转字段**：只有 `duration / width / height / file_name / mime_type / supports_streaming / minithumbnail / thumbnail / video:file`。方向分类只能「宽高取 TDLib + 旋转取本地文件 AVFoundation track transform」，读不到就归「未知/待识别」，不能猜。
2. **TDLib 是静态框架**：`vendored_frameworks` + CocoaPods 默认静态集成，不需要 `use_frameworks!`，也不需要往 `Runner.app/Frameworks` 里塞东西；`-Wl,-u,_td_create_client_id` 防止 `tdjson.o` 被 dead-strip。
3. **本机网络**：默认代理 `127.0.0.1:51544` 已死；`127.0.0.1:10808`（SOCKS5）可用，`api.telegram.org` 302、`core.telegram.org` 200。TDLib 若要在本机做协议级验证可走 `addProxy` socks5。
4. **GitHub 令牌作用域**：`gist, read:org, repo`，缺 `workflow`，所以 workflow 文件被 API 拒收。

## 5. 构建通道（已通）

GitHub Actions `macos-26`（Xcode 26.6 / Swift 6.3.3 / iOS SDK 26.5 / CocoaPods 1.17.0）实际构建成功：
run [40198573231](https://github.com/1585365426/tg-media-probe/actions/runs/40198573231)。
前两次失败的根因（Xcode 16.4 缺 `isolation:` 重载、`td_send/receive/execute` 被 dead-strip）与修复记录在 `docs/CI-RUN-REPORT.md`。

## 6. 探针链路设计（真机已跑通）

`setTdlibParameters → 登录态 → getChats → getChat(过滤 is_channel) → getChatHistory(50) → messageVideo 元数据 → downloadFile → 本地文件 exists/length 校验 → AVPlayer initialize`

状态只有 `pending / running / success / failed / skipped`。下载进度直接取 TDLib `updateFile.local.downloaded_size`；完成判定必须 `is_downloading_completed` 且本地 `length == size`，不等即失败。

只读约束：`lib/` 内不含 `deleteMessages / deleteChatHistory / deleteChat / leaveChat / sendMessage / forwardMessages / editMessageText`，CI 中 `test/readonly_guard_test.dart` 会对整棵源码树再扫一遍。

## 6.1 第 4 步（界面与功能）

代码已提交 `c5a3372`（界面与功能）+ `7fbee2f`（E/F 探针页修复），本机 `flutter analyze` 无问题、
`flutter test` **255 passed / 1 skipped**。详细实现、安全校验与自测对照见 `docs/STEP4-REPORT.md`。

已推送并构建两轮：

| run | 提交 | IPA SHA256 | 说明 |
|---|---|---|---|
| [40223283270](https://github.com/1585365426/tg-media-probe/actions/runs/40223283270) | `7fbee2f` | `08842ca7…401fd7` | 第 4 步 + E/F |
| [40252236401](https://github.com/1585365426/tg-media-probe/actions/runs/40252236401) | `0a728e6` | `0daed69c…0f4c62` | H/I/J 修复，274 passed |
| [40257900132](https://github.com/1585365426/tg-media-probe/actions/runs/40257900132) | `9d11c26` | `238367ac…fcd0f4` | 抖音 Tab / 全屏 / 缓存统计 / 时长 6 档，288 passed |

真机首轮复测（截图）暴露三个问题并已修：H 探针页抢 TDLib 数据库锁（error 400）、
I 视频页首屏只取一页且切 Tab 不刷新导致空态、J 时长 chip 被裁。详见
`docs/BUILD-40252236401.md`。

### 6.2 第六轮（用户 8 条需求）

真机第三轮截图提出的 8 条，其中第 3、4 条用户取消，第 8 条按 F1（全屏沉浸）实现。
代码提交 `27da705`，CI 修复 `9d11c26`，详情 `docs/BUILD-40257900132.md`。

| # | 需求 | 状态 |
|---|---|---|
| 1 | 收藏页被强制横屏 | 已修：收藏页锁竖屏 + 视频页切 Tab 时释放横屏 |
| 2 | 视频不能全屏 | 已修：`FittedBox` + `BoxFit.cover` |
| 3 | 收藏长按删除 | 用户取消 |
| 4 | 去除下载功能 | 用户取消（仅文案改为「加载中」） |
| 5 | 临时缓存始终 0 B | 已修：扫描漏了 `tdlib_files`，新增 `CacheKind.tdlibBlobPool` |
| 6 | 视频加载慢 | 已修：后两条预取，TDLib 优先级 1 |
| 7 | 时长 6 档可换行 | 已修：7 项枚举 + `Wrap` |
| 8 | 新增抖音 Tab | 已修：第 4 个 Tab，immersive + randomOrder |

**这六项都还没有真机证据。** 另外 CI 曾因 `xcodebuild -version | head -1` 触发
SIGPIPE（exit 134）失败一次，已在 workflow 里改掉。

**真机交互全部未验证**——装包、启动、登录、频道、播放、下载、横竖屏、Face ID、收藏、缓存清理都还没跑过。

## 7. CI 产出位置（跑完后读取，不需要 Actions 界面）

- `ci-report` 分支：`summary.txt / macos.txt / xcode.txt / iphoneos-sdk.txt / cocoapods.txt / flutter.txt / fetch-tdlib.txt / tdlib-layout.txt / pod-install.txt / deployment-targets.txt / analyze.txt / test.txt / build-ios.txt / inspect.txt / package.txt`
- Actions artifact：`tg-media-probe-ipa`（IPA + sha256 + 全部日志，14 天保留）
