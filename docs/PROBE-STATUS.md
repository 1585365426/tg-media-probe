# TG Media 第 2 步：技术可行性验证状态

最后更新：2026-10-25 21:20（Windows 开发机）
仓库：https://github.com/1585365426/tg-media-probe （public，`main`，源码与脚本已推送）

## 1. 已验证（真实执行过，可复现）

| 项目 | 命令 | 结果 |
|---|---|---|
| Flutter 工具链 | `flutter --version` | Flutter 3.47.8 stable / Dart 3.13.7 / engine dfd2e6cb7d |
| 依赖解析 | `flutter pub get` | 成功，45 个依赖 |
| 静态检查 | `flutter analyze` | `No issues found!` |
| 自动化测试 | `flutter test` | **37 passed, 1 skipped**（native 加载用 skip） |
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

## 2. 未验证（缺环境或未跑，不计入通过）

| 项目 | 原因 |
|---|---|
| iOS 编译 / CocoaPods 装配 / 原生库链接 | 本机 Windows，无 Xcode / CocoaPods |
| Podfile & podspec 的 Ruby 语法 | 本机无 ruby / pod |
| GitHub Actions 实跑 | `.github/workflows/ios-probe.yml` 尚未推上去：令牌缺 `workflow` scope |
| 生成的 `.app` / IPA / SHA256 | 依赖 CI |
| TrollStore 安装、启动 | 依赖 IPA + 真机 |
| 真实登录 / 频道 / 元数据 / 播放 / 下载 | 依赖可安装产物 + 真机 + 用户自己的 api_id/hash |

## 3. 关键实测结论

1. **TDLib 的 `video` 对象没有旋转字段**：只有 `duration / width / height / file_name / mime_type / supports_streaming / minithumbnail / thumbnail / video:file`。方向分类只能「宽高取 TDLib + 旋转取本地文件 AVFoundation track transform」，读不到就归「未知/待识别」，不能猜。
2. **TDLib 是静态框架**：`vendored_frameworks` + CocoaPods 默认静态集成，不需要 `use_frameworks!`，也不需要往 `Runner.app/Frameworks` 里塞东西；`-Wl,-u,_td_create_client_id` 防止 `tdjson.o` 被 dead-strip。
3. **本机网络**：默认代理 `127.0.0.1:51544` 已死；`127.0.0.1:10808`（SOCKS5）可用，`api.telegram.org` 302、`core.telegram.org` 200。TDLib 若要在本机做协议级验证可走 `addProxy` socks5。
4. **GitHub 令牌作用域**：`gist, read:org, repo`，缺 `workflow`，所以 workflow 文件被 API 拒收。

## 4. 唯一待解阻塞：workflow scope

方式 A（推荐，一条命令）：本地执行

```bash
gh auth refresh -h github.com -s workflow
```

浏览器会给出一次性码，确认后作用域变为 `gist, read:org, repo, workflow`，随后 workflow 即可推送。

方式 B：网页新建
https://github.com/1585365426/tg-media-probe/new/main/.github/workflows/ios-probe.yml
内容 = 工作副本 `.github/workflows/ios-probe.yml`（19 steps）。

## 5. 探针链路设计（代码就位，未跑通）

`setTdlibParameters → 登录态 → getChats → getChat(过滤 is_channel) → getChatHistory(50) → messageVideo 元数据 → downloadFile → 本地文件 exists/length 校验 → AVPlayer initialize`

状态只有 `pending / running / success / failed / skipped`。下载进度直接取 TDLib `updateFile.local.downloaded_size`；完成判定必须 `is_downloading_completed` 且本地 `length == size`，不等即失败。

只读约束：`lib/` 内不含 `deleteMessages / deleteChatHistory / deleteChat / leaveChat / sendMessage / forwardMessages / editMessageText`，CI 中 `test/readonly_guard_test.dart` 会对整棵源码树再扫一遍。

## 6. CI 产出位置（跑完后读取，不需要 Actions 界面）

- `ci-report` 分支：`summary.txt / macos.txt / xcode.txt / iphoneos-sdk.txt / cocoapods.txt / flutter.txt / fetch-tdlib.txt / tdlib-layout.txt / pod-install.txt / deployment-targets.txt / analyze.txt / test.txt / build-ios.txt / inspect.txt / package.txt`
- Actions artifact：`tg-media-probe-ipa`（IPA + sha256 + 全部日志，14 天保留）
