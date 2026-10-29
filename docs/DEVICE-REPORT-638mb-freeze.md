# 638 MB 停在 0.1% 且报告出不来：三个没有截止时间的等待

真机现象一句话：**`512 KB / 638 MB (0.1%)`，画面不动，诊断报告拿不到。**

这份日志里没有失败、没有超时、没有回退——不是"播放失败"，是**没有任何一层做出判断**。一个播放要走到"有结论"，必须有一个 await 完成；这次一个都没有完成，所以报告是空的。

## 512 KB 这个数字

`524288 = 512 × 1024`，正好是 `TGMediaResourceLoader.chunkBytes` 和 TDLib 单块下载的对齐量。所以它不是一个随机的进度点：**第一块之后没有第二块**。

有两种可能，表现完全一样，修法完全不同：

| 可能 | 现象 | 需要的修法 |
|---|---|---|
| TDLib 的传输死了（网络切换、内部挂起、被别的请求顶掉） | `downloaded_size` 停在 524288，`is_downloading_completed=false` | 取消 + 重新发起 |
| 文件是 tail-moov（moov 在末尾），播放器在等最尾部 | 下载在跑，但播放器要的字节在 638 MB 处 | 单独取一次尾部窗口 |

旧代码对两种都没有回答。所以这一版先做的是**让两种情况都能被区分出来**，而不是猜一个去修。

## 三个洞

### 1. `handle.load()` 没有截止时间

`video_player` 的 `initialize()` 只在 item 进入 `readyToPlay` 时完成。资源加载器还在等字节时，这个状态永远不会到，于是这个 future 永远不完成：

```
_installPlayer → await player.activate(url) → await handle.load()  ← 永久挂起
```

之后所有东西都停在这里：没有 `notePlayerReady`、没有 `notePlayerFailed`、没有 fallback 判定、没有 verdict。用户看到的是转圈，日志是空的。

改法：`PlayerSlot` 加 `loadTimeout`（默认 25s，可注入），超时抛 `PlayerLoadTimeout`，控制器记 `player_load_timeout`——和"解码失败"分开，因为一个是缺字节，一个是文件有问题。

### 2. 传输死了没人知道

TDLib 只在开始和结束时给事件，**没有"我停了"这个事件**。所以一个停在 512 KB 的 job，`isRunning` 永远是 `true`，上面每一层都在等一个不会到来的字节。

改法：`TelegramMediaDownloader` 订阅 `updateFile`，记录每个文件最远到达的字节和最后一次移动的时间；每 3s 扫一次，超过 `stallWindow`（15s）没有新字节时**先 `stat` 复核**（广播事件可能丢，重启一条健康的 638 MB 下载代价太大），确认没动才 取消 + 重新发起，最多 3 次；之后 job 置 `failed` 并写明原因。

### 3. 等整文件下载时从没读过 Downloader 的裁决

`_waitForFullDownload` 每 500ms 轮询一次，上限 30 分钟，判断条件只有"磁盘够不够"。job 死了它照样轮询。这就是"卡死且没有结论"的第二条路。

改法：轮询里读 `job.state == failed` 就立刻停，记 `download_failed_while_waiting:<原因>`。

## 这一版会产出什么数据

装上去重跑同一个 638 MB 文件，三种结局都能拿到一份可读的报告：

| 面板会出现 | 含义 |
|---|---|
| `player_load_timeout` + `event DOWNLOAD_STALL … retries=1/3` | 传输确实死了，看门狗已经重启过一次，日志里有 bytes/expected |
| `player_load_timeout` + `moov=afterMdat moovAt=638500000..638582783` + 下载在长 | tail-moov，播放器在等 638 MB 处的 moov，下载是健康的 |
| 正常播放 | 看门狗把死掉的传输救回来了 |

新增三行，全都不靠猜：

- `isDownloading=… silent=<秒>` —— `true` 加上不断增长的 silence 就是"卡死"的形状；百分比区分不了"在写"和"死了"。
- `event DOWNLOAD_STALL file=… age=…s retries=… reached=… expected=…` —— 看门狗自己的话，原样进面板和导出。
- `moov=afterMdat moovAt=<start>..<end>` —— `Mp4Probe.scan` 现在算出 box 的绝对偏移，尾巴在多少字节处是数字，不是推测。

## 故意没做的

**取尾部窗口（tail fetch）。** 它能让 tail-moov 的文件秒开，但要先解决一个连带问题：TDLib 先写尾部会 `ftruncate` 到完整长度，于是 `diskSize == expectedSize` 而中间是空洞——`isPlayableFromDisk` 会把它当完整文件放给 AVPlayer，播出来是花屏而不是黑屏。必须先让"完整性"从"文件长度"改成"覆盖区间"，再放这个窗口进来。等这份日志确认是 tail-moov，下一步就做这个，一次做完。

## 未验证

- 上述三种结局没有一条在真机上看到过（等这次装机）。
- STEP 6 矩阵（23MB / 152MB / 593MB / 1GB、弱网、后台、Seek、remap、`DISK_FULL`）仍未实测。
- 25s 的 `loadTimeout` 是否合适：理论上应该 ≥ 加载器自己的 10s `WAIT_TIMEOUT` 加一次重试，25s 是这么定的，但真机上没量过。
