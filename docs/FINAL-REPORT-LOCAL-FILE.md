# 整体重构 · 最终报告（LOCAL_FILE 单链）

日期：2026-10-29
分支：`rebuild-step3`，提交 `6588210`
工作流：`ios-probe` / run `40814072216`

---

## 1. 一句话结论

边下边播已**正式废弃**。播放链路只剩一条：**Telegram → TDLib → 完整下载 → 四重校验 → 本地文件 → video_player/AVPlayer**。
没有 ResourceLoader、没有 HTTP Proxy、没有 GrowingFileReader、没有随机 Range、没有 partial-file playback。
一条 23MB / 152MB / 593MB 的视频，要么是「已验证的本地文件」，要么是「明确的错误 + 重试按钮」，中间没有第三种状态。

---

## 2. 决策依据：E1 真机数据

| 项 | 值 |
|---|---|
| device | iOS 15.3.1 |
| TDLib | 1.8.69 |
| fileId | 4376 |
| fileSize | 2362816 |
| chunk #0 (`offset=0, limit=1048576`) | 1048576 bytes |
| chunk #1 / #2 | 0 bytes |
| TDLib 返回 | `400: There is not enough downloaded bytes in the file to read` |

结论：TDLib 的**有界区间读取**在未下载时拿不到字节，可靠窗口只有本地已落盘的部分。因此「边下边播」不是调参问题，是架构不成立。E1 判定为 **FAIL**，并作为架构依据写进文档（不得改判 PASS）。

---

## 3. 最终架构

```
Telegram 频道
   │  messages.getHistory（只读）
   ▼
TDLib  ── downloadFile(offset: 0, limit: 0) ──► 磁盘完整文件
   │                                              │
   │                                    ┌─────────┴──────────┐
   │                                    │ CacheValidator     │ 四条独立事实：
   │                                    │ 1 is_downloading_completed == true
   │                                    │ 2 路径存在
   │                                    │ 3 磁盘大小 == 承诺大小
   │                                    │ 4 首 4KB 可读
   │                                    └─────────┬──────────┘
   │                                              ▼
   │                                        DownloadPhase.ready（唯一可播放终态）
   ▼                                              │
PlaybackController ── 单播放器（先 dispose 旧的，再建新的） ──► VideoPlayerController.file()
```

关键约束（都有测试守着）：

- **只有一个下载任务**：`DownloadManager.ensureLocal` 对另一个 fileId 会先 `cancelDownloadFile`。
- **只有完整文件能进播放器**：`MediaPreparer` 接口只向播放层暴露 `DownloadOutcome.ready(path)`。
- **只有一个播放器实例**：`PlaybackController` 用 `_PlayerSlot` 做幂等释放，`livePlayerCount` 由测试断言 100 次切换 ≤ 1、dispose 后 = 0。
- **无预加载**：翻页只切索引，下一页不发任何请求。
- **编号 = 历史位置**：`MediaIndex.fromRecords` 按 `(messageDateUnix, messageId)` 升序，索引+1 即编号，最早 = `#001`；新视频追加不重排；`fileId` 变化不影响编号；编号从不来自 `fileId`/`messageId`。

---

## 4. 删除清单（本次提交共 -33346 行 / 71 个文件）

### Dart 播放链（19 个，`lib/playback/`）
`download_audit.dart` `downloader.dart` `growing_file_reader.dart` `media_metadata.dart` `mp4_probe.dart` `native_streaming.dart` `playback_failure.dart` `playback_lifecycle.dart` `playback_session.dart` `playback_trace.dart` `player_slot.dart` `resource_loader.dart` `source_decision.dart` `stream_proxy.dart` `stream_window.dart` `streaming_diagnostics.dart` `video_player_handle.dart` `video_source.dart`

### UI（7 个，`lib/ui/`）
`feed_controller.dart` `feed_page.dart` `channel_pages.dart` `chunk_probe_panel.dart` `probe_page.dart` `streaming_overlay.dart` `storage_panel.dart`

### 存储清理旧层（5 个，`lib/storage/`）
`cache_manager.dart` `cache_budget.dart` `active_files.dart` `temp_zone_report.dart` `cache_ownership.dart`
（旧的「临时区白名单清理 + 缓存上限策略」整套退役；本地字节的唯一删除者现在是 `MediaCache`）

### TDLib 探测（3 个，`lib/td/`）
`chunk_probe.dart` `media_probe.dart` `download_metrics.dart`，以及 `lib/data/video_number_lookup.dart`

### iOS（3 个 Swift + 工程引用）
`ios/Runner/Streaming/TGMediaPlayer.swift` `TGMediaResourceLoader.swift` `TGMediaStreamingPlugin.swift`
`project.pbxproj` 中 `Streaming` 出现次数 = **0**

### 功能级删除
抖音 Tab、第二个/第三个 Tab、我的、图片、文件、收藏、下载历史、下载任务、时长筛选、右侧点赞/评论/分享/头像栏、长按菜单、边下边播、HTTP Proxy、ResourceLoader、GrowingFileReader、随机 Range、ChunkMediaPlayer

### 测试（33 个旧文件）
streaming_diagnostics / chunk_probe / feed_controller / immersive_feed / video_source(_v2) / playback_trace / streaming_playback / source_decision / preload_count / playback_failure / playback_recovery / download_audit / downloader / resource_loader / feed_number_jump / mp4_probe / video_number_lookup / stream_window / player_slot / feed_full_set / download_metrics / switch_stress / streaming_overlay / watch_store / feed_counts / final_architecture / no_user_download / feed_paging_regression / cache_budget / cache_clear / cache_ownership / temp_zone_report / 等

---

## 5. 新增 / 重写

### 新增（26 个文件，+5636 行）

| 文件 | 职责 |
|---|---|
| `lib/download/download_state.dart` | `DownloadPhase`（idle/checking/downloading/verifying/ready/failed/cancelled）、`DownloadFailure`（含中文文案）、`DownloadOutcome`、`MediaPreparer` 接口 |
| `lib/download/download_manager.dart` | 单任务下载状态机、`_Run` 身份隔离、续传、停顿看门狗（25s 无新字节 → 重启一次 → 报错） |
| `lib/download/download_speed.dart` | 1s 窗口 EWMA(0.4) + 无进展衰减；计数倒退即重启，绝不出负数 |
| `lib/download/cache_validator.dart` | 四重完成判定；`downloaded_size >= size` **不**参与判定 |
| `lib/download/media_cache.dart` | `mediaRoot` 内测量/清理/磁盘空间；删除后校验文件确实消失才计入释放字节 |
| `lib/playback/local_media_player.dart` | 只认 `VideoPlayerController.file(File(path))` |
| `lib/playback/playback_controller.dart` | 单播放器、generation 丢弃被取代的加载、`_PlayerSlot` 幂等释放 |
| `lib/data/media_index.dart` | `#001` 稳定编号、`parseMediaNumber`、搜索、`displayTitle`（caption→fileName→`视频 #001`） |
| `lib/platform/disk_space.dart` | `MethodChannelDiskSpace('com.tgmedia/storage')` → `volumeAvailableCapacityForImportantUsage`；不可测返回 -1 视为可下 |
| `lib/ui/channel_page.dart` | 频道列表（`N 个视频` / `统计中` / `该频道没有可播放的视频`） |
| `lib/ui/channel_videos_page.dart` | 编号列表、按编号跳转（`未找到 #023（当前共 N 条）`）、搜索、下拉刷新 |
| `lib/ui/video_player_page.dart` | 全屏播放页、单击显示/隐藏、双击暂停/播放、上下滑切换、横屏、无长按 |
| `lib/ui/diagnostic_badge.dart` | 默认 OFF；下载中=速度+真实字节，完成=`LOCAL_FILE`+大小，失败=`DOWNLOAD ERROR` |
| `test/support/fake_transport.dart` `fake_player.dart` `fake_preparer.dart` | 三个边界替身，使 widget 测试不依赖真实磁盘 IO |

### 重写
- `lib/app/app_root.dart`：两 Tab（频道/设置）、`_SessionTransport`、装配 `MediaCache` + `DownloadManager`
- `lib/app/app_preferences.dart`：播放速度 / 主题 / 默认静音 / 诊断角标；删除预加载与缓存上限
- `lib/ui/settings_page.dart`：五组「账户 / 安全 / 播放 / 缓存 / 关于」
- `lib/data/media_record.dart`、`lib/data/index_store.dart`、`lib/storage/storage_layout.dart`（新增 `mediaRoot`，`tdlibFilesDir = mediaRoot/tdlib`）
- `ios/Runner/AppDelegate.swift`：移除 Streaming 插件注册，新增 `com.tgmedia/storage` 通道

---

## 6. 本轮修掉的三个真实缺陷（由新测试暴露）

1. **`DownloadManager` 状态串台**：被取消的旧 run 结束后清空了新 run 的 `activeFileId`/`_pending`，表现为「点第二个视频，管理器显示没在下东西」。改为 `_Run` 身份化，只有 owner 能清理状态。
2. **`PlaybackController` 二次释放**：被取代的加载在 `open()` 返回后继续触碰已释放的 player，第二次 `dispose()` 抛 `A FakePlayer was used after being disposed`（真机上等价于崩溃）。改为 `_PlayerSlot` 幂等释放 + 每次平台调用前判 stale。
3. **`MediaCache.clearLocal` 假成功**：删除调用静默失败时仍计入「已释放字节」，用户会看到「释放 500MB」而磁盘没变。改为删除后 `exists()` 复核，失败归入 `errors`。

---

## 7. 验收数据（本机可验证部分）

| 项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **No issues found!**（13.3s） |
| 单元/组件测试 | `flutter test` | **567 passed / 1 skipped / 0 failed**（≈45s） |
| 跳过项 | `tdjson_load_test` | `TDJSON_PATH` 未设置：本机无 TDLib 二进制 |
| iOS 编译 + 未签名 IPA | GitHub Actions `ios-probe` | 见第 8 节 |
| TDLib 运行时 | 本机无 xcframework | **NOT TESTED** |
| iPhone 11 Pro 真机（23MB / 152MB / 593MB / 100 次切换） | 需真机 | **NOT TESTED** |

### 测试覆盖（按主题）
- `media_index_test`（12）：`#001` 是最早、追加不重排、fileId 变化不动编号、`23`/`#023` 解析、`displayTitle` 不含 messageId
- `download_manager_test`（12）：缓存命中零请求、验证后才 ready、大小不符即失败并 deleteFile、空间不足零请求、取消不产生 ready、停顿上报、一次重启、第二视频取消第一视频、TDLib 错误、无 fileId
- `playback_controller_test`（9）：单播放器、被取代的加载不留残留、**100 次切换 livePlayerCount ≤ 1 且 dispose 后归 0**
- `video_player_page_test`（10）：编号与字幕一致、角标三态真实、失败文案与重试、上滑切页、单击切换控制栏
- `cache_validator_test`（8）/ `media_cache_test`（6）/ `download_speed_test`（6）
- `architecture_scan_test`（13）：旧模块不得复活、`lib/playback` 仅两文件、无 ResourceLoader/Proxy/GrowingFile 字样、iOS 无 Streaming、`downloadFile` 只由 download_manager 发出、播放器只开文件、两 Tab 且无抖音、无 `onLongPress`、角标默认 false、`mediaRoot` 不在 Caches、本地字节只有一个删除者
- `security_negative_test`（9 组）：越界删除、符号链接逃逸、只清自己目录、占用中文件、假成功、Keychain、密码记录被改、诊断未脱敏、只读守卫

---

## 8. iOS 构建结果（CI 实测）

GitHub Actions `ios-probe` / run `40814072216`（`macos-26`，Xcode 26，Flutter 3.47.8）**全部步骤通过**：

| 步骤 | 结果 |
|---|---|
| Analyze | ✓ No issues found!（6.9s） |
| Unit tests | ✓ 567 passed / 1 skipped / 0 failed（33s） |
| Build unsigned iOS app | ✓ `Built build/ios/iphoneos/Runner.app (61.0MB)`，61.9s |
| TDLib 符号证明 | ✓ `_td_create_client_id` `_td_send` `_td_receive` 均在 Runner 内 |
| Package / Upload IPA | ✓ |

产物：

| 项 | 值 |
|---|---|
| 大小 | 19,760,922 bytes（18.8 MB） |
| sha256 | `7c2f12267e303eb42eb6846e4663960597c54524ddfb58bc127c8e23b7e62c36` |
| bundle id | `com.tgmedia.tgMediaProbe` |
| MinimumOSVersion | 15.2 |
| 桌面副本 | `TGMediaProbe-step14-LOCAL-FILE.ipa` + `.sha256` |

细节见 `docs/CI-RUN-REPORT-LOCAL-FILE.md`。

---

## 9. 未完成项（诚实清单）

| 项 | 状态 | 说明 |
|---|---|---|
| TDLib 运行时加载 | `NOT TESTED` | 本机无 `TDLibFramework.xcframework`，`tdjson_load_test` 跳过；CI 有二进制但只验证链接符号，未跑真实登录 |
| iPhone 11 Pro 真机验收（23MB / 152MB / 593MB） | `NOT TESTED` | 需要设备，未执行 |
| 100 次连续切换的真机表现 | `UNIT TESTED` / 真机 `NOT TESTED` | 单测已断言实例数 ≤ 1；真机内存曲线未测 |
| 后台/锁屏恢复播放 | `NOT TESTED` | 未在真机验证 |
| 横屏（设备旋转锁关闭） | `UNIT TESTED` / 真机 `NOT TESTED` | 旋转锁开启时给出明确提示，不假装成功 |

---

## 10. 复现命令

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
export PATH="/c/flutter-sdk/bin:$PATH"
cd F:/AI-HuanCun/2026-10-25-20-11-38/tg_media_probe
flutter analyze
flutter test
git push origin rebuild-step3          # 触发 ios-probe，产出未签名 IPA
"/c/Program Files/GitHub CLI/gh.exe" run download <run-id> -n tg-media-probe-ipa --dir .
```

---

交流群 1121243020 ｜ 中转站 pursueray.cn ｜ 官网 http://103.212.186.16:8090/#what ｜ 本项目完全免费
