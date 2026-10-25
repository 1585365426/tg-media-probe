# TG Media 第 2 步：技术可行性验证状态

生成时间：2026-10-25（Windows 开发机）
仓库：https://github.com/1585365426/tg-media-probe （public，源码已推送，执行环境 macOS CI 免费额度）

## 1. 已验证（真实执行）

| 项目 | 命令 | 结果 |
|---|---|---|
| Flutter 工具链 | `flutter --version` | Flutter 3.47.8 stable / Dart 3.13.7 / engine dfd2e6cb7d |
| 依赖解析 | `flutter pub get` | 成功，41→45 个依赖 |
| 静态检查 | `flutter analyze` | `No issues found! (ran in 16.7s)` |
| 自动化测试 | `flutter test` | **37 passed, 1 skipped**（native 加载用 skip） |
| TDLib 请求与官方 schema 一致性 | `test/schema_conformance_test.dart` | 16 个请求全部字段名/必填项与 `td_api.tl` 一致（3365 行，上游 master） |
| 只读约束 | `test/readonly_guard_test.dart` | lib/ 下无任何云端写入/删除方法名 |
| 日志脱敏 | `test/redact_test.dart` | api_hash / 手机号 / 验证码 / 密码全部被脱敏 |
| shell 脚本语法 | `bash -n scripts/*.sh` | 4 个脚本全部 OK |
| CI YAML 结构 | `yaml.safe_load` | 解析成功，1 job / 15 steps |

Flutter 版本与 iOS 目标兼容性：Flutter 3.47 起最低 iOS 由 13 抬到 **15.0**（官方 3.47 发布说明），工程 `IPHONEOS_DEPLOYMENT_TARGET` 已由模板的 15.0 改为 **15.2**（3 处全部替换），Podfile `platform :ios, '15.2'`，podspec `ios.deployment_target = '15.2'`。目标 iOS 15.2–15.4.1 落在范围内，但**没有余量**：Flutter 3.48 之后若继续抬升最低版本，工程会失去兼容性，必须锁 `3.47.8`。

## 2. 未验证（缺环境，不计入通过）

| 项目 | 原因 |
|---|---|
| iOS 编译 & 原生库链接 | 本机 Windows，无 Xcode / CocoaPods / macOS |
| `TDLibFramework.xcframework` 静态/动态形态 | 354 MB 预编译包本机未下完（代理中断），podspec 采用 `vendored_frameworks` 的具体行为待 CI 首次构建确认 |
| Podfile / podspec Ruby 语法 | 本机无 ruby / pod |
| TDLib 运行时加载（`td_create_client_id`） | 无 Windows 版 TDLib 二进制，`TDJSON_PATH` 未设置，测试 skip |
| IPA 构建、TrollStore 安装 | 依赖 macOS runner |
| 真实登录 / 频道 / 元数据 / 播放 / 下载 | 依赖可安装的构建产物 + 真机 |

## 3. 关键实测发现

1. **TDLib 的 `video` 对象没有旋转字段**。schema 只有 `duration / width / height / file_name / mime_type / supports_streaming / minithumbnail / thumbnail / video:file`。因此第 3 步的方向分类不能只靠 TDLib 元数据：宽高来自 TDLib，旋转必须从本地文件的 AVFoundation track transform 读取，未知时归入「未知/待识别」。
2. **TDLib 预编译来源**：`Swiftgram/TDLibFramework` release `1.8.69-025086e3`，354.6 MB，`TDLibFramework.zip`，官方 Package.swift 里声明的 SHA256 = `65758175da552aabee45463698c6fb4553d614612df0cbd49c07d550eed46a41`。`scripts/fetch_tdlib.sh` 用这个值做校验，不通过就中断。
3. **本机网络**：默认代理 `127.0.0.1:51544` 已失效（000 / 502），但本机 `127.0.0.1:10808`（SOCKS5/HTTP）可用——经它访问 `api.telegram.org` 得 302、`core.telegram.org` 得 200。也就是说本机可达 Telegram，只是直连被拦。TDLib 支持 `addProxy`（socks5），这条路径在后续需要在本机做协议级验证时可用。
4. **GitHub 令牌缺少 `workflow` 权限**：`X-Oauth-Scopes: gist, read:org, repo`。因此 `.github/workflows/ios-probe.yml` 无法推送（`refusing to allow an OAuth App to create or update workflow`），CI 尚未触发。源码已推送成功（commit `0cb1b1e`，65 files）。

## 4. 需要执行的一步（二选一）

A. 本地执行 `gh auth refresh -h github.com -s workflow` 完成一次浏览器授权，之后我推送 workflow 并盯 CI 结果。

B. 网页新建文件：https://github.com/1585365426/tg-media-probe/new/main/.github/workflows/ios-probe.yml ，内容取自仓库工作副本的 `.github/workflows/ios-probe.yml`（15 steps，含 macOS 构建、符号校验、IPA 打包、诊断回写）。

CI 一旦跑起来，`ci-report` 分支会自动回写 `xcode.txt / flutter.txt / analyze.txt / test.txt / build-ios.txt / inspect.txt / package.txt`，无需 Actions 界面即可读结果。

## 5. 探针链路设计（代码已就位，未跑通）

顺序固定：`setTdlibParameters → 登录态 → getChats → getChat(过滤 is_channel) → getChatHistory(50) → messageVideo 元数据 → downloadFile → 本地文件 exists/length 校验 → AVPlayer initialize`。

每一步的状态只有 `pending / running / success / failed / skipped`，没有假进度：下载进度直接来自 TDLib `updateFile.local.downloaded_size`，完成判定只看 `is_downloading_completed` 且本地 `length` 必须等于 TDLib 报告的 `size`，不等即判失败。

只读约束：`lib/` 内不含 `deleteMessages / deleteChatHistory / deleteChat / leaveChat / sendMessage / forwardMessages / editMessageText` 等任何写入或删除方法名，`test/readonly_guard_test.dart` 会在 CI 里对整棵源码树再扫一遍，命中即构建失败。
