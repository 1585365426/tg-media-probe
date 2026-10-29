# CI 运行报告 · LOCAL_FILE 重构

- 工作流：`ios-probe`
- run id：`40814072216`
- 提交：`6588210`（`feat(player): replace streaming with the LOCAL_FILE chain end to end`）
- 分支：`rebuild-step3`
- runner：`macos-26`，Xcode 26，Flutter 3.47.8
- 结论：**全部步骤通过**

## 步骤结果

| 步骤 | 结果 |
|---|---|
| Host / Xcode / CocoaPods 版本 | ✓ |
| Assert toolchain is Xcode 26+ | ✓ |
| Install CocoaPods | ✓ |
| Install Flutter 3.47.8 | ✓ |
| Cache TDLib xcframework | ✓ |
| Fetch, checksum and unpack TDLib xcframework | ✓ |
| Assert xcframework layout and minimum OS | ✓ |
| Fetch TDLib schema fixture | ✓ |
| Pub get | ✓ |
| **Analyze** | ✓ `No issues found!`（6.9s） |
| **Unit tests** | ✓ `567 passed / 1 skipped / 0 failed`（33s，`TDJSON_PATH` 未设置导致 1 skip） |
| Pod install | ✓（tdlib pod 存在，`-u,_td_*` 链接标志齐全） |
| **Build unsigned iOS app** | ✓ `Built build/ios/iphoneos/Runner.app (61.0MB)`，Xcode build 61.9s |
| Inspect linked binary（TDLib 符号证明） | ✓ `_td_create_client_id` / `_td_send` / `_td_receive` 均存在 |
| Package unsigned IPA | ✓ |
| Upload IPA artifact | ✓ |

## 产物

| 项 | 值 |
|---|---|
| 文件名 | `TGMediaProbe-unsigned.ipa` |
| 大小 | 19,760,922 bytes（约 18.8 MB） |
| sha256 | `7c2f12267e303eb42eb6846e4663960597c54524ddfb58bc127c8e23b7e62c36` |
| bundle id | `com.tgmedia.tgMediaProbe` |
| MinimumOSVersion | 15.2 |

桌面副本：
- `C:\Users\Administrator\Desktop\TGMediaProbe-step14-LOCAL-FILE.ipa`
- `C:\Users\Administrator\Desktop\TGMediaProbe-step14-LOCAL-FILE.ipa.sha256`

## 说明

- CI 的 `flutter test` 与本机结果一致（567 / 1 skip / 0 fail），说明重构没有依赖本机环境。
- 未签名 IPA 用 TrollStore 或自签工具安装；真机验收清单（23MB / 152MB / 593MB、100 次切换）仍需在 iPhone 11 Pro 上执行，本轮标记 `NOT TESTED`。
- 唯一告警是 GitHub 关于 `actions/*@v4` 使用 Node 20 的弃用提示，与代码无关。

---

交流群 1121243020 ｜ 中转站 pursueray.cn ｜ 官网 http://103.212.186.16:8090/#what ｜ 本项目完全免费
