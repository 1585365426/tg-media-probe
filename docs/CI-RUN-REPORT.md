# CI 构建报告（第 2 步 / P3 构建通道验证）

真实运行，非推断。三次运行全部留档，前两次失败原因与修复均已落地。

## 运行链接

| # | Run | 结果 | 耗时 | 失败点 |
|---|---|---|---|---|
| 1 | https://github.com/1585365426/tg-media-probe/actions/runs/40197274279 | failure | 4m08s | `flutter build ios`：video_player_avfoundation 用了 Xcode 26 SDK 才有的 `isolation:` 参数 |
| 2 | https://github.com/1585365426/tg-media-probe/actions/runs/40197805319 | failure | 5m49s | 构建已通过；符号校验发现 `td_send / td_receive / td_execute` 被 dead-strip |
| 3 | https://github.com/1585365426/tg-media-probe/actions/runs/40198573231 | **success** | 6m19s | — |

成功运行对应提交：`42b8a4f`（main）

## 运行 3 的 20 个步骤（全绿）

`checkout → Xcode/CocoaPods 版本 → 断言 Xcode ≥ 26 → Flutter 3.47.8 → flutter --version → TDLib 缓存 → 下载+SHA256+解包 → 断言 xcframework 布局与最低系统 → 拉 td_api.tl → pub get → analyze → unit test → pod install(+链接参数断言) → flutter build ios --release --no-codesign → 二进制符号校验 → 打 unsigned IPA → 上传 artifact → 失败日志上传(skip) → 回写 ci-report 分支 → 收尾`

## 真实环境

```
macOS   26.6.2 (25G83), macOS ARM64 runner
Xcode   26.6 (17F113)
Swift   Apple Swift 6.3.3 (swiftlang-6.3.3.1.3)
iOS SDK 26.5
CocoaPods 1.17.0
Flutter 3.47.8 stable / Dart 3.13.7 / engine dfd2e6cb7d
```

## TDLib 链接证据

```
xcframework 切片      app.swiftgram.tdlibframework.iOS
切片 MinimumOSVersion 12.0
CFBundleShortVersionString 1.8.69
二进制形态            static archive? yes (ar archive: linked in, nothing to embed)
Podfile.lock          tdlib (1.8.69)
Pods-Runner.release.xcconfig:
  OTHER_LDFLAGS = $(inherited) -ObjC -Wl,-u,_td_create_client_id -Wl,-u,_td_execute
                  -Wl,-u,_td_receive -Wl,-u,_td_send -l"c++" -l"flutter_secure_storage"
                  -l"z" -framework "AVFoundation" -framework "CoreFoundation"
                  -framework "CoreMedia" -framework "Foundation" -framework "Security"
                  -framework "TDLibFramework"
nm -gU Runner        000000010152e91c T _td_create_client_id
                     ... (td_send / td_receive / td_execute 同样存在)
结论                 all four tdjson entry points are present in Runner
```

## 产物

| 项 | 值 |
|---|---|
| 文件 | `TGMediaProbe-unsigned.ipa` |
| 大小 | 19,442,605 字节（19 MB） |
| SHA256（CI 声明） | `326d69f48811a71f36d0ee07071e3d1260bf174a9ee79e498c9f4957733ae42c` |
| SHA256（本机独立重算） | `326d69f48811a71f36d0ee07071e3d1260bf174a9ee79e498c9f4957733ae42c` ✅ 一致 |
| 结构 | zip 78 项，单一 `Payload/Runner.app` |
| Runner 可执行文件 | 41.9 MB，Mach-O 64-bit thin，cputype 16777228 = **arm64** |
| `MinimumOSVersion` | **15.2** |
| `LC_BUILD_VERSION` | platform 2 (iOS), **minos 15.2**, sdk 26.5 |
| CFBundleIdentifier | `com.tgmedia.tgMediaProbe` |
| CFBundleDisplayName | TG Media Probe |
| UIDeviceFamily | `[1, 2]`（iPhone / iPad） |
| UIRequiredDeviceCapabilities | `[arm64]` |
| 内嵌 Frameworks | `App.framework` / `Flutter.framework` / `objective_c.framework` + 两个插件 bundle |
| 是否内嵌 TDLib 动态库 | **无**（静态链接进 Runner，符合预期） |
| 代码签名 | **无**（`--no-codesign`，由 TrollStore 安装时自行签名） |
| 本机副本 | `artifacts/run-40198573231/build/ios/ipa/TGMediaProbe-unsigned.ipa` |
| CI 侧完整日志 | 同一目录 `ci-report/*.txt`（24 个文件），另见 `ci-report` 分支 |

## 第一次失败：Xcode 16.4 编不过插件

`macos-15` runner 是 Xcode 16.4 / iOS SDK 18.5。`video_player_avfoundation 2.12.3` 的源码：

```swift
// AVFactory.swift:117
func load<T>(_ property: AVAsyncProperty<AVAsset, T>, isolation: isolated (any Actor)?)
// VideoPlayer.swift:568
let naturalSize = try await videoTrack.load(.naturalSize, isolation: #isolation)
```

`isolation:` 这个重载只在 iOS 26 SDK 存在，Xcode 16.4 报
`Extra argument 'isolation' in call` / `Extraneous argument label 'isolation:'`。

修复：runner 改 `macos-26`（Xcode 26.6），并加断言步骤（Xcode < 26 时自动 `xcode-select` 到 `Xcode_26*.app`，没有就 fail）。
Apple 官方 SDK 支持表：Xcode 26 的部署目标范围是 **iOS 15–26**，所以 15.2 不受影响（构建产物 `minos 15.2` 已证）。

## 第二次失败：符号被 dead-strip

第一次只写 `-Wl,-u,_td_create_client_id`。结果 `_td_create_client_id` 在，其余三个不在：

```
found with: nm -gU
0000000100033570 T _td_create_client_id
ERROR: _td_send missing from binary
ERROR: _td_receive missing from binary
ERROR: _td_execute missing from binary
```

这是**功能性 bug**，不只是校验问题：`lib/td/tdjson_ffi.dart` 运行时要 `DynamicLibrary.process().lookup('td_send'/'td_receive'/'td_execute')`，缺一个就整条链路起不来。

修复：四个 `-u` 全写，并在 pod install 步骤里逐个 grep 断言 `-u,_<sym>` 真的进了 `Pods-Runner.*.xcconfig`。

## 顺带修掉的两个隐性坑

1. **CRLF**：Windows `core.autocrlf=true` 把 CRLF 写进了 `.sh / Podfile / podspec`，macOS 上会 `/bin/bash^M: bad interpreter`。加 `.gitattributes`（`* text=auto eol=lf` + 逐类型 `eol=lf`）+ `git add --renormalize`，现为 `i/lf`。
2. **Runner 没 include Pods 的 xcconfig**：`ios/Flutter/Debug.xcconfig`、`Release.xcconfig` 原本只有 `#include "Generated.xcconfig"`，CocoaPods 会警告 base configuration 未设置，后果是 `-framework TDLibFramework` 和四个 `-u` 全都不进链接参数。已补 `#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.*.xcconfig"`，CI 里也有对应断言。

## 状态口径（不可互相替代）

| 状态 | 结论 |
|---|---|
| 代码已编写 | ✅ |
| 自动化测试已通过（37 passed / 1 skipped） | ✅ |
| iOS 包已构建成功（Xcode 26.6，arm64，minos 15.2） | ✅ |
| IPA 已生成并本地校验 SHA256 | ✅ |
| IPA 已安装到 iPhone 11 Pro | ❌ **未执行** |
| Telegram 真实登录 | ❌ **未验证** |
| 真实频道列表 / 媒体元数据 | ❌ **未验证** |
| 真实视频播放 | ❌ **未验证** |
| 真实媒体下载 | ❌ **未验证** |
| 缓存清理安全测试 | ❌ **未验证**（第 3 步实现后才有对象） |
