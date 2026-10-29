# 探针日志约定

这个目录只放**真机跑出来的**实验记录。没有在真机上跑过的实验，这里只允许出现
`NOT TESTED`，不允许出现通过。

## 文件

| 文件 | 内容 |
|---|---|
| `E1-result.md` | 连续分块下载实验的结论与数据 |
| `E2-result.md` | tail-moov 实验（E1 通过后才做） |
| `E3-result.md` | 远程 seek / offset 切换（E1、E2 通过后才做） |
| `E4-result.md` | POSIX 读取 vs `readFilePart`（E1、E2 通过后才做） |

原始日志不放在仓库里：它在手机的 `Documents/probes/` 下，每次运行两个文件

```
E1-<yyyyMMdd-HHmmss>.jsonl   一行一个事件，含每个 updateFile 的完整快照
E1-<yyyyMMdd-HHmmss>.md      人读的汇总，可直接粘贴
```

`.jsonl` 的第一行是 `@type=e1_header`，带设备、TDLib 运行时版本、
`getFileDownloadedPrefixSize` 是否可用、文件身份和分块参数。没有这一行的
数据不能用来做结论。

## 状态词

只允许这五个，和任务书一致：

| 词 | 含义 |
|---|---|
| `PASS` | 实验完整跑完，所有证据一致 |
| `CONDITIONAL` | 数据可取，但存在明确限制，播放器必须绕开 |
| `FAIL` | 关键证据不成立 |
| `NOT TESTED` | 没有在白名单设备上真实执行 |
| `UNKNOWN` | 执行过，但结果无法判读 |

## 怎么跑 E1

1. 装最新 IPA，登录（会话会持久化，之后不需要再登）。
2. 设置 → 最下面「下载实验（E1）」。
3. 「扫描频道视频」→ 用 `≈23 MB` / `≈152 MB` / `≈593 MB` 三个按钮各选一个
   真实样本；如果某一档不存在，就选最接近的那个，并在报告里写明实际大小。
4. 保持「先 deleteFile」开启：「同步请求计时」保持开启。
5. 「运行 E1」→ 状态变成 `E1 = …` 后，点「复制报告 (Markdown)」和
   「复制 JSONL 事件流」，把两段贴回来。
6. 每个样本跑一次，共三次。

一次运行会发出 5 个 1 MB 的连续区间请求，外加一个同步区间，外加若干次
`getFile` / `getFileDownloadedPrefixSize`。全程只读云端，唯一会变的是本机
TDLib 文件池里那个文件（`deleteFile` 只删本地缓存）。
