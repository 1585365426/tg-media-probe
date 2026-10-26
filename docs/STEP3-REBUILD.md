# 第 3 步重做：把"慢"和"没反应"变成数字

生成时间：2026-10-26 17:20 (GMT+8)
分支：`rebuild-step3`
基线：`3480894`（第 3 步真机验证通过后的稳定点：A/B/C/D 修复已含）
本轮提交：`d572542`（功能）+ `11dde64`（CI 分支）

---

## 1. 为什么回到第 3 步

第 4 步之后每一轮都在同一处返工：

| 轮次 | 做法 | 结果 |
|---|---|---|
| 第 7 步 | 回环 HTTP Range 边下边播 | RangeServer 返回合法 206，TDLib 不给字节，`initialize()` 不抛异常、`timeout()` 不触发 → 黑屏 |
| 第 8 步 | 首帧看门狗 + 会话熔断 + 阶段文字 | 症状变成"一直加载"，仍不可播 |

共同点：两层都**没有真实测量**。播放器是否拿到字节、下载到底多快、缓存目录里有什么，全靠推断。第 7、8 步的修复都是针对推断出来的原因的补丁。

第 3 步是唯一在真机上完整走通"下载 → 本地文件 → AVPlayer 初始化成功、时长 27s"的版本（证据 `DEVICE-EVIDENCE-20261026-B.md` 第 9 项）。回到那里不是倒退，是把地基换回已验证的那一块，再把缺的测量补上。

**保留**：第 3 步全部内核（TDLib FFI、只读守卫、四区隔离、分页同步、单播放器槽、方向桥）。
**不含**：第 4 步之后的三 Tab、抖音页、收藏、设置页、锁屏、回环流式服务。这些不在本轮范围。

---

## 2. 本轮新增

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib/util/byte_format.dart` | 46 | 字节 / 速率 / 耗时格式化，全部纯函数 |
| `lib/td/download_metrics.dart` | 190 | 单次下载的首字节延迟、窗口速率、端到端均速、ETA |
| `lib/storage/temp_zone_report.dart` | 300 | 四区真实盘点 + 临时区整体清理 |
| `lib/ui/storage_panel.dart` | 330 | 盘点 / 清理界面，每区显示文件数与最大文件 |

### 2.1 下载变成可测

`DownloadMetrics` 记录三类数，回答三个不同问题：

| 数字 | 回答什么 |
|---|---|
| `timeToFirstByteMillis` | 是连不上，还是连上了但没数据 |
| `bytesPerSecond` | 现在这一刻有多快（尾部 3 秒窗口） |
| `averageBytesPerSecond` | 用户端到端体验到的速度 |

从字节 0 开始的平均值分不出"链路慢"和"启动慢"，而这个区分决定了下一步该加并发还是该换路子。窗口速率在只有 1 个样本、或字节数没动时返回 null，UI 显示 `—` 而不是 `0 B/s` —— 停转和零速是两件事。

下载前先发 `getFile`：文件已在池里（上次下过、或同一条视频点第二次）就直接跳到第 8 步，不再请求一次已经在磁盘上的传输。

进度文案节流到 ~8 Hz。TDLib 开始按块推 `updateFile` 之后，每个事件重建整页的成本会超过传输本身。

### 2.2 缓存改成按物理目录盘点

旧实现按 `CacheKind` 分类扫 `thumb/ player/ partial/`。只要有一个写入方用了第四个目录（例如 TDLib 的 `tdlib_files/`），计数就是 0 B，磁盘却在涨。

`TempZoneReport` 反过来做：

- 盘点：递归列 `tempRoot` 全部文件，逐个 stat，报文件数、字节、最大的 8 个；
- 清理：遍历 `tempRoot` 全部文件，逐个过 `assertDeletableByCacheClear`（那一刻重新解析符号链接），再删。

安全性不来自"目录白名单"，来自每文件一次的守卫。新加一个写入目录不需要改这个文件。

`StorageLayout` 改成每轮 `resolveRoots()` 解析一次四个区根，而不是每个文件解析四次 × 四个区。真实池上千 blob 时，这一步本身就是"点了没反应"的来源。

---

## 3. 测试

```
flutter analyze   No issues found!
flutter test      204 passed, 1 skipped（基线 164 → 新增 40）
```

新增三个测试文件：

| 文件 | 用例 | 覆盖 |
|---|---|---|
| `test/byte_format_test.dart` | 9 | 单位进位、三位有效数字、负数显示 `—`、毫秒/秒/分三档 |
| `test/download_metrics_test.dart` | 17 | 首字节空窗、窗口不含慢启动、停转返回 null、单样本不除零、未知大小不出百分比、样本上限、完成后事件被丢弃 |
| `test/temp_zone_report_test.dart` | 14 | 未知子目录被统计、最大文件排序、缺失目录不抛、清理不动受保护区、嵌套未知目录被清、字节只计真删掉的、占用文件跳过与释放后清掉、进度覆盖、空区幂等、保护区消失判失败 |

### 3.1 反向验证（确认测试能抓 bug）

| 注入的缺陷 | 结果 |
|---|---|
| `cleanTempZone` 只扫 `thumbnailDir`（复刻旧 bug） | `reaches a nested directory that no cache kind knows about` 失败 |
| `rateWindowMillis` 3000 → 1000000（窗口失效） | `window excludes ramp-up that the average keeps` 失败 |

两处还原后全量重新跑绿。

---

## 4. 状态口径

| 状态 | 结论 |
|---|---|
| 代码已写 | ✅ 4 个新模块、4 个文件改动 |
| 静态检查 | ✅ `No issues found!` |
| 单元测试 | ✅ 204 passed / 1 skipped |
| 反向验证 | ✅ 两处注入缺陷均被抓出 |
| iOS 构建 | 见 §5 |
| IPA 生成 | 见 §5 |
| 真机安装 | ❌ 未执行 |
| 真机登录 / 下载 / 播放 / 清理 | ❌ 未执行 |

---

## 5. 构建记录

（CI 运行完成后补）
