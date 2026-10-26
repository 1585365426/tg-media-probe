# 第 4 阶段缺陷修复报告：分页、方向、播放位置、编号直达

生成时间：2026-10-27 00:55 (GMT+8)
分支：`rebuild-step3`
修复提交：`837c1f8`
修复前 HEAD：`379ab8c`（第 4 阶段上一轮修复报告）

**真机验证 0 项。** 本轮所有"已修"都指代码与自动化测试；真机部分见 §7，全部标未执行。

---

## 0. 三个数字分别是什么

用户提供了三组互相矛盾的数字，先把它们分开：

| 数字 | 来源 | 含义 |
|---|---|---|
| 84 条 / 视频 82 条 | 频道详情页页脚（截图） | 该频道**索引里有 84 行媒体记录**，其中 82 条是视频、2 条是图片。这是 `MediaPager(chatId)` 分三页累加出来的真实数字 |
| 38 条 | 抖音页首屏 | **一页 40 行减去 2 张图片**。既不是上限，也不是频道视频总数 |
| 4000+ 条 | 频道本身的消息总数 | Telegram 侧的历史消息量，与"视频数"不是一回事；索引只存媒体记录 |

结论：索引里确实有 82 条视频，而抖音页停在第一页的 38 条。38 是**一页过滤后的结果**，不是任何配置项。

---

## 1. 根因 A：拿到第一页之后不再增长

### 1.1 代码位置

`lib/ui/feed_page.dart` 的 `onPageChanged` + `lib/ui/feed_controller.dart` 的 `goToIndex/goNext`。

```dart
// 修复前（页面）
onPageChanged: (index) {
  controller.goToIndex(index);          // async，未被等待
  if (index >= controller.length - 1) controller.goNext();
},

// 修复前（控制器）
Future<void> goToIndex(int target) async {
  if (target == _index) return;
  if (target < 0 || target >= _items.length) return;   // 越界直接返回
  await _moveTo(target);
}
```

用户滑到第 38 条（index 37）时：

1. `goToIndex(37)` 开始执行，内部 `await _moveTo(37)` 需要等播放器释放/重建；
2. 同一帧里 `goNext()` 立刻执行，此时 `_index` 还是 36 → `_index + 1 = 37`，**不满足** `>= _items.length(38)`，于是走 `_moveTo(38)`；
3. `_moveTo(38)` 因越界直接返回；
4. 而 `PageView` 的 `itemCount` 仍是 38，**没有第 39 页可滑**，`onPageChanged` 再也不会触发。

于是列表永久停在 38。不是"Telegram 没有更多"，也不是"索引只有 38 条"——是打开下一页的唯一入口被这个竞态吃掉了。

### 1.2 修复

```dart
Future<void> goToIndex(int target) async {
  if (target == _index) return;
  if (target < 0) return;
  // 目标超出当前已加载窗口：先把窗口扩出来，再移动
  if (target >= _items.length) {
    if (!source.hasMore || _loadingMore) return;
    await _loadMoreAhead();
    if (target >= _items.length) return;
  }
  // 落到窗口尾部：后台再取一页，让下一次滑动有地方去
  if (target == _items.length - 1 && source.hasMore && !_loadingMore) {
    unawaited(_loadMoreAhead());
  }
  await _moveTo(target);
}
```

页面侧只保留一次 `controller.goToIndex(index)`，不再有"先 A 后 B"的竞态。

`_loadMoreAhead()` 抽出来，`goNext()` 与 `goToIndex()` 共用，避免两处各写一遍"加载下一页"。

### 1.3 回归测试（`test/feed_full_set_test.dart`，5 项）

用 84 行（82 视频 + 2 图片，日期全相同）复现截图里的数据形状：

| 用例 | 断言 |
|---|---|
| 索引里确实是 82 视频 / 84 行 | `countByChat == 82`、`page(500).items == 84` |
| 第一页 40 行 → 38 视频 | 复现"38"这个数字的来源 |
| 滑到尾部（`goToIndex(37)`）| `length > 38`，即窗口被扩开 |
| 走完整窗口 | `length == 82` 且 `atEnd == true` |
| 不带频道过滤 | 同样 `length == 82` |

---

## 2. 根因 B：没有一处持有竖屏

### 2.1 现状与修复

- 上一轮已让 `AppShell` 持 `lockedPortrait`、`PageOrientationScope.dispose()` 回 `portrait`；
- 本轮补上**播放页之外的全部路由**：`MaterialApp.home` 外层新增 `_PortraitHost`，登录页、解锁页、启动页、设置页都在它下面，不会再跟着手机横过来；
- 抖音页仍是 `lockedPortrait` 进入，只有 `_toggleLandscape()` 会请求 `forcedLandscape`；
- 退出播放页由 scope 的 `dispose()` 回竖屏。

### 2.2 测试（`test/orientation_test.dart` 新增 4 项 + 既有 3 项）

| 断言 | 说明 |
|---|---|
| `_PortraitHost(child: _buildRoot())` 存在且含 `lockedPortrait` | 默认竖屏包住整个路由器 |
| 播放页 `forcedLandscape` 只出现在 `_toggleLandscape` 之后 | 进入页面不会请求横屏 |
| `feed_controller.dart` 不含 `setMode` / `OrientationBridge` / `SystemChrome` | **切换视频不可能触发旋转** |
| `app_root.dart` 至少两处 `mode: lockedPortrait` | host + shell |
| 既有：`dispose` 顺序是 `setMode(portrait)` → `reset`，最终 `lockedPortrait` | 退出即竖屏 |
| 既有：壳竖屏 → 视频页横屏 → 退出 → 竖屏 | 借还关系正确 |
| 既有：`_toggleLandscape` 等 400 ms 后校验 `MediaQuery.orientation` | 原生失败不伪装成功 |

iOS 15 分支仍是 `UIDevice.setValue(forKey:"orientation")` + `attemptRotationToDeviceOrientation()`（`setNeedsUpdateOfSupportedInterfaceOrientations` 是 iOS 16+，上一轮已踩过）。

---

## 3. 根因 C：点第 5 条播第 1 条

### 3.1 根因

音频/视频由控制器驱动，画面由 `PageView` 驱动，两者**没有同步**：

- `goToMessage()` 只改控制器索引（`_moveTo`）；
- `FeedPage._pager` 仍在第 0 页；
- 于是屏幕显示第 1 条，声音是第 5 条；用户再滑一下又跳回第一条附近。

### 3.2 修复

`_onControllerChanged()` 里在帧后调用 `_syncPagerToController()`：

```dart
final target = controller.index;
if (_pager.page?.round() == target) return;
_pager.jumpToPage(target);   // 纠偏，不做动画
```

控制器仍负责"哪些视频、什么顺序"，页面只负责把索引画出来。

### 3.3 测试

- `feed_controller_test`：点首页命中不额外请求、跨页能找到、找不到返回 false 且停在当前项；
- `feed_number_jump_test`：编号 38 → `index == 37` 且 `messageId` 是该条（不是第一条）。

---

## 4. 新增 D：观看记录与进度

### 4.1 模块

`lib/playback/watch_store.dart`（188 行，新文件）：

| 项 | 设计 |
|---|---|
| 主键 | `chatId:messageId`。不用列表位置，列表变长不会把别人的进度挪过来 |
| 存储 | `index/watch.json`（受保护分区，缓存清理永不触碰），先写 `.tmp` 再 rename 原子替换 |
| 恢复规则 | 已看完 → 从头；<3 秒 → 从头；≥95% → 从头；其余回到「上次位置 −2 秒」 |
| 完成 | 播放位置 ≥ 时长 −600 ms 时写 `completed: true`，每条只写一次 |
| 写入频率 | 进度按整秒去重，不做每帧写盘 |
| 失败 | 写入/读取异常全部吞掉：磁盘满不能导致播放失败 |
| 不做 | 不写云端、不改频道内容、不是收藏/点赞/下载 |

`FeedController` 新增 `watch` 参数、`_restoreProgress()`（激活成功后 seek）、`_maybeRecordProgress()`（轮询里判定完成）、`resetProgress()`。

### 4.2 测试（`test/watch_store_test.dart`，15 项）

5 条恢复规则 · 重启后位置仍在 · 原子写无 `.tmp` 残留 · 两条视频互不影响 · 同 message_id 不同 chat 是两行 · 损坏文件当空历史 · 完成标记保留位置但重播从头 · 重置删除该行 · 清理不存在的行是空操作 · 写失败会抛给调用方（由 feed 吞掉）· 读失败返回 null 不抛。

**未验证**：真机上"退到后台再回来继续播"、"杀进程后重进恢复"——需要设备。

---

## 5. 新增 E：编号直达（替换原搜索入口）

### 5.1 规则

| 输入 | 行为 |
|---|---|
| `1` | 当前列表第 1 条 |
| `38` | 当前列表第 38 条；如果还没加载到 38，先继续分页直到覆盖或用尽 |
| 超过总数 | 「未找到该编号（当前共 N 条）」，**不跳回第一条** |
| `0` / 负数 / `>100000` / 非数字 / 空 | 「请输入 1 – N 之间的编号」，不发请求 |
| 列表中段被同步改变 | 先解析成 `(chatId, messageId)`，跳转后再校验落地身份；不一致返回 notFound |

实现：`FeedController.openNumber(int)` 返回 `NumberJumpResult { opened, notFound, invalid }`；顶栏入口从「搜索频道」改为「输入视频编号」（`Icons.tag`），弹窗只有数字键盘。原频道选择器 `_ChannelPicker` 一并删除（唯一调用方就是搜索入口）。**没有任何网络搜索**：这个测试里控制器根本没有 TdClient。

### 5.2 测试（`test/feed_number_jump_test.dart`，8 项）

编号 1 · 编号 38（断言 `index == 37`、`messageId` 正确）· 超出已加载窗口（20 → 60 条，边翻边找）· 超出全表（notFound 且停在原处）· 0/负数/超大值 invalid · 末尾编号 82 可达且 `atEnd` · 列表增长后编号 10 仍是同一条 · 编号跳转不触网。

---

## 6. 4000+ 条历史消息：续传式同步

### 6.1 根因

`syncCycle()` 每次 `cursor = null` 从头开始。一个 4000 条消息的频道，每轮只读 2 页（200 条）最新消息，**永远在读同一个范围**——即使上一轮已修好单页游标，也无法走到历史深处。

### 6.2 修复

```dart
Future<SyncCycleReport> syncCycle({
  required List<int> chatIds,
  int? pagesPerChannel,
  SyncCancelToken? cancel,
  bool resume = true,           // 新增
}) async {
  ...
  int? cursor = resume ? store.watermark(chatId)?.oldestMessageId : null;
```

- 默认 `resume: true`：从索引里最老的消息继续向更旧的方向走，反复调用就能一段段走完 4000 条；
- `resume: false`：从最新开始，用于"只想刷新最新"；
- 游标推进规则上一轮已改为"原始批次最老消息 id"，并且**游标不前进就结束本轮**；
- 末页判定只有一条：短页（`rawMessageCount < limit`）。

### 6.3 测试（`test/sync_4000_test.dart`，8 项，全部跑真实引擎 + 真实索引）

| 用例 | 实测结论 |
|---|---|
| 4000 条分批走到末尾 | `reachedEnd == true`，`countByChat == 400`（每 10 条 1 个视频），逐页取出的 id 集合恰好 400 个、全部 `id % 10 == 1` |
| 连续 5 轮游标单调深入 | 请求 `from_message_id` 序列 `[0, ...]` 严格递减，且**无重复值** |
| 中断后续传 | 5 轮后模拟"杀进程"，新建引擎从 watermark 继续，最终仍 400 条 |
| 刷新不重复索引 | `resume: false` 再跑一轮，`insertedRecords == 0`，总行数不变 |
| 限流恢复 | 第一轮 `FLOOD_WAIT` 报错，下一轮正常并推进 |
| 无视频批次 | 扫描 300 条、视频 0 条，`reachedEnd == false`，watermark 前进 |
| 末页只由短页触发 | 预算用完（1 页）时 `reachedEnd == false` |
| 索引行数不膨胀 | `countByChat(videosOnly: false) == 400` |

**注意**：这是模拟源，不是真实 Telegram。真实频道是否能在若干轮后走到 4000 条之前结束，必须真机验证；本报告不声称"真实频道已完整同步"。

### 6.4 进度与性能

- 扫描以 100 条/页、每轮 2 页为上限（`SyncLimits`），UI 线程不阻塞；
- 只索引媒体元数据（`MediaRecord`），**不预下载任何媒体字节**；播放时才 `downloadFile`；
- 可观察量：`SyncCycleReport.pages / rawMessages / insertedRecords / reachedEnd / lastError`，频道详情页页脚显示"已加载 N 条，其中视频 M 条（· 已到历史末尾）"；
- 不显示伪造的"4000/4000"：TDLib 不提供可靠的频道消息总数，界面只报已扫描与已发现。

---

## 6.5 CI 与产物

| 项 | 值 |
|---|---|
| CI run | [40358865054](https://github.com/1585365426/tg-media-probe/actions/runs/40358865054)（第 2 次尝试） |
| 结论 | **success**，9m38s（16:41:09Z → 16:50:47Z） |
| 提交 SHA | `837c1f8d200671abaa08523d0a06f20f011ead6e` |
| `flutter analyze` | No issues found（本机；CI step 13 同步通过） |
| `flutter test` | **643 passed / 1 skipped**（本机 `00:44`，CI `00:56`；skip = `TDJSON_PATH` 未设，本机无 TDLib 二进制） |
| IPA | `TGMediaProbe-unsigned.ipa` **19,774,382 B**（`ci-report/package.txt` 的 `ipa_bytes`） |
| SHA-256 | `02d5116eaa58f9bca1d768109b81d904bc9901c1e8ee283dbe114ba8cede2a6f` |
| 静态核验 | TDLib 静态链接进 Runner，四个 tdjson 符号导出；bundle `com.tgmedia.tgMediaProbe`，minos 15.2 |

**第 1 次尝试失败，原因不是代码**：

```
X The job was not acquired by Runner of type hosted even after multiple attempts
- Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.
```

排队 15 分钟后未拿到 macOS runner。`gh run rerun` 第 2 次成功。这条记录保留在案，因为它与"构建通过/不通过"是两件事。

测试数从 603 增到 643（+40）：分页全集 5、编号直达 8、观看记录 15、4000 条同步 8、方向策略 4。

---

## 7. 真机验证：0 项通过

| 项目 | 结果 |
|---|---|
| 抖音页滑到底部后条数增长（38 → 82） | 未执行 |
| 下拉刷新后条数与计数更新 | 未执行（本轮没有给抖音页加下拉刷新入口，见 §8） |
| 点第 5 条播第 5 条（画面与声音一致） | 未执行 |
| 编号 38 打开第 38 条 | 未执行 |
| 编号超范围提示 | 未执行 |
| 看完一条后重进是否回到开头 | 未执行 |
| 进度恢复到上次位置 | 未执行 |
| 杀进程后进度仍在 | 未执行 |
| 竖屏进入播放页不自动横屏 | 未执行 |
| 点全屏才横屏、退出即竖屏 | 未执行 |
| 系统方向锁提示 | 未执行 |
| 真实 4000+ 条频道同步到末尾 | 未执行（本机到 Telegram 不通） |

---

## 8. 未解决 / 需要注意

| 级别 | 问题 | 说明 |
|---|---|---|
| 高 | 全部真机项 | 见 §7，无一执行 |
| 中 | 抖音页没有下拉刷新 | 用户提到"下拉刷新后仍是 38"；本轮修的是翻页与索引，未给抖音页加 RefreshIndicator。若要"下拉重扫最新"，需要再决定交互位置 |
| 中 | 编号映射在列表头部插入新视频时会整体后移 | 现在是"当前列表第 N 个"，不是固定 id。若同步在顶部插入新视频，同一个编号会指向另一条；跳转已做身份校验，不会误播，但"38 永远是同一条"需要另立规则 |
| 中 | `syncCycle` 默认续传改变了语义 | 调用方若想"只刷新最新"，必须显式 `resume: false`；目前 UI 走的是续传 |
| 低 | 观看记录文件无上限 | 一个频道几百条视频会产生几百个小对象；未做裁剪 |
| 低 | 每轮 2 页 | 4000 条需要约 20 轮触底/同步才走完，符合"不一次性拉全量"的约束，但用户会感觉慢 |

---

## 9. 下一步

1. 装新 IPA，按 §7 顺序验：先竖屏/全屏（一眼可见），再点第 5 条（画面与声音是否一致），再滑到底看 38 → 82。
2. 触底仍不增长时，请记录页脚"已加载/视频"两个数字是否变化：不变说明同步没写索引；变而视频页不变说明翻页仍断。
3. 编号直达先验 1、38、82、83（83 应提示未找到）。
4. 第 5 阶段不动。
