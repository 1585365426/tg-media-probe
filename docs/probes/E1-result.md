# E1 结果：连续分块下载

> **`E1 = NOT TESTED`**
>
> 实验代码已经完成并在自动化测试下通过，但**没有在真机上执行过**。
> 按任务书 §12，这一行不能写成任何形式的通过。
>
> 日期：2026-10-29 ｜ 分支 `rebuild-step3` ｜ 探针实现提交 `eeffaf3`

---

## 0. 为什么是 NOT TESTED

E1 必须在**已经登录的 TDLib 实例**上跑。这台开发机没有这个条件，三条都是实测：

| # | 事实 | 检查方式 | 结果 |
|---|---|---|---|
| 1 | 没有 C/C++ 工具链，无法自己编一份 Windows tdjson | `command -v gcc g++ clang cl cmake make ninja` | 全部为空；`C:\Program Files\Microsoft Visual Studio` 只有 `18/Installer/Shared`，没有 `cl.exe` |
| 2 | 全盘没有可运行的 tdjson 二进制 | `find C:\Users\Administrator F:\AI-HuanCun -iname "*tdjson*"` | 只命中 `lib/td/tdjson_ffi.dart` 和它的备份，没有任何 `.dll` |
| 3 | 预编译框架只有 Apple 切片 | `scripts/fetch_tdlib.sh` 拉的 `Swiftgram/TDLibFramework` xcframework | `ios-arm64 / ios-arm64_x86_64-simulator / macos-arm64_x86_64 / tvos-* / watchos-* / xros-*`，Windows 无法执行 |

更关键的是第 4 条：**TDLib 会话（auth key + `td.binlog`）在手机上**。即便前三条都解决，
在 Windows 起一个新实例也要重新输入手机号和验证码，等于给账号新增一台设备。E1 的样本
和身份都在那个已有会话里，用新会话测出来的东西还要再解释一遍，不如直接在手机上的同一个
`TdClient` 里测。

所以这轮交付的是**测量工具**，不是测量结果。

---

## 1. 已确认的语义（文档级，**未实测**）

下面四条来自仓库里钉住的 schema 文件 `test/fixtures/td_api.tl`（上游 master），
是 E1 的设计依据。它们**不是**实测结论，E1 跑的正是"文档这么说，实际是不是这样"。

```text
//@limit Number of bytes which need to be downloaded starting from the "offset"
//-position before the download will automatically be canceled; use 0 to download
//-without a limit
//@synchronous Pass true to return response only after the file download has
//-succeeded, has failed, has been canceled, or a new downloadFile request
//-with different offset/limit parameters was sent; pass false to return file
//-state immediately, just after the download has been started
downloadFile file_id:int32 priority:int32 offset:int53 limit:int53 synchronous:Bool = File;
```

```text
//@download_offset Download will be started from this offset. downloaded_prefix_size
//-is calculated from this offset
//@downloaded_prefix_size If is_downloading_completed is false, then only some prefix
//-of the file starting from download_offset is ready to be read. downloaded_prefix_size
//-is the size of that prefix in bytes
//@downloaded_size Total downloaded file size, in bytes. Can be used only for
//-calculating download progress. The actual file size may be bigger, and some parts
//-of it may contain garbage
localFile path:string can_be_downloaded:Bool can_be_deleted:Bool is_downloading_active:Bool
  is_downloading_completed:Bool download_offset:int53 downloaded_prefix_size:int53
  downloaded_size:int53 = LocalFile;
```

```text
//@description Returns file downloaded prefix size from a given offset, in bytes
getFileDownloadedPrefixSize file_id:int32 offset:int53 = FileDownloadedPrefixSize;
```

```text
//@description Reads a part of a file from the TDLib file cache and returns read bytes. ...
//@count Number of bytes to read. An error will be returned if there are not enough
//-bytes available in the file from the specified position. Pass 0 to read all
//-available data from the specified position
readFilePart file_id:int32 offset:int53 count:int53 = Data;
```

从这四条能推出三件直接影响播放器设计的事，但都还等 E1 确认：

1. `limit > 0` 的请求是**有界**的，到量自动取消 —— 所以"每 1 MB 一个请求"在 API 语义上成立。
2. `downloaded_prefix_size` 是**相对 `download_offset`** 的，不是绝对水位。
   旧 B+ 把它当绝对水位用，只在 `offset=0` 的整文件下载下碰巧对。
3. `downloaded_size` 文档明确说"实际文件大小可能更大，且其中部分可能是垃圾" ——
   任何把 `downloaded_size` 或 `stat` 长度当成"这段数据可用"的判定都是错的。

**版本差要留意**：fixture 是上游 master，App 链接的是 `1.8.69-025086e3`。
`getFileDownloadedPrefixSize` 与 `downloaded_prefix_size` 是否在这个具体构建里存在，
探针在每次运行开始时问一次，把答案写进报告头（`getFileDownloadedPrefixSize=present/absent`），
运行时的真实版本用 `getOption('version')` 取，不用脚本里钉的那个字符串。

---

## 2. 实验实现（已就绪）

| 文件 | 作用 | 行数 |
|---|---|---|
| `lib/td/chunk_probe.dart` | E1 引擎：分块计划、事件采集、双路校验、判定 | 1469 |
| `lib/ui/chunk_probe_panel.dart` | 真机入口：扫描样本、选档位、运行、复制结果 | 313 |
| `lib/ui/settings_page.dart` | 挂载点（「下载实验（E1）」分区） | +26 |
| `test/chunk_probe_test.dart` | 计划 / 信号 / 判定 / 锚点 / 持久性 的规则测试 | 487 行 / 29 条 |
| `test/architecture_scan_test.dart` | 新增门槛：`lib/playback` 不得引用探针 | +1 条 |

挂载在**设置页**而不是探针页：`ProbePage` 会自建第二个 `TdClient`，与 `AppSession`
持有的那个抢 `tb.binlog` 锁，TDLib 会直接回 "Can't lock file"。E1 必须测的就是
产品实际在用的那个客户端。

### 每次运行发出的调用

```text
getOption('version')                              # 记录真实 TDLib 版本
getFileDownloadedPrefixSize(fileId, 0)            # 探测该 API 是否存在
getFile(fileId)                                   # 基线
deleteFile(fileId)                                # 清本地缓存（仅本地）
getFile(fileId)                                   # 清空后基线
for k in 0..4:
    downloadFile(fileId, offset=k*1MB, limit=1MB) # 分块请求
    getFileDownloadedPrefixSize(fileId, k*1MB)
    getFileDownloadedPrefixSize(fileId, 0)
    getFile(fileId)
    pread(local.path, k*1MB, 1MB) -> sha256       # 直接读文件
    readFilePart(fileId, k*1MB, 1MB) -> sha256    # 经 TDLib 读
    if k > 0: 重读 chunk#0 并比对 sha
downloadFile(fileId, offset=5MB, limit=1MB, synchronous=true)  # 端到端计时
```

区间在 EOF 处截断，不会向 TDLib 要超出文件的字节（那会返回 error，容易被误判成分块失败）。

### 每块记录什么

对应任务书 §4「E1 必须记录」：

| 要求 | 落在哪里 |
|---|---|
| fileId / fileSize | 报告头 + 每块明细 |
| offset / limit | 每块明细 |
| 调用时间 | `调用时 t=<ms>`（Stopwatch，单调） |
| 调用耗时 | `ack=<ms>` |
| updateFile 顺序 | JSONL 逐行，带 `seq` 与 `t`，含全部五个字段 |
| downloadedSize | 每块的「调用后」快照 |
| downloadedPrefixSize | 同上，且与 `download_offset` 一起参与锚点判定 |
| file.path | 每块明细 |
| isDownloadingActive / canBeDownloaded | 每块明细 + JSONL |
| 是否 task 重建 | `activeRuns`（`false→true` 转换次数） |
| 是否出现 cancel | `endedInactive` + `diskAfterInactive` 门 |
| 是否 offset 自动变化 | `offsetDrift` |
| 是否停顿 | `maxGapMs`（相邻事件最大间隔） |
| 是否报错 | `ackError` 原文 |

### 对应的六个问题

| 问题 | 用什么回答 |
|---|---|
| Q1 连续 0→1→2→3→4 MB 是否稳定拿到数据 | 每块 POSIX 字节数 + 双读取器 sha 一致 |
| Q2 prefix 是连续前缀还是 RangeSet，锚在哪 | `download_offset + downloaded_prefix_size` vs `chunkEnd`，以及 `(0)` 与 `(offset)` 两次查询的对比 |
| Q3 换 offset 后旧数据是否还在 | 每次换 offset 后重读 chunk#0 并比对 sha |
| Q4 一个 fileId 是否只有一个活动区间 | 每块 `offsetDrift` + `activeRuns` + JSONL 里 `download_offset` 的变化 |
| Q5 换 offset 是否重建 task | `activeRuns` > 1 的块数与 `ack` 延迟 |
| Q6 每 1 MB 是否稳定完成 | 5 块全部满足，且同步请求的端到端耗时 |

---

## 3. 数据

**没有。** 全部字段等真机执行后填。下面是空表，状态一律 `NOT TESTED`：

| 档位 | 实际文件 | 大小 | moov | 分块数 | 全块可取 | 双读一致 | 旧块存活 | 判定 |
|---|---|---|---|---|---|---|---|---|
| ≈23 MB | NOT TESTED | — | — | — | — | — | — | `NOT TESTED` |
| ≈152 MB | NOT TESTED | — | — | — | — | — | — | `NOT TESTED` |
| ≈593 MB | NOT TESTED | — | — | — | — | — | — | `NOT TESTED` |

运行时版本、`getFileDownloadedPrefixSize` 是否存在、每个样本的真实大小与编码，
都以报告头里的实测值为准，不以本文档上方引用的文档值为准。

---

## 4. 判定规则（机器执行，不靠人读）

`evaluateE1()` 在 `lib/td/chunk_probe.dart`，规则是固定代码，29 条单测覆盖：

| 条件 | 结果 |
|---|---|
| 没有任何分块 | `NOT TESTED` |
| 任一块 `downloadFile` 报错 | `FAIL` |
| 任一块在超时内未填满窗口 | `FAIL` |
| 任一块 POSIX 读到的字节数 < limit | `FAIL` |
| 任一块两个读取器 sha 不一致 | `FAIL` |
| 五个分块全过，但旧块在后续 offset 后不可读 | `CONDITIONAL` |
| 实验开始时文件已完整（未清缓存） | `CONDITIONAL` |
| 五个分块全过，旧块存活 | `PASS` |

"两个读取器不一致"判 `FAIL` 而不是警告：一边是 POSIX 直读文件，一边是 TDLib 自己的
cache 读，两者不一致说明至少有一边读错了窗口，基于任一边的播放器都会放出错数据。

---

## 5. 已知会污染实验的情况

| 情况 | 症状 | 处理 |
|---|---|---|
| 文件在实验前已完整 | 五块瞬间"满足"，测不到下载 | 默认先 `deleteFile`；若未清，判定降为 `CONDITIONAL` |
| `deleteFile` 失败 | 基线仍非零 | 报告头与 `after_purge` 行会显示；判定同上 |
| 该构建没有 `getFileDownloadedPrefixSize` | 该字段全 `ERR` | 仍有 `downloadedSize` 与 `diskAfterInactive` 两条门，结论里会写明 API 缺失 |
| 手机在运行中被锁屏/切后台 | 事件间隔出现大空洞 | `maxGapMs` 会暴露；必要时重跑 |
| 频道视频已被旧版本 App 缓存 | 与"文件已完整"同 | 换样本或先清缓存 |

---

## 6. 真机执行清单

1. 装本轮的 IPA（同一份包含 E1 全部能力），登录一次，之后会话持久化。
2. 设置 → 最下方「下载实验（E1）」。
3. 「扫描频道视频」。列表按大小升序。
4. 点 `≈23 MB` → 「运行 E1」。等状态变成 `E1 = …`。
5. 「复制报告 (Markdown)」+「复制 JSONL 事件流」，贴回。
6. 重复 4–5 于 `≈152 MB`、`≈593 MB`。
7. 若某一档在频道里不存在，选最接近的那个，报告会自动记录真实大小 —— 不要为了凑
   档位编数字。

一次运行约 6 个区间请求，正常网络下几十秒。

---

## 7. 这一步交付了什么、没交付什么

**交付了**：能在真机上产出 E1 全部证据的工具，以及判定规则的可执行实现；
`flutter analyze` 0 issue；`flutter test` 1003 passed / 1 skipped。

**没交付**：E1 的结论。原因是环境，不是遗漏 —— 本机跑不了真实 TDLib，
这一点在本轮开始前就已经注定，不该用任何形式的"推测通过"填补。

**没有做的事**（按任务书 §3）：没有开始 ChunkMediaPlayer，没有写 Swift 播放器，
没有删旧播放链路，没有碰 `AVAssetResourceLoader`，没有引 FFmpeg，
没有复制 Telegram-iOS 或 Turrit 的任何代码/二进制，没有用 mock TDLib 造数据。
