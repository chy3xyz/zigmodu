# Changelog

## [Unreleased]

### 第 19 批：`RedisCooldownStore` 从来就没编译过（文档教用户照抄的代码编译不过）、`AutoInstrumentation` 的耗时全是 0（真红）、io-mutex 家族第二批 11 处、（**破坏性：否**，一处公开签名放宽）

全量 `-Ddb=all` **1845/1902（57 skipped，0 failed）**。

**`RedisCooldownStore` 从来没有任何调用者，于是四个 vtable 函数体一次都没被分析过 —— 它编译不过。**
第一次红跑没跑到测试就先炸出编译错误：
```
src/ai/cooldown_store.zig:244:36: error: member function expected 2 argument(s), found 3   (旧的三参 put)
src/ai/cooldown_store.zig:265:37: error: member function expected 2 argument(s), found 3
src/ai/cooldown_store.zig:295:42: error: incompatible types: 'u32' and 'void'               (del 的 u32 丢进 void catch)
（修掉前两条后再现）src/ai/cooldown_store.zig:282:59: error: division with 'i64' and 'comptime_int'
```
而 `docs/LLM_POLICIES.md:193` **明着教用户** `zigmodu.ai.RedisCooldownStore.init(...)` —— 照着抄就编译不过。
做最小机械修复（`put` 改两参并在失败时释放 dupe 的 key、`del` 的结果用 `if … else |err|`、
`/ 1000` → `@divTrunc`），并且新加的 Redis 测试通过 `asStore()` **真正实例化那张 vtable** ——
这正是 AGENTS.md 要求的那种"真正调用"测试，也是这类"只导出、没调用者"缺陷唯一的防线。
> **未验证**：本机没有 Redis，Redis 侧只跑了 fail-open 镜像路径（`stream=null`、无 pool，`acquireStream`
> 直接失败），真实的 `SET/INCR/EXPIRE/DEL` 与 TTL 秒数**未经真实 Redis 验证**（`REDIS_URL` 门控用例未启用）。

**`AutoInstrumentation` 的耗时测量是桩的 —— 每个上报的耗时都是 `0`。** 五处 `const start_time = 0;` /
`put(name, 0)` 让 `(0 - start_time)/1e9 = 0`，也就是说
`zigmodu_module_init_duration_seconds` 与 `zigmodu_event_processing_duration_seconds` 两个直方图
**每次 scrape 都在报一个"测出来的" 0** —— 比同一文件里那个（本批之前刚补了日志的）丢弃采样更严重。
红证据（桩还在时）：
```
InstrumentedLifecycleListener records a measured duration...FAIL (TestUnexpectedResult)
InstrumentedEventListener records a measured duration...FAIL (TestUnexpectedResult)
```
改成真实单调时钟（`core.Time.monotonicNow()`，i64 纳秒；注意 `Time.monotonicNowNanoseconds()` **不存在**），
单位保持**秒**（`_seconds` 直方图）并用 `@max(…, 0)` 兜住时钟重置；缺 start 时**不再从 0 起算**，
而是记一条 warn 并把 init 记为"未测量"（计数与活跃 gauge 照常走，避免 gauge 失同步）。
新用例断言的是**形状 + 量级**：`totalCount() == 1`（确实记了一条）且 `sum() >= 0.002` **小于 60 秒**
—— `>= 0` 是同义反复、会掩盖回归；下界绑在测试自己等的 2 ms 上，能同时否掉"桩（0）"与"减反（负数）"，
上界能抓住单位回归（纳秒/毫秒混进 `_seconds`）。端到端用临时探针抓真实 Prometheus 文本验证过：
`zigmodu_module_init_duration_seconds_sum 0.002150` / `..._event_processing_duration_seconds_sum 0.002018`。
> **公开签名放宽**：`recordModuleInit(module_name, duration_seconds: ?f64, success)` —— `f64` → `?f64`
> 是**源码兼容**的（`f64` 可隐式转 `?f64`），但它是公开 API，记一条。
> **顺带发现、未修**：`InstrumentedEventListener` 有泄漏（consume span 没人 `deinit`/destroy、
> 两个 map key 在 `onEventConsumeEnd` 里 `remove` 后从未释放、内联 `allocPrint` 出来的 span 名也没释放）；
> `PrometheusMetrics.ModuleMetricsCollector` 是**同一个桩**（`module_start_time = 0`、
> `getUptimeSeconds()` 返回 `0 - self.module_start_time` = 恒 0，而且那个减法方向还是反的），
> 目前 `getUptimeSeconds` 无调用者，属"只导出"状态。

**io-mutex 家族第二批：11 处改成不可取消的等待。** 延续上一批的两条家规（丢资源/伪造读数且调用方无错误
通道 → `lockUncancelable`；调用方有错误通道 → 传播）。这批改的是上一批列出的 leftowers：
`ClusterMembership` 的 `getNodeCount`/`getHealthyNodeCount`/`getLeader`（`0`/`0`/`null` 会被读成
"全挂了"/"集群没有 leader"，而后者正是 failover 的信号）、`Cron.jobCount`（`0` = "没有任何任务"，
而任务正在按时触发）、`cooldown_store` 的 `cool`/`bumpFailures`/`reset`**两个 store 各一套**（`bumpFailures`
返回 `0` = "该 key 从未失败"，喂给 `auth_fail_threshold` 会让一个泄漏的 key 永远不被封；跳过的 `reset`
让手工清零失效）、`pool/Pool.idle`（`0` 会被 `stats()` 当 `idle_count` 发布）。
红证据：`selected 13 of 1787 tests (filter "canceled lock wait") — 8 passed; 5 failed`，每处一条
（memory store / redis store / Cron / ClusterMembership / Pool）。绿：同一 filter 13/13。
> **未验证**：红只覆盖每个测试的**第一条断言**（Zig 的 `try` 首次失败即结束），所以 `bumpFailures` 与
> `reset` 只有绿跑覆盖；测试注释已按实测口径改写，没有超额宣称。
> **保持现状并复核了理由**：`DistributedEventBus.takeNodeSocket`（临界区里是**没有发送超时**的阻塞
> `writeAll`，`lockUncancelable` 会把拆除永久卡在一个停滞的对端后面；而 `catch return null` 不丢资源，
> socket 仍挂在 node 上，注释也已说明至多漏一个 fd）。要改它得先有**有界的等待**。

**同族清点的更大一批（只读盘点，未改）：** 这一轮同时做了一次跨文件盘点，按爆炸半径排出 15 处**真缺陷**，
其中三条属于"线程/定时器永久停摆"级别（`runtime/scheduler.zig:754 poolMain` 的 `catch return` 会让
**池线程永久消失**，而 `stats()` 仍在报它；`runtime/runtime.zig:2195/2216 tickerMain` 会让
**定时器在本进程余下的生命里不再触发**；`mailbox.zig:244 close` 置了 `closed` 却**不广播**，停在
`not_empty.wait` 的接收者永不醒来、join/关停挂住），另有 `redis.zig:293/307` 的 `releaseStream`/`evictStream`
（`in_use` 永不复位 → 池槽永久丢失 → 池满之后**每一条 Redis 命令都失败**）、`EventBus.publish` 是 `void`
（事件投给**零个**订阅者而调用方无从得知，而它挂在 CRUD 数据路径上）、`EventStore.SnapshotStore.load` 的
`null` 被 `replayFromSnapshot` 读成"没有快照、从版本 1 重放"（快照读取失败 → 从**错误的窗口**重建状态）、
`Router.match` 的 `dupe catch return null`（分配失败 → **存在的路由返回 404**，且在 `continue` 分支上
匹配成功却**静默丢掉路径参数**）、`ai/memory.zig` 的 `remember` **返回成功却没存**（`forget` 的静默无操作
会留下本该被删除的数据，包括隐私删除）、`ai/audit.zig` 的 `record` 会**丢掉审计条目**（包括
`.tool_denied`）…… 全部逐条附了"两个含义/丢了什么 + 调用方能否察觉 + 有没有可用测试夹具"。
> **这批尚未修**，排进下一批。盘点还纠正了一处**机制误述**：`std.Io.Mutex.lock` 的快路径
> （对 `unlocked` 的 `cmpxchgStrong`）**不做取消检查**，所以 `catch` 只在"那一刻恰好有争用**且**调用任务
> 被取消"时触发 —— 于是"每次都触发"只对**有争用的拆除路径**成立；这也决定了上面"池线程/定时器永久停摆"
> 三条的**可达性无法从代码确定**（那几条线程跑在哪个 `Io` 下不确定），盘点把这一点标为**最大不确定性**，
> 而不是当成既成事实。

### 第 18 批：`mutex.lock(io) catch …` 家族的系统清点（15 处改成不可取消的等待，含一处 UAF 与一处析构泄漏）、`LoadBalancer` 把"量不出来"读成"空闲"（真红）、一批"注释即修复"（**破坏性：否**）

全量 `-Ddb=all` **1838/1895（57 skipped，0 failed）**。

**`mutex.lock(io) catch …` 家族：8 个文件里 48 处逐个判定，15 处改了。** 关键机制（决定了大多数判定）：
这些 `catch` 全都发生在**临界区开始之前**，所以不存在"改了一半"——只有两种失败模式：**临界区根本没跑**
（状态/资源被永久留着）与**返回一个被当成事实的伪造值**。而且 `std.Io.Mutex.lock` 唯一的错误是
`error.Canceled`，一个正在被拆掉的任务**每次都**带着它，所以 `defer`/关闭路径里的那个 `catch` 是
**每次都触发**，不是偶尔。`lockUncancelable` 没有这个提前返回，也不是取消点。
红证据（7 条新用例，跑在修复前）：
```
ai.cooldown_store.test.canceled lock wait does not fabricate a key as not-cooling...FAIL
scheduler.Cron.test.canceled lock wait does not let the scheduler deinit leak its jobs
  [SafeAllocator] (err): leaked [len: 352]  leaked [len: 5]
  [default] (err): [cron] scheduler deinit: mutex lock failed; skipping job cleanup
scheduler.Cron.test.canceled lock wait does not report a live job as missing...FAIL
core.ModuleRuntime.test.canceled lock wait does not lose a bulkhead slot...expected 0, found 1
core.ModuleRuntime.test.canceled lock wait does not fabricate an all-idle stats reading...expected 1, found 0
im.ConnectionRegistry.test.canceled lock wait does not lose a disconnect...FAIL
im.ConnectionRegistry.test.canceled lock wait does not fabricate an offline reading...FAIL
zm-test-runner: selected 8 of 1780 tests — 2 passed; 6 failed; 1 leaked
```
改掉的 15 处里有三条值得单独点出来：
- **`ConnectionRegistry.unregister` / `unregisterByConn`：UAF。** 取消时条目留在 `by_user` 里、`ctx` 指向
  调用方**正要释放**的会话 —— 下一次 `sendToUser` 就是 use-after-free；而且它返回 `false`（读作"id 未知"），
  注册表级的清理永远不知道什么都没退掉。
- **`Cron.deinit`：析构函数泄漏。** 跳过清理会漏掉每个 job 名与列表，然后 `self.* = undefined`
  让补救也不可能。与第 17 批 `BufferPool.deinit` 同一类。
- **伪造读数**：`isOnline`（false = "用户离线"，网关按它路由）、`onlineCount`/`onlineUsers`（0/空）、
  `ModuleRuntime.getStats`（`.{}` = 全空闲/全健康）、`ClusterMembership.isLeader`/`nodesSnapshot`
  （"我不是 leader"/空集群，后者喂给路由用的 `ClusterView`）、`cooldown_store.isCoolingFn`
  （`!isCooling(key)` 正是 `key_pool` 重新选取该键的条件）、`LoadShedder.highThru`（false = "未过载"
  → 在过载时放行流量）。
> **未做（已列全）**：同族里还有一批未改 —— `ClusterMembership.getNodeCount`/`getHealthyNodeCount`/`getLeader`、
> `Cron.jobCount`、`cooldown_store` 的 `cool`/`bumpFailures`/`reset`（两个 store 各一套）、`pool/Pool.zig`
> 的 `idle()`。另有约 52 处分布在本次范围外的文件里（`ai/key_pool`、`ai/provider_registry`、`core/EventBus`
> 一族、`cache/Lru`、`runtime/mailbox`、`metrics/PrometheusMetrics` 等），**未被判定**。
> **一条记录在案的残留**：`DistributedEventBus.takeNodeSocket` 的 `null` 在 `disconnectNode` 路径上会漏
> 一个 fd；按规则它该用 `lockUncancelable`，但那里的对端写没有超时，等锁可能让拆除永远停在一次卡住的
> `writeAll` 后面 —— 所以**没改**，记为残留而不是修复。
> **未验证**：改动里 8 处只有"triage 推理 + 本文件套件绿"，**没有红证据**（没搭 `ClusterMembership`/Redis
> fixture；其余四处按"每个文件一条复现"这预算取舍）；`lockUncancelable` 的阻塞代价未测量（只按检视确认
> 没有嵌套持锁）；全部为 macOS + Debug。

**`LoadBalancer` 把"量不出来"读成"空闲"（真红）。** `getConnectionCount` 的
`bufPrint(...) catch return 0`：对端名装不进 128 字节栈缓冲时返回 **0 条连接** —— 而 `0` 正是
`.least_connections` **最喜欢**的值，于是**量不出来的对端反而吸引流量**（与本文件刚把 `recordResult`
改成可失败、"绝不记录一个假值"的决定自相矛盾）。红证据：
```
LoadBalancer least_connections: an unreadable count is not read as idle...FAIL (TestUnexpectedResult)
  try std.testing.expect(std.mem.eql(u8, picked.host, "10.0.0.1"));   ← 有 7 条连接的长名对端赢了
```
改法：返回 `?u64`（栈缓冲装不下就回落到真正构造 key 的那条路径，所以合法的 253 字节主机名**永远**可测），
选择器对量不出来的对端 `orelse continue`（全部量不出来时保持原答案）。

**一批"注释即修复"（这些地方代码是对的，但读者无从知道）。** 三处的结论是"合法的尽力而为，但**没说**"：
`AutoInstrumentation` 丢弃一次耗时采样（同一文件几行之上就有"报告被丢弃的 span 事件"的既有约定）、
`OutboxConsumer` 的可选 gauge 注册失败（一个静默缺席/陈旧的 gauge 读起来就是"一切正常"，而这正是本文件
开头那段文档要防的事）、`scheduler.wakeIdle` 的锁等待（错过一次唤醒的代价是一个 poll 间隔，有文档语义
兜底，且没有调用方能对失败做任何事）。三处都补了文档 + 日志，**行为不变**。
反过来说，有两处审计点经核查是**形状不符**：`scheduler.zig` 那个是**测试假件**（真实生产者路径把
`error.Full` 回压给调用方），`api/Server.zig` 那处不是吞错（header 拒绝会回真 500，其余记 err 并关连接 ——
在一条刚失败的 socket 上这是调用方仅有的通道）。
> **顺带确认一条被怀疑的事**：`ClusterMembership.checkNodeHealth` 先 `free` leader 再 `null` 再重选，
> **不是缺陷** —— 两条语句在**同一次持锁**内（`lock` 在 :180、`defer unlock` 在 :213），而 `isLeader`/
> `getLeader` 取同一把锁，所以读者看不到那个中间态；且它**永远不会**在有健康节点时停在 `null`（`self` 在
> `init` 插入、文件里没有任何移除路径、也从不会被移到 `.healthy` 之外）。已用注释 + 一条回归用例钉住，
> **没有改生产代码**。
> **未做（新发现）**：`AutoInstrumentation` 的时钟是**桩** —— `const start_time = 0;` 让每个记录的耗时都是
> `0 - 0 = 0`，这是比它上面那个吞错更严重的"伪造值"，但不在本批的审计清单里，修它要引入真实时钟
> （`Time.monotonicNowNanoseconds`）并会动到所有针对耗时的断言；`ClusterMembership` 里到达 `.failed` 的
> 节点**从不被移除**，`getNodeCount`/`nodesSnapshot` 会一直把死对端算进去（leader 仍正确，因为
> `electLeaderLocked` 按状态过滤），要做退役策略（TTL/回收），比本批大。

### 第 17 批：`BufferPool.deinit` 在锁被别人持有时**照样**释放空闲表（内存不安全）、`verifyToken` 在分配失败时泄漏已拷好的字段（OOM 扫描抓出）（**破坏性：否**）

全量 `-Ddb=all` **1829/1886（57 skipped，0 failed）**。

**`BufferPool.deinit` 的 `tryLock` 失败路径是内存不安全的。** 旧实现抢不到锁就**直接**
释放空闲表 —— 而持锁者要么正在 `release`（它现在会不可取消地等这把锁），要么正要进入临界区：
于是 `free.append` 会写进已释放的存储，同一条缓冲区还可能被释放两次。这不是"少一次析构"，是 UAF。
红证据（把修复临时还原后）：
```
deinit waits for a held lock instead of freeing underneath its holder...FAIL (TestUnexpectedResult)
```
改法：析构函数必须跑完，所以**等**（`lockUncancelable`，与 `cache/Lru.zig`、`pool/Pool.zig` 的 `deinit`
同一规则）；这里没有错误通道，`catch return` 只会留下一个永远没人释放的池。新用例用两个线程
（一个故意持锁、一个 `deinit`）+ 一个 `deinited` 标志钉住"不能在持锁期间完成"，判据是
`std.testing.allocator` 的泄漏检测 + `!ran_while_locked`；绿：`BufferPool` 8/8。

**`verifyToken` 在分配失败时会泄漏已经拷好的字段（OOM 扫描抓出）。** 上一批有个 agent 把这条列为
"读代码的推测、**没有实测**"，并因为担心它而没敢做全量扫描 —— 这次做了，猜测**成立**：
```
verifyToken survives every allocation point failing (OOM scan)...
fail_index: 13/15   allocated 1086 / freed 1080
... SecurityModule.zig:254 in verifyToken    .iss = try self.allocator.dupe(u8, parsed.value.iss),
FAIL (MemoryLeakDetected)
```
两处成因：① `roles` 的逐个 `dupe` 循环用的是**循环结束后**才注册的 `errdefer` —— 中途失败时一个都
没释放（改成计数器 + 先注册）；② 返回的 struct literal 里 `.sub`/`.iss`/`.aud` 三个 `dupe` 是**从左到右**
求值的，`.iss` 失败会把已拷好的 `.sub` 悬在那里，而调用方**根本没收到**这个 payload、无从释放
（与之前 `Hpack` 那个 OOM 泄漏同形）—— 改为先具名拷贝、各挂一个 `errdefer`。
绿：`SecurityModule` 19/19；该扫描现在覆盖 `verifyToken` 的**每一个**分配点，下一个 agent 不会再撞到
同一堵墙。

> **本批未做（原计划的另一半）**：把全仓约 11 处 `mutex.lock(io) catch return …` 逐个判定
> （`im/ConnectionRegistry.zig`、`core/ModuleRuntime.zig`、`core/ClusterMembership.zig`、
> `scheduler/Cron.zig`、`ai/cooldown_store.zig`、`resilience/LoadShedder.zig`、`web4/challenge.zig`、
> `core/DistributedEventBus.zig`）—— 负责这一步的 agent 在写完 `BufferPool` 的用例后因网络故障中断，
> 其余站点**未被判定**（其中 `ConnectionRegistry` 的三处在上一批的清点里被列为"低影响"）。
> 同类待办还有：`sqlx` 的 `MySqlConn` 若干 `catch return null`（已文档化为"退回文本协议"）、
> `metrics/AutoInstrumentation.zig`、`runtime/scheduler.zig`、`api/Server.zig`、`OutboxConsumer.zig`
> 的若干低ranked站点。

### 第 16 批：认证路径把"我们这侧出错"答成 401（含一条静默半份身份）、API key 比较非恒定时间（实测 3560×）、MySQL 把 NULL metadata 读成"零行"、审计的一处前提被证伪（**破坏性：是**，1 处编译错）

全量 `-Ddb=all` **1827/1884（57 skipped，0 failed）**；MySQL 门控真机（含全量 `DB=mysql` 跑）全绿。

**认证路径：`verifyToken` 的失败不再一律 401。** 三处同形塌陷：`api.Middleware.jwtBackend` 的
`sec.verifyToken(token) catch return false`、旧路径 `verifyJwtLoadPermsAndNext`、`authFromCatalog`。
于是**分配失败**（我们这侧，本该 5xx）与**未知 kid**（配置错，本该被运维看见）都变成"token 无效"，
登录风暴在内存压力下看起来就是一片坏 token。红证据（回退一行即红）：
```
jwtBackend reports an unknown kid as a server error...expected error.UnknownKeyId, found false
jwtBackend verification allocation failure surfaces as an error...expected error.OutOfMemory, found false
```
新口径：token 级失败（`InvalidToken`/`InvalidSignature`/`TokenExpired`/…）→ 401 + debug；
**`UnknownKeyId` 仍 401**（`kid` 完全由客户端控制，映射成 5xx 等于让任何未认证调用者制造 5xx）但加
**warn**：`token names an unknown kid — keyring missing a rotated key?`；其余（OOM、自定义 backend 的存储
故障）→ **500**。`authFromCatalog` 的 `.public`/`.optional` 分支对我们这侧的失败改为 **fail-closed**
（以前记一条日志后继续，带着"有 user_id、没有 roles"的半份身份往下走 —— role gate 一律 403，
handler 眼里的"无角色"则未定义）。
> **破坏性**：`Middleware.attachIdentityBestEffort` 由 `void` 改成 `!void`（先把 roles CSV 建好再写任何
> 属性，任一写失败即 `return err`）。仓库内只有本文件两处调用、未从 `http.zig` 再导出，但它是 `pub`。
> 红证据：`FAIL (SwallowedOutOfMemoryError)`（std 分配扫描器自己的诊断名 —— "注入了一次分配失败，
> 函数却照样返回成功"）。日志用 warn 而非 err 是刻意的：`scripts/test-runner.zig` 把任何 err 级日志判为
> 测试失败，且 warn 在默认生产日志级别下同样可见。

**API key 比较不是恒定时间（已改，并且做了实测）。** `ApiKeyAuth.validateKey` 用 `std.mem.eql`（首个
不同字节即返回），于是"猜对了多少字节"可以从耗时里读出来。红/绿都是**测量**：64 KiB key、两个只差一个
字节的错 key（byte 0 vs 最后一个字节），2000 次取中位数 ——
```
修复前:  diff@0 269000 ns / diff@last 957366000 ns   （比值 ≈ 3560×，对照组 mem.eql 同量级）
修复后:  diff@0 317212000 ns / diff@last 314665000 ns（差 0.8%，持平）
```
改为逐字节恒定时间比较（复刻 CSRF 用的那份形状）并去掉提前返回（比较次数也不依赖命中的槽位）。
> **未验证**：以上是 **Debug** 构建（本套件自身的构建），ReleaseFast 未测；优化构建下 `mem.eql` 会在
> 第一个不同的向量块处返回，泄漏最多缩小到块粒度、不会消失 —— 这是推理，不是测量。
> 另记录未改：`ApiKeyLoaderConfig.loader` 的类型是 `*const fn ([]const u8) bool`，**存储故障与"key 不存在"
> 完全同形**，客户端只会拿到 401。建议改成 `anyerror!bool`（与已是 fallible 的 `PermissionLoader` 对齐），
> 但那是公开 API 字段的破坏性变更，留给能承担它的窗口；当前缓解是文档要求 loader 自己 fail-closed 并
> 旁路上报。

**旧 JWT 中间件：我们这侧的失败从 401 变 500。** `src/security/AuthMiddleware.zig` 的
`verifyToken(...) catch { 401 }` 同形。红证据：`expected 500, found 401`（造法：先签一个合法未过期 token，
再把 `sec.allocator` 换成永不成功的失败分配器 —— 失败不可能是 token 的属性）。改成按错误名分类：token
级 → 401（消息原样），其余 → warn + 500。
> **未验证**：`InvalidEncoding`/`InvalidPadding`/`InvalidCharacter` 三个**无法再分** —— header 段（签名
> 校验前，客户端数据）与 payload 段（校验后，我们自己签坏）产生同名错误，注释里写明了这一点；
> `verifyToken` 的推断错误集共 22 个（用一次性探针打印后删除）。分配失败只钉了 `fail_index = 0`，没做
> 全量扫描：`SecurityModule.verifyToken` 拷贝 payload 那段（`sub`/`iss`/`aud` 的 dupe）没有 `errdefer`，
> 全量扫描会撞到本文件管不到的路径 —— **这一点没有实测，是读代码的推测**。

**审计的一条前提被证伪（记下来，因为"没修"也是结论）。** 上一轮清点说
`src/core/cluster/TlsTransport.zig` 的 `sign(payload) catch return false` 会把我们的 OOM 说成"对端签名
伪造"。实测**不成立**：`sign` 的 HMAC 与 hex 全算在栈数组上，**没有任何分配器**，所以那个 `catch` 是
**死代码**。钉子测试（打开失败分配器后 `verify` 仍返回真值、`allocations` 计数不变）在未改动的源码上
就是绿的 —— 即"修改前没有可红的测试"。为了仍然把危害形状固定下来，做了一次**单点 mutation**（给
`verify` 加一次分配 + 用旧的 `catch return false` 上报）→ 立刻红：
`try std.testing.expect(auth.verify("payload", &sig))` 失败，即"我们的分配失败 → 合法对端被判为伪造"。
mutation 已还原；改法是最小且诚实的：抽出 `hexTag`，让 `verify` 整条路径**没有**错误通道，并在注释里
写明 `false` 在真实入站路径上意味着什么（`RaftTransport.verifiedRecv` → `error.ClusterAuthFailed` →
调用方**静默丢弃该对端**，不重试、不记日志）。`sign` 的签名未变（`RaftTransport.zig:1153` 的 `try`
不受影响）；去掉它那个空错误集的 `!` 列为后续项。

**`BufferPool`：`release`/`available`/`stats` 不再可被取消。** 红证据一条给出三件事：
```
release keeps the buffer when its lock wait is canceled...FAIL (PoolExhausted)
[SafeAllocator] (err): leaked [len: 4096]   ← 被取消的 release 丢掉一个 4 KiB 缓冲区
available and stats report the true state when a lock wait is canceled...expected 1, found 0
```
即：取消丢缓冲区 → `allocated` 永久虚高 → 以后 `acquire` 报**假** `PoolExhausted`，而读侧给出伪造读数
（会被 scrape/健康检查当成事实）。改 `lockUncancelable`（本仓 `Pool.release` 早为同一问题做过同样选择），
`acquire` 仍传播 `error.Canceled`（等待缓冲区正是取消有意义的地方，且它有错误通道）。
> **未改并记录**：`BufferPool.deinit` 仍用 `tryLock`，失败时**不持锁**就 free 空闲表 —— 与并发
> `release`（现在会不可取消地等这把锁）之间存在竞态；全仓还有约 11 处
> `mutex.lock(io) catch return …` 未逐个判定是缺陷还是有意语义。
> 另：`PoolExhausted` 现在仍可能因**池子无法区分**的原因上报（调用方交回 sub-slice、或干脆不 release），
> 注释里写明了。

**MySQL：`mysql_stmt_result_metadata` 返回 NULL 不再被读成"零行"（真机端到端红证据）。**
这条以前被注释解释为"`field_count > 0` 后应该很罕见"，而 NULL 被当成空结果集 —— 调用方看到"没有行"
而不是错误。用 **C 探针**先在真机上确定语义：NULL ⟺ `field_count == 0`（errno=0），
`stmt_reset`/`store_result`/`free_result` 后再取仍非 NULL；再反汇编实际链接的 `libmysqlclient.24`，
该函数只有两条 NULL 路径：`field_count == 0`（直接返回、不设 errno）与描述符 `my_malloc` 失败时的
`errno 2008`（CR_OUT_OF_MEMORY）。为了在线缆上拿到红，用 **DYLD 符号拦截**强制返回 NULL：
```
168/1758 sqlx.sqlx.test.mysql live connection...expected 1, found 0
FAIL (TestExpectedEqual)   ← 服务器返回 1 行，驱动报 0 行，且没有任何错误
```
现在：`field_count == 0` → 仍按空结果集（debug 日志，这就是所测量的子情形）；否则打印
`field_count/errno/msg` 为 err 并返回映射后的错误，不再返回空行集。
> **未验证**：那条错误分支**没有 CI 可跑的回归测试** —— 仓库没有可注入该故障的缝，而我没有往驱动里加
> 测试钩子（能进 CI 的只有判决函数单测与"空结果集"这条保留子情形）。本机链的是
> `/opt/homebrew/opt/mysql/lib/libmysqlclient.24`（**不是**注释里假设的 libmariadb），所以针对
> mariadb 构建的拦截器会被静默忽略 —— 这一点也写进了注释。

**`mysqlParseJson` 的解析器 OOM 不再折成 `error.InvalidFormat`**（红：`expected error.OutOfMemory,
found error.InvalidFormat`）。该文件里最后一处这类塌陷；`CachedConn.decodeCached` 早先已按同一口径修好，
本次以它为模板。该函数此前只有测试调用（全部 `try`）。

### 第 15 批：授权路径在 OOM 下 fail-open（真红，含一处越界写）、口令校验把"我们这侧出错"答成"口令错"（**破坏性：是**，1 处编译错）、另有 10 处"失败被当成成功值"（**破坏性：否**）

全量 `-Ddb=all` **1815/1871（56 skipped，0 failed）**。

**数据权限在分配失败时 fail-open —— 这是本批最严重的一条。** `DataPermission.buildWhere` 的
`.dept_only` / `.dept_and_child` / `.self_` 三个**限制性**作用域把 SQL 片段的分配写成
`catch return null`，而 `null` 在本模块的文档与既有用例里**只**表示 `.all`（不限）。于是内存紧张时
**限制条件整条消失**，调用方（`examples/zmsaas/backend/src/shard.zig` 的 `if (filter) |f|`）把范围查询
变成全表查询。红证据（`FailingAllocator(fail_index = 0)` + 与真实调用方逐字相同的拼接）：
```
RED self_:          filter=null => UNRESTRICTED  rows_returned=2 (table has 2 rows, 1 belongs to the user)
RED dept_only:      filter=null => UNRESTRICTED  rows_returned=2
RED dept_and_child: filter=null => UNRESTRICTED  rows_returned=2
```
修法：**fail closed**（复用文件里 `.dept_custom` 已有的 `reject`，即 `"1 = 0"` + 空参数），而不是改签名
—— `null` 继续只表示 `.all`，调用方的拼接逻辑无论怎么写都丢不掉限制；`.all` 与正常路径未变。
> **顺带查出一处越界写（同一分支）**：`buildInClause` 往 `var buf: [256]u8` 里按运行期下标写入，而子句
> 长度随部门列表增长（`3*n + col.len + 4`）。红证据：`.dept_custom` 列表到第 82 个 id 时
> `panic: index out of bounds: index 256, len 256`（ReleaseFast 下是写穿栈帧）。改为按 `ids.len` 精确分配。
> 另记录未改：`.dept_and_child` 的实现与 `.dept_only` 完全相同（没有子孙展开），比名字更**宽松**但仍是
> fail-closed，改它是语义决定；`fromRoles` 依赖 `DataScope` 的整数顺序（重排会静默换作用域，方向是过度
> 限制）。

**口令校验：把"我们这侧出错"答成"口令错"，并关掉一处前缀比较（破坏性）。**
`PasswordEncoder.matches` 与 `SecurityModule.verifyPassword` 的 base64 解码写成 `catch return false`，
于是**存储哈希不可解码**或**解码时分配失败**都被答成"口令不匹配"——登录在内存压力下得到 401 而不是 500，
失败登录计数也是假的。红证据：`[REDREPRO] fail_index=0 matches(correct password) = false`、
`[REDREPRO] matches(valid password, un-decodable stored hash) = false`。
> **顺带找出一条真漏洞**：旧代码在长度检查后做 `expected_hash[0..32]`，是**前缀比较** ——
> "32 字节真实摘要 + 1 字节垃圾"的存储记录会被**判定通过**（实测 `[PRE-FIX] 33-byte digest (32 real +
> 1 garbage byte) accepted = true`）。现在摘要长度必须**恰好**等于派生 key 长度。
> **Breaking?** 是（编译错）：两个函数改为返回 `PasswordError!bool`
> （`error{MalformedStoredHash} || std.mem.Allocator.Error`），调用点必须 `try`/`catch`。仓库内
> **没有**调用方（只有本文件测试），但**消费者 App 的登录 handler 必须改**，见
> [`docs/UPGRADING.md`](docs/UPGRADING.md) §v0.33.4 的一行改法。`SecurityModule.verifyPassword` 另外
> 改为**解码后比较字节**（不再"把派生 key 重新 base64 再比字符串"），于是那次分配整个消失、校验算法
> 字段也不再被忽略。常量时间比较未改（仍是 `timingSafeSliceEql` 比字节）——**但没有做时序测量**，
> 只能说实现没被削弱。

**另外 10 处"失败被当成一个看起来正常的值"（都不改签名）。**
- **`src/core/ClusterMembership.zig` 的 use-after-free（红：`UUUUUU` = `free` 写入的 undefined 填充）**：
  `.leader_election` 与 `electLeaderLocked` 都是**先 free 旧 leader、再 dupe 新的**，`dupe` 失败时字段仍
  指向已释放内存，之后每次读（`getLeader`/回调/比较/`deinit`）都是 UAF，并伴随
  `panic: double free`（`ClusterMembership.zig:349` 与 `:111` 两处 free）。改为**先 dupe 再 free**，
  失败则保留旧 leader 并 warn（写入侧是 `onBusEvent` 的 `void` 回调、`electLeader` 全链 `void`，没有错误
  通道；`false` 本来就表示"不广播"，改成错误无法区分。**这是缓解而非传播**，理由写在代码里）。
- **`src/core/cluster/LoadBalancer.zig` 的 invalid free（红：`double free` / `Bus error` on `.rodata`）**：
  `recordResult` 先把调用方的**借用** `peer_key` 放进 map，再用 `dupe` 换成自有副本，`dupe` 失败即
  `catch return` —— map 里留下借用切片（多数是临时值），`deinit` 去 free 它。改为 `!void` 并在插入前
  先取自有副本，失败则释放副本并返回错误（计数因此不会与 map 内容不一致）。仓库内只有本文件测试调用它。
- **`src/redis/redis.zig`：基础设施故障被答成数据（7 处）**。`setNX`/`lock` 返回 `false`（读作"别人先占"）、
  `del` 返回 `0`（"一个都没删"）、`exists` 返回 `false`、`ttl` 返回 `-1`（**"键存在且永不过期"**，最锋利）、
  `unlock` 静默返回（"锁已释放"）。`errors.ResultT(T)` 就是 `Error!T`，所以**返回一个值等于成功**。
  红证据（离线 client，`acquireStream` 在任何 socket 之前失败）：
  `expected error.RedisError, found -1` / `expected error.RedisError, found false`。
  改为 `try`，并**保留**服务端真实回答的语义（真 `-1`、真 `false`、真 `nil` 仍是值），非预期回复/解析失败
  一律报错。**行为变化**：调用方（`RedisRateLimiter`、`RedisCooldownStore` 等）在 Redis 不可达时会**抛错**
  而不是静默拿到 `0`/`false`。
  > 顺带：`hSet` **从未被任何代码调用过**，所以在惰性分析下这一行从未编译 ——
  > `error: expected type 'error{...}!bool', found 'comptime_int'`。又一个"只导出、没调用者"的陷阱实例。
- **表单解析：客户端错与服务端错被塌成一个 `null`（H1 + H2 两个调用点）**。`parseFormBody` 的
  `error.TooManyParams`（客户端字段超限 → 该 400）与分配失败（我们这侧 → 该 500）都被
  `catch null` 读成"没有表单体"。红证据（同一请求两种协议）：
  `expected: HTTP/1.1 400 Bad Request / found: HTTP/1.1 200 OK`、
  `h2 adapter parity: the form parser takes Server.Config.max_params too...expected 400, found 200`。
  现在新增 `parseUrlencodedForm`（`.absent` / `.parsed` / `.refused{status, message}`）与
  `paramParseFailureStatus`，两条协议各自按类别回 400 或 500；**顺带**把请求边界的同一个塌陷也分开
  （查询串解析的分配失败以前回 400，现在 500；字段洪泛仍 400）。
- **`src/http/Params.zig` 的 double free（红：`panic: double free`）**：`putOwned` 在插入失败时
  **释放调用方拥有的内存**，而它自己的文档注释写着"出错时调用方仍拥有它们"，两个请求解析器正是按该契约
  写的清理。`put` 是反过来的同一问题（自己那份名字被 `errdefer` 与显式 free 释放两次）。两处都改为
  **只在插入成功后**释放多余副本，契约未变。
- **`src/messaging/OutboxConsumer.zig` 的静默停摆**：`parseEntry(row) catch continue` —— 无日志、无计数、
  无死信、**且不标记该行**，于是每次 poll 都重新选中它，队列永远不排空、什么都不投递。红证据（列名大小写
  不匹配的声明列，`sqlite3_column_name` 报的是声明名，`Row.get` 大小写敏感 → 每行 `MissingColumn`）：
  `after 2 polls: pending=1 selected=0/0 delivered=0 failed=0`。现在**死信化**：`status = 3` +
  `error_message` + 一条 warn + 计入既有 `outbox_failed_total`，复用**已有**的
  `OutboxPublisher.buildResubmit`（`status = 3 → 0`）恢复，没有引入新表或新子系统。
- **`src/http/HttpClient.zig` 的连接池**：`release` 取不到池锁时 `catch return` → 连接既不入 idle 也不关闭、
  `active_connections` 里永远留着（池静默缩水）；`discard` 同形；`acquire` 在 append 失败时已 `swapRemove`
  掉 idle 项 → **整条连接丢失**（红：`leaked [len: 9]`，正是 host 字符串）；`release` 往 idle 追加失败时
  只 debug 后丢掉（socket 不关、host 不 free，注释还错说"与死连接分支结果相同"）。前两处改用
  `lockUncancelable`（本文件 `deinit`/`https_mutex` 早已如此，同仓 `Pool.zig` 也修过同一 bug），后两处
  把不可逆的移除放在可失败的分配之后 / 失败时关闭并释放。
- **`src/im/BufferPool.zig`：把取消说成 `error.OutOfMemory`**（红：`expected error.Canceled, found
  error.OutOfMemory`）。`std.Io.Mutex.lock` 是 `std.Io.Cancelable`，如实传播 `error.Canceled`。
- **`src/sqlx/sqlx.zig` `CachedConn`：缓存解码把"缓存的 JSON 坏了"与"我们分配失败"一起报成
  `error.DatabaseError`**（4 处；红证据的栈显示失败发生在解析器内部的
  `allocator.create(ArenaAllocator)`，不是解析判定）。现在**坏条目 = cache miss**（穿到查询并在同一次调用里
  由 `setCache` 修复，与序列化侧既有的 fail-open 对齐），**分配失败 = `error.OutOfMemory`** 冒泡。
  `CachedConn` 是公开类型，按 `DatabaseError` 分支的消费者需知。
- **`src/core/DistributedLock.zig`：release 在分配失败时静默不释放**（红：A 释放后 B 仍拿不到锁，
  没有日志，只有 TTL 兜底）。`allocPrint(...) catch return` 换成栈上 `bufPrint`（表名上限 64 是
  `init` 已保证的），错误路径**从"降级"变成"不存在"**，签名不变。
- 另记录：`src/sqlx/sqlx.zig` 的 sqlite **BLOB 列**（唯一未解码的类型）以前静默读成 SQL NULL，现在
  **每种类型每个进程 warn 一次**（值通道仍是 `null`，因为把 BLOB 当字符串解码会按第一个 NUL 截断、
  而 BLOB 的 C 绑定不在可改范围内；直接报错会让任何 `SELECT *` 到该列的查询失败，包括从不读它的调用方）；
  MySQL 预处理路径的 4 处 `catch return null`（把 OOM 折成"退回文本协议"）改为
  `switch (err) { error.OutOfMemory => return err, else => return null }`（红：
  `expected error.OutOfMemory, found .{ .arena = …, .rows = … }`）。

> **本批未做（已记录）**：`src/api/Middleware.zig:815` 的 `jwtBackend` 与
> `src/security/AuthMiddleware.zig` 把 `verifyToken` 的 OOM/`UnknownKeyId` 一起答成 401；
> `src/core/cluster/TlsTransport.zig:83` 的 `sign catch return false`；`ApiKeyAuth.validateKey` 用
> `std.mem.eql`（**非恒定时间**）且 loader 契约 `fn ([]const u8) bool` 没有错误通道；
> `src/sqlx/sqlx.zig` 的 `mysqlParseJson` 把解析器 OOM 折成 `InvalidFormat`；
> `BufferPool.release`/`available`/`stats` 与 `ConnectionPool.acquire` 的取消处理；
> `Middleware.zig:403` 的 `joinCsv` 失败会留下**没有 roles 的身份**。

## [0.33.3] - 2026-09-24

### 第 14 批：H2 上 gRPC 路由的 `HEAD` 仍会发 DATA 帧（真红）、sqlite 把 OOM 与 SQL NULL 混成一个 `null` 并顺带修掉一个真泄漏（**破坏性：否**）

全量 `-Ddb=all` **1783/1836（53 skipped，0 failed）**。

**H2 上走 gRPC 路由的 `HEAD` 仍会发出 DATA 帧 —— 已修。** 上一批给 H2 加了 `no_body`（HEAD 不发 body）
并在 site 编码器上生效，但 **gRPC 的四个形状在 `buildStreamResponseWire` 里早于那个判定就 return 了**，
`st.content_type` 又来自请求头，于是 `HEAD` + `content-type: application/grpc` 会拿到一个 5 字节 DATA
（空 gRPC 消息 `00 00 00 00 00`）—— 字段段本身是对的（头段 200 + `application/grpc`、trailer 段有
`grpc-status`），错的只是八位组。红证据：
```
[default] (warn): [TEMP] HEAD gRPC DATA frame: 5 bytes { 0, 0, 0, 0, 0 }
expected 0, found 1
```
修法：四个 gRPC 形状不再各自 `return wire`，而是汇进一个 `grpc_wire`，统一经
`grpcWireWithoutBody(allocator, wire, no_body)` 出去（**非 HEAD 逐字节不变**：该函数对非 `no_body` 原样
返回入参）；`maybeStartLiveBidi` 对 `HEAD` 提前返回 —— 那是唯一在 `buildStreamResponseWire` **之外**写
DATA 的 gRPC 形状（handler 边刷边写）。**决定写进注释**：`HEAD` 保留 gRPC handler 的调用与字段段、
只丢掉 DATA；丢掉 DATA 之后剩下的"trailers-only"（`grpc-status`/`grpc-message` 在 trailer 段、没有消息）
**本身就是 gRPC 合法的错误/空应答**，所以不需要编造状态；而"不看 registry、直接 `and !no_body`"正是
这条要避开的陷阱 —— 那会让 gRPC 分支落到 site handler，给一个**存在的**路由回内置 404。
> **未验证**：`maybeStartLiveBidi` 的 HEAD 守卫只有推理（仓库里没有 H2 上的 bidi pump socket 用例，
> 两个 bidi 用例都是 registry 级的）；四个形状里只有 unary 端到端跑过 h2c；"trailers-only 合法"依据的是
> gRPC 规范，**没有真 gRPC 客户端**验证过（用例里的客户端是个读帧的 HTTP/2 客户端）。
> 非 HEAD 的 gRPC 路径已按原有测试复核：`--filter "rpc"` 18/18、`--filter "bidi"` 2/2、`--filter "h2 server"`
> 8/8、`--filter "h2c upgrade"` 9/9、`--filter "h2 adapter parity"` 7/7。

**sqlite 的 `readSQLiteValue` 把"分配失败"与"SQL NULL"混成同一个 `null` —— 已修。** 这比"错误名撒谎"
更糟：调用方拿到的是**错值**（一个普通的 NULL 单元混在完好的一行里），**没有任何错误、没有任何日志**。
红证据（SafeAllocator 的 1 字节泄漏栈直指那一行）：
```
RED: readSQLiteValue returned a NULL cell after its text copy failed to allocate
FAIL (TextCellAllocationFailureReportedAsSQLNull)
[SafeAllocator] (err): leaked [len: 1] allocated at: …/sqlx.zig:1706:55 in readSQLiteValue
    break :blk Value{ .string = allocator.dupe(u8, text) catch return null };
```
改为 `!?Value`（**与 `pgReadCell` 同形**），文本单元用 `try`；文档注释写明 `null` **只**表示 SQL NULL
或未解码的列类型、**绝不**表示分配失败。两个调用点（`SQLiteConn.queryFn`、`SQLiteStmt.queryFn`）加
`try` —— 它们本来就返回 `errors.ResultT(Rows)` 且错误集含 `OutOfMemory`，所以**没有涟漪**。
> **顺带修掉一个真泄漏**（新写的扫描用例发现的）：`SQLiteConn.getCachedStmt` 里 `stmt_cache.put` 分配
> 失败时，缓存键与预处理语句**都漏了**（34 字节 `CREATE TABLE` 键）；现在释放键、finalize 语句再返回
> 错误，与 MySQL 驱动的同一路径一致。
> 两条新用例：① 直接驱动那个接缝（真 SQL NULL 仍是 `null`、文本单元复制成功是 `"x"`、复制失败是
> `error.OutOfMemory` —— 两侧都钉住）；② 公共路径扫描，**每个索引用一个全新分配器**（失败的那次分配
> 不会被计数，共享计数器会漂移 —— `std.testing.checkAllAllocationFailures` 就是这个形状），且单元故意
> 用 4096 字节：短文本会由行缓冲已有的 arena 节点直接满足、**根本碰不到注入的分配器**（实测过一个变体）。
> **未验证**：没有真机 PG/MySQL 参与（sqlite 走嵌入式 `:memory:`，是真实驱动路径）；`else => null`
> 分支（未解码的列类型，如 BLOB）仍会静默变成 SQL NULL —— 那是另一类混淆（不涉及分配），注释里点名了
> 它以免被误当成这个 OOM 情形。

### 第 13 批：PG `?*PGresult` 的 null 语义收敛（上一批只给了评估、这次真做）、一个进程两个 server 的全局状态彻底按实例隔离（**破坏性：否**，公开签名未动）

全量 `-Ddb=all` **1780/1833（53 skipped，0 failed）**；PG 门控真机 `allocation` 组 38 passed / 9 skipped，
MySQL 门控真机 33 passed / 13 skipped（均 0 failed）。三个调用 `openApiFromCatalog` 的示例
（`tenant-mgmt` / `tenant-shop` / `zent-modulith`）本机 `zig build` 通过。

**PG 的 `?*PGresult` 里，`null` 同时表示"分配失败"和"驱动失败" —— 已收敛。** 上一批只给出了评估并
**明确没有开始**（怕把真驱动错误吞成 OOM），这批做完并**更正了那份评估的两处事实**：
- 调用点不是"约 22 个外部"：`execPrepared → execParamsDirect` 是 **7** 个、`→ execPreparedStmt` 是 **5**
  个（合计 12 个内部），外部只有 **2** 个（`queryFn`、`execFn`；流式游标与 `copyFrom` 不走这两个）。
- **`convertPlaceholders` 从来不用 `null` 表示"无需转换"** —— `count == 0` 时它返回的是一份 `allocZ`
  副本，那里的 `null` 本来就只表示分配失败。真正的"三方纠缠"在**调用方**的读法里
  （`orelse return execParamsDirect(...)` / `orelse return error.DatabaseError`）。
- 评估还**漏了两个 PG 口袋**：`queryCursorFn` 把 `convertPlaceholders` 的 OOM 映射成 `DatabaseError`；
  以及 **`PostgresStmt.execParamsPrepared` 是同一个缺陷的结构复制**（5 处 arena `catch return null`
  与 `conn == null`、`PQexecPrepared` 返回 null 混在一起）。所以"PG 侧最后一个大口袋"这句是错的，
  这次一并修掉。

改法：`execPrepared` / `execParamsDirect` / `execPreparedStmt` / `execParamsPrepared` 改为
`errors.ResultT(?*libpq_c.PGresult)`，`convertPlaceholders` 改为 `errors.ResultT(?[:0]u8)` 且
**`null` 只表示"没有需要改写的内容"**；所有分配点一律 `try`。规则写进文档注释：**`null` 只表示"驱动
没有交回 `PGresult`"**。红证据（真机 PG）：
```
... postgres query walk reports connection-side allocation failures as OutOfMemory...
  expected error.OutOfMemory, found error.DatabaseError   (queryFn / execFn 各一条)
```
新增 8 条用例、全部在真机 PG 17.10 上跑（query walk / exec walk / 无参查询 / 缓存语句复执行 /
驱动失败是"有结果"而非 null / 绑定参数 walk / 预处理绑定 walk / `convertPlaceholders` OOM）。
> **行为变化**：OOM 下 PG 查询现在报 `error.OutOfMemory`（以前是 `DatabaseError`）；缓存键或缓存插入
> 分配失败时**不再**回退到"未缓存路径"再执行一次（旧行为会带着一个失效的缓存名继续跑）。公开签名
> 一个没动。
> **未验证**：`execPreparedStmt` 的**缓存命中**路径只有代码级红（那轮 filter 没选中它）；
> `execParamsDirect` 的绑定参数数组与 `convertPlaceholders` 只有**签名级**红 —— 旧签名下那些直接调用
> 的测试根编译不过，所以不存在运行时红证据。另：`PostgresStmt.prepare` 不经过 `convertPlaceholders`，
> 所以走 `PostgresStmt` 的用户必须自己写 `$N`（新用例因此用 `$1::int`）。

**一个进程里两个 server 的全局状态：`OpenApiRouteStore` 与 `catalogLoaderFromTable` 都改成按实例隔离。**
上一批的结论是"权限门（gate）本身正确，但旁边有两块**真**的进程级状态，且都未改"—— 这批改掉：
- **`OpenApiRouteStore`（文档端点）**：单份 store → 按 **`*CatalogSlot` 去重**的绑定槽（上限 16），每个槽
  有自己的函数指针；同一 slot 再注册只更新该 app 的 config（"重复注册覆盖"这个行为只对同一个 app 保留）。
  红证据：**shop 的 `/openapi.json` 里出现了 `"Admin App"`**（后注册的 admin 覆盖了唯一那份 store，
  文档本身仍是合法 JSON，所以没有任何东西报错）。
- **`catalogLoaderFromTable`（执法路径）**：模块级 `Holder.tbl` → 按 **`RolePermissionTable` 指针去重**
  的 trampoline 槽池（上限 64）。红证据（同一个 reader token，A 表授 `report:read`、B 表授
  `report:audit`）：第二个 loader 把**第一个 app 的 loader** 也重定向到了 B 表，A 按一张它自己从未声明的
  表执法 → **`expected 200, found 403`**。
- **两次变异各只打红对应的那一个用例**（证明归因是测出来的）：① `claimOpenApiBinding` 的
  `if (existing.catalog_slot == slot)` 改成恒真（回到"一份进程级 store、后写覆盖"）→ 只有 openapi 那条红；
  ② 把 `catalogLoaderFromTable` 换回单槽（= 模块级 Holder）→ 只有 loader 那条红（`expected 200, found 403`）。
  既有那条 `one process, two servers: each gate enforces its own catalog` 在红/绿/变异三种运行里始终 OK，
  **没有被削弱**（只改了一处已失效的注释措辞）。
- **代价（有意接受并记录）**：`CatalogPermissionLoader` 与 `HandlerFn` 都是**裸函数指针**、`Context` 里
  也没有 app 身份，所以共享 handler 在请求期无法自证属于哪个 app；在不动这些公开类型的前提下，per-instance
  状态只能用"一个槽一个专属函数指针"实现 —— 于是有了**固定且不回收的槽预算**（表 loader 64、OpenAPI 16），
  **接线期**领取，耗尽即 panic（panic 文本直接告诉你抬高哪个常量）。去重的语义边界是：同一张表指针 / 同一个
  slot 的两个 app **有意**共享这份状态（与它们共享表/目录的事实一致）。
- **未验证**：槽耗尽与 `error.LoaderSlotEmpty` 两条错误路径没有用例（fail-closed 的 503/500 语义未动）；
  `examples/**`、`tools/zmodu`、`scripts/ci-integration.sh` 没有整跑（本机单独 build 了三个用
  `openApiFromCatalog` 的示例，通过；`tools/zmodu` 生成代码里的签名未变）。

### 第 12 批：夜间 soak 在 Linux 上编译不过（已修）、SSE 不再给 HEAD 写事件、sqlx OOM 误标第二批并修掉一个真泄漏（**破坏性：否**）

全量 `-Ddb=all` **1777/1823（46 skipped，0 failed）**；MySQL 门控真机 `allocation failure` 组 18 passed /
6 skipped、`mysql` 组 25 passed / 2 skipped，PG 门控真机 15 passed / 9 skipped（均 0 failed）。

**夜间 soak 在 CI 上是红的，而且已经红了一段时间 —— 它在 Linux 上根本编译不过。** 排程跑
（run `35975588517`，commit `1bf35c4`）的 `Nightly soak` job 失败于：
```
src/soak_cluster.zig:645:47: error: no field named 'd_name' in struct 'os.linux.dirent64'
```
`linuxFdCount()` 里读的是 `dirent64.d_name` / `d_reclen`，而本工具链的
`std.os.linux.dirent64` 字段是 `name` / `reclen`。**为什么一直没被发现**：push 触发的 run 会把
`Nightly soak` 标成 skipped（只有排程跑才真跑），而 macOS 上 `builtin.os.tag == .linux` 的分支被
comptime 剪掉、函数体不做惰性分析 —— 于是这条错误只在 Linux + 排程跑的组合里出现。
修法：`ent.name` / `ent.reclen`。绿证据：`zig build soak-cluster -Dtarget=x86_64-linux -Ddb=none`
现在能编译通过（只剩 "host cannot execute binaries from the target"，即编译成功、无法运行）。

**SSE 不再给 `HEAD` 写事件字节（上一批记录的空缺，已闭环）。** 先做可达性判定：`sse_routes` 只按
`group.get(...)` 注册（`ComptimeRouter.zig:724`），而路由表按**精确方法**查（`Server.zig:1935`，全框架
没有 HEAD→GET 回退），所以 HEAD 打到只注册 GET 的 SSE 路径会落进 404 分支、而 404 已经 HEAD 安全；
但**文档里的第二种 SSE 声明形式**（普通 `routes` 行 + `meta = .{ .sse = true }`，见
`docs/ROUTE_TABLE.md:293`）可以用**任意方法**注册，把同一个 handler 同时挂 `get` 与 `head` 就可达 ——
实测修复前 HEAD 的响应里带着 `event: tick\ndata: 1\n\n`。红证据：
`expected: "" / found: "event: tick"`。修法：`SseWriter` 新增 `head_request`（`init` 时由
`isHeadRequest(ctx)` 判定，带 `@hasField` 守卫），六个写路径
（`sendEvent`/`sendData`/`sendMultiLine`/`sendRetry`/`sendComment`/`heartbeat`）各自提前返回；`init`
仍照发完整字段段（`Content-Type: text/event-stream` 等），所以 HEAD 的字段段与 GET 一致。
用例是真 socket 三段：GET 基线（钉住 GET 的逐字节框架）、带 `Connection: close` 的 HEAD（字段段 +
body 为空）、以及**同一条连接上 HEAD 与 GET 流水线**（HEAD 的响应必须停在字段段、下一个请求必须被完整
应答）。**变异检查**：只去掉 `heartbeat` 那一处守卫，用例立刻在 `expectEqualStrings("", …)` 变红。
> 有意留下的决定：`event_count` 只在事件真正上线时才增长，所以 HEAD 下它不动 —— 如果有 handler 用
> `while (writer.event_count < n)` 做循环条件，它会空转。这是"最小改动、不发明计数器语义"的选择，**已
> 记录为可复议项**。另外，一个"永远 sendEvent"的长命 SSE handler 在 HEAD 下会静默丢写并继续持有
> fiber/连接（与 `Context.writeChunk` 对 HEAD 的处理同形，不是本次引入，也未修）。SSE 不响应
> HEAD→GET 回退（HEAD 打只注册 GET 的路径仍是 404）；H2 上 SSE 本来就 fail-closed（`error.NoStream`）。
> `markSseResponse` 在客户端要求 close 时仍发 `Connection: keep-alive`（既有，未动）。

**sqlx OOM 误标清扫第二批（MySQL 语句族 + PG 流式/批量），并修掉一个真泄漏。**
改为 `try` 的站点：MySQL 语句族的列值回取与 dupe、`shared_columns`/`binds`/`null_flags`/`lengths`/
`err_flags`/`bind_bufs`/`is_unsigned_flags`/`col_types` 八个 arena 分配、列名 dupe、每行 `?Value` 数组、
`rows_list.append` 与 `rows_slice`、`prepareFn` 的 `MySqlStmt` 分配、流式游标的列数组与列名、
`batchInsertPrepared` 的 bind；PG 流式 `queryCursorFn` 的 `allocZ`/参数数组/`allocPrint`/`dupe`/列数组、
以及 `copyFrom` 的 `allocZ`。`getCachedStmt` 的两处保留 `mysql_stmt_close(stmt)` 清理后按 err 返回
（换裸 `try` 会漏句柄）。真驱动错误（`mysql_stmt_prepare`/`execute`、`PQsendQueryParams == 0`、各 PQ
状态、`validateIdentifier`）**保持不动**。
> **修掉的真 bug（不是这个缺陷类）**：`mysqlStmtReadRows` 按**值**收 `ArenaAllocator`，于是行缓冲的
> 节点记在**副本**里，而调用方 `errdefer arena.deinit()` 释放的是空链表 —— 在
> `std.testing.allocator` 下报 3 处泄漏（`allocated at sqlx.zig:3313/3314 in mysqlStmtReadRows`）。
> 改成按指针传（两个调用点）。
> 红证据统一为 `expected error.OutOfMemory, found error.DatabaseError`（在临时副本里逐处还原出红后
> 复原）；真机验证：MySQL 9.3.0 上 5 条（语句行扫描 / 预处理单元 / 语句缓存 / 流式列 / 批量插入），
> PG 17.10 上 2 条（流式游标 / `copyFrom`）。
> **未做并给出评估**：`execPrepared` / `execParamsDirect` / `execPreparedStmt` 的契约是 `?*PGresult`，
> **null 同时表示"分配失败"与"驱动失败"**（约 22 个调用点，涟漪收在 `PostgresConn` 内但不机械，
> 还有 `convertPlaceholders` 用 null 表示"无需转换"三方纠缠）—— 本批**没有开始**，因为判错任一处就会
> 把真驱动错误吞成 OOM。`convertPlaceholders` 的 3 个 `orelse` 调用点因此**仍会误标**。
> 另：`batchInsertPrepared` 的 bind 失败现在会透出细分错误（如约束冲突）而不是一律 `DatabaseError`
> —— 这是"更少隐藏"，但**该分支没有测试**。

### 第 11 批：CI 那条 macos 红是同一条测试测错了量；HEAD 收尾（流式与错误响应）；sqlx 的 OOM 误标清扫并带出一个真 bug（**破坏性：否**）

全量 `-Ddb=all` **1775/1814（39 skipped，0 failed）**；MySQL 门控真机 19 passed / 2 skipped，PG 门控真机
12 passed / 4 skipped（`allocation failure` 组）。

**CI 的 macos 红：公平性用例测的是"A 的绝对计数"，而它由池线程推进、测试线程只是采样。**
`Pooled (§12.3): an endlessly busy worker cannot starve a ready one` 断言 `a_when_b < 256`，其中
`a_when_b` 是 B 首次处理时读到的 A 的计数。但 A 是**自喂**且无界的（每次处理都给自己再发一条），计数由
**池线程**推进；测试线程只是在自旋里采样，它一旦被调度走，它看到的（以及被比较的）就已经是"这几万条"
之后的值 —— 于是这条断言测的是 **A 的绝对进度**，不是 **B 在 A 后面等了多久**。实测（本机 10 核、load
avg 15.5）：带 6 个忙循环 700 次 → **30 次失败**；空载 400 次 → **2 次失败**；而把两端都放在池线程上读的
增量 `a_when_b − a_after_send` 在**每一次**运行里都 ≤ **16（= 一个 batch）**，最大 16，p99 = 15 ——
**调度器的公平性界一次都没破**。失败值的拆解也印证：Σ(when−64) 里 97% 发生在 B 被发送**之前**，真正
"B 的等待"只占 2.6%。
修法（只改测试，`scheduler.zig` 一行未动）：A 的自喂改成 **1:1**（邮箱水位恒定、永远抽不干，"A 一直
忙"这个前提才成立），测试线程在 `b.send(1)` 之后置 `probe_sent`，A 在此之后跑的第一条消息记下
`ref_after_sent`，断言改为 `a_when_b −| ref_after_sent < 256`（饱和减覆盖"B 先被服务"的情形），并加了
一条**前提检查**：B 被服务之后 A 仍在继续跑（否则"B 没被饿死"可能只是因为 A 已经跑干）。
**两次变异证明新用例有牙**：`default_batch: 16 → 1_000_000` → `served_after=999932` 红；让忙 worker
插队 64 个 batch（等于取消公平性）→ `served_after=972` 红（两次都已还原）。修后 **1200 次带载 + 600 次
空载 0 失败**。
> 这条与第 8 批那条（等待谓词极性反了）是同一类病：**用例在测一个它其实控制不住的量**。两条都是只在
> 加载的 CI runner 上暴露，本地全绿。

**HEAD 收尾（上一批记录的三处空缺）。** ① **H1 流式路径不再给 HEAD 写 chunk**：`writeChunk` /
`endStream` 在 `method == .HEAD` 时直接返回（`startChunked` 的文档写明理由），字段段仍照发，所以 HEAD 的
应答与 GET 的字段段逐字节相同（`Transfer-Encoding: chunked` + `Content-Type`）而后面什么都不跟 ——
流的长度在最后一个 chunk 之前不可知，所以**不**编造 `Content-Length`，保留 GET 会带的
`Transfer-Encoding`（RFC 9112 §6.3：对 HEAD 的响应在第一个空行就结束，与定界字段无关）。红证据：
`expected: "" / found: 5`（body 是 `5\r\nalpha\r\n4\r\nbeta\r\n0\r\n\r\n`）。② **`writeErrorResponse`
服从 HEAD**：新增 `head_request` 参数与 `requestLineIsHead`（按请求行取方法 token，大小写敏感，
`HEADER`/`head` 不算），八个调用点分别传"能确定的方法"或 `false`（首行没到达 / accept 线程的 503 甩
负载根本没读过请求字节）；红证据：`expected: "" / found: {"error":"Bad Request"}`。③ H2 自带 404 的
`no_body` **本来就是对的**，这次只是补了用例（红跑里它就已经是 OK）。
> **仍缺**：accept 线程的 503 甩负载（方法在那一刻真的不可知，读一点就会毁掉这条路径存在的意义，**有意
> 保留**）；**SSE** —— `SseWriter` 直接把事件写进 `ctx.stream`，所以 HEAD 打到 SSE 路由仍会拿到事件字节
> （与 ① 同类，需要在 `Sse.zig` 里做同样的处理，不在本批范围）；**H2 + gRPC** —— `buildStreamResponseWire`
> 在 `no_body` 判定之前就返回 gRPC 的帧，所以 `HEAD` + `content-type: application/grpc` 仍会有 DATA
> （需要一个决定而不是一个 `and !no_body`，否则会静默变成 404）。

**sqlx 的 OOM 误标清扫（上一批只改了 MySQL 缓冲路径，这批扫其余）。** 把"分配失败被包成
`error.DatabaseError`"的站点逐处看过，改这些：sqlite 语句缓存键、sqlite 行扫描（`queryFn` 与
`SQLiteStmt.queryFn`）、sqlite `prepareFn` 的 stub 分配、**PG 缓冲行路径**（`PostgresConn.queryFn` 与
`PostgresStmt.queryFn`）、MySQL 的 `formatQuery` 三个调用点、`scanStruct` 的两处字符串复制、
`valueToType` 的 `[]const u8` 复制。PG 的 `PostgresStmt.prepare` **不能**直接 `try`：它推断出的错误集
含 `error.NoSpaceLeft`（来自它自己的 32 字节名字缓冲），按 err 分派保持对外错误集不变。每个改动点都有
一次性失败分配器的用例，红证据统一是 `expected error.OutOfMemory, found error.DatabaseError`
（在 `/tmp` 的临时副本里还原出红、已复原）；PG 与 MySQL 的用例分别在**真机**上跑过。
**顺带查出一个真 bug（不是这个缺陷类）**：`PostgresStmt.name` 声明成 `[]const u8`，但它由 `allocZ`
分配，`closeFn` 的 `free(self.name)` 因此交给分配器一个**长度少 1** 的切片 —— 在
`std.testing.allocator` 下直接 `panic: free of [...] mismatches allocation of [...]`（长度 14 vs 15）。
改成 `[:0]const u8`。
> **仍未清扫**（各自需要自己的用例，本批预算不够，**没有**做未经验证的批量替换）：PG 流式
> `queryCursorFn` 的分配点、PG `copyFrom`、MySQL `mysqlStmtReadRows` 一族、MySQL `MySqlStmt`、
> `mysqlBindParams` 的 catch。PG `execPrepared`/`execParamsDirect` 的契约是 `?*PGresult`（null 表示
> 失败），要正确标注 OOM 得改签名、牵动 `queryFn`/`execFn`/游标/`copyFrom`。
> 另：`validateIdentifier` 与 JSON `parseFromSlice` 的 catch 是**校验/解析失败**、`valueToType` 的
> `parseInt`/`parseFloat` 是**真值转换失败**，都不是分配失败，**有意不动**。

### 第 10 批：H1 会写出重复的 `Content-Length`（真红）、h2c 升级放开方法限制、HEAD 不再带 body、MySQL 缓冲路径把 OOM 误报成 `DatabaseError`、游标断线现在会上报 breaker（**破坏性：否**）

全量 `-Ddb=all` **1763/1795（32 skipped，0 failed）**；MySQL 门控真机 16 passed / 2 skipped / 0 failed，
PG 门控真机 1 passed / 3 skipped / 0 failed。

**H1 的 `Content-Length` 会被写两遍 —— 而且在 `HEAD` 上是自相矛盾的（真红，已修）。** 这是被
"检查 h2 侧故意丢弃不匹配的 `content-length` 时顺手回看 H1"发现的，而且**在真实路由上现场存在**：
`StaticFiles.zig:197` 会自己声明文件长度，于是 `GET /static/small.txt` 的响应里有两个
`Content-Length: 17`，`HEAD /static/big.bin` 则是 `Content-Length: 5120` **紧跟着** `Content-Length: 0`。
（既有测试没发现，因为它们只取第一个匹配。）重复的定界头是走私邻域的形状，不是排版问题。
红证据：`expected 1, found 2`（断言响应里该字段的条数）。
修法（`src/api/Server.zig:2098` + helper `:2173`）：**一个定界字段，在写 map 之前就定下来** ——
走 chunked（`Transfer-Encoding`，改为大小写不敏感）→ 两边都不写；`HEAD` → 用 handler 声明的合法值
（没有八位组会发出去，而 `StaticFiles` 依赖它）；其余情况 → handler 的值**只在它等于即将写出的字节数**
时保留（这正是 `assembleSiteResponseBlock` 在 H2 上已经执行的规则），否则用服务端自己算的。值必须是严格的
`1*DIGIT`，复用请求侧的 `parseContentLength` —— 第一版用了 `std.fmt.parseInt`，它把 `1_7` 读成 17，
于是自己先红了一条（`declaredLengthMatches`），已改。

**h2c 升级放开方法限制，并且 `HEAD` 不再发 body。** 上一批把升级请求按 stream 1 派发后，
`connFiber` 的升级分支仍只认 `GET`（RFC 7540 §3.2 对方法**没有**限制），于是 `POST` 升级根本进不来
（body 路径其实早就实现并有用例）。红证据（两条都被当成普通 H1 处理、**完全没有 101**）：
`h2c upgrade: a POST carrying a body is stream 1, and OPTIONS upgrades too` 与
`h2c upgrade: a HEAD request is answered with no body at all`。现在门只由 `server.enable_http2` 决定；
`fillUpgradeStream` 的 `end_stream = true` 保留并写明理由：H1 请求（含 body）在会话开始前已整个读完，
所以**无论什么方法** stream 1 都是半关闭 remote —— 写成条件反而会让 POST 升级挂住。
> **随之而来的行为变化**：`HEAD` 的响应体在 H1 与 H2 上都不再发送（红：`expected "" / found "eleven byte"`）。
> 这是修正而非回归，但确实是行为变化，且**尚未覆盖**：H1 的 `startChunked` 流式路径仍会写 chunk、
> `writeErrorResponse`（解析错误 / WS 握手失败 / 拒绝头 500 / 503 甩负载）仍会给 HEAD 写 body。

**MySQL 缓冲读把 arena 的 OOM 误报成 `DatabaseError`（已修）。** `mysqlReadRowsAfterQuery` 里每个
arena 分配点都写 `catch return error.DatabaseError`，于是 `std.crypto` 之外的诊断链全在说谎：
`toErrorContext` 把 `OutOfMemory` 映射成具名 code 而 `DatabaseError` 落到 `UnknownError`，metrics 回调
记的 `@errorName(err)` 也是错的，而且**同一种故障在流式路径上报 `OutOfMemory`、在缓冲路径上报
`DatabaseError`**（`src/core/Error.zig:194-196` 明说这一族应是 `OutOfMemory`）。红证据：
`expected error.OutOfMemory, found error.DatabaseError`。改为 `try` 如实传播。
> 同一个循环里的两处**守卫**（`mysql_fetch_row` 为 NULL、`mysql_fetch_lengths` 为 NULL）也一并改成
> 返回 `error.DatabaseError` 而不是伪造一整行 NULL。但**没有为它们造测试**：用原始 C API 探针实测
> MySQL 9.3.0 后确认 `mysql_fetch_lengths` 的 NULL **等价于"当前没有行"**（`num_rows=2` 时 fetch 前为
> true、两次 fetch 后为 false、越界 fetch 后为 true），框架函数跑 8 种语句形状（空结果 / NULL 单元格 /
> 零长串 / 200KB 大格 / 5 行 / binary / 中途报错 / `SET`）共 9 次循环内 fetch **无一返回 NULL** ——
> 在 `res != null` 的前提下该解引用不可达。注释里写明"这是守卫"，实测依据记录在测试注释中。

**游标中途断线现在会记进 breaker（metrics 仍不记，附成本实测）。** `Cursor.next` 变成可失败之后，
调用方能看到错误，但**没有任何地方记录它**。现在 `Cursor` 增加 `owner: ?*Client` 与
`booked_failure: bool`：`next` 出错时按与获取路径**同一个** `isAcceptable` 过滤上报，**每个游标最多记一次**；
`deinit` 的 ping 失败也走同一条路，避免同一次断裂被记两遍；手工构造（`Cursor.init`）的游标 `owner = null`
→ 不计数。红证据：`expected 1, found 0`（`db.cb.failure_count`）。
> **metrics 仍只在获取阶段上报**，这是**有实测依据的选择**：用计数分配器实测，失败的 `next` 调用
> **分配 0 次**（只是 mutex + 计数），而"把 `sql_str` 拷一份留在游标上喂 metrics"是**每个游标 +1 次分配
> （实测 156 字节）**、每次获取都付、且绝大多数游标永不出错；借用调用方的 `sql_str` 也**不行** —— API
> 没承诺其生命周期，树内就有传临时缓冲的调用（`src/ai/business.zig:322` 传 `sql_buf.items`，调用方
> `defer` 释放），那会让 metrics 回调收到悬垂切片。

> **未结的一项**：本批期间有一次整跑 `FAILED`（125s，输出未留存），之后**三次同样的整跑全部通过且
> 计数一致**（1763/1795）。无法证伪也未能复现，怀疑是既有的 wall-clock 敏感用例（runtime stress）抖动，
> 但**没有排除与本次改动有关** —— 记在这里而不是当作已解释。
> 另：同类 OOM 误标在 **PG 缓冲路径**（`pgReadRows`）、**sqlite** 路径与 `formatQuery` 调用点仍然存在，
> 本批只改了 MySQL 缓冲路径。

### 第 9 批：H2 不再丢响应头（Set-Cookie/Location/Retry-After 全丢）、h2c 升级按 RFC 把升级请求当 stream 1 派发、MySQL 流式游标首次有真机用例（**破坏性：否**）

全量 `-Ddb=all` **1753/1782（29 skipped，0 failed）**；PG 17.10 与 MySQL 9.3.0 门控用例分别在
对应服务器上跑过（见下：**门控的正确调用形式**）。

**H2 上除 `content-type` 以外的响应头会被整批丢弃 —— 已修。** `Http2Server.SiteResponse` 只带
`status`/`content_type`/`body`，于是 handler 在 `Context` 上设的 `Set-Cookie` / `Location` /
`Retry-After` / `Cache-Control` / CORS 头在 H2 上**静默消失**（H1 正常）。红证据（真 socket h2c，
解析 HEADERS 帧）：
```
====== expected this output: =========
:status,content-type,location,retry-after,set-cookie,x-app␃
======== instead found this: =========
:status,content-type␃
```
`SiteResponse` 新增 `headers: []const Hpack.Header = &.{}`（**有默认值**，第三方 `SiteHandler` 不受影响；
`headers_owned` 决定 `deinit` 是否逐条释放）。三个决策：
- **`content-type` 保留独立字段**：只有一个权威来源就不存在"两个 content-type"的歧义，而且删字段会破
  已有 `SiteHandler`；编码器是唯一咽喉点，extras 里的 `content-type`（不分大小写）一律忽略。
- **新增响应侧预算 `ResponseHeaderBudget`**，三段同时生效：`SETTINGS_MAX_HEADER_LIST_SIZE` 记账
  （取 `min(peer 广播值, 我们的)`，**peer 的 0 = "不收任何字段"与我们的 0 = "关闭"语义不同，不能直接
  `@min`**，所以 peer 现在被单独跟踪）、字段数上限、以及**编码后块 ≤ peer `SETTINGS_MAX_FRAME_SIZE`**
  —— 后者是硬约束：整块塞进**一个** HEADERS 帧、本模块从不发 CONTINUATION，超了 peer 必须回
  FRAME_SIZE_ERROR。连 `:status` 都塞不下（现实中不可能）时返回 `error.ResponseHeaderBlockTooLarge`
  → 既有路径回 `RST_STREAM(INTERNAL_ERROR)`，绝不发一个超帧。
- **h2 禁止的连接相关字段 = 丢掉 + 一条 warn，不整响应拒绝**：RFC 9113 §8.2.2 对
  `connection`/`keep-alive`/`proxy-connection`/`transfer-encoding`/`upgrade` 是 MUST NOT，静默透传不行；
  但拒绝会把"中间件设了 `Connection: keep-alive`（框架自家 SSE 就设）或 handler 写了错 `Content-Length`"
  在同一条路由上从 H1 的正常服务变成 5xx —— 那正是本次要消除的协议间差异。同一策略覆盖伪头/空名、
  非 tchar 名、值含 CR/LF/NUL、以及 `content-length` 与 body 不符（RFC 9113 §8.1.1 不符即 malformed，
  只有相等才转发）。日志按响应一条汇总（首个被丢字段名 + 原因）。
交叉验证：用重建后的 `examples/http-stress-test` 起服、`curl --http2-prior-knowledge` 实测拿到
`HTTP/2 200` + `content-type: application/json` 且无 malformed frame。**未验证**：真实客户端只验到
status/content-type/body（示例没有设 `Set-Cookie` 的路由），这些字段的线上存在性由仓库自带 HPACK
解码器验证。

**h2c 升级路径根本没派发 stream 1 —— 已修。** RFC 7540 §3.2 / RFC 9113 §3.2：**携带升级的那个请求**就是
stream 1（且处于半关闭 remote），客户端不会再发 `HEADERS(1)`；而本模块只在收到 HEADERS/DATA 时才派发，
于是真实客户端 `curl --http2` 升级后**拿不到任何响应**（原始 socket 探针实测：101 之后只回
`SETTINGS` + `SETTINGS ACK`，on-线 27 字节、无 stream-1 帧；补发一个 `HEADERS(1)` 后立刻正常返回，说明
编码路径本身没问题）。prior-knowledge h2c 正常，所以一直没被发现。
修法：新增 `Http2Server.UpgradeRequest`（method/target/authority/scheme/fields/body/`HTTP2-Settings` 原值），
`serveAfterUpgrade` 多收一个参数，旧的 `serveAfterPrefacePrefetchReader` 主体变成私有的
`serveSession(..., upgrade: ?UpgradeRequest)`，公开入口传 `null`（**其它调用者不变**）。升级请求按
`headers_done + end_stream = true` 播种、**恰好派发一次**后从 `streams` 摘除，并把 `HTTP2-Settings`
**先**当 peer SETTINGS 应用（`conn_max_frame_size`/`peer_max_header_list`/连接窗口）——不等客户端的
SETTINGS 帧，客户端重复发同一组值是无操作；payload 解不开回 `GOAWAY(PROTOCOL_ERROR)`。
之后的 `HEADERS(1)` 命中显式守卫，回 `RST_STREAM(STREAM_CLOSED)` 而不是二次派发（RFC 7540 §5.1）。
红证据：`FAIL (NoStream1ResponseAfterUpgrade)` + 临时帧转储（只有一条 `typ=settings sid=0 len=18`）。
**两条变异检查**证明用例有牙：把 `HTTP2-Settings` 的应用挖空 → `expected 70000, found 65535`（正好是
默认 peer 窗口）；关掉 `HEADERS(1)` 守卫 → `NoStreamClosedForRepeatedHeaders`。真机 `curl --http2`
（非 prior-knowledge，重建后的示例服务）实测：`101 Switching Protocols` → `HTTP/2 200` +
`content-type: application/json` + body，**不再挂住**。
> **残留**：`connFiber` 仍把 h2c 限制在 `GET`（RFC §3.2 没有方法限制），所以真实的 `POST` 升级仍进不来
> （body 路径已实现并有 `GET + Content-Length` 的用例）；`HTTP2-Settings` 畸形 payload 的
> `GOAWAY` 分支、以及 `fillUpgradeStream` 的 OOM 路径都**没有测试**。

**MySQL 流式游标首次有真机用例（补齐上一批"只推理"的那半边）。** 上一批把 `Cursor.next` 变成可失败后，
MySQL 侧的 `mysql_errno` 分支与 `columns_arena` 生命周期**没有任何测试**。新增三条（`DB=mysql` 门控，
真机 MySQL 9.3.0）：中途服务器错误必须以 error 返回、每个流式行的列名必须仍然可读、失败后同 client 仍可用。
> **一个必须记下来的坑**：**PG 用的除零形状在 MySQL 上不成立** —— 本机 `sql_mode` 含
> `ERROR_FOR_DIVISION_BY_ZERO`+`STRICT_TRANS_TABLES`，但 `SELECT 100/(3-i) …` 在 i=3 只返回 `NULL`
> 不报错（`mysql -e` 实测 `50.0000 / 100.0000 / NULL / -100.0000`）。改用**逐行投影错误**：第三行才求值的
> 标量子查询返回两行 → `ER_SUBQUERY_NO_1_ROW (1242)` → `error.DatabaseError`；`mysql --quick`
> （同一 `mysql_use_result` 协议）确认 "先出 2 行、再 ERROR 1242"，**且不能加 `ORDER BY`**（会 filesort，
> 错误在任何行到达前就返回，反而测不到 mid-stream）。
> 列名那条的 red 证据**纠正了一个假设**：把 `columns_arena.reset` 放回 `next` 顶部（等价旧生命周期）→
> 崩在**第一行**（`Segmentation fault at address 0x5555…` @ `expectEqualStrings`），不是"只有后续行坏" ——
> `reset` 在 fetch 之前执行，所以第 1 行的 `columns` 就已经悬垂。用例因此在第 1/2/3 行都读名字。
> `mysql_fetch_lengths` 那个 NULL 守卫**给不出 red 证据**（C API 只在 `mysql_fetch_row` 返回 NULL 时才
> 为 NULL，而进入守卫的路径都在一次成功 fetch 之后）；用 JSON path(3143)/GIS(3037)/标量子查询(1242)
> 三类逐行错误都没能触发它，注释里写明"这是守卫，不是被测分支"。

> **口径更正（上一批写错过，这条比 bug 本身重要）**：`DB=mysql bash scripts/test-fast.sh …` **不会**
> 启用 MySQL 门控用例 —— `test-fast.sh` 自己持有 `DB` 变量（默认 `sqlite`、由 `--db` 覆盖为 `all`），
> 前缀导出的值被脚本内的赋值盖掉，测试二进制看到的是 `DB=all`，`skipUnlessDb("mysql")` 全部静默 skip
> （实测同一 filter：包装脚本 8 passed / 7 skipped，直连 build 13 passed / 2 skipped）。
> **正确形式**：`DB=mysql zig build test -Ddb=all -Dtest-filter=… -Dtest-force-run=true`。
> PG 不受影响（`ZIGMODU_TEST_PG=1` 是环境变量，没有同名脚本变量）。上一批那句"与 MySQL 9.3.0 分组跑过"
> 因此是错的，已在原处标注。

### 第 8 批：CI 那条红是测试的等待谓词反了；`Cursor.next` 不再把错误折叠成 EOF；H2 补齐表单/改写器/查询串；`authRateLimitMiddleware` 首次可编译（**破坏性：是**，1 处编译错）

全量 `-Ddb=all` **1740/1766（26 skipped，0 failed）**；PG 侧另有真机 17.10 跑过
（`ZIGMODU_TEST_PG=1` 是**唯一**能穿过 `scripts/test-fast.sh` 的环境门控）。

> **更正一处口径（本批写错过，第 9 批发现）**：`DB=mysql bash scripts/test-fast.sh …` **不会**启用
> MySQL 门控用例 —— `test-fast.sh` 自己持有 `DB` 变量（默认 `sqlite`，被 `--db all` 覆盖），前缀导出
> 的值会被脚本内的赋值盖掉，于是测试二进制看到的是 `DB=all`，`skipUnlessDb("mysql")` 全部 skip。要跑
> MySQL 门控用例得绕过包装脚本：`DB=mysql zig build test -Ddb=all -Dtest-filter=… -Dtest-force-run=true`。
> 本批（第 8 批）的 MySQL 侧因此**没有**真机验证，第 9 批才补上。

**CI 上那条 5 分钟超时：测试等错了极性，不是运行时的错。** `Runtime: shutdown with the pool mid-batch
hands the claim back first` 的第二次等待写成 `waitUntil(Flag(rt.alive))` —— 而 `Flag.ready()` 返回**原值**，
`rt.alive` 初值就是 `true`（`src/runtime/runtime.zig:1085`）且只会被 `shutdown` 置 `false`。于是它等的
是"alive 变成 true"：绝大多数运行里主线程的第一次检查早于 teardown 的 clear，**立刻返回**（于是它连
"shutdown 已开始"都没等到，与注释相反）；一旦 teardown 的 clear 先落地，谓词永假，5 s 预算耗尽后走
`error.WaitTimeout` 错误路径 → 三方死锁（main 卡在 `deinit` 的 `shutdown_mu`，teardown 卡在 pool join，
pool 线程在 handler 里等 `release`，而 `release` 只有 main 会设）。实测挂死率 **0.1%（1000 次顺序）/ 约
0.3%（4 路并发各 600–480 次）**，CI 上就是那条 `timed out after 5m1.634ms`。
`Clock.Manual` 是误导：`waitUntil` 用的是真实 `monotonicNowMilliseconds`，超时**会**触发，挂死在错误路径之后。
修法（只改测试）：新增 `Cleared(V)` 探针（`!value.load(.acquire)`，即"等一个被别人清掉的标志"），并让
失败路径**先放掉 `shared.release` 再 re-raise** —— 否则任何一次等待失败都不可报告（deferred `deinit` 会
把整个测试二进制挂住）。**强制复现**：在 `std.Thread.spawn` 之后注入 25 ms 忙等（保证 clear 先落地）→
修前 `exit=124`（30 s 超时）/ 修后 0.02 s 过；修后 0/2000 顺序 + 0/2000 并发宽 4。
生产侧的顺序经反汇编与 lldb 独立确认过是对的（`shutdown` 在 `<+180>` 就 `stlrb` 清 `alive`，到 `+792`
才调 `Scheduler.shutdown`），**没有**改动生产代码。

**`Cursor.next` 把驱动错误折叠成"结果取完"（真红已修，破坏性）。** `sqlx.Cursor.next`（以及两个驱动游标）
返回 `?*Row`：流中途的服务器错误与"没有更多行"不可区分，于是**被截断的结果被当成完整结果**。
真机 PG 红证据（`SELECT 100 / (3 - i) AS q FROM generate_series(1, 5) AS i`，`.mode = .streaming`）：
```
[red] row 1 / row 2 … loop ended with no error after 2 row(s); the query has 5 and the server raises at row 3
expected 5, found 2
```
新的签名是 `errors.ResultT(?*Row)`（仓库里 `GrpcStreamReader.next` 已是这个形状）：MySQL 侧
`mysql_fetch_row` 为 NULL **且** `mysql_errno != 0` → 抛错，PG 侧非 `TUPLES_OK`/`SINGLE_TUPLE`/`COMMAND_OK`
→ 走新增的 `pgResultToError`（与获取路径同一张 SQLSTATE 表），连接掉了（`PQgetResult` NULL +
`PQstatus != CONNECTION_OK`）→ `error.DatabaseConnectionFailed`，每行的 arena 分配与
`mysql_fetch_lengths` 的 NULL 解引用也都改成可失败。**同一个流上顺带修掉一个 use-after-free**：列名原
本分配在**每行都会 `free_all` 的行 arena** 里，所以每个流式行携带的 `columns` 都是悬垂切片 —— 真机红证据是
读 `row.columns[0]` 直接 `FAULT`/`SIGSEGV`（列名改为独立的 `columns_arena`）。
**Breaking?** 是（编译错）· 仓库内 39 处（19 个文件）已改完；消费方 `while (cursor.next()) |row|` →
`while (try cursor.next()) |row|`，逐条见 [`docs/UPGRADING.md`](docs/UPGRADING.md) §v0.33.3。
**刻意没有**保留一个"旧的 `next()` 继续折叠 + 新的 `tryNext()`"的兼容层：`Repository`/`QueryResult`/分页
里**没有**任何 Cursor 调用点（那层兼容只会把静默截断留给唯一需要它的那批调用者）。
MySQL 侧的 `mysql_errno` 分支与 `columns_arena` **无测试覆盖**（本机 MySQL 9.3.0 只跑了门控用例，
8 passed / 0 failed），只做了推理。

**H2 适配器补齐 H1 已有、H2 一直缺的四件事（真红各一条）。** 这些是"静默行为不同"，不是"不支持"：
① **表单体不解析** —— H2 上 `ctx.requestParam("field")` 恒为 null（红：`expected 张三, found MISSING`），
现在按与 H1 相同的 helper 解析并遵守 `Server.Config.max_params`（限内解析、超限不解析，两个方向都有断言）；
② **`path_rewriter` 不运行** —— 重写后的路径在 H2 上 404（红：`expected 200, found 404`）；
③ **`:path` 里的查询串不拆** —— `/h2query?a=1` 带着查询串去匹配路由（红：同上 404）且 `ctx.query` 为空，
现在按 `RequestParser` 的方式拆开（`ctx.raw_path` 保留完整 target），**拆不动时返回 400** 而不是带着缺参数
继续路由；④ **`ctx.allocator` 是连接级的** —— H1 每次请求给一个 arena，H2 给的是整个会话的 allocator，
于是 handler 分配的东西会随会话一直累计（`setPathRewriter` 的文档示例正好用 `ctx.allocator`，实测在
SafeAllocator 下当场泄漏 `leaked [len: 5]`），改为每请求 arena。五条用例都是真 socket h2c。

**`authRateLimitMiddleware` 此前从未被编译过 —— 它里面有 4 个编译错误，修好后才看得见那个 panic。**
Zig 惰性分析函数体，而这个工厂**没有任何 in-tree 调用者**，所以：返回类型声明成 `!api.MiddlewareFn` 却返回
`.func/.user_data`（`Middleware`）、把 `&.{}` 当 writer 缓冲、在临时值上取 `*const Io.Writer`、
`next(ctx, next, user_data)` 用三个实参调用 `HandlerFn` —— 四个错误全在一个语句里，一直没被发现。
最小修到能编译后，上一批报告的 panic 就复现了：H2 上 `ctx.stream` 为 null，而 429 路径
`ctx.stream.?.writer(ctx.io.? …)` 直接 `panic: attempt to use null value`（`exit=134`）。
现在拒绝走 Context 的响应通道（`ctx.setHeader("Retry-After", "60")` + `ctx.sendError(429, …)`）。
> **顺带发现**：旧代码是把 body **直接写到 socket、且写在状态行之前**的 —— 在 H1 上也是一条框架错误的响应，
> 不只是 H2 的问题。这条路径既然从没编译过，任何依赖它 429 响应体的应用都不存在。

**`permissionGateWith`「一个进程两个 server」有结论了：正确，且现在有用例钉住。** 新增用例在一个进程里
建两套完整拓扑（各自 Router/CatalogSlot，路由与权限映射都不同，共用一个 JWT 密钥与授权表，所以差异只在
"各自 catalog 要什么"），断言 reader token 在 A 200 / B 403、A→B→A 交错后仍 A 200、writer token 相反、
`/status` 的公开性按 app 各自成立、`/audit` 只在 A 注册（B 404）。**用例的牙**：故意把 gate 改成读一个
进程全局 slot（两个 server 共用最后一个构造的 catalog）→ 立刻红（`expected 200, found 403`），已还原，
生产代码一行未动。原因是设计使然：slot 指针与 config 在**每次构造**时拷进 per-call `Store`、
catalog **每请求**读，中间没有进程级状态。
> **顺带查出两个真的进程全局**（当时都**未改**，且都是既有文档化的单实例假设）：
> `OpenApiRouteStore`（第二个 server 注册会覆盖第一个 → A 的 `/openapi.json` 会服务 B 的 catalog，
> 只影响文档端点不影响执法）；`catalogLoaderFromTable` 的模块级 `Holder.tbl`。
> **两者已在第 13 批修掉**（分别按 `*CatalogSlot` 与 `RolePermissionTable` 指针分状态）。

**H2 的 `ctx.io` / 请求预算**（上一批只修了流式拒绝，这批补齐）：H2 路径此前不 arm `ctx.io` 与
`setDeadline`，于是 `ctx.io` 为 null（`jwtAuth` 会静默降级到没有 CSPRNG 句柄的 `SecurityModule.init`、
x402 发票号回落到时间戳+计数器）、`sqlContext().deadline_ms` 为 null（存储层不会拒绝开始新查询）。
红证据：把这两行注释掉 → `io=null sql_deadline=none within_budget=false` / 期望
`io=set sql_deadline=set within_budget=true`。
> **已知未修**：`Http2Server.SiteResponse` 只带 `status`/`content_type`/`body`，所以 **H2 上除
> `content-type` 以外的响应头全部被丢弃** —— `Retry-After`、`Location`、`Set-Cookie`、CORS 头都会
> 静默消失。修它要给 `SiteResponse` 加头列表，是独立的下一批。

### 第 7 批：plain 池不再交出死连接、常驻 HTTPS client 的证书时钟重挂、Otlp/Secrets 常驻 client、sqlx Builder 不再静默丢子句、catalog 查询按 schema 限定（**破坏性：否**）

全量 `-Ddb=all` **1731/1755（24 skipped，0 failed）**（第 6 批 1721/1745 → +10 用例）。

**plain-HTTP 池会把死连接交出去（真红，已修）**。`executeRequest` 原本在返回前无条件 `release`，而
`release` 只看 `isAlive()`（对 `last_used` 的 30 s 窗口）——对端在应答后关掉的连接**不是**"不 alive"，
于是它回到 idle 又被下个请求领走。新用例（loopback：服务一次后关闭）红证据：
`round 1: WriteFailed — 1 idle connection(s) in the pool, 0 active`，四次重试**全**打在同一条尸体上。
修法照 HTTPS 那条路：新增 `ConnectionPool.discard`（关 socket 并从 active 列表摘除，不再入池）与
`removeActiveLocked`（`release` 与 `discard` 共用），失败路径 `errdefer … discard`、成功路径才
`release`（`executeRequest` 与 `executeRequestStream` 各一处）。

> **残留（有意不修）**：对端在**成功应答之后**才关连接时，仍可能有**一次**失败（重试循环吸收掉，
> 池随后自愈）。修复前是"此后每一次都失败"。要彻底消掉得做整个 target 的剪枝（HTTPS 路径那样），
> 那需要另一轮实验。`isAlive()` 本身仍是启发式，不是存活证明。

**常驻 HTTPS client 冻结了它的时钟（随之修掉）**。上一批把 `std.http.Client` 变成了常驻对象，而 std 的
`Client.now` 在 init 时取值、**只读一次**并作为 `.realtime_now` 交给 TLS 做证书有效期判定
（`crypto/tls/Client.zig` → `chain.verify`）。后果：跑久了会用一个陈旧的"现在"判定 —— 一小时前刚过期的
证书可能被放行。一次性实验（真实出站 HTTPS，非仓库用例）：把 `client.now` 钉到 2010-01-01 后**每次**请求
都 `TlsInitializationFailed`，置 `now = null` 后立刻 200 且 std 自己重新取了值 —— 所以 std 的官方开关就是
`now = null`，**不需要重建 client**。落地：`https_clock_max_skew_seconds = 300`（偏离真实时钟超此值才重挂，
即最多每 300 s 流量触发一次 CA bundle 重扫），且重挂只在 `https_inflight == 0` 时做 —— std 是在自己的
CA 锁**之外**读 `now` 的（它源码里就留着 `TODO data race …`），所以必须保证没有在飞请求。用例钉住：界内不动、
越界（两个方向）清空、client 仍只有 1 个、真实请求后 std 自行重新武装。池化的 TLS 连接与
`https_clients_created == 1` 都不受影响。

**`OtlpExporter` / `SecretsManager` 改为长生命周期 `HttpClient`**。这两处此前**每次调用**都
`HttpClient.init` + `deinit`，拿不到任何连接复用（HTTPS 每次重握手）。现在各自持有一个懒创建的常驻
client（单次原子发布：`load(.acquire)` 快路径、`cmpxchgStrong` 慢路径，败者丢弃自己那份——`HttpClient.init`
不分配任何东西，所以丢弃不掉连接也不掉字节），在各自的 `deinit` 释放。红证据（loopback 探针按 TCP accept
计数）：修复前 3 次 export → **3** 次 accept、3 次 Vault 读 → **3** 次 accept；修复后各 **1** 次，并直接断言
`idle_connections.items.len == 1 && items[0].request_count == 3`（重拨会把计数重置为 1）。另外做了两次
"守卫确实会咬人"的变异检查：把 `SecretsManager.deinit` 的拆卸换成只 swap 不 deinit → SafeAllocator 报
`leaked 176 bytes`；在 cmpxchg 败者分支插探针 → 一共命中 14 次（证明竞态分支真的被执行，探针已移除）。

> **行为面变化**：`max_connections = 2` 的口径从"每次调用的 2 条"变成"每个组件实例的 2 条"——同一实例上
> 超过 2 个并发的 plain-HTTP export / Vault 读可能拿到 `error.PoolExhausted`（HTTPS 不走这个池）。
> **契约**：两个 `deinit` 都**不得与在飞请求并发**（`deinit` 没有 `io` 可用于等待，加引用计数得改公开签名），
> 已写进两处文档注释。`https://` 的 **TLS 连接复用仍未经 loopback 实测**（自签对端不在系统信任库里）。

**sqlx `Builder` 的链式方法不再静默丢子句**。`where` 等六个链式方法会把实参复制一份，复制失败时错误**无处
可去**——于是 builder 照常输出**少了那个子句**的语句。对 `WHERE` 来说这不是少个括号，是查询被悄悄放宽。
红证据（一次性失败分配器）：期望 `SELECT * FROM users WHERE tenant_id = ?1 ORDER BY id DESC`，
实际 `SELECT * FROM users ORDER BY id DESC`。

> **实现选择（与最初设想不同，记录一下理由）**：没有改成返回错误联合（那会让
> `_ = b.where(…)` 直接编译不过，**下游每一处调用点都得改**，并且把 fluent 链打断成 `_ = try …` 一串），
> 而是把错误**latch** 在 builder 上、由 `toSql` 返回。`toSql` 本来就是 `![]u8`，是每个调用点都必须经过的
> 唯一装配口，所以"少了子句的语句被发出去"这条路依然不存在 —— 而源码保持兼容。链失败时**不**改动 builder
> 状态（`appendClause` 先复制再改列表，`replaceClause` 同理），所以失败调用不留下半个子句。
> 顺带：`Builder.select` 把 OOM 伪装成 `error.DatabaseError`，改为直接抛出 —— 它同时也是 OOM 扫描看不到
> 这条路径的原因。新增两条用例（一次性失败分配器逐个分配点 + `checkAllAllocationFailures` 全链扫描）。

**catalog 列探测不再跨 schema 命中**。`information_schema.columns` 的查询此前**不带任何 schema 谓词**，
同名表在别的 schema 里存在就会答"这列存在"，而且显式写成 `schema.table` 时 schema 被**丢掉**。现在收敛到
`src/sqlx/sqlx.zig` 的可复用 `catalogColumnProbe(dialect, table, column)`（新 `CatalogDialect` /
`CatalogColumnProbe`）：PG 用 `table_schema = current_schema()`、MySQL 用 `table_schema = DATABASE()`；
写成 `billing.orders` 时改为 `LOWER(table_schema) = LOWER(?)` 并把 schema 作为**绑定参数**（不是拼进文本）。
`src/web4/x402_store.zig` 的迁移探测改调这个 helper。

> **未验证**：没有可达的 PG/MySQL 服务器，所以**服务端行为没有实测**——用例只断言生成的语句与绑定参数的
> 顺序/个数。真机覆盖（`ZIGMODU_TEST_PG=1` / `DB=mysql` 门控的 `probeCatalogColumn`）在本地是 skipped。

**删除 `ConnPool.reconnect` 与其两个只服务它的字段**（`max_reconnect_attempts` / `reconnect_delay_ms`）。
它开连接时**不更新 `active` 计数**（其他所有开路都更新），且**无任何调用点**（`zmodu deadcode` 也把它标为
dead 并已在基线里）——缺陷真实但不可达，所以删掉而不是给它补账。`check-deadcode.sh` 报
`3 dead declaration(s) removed`。

### 第 6 批：HTTPS 池化、x402 发票绑定付款人、CSRF 签名与代理头信任收紧、flate 压缩中间件（**破坏性：是**，两处）

全量 `-Ddb=all` **1721/1745（24 skipped，0 failed）**（基线 1693/1715 → +28 用例，新增 2 条 PG/MySQL 门控 skip）。

**HTTPS 池化（`src/http/HttpClient.zig`，+526/−9）**。此前每个 `https://` 请求都新建一个 `std.http.Client`，
连接无法复用（`keep_alive` 也被显式设成了 false）；现在常驻一个懒创建的 `https_client`（`httpsClient()` 在锁内
创建/发放，`deinit` 用 `lockUncancelable` 把它摘出来后**在锁外**销毁），`keep_alive` 恢复默认 true。红证据：
还原"每请求新建 client" → 单实例计数 `expected 1, found 2`。

> **过程中发现的一条 std 行为**（否则这次改动会引入一个更糟的 bug）：用 `/tmp/probe_std_client.zig` 在 loopback
> plain 上逼出 std 连接池的两条不同命运 —— **读失败**（`HttpConnectionClosing`）时 std 会把死连接从 free 表剔除；
> 但**写失败**（`WriteFailed`，`reader.state` 仍 `.ready`）时死连接会被**放回** free 表，于是每次请求都命中同一条
> （`accepts` 恒为 1，池等于卡死）。因此失败路径改为调用 `discardIdleHttpsConnectionsFor(url)` 按 host/port/protocol
> 精确剪枝（用 `@hasField` 编译期断言钉住 std 的字段名，上游改名会编译失败而不是静默失效）。另外 std 对半读响应会先
> `discardRemaining()` 抽干再回池 —— 对没有终止的 SSE/LLM body 就是无限阻塞，所以 `executeHttpsStream` 用
> `errdefer { conn.closing = true }` 保证失败不回池。新增 5 条用例。

**x402 发票绑定付款人（`src/web4/x402_store.zig` + `middleware.zig`）**。以前只要知道 `invoice_id`，任何客户端都能
拿自己的 tx hash 把这张发票核销掉（发票是"每张恰好核销一次"的台账，先到先得）。现在签发时写入 `payer_did`，核销时
比对，不符 → **新的** `RedeemResult.payer_mismatch`（403，且**不消耗**发票，合法付款人仍可核销；刻意不复用
`already_used`，否则下游会把越权探测读成"已用过"）。比对发生在 status/deadline 判断**之前**。付款人来源是
**attr**（默认按序读 `did` → `user_id`，`X402Config.payer_attr` 可覆盖），**从不读 header** —— 伪造 `x-did`
仍然 403。未绑定的遗留行（老库 `payer_did IS NULL`）按原语义放行。`migrate()` 增加幂等 `ALTER`（sqlite 走
`PRAGMA table_info`，PG/MySQL 走 `information_schema`），老库可以直接升级。红证据：去掉比对 →
`expected .payer_mismatch, found .redeemed` / `expected 403, found 200`。**在真 PG 17.10 与 MySQL 9.3.0 上验过**
（门控形式：PG 用 `ZIGMODU_TEST_PG=1`；MySQL **不能**用 `DB=mysql bash scripts/test-fast.sh` —— 那句的
`DB` 会被脚本自己的赋值盖掉、门控用例全部静默 skip，得用 `DB=mysql zig build test -Ddb=all
-Dtest-filter=… -Dtest-force-run=true`；见第 9 批的口径更正）。

> **接线前提（应用侧）**：`x402Middleware` 必须挂在身份中间件**之后**，否则 attr 还没写，发票会**静默**变成未绑定
> （等于没有这道防护）。mTLS / API-key 场景没有 `did`，用 `payer_attr` 指到你的身份 attr 上。

**CSRF：签名 token + 代理头信任收紧（`src/api/Middleware.zig`）**。新增
`CsrfConfig{ trust_forwarded_host = false, sign_key = null }` 与 `csrfWith(config)`、`csrfMintSignedToken(io, sign_key)`。
`csrf()` 现在是 `csrfWith(.{})`，即**默认不采信 `X-Forwarded-Host`/`Proto`** —— 这两条是客户端可伪造的，旧行为允许
攻击者在代理会透传该头时把 origin 检查绕过去（红证据：伪造 XFH → `expected 403, found 200`）。反代场景用
`csrfWith(.{ .trust_forwarded_host = true })` 显式打开（打开时会打一条 warn 提醒代理必须每请求覆写）。
`sign_key` 把 cookie 里的 token 从纯随机 nonce 变成 `nonce.signature`（nonce = 32 B `randomSecure` hex，
sig = HMAC-SHA256 hex，共 129 字节，常数时间比较），未签名/篡改的 token 一律 403。

> **这是本批的第二处破坏性变化**：`csrf()` 现在要求中间件在 `user_data` 上拿到 `CsrfConfig`（`csrfWith` 自己会装）。
> 手工调用 `mw.func(ctx, next, null)` 会 panic；按 `http.addMiddleware(http.csrf())` 的常规用法不受影响。文件内 8 处
> 测试已相应改写。

**响应压缩中间件（新文件 `src/api/Compression.zig`，699 行 / 13 用例）**：`http.compressionMiddleware` +
`CompressionConfig`，deflate（zlib 容器）。默认 `min_size = 1024`；类型白名单（json/js/xml/wasm + 结构性
`text/*`、`+json`/`+xml`，`image/svg+xml` 会压）；排除 1xx/204/205/206/304；**只有压缩后更小才替换**；候选类型上
**无条件**加 `Vary: Accept-Encoding`（含客户端没发该头的情形，缓存正确性优先）并与已有值合并；替换后**移除
`Content-Length`**（Server 会重算）；`ctx.streaming` 直接跳过；失败顺序保证不会出现"带了 `Content-Encoding` 但
body 没编码"的响应。红证据：把 `compressResponse` 挖空 → 12 条里 8 条红。**未做**：brotli/zstd（std 无编码侧）、
流式增量压缩、动态级别、按路由开关。新文件需要 `src/tests.zig` 里有一行 `_ = @import(...)` 才会进测试二进制
——`http.zig` 的导出只保证它被编译。

**测试隔离：WAL 用例的固定目录（顺带，解释了一类 flake）**。`zig build test` 并行跑 6 个测试二进制，
`WAL.zig` / `SagaOrchestrator.zig` / `DistributedEventBus.zig` 的 8 处用例用的是**固定相对目录**
（`wal_test`、`wal_test2`、`wal_test_deb`、`wal_test_saga` …），彼此 `deleteFile` 拆台，表现为
`error.FileNotFound` @ `WAL.zig:221 createSegment`（上一次在 `ai.workflow` 用例上偶发过一次）。改为
`testWalDir(base, buf)` = `"{base}_{pid}"`，旧的固定目录已删除。

## [0.33.2] - 2026-09-24

### 第 5 批：CI bench 基线重录、Lru/Pool 两处真红修复、h2 dispatch E2E、OOM 注入扫出两个真缺陷（**破坏性：否**）

按"ROI 先做"清单推进。全量 `-Ddb=all` **1693/1715（22 skipped，0 failed）**。

**CI bench 基线重录（已单独提交 `60a4313`）**：CI 基线此前是 **27 条指标 / 0 条 alloc 预算** →
`check-bench.sh` 在 CI 上对 alloc 判据 `budgeted=0`，**等于没生效**（本地 32/32 是生效的）。
数值取自 `89d5dd4` 绿跑产出的候选 artifact（27 → 32 条，补上新指标），预算从本地基线逐条抄入
（预算描述"该热路径应零分配/按契约分配"，是结构属性、与机器无关）。现在两边同为 32/32。

**`Lru.deinit` 的无锁 teardown（真红）**：`if (!self.mutex.tryLock())` 抢不到锁就**在别人持锁、
正在改 `map`/`list` 时**销毁节点并 `map.deinit()`。新用例把"free 是否发生在持锁者临界区内"记进
计数分配器，修复前 `expected 0, found 3`（3 次 free 全在临界区内）；改用 `lockUncancelable` 后
5/5 绿。语义变化是有意的：deinit 从"竞争失败就带病拆"变成"等待"，注释写明理由。

**`Pool.release` 取消时丢连接（真红）**：`self.mutex.lock(self.io) catch return` → 取消即返回，
连接既不回 idle 也不销毁、`active_count` 不减（每发生一次池永久少一个槽）。新用例在 release 卡在
池锁上时对其 future 下 cancel，修复前 `expected 1, found 0`（`idle + destroyed != created`）并
被 SafeAllocator 判泄漏；改用 `lockUncancelable` 后 5/5 绿。**选"等"而不是"取消即销毁"的理由**：
`release` 返回 `void`，取消发生时**没人能接收这个连接**，"尊重取消"只能二选一——每次取消白扔一条
健康连接，或丢一个槽位（正是本 bug）；同文件 `deinit` 与 `sqlx.ConnPool.release` 也已是这个口径。

**h2 完整 dispatch E2E（3 条真 socket）**：补上此前**唯一零观测的那一跳**
（`Config → Server.http2ServeOptions → 执法/派发`）：① 注册路由返回 handler 体、`:status=200`、
`content-type=application/json`；② 路由级中间件按 h2 请求头判定（无 `x-tenant` → 401、有 → 200）；
③ `Server.Config.max_body_size = 64` 在 h2 上生效（128 字节 → `RST(ENHANCE_YOUR_CALM)` 且连接存活、
8 字节 → 200）。**红证据**：在 `http2ServeOptions` 顶部插 `if (true) return .{};`（= 统一前行为）
→ 三条全红（内置 404 `not found` / 无视限额）。

> **更正上一版的一条结论**：上一批声称"h2 响应的 content-type 大小写敏感查找已修"，**实际没有**
> —— 我改用的 `ctx.header()` 是读**请求头**的，h2 响应一直回落 `application/octet-stream`。
> 本版用 `headerLookup(ctx.response_headers, "content-type")` 真正修好，并由上面第 ① 条用例钉住。

**OOM 注入扫描落地（`checkAllAllocationFailures`，此前 0 处使用）**：挑了 5 处"分配密集 + errdefer
链复杂"的小函数（`Hpack.Decoder.decode` ×2 路径、`Validator.validateStructCollect` ×2、
`sqlx.Builder.toSql`/`batchInsert`、`SecurityModule.generateTokenWithTenantAndVersion`），
逐个分配点注入失败。扫描成本合计 **3.6s**（N=7–24 个分配点/函数）。**扫出两个真缺陷**：

1. **`Hpack.decode` 在 OOM 时泄漏名字副本**：同一个 struct literal 里的两个 `dupe`，第二个（value）
   失败时第一个（name）还悬着（`errdefer` 要等结构体构造出来才注册）。红：`fail_index 7/11`，
   `allocated 364 / freed 354`（漏 10 字节），失败点与泄漏点栈都指向那两行。修法：把两条 dupe 提成
   具名变量、name 先 `errdefer free` 再试 value。
2. **Huffman 字面量名字的第二处 use-after-free**（非 OOM 路径）：名字缓冲的清理写成了**块表达式内的
   `defer`**，而块表达式里的 `defer` 在 `break :blk` 时就执行——于是它在 `dupe(name)` **之前**就 free 了
   缓冲。新用例打出 `found: UUUUUUUUUU`（0xAA 释放毒）而非 `x-trace-id`。既有测试没发现是因为
   Huffman 端到端用例只编码**值**、名字走静态索引。修法：把清理移到字段作用域（与同函数 value 的写法一致）。

   为证明绿的扫描不是空跑，对生产代码各做了一次"临时拆掉一处清理 → 扫描变红 → 立即还原"的变异检查
   （Validator `appendViolation` 的 errdefer → 漏 12 字节；Builder `toSql` 的 `buf.deinit` → 漏 344 字节；
   SecurityModule 的 `header_json` free → 漏 38 字节），三处均已还原。

**`ConnPool.active`：判定为"不是 bug"，并更正此前的一处描述**。加了特征化用例后确认：它数的是
**池拥有的连接数（idle + 借出）**，不是"在飞数"——开连接 `+1`、关连接 `-1`，release→acquire 净变化 0，
而 acquire 的容量闸门正是拿它比 `max_open`，语义必须如此。此前记的"读数偏低"是反的：按"在飞"去读会
**高估**空闲数，且无流量时它会钉在池的高水位；真正的在飞数是 `active - idle`。想要"在飞"指标应当是
**纯增量**（加 `current_in_use = active - idle`），不要改计数语义（改计数必须同时改容量闸门，否则池会
放进 `max_open + max_idle` 条 socket）。顺带发现 `ConnPool.reconnect` 是唯一"开连接不计账"的地方，
但**无任何调用点**（死代码）。

**测试隔离修复（顺带，解释了我们看到的"偶发失败"）**：两个用例用**固定的 `/tmp` 路径**
（`/tmp/zigmodu_2pc_in_doubt.db`、`/tmp/zigzero_sqlx_stmt_test.db`），并发跑同一套件（第二个测试二进制、
或同一工作树里的另一个代理）会互相 `deleteFile` 拆台——这正解释了并行时偶发的
`TwoPhaseCommit: in-doubt` / `sqlite prepared statement` 失败。两处改为**按 pid 唯一**并保留了前后清理。
## [Unreleased]

### soak 的 RSS 增长查明：**是测试分配器这条探针**，不是集群；门禁改成有意义的（**破坏性：否**）

困扰几轮的"RSS 随流量线性增长"有了确定性根因：`std.testing.allocator`（SafeAllocator）在**每次
alloc/free 各做一次栈回溯**，而这套工具链上**每次回溯在进程里永久留下 ~313 B** —— 落点是
`std.debug.getDebugInfoAllocator()` 那个**永不 reset 的 arena**（arena 的 `free` 是 no-op），
`SelfUnwinder.deinit` 每次都用它释放 CFI/表达式 scratch。证据链（每步都是差分实验，非推理）：

| 实验 | 结果 |
|---|---|
| 同一负载，只换根分配器 | `testing.allocator`：活字节 172 KiB / **RSS 11→89 MiB**；`smp_allocator`：活字节 130 KiB / **RSS 9→12 MiB 平** |
| 纯 churn（最多 1 个活分配，200k 次 `alloc(128)`+`free`） | testing **+125 MiB**；smp / page **0** |
| 分配器内部记账（SafeAllocator + 计数 backing） | 活字节恒 32 KiB、alloc/free 成对 → 分配器**一个字节都没留** |
| 唯一变量 A/B：`.stack_trace_frames = 7`（Debug 默认） vs `0` | `7` → **+125,040 KiB**（三次一毫不差）；`0` → 平 |
| 完全不碰分配器：400k 次 `captureCurrentStackTrace` | **+125,104 KiB ≈ 313 B/次，线性**；空转对照组 0 |
| 在编译根 hook `getDebugInfoAllocator` | 同样 400k 次 → **+128 KiB 平**（hook 被调 2,002,320 次） |

模型自洽：105k 次分配 → 78 MiB = 782 B/次 ≈ 2 次捕捉 × ~330 B，用它预测 4800 那组得 167 MiB
（实测 163 MiB，差 2.5%）。

**harness 改动**：soak-cluster 与 runtime-stress 的根分配器从 `std.testing.allocator` 换成
`DebugAllocator(.{ .stack_trace_frames = 0 })` —— canary 与泄漏检测都保留，只是不做栈回溯
（那正是泄漏源）；soak 另加一条**精确判据** `soak_gpa.deinit() == .ok`（活字节回到拆机前），
RSS 预算从 128 收紧到 **48 MiB**（原来它是"量 Zig 调试 arena"的假门禁，我还把它接进了夜间 CI）。

实测（本机）：soak-cluster 默认 **RSS 10→12 MiB**（原来 88–91）、4800/写者 **9→12 MiB**（原来 163）、
`1 passed`；runtime-stress RSS spread 49 KB（budget 24 MiB）、PASS。顺带把文件里那段"未结发现"的
注释换成根因与标定数据。

### HTTP/2 收尾：限额统一、会话空闲超时、HPACK 头列预算、h2c 升级路径（**破坏性：否**，两处 h2 行为变化）

- **限额统一**：新增 `Server.http2ServeOptions`（唯一构造点），h2 从此跟随 H1 的
  `max_body_size` / `header_limits`（解压后头列 **16 KiB / 100 条**）/ `header_timeout_ms`；
  过去 h2 **完全绕开**这三个（硬编码）。**没有引入新旋钮**（一个设置管两个协议，刻意的）。
- **会话空闲读超时**：h2 过去**永不超时** —— 一个连上就不说话的 prior-knowledge h2c 连接会永久占住
  一个连接处理线程。现在按剩余预算武装读超时（递减，所以"每 budget-1 ms 发一个字节"不能续命），
  超时回 `GOAWAY(ENHANCE_YOUR_CALM)`。**这是对 h2 的行为变化**：浏览器挂着的空闲 h2 连接会在
  10 s 后断开；`header_timeout_ms = 0` 可关（会同时关掉 H1 的 slowloris 闸门）。
- **HPACK 头列预算 + 通告**：按"解压后字节（每字段 +32 B 开销）+ 条数"计费，通告
  `SETTINGS_MAX_HEADER_LIST_SIZE`（通告值 == 执法值）。**超限是流级 `RST(ENHANCE_YOUR_CALM)`**
  （RFC 9113 §6.5.2），且**整个块仍解完只是丢字段** —— 中途弃块会让 HPACK 动态表与对端编码器错位，
  把流级错误升级成连接级（有用例钉住"下一个流仍能按索引解出正确值"）。
- **顺带修三处**：① `serveAfterUpgrade` 从未被调用（h2c 升级路径仍用硬编码选项 = 死 API），且升级
  路径丢管线化 preface 字节（客户端把 preface 与升级请求同段发来时）—— 两处都修；② `Hpack.decode`
  的 `errdefer` 用**长度 ≤ capacity 的 slice** 去 `free` 再 `deinit` 容量 = invalid free（此前不可达，
  新预算错误路径一踩就 SIGABRT）；③ h2 响应的 content-type 查找是大小写敏感的
  （`response_headers.get("content-type")` vs 实际写入的 `Content-Type`）→ h2 响应一律落到
  `application/octet-stream`，改用大小写不敏感的 `ctx.header()`。
- 测试：新增 8 条（5 条真 loopback），②③ 有可复现红（探针断开预算/`arm_ms` 即红）；① 只有推理链
  —— `Config → ServeOptions` 那一跳没有测试观测，**"走注册路由的完整 dispatch E2E"仍未做**。

### sqlx 游标收尾：接回熔断与指标、`PQcancel` 抽干、PG 幽灵行（**破坏性：否**）

- **游标路径接回熔断器与指标**：`queryCursorExPrimary` 过去只 `cb.allow`，成功/失败都不记账、
  不触发 `metrics_callback`（对比 `queryPrimary` 两者都有）—— 副本熔断在游标路径上永不打开。
  现在四处字段（`duration_ns`/`query`/`ok`/`err_msg`）与熔断时机**逐字段对齐** `queryPrimary`；
  "抽干时流断了"也在 `Cursor.deinit` 记账（deinit 处不报 metrics：游标没留 `sql_str` 副本，
  为一条迟到事件拷一份等于给每个游标加一次分配）。
- **PG 早弃游标改用 `PQcancel`**：过去只能"读完剩余行"（弃掉大扫描要付全量读取代价）。新绑定
  `PQgetCancel`/`PQcancel`/`PQfreeCancel`（签名用 clang 对着真 `libpq-fe.h` 验过），errbuf 256 B
  照 `fe-cancel.c` 约定；`PQgetCancel` 为 NULL 或 `PQcancel` 失败都**回落到抽干**（旧行为、旧成本）。
  **未运行时验证**：真 PG 的 cancel+抽干时序（本机无服务）。
- **修 PG 流式游标的幽灵行**：读到结尾会多出**一行全 NULL**（空结果集时这行是唯一看到的行），
  `row.get("col").?` 在 Debug/Safe 直接 panic。依据链到 libpq 的 `PGASYNC_READY` 终局交付
  （`PQntuples(res)==0`），`!eof` 门控也因此更准。
- **`Client.withAcceptable` 任何调用方都编译不过**（内层函数捕获运行时参数 → `'f' not accessible`）
  → 参数改 `comptime`；**buffered 游标返回的行 `arena` 是悬空/undefined**（`Row.rowAllocator()` /
  `scan()` 即 UB）→ 在 `Cursor.next` 的 buffered 分支补 `row.arena = &rows.arena`。

### 构建/工具链：`Compile.max_rss` 实测是 fail-silent（**决定不加**）、fmt 门禁入 build 图、关停锁逐处判定

- **`Compile.max_rss` 不加**：实测超限时打印 `memory usage peaked at 0.26GB …, exceeding the declared
  upper bound`、树里显示 `failure`，但**总结是 `3/3 steps succeeded`、退出码 0**（源码：
  `Maker/Step.zig` 只把消息 append 进 `result_error_msgs`，不返回错误；`Maker.zig` 仍置 `.success`）
  —— 又一个"树里红、CI 绿"的假门禁。`--skip-oom-steps` 更是静默跳过。CI 侧的真杠杆是 `-j2`。
- **`b.addFmt` 落地**：新增 `zig build fmt-check`（`check = true`），CI 从两处裸 `zig fmt --check`
  收编到一处；探针验证过"绿跑后改坏文件仍会红"（不会被缓存掩盖）。
- **关停路径 `lockUncancelable`**：前提修正（全仓并非 0 处，`runtime.zig`/`scheduler.zig`/`sqlx.zig`/
  `breaker.zig` 已在用）；逐处判定后**只改 2 处**：`Pool.deinit`（原来取消即 `catch return`，跳过销毁
  idle 连接 = 全泄漏）与 `WorkerPool.signalShutdown`（取消则 `shutdown` 标志没置、broadcast 没发 →
  随后 `thread.join()` **永久挂死**）；其余 10 处（请求路径/getter/`Lru` 的完整清理分支）判定不改并
  写明理由。顺带报告未修：`Lru.deinit` 的 `tryLock` 无锁 teardown 竞态、`Pool.release` 取消时静默丢连接。

### 文档

`AGENTS.md` 与 `docs/ROUTE_TABLE.md` 的背压表补上 h2 一行：h2 跟随 H1 的限额/超时、**没有独立旋钮**，
并标出"空闲超时与头列预算对 h2 是新行为"。

## [Unreleased]

### 第 3 组：sqlx 游标所有权/闸门、两处配置串号、CSRF/CSP、web4 顺序与时钟、x402 台账语义（**破坏性：否**，含一处 fail-open 修复）

**x402：`store` 明确为「幂等台账」，校验回归 verifier（fail-open → fail-closed）**
`x402Middleware` 过去在配了 `store` 时**完全跳过 verifier** —— 而 `redeem` 只把客户端自报的
`tx_hash` 写进库，所以任何客户端对任意已签发发票自报一个 hash 就通过。旗舰示例正是这个配置，
它自己的测试还用伪造的 `"0xabc"` 断言 **200**（把漏洞固化成了期望值）。现在：**校验始终走
`X402Config.verifier`**，store 只负责"每张发票恰好核销一次"；文档（`x402.zig`/`x402_store.zig`/
`middleware.zig` 字段注释/AGENTS.md）统一改成"台账 ≠ 校验器"。示例改为显式注入 dev 用的
`verifyPaymentAllowAll`，并**加了一个 strict 门**（同一个 store + 默认 reject verifier）断言
**403** —— 这条断言在 store 越权顶替校验时会红。行为变化：只配 store 不配 verifier 的应用
会从"放行"变成"403"（这正是修复本意）。

**sqlx**
- **流式游标现在拥有连接**：过去 `queryCursorEx` 在返回前就 `defer release`，而游标内部仍持有
  `conn`/`PGconn` —— 另一个 fiber 可立刻拿到同一条连接发查询（协议交错）。现在流式游标把
  `{pool, conn}` 存进 `Cursor`，`deinit` 时先 `ping` 再 `release`，不健康就 `discard`；
  **PG 侧 `deinit` 先抽干 `PQgetResult`**（`pingFn` 只看 socket 状态，所以旧代码下这条连接
  永远"健康"地被复用并持续出错）。红→绿：无 `checkout` 字段时编译失败 → 两条用例（归还一次
  且 `acquired == released`；坏连接被 discard 不进 idle）。**未运行时验证**：真 PG/MySQL 的抽干
  路径（本机无服务），且"游标必须先于 `Client.deinit` 释放"现在是硬约束（已文档化）。
- **`Builder` / `Bulk` 的标识符闸门**：表名/列名/upsert 的 conflict/update 列过
  `validateIdentifier`，`where`/`orderBy`/`having`/`join` 片段过 `validateSqlFragment`
  （开发者表达式不误判）。红：恶意表名被原样拼进 SQL。语义变化：`selectColumns` 现在只收列名
  （`"COUNT(*) AS n"` 这类表达式被拒）。
- **`queryScalar` 从未能编译**：它转调要求 struct 的 `queryRow`，而 `scanStruct` 的报错文案
  恰恰推荐"用 `queryScalar` 扫单列"—— 一个指进去就是死路的循环。现在两条形状都支持：struct
  按列名扫（既有用法不变），标量取首行首列（`i64`/`f64`/NULL/无行/绑定参数都有用例）。
- **SQLite 扩展码被拿去比主码**：`sqlite3_extended_errcode` 返回 2067（UNIQUE）之类，而代码写
  `ext_code == 19`，于是约束诊断与 `error.ConstraintViolation` 在 sqlite 上**从不触发**（一律
  落 `DatabaseError`，任何 switch 这个错误的调用方都踩空）。新增 `sqlitePrimaryCode()` 遮蔽后
  在三处使用。**顺带被新用例抓到同一函数里的 off-by-one**：`"UNIQUE constraint failed:"` 是 25
  字符而代码用 `+24`，所以诊断出的表名一直带一个前导 `:`（现已用字面量 `.len`）。

**安全**
- **两处函数级 `var` 单例 → 每槽一个 trampoline**（`ApiKeyAuth.zig`、`CatalogPermDb.zig`）：
  第二次 `apiKeyAuth(A)`/`loaderFromClient(A)` 会覆盖第一次的配置，于是**用 B 的密钥能过 A 的
  路由**、A 的 loader 读 B 的库。红：`expected 401, found 200`。改成"槽表 + 原子领取 + 每槽独立
  函数指针"（裸函数指针不带上下文，闭包只能落在函数身份上），空槽 fail-closed，上限 64。
  顺带修掉一处**从未被实例化所以从未暴露的编译错**（`next(ctx, next, null)` 对单参 `HandlerFn`）。
- **CSRF 补 Origin/Referer 校验 + 常数时间比较**：带 `Origin`/`Referer` 时其 host 必须匹配
  `Host`/`X-Forwarded-Host`（scheme 与 `X-Forwarded-Proto` 一致），`null`/`user@host`/无 scheme
  一律拒；**不带这两个头时维持现状**（CLI/服务间调用不受影响）。红：`expected 403, found 200`。
- **CSP 注释与实现对齐**：`defaultSecurityHeaders` 仍然**不含** CSP（行为不变，注释改成说明原因）；
  opt-in 的 `securityHeaders()` 默认带一条硬化子集（`object-src 'none'; base-uri 'self';
  frame-ancestors 'none'`）。**注意**：`productionProfile` 内部就是 `securityHeaders(null)`，
  所以生产档位应用会开始收到这条 CSP（不含 `script-src`/`default-src`，不打断内联脚本）。

**web4**
- **先验签、后消费 challenge**：原先先 `verifyAndConsume` 再验签 —— 知道某 DID 未使用 challenge 的
  人发一个**签名无效**的请求就能把它烧掉（一次性挑战变 DoS 面）；消费失败与签名失败的 401 文案现在
  逐字节相同（不再泄露"该 DID 是否有有效 challenge"）。原子性未变（消费仍在 store 的 mutex 里）。
- **墙钟而非单调钟**：发票 `created_at`/`redeemed_at`/`deadline` 原用 uptime（重启后永久失真，
  还被当 Unix 时间发给客户端）→ 改用 `Time.wallClockSeconds(io)`（store 借 `sqlx.Client.io`；
  middleware 用 `ctx.io orelse store.io()`，合成 context 退化为 libc `clock_gettime(REALTIME)`）。
- **发票 id 用 `randomSecure`**（原先 `-{monotonicMs}` 同毫秒碰撞且可猜），重复 id 由 store 预检
  归类为 `DuplicateInvoice` → **402**（原先撞 UNIQUE 冒泡成 500）。顺带查明 sqlite 的 UNIQUE 违规
  报扩展码 2067 而驱动只比主码，所以"预期内的重复"必须预检才不会被记成 error 日志。

验证：全量 `-Ddb=all` **1667/1689（22 skipped，0 failed）**；`zig build check`/fmt/check-version/
deadcode 全绿；`examples/web4` 的测试（含新 strict 门 403 断言）通过；`examples/tenant-mgmt`、
`examples/zmsaas/backend` 构建通过。

**未做**：`X-Forwarded-Host` 的信任边界（需要 trusted-proxy 名单）；CSRF token 签名（会改 wire 形状）；
PG 抽干改用 `PQcancel`（需要新增 libpq 绑定）；游标路径对熔断器/指标"隐形"
（`queryCursorExPrimary` 不记 success/failure）；`queryScalar` 的 struct 分支仍是 `queryRow` 语义。

## [Unreleased]

### 协议面加固：HTTP/2 三条「未认证单包打崩进程」、HPACK UAF、sqlx 两条 P0、challenge 弱熵（**破坏性：否**）

一次"从没被审过的面"的深审（HTTP/2 / HPACK / sqlx / web4），每条都带实测探针或确定性红。

**HTTP/2 入站（h2 是 opt-in，但打开后这些都在鉴权之前执行）**
- **`SETTINGS INITIAL_WINDOW_SIZE` 越界 → `@intCast` panic**：线上 u32 直接窄化成 u31。红：喂
  `0x8000_0000` → `panic: integer does not fit in destination type` → ABRT。现在先校验（0 → 协议错，
  >2^31-1 → `FLOW_CONTROL_ERROR`）再窄化。
- **入站 DATA 超接收窗口 → u31 下溢**：全文件没有 `data_len` 与窗口的比较，一帧 `length=65536` 即可
  （**不需要该流存在**）。红：`panic: integer overflow` → ABRT；ReleaseFast 下会回绕成巨值 → 该连接流控
  永久失效。`consumeRecv` 改为可失败，连接级 GOAWAY / 流级 RST。
- **无入站 `MAX_FRAME_SIZE` 校验、无字节预算**：HEADERS + 4096×16 MiB CONTINUATION 可灌 ~68 GB 进
  `header_block`（`max_frames` 数的是帧不是字节）。现在：入站帧长按通告值拒、连接字节预算（64 MiB）、
  每流 header_block（64 KiB）与 body（8 MiB）上限、CONTINUATION 计数闸，超限 GOAWAY
  `ENHANCE_YOUR_CALM`。**红（真 socket）**：把校验去掉 → 一次 socket 会话就 `panic: integer overflow`。
- **通告了 `MAX_CONCURRENT_STREAMS=100` 却不执行**，且客户端流 id 未校验「奇数 + 严格递增」。
  红（真 socket）：去掉两个校验后偶数流照样被服务、第 101 条被接受。现在按通告值 RST `REFUSED_STREAM`
  / GOAWAY `PROTOCOL_ERROR`，并顺带堵住 PRIORITY 无界建状态。
- **测试**：10 条函数级 + **4 条真 loopback 端到端**（此前 h2 没有端到端用例），含「正常请求不被误伤」的
  反向断言。

**HPACK**
- **use-after-free**：`01` 分支引用的 name 指向动态表条目，而 `pushDynamic` 会淘汰并 free 它，之后再
  `dupe` 读的是已释放内存。**红**：探针回读 `0x55`（freed-fill）而非 `'s'`。修法：复制先于 `pushDynamic`。
- **Dynamic Table Size Update（`001xxxxx`）未实现** → 合规客户端（nghttp2）请求被拒。**红**：合法块
  `[0x20, 0x82]` 报 `InvalidHpack`。现在支持（超通告上限 → `InvalidHpackTableSize`）并提供
  `isConnectionError()`，**调用方改成连接级 GOAWAY**（`Http2Server` 两处，连带 1 条真 socket 用例）。
- Huffman 填充 >7 bit 现在拒绝（整字节 `0xFF` 结尾不再算合法）；`Header` 的所有权显式化
  （`name_owner`/`value_owner`），不再靠 ptr+len 指纹判静态。
- 共 18 条新测试，`Hpack` 19/19、`http` 面 177/177。

**sqlx**
- **读副本回退可无限递归**：副本失败为 `error.NotFound` 时熔断器不记失败 → 每层又选回同一副本。现在回退
  走 `queryPrimary`，不再重入 `readTarget()`；「可接受」的副本失败也会记一次。新增 3 条副本用例
  （其中 1 条专门覆盖 `NotFound` 分支——旧用例用 `ConnectionFailed` 掩盖了它）。
- **MySQL `batchInsertPrepared` 双重 `mysql_stmt_close`**：同一 `stmt` 上 `errdefer` 与 `defer` 并存，
  行数不符或 `mysql_stmt_execute` 失败（唯一键冲突）时双双执行 → double free。现在「sole owner，每条
  退出路径恰好 close 一次」。**注意**：该用例需要真 MySQL，本机是 **skipped**，实证只能靠 CI 的
  `Test (DB=mysql)`。
- 附带两条 P1：取消的池等待者不再丢掉已移交的连接（原先每发生一次池永久少一个槽位）；失败的
  rollback/commit 改为**丢弃**连接而不是放回池（下个借用者会继承 "transaction is aborted"）。

**web4 / 门禁**
- `challenge.zig` 用 `DefaultPrng.init(时间戳 ^ 指针)` 生成一次性挑战（同毫秒 + 同一 did → 同一个
  challenge，被截获的签名可在新窗口重放）。**红**：同一 did 两次签发得到相同值。改用
  `std.Io.randomSecure`（`issue` 的错误集因此多了 `EntropyUnavailable`/`Canceled`——仓库内唯一调用点用 `try`）。
- **门禁补上它漏掉的形态**：熵扫描与 audit b24 现在识别 **PRNG 播种**（`DefaultPrng`/`DefaultCsprng`/
  `Xoshiro256`/… 同行 `.init(`）。**红**：事故形状种回去 → `check-production` exit 1 并指名到行；
  还原后 OK。8 处合法用途（负载均衡挑节点、选举抖动、tracer id、测试夹具）以**逐行锚点**豁免——
  被豁免文件里新增一行弱种子**照样报**（已验证）。顺带说明为什么漏：`audit` 的 b 规则只走
  `<dir>/src/modules`，框架自身靠 check-production 的整树扫描，漏的是**模式表**不是扫描范围。

**顺带（同一批，独立小项）**
- `src/ai/actions.zig` 的第二份 `isValidIdentifier` 改为委托 `sqlx.validateIdentifier`（与 `business.zig`
  同口径；本地那份接受首位数字、无长度上限）。
- `src/messaging/OutboxConsumer.zig` 的 `topic_filter` 由字符串拼接改为**绑定参数**（`topic = ?`）：
  话题名带引号时旧写法直接产生语法错误 —— `sqlite3` 实测 `WHERE topic = 'ai.o'brien'` →
  `syntax error near "brien"`。新增一条注入回归用例（`ai.o'brien` 必须命中且语句完好）。

**明确未做（留给下一批）**：H1/H2 限额统一（需要 `Server.zig` 把 `max_body_size`/`header_limits` 传进
`ServeOptions`）；**H2 会话没有读超时**（连上不说话的 prior-knowledge h2c 连接会一直占一个处理线程，
需要决策加超时还是改 Server.zig）；HPACK 解压膨胀预算（`SETTINGS_MAX_HEADER_LIST_SIZE` 未通告）；
h2 仍缺"完整 dispatch 链路"的端到端用例（现有 4 条走内置 404 站点响应）；`web4/middleware.zig`
「先消费后验签」的顺序问题（同批 agent 给了改法但不在其文件白名单内）。

验证：全量 `-Ddb=all` **1645/1667（22 skipped，0 failed）**；`zig build check`/`check-version`/deadcode/
fmt/yaml 全绿；`zig build soak-cluster` 通过（RSS max 66 MiB，预算 128）。

## [Unreleased]

### 修 CI 红：`poll(&.{})` 在 Linux 上 EFAULT 直接 ABRT；`check-api` 在无 rg 的主机上失败（**破坏性：否**）

推 `93c4e18` 后 master 红了两个 job，两条都出在上一批改动里：

**① Ubuntu `Run tests`：`panic: reached unreachable code`（ABRT）。** 栈是
`RaftElection.sleepWithoutIo` → `std.posix.poll` 的 `.FAULT => unreachable` —— 也就是
**poll 返回了 `EFAULT`**。原因不是 poll 的语义，而是**空切片字面量的指针**：`poll(&.{}, ms)`
传的是一个零长数组字面量的地址，编译器可以把它物化成不可解引用的值（Debug 下是 `0xaa…`
的 undefined 填充），Linux 就此拒绝。macOS 不复现，容器里跑最小复现也不复现 —— 决定它的是
codegen，不是 API，这正是它的恶毒之处。

修法：**不再玩指针**。POSIX 目标下改用 libc `nanosleep`（无指针参数）；没有 libc 时用
**真实变量**的零长数组去 poll（那是栈地址，永远有效）；无 poll 的平台（Windows/WASI）
仍退化为 `yield`。验证：macOS 上那条崩溃的测试与全部 56 条 `Raft*` 通过；把修复后的测试
二进制**交叉编成 aarch64-linux 在 Debian 容器里跑**，同一条测试 `1 passed; 0 failed`；
三个交叉目标（x86_64/aarch64-linux-gnu.2.36、x86_64-windows）编译 exit 0。
**没能复现红**：用修复前的 HEAD 编同一个二进制在容器里跑，那条测试**通过** —— EFAULT 只在
CI 那次构建的 codegen 下触发，所以"先红"这一步只有 CI 的栈可作证，本地复现失败这一点如实记录。

**② macOS `check-api`：`error: ripgrep (rg) is required … not found on PATH`。** 上一批给
`if rg -q …` 加的前置守卫修掉了"缺工具就静默通过"，却把**没有预装 rg 的 macOS runner** 判红 ——
两种都不对。现在门禁**优先 rg、回退 `grep -Rn --include='*.zig'`，只有两者都不存在才失败**：
门禁要的是"真的搜过"，用哪个工具是实现细节。**红/绿都验过**：造一个含字面
`zigmodu.http_server` 的 fixture，有 rg 与无 rg 两条路径都 exit 1 并打出报文；清理后 exit 0。


## [Unreleased]

### zent 升到 v0.76.2：两个示例改 pin，并采用 0.76.0 的按驱动裁剪（**破坏性：否**）

`examples/zent-modulith` 与 `examples/metaverse-creative` 的 pin 从 v0.74.2 升到 **v0.76.2**
（commit `71a1a80a`），delta 里值得知道的四条：

- **v0.75.0 `junction_name_collision`（read-breaking）**：`junctionTableForEdge` 推导的
  `<a>_<b>` 若正好是某个实体声明的表名，两边都 `CREATE TABLE IF NOT EXISTS`、实体先建 ——
  联结表的 `CREATE` 成了 no-op，该边每次遍历都在**另一张表**上选列。以前 `checkSchema`
  报的是症状，现在报这个具名错误并归 read-breaking（`assertSchema(…, .read_breaking_only)`
  会拦住发布）；`migrateSchema` 只 `warn`，改名是调用方的决定。本仓库示例不涉及撞名。
- **v0.76.0 按驱动裁剪（已采纳）**：`b.dependency("zent", .{ …, .pg = false, .mysql = false })`
  让 zent 跳过未声明的驱动的 `translate-c`。`zent-modulith` 是纯 SQLite 所以关 pg+mysql；
  `metaverse-creative` 的 `src/db.zig` import 了 `zent.sql_postgres`，只关 mysql。关掉一个
  确实 import 的驱动会在首次使用时编译失败（`no module named 'pg_c'`）——fail-loud，不静默降级。
- **v0.76.1 三处 OOM 路径泄漏**（`Builder.initCapacity`/`takeQuery`/`Selector.init`）：
  同一种"前面的 `try` 已交出所有权、后面的 `try` 才失败"的形状，只在 OOM 时可见；消费方升级即得。
- v0.76.2 只修上游自己的 dead-code 门禁。

**验证（离线，用解开的 0.76.2 做 path 依赖）**：两个示例都构建通过；
`zent-modulith` 的 `zig build test`（该步含 43 项 smoke）**43/43 通过、干净退出无泄漏**；
`metaverse-creative` 的 `zig build demo` 端到端通过（`balanced=true outbox=1 …`）。

**没验到的两件事（如实）**：① 本机到 github.com 的 git/HTTPS 直连不通（`gh api` 那条约
通），所以**新 pin 的实际 fetch 没有跑过**——hash 是用 API 取到的同源 tarball 算的，而
这个方法先用 v0.74.2 校准过（复算值与仓库已 pin 的 hash **逐字节相同**）；② 按驱动裁剪的
收益在本机**测不出来**：关掉两条 translate-c 是 763 MiB / 80 s，默认是 723 MiB / 82 s ——
省下的两条与 SQLite 那条（~597 MiB）**并行**，各 ~23 s / 30 MiB，只有它们在某些主机上成为
主项时才明显（上游给的数是每驱动 ~26 s / ~590 MB）。示例里保留了这两个选项，因为它表述的是
"这个示例链哪些驱动"这一事实，而不是因为在本机量到了收益；注释与 `docs/ZENT.md` 都按实测写的。


## [Unreleased]

### HTTP 服务端加固：长响应头曾静默丢整个响应、body 阶段零超时、读错误被吞（**破坏性：否**，行为修复 + 两个新配置/错误值）

四件事，前两件可被远程触发：

1. **响应头 256B 栈缓冲 → 静默丢响应。** `writeResponse` 用 `line_buf: [256]u8` + `bufPrint`
   逐行拼头，任何头行超长就抛 `NoSpaceLeft`，冒到调用点只打一行日志然后 **关连接**——
   客户端收不到一个字节。触发链是现成的：CORS 把请求 `Origin` 原样回显，而
   `*.example.com` 后缀匹配允许任意长前缀。现在状态行/头/`Content-Length` 全走
   `w.interface.print`，并给单值加了 **8 KiB 上限**（超限明确报 `error.HeaderTooLarge`；
   若绕过 API 直写 header map，则回 **500** 而不是丢连接）。
2. **`setHeader` 不校验 CR/LF。** query/form 值会 percent-decode，`%0d%0a` 于是成为真
   CR/LF ——handler 把请求值塞进响应头就是响应拆分。现在集中校验（名字 `1*tchar`、
   值禁 `\r`/`\n`/`\0`），非法返回 `error.InvalidHeader`。
3. **body 阶段没有任何 deadline**（header 一读完就解除），`Content-Length: 8M` + 每秒
   1 字节可无限占连接。新增 `Config.body_timeout_ms`（默认 **30 s**，`0` 关；
   `HTTP_BODY_TIMEOUT_MS` 可覆盖），在空行处 re-arm 而不是清除；超预算回 **408**。
4. **读错误被吞成 0 字节 → 静默关连接。** `readAll` 把 `EndOfStream` 与 `ReadFailed`
   都返回 0，调用点报 `IncompleteBody`，而连接循环对该错误**直接 return（不发响应）**。
   现在 `ReadFailed` 保真：超时/读失败 → **408**，对端半关且 body 不足 → **400**，
   两种都有响应可观测。顺带 `jsonStruct` 改为直接写进 `self.response_body`
   （`Writer.Allocating.fromArrayList`），省掉每请求一次分配 + 一次全量 memcpy。

**红→绿**：7 个新用例在修复前全红（`expectError(error.InvalidHeader, …)` 拿到
`NoSpaceLeft`；`readAll` 读失败返回 0；半截 body 用例断言"有响应"失败；stalled body
用例断言 2 s 内返回失败；`jsonStruct` 分配数断言失败），修后 `api.Server.test.` **69/69**、
`api.` 166/166、`http.` 149/149，且既有的逐字节响应断言（`{"ok":true}`、Unicode、转义）
原样通过。端到端：`zig build integration` OK、zent-modulith smoke **43/43 干净退出无泄漏**。

**行为变化（需知悉）**：`body_timeout_ms` 默认 30 s 让慢上传（8 MB 需持续 ≥ ~270 KB/s）
从"无界"变成 408——要旧行为设 `0`；`setHeader` 新增 `error.InvalidHeader` /
`error.HeaderTooLarge`（`!void` 签名未变）；半截 body 从静默关连接变成 400 + warn。

### HTTP 客户端与静态文件：chunked 解帧是 O(n²)、请求头逐行分配、大文件整份驻留内存（**破坏性：否**，行为修复 + 一处行为变化）

- **chunked 解帧换 `std.http.ChunkParser`**（`HttpClient.streamChunkedBody`）：旧实现用
  `carry` 缓冲每块 `copyForwards` 前移剩余 + `resize`，**量化**后是 96 KiB 报文、
  16 KiB payload 下 `memmove` **134,201,346 字节 = payload 的 8191 倍**、CRLF 重扫 4099 倍；
  新实现只拷尺寸行（每块约 3 字节），payload 零拷贝。带一条严格度还原的校验
  （`ChunkParser` 把 `A-Za-z` 当十六进制位）。新增用例：64×8 KiB 流式与缓冲两条入口
  结果一致、16384×1 B 单读窗、以及 4 类畸形帧必须报错。
- **请求头零分配**：4 处 `allocPrint` + `defer free` 换成 `w.interface.print`；该函数签名
  去掉了 `self`，**函数体内已无 allocator 可达**——每请求 N+2 次分配在编译期无法回归。
- **静态文件大响应改流式**（`StaticFiles`）：超过 chunk 阈值的 `GET` 走
  `startChunked` + `writeChunk`（不再把整份文件读进 `response_body`，1 GB 文件不再等于
  1 GB 峰值）；`HEAD` 恒不走 chunked 所以 `Content-Length` + 空 body 语义不变；
  `Range`/416/`Content-Range` 不变。
- **顺带修掉的真缺口**：`HttpClient.readResponse`（非流式的 `get`/`post`）**从不认
  `Transfer-Encoding: chunked`**，会把分块帧当 body 返回乱码——静态文件改成 chunked 后
  框架自己的客户端就会踩到。现在两个入口共用同一份解码器。

**行为变化**：超过 chunk 阈值的静态响应不再带 `Content-Length`（RFC 7230 禁止 CL 与 TE
共存），不认 chunked 的 HTTP/1.0 客户端对大文件应改用 `HEAD`/`Range`；chunked 尾部
（空 trailer 之外的 trailer、缺末尾 CRLF）现在会报错——旧实现把残留字节留给池中连接的
下一个响应（静默错位）；`chunk_bytes = 0` 从"静默返回空 body"变成 fail-loud。

### 并发加固：`stats()` 的跨线程裸读（UB）、supervisor 锁快路径、pooled `join()` 无界自旋、RaftLock 烧核（**破坏性：否**，行为修复）

- **`Handle.stats()` 跨线程读 4 个非原子字段**（`thread`/`joined`/`errors_in_window`/
  `stopped_by_supervisor`），写者之一是 `join()`——跑在 `Runtime.shutdown` 的线程上。
  **TSan 红→绿**：修复前的副本上 `ThreadSanitizer: data race`（`runtime.zig:895` 写 vs
  `:816` 读），修复后干净。`thread` 是结构体不是指针（`std.atomic.Value(?std.Thread)`
  编译不过），所以新增 `thread_live: std.atomic.Value(bool)` 与它在同两条语句上翻面，
  取值与旧 `thread != null` **逐点等价**（含 `join` 中的微窗口）。`errors_in_window`
  的写者全在 worker 自己线程上、无残留非原子写；`stopped_by_supervisor` 改原子后
  `countSupervisedStop` 的 release/acquire 发布关系不变（反而更强）。
- **supervisor 锁快路径 `swap` → `cmpxchgWeak` + 32 轮后 `Thread.yield()`**（照仓库
  `core/SpinLock.zig` 的形态）；微基准（4 线程 × 40 万次加锁）**73–97 ns → 25–34 ns**。
- **pooled `join()` 从无界自旋改为有界**：前 1024 轮 `spinLoopHint`（覆盖常规的批次
  hand-back，微秒级、无系统调用），之后每 **1 ms** `std.Io.sleep` 轮询同一谓词。
  实测：handler 持有 claim 150 ms 时，等待者自身 CPU **140,898 µs → 976 µs（~145×）**；
  `runtime-stress` 整机停机 49 ms。代价是谓词翻转后最多晚 1 ms 返回。
- **`RaftLock` 三档等待**（`RaftElection`）：`swap` 无界自旋 → `cmpxchgWeak` 快路径 →
  32 轮自旋 → 128 轮 `yield` → 每轮 1 ms 的 `std.posix.poll(&.{}, 1)` 睡眠。该文件拿不到
  `io`（`ClusterBootstrap` 有 `io` 但从不传给 `RaftElection`，且要改 15 个入口/约 30 个
  调用点），所以用 poll 而不是 `std.Io.sleep`；Windows/WASI 无 `poll` 时退化为 `yield`。
  实测持锁者睡 120 ms 时等待者 CPU **120 ms → 0 ms**（单 `yield` 无用：仍是 116 ms，
  因为持锁者在等 syscall、`yield` 立刻返回）。新增两个用例：慢 RPC 下等待者 CPU 上界、
  互斥与 `isHeld` 语义；`soak-cluster` 全绿（≤1 ms 交接延迟可接受）。

### CI 与构建加固：两个门禁可能"因工具缺失而变绿"、测试步骤无超时、夜间从不跑并发 harness（**破坏性：否**）

- **`check-api` 的 `rg` 缺失会静默通过**（`if rg -q …` 退出 127 → 假分支 → 步骤成功，
  `2>/dev/null` 还把报错吃了）。加 `command -v rg` 前置检查——实测：`rg` 不可见时
  exit 1 + 明确报错（旧写法等效片段返回 0，即原缺陷）。
- **测试步骤统一 `--test-timeout 300s`**（5 处），并给 `build-and-test`/`lint`/`examples`/
  `integration-full`/`test-postgres`/`test-mysql`/`test-live-services`/`benchmark` 补
  `timeout-minutes`；`test-postgres` 原本是**裸 `zig build test` 且无 job 超时**（挂住可烧
  6 小时、无日志），现在走 `ci-run-logged.sh` 并上传日志 artifact。
- **失败 artifact 从整个 `.zig-cache/` 收窄为日志**（前者体积大、不可读，白烧 10 GB 配额）。
- **夜间 job 补上从未跑过的并发 harness**：`zig build soak-cluster`（raft 选举/复制 +
  总线不变量）、`zig build runtime-stress -Druntime-stress-duration-ms=60000`、以及有界
  fuzz `zig build test --fuzz=2000`（不给上限会开 webui 永久运行；与 `-Dtest-filter`
  互斥是设计使然）。这三个只挂 `schedule`/`workflow_dispatch`，不加
  `continue-on-error`（那正是"隐藏失败"）。
- **`soak-cluster` 的 RSS 预算重校准（128 MiB，CI 显式给 192）与一条未结发现。** 把它接进
  CI 时它在本机红了，追下去是两件事：① 这个断言的默认 64 MiB 在本机**本来就在边缘**——
  用 `f00269a`（本批次之前的 HEAD）建 worktree 对照，**未改动的树** 2400/写者跑三次是
  42 / 63 / 70 MiB，确实能过但余量很薄；② 把流量翻倍（4800/写者）后**基线与本树都失败**
  （基线 12→108 MiB、本树 11→163 MiB 且仍在涨），说明**增长随流量线性、且早于本批次存在**，
  而每一轮 `std.testing` 的泄漏检查都是 `0 leaked` —— 所以这个指标量到的是**分配器页驻留**，
  真正的泄漏门禁是那条 `0 leaked`。因此默认值抬到 128 并写明标定数据，CI 里显式给 192
  （Linux runner 的分配器行为不该是掷硬币）。**未结部分**：同样 2× 流量下本树比基线多约
  +55 MiB，二分测试给不出干净归因（单独加 runtime/supervisor 是 34 MiB、单独加
  `RaftElection` 是 74 MiB，都在基线自身的 42–70 波动范围内），需要堆剖析才能定论。


### 跨编译可带 sqlite：`SQLITE_INCLUDE` / `SQLITE_LIB` 覆盖 + 跨编译口径落文档（**破坏性：否**）

`examples/_shared/db_link.zig` 原先只给 postgres/mysql 留了环境变量覆盖，sqlite 是裸
`linkSystemLibrary("sqlite3")`——于是跨编译任何带驱动的目标都直接
`unable to find dynamic system library 'sqlite3' using strategy 'paths_first'`
（探测逻辑是主机的，Zig 不会去目标 sysroot 找；CI 的 windows-cross job 因此只能
`-Ddb=none`）。新增 `detectSqlitePaths`，与 pq/mysql 对称：`SQLITE_LIB`（必需）+
可选 `SQLITE_INCLUDE`。

**端到端验证**（不是只读代码）：从容器里的 aarch64 Debian 取出真
`libsqlite3.so.0.8.6` → `SQLITE_LIB=… zig build -Dtarget=aarch64-linux -Ddb=sqlite`（musl，
Zig 对 aarch64-linux 的默认 libc）与 `-Dtarget=aarch64-linux-gnu.2.34`（glibc）双双成功；
再用真用库的 `examples/tenant-mgmt` 交叉编译，在目标容器里 `ldd` 确认
`libsqlite3.so.0 => /lib/aarch64-linux-gnu/libsqlite3.so.0`。证伪侧：`SQLITE_LIB` 指向
空目录时错误信息里的 searched paths 正是 `<dir>/libsqlite3.so` / `.a`（证明变量确实进入
搜索，不成功是因为那里没有库）。

**顺带记录两个坑**（写进 `docs/SQLX_DRIVERS.md` §12）：① glibc 目标不写版本会得到
一屏 `undefined reference: …@GLIBC_2.34`（Zig 的 stub 比库旧），补 `.2.34` 即通；
② 没被程序引用的依赖会被链接器丢掉——对 `examples/basic` 用 `-Ddb=sqlite` 交叉编译会
"成功"但 `ldd` 里没有 sqlite，验证要用真用库的示例。

**§12 同时落了跨编译内存口径**（本机实测、每档独立冷缓存）：Debug 266 MiB / 热缓存
31 MiB / ReleaseSmall 419 MiB / ReleaseSafe 858 MiB / ReleaseFast 862–892 MiB，而原生
全量 `test` 编译约 1 GiB。结论是**决定内存的是 `-Doptimize=` 而不是"跨"**，跨编译不要走
`test`（跨目标也跑不了），受限机器用 `-j2 --maxrss 1G --skip-oom-steps`；`-fincremental`
是拿内存换重编速度，不省内存。

## [0.33.1] - 2026-09-23

### 新增审计规则 b24（弱熵源）+ 修掉它抓出的 `DistributedLock` 缺陷（**破坏性：否**）

- **规则**：`zmodu audit` 新增 b24——`std.Io.random` / `std.crypto.random` 是禁用熵源
  （前者失败会回落到 pid + 墙钟 + ASLR，正是 AGENTS.md「CSPRNG」那条禁的缺陷类；
  后者本工具链根本没声明）。合规写法是 `std.Io.randomSecure(io, buf)`。b24 只扫
  `src/modules/**`（应用代码），框架自身的 `src/` 由 `check-production.sh` 新加的
  第三趟扫描兜底——**不分 ratchet 层、一个命中即 exit 1**。
- **它抓出的真缺陷**：`src/core/DistributedLock.zig` 用 `std.Io.random(io, &seed)`
  生成锁 owner id。弱熵 ⇒ 两个副本可能算出**同一个 owner** ⇒ 双方都通过
  `SELECT owner` 的"可重入"判定进入临界区，而 `release` 是
  `DELETE … WHERE name = ? AND owner = ?`，于是**一个副本会释放另一个的锁**。
  改用 `randomSecure`（`init` 已是 `!Self`，全部调用点已 `try`）。
- 验证：把 HEAD 版该文件放回同结构仓库跑同一脚本 → `check-production: banned entropy
  source … :105` exit 1；当前树 exit 0。`audit.zig` 单测 12/12；`SqlLock` 用例 3 通过
  1 跳过（跳过的是 PG 门控用例）。
- 门禁口径差异（已写进 AGENTS.md 与 BEST_PRACTICES）：b10 的豁免是**整行子串匹配**，
  而 `zig build check` 的 hot-path catch 扫描**不豁免 `errdefer`/`rollback`/`sendError`、
  也没有 ignore 标记**——照 b10 的豁免写法写在生产代码里会红 CI。

### 表名标识符闸门接到 ai / web4 的 SQL 入口（**破坏性：否**）

`src/ai/approval_store.zig`、`src/ai/run_audit.zig`、`src/web4/x402_store.zig` 的每个
会拼接表名的 SQL 入口（`migrate`/`push`/`listPending`/`resolve`/`count`/`record`/`list`/
`create`/`redeem`）在函数首行过 `sqlx.validateIdentifier`；`src/ai/business.zig` 的
`isValidIdentifier` / `isPlainIdentifier` 收窄为它的严格子集（`[A-Za-z_][A-Za-z0-9_.]*`、
≤128；`isPlainIdentifier` 另拒 `.`）。这不是装饰性校验：`Client.exec` 本身不校验，
PG 无参路径走 `PQexec`（libpq 简单查询会执行整串多语句），所以表名里带 `; DROP …`
在 Postgres 上是真能落地的。错误名仍为 `error.UnsafeSqlIdentifier`（`business.zig`）
/ `error.InvalidSqlIdentifier`（新闸门），调用方全是推断错误集、无需改动。

验证：三个模块的新测试断言每个入口都返回 `error.InvalidSqlIdentifier`；全量
`-Ddb=all` 通过；反例侧已核「闸门非摆设、入口无遗漏、默认表名不误拒、无泄漏」。

### `docs/dev/README.md`：内部文档索引（**破坏性：否**）

给 `docs/dev/` 的 22 份评审/评估/路线草稿加了索引：哪些仍生效、哪份被哪份取代、
哪些路径被源码按字面引用（不能改）。`docs/README.md` 已链接它——**提交时必须同时
`git add`，否则干净 clone 里是断链**。


### DLQ 自身无锁：并发 `push` / `purgeExpired` / `requeue` 是纯竞态（**破坏性：否**，行为修复）

失败路径最终汇入的 DLQ 一直是**裸 `ArrayList`**，而后台 retry fiber 每秒 `purgeExpired`
+ `requeue`（回调又会经 `publish → fanOut → 失败 → push` 重入队列），业务线程同时在
`push`——三方共碰同一个 list。**红是 100% 复现**：并发 push + retry 10/10
`Segmentation fault at address 0xaa…`（栈 `purgeExpired → Allocator.free`，free 到已
poison 的指针）；并发 push 淘汰上限 10/10 `panic: remap after remap`（append 撕裂 list
元数据）；另有一条私有副本契约测试确定性失败（`expected 0, found 8`——调度出去的
slice 指针就是队列内的原 slice）。

修法：DLQ 内加 `SpinLock`（沿用仓库既有 `core.SpinLock`；九个入口全是 io-free，换
`std.Io.Mutex` 需要先给全部入口加 `io` 参数、属 API break，未做）；`push` 的长度判断
+ 淘汰 + append 收进同一临界区；`requeue` 在锁内**只取一条并把它 dupe 成私有副本**，
**解锁后**才调回调；`stats` 不再内部调 `size()`（会二次加锁自死锁）；日志与
`freeEntry` 移到锁外。**回调必须锁外**在模块头文档化——回调路径会经 `fanOut` 取
`nodes_lock`，持 DLQ 锁调用就是自死锁 + 跨线程 ABBA。

验证：新并发测试（账目守恒 `pushed - purged == size`、每 id dispatch ≤ `max_retries`、
淘汰后 `size == max_size`）修复后 10/10 绿、整文件 3 轮全绿；`zig build check` OK。

### 总线节点注册表：同 id 并发 connect 双记录、`deinit` 无锁拆除、遍历期被 realloc（**破坏性：否**，三处并发修复 + 一个新 API）

注册表上一轮拿了 `nodes_lock`，但还有三个窗口：

**① 查重与 dial 之间的窗口**：dial 前扫到"没有这个 id"、dial 之后才登记，四个并发
caller 会各建一条记录（各带自己的 `write_lock`，per-node 串行化前提被破坏）。改为
「锁内占位（`reserveNode`，带 reservation token）→ 锁外 dial → 锁内按 token 裁决
（`settleConnect`）」；已有条目（连上的或别人正在 dial 的）直接返回不拨号。**红是
确定性的**：回滚后 `expected 1, found 4`（连跑两次同结果），第二条测试
`expected 1, found 0`。

**② `deinit` 无锁顺序拆除**：新增 `tearDownRegistry`（锁内整表摘下，出锁后逐条
`destroyNode`），锁取不到时**选择泄漏而不是二次释放**并记 error。**红**：测试握着
`nodes_lock` 断言拆除线程 200ms 后仍未结束，回滚后 `FAIL (RegistryTornDownUnderItsLock)`。

**③ `getConnectedNodes()` 无锁交出内部数组**，而 gossip 线程的 `connectToNode`
（append realloc）/`disconnectNode`（take+destroy）会移动/释放它——任何"边走边用"
的调用方都在读悬垂内存。新增 `snapshotNodes(allocator) !NodeSnapshot`：锁内整份拷贝
（`id`/`address`/`connected`/`send_failures`），元素归调用方、`deinit()` 释放，锁内
不做 I/O/回调/free（**不选锁内 visitor**：`fanOut` 已证明锁内跑回调会 park 整个注册表，
且 `Io.Mutex` 不可重入，回调再进 bus 就是自死锁）。**红是确定性的**：用旧 API 压力
测试 → `Segmentation fault at address 0xaaaaaaaaaaaaaaaa`（testing allocator 的
已释放填充值），即读到了被 take/realloc 的条目。`getConnectedNodes()` 保留但文档改成
醒目的「不安全、仅调用方自保独占时可用」，`docs/API.md` 同步。

**④ 顺带修掉一条既存缺陷**：`connectToNode` 的 outbound 握手没有 `authEnabled()`
守卫，于是**一个凭据都没配**的 dev/单机集群里，每条成功 dial 都被
`bindOutbound` 以 `PeerKeyMissing` 丢弃——"只能收不能连"，且 `sendEventFrame` 的裸帧
分支永远不可达（与同一函数 dial 前的守卫、与 `cluster-identity-design.md` §5 的格
自相矛盾）。改为与入站侧逐字对称的 `if (authEnabled())`；**有凭据路径一条未放宽**
（dial 前拒绝、握手不应答/MAC 不对仍关连接，均有测试）。**红**：`warn … refused the
handshake: error.PeerKeyMissing` + 断言 `socket != null` 失败。

验证：`DistributedEventBus` 44/44、`ClusterMembership` 11/11、
`DistributedIntegrationTest` 11/11；`zig build check` OK；`zig build soak-cluster`
18/18 流全量、**0 leaked**（约 470 次快照取用，漏一个 `deinit` 就会被抓）。
soak harness 已迁到 `snapshotNodes`（每处 `defer snap.deinit()`，快照失败计入
`harness_internal_failures` 而不是被当成"没有 peer"）。锁序仍为
`nodes_lock → Node.write_lock`，另有既存的 `nodes_lock → DLQ.lock`（反向由 DLQ
在锁外调回调避免）。

**既知遗留**：`getNodeCount()` 仍是无锁"移动中的数字"（不暴露指针，最坏是过期计数）；
`deinit` 与"另一线程仍在 bus 内"并存仍是契约违规（其余字段无锁且结尾 `self.* = undefined`）；
混配集群（我方无凭据、对端有凭据）按硬切不支持处理，表现为对端关连接 → `send_failures`
涨到阈值进 DLQ。

### 总线三条并发遗留：并发断连 double-free、出站无发送超时、`send_failures` 丢计数（**破坏性：否**，行为修复 + 一处 API 形状微调）

上一轮把 per-connection 写路径收敛成了「同一 fd 只关一次」的漏斗，但节点注册表本身还在裸奔。三条一起来：

**① 并发断连同一节点会 double-free**（`self.nodes` 的 `free(id)` + `swapRemove` 无锁）。
容器元素改为堆分配 `*Node`（条目地址稳定，摘除不再搬动邻居，也不让在途写者持有的
`write_lock` 变成另一份拷贝里的另一把锁——FIX2b 的保证因此保住），新增 `nodes_lock`，
固定锁序 **`nodes_lock` → `Node.write_lock`**；新增 `takeNode`（锁内摘除哈希环与条目，
交给唯一调用者）/`destroyNode`（**锁外** close+free），`disconnectNode` 只做
take→log→destroy。所有遍历（`fanOut`/`sendHeartbeat`/`setPartitioner`/connect 查重）
进临界区，顺带修掉 `disconnectNode` 里「先 free 再用 id 做哈希查找」与日志行 UAF。
**红→绿**：把 `disconnectNode` 还原成旧形状 → `panic: double free of … len 3`（"dup"，
即 node.id），恢复后 16 轮 × 8 线程并发断连测试稳定绿（断言节点表最终为空、重复断连
为 no-op）。

**② 出站 socket 没有发送超时**，teardown 会等写锁 ⇒ 对端既不收也不关就能把
`disconnectNode`/`deinit` 一起拖住。新增 `outbound_send_timeout_ms`（默认 5s，
`applySendTimeout` 镜像 `applyRecvTimeout` 的「失败只 warn」），并**必须同步**把
`sendEventFrame` 的写从 std writer 换成 `sockread.writeFull`——因为 `SO_SNDTIMEO`
到期返回 `EAGAIN`，而 `std.Io.Threaded.netWritePosix` 把它判成 OS bug（Debug 直接
panic）；`writeFull` 映射成 `error.WriteTimeout`，正好落进既有失败路径
（计数→跨阈值 DLQ→隔离）。**红→绿**：还原成 std writer → `panic: programmer bug
caused syscall error: AGAIN`；换回后新测试（对端不读、256KiB 帧、200ms 界）3s 内
返回 `WriteTimeout`。

**③ `send_failures` 非原子 + DLQ 重复入队**：改成 `@atomicRmw`，并用其**返回值**做
一次性转移凭据（只有把计数从 `max-1` 推到 `max` 的那次返回 true）——此前每个
≥ 阈值的线程都会推一次 DLQ 并各关一次 socket。**红→绿**：旧形状下 200 次并发失败
只记到 182 次（丢 18），恢复后断言计数恰好 200、crossing 恰好 1。

验证：`DistributedEventBus` 全文件 **37/37** 通过（会话内 3 次稳定）；`zig build
check` OK；`zig build soak-cluster` 端到端 **1 通过 / 零丢帧**（18 条 (dest,src,writer)
流全 2400/2400，leader 在位 100%，fd 23→23），耗时 1m21s 与改动前相当——扇出串行化
（见下）没有伤到吞吐。

**知悉的权衡与 API 形状**：`fanOut` 持 `nodes_lock` 跨越阻塞写，所以同一 bus 的
publish 扇出现在互相串行、connect/disconnect 会等一次扇出（有 5s 发送超时兜底）；
要收窄需 per-node 认领/引用计数或 hazard pointer。`getConnectedNodes()` 返回类型变为
`[]const *Node`，`connectToNode` 错误集新增 `error.NodeRegistryLockUnavailable`
（仅取消时出现）；仓内无 src 之外的调用方，soak 与全部测试已适配。
**仍未修（不在本文件）**：`DLQ.zig` 自身 `entries` 无锁（并发 purge/requeue 仍纯竞态）；
`deinit` 仍依赖 stop 后单线程；`connectToNode` 查重与 dial 之间仍有同 id 双记录窗口。

### 总线 teardown 收敛到单一漏斗：断连与写入曾可并发关同一个 fd（**破坏性：否**，行为修复）

上一条修的是「盖章在锁外」导致的**静默丢帧**，但 teardown 侧还有第二条同族缺陷：
`recordSendFailure` / `disconnectNode` / `deinit` 关 socket 时**不取 per-connection
写锁**，而且 `recordSendFailure` 用的是 `sendToNode` 早先读到的 **handle 快照**。于是
两个并发失败者会对同一 fd 关两次（第二次若 fd 已被复用就静默偷走别人的 fd），
`disconnectNode` 更能在 `sendFramed` 正持锁 `writeAll` 时把 fd 关掉。

**这次有确定性红**：8 线程并发 `sendToNode` + 死 peer + `max_send_failures=1`
→ **3/3** `panic: programmer bug caused syscall error: BADF`
（`netWritePosix ← drain ← sendEventFrame ← sendFramed ← sendToNode`，
`process terminated with signal ABRT`）——某线程正在写、另一线程把 fd 关了。

修法：新增 `takeNodeSocket`（锁内取 handle → 置 `node.socket = null` → 解锁返回）与
`closeNodeSocket`（拿到 handle 的那个调用者**在解锁之后**才 close），所有 teardown
路径经此漏斗；`sendToNode` 只保留 `node.socket != null` 的只读判断，`recordSendFailure`
不再接收 handle 快照。同一 fd 只有一个所有者，且关闭不与写入并发。

验证：契约测试（持锁模拟写临界区 + teardown 必须等待；teardown 漏斗把每个 socket
交给恰好一个调用者，含「fd 号被新连接复用后重复 teardown 不得碰它」的 stale-handle
场景）；`DistributedEventBus` 全文件 34/34 通过。**残余风险（如实）**：teardown 现在
会等写锁——若某次出站 `writeAll` 永久卡住（出站 socket 没设 `SO_SNDTIMEO`），
断连/关机也会跟着卡，正解是给出站加发送超时；`disconnectNode` 对 `self.nodes` 的
`free` + `swapRemove` 仍无锁，**并发断连同一节点**的 double-free 属另一条既存缺陷，
不在本次范围。

### `Server.stop()` 改成唤醒式：跨线程关 listener fd 会踩 `accept4` 的竞态窗口（**破坏性：否**，行为修复）

`stop()` 原实现从调用线程直接 `shutdown` + `close` listener fd，与 accept 循环并发踩同一
fd。两个平台各有各的坏法：Linux 上 close 唤不醒驻留的 `accept`（上一版已用 shutdown 缓解），
macOS 上则是在 `while (running)` 检查与进入 `accept4` 之间那个 ~100ns 窗口——stop 恰在此
刻拆完 fd，新的 `accept4` 在已关闭 fd 上启动，`std.Io.Threaded.netAcceptPosix` 把 `EBADF`
归类为 `errnoBug`，Debug 下直接 panic（发生在 std 内部，Server 层捕不到）。

现在 `stop()` 只做两件事：置 `running = false` + `wakeAccept()`（`shutdown(SHUT.RDWR)`
唤醒 Linux 驻留 accept，再向实绑端口自连一个真实连接唤醒 macOS/BSD 的 accept）；
**fd 只由 accept 线程自己在循环退出后关闭**。accept 成功后若 `running == false`（stop 落在
迭代中途，或就是那个唤醒连接）则关闭该连接并退出，唤醒连接不进 dispatch。

回归测试：停驻 accept + 跨线程 stop + join 的契约测试，以及 8 线程连接洪水下 15 轮
start/churn/stop 的竞态压力测试。**如实说明**：修复前本机无法确定性复现该 panic（是抢占
窗口竞态，本机 Darwin 对驻留 accept 返回可捕获的 `ECONNABORTED`），两个测试守护的是
停止契约与竞态形状，不是「修前必红」。

验证：`zig build test -Dtest-filter="api.Server"` → 59/59 通过（含 2 条新用例）。

### 总线同 socket 并发写者：seq 盖章在写锁外，导致偶发静默丢帧（**破坏性：否**，行为修复）

per-connection `write_lock` 早已存在（防的是帧内字节交错），但 replay `seq` 是在**锁外**
盖的章——`publish` 先 `nextSeq()` 再序列化，然后才竞争写锁。于是两个并发发布者的
「盖章顺序」≠「上锁写入顺序」，低 seq 帧可能晚于高 seq 帧上线；接收侧 `acceptSeq` 要求
per-claim 严格递增，把晚到的低 seq 帧当重放以「not ahead」丢弃——流不坏、连接不断，
**静默丢一帧**（soak 实测 ~1/15）。

修法：`sendFramed` 改为在锁内完成「盖章 → 序列化 → MAC → 写入」，`publish` / `sendHeartbeat`
不再共享预渲染 json，逐 peer 传入 `(topic, payload, timestamp)`；`node.socket` 存活检查
一并进锁，顺带消掉 stale-fd 写入窗口。

红→绿证据：新回归测试（socketpair 真实握手 + 双线程 publish，接收侧断言 seq 严格递增且
payload 集合恰好 0..1999）在修复前 **10 轮 9 红**（`seq gap at delivery 169` 同形诊断）；
把盖章移回锁外的变异 **6/6 红**；修复后 13/13 绿、`DistributedEventBus` 全文件 32/32 绿。
注意 wire seq 现在 per-peer 非连续（计数器还被本地分发与其他 peer 消耗），协议契约是
「严格递增 + 不丢帧」，测试按此断言。

### comptime 泛型合并陷阱：参数只被 discard 时，所有实例化会 memoize 成同一个类型（**破坏性：否**，行为修复）

本 Zig 版本（0.17.0-dev.2151）实测：`fn Impl(comptime slot: usize) type` 里若参数只被
`_ = slot;` 丢弃，则 `Impl(0) == Impl(2)` 为真，**容器级 static 跨实例共享**——编译通过、
静默错绑。全仓库 77 个返回 `type` 的泛型工厂排查后命中两处：

- `RaftTransport.TransportImpl(slot)`：其注释声称 per-slot static 派发，实际会被合并，
  同进程多 raft transport 实例互相踩。已在类型体内加承载性引用（`pub const slot_id = slot`）
  并更正注释；回归测试直接断言 `TransportImpl(0) != TransportImpl(2)`（修复前 FAIL）。
- `data.CrudService.CrudEvent(Entity)`：同形状（`CrudEvent(A) == CrudEvent(B)`），今天不会
  出错（union 载荷本就不含 Entity），但按类型隔离的行为将来会静默失效。同样加承载 decl
  + 断言测试。

其余 75 个工厂经机检 + 人工复核确认安全（参数真实进入返回类型字面量即不触发）。精确
判据：**参数是否被返回的类型字面量捕获**——工厂体内的 `guard`/日志不算，方法体内引用不算
（那种也不会合并）。

### CI 的 benchmark 基线可自刷新：新增候选 artifact 通道（**破坏性：否**）

`scripts/bench-baseline.ci.json` 落后于套件（本轮新增的两个指标在 CI 上只会 WARN，且该
文件没有 `max_alloc_per_op` 字段，alloc 判据在 CI 上完全不生效）。仓库纪律又不允许 blanket
`--update`（会把当日 runner 速度烤进 ratchet，还丢 `note`）。现在门禁 run 在
`BENCH_UPDATE_MISSING_OUT` 指向路径时额外写一份**合并候选**：既有条目逐字保留（含
`note`/预算），只追加基线不知道的指标与待填 ratio；CI workflow 用 `upload-artifact` 在
**绿跑**时上传（红 run 不上传，避免用失败数据当 ratchet 材料），维护者下载 diff 后提交即
闭环。verdict 逻辑零改动。

验证：本机两条路径都跑过——默认基线 + env → 门禁仍 OK、artifact 与本地基线逐字节相同；
刻意用 CI 基线跑 → 预期红（aarch64 的 `RingBuffer SPSC`），artifact 仍按设计产出。

### benchmark  suite 补两个缺口 + `alloc/op` 从"只打印"升级为门禁判据（**破坏性：否**，CI 判据新增）

- 新增两个 bench 指标：**MPSC 多生产者 push**（`MpscRing 4P x2M`，4 个生产者游标
  轮流推共享环，满则 inline drain）与 **`after()` 定时器调度路径**（`Timer after x100K`，
  caller 侧 `Delivery` 分配 + 命令环 push、owner 侧 tick 排空 + 轮插，Manual 时钟自举
  不启 Runtime）。套件从 30 → 32 个 gated 指标。
- `[alloc]` 段从 9 个指标扩到**全部 32 个**；`scripts/bench-baseline.json` 每条新增
  可选 `max_alloc_per_op` 预算（当前实测值 +25% 余量，结构性零分配的指标配 0.00），
  `scripts/check-bench.sh` 对声明预算的指标超限即判红。以后任何 PR 在热路径引入
  隐藏分配都会直接挂门禁。
- 顺带修了一个 LLVM 特化翻转导致的度量失真：`CircuitBreaker` 镜像计时循环曾被编译器
  优化得比 judged 循环慢 ~4x，改为单一循环文本 + 可选计数指针。

验证：`bash scripts/check-bench.sh` → `OK: 32 metric(s) within 2.0x … 32 of 32
alloc budget(s) held`；基线经 `--update` 在本机 ReleaseFast 实测重录（漂移 0.94–1.11x）。
遗留：`bench-baseline.ci.json` 需在 CI runner 上重录（两个新指标在 CI 上 WARN 不判红）。

### zent-modulith smoke 门禁补 `leaked` 断言 + 优雅退出；修掉 6 处存量泄漏（**破坏性：否**）

- 旧 smoke 用 SIGTERM 杀进程且示例无任何信号处理，`main` 从不返回，泄漏报告永远
  打不出来。现在：仅置标志的 SIGINT/SIGTERM handler + 自连接唤醒阻塞中的 `accept`，
  主线程优雅关停后 `SafeAllocator` 的 `leaked …` 报告进日志；smoke 判败新增
  「退出码非零 / 日志含 leaked」两条。两条失败路径均实测过真能判红。
- 开启泄漏可报后暴露 6 处存量泄漏（全是"跨分配器释放"或漏调既有 deinit 的形状，
  与 zweq 报告的那类同源）：`dev_auth` token 错用请求 arena 释放、tx_demo 事件
  上下文错用 `ctx.allocator`、`features_demo` WithEdge 预载行未走 `deinitRows`、
  catalog 两处计数行漏 deinit / 错用 arena free。全部一行级修复。
- **框架级发现（未修，记入 follow-up）**：`Server.stop()` 跨线程关 listener 与阻塞
  `accept4()` 竞争，macOS Debug 下 EBADF 被 std 归类为 `errnoBug` 直接 panic
  （`src/api/Server.zig` accept 路径）。示例侧以 `running=false` + 自连接唤醒绕开，
  框架侧待单独修。

验证：`bash examples/zent-modulith/smoke.sh` 连续 4 次 exit=0，每次 43 checks /
0 failed，结尾 `smoke: clean shutdown, no leaks`。

### 校验失败可选结构化错误体 + 消息本地化钩子（**破坏性：否**，opt-in，默认行为逐字节不变）

`Validation` 中间件新增 `structured_errors` / `message_hook` 选项
（`withStructuredErrors()` / `withMessageHook()` 链式入口）。开启结构化后 422 响应的
`data` 位携带 `errors: [{field, rule, message}]`（每失败字段一条，rule 是机器名），
`msg` 仍是首条消息；`Validator.validateStructCollect` 返回全部违规
（`Violation`/`Violations`，一次 deinit），`Validator.MessageHook` 可本地化默认规则
消息（`FieldRules.message` 覆写仍优先）。零值默认 = 旧字符串消息路径，旧用例的精确
响应体断言原样通过。装了 RFC 7807 `error_renderer` 时渲染器收到首条消息（该形状无
`data` 槽，已在文档注明）。

验证：`zig build test -Dtest-force-run=true` → 全绿（含 8 条新用例：单/多字段、
覆写逐字、默认码 4220 可配、仅钩子平坦信封不变、结构化+钩子组合）。

### 首批 fuzz 目标落地：Raft 帧 / 总线握手+事件帧+JSON / HTTP 请求行（**破坏性：否**）

三个解析面各加 `std.testing.fuzz` 块（RaftTransport.zig / DistributedEventBus.zig /
Server.zig）：任意字节下解析器只许返回 error 或成功，不许 panic/越界；种子含真实
编码帧、真实 HMAC 的握手形状与审计加的拒绝形状。总线侧从 `bindInbound/bindOutbound`
切出两个纯解析函数（行为等价）。`scripts/test-runner.zig` 补上 `fuzz` 导出——此前
只要套件里有 fuzz 块，`-Dtest-filter=` 路径就编译不过（`no member named 'fuzz'`），
现在 filter 路径按 default runner 同款语义回放 corpus + 空输入。真 fuzzer 走
`zig build --fuzz test`（不要用 `-Dtest-filter` 组合）。

验证：普通 `zig build test` 全绿（`3 fuzz tests found`）；真 fuzzer 实测
HTTP 目标 60380 runs、Raft 帧 130151 runs、总线 30310 runs 无崩溃——未发现解析器
缺陷，无需修解析器。

### 新增 `zig build soak-cluster`：cluster/bus 的长时正确性 soak（**破坏性：否**）

此前 `zig build soak` 只碰 HTTP+租户、`runtime-stress` 只碰 runtime，本轮改过的
ClusterServer 生命周期 / 总线握手 / 入站 AppendEntries 截断**没有任何长时覆盖**
（`docs/dev/v1.0-readiness-v0.32.md` B-10 的头号缺口）。现在：进程内 3 节点
`ClusterBootstrap`（真实选举/心跳/复制 + 认证帧）+ 全互联总线发布流量（**每节点
两个并发写者**，带 writer 维的 seq），主线程周期性断言：per-(dest,src,writer) 的
消息 seq 严格递增且集合完备（gap/dup/malformed 全 0）、leader 稳定（双 leader 样本
0 / 在位占比阈值）、raft 日志三节点全等、fd/RSS/线程 spread 预算内且 teardown 后
fd 回基线。参数走 `-Dsoak-cluster-iterations`（默认 2400/写者 ≈ 60s 流量）与
`SOAK_CLUSTER_*` 环境变量阈值。文件头注明：并发/正确性 soak，非 24h 长跑；混合
版本对跑不在此覆盖。**多写者不是装饰**：单写者时并发盖章窗口根本打不开，无论漏斗
是否正确 harness 都会报绿——按写者记账（并用一次「跳号变异」验证账目有牙）才让它
成为总线写序契约的端到端验证。

验证：`zig build soak-cluster` 三次 exit=0（2400/写者 ×2、4800/写者 ×1），18 条
(dest,src,writer) 流全部全量送达（4800 规模下 18/18 × 4800/4800），leader 在位
100%、零翻转，fd 23→23（teardown 回基线 5），send_failures 水位 0。

### examples/alpha-engine 补 `.blocking` 执行类别样板（**破坏性：否**）

`ExecutionClass` 双池隔离机制已落地，但 examples 零示范（评估 P1「机制可信、默认
不安全」）。全 examples 树审计后唯一 DB-bound 的 runtime spawn 点（propose 模块的
`ai.AgentWorker`，handler 路径有 sqlite INSERT / SELECT）加了
`.execution_class = .blocking`，builder 链配 `.withBlockingThreads(4, 8)` 并注释
sizing 理由；其余 worker 纯内存/纯计算，不加。`examples/runtime-workers` 是 CPU 池
演示主题，刻意保持纯净。

验证：`cd examples/alpha-engine && zig build` + `zig build run` → 6 条 `[assert]`
全 PASS；未声明 blocking 池时 spawn 直接 `BlockingPoolNotConfigured` 失败，证明
接线真实生效。

### 三个 live 测试"查了环境变量却不用它"：NATS 与 Redis 的默认地址根本连不上（**破坏性：否**）

`Test (Redis + NATS + Kafka live)` 那五条红（NATS×3、RedisRateLimiter×2）是同一
个形状，而且都不是被测代码的问题、也不是"服务不可达"：

1. **默认地址是主机名，而解析器只认字面 IP。** `NatsConfig.url` 默认 `"localhost"`、
   `RedisConfig.host` 默认 `"localhost"`，而两者的 `connect` 都用
   `IpAddress.parseIp4` —— 主机名直接 `error.InvalidCharacter`。NATS 的文件头还写着
   "default: localhost:4222"，也就是**文档里的默认值从来没连上过**，任何主机名都不行。
   默认值改成 `127.0.0.1`（并在注释里写明：要支持主机名得走 `HostName.connect`）。

2. **测试只检查变量存在，然后拿默认值去连。** `if (REDIS_URL == null) skip;`
   之后 `Redis.new(allocator, io, .{})` —— 于是 `REDIS_URL` 指向别处会被静默忽略，
   这些测试实际断言的是"localhost:6379 上有服务"。现在从 URL 取 **host 与 port**
   （`RedisConfig.fromUrl` / `natsTestConfig`），非默认端口（容器发布的端口）也能跑。

3. **NATS 的 `ping` 只读一次就要求恰好是 `PONG`。** PING/PONG 与消息是按设计交织的：
   `publish` 之后 `flush()` 时，服务器先送来那条 `MSG`，旧代码读到的是 MSG 的字节却
   拿它和 `"PONG
"` 比，于是**在一条健康的连接上**返回 `error.ProtocolError`。
   现在循环读到 `PONG` 为止，途中的帧交给 `parseMessages` 派发（MSG 与 PONG 可能
   同一个 chunk），并有 `ping_timeout_ms`（默认 5s）兜底。

验证（真服务，本机）：
- `REDIS_URL=redis://127.0.0.1:16379 NATS_URL=nats://127.0.0.1:14222
  bash scripts/test-fast.sh --force-run --db all` → **1565/1578 passed（13 skipped），0 failed**
  （CI 上是 1559/1576 with 5 failed）。
- 不带这两个变量：**1557/1578 passed（21 skipped），0 failed** —— 比改动前多 2 条，
  是新加的两个配置解析单测（`RedisConfig.fromUrl`、`natsTestConfig`）。

### MySQL 预处理语句在 MariaDB 上崩进程：`MYSQL_FIELD` 的步长比库里的小 8 字节（**破坏性：否**）

`client.query("… WHERE x = ?")` 走预处理语句路径时，CI 的 `Test (DB=mysql)` 一直
`terminated with signal ABRT`：

```text
thread 3756 panic: attempt to use null value
  src/sqlx/sqlx.zig:2908  const name = field.name[0..field.name_length];
```

**根因是数组步长，不是查询。** `mysqlStmtReadRows` 用
`mysql_fetch_fields(meta)[c]` 取列描述符，而这个文件里 `MYSQL_FIELD` 的声明在
`type` 之后结束（116 字节，补齐到 120），MariaDB Connector/C 的结构体还有一个
尾部指针。容器里量出来的数：

```text
sizeof(MYSQL_FIELD) = 128   offsetof(extension) = 120   offsetof(type) = 112
```

于是 `fields[1]` 落在真实第 1 列**前 8 字节**——读到的是第 0 列的尾巴：`name == NULL`、
`name_length == 0`、`type == 0`。第 0 列一切正常，所以症状看着像"偶发的空指针"。

修法：改走 `mysql_fetch_field(meta)` 的游标（与同文件里非预处理路径一直用的写法
一致），不再对任何 `MYSQL_FIELD` 数组做下标；顺带给列描述符结构体补上尾部指针，
让 `@sizeOf` 与库一致；`name` 为空的列改为报错而不是解引用。

同一条路径上还修掉一个**被这次崩溃掩盖的**测试缺陷：`mysql live connection` 里
`allocator.free(name_str)` 释放的是 `rows` arena 拥有的字符串（5 字节的 "Alice"），
报 `free of invalid memory`。arena 的释放点是 `rows.deinit()`。

验证（本机 + Linux 容器，都是真库）：
- Linux 容器 + `mariadb:11` + Debian libmariadb（= CI 的配置）：
  `DB=mysql … zig build test -Ddb=all` → **1556/1576 passed（20 skipped），EXIT=0**
  （CI 上此前是 `1555/1576 (20 skipped, 1 crashed)`）。
- 过滤跑 `mysql live connection`：`1 passed, 0 failed, 0 leaked`（此前 ABRT）。
- macOS 全量：1555/1576，21 skipped，0 failed（未回归）。

顺带：该测试的端口改为可由 `MYSQL_PORT` 覆盖（默认 3306），此前端口写死，
没法对着容器发布的端口跑。

## [0.33.0] - 2026-09-21

### 监听 socket 关不醒 `accept`：四个 `stop()` 在 Linux 上不返回（**破坏性：否**，行为修复）

Linux 的 `close()` **不会**唤醒已经阻塞在 `accept()` 的线程（内核为那次进行中的调用留着
socket），于是"停服务"变成"永远等下去"。`Server` 早就知道这条并写了 `shutdown()` 绕法，
另外四个自己 accept 的地方都是裸 `deinit`：`DistributedEventBus.stop()`（随后的
`fiber_group.await` 永不返回）、`ClusterServer.stop()`、`WebSocketServer.stop()`、
`WebMonitor.stop()`。收成一个 `sockread.closeListener(io, *Server)`，五处统一。

证据是 gdb 现场（Linux 全量 `zig build test` 挂住时）：

```text
Thread 1 (main)       Io.Group.await  ← DistributedEventBus.stop()   :350
Thread 3 (async task) accept4         ← acceptLoop                    :392
测试名：core.DistributedEventBus.test.two credentialed nodes bind over the network
```

修复后同一棵树：`run test 1440 pass, 21 skip (1461 total)`、退出码 0（此前挂到超时）。
macOS 侧 1555/1576 不变。

### zent 升到 v0.74.2：`getOwned` 改名 + 四条 BREAKING（**破坏性：是**）

pin 与 hash 升到 `v0.74.2`（两个示例）。本仓库要动的调用点只有一处：
**v0.73 把 `CrudService.get` 改名 `getOwned`**（它返回的是复制进*调用方* allocator 的行，
配套 `client.<entity>.deinitRowWith(allocator, &e)`）—— `zent_crud.get` 已改用它。

同时按上游 changelog 把 §14 补齐八条，其中三条会打到消费者：
**v0.70 SQLite 强制外键**（`PRAGMA foreign_keys = ON` 并回读确认；悬空引用会
`ForeignKeyViolation`，级联删除真的删，测试/清理顺序要跟着改）、**v0.73 `Sum`/`Avg` 空集报
`EmptyAggregate`**（原来是 `TypeMismatch`）、**v0.69 `SaveError` 增两个成员**
（`InconsistentRowFields`/`MissingPrimaryKey`，穷尽 switch 会编译失败）。
另四条是行为修复：PG 的 `23502`/`23503` 不再误报 `UniqueViolation`、`Restore` 受策略过滤与
拦截器约束、`queryTargets*` 中途失败不再给短页、EntQL 拒绝实体上不存在的字段。

验证：`examples/zent-modulith` 构建 + smoke **43 checks, 0 failed**；
`examples/metaverse-creative` 的 `zig build demo` 走通（`balanced=true outbox=1`）。

### `zmodu audit` b23：分配器归属（**破坏性：否**）

新增规则：`deinitRow(s)` / `deinitRows(...)` 只对**驱动扫描出来**的行用（`Query().All()`、
builder `Save()`）；把"由带 allocator 形参的调用产出"的行交给它 ——
`getOwned`（旧名 `get`）/ `Query().AllIn(arena)` / `queryRowOwned` / `scanRowsToOwned` ——
是用 client 的分配器释放别人的内存（`free of invalid memory`，会打死进程）。
判据是"目标的绑定来自一个参数里出现 allocator/arena 的调用"，即 `docs/ZENT.md` §14 写明的
那两种形态；误报在同一行写 `// audit: ignore b23` 豁免。全仓 `zmodu audit .` 0 命中。

### CL/TE 走私：真实代理拓扑用例（**破坏性：否**，补上缺失的证据）

安全审计 ② 此前只有静态推导 + 进程内解析器测试；解析器只是一半，另一半是**前置代理的
定界行为**。新增 `examples/production-deploy/smuggling-e2e/`：nginx 在前（`proxy_request_buffering`
on/off 两个口），5 条载荷，断言是"**后端服务过的每一条请求，都是网关收到过的**"——
两边各自记账，后端服务了而网关没收到的那一条就是走私原语，按定义成立。四条对照证明这个
不变式能红（直接打后端 → 后端计数 > 网关计数）。

实测 10 行全 `ok`：CL+TE 由 nginx 自己 400、裸 `Transfer-Encoding` 由后端 400、chunk 扩展行
被 nginx 规范化后转发。用例已接进 CI 的 `Integration (full)`；**未覆盖** Envoy、HTTP/2 前端、
TLS 终结层。

### CI 台架两处"红了也看不见"（**破坏性：否**）

① `cmd 2>&1 | tee log` 在命令留下握着 stdout 的孤儿进程时永不结束 —— 一次编译失败的
报错发生在 07:20，这一步却挂到 07:45 才被超时打断（收尾日志里的
`Terminate orphan process: pid (2921) (test)` 就是那个孤儿）。五处改走
`scripts/ci-run-logged.sh`（shell 重定向写文件、结束后 cat、退出码是命令自己的）。

② `set -e` 在 macOS 的 bash 3.2 下**不会**因为 `[[ … ]]` 失败而中止（Linux 的 bash 5 会），
所以 `scripts/ci-integration.sh` 里那六处断言在本机一直是哑的 —— 三条错误期望因此活到
ubuntu 不再被跳过的那天。改成显式 `exit 1` 的 `expect_code`/`expect_body`。

### 校验失败的 `code: 0` 修掉；`FieldRules` 消息带字段名（**破坏性：是**）

**① `validateRequest` 写出的 422 体里业务码是 `0`，而 `0` 在这个方言里是成功。**
`api/middleware/Validation.zig` 原来是 `ctx.sendErrorResponse(422, 0, msg)`：`{code,msg,data}`
信封里 `code: 0` 正是 `sendSuccess` 写的值，所以"先判 `code` 再判 HTTP 状态"的客户端
把一次**拒绝**读成了**成功**。现在业务码是配置项、默认 `4220`、且**配不成 0**
（`Validation.errorCode()` 把 0 换成默认值——"把 0 配回来"就是把这个 bug 配回来）：

```zig
try validateRequest(ctx, req, rules);                          // 4220
var v = Validation{}; v.error_code = 4711;  try v.validateRequest(ctx, req, rules);
try Validation.withErrorCode(4711).validateRequest(ctx, req, rules);
```

HTTP 状态仍是 422；信封形状与 RFC 7807 渲染器行为都没动。

**② `Validator.FieldRules` 的消息现在带字段名，并可逐字段覆盖。**
默认消息从 `field 'email' invalid email format` 变成 `email: invalid email format`
（多字段请求体下不点名就修不了）；`FieldRules.message` **逐字替换**整条消息
（不加字段名前缀），覆盖该字段上任何一条规则。`validateStruct` 的返回形状没变
（仍是 `!?[]const u8`，调用方负责 free），所以没有连带的签名变更。

**刻意没做**（留给后续评审）：结构化 `{field, rule, message}` 错误对象、i18n 钩子。

### 生成 OpenAPI 的三个文档注解 + 两个"带了却没输出"的字段（**破坏性：否**）

`RouteMeta` 新增 `summary` / `description` / `request_body`（`?[]const u8`，纯附加），
`exportOpenApi` 的回落链是 `summary → permission → module`、`description → 按 auth 种类的词`、
`request_body → 不输出`。**未标注时输出与从前逐字节一致**（用例里冻结了一份 golden；
改动前后对同一份"全未标注"目录各生成一次，md5 相同、`diff` 为空）。

同时修掉两处"字段存在但从不输出"：
- `ApiParam.description` 在 `generate()` 里被丢掉 —— 参数的结构体一直带着它
  （`deinit` 还负责 free），生成的文档里却从来看不到；现在非空才输出，空描述不产生键。
- `ApiEndpoint.request_body` 在 `cloneEndpoint` 里根本没被复制，所以 `addEndpoint`
  之后 `generate()` 永远看不到它 —— `ApiEndpoint` 有这个槽位，但发射器从来没写过
  `requestBody`。现在补上最小的一份（`content.<content_type>.schema`；以 `{`/`[` 开头的值
  原样内联，否则包成 `{ "$ref": … }`）。

### 总线事件序列化现在会转义（§14 收尾）（**破坏性：是**）

`serializeEvent` 用一个 `std.fmt` 格式串把 payload **原样**插进 JSON，所以 payload 里带一个 `"`
就会产出**非法 JSON** —— 接收方解析失败，事件变成一条 DLQ 条目。更早那条"子串匹配器"时代它更糟：
payload 里的 `"source":"node-b"` 会**冒充来源**。

现在换成一对共享的写入/计数 helper（`JsonWriter` + `escapedLen`/`decimalLen`/`decimalLenU64`），
两个函数都从同一组 helper 构建，所以"不会漂移"这条性质是**构造性**的，而不是靠共用格式串。

> **这次改动本身就撞了两次真 bug，都是新加的"漂移断言"抓到的**（它断言
> `eventJsonSize(e) == serializeEvent(e, buf).len` **并对结果跑真解析**）：
> ① `event_json_overhead` 写错一字节（53 应为 52）—— 所有投递用例立刻以 `EventTooLarge` 变红；
> ② `decimalLen(minInt(i64))` **整数溢出**（对它取负）—— 时间戳可以是它。
> 没有那条断言，① 会表现为"事件不再投递"，② 会在某个负时间戳上 panic。

**那条"注入"用例的结论反过来了**：它原本断言"注入被拒（→DLQ）"，现在断言**注入无效** ——
payload 原样作为**数据**送达，而文档里只有**一个** `source` 字段、且仍是真正发送方。
这是更强的陈述：从"拒绝攻击"变成"攻击构不成"。

**未做**：`ConcurrentError` 的拒绝分支仍无用例 —— `testing.io` 的 `concurrent_limit` 是 unlimited，
**树内构造不出来**，这是"不可测"而不是"没测"。


### `ClusterServer` 改为并发分发（handler 签名变更）；入站 AppendEntries 设界（**破坏性：是**）

**① accept 环此前在**自己的线程上内联跑 handler**：一个慢对端会**串行占用整个入站**（前面那次只修了
"挂死"，没修"吞吐"）。而 handler 的签名是 `*const fn (ClusterConnection) void` —— **没有 context**，
这正是 `RaftTransport.InboundServer` 用 `threadlocal var current` 绑 raft 的原因；
一旦换到别的线程跑，`current` 就是 null → **每个入站连接都被丢弃**。

所以按总线的先例（`DistributedEventBus` 的 `Group.concurrent`，审计自己点名的正确形状）改成带 context：

```zig
// 旧： fn (ClusterConnection) void
// 新： fn (?*anyopaque, ClusterConnection) void，start(handler, context)
```

`concurrent`（不是 `async` —— handler 会阻塞在读上，`async` 到限就回落到 accept 线程，那正是要移除的串行），
`stop()` 等待 group，两个 `threadlocal` 删除。因为 handler 签名变了，**这是破坏性变更**。

**② 入站 `AppendEntries` 此前没有任何上界**（`max_append_entries` 只用于出站分块）：≈2MB/帧 的暂态分配
+ ≈1.8MB/帧 的常驻增长，可重放。现在**截断**（不是拒绝）：只应用前 `max_append_entries` 条，
响应的 `success`/`match_index` 如实反映应用到了哪里 —— 这是合法 Raft（前缀），leader 下一轮从那里继续，
所以**两端配置不一致时是自愈的**，而拒绝会让复制永久卡死。另加解码侧的帧级上界
（`MAX_ENTRIES_PER_FRAME`），在**分配之前**拒绝。

**验证**：全量 **1534/1555（21 skipped，0 failed）**（比上一版 +4），fmt + 6 道门禁全绿。
两条变异我都自己重做过（inline 那条需要连带 `var conn`→`const conn` 才能编译，所以是"改两处"的变异，
已按字节还原、md5 一致）：
  inline 分发回去 → `two stalled peers do not stop a third connection from being answered`
                    在 `try fast.recv` 处 `FAIL (ConnectionError)`（第三个对端在自己的
                    2000ms 耐心内拿不到回复，因为内联分发要先还清两个 1000ms 的停顿）
  clamp 去掉     → `an inbound AppendEntries applies at most max_append_entries entries, and says so`
                    `expected 3, found 10` / `FAIL (TestExpectedEqual)`
都是断言红不是编译错。

> **复核时澄清了一处**：半帧测试里我原先的两条 elapsed 断言被**搬到了对端 A**，
> 不是被删除 —— 并发之后 B 是**立刻**被服务，所以"上界生效"这件事只在 A 上可见，
> 而 B 换成了更严的 `< timeout_ms - 50`。我自己做变异确认了它有牙齿
> （`FAIL (TestUnexpectedResult)` 在 `:1798`）。

**未做**：`ConcurrentError` 的拒绝分支没有用例（`testing.io` 的 `concurrent_limit` 是 unlimited，
触发不到）；真正的身份绑定（每节点凭证 + 握手）仍 open。


### `sockread` 的超时设置会 **panic** 而不是 warn（AF_UNIX）；以及总线 §14 的五条（**破坏性：是**）

**① `setRecvTimeout` / `setSendTimeout` 的 `catch` 是死代码。**
`std.posix.setsockopt` 把 `EINVAL` 映射成 `unreachable`（`std/posix.zig:1081`），所以内核拒绝该选项时
调用方**拿不到错误可 catch —— 直接 panic**。实测（macOS）：`setsockopt(SO_RCVTIMEO)` 在**对端已关闭的
AF_UNIX socket** 上返回 `EINVAL`（对端活着 → `SUCCESS`，对端已关 → `INVAL`，两个选项都是），
于是进程 abort。**TCP 上同一调用在对端关闭后仍是 `SUCCESS`、不会 panic** —— 所以集群/HTTP 那些路径
从来不是暴露面，**这是 AF_UNIX 的危害**，而本仓库所有 `socketpair` 用例都是 AF_UNIX。
改为走裸 `std.posix.system.setsockopt` + 显式 errno，任何拒绝都能上报。

**② 总线的五条**（`docs/dev/cluster-auth-design.md` §14 的未做清单）：子串匹配器换成真正的 JSON 解析；
每个 peer 一个写锁（`sendFramed` 成为唯一出口）；入站读加 30s 空闲上界（= 6 × 心跳间隔）；
`source_node` 用 `identityKey = HMAC(cluster_secret, claim)` 与 MAC 绑定；帧内 `"seq"` + 每 claim 的
高位标记做重放防护（限制如实写在 §14）。

> **复核时改掉了这条测试的一次"假绿"**：`a frame is keyed by the source it claims` 原先只断言
> "key 不是裸 secret" + 一个正对照，**没有断言 key 随 claim 变化**。我把 `identityKey` 改成忽略 claim
> （两边都用同一个固定标签）—— 该测试**照样通过**，也就是说身份绑定可以在无声中消失。
> 已补一条"为 claim A 签的帧不能以 claim B 通过"的断言；同一条变异现在会红
> （`expected 0, found 1`）。**另需如实说明**：在**共享 PSK** 下 `identityKey` 相对"直接 MAC 整段 json"
> 并无额外安全性 —— 拿到 secret 的人可以推导任何节点的 key；真正的身份绑定需要**每节点各自的凭证**
> （握手），这条仍 open。


### `DistributedEventBus` 入站：真 JSON 解析 · 按身份派生密钥 · 序号防重放 · 写锁 · 空闲上界（**破坏性：是**）

`docs/dev/cluster-auth-design.md` §14 上一轮记下的五条**全部关闭**，改动全在
`src/core/DistributedEventBus.zig`。

| # | 缺陷 | 现在的行为 |
|---|---|---|
| 1 | `extractJsonValue` 是**子串匹配器**：payload 里出现字面量 `"topic"` / `"source"` 就能改变解析方向 | `std.json` 真解析。payload 里的转义引号不再截断值；注入重复字段的 payload 从"投递成别人的事件"变成 `DuplicateField` → DLQ，**不投递** |
| 2 | `source_node` 直接取自 JSON，从不与对端绑定 | MAC 密钥改为 `HMAC-SHA256(cluster_secret, 声称的 source)`。**残留**：持有 `cluster_secret` 者仍可冒充任何节点（PSK 固有，超出 L1 威胁模型） |
| 3 | 无重放防护 | 帧带 `"seq"`（在 MAC 覆盖区内），每 claim 一个**严格递增**高水位、跨重连存活。**残留**：从未被接受过的帧仍可重放一次；宿主机重启使发送方序号回退 → 需 `forgetPeerSeq(id)` 人工放行（无自动重置） |
| 4 | 同一 socket 上 `publish` 与心跳 fiber 并发 `writeAll` | 每节点一把 `std.Io.Mutex`（`sendFramed` 是唯一出口） |
| 5 | 入站读无超时：连上不发言的对端占住 fiber，`stop()` 等它 | `SO_RCVTIMEO` 空闲上界 30s（= 6 × 心跳间隔，`inbound_idle_timeout_ms`，0 关闭） |

**破坏性**：帧形状变了（密钥按身份派生 + 必带 `"seq"`），新旧版本**双向都不通** —— 混合版本集群必须一起升级。

**顺带发现（不在本次改动范围）**：`sockread.setRecvTimeout` 的 `catch` 永远不会触发
—— `std.posix.setsockopt` 把 `EINVAL` 映成 `unreachable`，而 macOS 对**对端已关闭**的 AF_UNIX socket
上的 `SO_RCVTIMEO` 返回 `EINVAL`，实测会 panic 调用方。总线因此自己发同一个 `setsockopt` 并容忍失败；
`src/core/sockread.zig` 建议单独修。

验证：全量 `1529/1550（21 skipped，0 failed）`；`-Dtest-filter=DistributedEventBus` 16/16 → **22/22**；
四条变异逐条验红（子串解析回归、去掉写锁、去掉 `SO_RCVTIMEO`、接收侧换回集群级单一密钥），
都是断言红不是编译错。细节见 `docs/dev/cluster-auth-design.md` §14「第二轮」。

### `BufferPool.release` 的静默泄漏：不足尺寸的 buffer 既不回收也不归还（**破坏性：否**）

`src/im/BufferPool.zig` 的 `if (buf.len < BufSize) return;` —— 调用方的 buffer **既没进池、
也没被 free**，而 `allocated` 还留在高位，于是 `acquire` 最终报 `PoolExhausted` 而实际
没有任何东西是活的。这一侧无法 free 它（分配器要的是那次分配自己的长度）也不该收它，
所以现在**用日志点名这个调用方 bug**，契约写进 `release` 的文档注释。

**边界刻意没动**（仍是 `< BufSize`）：改成 `!=` 会连 oversized 一起拒，而 >4KiB 单帧那条路
正可能让读缓冲变大 —— 只把"静默"改成"有名"。

**没有行为红**：修复前后池的状态完全一样（旧代码也是什么都不做），变的是那条警告；
用例是钉子不是复现，测试注释里这么标了。


### WebSocket ②：io_uring 那条解析路径不再"编译不过所以安全"，握手补上 RFC 6455 §4.2.1（**破坏性：是**）

`docs/dev/security-audit-ws.md` 的处置。`WsFramer` 加固过一轮，**第二个解析器**（`src/im/ws_uring.zig`）没有 ——
原因不是忘了，而是它**从未被编译过**：`start()` 里的 `std.time.sleep` 在 Zig 0.17 已删除，
仓内又没有任何调用点，Zig 的惰性分析因此让 `start()` → `runLoop` → `processData` 整个解析体
**不进任何分析图**。审计把它记成"潜在，当前不可达"；那是没错的，但**修编译错误本身就是激活它** ——
所以这次改动里，编译修复与解析器修复必须同时落地，否则"潜伏缺陷"只是变成"活漏洞"。

| # | 缺陷 | 旧行为 |
|---|---|---|
| 1 | `start()` 调用了已删除的 `std.time.sleep` | io_uring 路径名义存在、实际不可用；正因如此下面每条都不可达 |
| 2 | 64-bit 长度无上界 | `header_len + 4 + payload_len` 在一个 10 字节帧上溢出 → `buf[10..9]`（start>end 切片）；安全构建 panic，ReleaseFast 内存不安全 |
| 3 | ping payload > 255 | `@intCast` panic（0x9 的 payload 上限在那里是 ~4094） |
| 4 | 无 RSV / 掩码必需 / opcode 白名单 / 控制帧约束 | 未掩码、RSV 置位、未知 opcode、分片控制帧一律当合法帧分发 |
| 5 | 无分片重组 | 首片被当完整消息、续帧落进 `else => {}` **静默丢弃** —— 静默截断（OpenIM protobuf 首当其冲） |
| 6 | 无 UTF-8 校验 | 非法 UTF-8 的文本帧直接交给应用 |
| 7 | 单帧 >4 KiB | `readFrame` 返回 `error.PayloadTooLarge` → 连接静默断开，尽管 `max_message_bytes` 是 1 MiB |
| 8 | 握手只查 `Upgrade` + key 非空 | 缺 `Sec-WebSocket-Version`、`Connection` 无 `upgrade` token、key 为空，三种都能拿到 101 |

**共享，而不是复制。** 审计的原话就是"完全同构的两个解析器"，所以规则只留一份，两边都调它：

- `WsFramer.validateFrameHeader(header: [2]u8, payload_len: u64)` —— RSV / **MASK 必需** /
  opcode 白名单 `{0x0,0x1,0x2,0x8,0x9,0xA}` / 控制帧 FIN=1 且 ≤125。纯函数、零分配、无 I/O，
  两个解析器共用，**无法漂移**。
- `WsFramer.Assembler` —— 分片/FIN 状态机 + 1 MiB 上界 + UTF-8 规则，`?Message` 表示"还不完整"。
  fiber 路径的 `MessageReader` 与 io_uring 的 `processData` 都驱动它，单帧消息仍零拷贝
  （payload 直接指向调用方的缓冲）。
- `WsFramer.CloseCode`（1002 / 1007 / 1009）与两边的 `closeCodeFor`：协议错误现在**告诉对端原因**再断。

**UTF-8 在"完整消息"上校验**（RFC 6455 §8.1）。一个多字节字符可以横跨分片边界 ——
`"中" = E4 | B8 AD` 被切成 `E4` + `B8 AD` 时，两片各自都不是合法 UTF-8，重组后才是。
按片校验会把**合法**消息判非法，所以校验点只有一个：重组完成之后（单帧消息即 payload 本身）。
失败 → 关闭码 **1007** + 不投递。二进制帧不校验（不透明字节）。

**单帧 >4 KiB**：选"调用方持有溢出缓冲"（`readFrame(buf, overflow)`），而不是"`readFrame` 接受 allocator
并就地放大调用方的 `buf`"。理由是所有权契约：`buf` 是 `BufferPool` 发的 4096 字节切片，
而 `release` 按 `buf.len >= BufSize` 收 —— **被 `realloc` 过的切片会被静默丢弃**，正是这一轮要避开的性质。
现在 `readFrame` 只在帧放不下时把 `overflow`（调用方持有、首次使用时按 2 的幂增长、上限 `max_message_bytes`）
长起来，**调用方的切片永不变形**，≤4 KiB 的常见路径一次分配都没有。

**握手**（`Server.wsHandshakeValid` + `connectionHasUpgrade`）：`Sec-WebSocket-Key` 非空、
`Sec-WebSocket-Version` 恰好 `13`、`Connection` **含** `upgrade` token（逗号分隔、大小写不敏感，
所以浏览器的 `keep-alive, Upgrade` 放行）—— 任一不满足 → **400 且不升级**（不写 101、`on_connect` 不跑）。
顺带修好一条既有缺陷：`framer.handshake` 失败原本走 `ctx.sendError(400, …)` 后 `return`，
而这一块是直接 `return` 出 `connFiber` 的 —— 那个响应**从来没写进 socket**；两条 400 路径都改走 `writeErrorResponse`。

**破坏性：是**
- `WsUring.init(allocator, cfg)` → `WsUring.init(allocator, io, cfg)`（`std.Io.sleep` 需要 io）。
  仓内唯一引用是生成器 README 的示例块，已同步；调用方按 `init.io` 传入即可。
- 没带 `Sec-WebSocket-Version: 13` 的握手请求现在回 400（以前回 101）。
  合规客户端（浏览器、`websocat`、任何标准库）本来就发这个头；`Server.zig` 里两条既有测试的
  握手字符串因此补上了该头（**断言未改**，改的是输入 —— 它断言的形状现在是"未升级"）。

**验证**：全量 **1523/1544（21 skipped，0 failed）**，主产物 1429（新增 17 条 + 另一工作流的 1 条）；
`zig fmt --check` + `check-production.sh` + `check-deadcode.sh` 全绿。
两条变异逐条验过红、**都是断言红不是编译错**（按字节还原，`md5 -q` 前后一致，`grep -c MUTATION` → 0）：
删掉 `validateUtf8` 的检查 → `Assembler: an invalid UTF-8 text message is rejected` 在
`expected error.InvalidUtf8, found .{ .kind = .text, .payload = { 104, 255, 254 } }` 处
`FAIL (TestExpectedError)`；删掉共享校验器里的 MASK 必需规则 →
`validateFrameHeader: the RFC 6455 negative paths, one case each` 在
`expected error.UnmaskedClientFrame, found void` 处同形红。
`start()` 的编译修复用**同一条测试**证明：把那段 `std.time.sleep` 按原样放回，
`-Dtest-filter="WsUring.start is analysed"` 编译失败（reference trace 为
`runLoop: src/im/ws_uring.zig` → `std.Thread` 的 spawn 闭包），还原后同一条测试 1/1 通过。

**未实测（写在明处）**：io_uring 事件循环本身。macOS 上 `IoUring` 是 stub，且 `init` 本体在非 Linux 上
停在 `@compileError`，所以 `start()` / `runLoop` / `submitRead` 只有**编译期**保证；
解析器函数（`parseFrame` / `writeControl`）已在本机用纯字节用例覆盖。
另外 `ws_uring` 的**单帧上限仍是 `Conn.BufSize`（4 KiB）**（超出即 1009 关闭而非静默挂起）——
本轮的"单帧到 `max_message_bytes`"只落在那条 fiber 路径上；io_uring 路径的分片重组已到位，
所以 >4 KiB 的消息按 ≤4 KiB 的分片发即可，单帧放大留待有 Linux 环境时再动。
`extensions/WebSocket.zig` 是第三份解析器（审计 §1.2 的 `[60]u8` 握手缓冲在那一份里），本轮未动。

### 集群入站零认证 ③：`DistributedEventBus` 自己的 listener 也上帧 + L1 —— 最后一个面闭环（**破坏性：是**）

`docs/dev/cluster-auth-design.md` §3.3 的**第三个调用点**（审计项 ③ 的最后一个面）。
此前该文件有自己的 listener（`:117`）、自己的 accept 环（`:149`）、自己的 `handleConnection`（`:198`），
**全程零认证**：任何能连上总线端口的主机都能发布事件，且每个事件被信任为它自称的 `source`。

**先修帧，再上认证** —— 不是顺序偏好，是 MAC 的前提：总线**完全没有消息帧**
（一条 `readSome` 的返回值被当成一条完整消息），所以挂在它上面的 MAC 无法可靠验证 ——
一条被两次读切开的合法消息给出半个 body，MAC 必然失败，于是**合法**事件被丢。
帧化同时关掉两个既有的丢数据缺陷。

| # | 缺陷 | 旧行为 |
|---|---|---|
| 1 | 一条消息被两次读切开 | 半个 JSON 解析失败 → 丢（或进 DLQ）—— **数据丢失** |
| 2 | 两条消息落在一次读里 | `parseEvent` 只认第一条，第二条**静默丢弃** |
| 3 | 固定 4096 字节栈缓冲 | 更大的 payload → `serializeEvent` 返回空切片 → `writeAll("")` **什么都没发**，且不记失败 |

**帧形状（双向）**，与 `NetworkTransport.ClusterConnection` 同一套长度前缀：

```text
[4-byte BE len][mac: 32 raw bytes][json]    配了 cluster_secret
[4-byte BE len][json]                       没配（"bare"：有长度前缀，没有 MAC）
```

`len` 覆盖它之后的一切，所以接收侧一次 `readFull(len)` 拿到整条；`len == 0` 或 >
`NetworkTransport.MAX_MESSAGE_SIZE`（1 MiB）**在缓冲之前**拒绝并断开（流已失步）。
**MAC 只覆盖 json 字节** —— 这个面没有 tag 字节（JSON 自带 `"topic"`），
所以 MAC 在**头部**，与 Raft 那边尾部的 `[tag][payload][mac]` 形状相反。
校验在任何解析之前完成，失败即 `std.log.debug` + 丢连接（认证失败**不是**解析失败，不进 DLQ）。

**改动面**：`DistributedEventBus` 加 `cluster_secret` + `setClusterSecret`、
`sendEventFrame`（`sendToNode` 与 `sendHeartbeat` 共用，帧整体一次 `writeAll`）、
按事件大小分配的 `serializeEventAlloc`（替掉三处 `[4096]u8`）、定长帧接收环、
以及**没有密钥时 `start()` 的 `log.warn`**（独立 bus 的端口是公开面）。
`ClusterBootstrap.start()` 把**同一个** `config.cluster_secret` 交给 bus（`:167`）：
Raft 端口认证了、事件端口没认证，等于审计项只关了一半。

**破坏性：是** —— 总线线上格式变了，**混合版本对端必须一起升级**：

- **新侧**收到非帧字节（旧格式）→ 长度落在 `1..1 MiB` 之外 → 丢连接 + debug 日志；
- **旧侧**读到新帧**不保证干净地拒绝**：它的 `extractJsonValue` 是子串匹配器，
  长度前缀与 MAC 是前导字节，JSON 跟在后头 —— 它可能解析出**一个错的事件**，
  而不是干脆丢掉（`docs/dev/cluster-auth-design.md` §14）。

**一行改法**：不用改代码，改的是部署 —— 所有节点**同版本**升级，密钥由应用从
`SecretsManager` 取好填进 `BootstrapConfig.cluster_secret`；只用 `DistributedEventBus.start(port)`
的独立部署调用一次 `bus.setClusterSecret(key)` 即可（不调用就是上面那个 warn 描述的公开总线）。

**验证**：全量 **1505/1526（21 skipped，0 failed）**（+6，即新增 6 条用例），
`zig fmt --check` + `check-production.sh` + `check-deadcode.sh` 全绿；
Raft 侧未动且仍绿（`-Dtest-filter=RaftTransport` 14/14、`-Dtest-filter=RaftElection` 31/31）。
两条变异逐条验过红、**都是断言红不是编译错**（按字节还原，md5 前后一致）：
删掉 MAC 不匹配时的拒绝 → `a frame signed with another key is dropped` 在
`expected 0, found 1` 处 `FAIL (TestExpectedEqual)`；
把接收环换回"一次 `readSome` = 一条消息" →
`a frame split across two writes delivers exactly one event` 在 `expected 1, found 0` 处同形红。

**未做（写在明处）**：`source_node` **没有**与 `self.nodes` 对照（accept 侧无法把连接映射回 id ——
对端地址是 `dialer_ip:临时端口`，与节点表的 `host:监听端口` 天然不等），所以配了密钥的对端仍可在
payload 里冒用别的成员 id；`extractJsonValue` 仍是子串匹配器而非 JSON 解析器；
总线侧**没有**重放防护（Raft 靠 term 单调兜底，总线没有这个性质）；
并发写同一 socket 未加锁；混合版本未实测对跑。逐条见 §14。

### 集群成员校验（L2）：三个 Raft handler 只认成员 —— 零认证那条审计闭环（**破坏性：否**）

`docs/dev/cluster-auth-design.md` §4 的落地，补上 §3（L1 逐帧 HMAC）之外的另一半。
此前**只有** `handleVoteResponse` 校验成员，同族另外三个 handler 一个都不查：

| Handler | 之前 | 现在 |
|---|---|---|
| `handleVoteRequest` | 任意 TCP 对端报**任意** `candidate_id` 就能拿到一票 | 非成员 → `vote_granted = false`。**位置在任何状态修改之前** —— 冒名者连我们的 term 都推不动 |
| `handleAppendEntries` | 从不看 `leader_id`，只看 term | 非成员（且不是自己）→ `success = false`，**先于 term 更新**，伪造者到不了日志 |
| `handleInstallSnapshot` | 同上 | 同上 —— 这条是**清空整个日志**的那条路 |

「也不是自己」是必要的：`becomeLeader` 会把 `leader_id` 设成自己的 `local_id`。

**为什么现在才能落地**：它当初被 §10 挡住 —— 那时 peer id 是 host 串、节点自报 `node_id`，
合法的 leader 同样不在 `peers[].id` 里，加校验会把**唯一还能工作的**复制路径也堵死。
`d84a31c` 把 id 空间修好之后，合法 leader 才真的出现在成员表里。**顺序是 §12 → §10 → L2。**

**连带改的是 fixture，不是断言**：L2 之前，空 peer 列表的 follower 也接受任何 `leader_id`，
所以多个既有用例的 follower（`RaftElection.init(..., &.{}, ...)`）现在会拒掉合法 leader。
动了 `RaftElection` 8 处与 `RaftTransport` 4 处环回 fixture，**没有一条断言被削弱** ——
独立核过整个 diff 里没有删除任何 `expect`/`assert` 行。其中一处值得记：
`real loopback replication` 的第 3 步断言 `voted_for == "node-z"`，所以 `node-z` 必须被
**命名为成员**，否则那条断言会因为"未知候选人"失败、而不是因为它在测的原因。

> **一处与指令相左、但改的人是对的**：brief 要求把 `ClusterBootstrap` 里
> `candidate_id = "peer-node"` 那条断言（未列成员却拿到票）翻成 `false`。
> 但 §10 的修复已经把这个 fixture 改成 `.peers = &.{"peer-node@127.0.0.1:19731"}` ——
> `peer-node` **现在就是成员**，再断言 `false` 会对着**正确**的代码失败。
> 已核实并保留那条正向断言，另补了反向方向（`unlisted-node` 带 `term = current + 100`）。

**L2 挡不住什么（写在明处）**：`leader_id == local_id` 按设计放行，所以一个自称**我们自己 id**
的对端仍然过 L2。这符合分层：**身份层是 L1（HMAC）**，id 在线上始终是自述的。
L2 挡的是"已不在成员表里的节点"，以及配合 L1 之后"随便报一个成员 id 的陌生人"。

**验证**：全量 **1499/1520（21 skipped，0 failed）**（+5，即新增用例），`zig fmt --check` + **6 道门禁全绿**。
两条变异逐条验过红、**都是断言红不是编译错**（`handleVoteRequest` 那条我自己重做过，
md5 与失败断言与报告一致）：删掉投票校验 →
`an unlisted candidate is denied a vote and cannot move the term` 在
`try testing.expect(!denied.vote_granted)` 处 `FAIL (TestUnexpectedResult)`；
删掉 AppendEntries 校验 → `an unlisted leader is refused and mutates nothing` 同形红。
§12 的 `+ 1` 两处（`:801` / `:1029`）未动。

**未做**：`DistributedEventBus` 自己的 listener（独立端口，单独一项）、§3.6 的重放残留
（按设计接受：Raft 的 term 单调 + 幂等已覆盖）、混合版本集群未实测对跑、
密钥来源只有文档约定无代码强制、`scripts/ci-integration.sh` 未跑。

### 修 peer id 空间：`ClusterBootstrap` 配出来的多节点集群**永远选不出 leader**（**破坏性：是**）

`start()` 用 `raft.addPeer(p.host)` 把 peer 加进去 —— **peer 的 id 是 host 字符串**（`"127.0.0.1"`）。
但节点回答投票时上线的是它自己的 `node_id`（`RaftTransport`：`encodeVoteResponse(..., raft.local_id)`），
而候选人计票走 `peerId(from_peer)`，只在 **`raft.peers[].id`** 里找 —— `"node-b"` 不在 `{"127.0.0.1"}` 里，
`orelse return` **把这一票丢掉**。`quorumSize()` 要 peer 的多数，所以这类集群**一张票也计不进来**
（`docs/dev/cluster-auth-design.md` §10 的六条证据链）。地址簿同样以 host 为键，中转的投票应答也查不到。

`ClusterBootstrap` 的测试里**没有一处断言过 leader**，所以它一直没被发现 —— 用例只验"起来了"。

**修法**：peer 的身份与地址拆成两份事实。

```zig
.peers = &.{ "node-b@127.0.0.1:9001" },   // 新的静态 peer 语法：`"<id>@<host>:<port>"`，`@<id>` 可省

for (peers) |p| {
    try raft.addPeer(p.id);                        // 曾是 p.host
    try self.addresses.add(p.id, p.host, p.port);  // 键 = id，值 = host:port
}
```

`PeerDiscovery.Peer` 因此多了 `id`（与 `host` 一样是自有拷贝，`resolve` / `deinitResolved` 两头都管）。
不带 `@` 的旧写法仍能解析（`id` 回落成 host），**但多节点集群会被 `start()` 拒掉**
（`error.PeerIdRequired`，与既有两个门禁同形：`log.warn` + 返回错误）：那种集群**本来就是死的**，
拒绝它不是回归，而是把"静默地永不选主"变成一个启动错误。单节点（`raft_cluster_size <= 1`）不受影响。

**破坏性**：**是** —— 多节点集群的 `.peers` 现在必须带 `@id`，否则**启动失败**。一行改法见 `docs/UPGRADING.md`。
`PeerDiscovery.Peer` 多一个字段，构造它的代码要补 `.id`（`registerService` / 金丝雀 peer）。

**验证**：全量 **1494/1515（21 skipped，0 failed）**（比上一版 +4），`zig fmt --check` + 6 道门禁全绿。
新增 4 条用例：`PeerDiscovery` 两种语法的解析（含回落）、`error.PeerIdRequired` 门禁（含"带 id 就能起来"的正对照）、
`a ClusterBootstrap-configured cluster elects a leader (peers credited by id)`、以及 mirror 该接线的
`RaftElection` 版（走 `addPeer`）。**两条变异逐条验过红**：把 `addPeer(p.id)` 改回 `addPeer(p.host)` →
选举用例在 `try std.testing.expect(raft.isLeader())` 处 `FAIL (TestUnexpectedResult)`；
把门禁条件改成永不触发 → `expected error.PeerIdRequired, found void`。**都是断言红，不是编译错**，
且都已按字节还原（`md5` 前后一致、`grep -c MUTATION` = 0）。

**未做**：§4/L2（`handleVoteRequest` / `handleAppendEntries` / `handleInstallSnapshot` 的成员校验）——
它排在这次 id 空间修复**之后**（§10 的排序修正），本次仍不动。

### 修选举的票数 off-by-one：多要一票，N=2 结构上不可能选出 leader（**破坏性：否**）

`quorumSize()` 是 `clusterSize()/2 + 1` 而 `clusterSize()` **包含自己**，但 `votes_received`
**只记 peer 的票**。于是实际要求 `1 + quorumSize()` 票，分母只有 `clusterSize()` ——
**比 Raft 的多数多要一票**。

实测（不是推演）——2 节点集群、让唯一 peer 授予投票：

```
[PROBE] N=2 clusterSize=2 quorumSize=2
[PROBE] after 1/1 peer grants: leader=false
```

| N | Raft 多数 | 修前要求 peer 票 | 修前实际总票 | 后果 |
|---|---|---|---|---|
| 2 | 2 | 2 | 3 | **不可能**（只有 1 个 peer） |
| 3 | 2 | 2 | 3 | 需要**全体一致** → 任一 peer 不可达即无法选举 |
| 5 | 3 | 3 | 4 | 需要 4/5 |

即**整体少一个节点的容错度**，N=2 完全不可用。修法是一行（`handleVoteResponse` 与 `hasQuorum`
各一处，把自己那一票算进去），验算 N=2/3/5 都对得上 Raft 的多数。

> **它为什么一直没被发现**：既有的 3 节点用例两个 peer 都活着、2 票拿得到，所以通过；
> 而 `RaftElection three-node candidate needs two peer grants, not its self-vote` 这个**测试名本身就是那条 bug** ——
> 它的注释写着 "a 3-node cluster is only won with 2 of 3 votes"（正确的 Raft 规则），
> 断言却要求 **2 个 peer** 的票（= 3 票全拿）。**注释说的是意图，断言记的是实现**，
> 而日志里还写着 "the candidate's own vote is not part of the tally" —— 把偏差当成了规范。
> `hasQuorum(2)` 更是被写进了两个不同文件的断言。

**一并改掉的旧口径描述**（否则它们继续把偏差当规范）：`startElection` 的口径注释、`hasQuorum`
的文档注释、`RaftElection quorum calculation` 的断言（并补 N=1/2/3/5 四组算术）、
`DistributedIntegrationTest` 与 `RaftTransport` 环回选举里的 `hasQuorum(2)`。
那个 3 节点测试改名为 `a three-node candidate wins with its self-vote plus ONE peer grant`。

`vote counting` 那条从 3 节点换成 **5 节点**：`quorumSize()=3` 且自己占一票，所以需要 **2 个 peer** 的票 ——
这才留出"重复票/非成员票落进 tally 但还没到多数"的观察空间。3 节点下第一票就当选、根本观察不到，
**这正是它当初被写成旧口径的原因**。

**验证**：全量 **1490/1511（21 skipped，0 failed）**（+1，即下面这条新用例），`zig fmt --check` + 6 道门禁全绿。
新的 `a 2-node cluster elects a leader with its single peer's grant` 有一条**我自己做的变异**：
把 `+ 1` 去掉 → `try testing.expect(e.isLeader())` 处 `FAIL (TestUnexpectedResult)`，**断言红不是编译错**。

**未修**：§10 的 peer id 空间问题（它让 `ClusterBootstrap` 配出来的多节点集群把票丢弃、
因而同样选不出 leader）需要先定配置形状 —— **本次不动**，证据链在
`docs/dev/cluster-auth-design.md` §10，修法记录在 §12 末尾。

### 集群入站逐帧 HMAC 认证 + fail-closed 门禁（安全审计 ② 的第 3 条；**破坏性：是**）

审计那条"入站路径零认证"（`ClusterAuth` 全仓库零调用点，TCP 可达即集群成员）的修复。
设计在 [`docs/dev/cluster-auth-design.md`](docs/dev/cluster-auth-design.md)（§3 + §3.5 已实现，§4 被阻断，
理由见下）。

**帧形状**：`[4 字节 BE 长度][tag][payload][32 字节 MAC]`，MAC 覆盖 `[tag][payload]`。
**验签与剥离在任何 decoder 之前完成**，所以 6 个 `decode*` 一字未改。配了密钥时，
`verifiedRecv` 用**常时比较**（复用 `ClusterAuth.timingSafeEql`）验签，失败即丢弃连接并 debug 日志。

**配置**（两处，`docs/dev/cluster-auth-design.md` §3.4）：

```zig
try ClusterBootstrap.init(allocator, io, .{
    .node_id = "node-a",
    .port = 9000,
    .peers = &.{"node-b@127.0.0.1:9001"},
    .transport = my_transport,
    .cluster_secret = secret,     // 32 字节；自己从 security.SecretsManager 取（env > file > vault）
});
```

**fail-closed 门禁**照抄既有的 `allow_stub_raft_transport` 惯用法：`transport != null` +
`raft_cluster_size > 1` + 没有密钥 → `start()` 返回 **`error.ClusterAuthRequired`**，
除非显式 `.allow_unauthenticated_cluster = true`。单节点不需要密钥（没有对端要对）。

> **破坏性在于门禁，不在于帧**：一个**今天在多节点上跑着**、没配密钥的部署，升级后会**拒绝启动** ——
> 这是刻意的（它此前确实是零认证的）。补一个 32 字节密钥即可，或显式承认不安全。
> 帧格式只在**配了密钥**时变化，所以单节点与不配密钥的集群字节不变。

**顺带必须一起签的三处**（否则配了密钥的集群直接不工作）：入站**回复**、投票响应**中继**、
`sendAppendEntries` 对**同一连接回复**的读取 —— 候选人会验证自己的入站帧，未签名的中继等于一票被丢；
未验签的回复读取会让 decoder 接受从未认证过的尾部字节。`writeFrameAuth` / `readFrameAuth` 是这条路上
唯一的决策点，所以三处不会漂移。

**实现期对设计的两处收紧**：

1. **密钥按值传，不建 `ClusterAuth`**。第一版每帧 `ClusterAuth.init`（内部 `dupe` 一次 `node_id`）
   再 `deinit`，而 MAC 只用 `pre_shared_key` —— 那个 `node_id` 从未被用过。代价有两个：每帧一次分配，
   以及**分配失败会把一票静默丢掉**（投票/心跳路径上凭空多出的失败模式）。现在 helper 收 `?[32]u8`。
2. **门禁用 `log.warn` 而不是 `log.err`**：`scripts/test-runner.zig:176-179` 把**任何 err 级日志**
   本身算作测试失败，所以 `err` 会让门禁测试与既有的 `RaftTransportUnavailable` 测试一起变红。

**验证**：全量 **1489/1510（21 skipped，0 failed）**（比上一版 +11），`zig fmt --check` + **6 道门禁全绿**。
新增 11 条用例（帧往返 / 换密钥 / 改 payload / 改 tag / 裸帧 / 短帧 / 带密钥的环回 AppendEntries
端到端 / 门禁四态）。**三条变异逐条验过红、全是断言红**：去掉验签 → 裸帧测试
`expected error.ClusterAuthFailed, found { …帧字节… }`；把常时比较那行改成不生效 →
`a frame signed with another key is refused` 同形红；删掉 `start()` 门禁 →
`expected error.ClusterAuthRequired, found void`。

**两个既有测试被改（有意，非弱化）**：`ClusterBootstrap accepts an app-supplied Raft transport`
加 `.cluster_secret`、`ClusterBootstrap drives raft.tick and serves inbound Raft RPCs` 加
`.allow_unauthenticated_cluster = true`（它手工写**裸**投票请求，必须走裸帧路径）。断言都未削弱。
设计稿点名的 `real loopback election…` 与 `a half-frame on the inbound side…` **未改动**且通过。
**未做**：§4 的 L2 成员校验（被下面的既有缺陷阻断）、`DistributedEventBus` 自己的 listener、
§3.6 的重放残留（按设计接受：Raft 的 term 单调 + 幂等已覆盖）、混合版本集群未实测对跑。

### 新发现（本次实现前核查出来的，比认证缺口更严重）：peer id 空间不一致 → 多节点集群选不出 leader

**未修，已记录**。`ClusterBootstrap` 把 **host 字符串**当 peer id（`ClusterBootstrap.zig:201`
`try raft.addPeer(p.host)`），而节点自己的 `local_id` 是 `config.node_id`。投票回复上线时带的是
`raft.local_id`（`RaftTransport.zig:634`），候选人却拿它去 `self.peers[].id`（host 串）里找
（`RaftElection.zig:762` 的 `peerId`）→ **对不上，这一票被丢弃**。`quorumSize()` 要求 peer 票过半，
所以 `raft_cluster_size > 1` 的集群**永远选不出 leader**。`ClusterBootstrap` 的测试里**没有一处断言过
leader**，所以它一直没被看见。

**为什么这挡住了 L2**：`handleAppendEntries` 现在**不校验** `leader_id`，这正是 leader→follower
复制**唯一还能工作**的原因 —— 照设计给三个 handler 加成员校验，合法的 leader（`"node-a"`）同样会被拒，
**把唯一能走的路也堵死**。所以顺序必须是：① 修 id 空间 → ② L1（本次已落）→ ③ L2。
证据链在 `docs/dev/cluster-auth-design.md` §10。

### P1 剩余五项：WS 帧协议、连接池耗尽、Raft 的 5 处 free-then-dupe 与别名守卫（**破坏性：否**，但 WS 一则改变行为）

评估里 P1 剩下的五项，按文件分三组。

**① WebSocket 帧处理（`src/im/WsFramer.zig` + `src/api/Server.zig`）—— 这条的用户可见度最高。**

`readFrame` 把 `header[0]` 的 FIN(0x80) 与 RSV1-3(0x70) 一起掩掉、从不检查，而 Server 的
`switch (frame.opcode)` **完全不看 FIN**。后果是：一个**分片**消息的**第一个**分片被当成完整消息交给
`on_message`，随后每个 continuation 帧（opcode `0x0`）落进 `else => {}` **被静默丢弃**，连接还开着 ——
**标准客户端的大消息因此静默截断**：没有错误、没有 close，只有短了一截的数据。

现在：

- `readFrame` 按 RFC 校验并**拒绝**：RSV 非 0 → `ReservedBitsSet`；未掩码的客户端帧 →
  `UnmaskedClientFrame`（§5.1 要求服务端关闭）；opcode 不在 `{0,1,2,8,9,A}` → `UnknownOpcode`；
  控制帧 > 125 字节 → `ControlFrameTooLarge`、FIN=0 → `FragmentedControlFrame`。
  掩码位既然成为必需，掩码键改为**无条件**读取、解掩码也无条件。
- 新增 `WsFramer.MessageReader`：**重组分片**并顺带服务穿插的控制帧（ping 回 pong、close → `.close`），
  所以调用方**永远拿不到半条消息**。单帧消息零拷贝（仍指向调用方的缓冲），只有真的分片才用
  堆上的 `frag`；上限 `max_message_bytes = 1 MiB`（与 `NetworkTransport.MAX_MESSAGE_SIZE` 同值）。
  协议错误先发一个 close 帧再返回错误，而不是留一个裸 TCP 重置。
- `WsFramer` **没有变大**：它是每个连接在 `Server.zig:2770` 建的**栈上局部量**（本就带 8 KiB 内联
  `read_buf`），所以重组缓冲放在 `MessageReader` 里而不是内联。

> **行为变化，值得知道**：不按规范发掩码帧的客户端现在会被断开（以前被静默接受）；
> 超过 4096 字节的**单帧**仍然是 `PayloadTooLarge`（WS 读缓冲是 4 KiB），但连接现在收到 close 帧而不是静默掉线。
> 不做的事：**`src/im/ws_uring.zig` 有同一套缺陷且未被修**（它只在 `server.ws_uring` 打开时走，Linux-only），
> 也**没有**做 UTF-8 校验（§8.1 要求 text 帧必须是合法 UTF-8）。

**② `ConnectionRegistry` 的另一半（`src/im/ConnectionRegistry.zig`）**

- **池耗尽**：`unregisterByConn` 与 `tickAndCleanup` 用 `allocator.destroy` 而不是 `releaseEntry`，
  而池**没有补充路径**（`free_list` 只由 `initCapacity` 与 `releaseEntry` 写）。所以一个分片经历
  `capacity` 次连接/断开后就再也建不起连接 —— 而且 `register` 返回的那个 0 被所有调用方读成"注册失败"。
  生成物用的正是 `unregisterByConn` 这条路。现在两处都回收。
- **`putAssumeCapacity` 越界写**：它建立在一个**不成立的前提**上 —— `initCapacity` 的
  `ensureTotalCapacity` 失败时**只记一条日志**（池的 `create` 循环还是 `catch break`），
  所以分片可能带着**没扩容**的 map 回来，而 `putAssumeCapacity` 对这样的 map 会写到分配之外。
  改为可失败的 `put` 并回滚，于是"0 = 什么都没注册"这条契约真正成立；
  `by_conn` 放在 `by_user` **之前**插入（它是会触发扩容的那次调用），这样一次失败的注册
  不会顺手把用户**在线的**连接也弄丢。顺带把替换旧连接的 `getPtr` 改成 `fetchRemove` ——
  后者会**把键摘掉**，只 `releaseEntry` 不摘键会让 `by_user` 指向一个已经回到空闲链表的结构，
  而那个结构可能被下一次 `acquireEntry` 交给**另一个用户**，`sendToUser` 就投错人。

**③ Raft（`src/core/cluster/RaftElection.zig`）**

- **free 后 `try dupe` 共 5 处**（不是审计说的 3 处）：`handleVoteRequest` 的 `voted_for`、
  `handleAppendEntries` 的 `leader_id`、`startElection` 的 `voted_for`、`compactLog` 与
  `handleInstallSnapshot` 的 `snapshot_data`。原顺序是**先 free 再 try dupe**，分配失败就把字段
  留在已释放的内存上，而 `deinit` 会**再 free 一次**。现在一律**先分配成功、再释放旧值**。
  后两处还往前挪了一步：`compactLog` 会先扔掉被压缩的日志条目、`handleInstallSnapshot` 会
  **清空整个日志**，所以分配必须在任何破坏性改动之前 —— 否则失败留下的是"悬垂的 `snapshot_data`
  **加上**一个已被清空的日志"。
  （`handleVoteRequest` 里 `free` 后接 `= null` 的那处是安全的，没动。）
- **`becomeLeader` 缺别名守卫**：`deinit` 一直有 `l.ptr != self.local_id.ptr` 这道守卫（连注释都在），
  `becomeLeader` 没有。`dupe` 失败时它让 `leader_id` **别名** `local_id`，于是下一次当选会
  `free(local_id)`、再从已释放的缓冲 dupe，"同一个意图实现两次、只在一处加了守卫"。

**验证**：全量 **1478/1499（21 skipped，0 failed）**（比上一版 +14：ConnectionRegistry +3、
RaftElection +2、WsFramer +9），`zig fmt --check` + 6 道门禁全绿。**6 条变异逐条自己重做过、全是断言/panic 红**：

| 改动 | 变异 | 红的样子 |
|---|---|---|
| WS 分片 | 忽略 FIN（变回修复前的形状） | `expected: Hello` / `found: Hel`，`FAIL (TestExpectedEqual)` —— **就是那个静默截断** |
| WS 未掩码 | 去掉掩码检查（并恢复条件式掩码键读取） | `expected error.UnmaskedClientFrame, found .{ .message = … payload = {104,105} }` |
| 池回收 | `releaseEntry` → `allocator.destroy` | `round 1: shard 0 pool exhausted after 0 users` → `TestUnexpectedResult`（**一轮**就耗尽，比我预计的还糟） |
| 陈旧清扫 | 同上（`tickAndCleanup`） | 同形，且只让清扫那条红（两条用例各自独立） |
| Raft `voted_for` | 恢复 free-then-dupe | `panic: double free of [addr: …, len: 2 (0x2)]`（len 2 = `"c1"`） |
| Raft 别名 | 去掉 `becomeLeader` 的守卫 | `panic: double free of [addr: …, len: 5 (0x5)]`（len 5 = `"node1"`） |

> 写这条时被门禁抓了一次：`check-production` 拒绝了 `writeClose() catch {}`（热路径禁裸 `catch {}`），
> 已改成带日志的 `closeForProtocolError()` 辅助函数。门禁起作用了。

**未做 / 未验证**：
- **`putAssumeCapacity` → `put` 这一条没有行为红**。要构造"`ensureTotalCapacity` 失败而池分配成功"
  需要让**同一次 `initCapacity`** 里 map 扩容失败、`create` 循环成功，而它俩共用一个 allocator，
  `FailingAllocator` 只能按调用序号失败、无法按调用点区分 —— 所以这条的依据是**代码级论证**
  （那句"infallible"的注释本身就不成立），不是用例。**不谎称有证据。**
- 同上：`register` 的 `by_conn` 先于 `by_user` 的顺序改动也没有独立红；替换路径那条用例是
  **回归钉子**，修复前的代码也能过（原因写在它的注释里）。
- WS 的 `ws_uring.zig` 路径、UTF-8 校验、>4 KiB 单帧仍不支持（见 ① 的说明）。
- WS 那 3 条核心用例之外我没逐个复跑（`fragmented` / `unmasked` 由我亲自变异复核，
  其余 7 条由实现的子代理跑过并报绿）。

### `ConnectionRegistry` 的连接 id 0 与失败哨兵撞车 → 释放后使用（**破坏性：否**）

连接 id 是 `(分片 << 26) | 计数器`，所以**分片 0 的 id 窗口从 0 开始** —— 而
`ConnectionRegistry.register` 用 **0 表示"注册失败"**。于是分片 0 的**第一个**连接返回 0，
调用方按约定当成失败：

```zig
// tools/zmodu/src/main.zig:7896（脚手架生成的 IM 网关）
const conn_id = self.registry.register(user_id, @ptrCast(session), sendViaWsFramer);
if (conn_id == 0) { self.allocator.destroy(session); return null; }   // ← 把一个活连接 free 了
```

而 `register` 是**先写进 `by_user` 再返回**的，所以那条记录仍指向刚被 free 的 `WsSession` ——
下一次 `sendToUser`（`ConnectionRegistry.zig:260`）解引用它就是**释放后使用**。
触发面：任何 `user_id & 63 == 0` 的第一个连接，也就是**每个用脚手架生成的项目都带着这个 bug**。

修法是**把 0 留出来**：id 起始值改为 `(分片 << 26) | 1`（`firstId`），分片 0 付出一个 id 的代价；
同时让计数器在**自己那个 2^26 窗口内**回绕 —— 最末分片的窗口止于 `0xFFFF_FFFF`，
不回绕的话它加一就正好落到 0，也就是这个方案存在的意义所在。
公开 `register` 的 `0 = 失败 / 成功的注册永不返回 0` 契约现在写在它的文档注释里。

> **为什么它活了这么久**：`src/tests.zig` **从来没有 wire 过 `src/im/`** ——
> `ConnectionRegistry.zig` 只经 `im/im.zig`（由 `root.zig` 导出，而聚合测试不 import 它）可达，
> 所以这个文件里的 **8 条用例一条都没跑过**。既有的用例又恰好只用 `user_id ∈ {1, 42, 65, 999}`，
> 落在分片 1 / 42 / 1 / 39 —— **分片 0 一次都没被碰过**。
> 本次把 `im/ConnectionRegistry.zig` 接进 `tests.zig`（`WsFramer`/`BufferPool` 早就经 `api/Server.zig`
> 可达，只有这一个文件是孤儿），新增 3 条用例，**两条变异各验过红**：
> `firstId` 去掉 `| 1` → 3 条以断言红（`TestUnexpectedResult` / `expected 4227858433, found 4227858432`）；
> 把回绕目标改成裸 `0` → 恰好 1 条红（回绕那条）。**都不是编译错。**
> 全量 **1464/1485（21 skipped，0 failed）**，比上一版 **+8**（整个文件的用例首次执行）。

### 文档漂移批次：AGENTS.md 的 CSPRNG 规则、`db.query` 口径、`ws_routes` 示例、UPGRADING 缺段（**破坏性：否**）

四组都是"文档与代码相反"，其中两组会**主动**把读者带错：

- **`AGENTS.md:256` 仍在主张已被替换的规则**（"CSPRNG: multi-source entropy, never single-timestamp
  seed"）—— 那正是 v0.32.0 删掉的方案。改为 `std.Io.randomSecure(io, buf)`，并写清
  **不要**用 `std.crypto.random`（本工具链无此声明）与 `std.Io.random`（失败回落 pid+墙钟+ASLR）。
  顺带修 `AGENTS.md:170` 把 `@intFromPtr(&seed)` 当"for entropy"的推荐（它是 pid 形状的值，不是熵源），
  并给 DO/DON'T 表补上 **CSPRNG** 与 **`ws_routes` 必须显式 `.meta.auth = .public`** 两行。
- **`db.query` 的租户口径**（`docs/AI_SKILLS.md` / `docs/MCP.md` / `docs/AI_DEV_GUIDE.md`）：
  三份文档都只说实体类技能做租户隔离。而 `MCP.md` 的 quick-start 更是**同时**用默认入口注册
  **和**设置 `ctx.tenant_id = 1` —— 那个会话里 `db.query` 按新契约**必然** `error.TenantScopeUnavailable`。
  现在三处都写明：有租户上下文就必须走 `registerBusinessSkillsWith(..., .{ .db_query_tenant_column = … })`，
  并说明外层包裹要求**你的 SELECT 把租户列放进结果集**。
- **`docs/ROUTE_TABLE.md` 两处 `ws_routes` 示例现在是编译错**（`.meta` 缺 `.auth` / 完全没写 `.meta`，
  而 `.auth` 默认 `.inherit`）—— 照抄会直接编译不过。两处都补上 `.auth = .public` 并说明原因。
- **`docs/UPGRADING.md` 补 v0.32.0 段**：该文件止于 v0.28.0，而 v0.32.0 有 **5 处破坏性变更**
  （3 处是编译错：WS 路由声明、CSPRNG 的 `io` 参数、`Method.fromString` 返回 `?Method`）。
  已核对 `v0.29.0..v0.31.0` 区间**零**破坏性变更（`git log` 里 6 个 `!` 提交全在 v0.32.0），
  所以补一段就把这个洞补完了；每条按房内格式给了 **Breaking? / 影响面 / 一行改法**。

**同批收掉的另外四个单行漂移**（同一次审计查到，紧随其后一并修）：

- `CLAUDE.md:35` 与 `docs/PRODUCTION_ROADMAP.md:144` 都写 OTLP/Vault **仅 `http://`**，
  而 `OtlpExporter.zig:88-89` 与 `SecretsManager.zig:198-199` 都接受 **`http(s)://`**
  （HTTPS 经 `std.http.Client` 系统信任库），ROADMAP 那句引的 `OtlpTlsNotSupported`
  **在 `src/` 里已不存在**（只剩测试注释与断言提到它）。两处都改成 `http(s)://`。
- `docs/API.md:1115` 写 `fromString(s: []const u8) Method`，实际是 **`?Method`**（`Server.zig:60`，
  未知/畸形方法 → `null` → 501）。
- `docs/dev/final-assessment.md` 的 S1/S2/S3 修复列写着 `std.crypto.random.bytes()`。
  **该文件是 v0.8.3（2026-05-11）的历史快照，所以没有改写它的历史记录** ——
  改为在表下加一段年代说明：这三处后来已统一为 `std.Io.randomSecure(io, buf)`，
  而 `std.crypto.random` 在当前工具链上不存在、`std.crypto.random.bytes()` 现在**编译不过**。

## [0.32.0] - 2026-09-20

### 集群/Raft 两条高危（安全审计 ② 的第 1、2 条；**破坏性：是**）

两条都来自 `docs/dev/security-audit-cluster.md`，都属于"**对端只需 TCP 可达**"这一类 ——
那条线上**零认证**仍然成立（`TlsTransport.ClusterAuth` 定义在案、有单测，但**全仓库零调用点**，已复核）。

**① `entry.index == 0` 的无符号下溢**（`src/core/cluster/RaftElection.zig`，`handleAppendEntries`）：
`decodeAppendEntries` 把 `entry.index` 直接照抄线上值、不做任何校验（`RaftTransport.zig:235`），
而条目循环用 `self.log.items[entry.index - 1]` —— `index == 0` 时这个 `u64` 减法下溢。现在**在任何日志
改动之前**拒绝 `index == 0`（`error.InvalidLogIndex`）。检查放在**循环之外**是有意的：循环体内先
`truncateLog` 再 append，把检查放进去会让一个畸形请求在失败的路上**先删掉已提交的条目**。

> **两种构建形态都实测过（去掉守卫之后）**，而且坏的方式**不同**：
>
> - **Debug / ReleaseSafe** —— `entry.index - 1` 是运行时 `u64` 运算，**溢出检查先于任何下标使用触发**：
>   `panic: integer overflow` → `signal ABRT`，整个测试进程没了。一个帧、无需认证。
> - **ReleaseFast** —— 减法绕成 `0xFFFF_FFFF_FFFF_FFFF`，而**地址运算把 `items[那个值]` 折到
>   `items.ptr - 32`**（实测：`sizeof(LogEntry) == 32`，`delta = -32`；**正好一个条目，不是野指针**，
>   这也解释了它为什么不 segfault）。随后循环拿越界的 `term` 参与比较，实测里**接受了这条畸形条目**：
>   对一个两条条目（index 1、index 0）的日志返回 `.{ .success = true, .match_index = 2 }` ——
>   等于告诉 leader "index 2 已复制"。这是 **Raft 状态机的 safety 违背**，不只是崩溃。
>
> 审计原文写的是"ReleaseFast = 野指针读"，实测比那个**更具体也更糟**，已按实测更正。

**② 入站 `recv` 没有超时**（`src/core/cluster/RaftTransport.zig`，`handleConnection`）：
`ClusterServer.start` 在**它自己那条 accept 线程上内联**跑 handler（`NetworkTransport.zig:88`），
而 `conn.recv` 此前没有任何上界 —— 全仓库只有出站侧设了 `setRecvTimeout`。于是一个连接、只发
**4 字节长度前缀**就挂住，就能停掉整个节点的 Raft 入站（没有投票、没有心跳、没有复制），并且
`ClusterBootstrap.stop()` 会卡死在 `thread.join()`：唤醒连接只能进 backlog，而 accept 环正卡在 `readFull` 里。
现在入站也设 `setRecvTimeout` / `setSendTimeout`，用的就是出站那个 `ElectionConfig.rpc_timeout_ms`
（默认 100ms）—— 它从此同时约束一次 RPC 的**两个方向**；WAN 觉得紧就把两端一起调大。

> **没改的东西**：accept 环仍然是**单线程内联**的，所以一个慢对端**仍然串行占用**它 ——
> 这条修的是**挂死**，不是**吞吐**。`DistributedEventBus` 早就为自己的环做过并发改造，
> 那是后续的结构性改动，本次刻意不做。

**验证**：全量 **1456/1477（21 skipped，0 failed）**（比上一版 +2，即下面这两条新用例），
`zig fmt --check` + production / deadcode / version / tenant-scope / pool-guard 五道门禁全绿。
两条各带一条**我自己重做过的变异**：① 去掉守卫 → 上面两种形态（安全构建是 **abort**，不是断言红）；
② `rpc_timeout_ms = 0` → `expected error.ConnectionClosed, found error.ConnectionError`（断言红，
即"第二个对端根本没被服务"），已按字节回退。

> **第 6 道门禁 `check-bench` 的诚实读数**：本次改动**跑绿了 5/5**
> （`TimerWheel x100K` 中位数 8.55 / 9.09 / 9.10 / 10.40 / 10.57 ms，基线 6.808 ms，那一轮 `load=7.50–13.73`，10 核），
> 但它**在同一棵未改动的树上也会红** —— 把本次改动全部 stash 掉后实测 3 次：`9.33 OK / 8.36 OK / 13.63 FAIL`。
> 这不是本次改动引入的，而是 `docs/dev/READING_NUMBERS.md` §"一条边界" 已经记录过的那条
> **内存/页路径受限、参考无法为它作证**的双峰指标（参考是 cache-local 小循环，机器忙时照样平）。
> 按那份文档的口径，这类指标**比分布、不比单点**；本次不是回退，也**没有** `--update` 基线。

**未做 / 未验证**：② 的用例验的是"**第二个连接会被服务**"，没有用真的半帧连接去测；① 的
`error.InvalidLogIndex` 在 `handleConnection` 里落到 `logDrop`（debug 日志 + 断开，**不回包**）——
对恶意帧这是应有的行为，但没有用例锁住它。**审计第 3 条（零认证）本次未修。**

> **为什么这条标"破坏性"**：① 给 `RaftElection.handleAppendEntries` 的错误集**加了一个成员**
> （`InvalidLogIndex`，现共 2 个：另一个是 `OutOfMemory`）。按 `src/test/ErrorSetSnapshot.zig`
> 自己的契约（"加新成员 = 破坏性变更，必须在这个文件里承认"），已把它登记进快照并把**上限钉在 2** ——
> 下游对它写穷尽 `switch (err)` 的人会在**自己的**调用点断，所以窄化不了也瞒不住；
> 下次再加错误会在**这个测试**里红，而不是在消费者那里。
> 顺带确认它**没有**退化成 `anyerror`（那会让穷尽 switch 直接不可能）。
> 运行时行为的变化就是修复本身：此前这条请求会**通过**，现在返回错误、由 `handleConnection` 丢弃。

### 三处「默认为放行」改成 fail-closed（安全审计的中危 ③⑤⑦；**破坏性：是**）

审计里三条同形缺陷，全部是"**默认放行**"这一类 —— 也是 zent 侧 v0.66 已经修过、sqlx 侧没同步的那一类。

**③ `.dept_custom` 的空/坏 `dept_ids`**（`src/datapermission/DataPermission.zig`）：`ids.len == 0` 与解析失败
都 `return null`，而 `null` 按契约是"**不过滤**"。现在照 zent 的先例给出
**`deny_clause = "1 = 0"`**（`docs/ZENT.md` §14 的同一条），并且**只有 `.all` 才能产生 `null`**。

> **调用方的形态一字未改**：`if (filter) |f| { … }` 仍然成立 —— 变的是**什么时候**产生 `null`。
> 所以 `examples/zmsaas/backend/src/shard.zig` 那个调用点不需要改，而它现在**不会再从 `.dept_custom`
> 拿到 `null`**。这条是这次改动里最容易出错的地方（改了"拒绝"的表示却忘了读它的人），已专门确认。

**⑤ `permissionGateWith` 把配置存在函数级全局 + 空 catalog 放行**（`src/api/Middleware.zig`）：
非泛型函数里的嵌套 `struct { var … }` 是**进程内唯一** —— 一个进程里跑两个 server（公网 API + 内网 admin）
时，第二次调用会覆盖第一次的 catalog 与配置，**互相读到对方的 catalog**（若目标路径在那份 catalog 里是
`.public`，权限检查就被跳过）。改成**每调用一份**（与同文件 `jwtAuthFromCatalog*` / `authFromCatalog` /
`tenantResolver` / `moduleGate` 一致），并把**空 catalog 改成 fail-closed**（此前 `try next(ctx); return;`
是直接放行，而同族 `jwtAuth*` 在同样状态下是全站强制鉴权 —— 同族默认值不一致）。
顺带把 legacy `jwtAuth` 的 `stored_security`（`src/security/AuthMiddleware.zig`）一并改掉：它是同一个形状，
会让第二个 server 用**最后一个** secret 验签。

**⑦ `tenantClause` 的租户谓词没有括号**（`src/persistence/Orm.zig`）：`"{s} AND {s} = ?"` 直接接在调用方的
`where_sql` 后面，于是 `WHERE owner_id = ? OR is_public = 1` 变成
`… OR is_public = 1 AND tenant_id = ?` —— 按优先级**租户隔离对 `OR` 的第一个分支失效**，
而且 `validateSqlFragment` 的黑名单不禁 `OR`/`AND`，所以它一路通过、**没有任何报错**。现在把调用方那段
谓词**包起来**，使 `AND tenant_id = ?` 作用于整个 `where_sql`。

**验证**：全量 **1454/1475（21 skipped，0 failed）**，5 道门禁 + fmt 全绿。
其中 ③ 的守卫由**我自己重做变异**验过：把空列表改回 `return null`，两条用例以
**`RejectedScopeCameBackAsUnrestricted`** 变红（错误名本身即判据：被拒绝的 scope 不许以无限制的形态回来），
已按字节回退。

**未做 / 未验证**：⑤ 里"一个进程跑两个 server"的**双实例场景没有构造用例**（改动的正确性来自
"与同文件那四个一致"这一构造性论证）；只在 SQLite 上跑过 ⑦ 的 SQL 形态（本机无 PG/MySQL）。


### **Breaking**：CSPRNG 换成 `std.Io.randomSecure` + `db.query` 的租户边界（安全审计的中危 ⑥ 与 ④）

**⑥ API key / 密码盐 / uuid 的种子熵不够。** 原种子是「毫秒 + 常量 42 + 栈地址 + 毫秒×1000」，
文档自称 "multi-source entropy" 字面成立，但**全部来源都是非秘密、低熵、且同一进程内共享的** ——
熵上限 ≈ ASLR 位数，且同一进程的所有生成共享同一个 slide，观测到一个就能枚举其余。
四处（`ApiKeyAuth` / `PasswordEncoder` / `SecurityModule` / `kit/random`）统一改为
**`std.Io.randomSecure(io, buf)`** —— 每次走系统调用、**失败即 `error.EntropyUnavailable`、没有回落**。

> **审计（和照抄它的简报）建议的 `std.crypto.random.bytes()` 在本工具链上编译不过**：
> `std.crypto.random` 在 Zig `0.17.0-dev.2151` 上**不存在**（实测 `struct 'crypto' has no member named 'random'`）。
> 本版本的熵入口是 `std.Io`。刻意**不用** `std.Io.random` —— 它的文档明写失败时回落到
> pid + 墙钟 + ASLR，那正是这条要消灭的缺陷类别。

**迁移**（忘了传 `io` 是**编译错误**，这是有意的：运行期弱盐比编译不过糟得多）：
`ApiKeyGenerator.generate(allocator, io)`、`PasswordEncoder.init(allocator, io)` /
`initWithIterations(allocator, io, iterations)`、`kit.random.uuid(allocator, io)` / `bytes(io, len)`。

**④ `db.query` 没有租户边界。** 兄弟技能 `entity.*` 做了，它没做。
修法是**外层包裹 + 参数绑定**（不是字符串拼接 —— 那会引入新的注入面，而且碰上模型写的 `OR`
会被优先级打穿，正是同一次审计第 ⑦ 条的形态）：

```sql
SELECT * FROM ( <模型原样 SQL> ) AS _zt_tenant_scope WHERE _zt_tenant_scope.<col> = ?
```

- 租户值**只以 `?` 绑定**出现，一个字节都不进 SQL 文本；列名过 `isPlainIdentifier`。
- **模型的表达式没有任何位置能削弱这条谓词**（外层独立 WHERE，模型写 `OR`/`1=1` 都不影响）。
- **有租户上下文但没声明列 → `error.TenantScopeUnavailable`**（fail-closed）。
  新配置 `BusinessSkillsConfig.db_query_tenant_column` + 新入口 `registerBusinessSkillsWith(...)`；
  旧 `registerBusinessSkills(...)` 签名**保留**（`docs/AI_SKILLS.md` / `docs/MCP.md` 引着它）。
  **注意**：`registerBuiltinCatalog` 走的是默认入口，所以**用内置 catalog 的多租户应用，
  其 `db.query` 在租户上下文下会被拒** —— 必须改调 `registerBusinessSkillsWith`。这是刻意的 fail-closed 默认值。
- 副作用（方向安全但值得知道）：包裹后模型自己的 `LIMIT` 在内层先生效，可能少返回几行；
  内层必须把租户列暴露在结果集里，否则外层报 "no such column" → **报错、不出数据**。

**验证**：新增 6 条用例，**三条变异全是断言失败、不是编译错** —— 把旧种子放回去：
`expected 256, found 29`（同一毫秒内 256 个 key 只有 29 个不同）与 `expected 64, found 15`（盐）；
把租户谓词去掉：`expected 2, found 3`（租户 2 的 `bob` 漏出来了）。全量 **1442/1463（21 skipped，0 failed）**、
5 道门禁 + fmt 全绿。

**未验证**：只在 `:memory:` SQLite 上跑过（本机无 PG/MySQL）；`Uring`/`Dispatch` 的 `randomSecure`
只读了 std 源码，没在 Linux/Windows 上跑。


### **Breaking**：HTTP 请求边界加固（fail-closed）—— 安全审计的高危 ②

审计（`docs/dev/security-audit-v0.31.0.md`）的第二条高危：请求解析有三处与规范不符，**合起来**允许与
按规范解析的前置代理（仓库自带 `examples/production-deploy/` 的 nginx/Envoy 拓扑）产生 **CL/TE 请求走私**。

| 修的是 | 之前 | 现在 |
|---|---|---|
| 头解析（RFC 9110 §5.6.3 的 OWS 可为 0 个字符） | `Server.zig` 只认 `": "`，`Host:x` / `Content-Length:5` **被静默丢弃**（＝该头不存在） | 正确解析；**无可解析行 → 400**（不再静默丢） |
| `Transfer-Encoding` | **全文零处理**：chunked 的体不被消费，残留在 reader 里被当成**下一个请求的请求行** | **出现即 400** |
| `Content-Length` + `Transfer-Encoding` 并存 | 无检查 | **400**（两种顺序都覆盖） |
| 重复 / 冲突 / 非十进制 `Content-Length` | 最后一次生效，`parseInt` 兜底（`1_0` 会被当成 10） | **400** |
| 未知方法 | `Method.fromString` 把**任何**未知/畸形方法折成 `.GET` | **501** |
| 请求行 | 第三段不校验、多余字段不管 | 字段数必须正好 3、版本必须 `HTTP/1.x`，否则 **400** |

**两个状态码的理由**（都在实现处写了）：
- **`Transfer-Encoding` → 400 而不是 411**：411 会邀请客户端"改用 `Content-Length` 重发"，而 **CL/TE 并存
  的请求正是这条修复要消灭的形状**；本服务器没有 chunked 请求解码器，"声明了 TE 却按没有 TE 处理"就是
  走私的成因，所以原地拒绝整条消息最可辩护。
- **未知方法 → 501 而不是 405**：RFC 9110 §15.6.2 把 501 定义为"服务器不认得这个方法"，而 405 的语义是
  "方法存在但该资源不允许"、按规范**必须**带 `Allow` 头 —— 为每个未知 token 现造一个 `Allow` 是编造的语义。

**应用会被感知到的行为变化**（如实列出）：① 无空格的合法头**第一次可见**（`ctx.header` 从 null 变真值）；
② 畸形头行从"忽略"变"整条 400"；③ 未知方法 → 501；④ 宽松 `Content-Length` 形态 → 400；
⑤ `Transfer-Encoding` → 400；⑥ 请求行多字段 / 非 `HTTP/1.x` → 400。
`PROPFIND` 这类**合法扩展方法**以前会被当 `GET` 处理，现在得到 501 —— 仓内无消费者（三处 `fromString`
调用都是**别的类型**的方法），但这个代价如实记下。

**公开 API 的破坏性变更**：`http.Method.fromString` 现在返回 **`?Method`**（未知 → `null`）。
折成 `.GET` 本身就是走私面的一部分，所以这个签名变化是修复的**要点**，不是副作用。

**两处附带改动（已明说）**：畸形请求的日志从 `log.err` 降为 `log.warn`（客户端过错不是服务端故障；
且 `scripts/test-runner.zig` 把任何 `log.err` 计为失败，否则"断言服务器拒绝坏请求"的用例必然被判红）；
`getStatusText` 增加 `501`。

**验证**：新增 5 个用例（其中 4 个走**真 socketpair** 的裸字节路径、1 个起**真 server** 断言
`HTTP/1.1 400` 落到线上并随后 EOF）；三条变异验过红且**都是断言/行为红、不是编译错** ——
其中头解析那条的 wire 级红尤其说明问题：TE 请求被**接受**，残留字节被当第二个请求行解析
（现场打出 `Parse error: error.InvalidMethod`）。全量 **1436/1457（21 skipped，0 failed）**，
6 道门禁全绿；`max_body_size` / `HeaderLimits` / `header_timeout_ms` **一个数字都没改**。

**未验证，别当实测**：**没有真实前置代理**（nginx/Envoy 拓扑未起），所以 CL/TE 走私的
**端到端可复现性是静态推导**：能证的是服务端一侧的两种解析结果（旧代码接受 TE 并把残留当下一个请求；
新代码在解析层就拒掉），**代理如何切分同一串字节没有实测**。头名的顺序/大小写变体只覆盖了 CL→TE 与 TE→CL
两种排列（头名已统一 lowercase 后比较，是代码级保证，无专门用例）。

**顺带报告一处既有地雷**（**未动**）：`Server.zig` 的 `RequestParser.parse` 是死代码，而且**本来就编译不过**
（给 5 参的 `parseAfterRequestLine` 传 4 个参数 —— 正因如此可以断定它从未被分析过）。


### **Breaking**：WebSocket 路由的 auth 声明改为**编译期强制**（且只能是 `.public`）

WS 升级在 `Server` 里是**在 `router.match` 之前、在任何全局中间件之前**被应答的，所以 `ws_routes` 上的
`auth` / `permission` / `roles` **没有任何执行点** —— 它们被记进 catalog，然后没人查；`findEntry` 还会主动
`continue` 跳过 `is_ws`。**这条真的咬过**：脚手架的 IM 网关在 WS 上把身份取自查询串
（`ctx.queryInt(u64, "userId", 0)`），任何客户端传 `?userId=<任意人>` 就能以那个人连接，而同一份模板里
那条路由写着 `.auth = .jwt`。

现在这三种写法**编译不过**：没声明 `.meta.auth` / 声明非 `.public` 的 auth / 声明 `permission`·`roles`。
**迁移**：WS 路由加 `.meta = .{ .auth = .public }`，身份在 `on_connect` 里用 `ctx` 自己验（§12.14）。
**为什么是编译期**：运行期拒绝会把那条骗人的声明留在源码里给下一个人抄。

- **脚手架模板改成 fail-closed**：`ImGateway.verifier` 默认 `null`，`accept` 在没接验签器时**拒连**
  （不再回落到信任客户端给的 id）；HTTP 侧身份改成 `ctx.requireUserIdInt(T)`（从 JWT 中间件写的 attr 读）。
  **生成物已实编译验证**（`scaffold --with-auth --with-websocket` → 生成工程 `zig build` exit 0）。
- **`Testkit.auditAuthCoverage` 的 `is_ws` 从静默 `continue` 改成断言** `.auth == .public` ——
  它过去正是唯一能发现这件事、却"看别处"的那道自动检查。

### 修 `ready_high_water` 的无符号下溢（**破坏性：否**；一个被发布的指标会永久撒谎）

`ReadyRing.tryPush`（`scheduler.zig`）与 `MpscRing.tryPush`（`ring.zig`）里
`depth = (pos +% 1) -% dequeue_pos`：**两个以上生产者**时，另一个生产者占的槽位可以先被消费掉，把
`dequeue_pos` 推过 `pos + 1`，减法**下溢成 ~2^64**；而 `high_water` 只增不减，所以**一次下溢就永久毒化**。
它被 `MetricsBridge` 发布成 `zigmodu_runtime_pool_ready_high_water`。修法是把游标**读在发布之前**
（发布前没有消费者能看见这个槽位，`dequeue_pos <= pos`）。`RingBuffer` 的 SPSC 同形表达式用的是局部量、
`head <= tail` 恒成立，**不可达**，未动。

- 新增 `MpscRing: high_water stays a ring level with more than one producer`（**2 生产者**是这个测试的全部
  意义 —— 单生产者不可达）；**变异验过红**（改回原样 → `TestUnexpectedResult`）。
- **现场证明**：`runtime-stress` 改前每次运行都印 `high_water=18446744073709551615`，改后是
  `high_water=4 capacity=8`。

### 新增 `zig build runtime-stress`：长时不变式的压测（**破坏性：否**）

`zig build soak` 是 **HTTP / 租户隔离** soak（64×2000 = 128K 请求只要 **6 秒**），**一行都不碰** Runtime。
而 v0.31.0 新增的那批东西共同特征是**只在稀有交错或长时下出错** —— 单次测试与短基准**结构上抓不到**。

`src/runtime_stress.zig`（+ `build.zig` 的 step）跑持续负载并周期检查 7 条不变式，**每条都要有"它被走到过"
的证据**（空洞的绿是最坏的）：监督守恒（没有成员静默消失）、强度用尽后**停止**重建、阻塞池隔离在长时下
成立、`ready_push_failures == 0`（两池）、热路径零分配、RSS/线程数不单调增长（时间序列）、停机可预测且
claim 全归还。三条变异验过红（含**"把负载调轻到断言走不到也会红"**）。`alloc_contract_test.zig`
**一个数字都没改**。

### 读数约定：唯一口径 + "候选回退"标记与手续（**破坏性：否**）

- `scripts/test-fast.sh` 现在**明说自己是谁**：`zm-test-count: aggregate …` 是要抄的那一行，
  `main-binary …` 标签里明写 "locates a failure, NOT the number to quote"；`--count` stdout 恰好一行。
  **"拿不到计数不能报成功"**：热缓存回放（`run test cached`，测试没执行也没计数）→ **exit 3**
  （改前 exit 0，与 `docs/BEST_PRACTICES.md` 里那句话自相矛盾）。
- `check-bench.sh` 每次运行都印一块 `references —`（4 条声明参考带 `RE-RUN-BEFORE-FIX` 标记与角色标签）；
  新增 `--explain <log>` 与 `--ratios <log…> <baseline.json>` 两个**离线**模式。`--explain` 的判据是
  "**参考自己有没有动**"，且明说"门禁的判据是不带参数那条命令的 exit code，它不改变它"。
- **两条局限都写进判词本身**（当天实测）：① **瓶颈不匹配** —— `TimerWheel x100K` 是内存/页路径受限，
  而控制参考 `atomic RMW` 是 cache-local，**没有参考能为它作证**（实测 2.25× → 重跑 1.26×，中间无代码
  改动），正确读法是取 N 次比分布；② **饱和对参考平坦度不可见** —— `machine:` 行新增 `load=` 字段，
  `--explain` 在 `load >= cores` 时把 `REAL-REGRESSION-CANDIDATE` **降级**为 `RE-RUN-BEFORE-FIX`
  （实测 load 10.0/10 核时参考全平而该指标读到 2.14× 与 2.52×）。两侧都用真实退出码验过（饱和 → 0、
  不饱和 → 1）。
- **判据一个都没放松**：`THRESHOLD`、两个基线文件、`REF_METRICS`/`NORMALIZED_METRICS` 的数组体**逐字未变**。

### 文档

- `docs/RUNTIME.md` **§12.14**（WS 声明的强制与其理由）。
- `docs/dev/v1.0-gap.md`：v0.31.0 → v1.0 差距评估（**功能已经不是主要差距了；"能不能证明"才是**）。
- `docs/dev/security-audit-v0.31.0.md`：首次安全审计，**两条高危经逐条复核成立**（WS 绕过中间件；请求边界
  只认 `": "` 的 `Content-Length` 且完全不处理 `Transfer-Encoding` → 与自带 nginx/Envoy 拓扑产生 CL/TE 走私）。
  **文中的"没读"清单同样重要**：`core/cluster/**` 的帧解码与 `im/**` 的 `WsFramer` 是未审计的高风险段。

## [0.31.0] - 2026-09-20

### Runtime：监督树 —— 组、策略、强度、树（**破坏性：否**；`docs/RUNTIME.md` §14）

§3b 的监督是**自我监督**：一个 actor 数自己的错、自己决定停不停。它有两个结构性缺口 ——
停掉是**终态**（actor 不会回来，`one_for_one` 那种"这个成员重来一次、其余照常"表达不了），
以及"这个 actor 死了"在**指标面上不存在**（`WorkerStats.stopped_by_supervisor` 只有轮询者看得见，
没有 `RuntimeStats` 聚合、没有 Prometheus 指标 —— 而 §3b 说预算是为了把"烧核"变成
"停止 + warn + **计数**"）。本次补上这两件。

**形状**：`rt.spawnGroup(policy)` 建组，成员在 spawn 时用 `Supervision.group` 入组；
四种策略 `one_for_one` / `one_for_all` / `rest_for_one` / `stop_group`（OTP 的词，
刻意不叫 `restart` —— 那个词已经被 `Supervision.Strategy` 的"记日志、接着服务"占了）；
强度 `Intensity{ max_restarts, window_ms }`（默认 `{3, 60_000}`，`0` = 不许重启，
与 `max_errors` 的"0 = 不限"相反，因为对重启来说"不限"正是这条预算要防的那个黑洞）。

**协调者是 runtime，不是用户 actor** —— 父的邮箱由父自己的 `Message` 类型决定，
runtime 无法合成任意用户 enum 的变体（§14.2 记了三条绕法为什么都不好）。
OTP 的 supervisor 本身也不跑用户代码，去掉的只是"为一个不跑用户代码的东西再写一个用户类型"。

**没有新线程、没有跨线程改状态**：执行者是**失败成员自己的线程**。它已经独占了那份状态，
组动作只是对同组成员的 handle 置位（和 `stop()` 是同一类东西）；被置位的成员在**自己的线程上**
（循环顶端 / 池认领点）做拆+建。

- **原地重建**：`deinit` + `init` 在同一个线程、同一个循环里发生。线程不退出、handle 不销毁、
  邮箱不关 —— 生产者手里的 `*Handle(W, cap)` 在重建前后是同一个，`Send` 语义不变。
  §3b 那句"在语义确定之前宁可不给"（"要么要求 State 可拷贝、要么声明 `reset` 钩子"）
  因此不再矛盾：重启就是重新 `init`，两条路都不需要。
- **升级 / 树**：组可以是组的成员（`rt.nestGroup`）。子组**强度用尽**时把决定交给父组
  （OTP：子 supervisor 放弃，父按自己的策略处理这棵子树），父重建子树时子组的预算一并清零。
  `.stop_group` **不升级** —— 它是声明，不是预算。
- **`run` 型成员被拒**：`W.run` 自持循环，runtime 插不进去、也读不到置位，所以往会重建的组里放
  是 `error.NotRestartable`（spawn 时报，不是静默降级）。`.stop_group` 不重建，因此接受它。
- **可见性**：`RuntimeStats.supervised_stops` / `group_restarts` +
  `zigmodu_runtime_supervised_stops` / `zigmodu_runtime_group_restarts` —— 前者是
  "一个成员被框架停掉了"，后者是"它被重建了几次"（**按成员计**：一次 `one_for_all` 动作
  重建两个成员就是 2）。`docs/RUNTIME.md` §8 的清单从 17 条变 19 条。
  两者都是**累计量**，理由同 `messages_discarded_on_stop`：`shutdown` 会在同一趟里 join 并销毁成员。

**邮箱多了第三个"接收者可以回来"的理由**（`Mailbox.wake` / `recvWakeable`）：
`stop_requested` 靠**关邮箱**叫醒停住的成员，重启请求不能这么做（关邮箱正是它不想要的结果），
而它又不是一条消息（邮箱是**有类型**的）。成员在**读置位之前**取 epoch，落在这两步之间的
`wake()` 才不会丢；普通 `recv` 在入口取当前 epoch，因此**行为一字未变**，没有组的成员走的还是老路。

**测试**（净增 20 条：`supervisor.zig` 10 条组级单测 + `runtime.zig` 7 条端到端 + `mailbox.zig` 2 条唤醒；
另有一条 `RaftElection` 守卫的**阳性对照**，见下）：
`examples/runtime-workers` 多了一段 §14 演示（`[v0.31] … rebuilds=2 supervised_stops=2`，
退出码以"真的重建过"为结论）。**过程中的两个真 bug 是测试抓出来的，不是推理出来的**：
池化路径漏清 `restart_requested` → **每次失败重建两次**；空闲成员没有任何东西唤醒它
（`one_for_all` 的"健康同伴"永远收不到请求）→ 才有了 `Mailbox.wake`。

### RaftElection：给那条竞态守卫补上阳性对照（**破坏性：否**；只加测试）

`RaftElection: a tick and an inbound RPC cannot both free voted_for` 用 `lock.isHeld()`
当"这一次窗口被锁串行化了"的释放条件。复核后结论是**这个判据是精确的，不是近似的**：
能进窗口的只有 `tick`（:274 取锁 + `defer`）与 `handleVoteRequest`（:330 同理）两条路径，
所以 free `voted_for` 的线程**必然正持着锁**，于是
`isHeld() == true ⟺ 观察者自己持锁 ⟺ 对方被挡在 acquire ⟺ 不可能重叠`。
它依赖两个当时没写下来的前提：测试里只有那两个驱动线程，且 mutator 是唯一的取锁者。

真正的缺口是**这条守卫在仓库里没有阳性对照**。而且健康构建里 `overlapped` 根本不可能为真
（互斥性让两个线程进不了同一窗口），所以那条断言在锁正确时接近同义反复 —— 它的牙齿主要是
"删掉锁 → 进程 abort"，而那是一次性的手工实验，没进仓库。

- 新增 `RaftElection: the window rendezvous fires iff nothing serializes the entry`：
  两个线程直接驱动 `WindowGate`，两半**只差一件事**——入口取不取锁。第一半 `lock = null`，
  第一个线程没有可退出的条件，**必然**等到第二个（`overlapped` 为真是确定性的，不是概率）；
  第二半两个线程各自持锁进门，于是 `overlapped` 保持 false 且**有理由**。
  8/8 复跑稳定；把第一半的入口也改成串行化，`expect(overlapped)` 立刻变红（验过的红）。
- **没有**引入 `isHeldByCurrentThread`（记 owner 的锁）：`tick` / `handleAppendEntries` 是全集群
  最热的路径，为防一个假想的未来编辑在那里加一次 `getCurrentThreadId()` 不划算 —— 判据本身是精确的，
  缺的是"它还会不会响"的证据，那条用测试补齐。

### Raft：出站 RPC 的回包等待有界了（**破坏性：否**；`ElectionConfig.rpc_timeout_ms` 默认 100 ms）

上一版把 RaftElection 的竞态守卫补了阳性对照，顺下来的问题是**持锁范围含出站 IO**。查下去发现
描述它的那句话本身是反的：`docs/DISTRIBUTED.md` 与 `RaftTransport.handleConnection` 都写着
"socket 读写是 IO，对端 connect 超时不该卡住 `tick()`"，而 `tick()` 的出站轮次
（`sendHeartbeats` → `transport.sendAppendEntries`、`startElection` 的 `sendVoteRequest`）
**整段在锁内**跑。而且 `RaftLock` 是**自旋**锁 —— 一个不响应的对端不是"慢一轮"，是让每个想碰
状态的线程（accept 线程的入站 RPC、`appendEntry`、所有访问器）在 `spinLoopHint` 上**烧核**。

这一版只落了**能落的那一半**，另一半是 std 的限制：

- **已修：回包等待有界。** 新增 `sockread.setRecvTimeout`（`SO_RCVTIMEO`，镜像已有的
  `setSendTimeout`）+ `ElectionConfig.rpc_timeout_ms`（默认 100 ms，`0` = 不限）。它覆盖的是
  生产里更常见的黑洞：**握手成功、然后永不回包**（对端 GC 长停顿 / accept 队列打满 / 机器过载）
  —— 这种对端 connect 侧的界**本来就管不到**。回归测试
  `a peer that accepts and never replies costs rpc_timeout_ms, not the peer's patience`：
  一个收下请求、绝不回复、把连接按住 2 秒的监听者；断言在 `rpc_timeout_ms` 内以"消息丢失"返回、
  **且真的到达过对端**（证明等的是回包而不是握手失败），上界卡在 1500 ms。
  变异（`rpc_timeout_ms = 0`）验过红：红的正是那条时间断言，不是编译错。
- **未修：dial。** `IpAddress.ConnectOptions` 声称有 `.timeout`，但 CI 锁定的 Zig 0.17 里
  `std.Io.Threaded` 的 `netConnectIpPosix` 是
  `if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout")`
  —— 第一版传了进去，测试直接 `signal ABRT`。**实测**出来的，不是读来的。所以 `dialTo` 没传；
  SYN 被丢的对端仍要付 OS 默认的 connect 超时。补这一半得自己写带 deadline 的非阻塞 connect + poll。
- **未修：锁范围本身。** 上面两条只是把代价**有界化**。收窄的设计（三段式）与三条义务
  （请求必须自足 —— 否则锁一放、`truncateLog` 就能把 `LogEntry.command` 释放掉，传输层会读到已释放
  内存；响应必须校验任期/身份，否则会把过期响应写进 `next_index`；`next_index`/`match_index` 在第三段
  读）写在 `docs/DISTRIBUTED.md` §"出站 IO 与锁"，**并注明落地前必须先补两条红测试**
  （阻塞的发送 + 并发截断；过期响应），因为现有假传输层全立即返回，撞不出这两类 bug。
- 顺带修正了一处**自己引入的**顺序 bug：`TransportImpl.init(allocator, io, &raft)` 在现有接线里
  先于 `raft = RaftElection.init(...)` 调用，所以任何在 `init` 里读 `raft.config` 的写法都在读
  `undefined`。改成发送路径上按需读（config 只在 `RaftElection.init` 写一次，不会撕裂）。

### Bench：参考判据支持"每条指标各自的参考" + 候选参考就位（**破坏性：否**）

`check-bench.sh` 原来只有一个机器参考名（`BENCH_REF_METRIC`），所有归一化指标都除以它。但
`RingBuffer SPSC x1M` 每轮的关键路径是**store→load 转发链**（`tryPush` 存 `tail`、`tryPop` 读回来，
加 release/acquire 降级），跟 `atomic RMW` 的**锁定 RMW** 不是同一个宿主性质 —— 于是 CI 基线的比值
`0.0524`（EPYC 那批）与本机 aarch64 的 `0.4976` 差 **9.5 倍**，文件头部本来就写着它"只是近似"
（引 Xeon 那次 0.0386 vs EPYC 0.0523-0.0527 的 26% 离散）。

- **机制**：`BENCH_NORMALIZED_METRICS` 的条目现在可以写成 `"<指标>=<参考>"`，不带 `=` 的回落到
  `BENCH_REF_METRIC`；两段内嵌 python 同一套解析。新增两条守卫：**跨参考不比较**（基线条目记住
  `normalized_by`，与门禁列表给的名字不一致就 WARN + 跳过，绝不拿两个不同分母的比值互比）、
  **参考集合里的指标一律只报告、不用绝对毫秒门禁**（否则候选值记进基线后会变成第二个随宿主世代
  翻红的绝对门禁，正是参考判据要消除的东西）。
- **候选**：新增 `StoreForward x10M` —— 裸的 store→load 转发链，每轮 2 个 release store + 2 个
  acquire load、同一缓存行、单线程、**去掉** ring 的索引算术与分支。
- **不换**：`RingBuffer SPSC x1M` **仍**除以 `atomic RMW x10M`。换不换是**跨宿主**的数据判断，
  一台机器上无法证明。本机 12 次并排：`ring/atomic` 0.4698–0.5086（离散 6.6%），
  `ring/StoreForward` 0.08658–0.09028（**4.3%**）—— 只能读作"本机更稳"，**不是**改进的证明。
  换参考现在是"改一行 + 每类机器 `--update` 一次"，流程已跑通（变异 M3 验过）。
- 四条变异都自己验过：参考名不存在 → WARN 且**跳过**（没有静默按默认参考算）；`--update` 遇到拿不到的
  参考 → 原样保留（不把毫秒写进 ratio 条目）；一行切参考 → 提示跨参考、`--update` 正常重录；
  候选偏移 12x → 报告而非门禁。
- **CI 基线未加 `StoreForward`**（本机值不能写进另一类机器），CI 会打一条 "not in the baseline" 的
  WARN 并照常通过，需要在 runner 上跑一次 `--update` 收编。

### Bench：`TimerWheel x100K` 的"~1.8x 余量"是**算出来的**，不是量出来的；并发掘出它的噪声是结构性的

- **"1.8x"不是门禁读数**：门禁只在**越界时**说话，通过时除了一行 `OK:` 什么都不打印。那个数是头部
  自己写的 `2.0 ÷ 1.06`（某一次判定运行 7.24 vs 6.808），即**算术余量**。
- **实测**（同机、两组独立采样、`[med3]` 中位数）：8 次 → 6.94–8.79 ms（基线的 **1.02x–1.29x**）；
  另一组 12 次 → 6.05–12.91 ms（**0.89x–1.90x**）。同批里 `TimerWheel churn x1M` 只散 1.05x、
  `atomic RMW x10M` 1.04x —— **这条比邻居噪声大 5 倍**，大样本里有一次距窗口只剩 5%。
- **噪声是结构性的、不是能修的**：这条 harness 建的是**新轮**、灌 `count` 个**永不重复**的 id，
  所以计时循环必然含 `nodes` 增长（100k → 34 次增长、14.75 MB）与**新页 first-touch** ——
  宿主的页路径**按构造在分子里**。稳态那条是 `TimerWheel churn x1M`，这条故意是冷形状。
- **被实测否掉的"修法"**：把这条 harness 也挪到 `harness_allocator`（文件里 `findById x20K` 的先例是
  把离散从 1.10–1.37x 降到 1.04x）。那条先例成立是因为**它的循环每轮释放**、块回到 freelist 让页保持热；
  **这条循环从不释放**（arm 完就丢掉整只轮），换过去只是多加了 `smp_allocator` 自己的 slab 元数据。
  实测：7.95–12.17 ms、游程离散 1.53x、单次运行内最大 **1.86x** —— 每个方向都更差。**已回退**，
  并把这条否证写进 harness 与门禁头部的注释，免得下一个人再试一遍。
- **现在的契约**：这条报慢是**候选回退** —— 先重跑确认，再看 `TimerWheel churn x1M`：churn 平而只有
  这条动了，那是宿主的页路径，不是轮子。

### Bench：调度器第一次有了基准 —— 并量出池化的那一跳值多少（**破坏性：否**）

第三方评估把"**Scheduler benchmark / pooled vs dedicated 的边界**"列在 P0，而 `src/benchmark.zig` 的
32 条指标**全是原语**（mailbox / ring / wheel / hotbus / objectpool / sequencer），**一条调度器的都没有**。
`docs/RUNTIME.md` §12.5 那句"池化多一跳，所以关键路径要 dedicated"因此一直是形容词。

新增 `BenchDrainWorker` 与 `benchWorkerDrain(mode, …)`，让三条基准落在**同一根轴**上 —— 同一个生产循环、
同一个 worker、同样 256 的邮箱，**只有"谁在 drain"不同**：

| 指标 | ns / 次交接 | 相对无线程 |
|---|---|---|
| `Mailbox post+drain x1M`（已存在，无第二线程） | 17 | — |
| `Worker drain dedicated x1M`（新） | 128 | 7.6× |
| `Pooled dispatch x1M`（新） | 190 | 11.3× |

即**池化的一次交接约为 dedicated 的 1.5–2.9 倍**（8 次独立运行）。"多一跳"从形容词变成了量级。

- **两条只报告、不门禁**，理由是实测的：8 次运行里 dedicated 散 1.84×、pooled 散 **3.09×**
  （同批 `Mailbox post+drain` 只散 1.26×），而窗口是 2.0× —— 一次运行内能摆 3 倍的数字当判据就是
  又一台假红机器（与 `TimerWheel x100K` 同一课）。已进 `check-bench.sh` 的 `REF_METRICS`
  （"宿主测量，永不门禁"），基线按点插入，**其余 28 条逐字节未动**。
- **没进 `[pct]` 区**，也是照该区自己的规则：它明确排除"per-call fixture 与计时区可比"的 harness
  （`findById x20K` 因此出局），而这两条每次调用都要建 Runtime + worker +（池化那条）池线程。
  第一版把它们放进了 pct，代价是每批 fixture 重建、整套从 6 秒变成**挂死**。
- **挂死还是另一个 bug**：第一条 harness 忘了 `stop()` 就 `join()`，dedicated 的线程永远停在 `recv` 里。
  实测症状是进程 9.5 分钟只用 4.88 秒 CPU（0.1%）、**一条输出都没有** —— 是"验证靠跑"而不是"靠读"
  才看出来的。已修，并把这个形状写进注释（池化侧由空邮箱自行释放，所以这个遗漏**只在 dedicated
  那条上出现**，而那正是第一条）。
- `[pct]` 区新增一行显式说明"hand-off 这一对为什么不在这里"。

### 修一条**我自己上一轮引入的** flake（§14 的测试在等错的计数器）

全量套件 3 轮里挂了 2 轮，都是 `Supervision (§14.5): a nested group escalates…` 的
`expected 2, found 1`（`outer_inits`）。根因不在框架，在测试：`rebuildWorker` 里
**`countGroupRestart()` 在 `startWorker()`（跑 `init`）之前**调用，所以
`group_restarts` **先于** `inits` 发布 —— 测试**等的那个计数器**和它**断言的那个**不是一个，
这是典型的 check-then-assert race。

同一个形状在 §14 的**四条**测试里都有（`one_for_one` / `one_for_all` / pooled / nesting），
只是碰巧只有一条先炸。修法：**等它断言的那个**（`inits`），并让两份测试 worker 的
`init` 计数用 `.release` 发布，使 `Published` 的 acquire 读能真正定序它后面的那些读数。
实测：修前 3 轮挂 2 轮 → 修后 **3 轮全绿（1302 pass / 21 skip / 0 fail）**。

（顺带一个反证：`benchmark.zig` **不在测试图里**（`src/tests.zig` 没引它），所以这条 flake
与我同一轮加的调度器基准无关 —— 查清这一点才没把两个问题搅在一起。）

### 公平性第一次被**断言**，并量出 `batch` 就是饿死上界（**破坏性：否**）

缺口矩阵 §5 要求 `no starvation` 进验收标准，而它此前**是设计论证、没有断言**：§12.3 写着
"环是 FIFO、每个 worker 至多一个 token"，可**能造出无界积压的 worker 只有一个自我续食的**，
而没有任何测试用那种 worker 试过。

新增 `Pooled (§12.3): an endlessly busy worker cannot starve a ready one`：A 每处理 32 条就给自己
补 32 条（积压无界，且 `ctx.stopped()` 时停手 —— 否则它会一直占住池线程，`shutdown` 永不返回），
B 只发一条。断言 **B 被服务**（A 有无限活儿也拦不住它）**且** B 到达时 A 还没跑过 256 条。

- **变异验过红，而且红的形状值得记**：把 `SchedulerConfig.batch` 调成 `1_000_000`，红的是**那条
  边界断言**而不是 `WaitTimeout` —— B **仍然被服务**，只是要等 A 那一批跑干。所以 `batch`
  **不是性能旋钮**：它就是**公平上界**，一个 worker 在忙邻居后面的最坏等待 = 一个 batch。
  小 batch 换吞吐、大 batch 换所有人的延迟上界，两边都不能只按吞吐调。写进 §12.5。
- 3 轮全量全绿（1303 pass / 21 skip / 0 fail）。

（另记一次**假红**，因为它值得当教材：`check-bench` 曾报 `findById x10K/x20K` 慢 2.1×，
但同一轮里机器参考 `atomic RMW x10M` 自己从 22.2 涨到 **35.8 ms**、所有比值同步掉到 ~0.6×。
机器静下来重跑即 exit 0、参考回到 21.4 ms。**先看参考有没有动**，比看被门禁的指标快得多。）

### Bench：池的扫描 —— 加池线程从来不更快（**破坏性：否**；只报告不门禁）

缺口矩阵 §3 要 `worker 数 × pool_threads` 的扫描，用它反过来决定每个 Runtime 改动。新增
`benchPoolSweep(io, workers, pool_threads, total)` 与 5 个网格点（每点 50 万条、64 槽邮箱、
中位 3 次），**只报告、不门禁，也不进 `bench-results.json`** —— 同一路径上一轮量到的离散是 1.84×/3.09×，
再多十几个这样的数字放到 2.0× 窗口前就是假红机器。

| workers | pool_threads | ns/条 |
|---|---|---|
| 1 | 1 | ~410 |
| 10 | 4 | ~114 |
| **100** | **1** | **~41** |
| 100 | 2 | ~55 |
| 100 | 4 | ~66 |

- **worker 越多、每条越便宜**（410 → 41）：每 worker 一只邮箱，100×64 = 6400 条的缓冲让生产者几乎
  不再撞 `error.Full`。代价主要在**生产者的重试**上，不在派发上。
- **加池线程从未变快**：6 次独立运行里 `pool_threads=1` **5 次最快、1 次持平**，最快的几次比 2/4
  线程**快 2–3 倍**，且单调（41 → 55 → 66）。所以 `pool_threads` 默认 1 是对的，
  **不要按吞吐把它调大**。
- **第二族：给每条消息真活儿**（256 步依赖乘法链，~400 ns），结论**反过来** ——
  `workers=8` 下 1/2/4/8 线程 = 78-92 / 49-59 / **31-34** / 33-38 ms（4 次运行）：
  **线程近线性扩展到 4（2.4-3.0×），8 条反而略降**（8 worker + 生产者已占满 10 核）。
- **两族合起来才是可决策的答案**：`pool_threads` 要**按活儿定** —— handler 琐碎就 1 条
  （此时生产者才是瓶颈，多线程纯属争抢），每条消息有真活儿就 `min(忙的 worker 数, 核数 − 1)`。
  单独看任何一族都会得出错结论。这句也印在扫描自己的输出里。
- 执行器：整个基准套件 7.2 秒（含 6 个网格点 × 3 次采样 × 最多 100 个池化 worker + 4 条池线程）。

### Replay：按 seq 区间与按轨筛选（**破坏性：否**；只加 API，`docs/RUNTIME.md` §13.8）

缺口矩阵 §7 要 `replay --from-seq 100000 --to-seq 120000` 那种能力。v1 只能整份重放，现在
`Replayer` 上有了定位与筛选（**没有 CLI 包装**，是 API）：

```zig
var rp = log.replayer(&manual);
try rp.open(100_000, 120_000);   // [from, to)
try rp.onlyTracks(&.{"book"});   // 回到全部用 clearTrackFilter()
try rp.bind("book", book_handle);
_ = try rp.replayAll();
_ = rp.skipped();                // 被跳过的总数
```

**五条语义决策**（`from` 之前＝跳过并计数；`to` 及之后＝根本不走进度、不计任何数；被筛掉的轨＝前进游标 +
计数；空 `onlyTracks`＝什么都不选且可见；轨 id 拼错＝`error.UnknownTrack`）写在 §13.8 的表里。
唯一的真合同是**计数恒等式**：一轮走完
`log.len() == delivered + skipped() + (seq >= to 的条数)` —— 被筛掉的洞**看得见**。

- **签名一个都没变**：`step` / `replayAll` / `remaining` / `isFullyBound` 的签名未动，无 window/filter 时
  `remaining()` 与 `isFullyBound()` 的**值**与旧行为逐位一致。（代价：`remaining()` 现在是 O(总条目数) 扫描。）
- **零分配**：`Replayer` 不持有 allocator，`open`/`seekTo` 只是扫描，`onlyTracks` 借调用方的 slice；
  `alloc_contract_test.zig` 一个数字都没改。
- **只改了一个文件**：`src/runtime/recorder.zig`（+536/−25）。
- **独立复核**（我自己跑的，不是采信报告）：4 条新用例全绿；`git diff` 里那四个公开签名**一行都没出现**
  （= 未改）；**变异自己重做** —— `to` 边界 `>=` 改 `>` → 3 条以 `TestExpectedEqual` 变红
  （`expected 4, found 5`，行号与报告一致），**不是编译错**，已回退。
- **未做**：落盘/WAL/codec、CLI 包装、seq 集合/多区间、按类型或时间戳筛选。既有一条边界未动：
  `Track` 内部不保证 `seq` 升序，而归并假设轨内升序。

### 停机策略与执行类别：把"执行模式的副作用"变成显式声明（**破坏性：否**；`docs/RUNTIME.md` §12.13）

缺口矩阵 §10 与 §6。两件事都改在 `src/runtime/runtime.zig`、`src/runtime/scheduler.zig`、barrel（+655/−31）。

**§10 StopPolicy**：同一个 worker 因为 `.dedicated` / `.pooled` 不同，"停机后邮箱尾巴怎么处理"就不同
（文档里甚至有测试锁死这个差异）。现在它是显式声明，**"不写"复现两种现状**：不写 = dedicated 得到
`.immediate`（历史行为）、pooled 得到 `.drain`（历史行为）。新增 4 条用例；**既有的两条停机语义测试
一行未改、原样通过**（其中"尾巴被计入 `discarded_on_stop`"的丢弃合同保持）。

**§6 执行类别**：`.blocking` 的 worker 走**独立的一只池**（`blocking_threads` / `max_blocking_workers`
各自声明），所以一个阻塞的 handler 占住池线程**不会**饿死 CPU 池 —— 两池不共享环/线程/计数，
是**结构性事实**而非时序巧合。`Scheduler` 的机制一行未改（同一套已验证的实例），§12.3 状态独占、
D4 每 worker 一 token、`push` 不可失败、§12.11 修的四处都不需要重新论证。

- **默认逐位不变、零新线程**：不写 `execution_class`（`.cpu`）且不写 `blocking_threads`（`0`）时，
  `Scheduler.start` 仍是懒启动，只有 `.blocking` spawn 才起阻塞池。
- **诚实划边界（写进 §12.13）**：这是**声明式**的，runtime 不能一般地检测阻塞，所以它解决
  "被声明为阻塞的 worker 不占 CPU 池"，**不**解决"忘了声明"。`blocking_threads` 按**下游资源并发量**
  定（如 DB 连接池大小），**不要按核数**。两个上界是**两次独立 admission**（总量是两者之和）。
  `.blocking` + `.dedicated` 是**编译错**（声明会被静默忽略，比不声明更糟）。
- **独立复核**（我自己跑的）：**合并后** 全量 **1313 pass / 21 skip / 0 fail**、门禁 **7/7 全绿**；
  **变异自己重做** —— 把策略解析改成"忽略 mode、一律 `.drain`"，**3 条以 `TestExpectedEqual` 变红**
  （`expected 2, found 8` / `expected .immediate, found .drain` / `expected 6, found 0`，与报告一致），
  **不是编译错**，回退按字节校验。`alloc contract` 8/8，**精确分配次数一个数字都没改**。
- **未做**：`MetricsBridge` 只发布 CPU 池的 6 条 `zigmodu_runtime_pool_*`，阻塞池目前只有
  `blockingPoolStats()` 这个读侧入口（无 live scrape）；`Application` 侧没有 `withBlockingThreads`
  （builder 接线是后续项）；`soak` / examples / CI 集成脚本未跑。

### 补齐执行类别留下的两处接线缺口（**破坏性：否**）

上一版把 `.blocking` / `SchedulerConfig.blocking_threads` 落进了 **Runtime**，但两条"**给应用用**"的路
没接：`MetricsBridge` 只发布 CPU 池那六条 `zigmodu_runtime_pool_*`，`Application` 侧也没有
`withBlockingThreads`（要用阻塞池只能手写 `Runtime.initWithOptions`）。这一版补上：

- **`MetricsBridge` 覆盖阻塞池**：同样六条，`zigmodu_runtime_blocking_pool_*`（declared / threads /
  ready_len / claimed / dispatches / ready_push_failures），与 CPU 池并列。没声明阻塞池时读 0 ——
  "这个 app 没有阻塞池"是仪表盘能画出来的答案，不是一条缺失的线。`zigmodu_runtime_*` 从 25 条变 31 条。
- **`Application.withBlockingThreads(blocking_threads, max_blocking_workers)`**：与
  `Config.blocking_threads` / `Config.max_blocking_workers` 同名同义，走
  `ApplicationBuilder → Config → Runtime.initWithOptions` 这条既有的镜像路（六处：两个 `Config` 字段、
  `init` 的拷贝、`runtime()` 的 scheduler 字面量、两个 builder 字段、builder 方法、`build` 的拷贝）。
- **新增 2 条接线测试**：`Application: withBlockingThreads declares the blocking pool the runtime then
  offers`（声明 4/2/7 三个数，断言 CPU 池上界与阻塞池上界**各自**到位，然后**真的 spawn 一个
  `.blocking` worker 并等它跑完** —— 那才是这条接线缺口的用户可见后果：以前 app 走 builder 声明
  `.blocking` 只会拿到 `error.BlockingPoolNotConfigured` 而无路可走）与
  `Application: no withBlockingThreads means no blocking pool at all`（默认仍是零新线程、`.blocking` 被拒）。
- **变异验过红**：拿掉 builder→Config 的拷贝，红灯是 `BlockingPoolNotDeclared`（**行为红，不是编译错**），
  已按字节回退。全量 **1315 pass / 21 skip / 0 fail**，门禁 **7/7**。
- 一处**我自己先写错**的断言值得记：第一版我断言 `blockingPoolStats().pool_threads == 2`，实际读 0 ——
  `pool_threads` 是"**正在跑的**线程数"，池是懒启动的（声明的池一条线程都不起）。改成断言
  `max_pooled_workers`（声明的上界）之后再 spawn 一条，才同时验证了"宽度进位"与"线程真起来了"。

## [0.30.1] - 2026-09-20

### DX：让"只跑匹配的测试"真的可用，且不再静默骗人（**破坏性：否**；新增 `bash scripts/test-fast.sh --filter`）

原来唯一可信的验证方式是整跑（~47s），因为所有"加 filter"的写法都在骗人 —— 三条都在
0.17.0-dev.2151 上实测复现：

- `zig build test -- --test-filter X`：build runner 把 `--` 之后的参数**整体丢弃**。传一个**不存在**的名字，
  依然跑满整套（**47.1s**）、**exit 0**，输出里的计数与不带 filter 一模一样。开发者以为自己只跑了一个测试。
- `zig test src/root.zig --test-filter X`：缺 `build_options` 模块与 SQL 驱动链接，得手拼 `-Mroot=`；
  而且产物二进制在**运行期拒收** `--test-filter`（`unrecognized command line argument` → abort）—— 该 flag 是编译期的。
- Zig 自带 `--test-filter`（`Compile.filters`）是**编译期**过滤：被排除的 test 连函数体都不分析，它 body 里的
  `@import` 不会发生，被导入文件的测试**根本不在编译里**。本仓库整套挂在一个聚合测试下
  （`src/tests.zig` → `test "compile all source files"`），所以实测 `-Dtest-filter=RaftElection` 编出的
  二进制只含 1 个用例（`root.test_0`，无名 `test { … }` 块，任何 filter 都匹配不到）且 **exit 0**；
  只有 `-Dtest-filter=.`（匹配一切）能跑满 1416。

**修法**（`build.zig` + `scripts/**`，未动 `src/**`）：

- `-Dtest-filter=SUBSTR` 改成**运行期**过滤：给 `test` step 的 5 个 test artifact 装上
  `scripts/test-runner.zig`（`TestRunner{ .mode = .simple }`，模型自编译器自带 `test_runner.zig` 的
  `mainTerminal`，保留 per-test allocator/io 与泄漏检测语义），整套编译、只执行命中的用例。
  无名 `test { … }` 块在 filter 下不执行（没有名字可匹配，且计数会把"命中 0 个"藏起来），并在摘要里单列。
- `bash scripts/test-fast.sh --filter <全限定名子串>` 是**被检查的入口**：汇总各二进制的
  `zm-test-runner: selected N of M tests` 行，总数 0 就 **exit 2** 并写明"没有验证任何东西"；
  拿不到计数时 exit 3 或给 WARNING，**绝不报告成功**。退出码：`1` 用例失败 · `2` filter 命中 0 · `3` 拿不到结果 · `64` 用法错误。
- `-Dtest-force-run=true` / `--force-run`：Zig 连 test **运行**结果一起缓存，热 cache 下重跑只打印
  `run test cached`（测试没执行、也没有计数）。带 filter 的运行本来就强制重跑。
  **默认行为未改**：不带任何选项的 `zig build test` 仍用 Zig 自带 runner 跑全部用例。
- 实测：命中 1 个 → `1 of 1416 tests matched`（秒级，且这个用例是嵌套在聚合测试之下的，编译期 filter 永远够不着）；
  命中 0 个 → exit 2、**0.7s**（对比整跑 47s）；默认整跑不受影响（`1395/1416 passed, 21 skipped, 0 failed`）。
- 文档：`AGENTS.md` §Testing「只跑匹配的测试（以及哪些形式不可信）」+ `docs/BEST_PRACTICES.md` §测试策略。

### Cluster：同一个 `RaftElection` 的两个线程现在由 raft 自己的锁串起来（**破坏性：否**；修真竞态 + 补回归测试 + 两处测试同步）

`ClusterBootstrap.start()` 起一个 accept 线程，把对端发来的 Raft RPC 直接分发进 `raft`（
`RaftTransport.handleConnection` → `RaftElection.handleVoteRequest` / `handleAppendEntries`），而
`tick()` 是**文档要求由应用自己的循环/定时器**去调的 —— 也就是另一个线程。当时 `RaftElection` 本身没有任何
同步（裸字段 + `ArrayList` + `StringHashMap`），两边都在 free/dupe `voted_for`、推 `log`、改
`next_index`/`match_index`，所以"同一时刻只有一个线程碰 raft"这个假设**在代码里不成立**。

- **红证据**（`/tmp` 探针：一个线程空转 `cluster.tick()`，另一线程用真 socket 连入站端口连发
  `vote_request`，12 次运行 / 随机 seed）：**6 次 ABRT + 2 次内存泄漏**（`SafeAllocator` 报
  `double free of [addr: 108fe5198, len: 9]`，栈 `handleVoteRequest` ← `handleConnection` ←
  `onInboundConnection` ← `runInbound`；泄漏那次报的是同一处 `dupe` 丢掉指针）。修后同一探针
  **12/12 干净**（0 ABRT / 0 泄漏）。
- **修法**（`src/core/cluster/**` 三文件 + 文档）：锁**搬进 `RaftElection` 自己**
  （`RaftElection.RaftLock`，原子自旋，和 `scheduler.zig` 协调池线程的口径一致）—— 每个碰共享状态的
  公开入口（`tick` / `handleVoteRequest` / `handleAppendEntries` / `handleVoteResponse` /
  `handleInstallSnapshot` / `appendEntry` / `addPeer` / `compactLog`，以及状态访问器）自己取放一次，
  私有的步骤函数（`startElection` / `sendHeartbeats` / `becomeLeader` / …）假设锁已在手。
  这样"同一时刻只有一个线程碰 raft"从**调用方的接线约定**变成类型自身的性质：`ClusterBootstrap` 直接驱动、
  `RaftTransport.InboundServer` 单独用、或应用自己调 `raft.tick()`，都被同一把锁串起来。
  `ClusterBootstrap.raft_lock` 与 `RaftTransport.handleConnectionLocked(…, lock)` 随之**删除**（不留第二把锁）；
  入站仍然是 **decode → dispatch → encode**，锁的窗口就是 dispatch 里那次 `handle*`，
  decode/encode 只碰 arena 缓冲与 init 后再不改的 `local_id`，**socket 读 / 回包 / 回推仍在锁外**
  （对端 connect 超时不该卡住 `tick()`）。锁**不覆盖**的东西也在 doc 里列了出来：私有步骤函数（它们只是
  一次状态转移内部的步骤）、`deinit`（终态，调用方须先停掉其它使用者）、以及只读成员数、又被锁定体自己
  调用的 `clusterSize` / `quorumSize` / `hasQuorum`。
- `ClusterBootstrap.getRaft()` 返回裸指针，**本质无法保护**，所以它**不装锁**、只写契约（doc 在该访问器上）：
  一个 raft 只允许一个驱动线程；`tick()` / `handle*` 各自持锁，但从别的线程驱动就要自己同步
  （整段要原子化的序列包在 `raft.lock` 里）；访问器是单次读而不是事务；`getLogEntry().command` /
  `getLeader()` 是借来的切片；`stop()` 之后指针失效。同一条契约也写在 `RaftElection.deinit` /
  `getLogEntry` / `getLeader` 的 doc 上。
- **仓库内回归测试**（进 `zig build test`，实测 **230 ms / 2000 轮**）：
  `RaftElection: a tick and an inbound RPC cannot both free voted_for` —— 两个线程 + 显式 barrier 复刻
  文档接线（一个线程 `tick()`，一个线程 `handleVoteRequest` / `handleAppendEntries`），再用一层 allocator
  包装（`WindowGate`）把 `voted_for` 的 read-then-free 窗口变成**会合点**：第一个 free 按住窗口，直到第二个
  线程也到达同一个 free（= 两个线程真的同时在这个窗口里）。不带锁的构建 → 第一轮就确定性 ABRT
  （`double free of [addr: …, len: 6]`，`alloc:` 在 `handleVoteRequest`、`first free:` 在 `startElection`；
  3 次独立运行都红）；带锁构建 → 会合点由"窗口持有者确实握着锁"这一状态直接解开（无 sleep、无超时、
  不撞概率，因此不引入新的 flaky）。
- 两处测试同步（都不是产品行为问题，是"等了一个计数、断言另一个计数"）：
  `Actor: a plain worker survives handler errors` 现在等 `handled` **和** `handler_errors` 都到 2；
  `MetricsBridge publishes the pool's counters` 在 `join()` 之后再等 `poolStats().claimed == 0`
  （`join` 等的是 worker 自己那个 `claimed` 标志，池计数在 `runOne` 里晚一步递减）。
- 读数：`Actor` 那条用同一段循环压 20000 轮 —— 旧等待条件有 7314 轮（37%）在断言前读到半更新状态，
  新条件 0 轮；池那条带负载 40 次：修前 7 次失败（`expected 0, found 1`），修后 0 次。

### Scheduler Phase 2：红证据与守卫的复现复核（**破坏性：否**；只补验证，生产代码未改）

v0.30.0 把就位环的出队改成 CAS 认领，**理由**是"旧出队下两条线程能拿到同一个 token、陈旧的槽位序号会让
某个 token 永远 pop 不出来"，但那一轮的执行者撞了步数上限、没交交接报告 —— 红证据与"守卫到底红不红"
一直是欠账。本次补齐，且**只加测试**（`src/runtime/**` 的非测试部分一行未改）：

1. **确定性红证据**（一次性暂停钩子，只在 `/tmp` 副本里跑）：把 `tryPop` 停在"读到 token 值之后、推进
   `dequeue_pos` 之前"，主线程再完整跑一次 `tryPop`。旧形状 → token0 被两条线程各拿一次
   （`T1=1 T2=1`，且陈旧 store 把 `dequeue_pos` 从 2 打回 1）；CAS 认领 → `T1=1 T2=2 T3=0`，恰好一个。
   第二种形态（陈旧的 `slot.sequence.store`）同样确定性复现：旧形状下 `tryPop()` 返回 null 而
   `len() != 0`（槽位永久不可读、后续推送还毒化一格）；新形状下被暂停的消费者只让生产者被拒一次
   （可恢复的窗口，不是丢 token）。
2. **守卫有牙齿**（验收方式：只把 `tryPop` 换回 Phase 1 写法，其余一行不动）：现有两条多消费者测试
   在旧实现下**确实是红的** —— `two consumers race one token …` → `expected 2, found 3`；
   `a hammered ring hands every token to exactly one consumer` → `ring: token 0 came out 4 times`；
   真池用例 `N pool threads conserve messages …` 更直接 **ABRT**（`push` 的重试预算耗尽 →
   `scheduler.zig:564: std.debug.assert(false)`，调用栈 `push ← runOne ← turn ← poolMain`）。
   结论：它们不是"没牙齿的测试"。
3. **新增守卫**：`four consumers released together still hand one token out once`（同一起跑线的加宽版，
   旧实现下红：`expected 1, found 2` / `expected 2, found 4`，视撞上的轮次）；
   `the declared occupancy pushes cleanly, round after round`（`bound + width` 口径连压 500 轮 × 7 次推送
   **0 拒绝**，同时断言 Phase 1 口径的环第 5 次就被拒；容量公式去掉 `+ pool_threads` 时它红：
   `expected 8, found 4`）；`with one pool thread a claim is never missed` 从一种形状扩到三种
   （`batch` 1/8/16、worker 2/4/6）。
4. **读数**：宽度 4 真线程 → `sent=8000 received=8000 dropped_full=0 overlaps=0 claim_misses=0
   dispatches=8000 push_failures=0`；宽度 1 三种形状 `claim_misses` 全 0。

零分配契约未放宽，`pool_threads` 默认仍是 1。细节与原文见 `docs/RUNTIME.md` §12.12.1。

## [0.30.0] - 2026-09-20

### Scheduler Phase 2：N 条池线程（**破坏性：否**；默认宽度 1 = Phase 1 行为）

Phase 1 的池只有**一条**线程，`docs/RUNTIME.md` §12.10 把"多池线程"列在"明确没做"里。这一批把它做掉，
而且**协议本体一行未改** —— `queued`/`claimed` 两个位、单出口回执、D4「每 worker 至多一项」、
D5「回执前重查邮箱」在任意 N 下都成立。改的全是协议**外围**，四处：

1. **`ReadyRing.tryPop` 改成多消费者安全**（本次最硬的一处）。Phase 1 的出队是"读 `dequeue_pos` → 读槽位 →
   写 `dequeue_pos = pos+1` → 释放槽位序号"：两条线程读到同一个 `pos` 就**都会拿走同一个 token**
   （§12.3 的状态独占在进门之前就没了），而两次序号写会让某个 token **永远 pop 不出来**（那个 worker 从此
   不再被调度，邮箱却继续收条）。修法是 Vyukov 出队那一半的标准写法：**下标用 `cmpxchgWeak` 认领**，
   赢了才拷值、才释放槽位序号，**没有引入任何新原语**（§12.7 的"不做新队列"仍成立）。
   **红证据**（只把 `tryPop` 换回 Phase 1 的写法，其余不动）：`scheduler: two consumers race one token and
   exactly one of them gets it` 第 2 轮就红 —— `expected 2, found 3`；`scheduler: a hammered ring hands every
   token to exactly one consumer` 红 —— `ring: token 0 came out 4 times`，环随即卡死（4 个生产者全部超预算
   放弃）。换 CAS 后：50 000 轮 + 4×5 000 token 全绿（连跑 5 次）。
2. **线程从"一条"变成"一组"**：`thread: ?std.Thread` → `threads: []std.Thread`（在 `Scheduler.init` 一次性
   分配，调度路径仍零分配）+ `started` 计数。`start()` 在**同一个 `start_claim`** 下起完整组再发布计数
   （懒启动的语义仍是"起或不起"），起失败则回滚 join，保持 all-or-nothing；`shutdown()` 先 `stopping` +
   唤醒，再**取走**计数（`swap(0)`）并 join 那么多条 —— 取走而不是读，否则两个并发调用方会 join 同一句柄
   两次（就是 §12.11 第 4 条的 `INVAL` → 中止）。
   `stats().pool_threads` 从此报**真实条数**（`0` = 池没起或已停，起来后 = 声明的宽度）。Phase 1 用
   `@intFromBool` 报 0/1，N>1 时会让 `pool_claimed ≤ pool_threads` 这条契约读数永远停在 0/1 上。
3. **宽度有声明入口**：`SchedulerConfig.pool_threads`、`Application.Config.pool_threads`、
   `ApplicationBuilder.withPoolThreads(N)`、`Runtime.InitOptions.scheduler.pool_threads`，**默认 1**。
   不碰 runtime 的应用仍是零线程（D2 不变）；声明了池却没声明宽度的应用跑的还是**一条**线程，既有测试与
   读数逐位不变。宽度为 0 夹到 1（没有消费者的池只能把 token 堆在环里），并且**进环容量公式**：
   `capacity = ceilPowerOfTwo(max_pooled_workers + pool_threads)` —— 消费者在出队窗口里持有的是槽位。
4. **claim-miss 之后退避**（性能，不是正确性）：`turn()` 区分 `ran`/`skipped`/`empty`，**只有 `ran` 清零
   自旋预算**（"跳过"与"环空"共用预算），park 判据从"环里没有 token"换成"**环与我上次看到的一样**"
   （`pushes` 计数未变）。否则一条被 claim 住的 token 会让 N−1 条线程全速空转（Phase 1 时这个形状根本
   不存在）。代价如实说：持有者交还 claim 时**不**唤醒 parked 线程（生产者路径上没有 mutex/信号，这是刻意
   的），所以"偷"到那条 token 最多晚一个 `idle_wait_ms`（1 ms）。

- 实测（本机，真线程，`batch = 1`）：4 worker × 4 生产者 × 2 000 条、宽度 4 →
  `attempts = 8000`、`received = 8000`、`dropped_full = 0`、`dispatches = 8000`、**`overlaps = 0`**、
  `claim_misses = 0`、`ready_push_failures = 0`；宽度 1 同上且 `claim_misses = 0`（**可证**：能交还 claim 的
  线程就是唯一能再 pop 的线程）；宽度 3 用 OS 线程数量到"起 3 条 → 再 `start()` 不增 → `shutdown()` 回基线"。
- **`claim_misses` 的监控口径变了**（唯一一条读数含义变化）：宽度 1 恒 0（非 0 = 协议被破坏，读法不变）；
  宽度 > 1 **允许非 0** —— 回执先清 `queued`、两条指令后再清 `claimed`，生产者落在这中间就会推一个
  "worker 还在被跑"的 token，此时另一条线程 pop 到它、抢 claim 失败即一次 skip（token 被重推，不是丢）。
  这条窗口只有持有者被抢占时才会宽，本机 11 次跑全为 0：**不要把 0 当契约，也不要把非 0 当告警**；
  要盯的恒 0 读数是 `ready_push_failures`。结构上界 `claim_misses ≤ attempted + dispatches`。
- 新增测试（`src/runtime/scheduler.zig`）：`two consumers race one token and exactly one of them gets it` ·
  `a hammered ring hands every token to exactly one consumer` ·
  `the ring is sized for its consumers' windows (the Phase 1 size would refuse)` ·
  `N pool threads conserve messages and never run one worker twice` ·
  `with one pool thread a claim is never missed (the Phase 1 reading)` ·
  `the declared width is the number of threads started — and all of them are joined`；
  `src/runtime/runtime.zig`：`Runtime: N pool threads conserve messages and never overlap on one worker`；
  `src/Application.zig`：`e2e: the builder's pool *width* reaches the runtime a module spawns .pooled on`。
- **零分配契约未放宽**：`src/runtime/alloc_contract_test.zig` 未改（线程数组在 `Scheduler.init` 一次分配，
  环仍在同一处一次分配）。
- 文档：`docs/RUNTIME.md` 新增 **§12.12**（机制、红/绿证据、实测数字、`claim_misses` 口径改法与测试名），
  并按 N 更新 §12.3 / §12.6 / §12.7 / §12.8 D2 / §12.9 第 4 条、§8 的 `pool_threads` 读法。

## [0.29.1] - 2026-09-20

### 修复：`.pooled` 路径上的四个缺陷（**破坏性：否**）

四处都是 v0.29.0 里已经发出去的缺陷，**都在 `.pooled` 这条可选路径上**（`.dedicated` 默认不受影响），
而且共用一个形状：池把"某件事一定会发生"当成前提，却没有把它变成断言。每处都是**先写能红的测试**再改。

1. **`push` 把"出队窗口"读成"环满" → 丢 token → 那个 worker 永久停摆**（危害最大）。
   `ReadyRing.tryPop` 先推进 `dequeue_pos`、再释放槽位（`slot.sequence = pos + capacity`）；生产者在这两条
   指令之间读到的是**上一轮的序号**，被 Vyukov 的检查判成"满"。普通有界队列里这是保守答案（调用方重试），
   在这里却是丢一个 **token**：worker 的 `queued` 还是 true，别的生产者也不会替它推 ⇒ 这个 worker 再不被
   调度，而邮箱继续收条。本机实测（cap=4、4 生产者、1 个 CAS 消费者、各 20 万次 `tryPush`）：
   ReleaseFast `800 000` 次尝试中 `324 416` 次被拒、其中 **`187 053`** 次读到的 `len < capacity`（环并没有满）；
   Debug 为 `133 070` / **`60 986`**。修法两处都做：① 环容量按 `max_pooled_workers + pool_threads` 取
   （消费者在窗口里也占一个槽位）；② `push` 被拒后**自旋重试**（预算 `push_retry_rounds`），只有整个预算都
   没等到才计数 + Debug/ReleaseSafe 断言 —— 从此"环满"只表示真的满。守卫不变：`ready_push_failures` 仍必须为 0。
2. **`Scheduler.start()` 的懒启动不是原子的 → 起两条池线程、只记住一条 → use-after-free**。
   池是第一次 `.pooled` spawn 才启动的，于是两个并发 spawn 会一起走到 `if (self.thread != null) return;`
   与 `self.thread = try std.Thread.spawn(...)` 之间：两条线程都起，只有后写的句柄被记住，`shutdown` 只 join
   一条，另一条活进 `Scheduler.deinit` 的释放里。修法：`start_claim` 上的 CAS，输的一方等这次尝试有结论。
   改前实测 `expected 4, found 5`（多出来的那条线程**没有任何计数器看得见**，判据只能是 OS 线程数）+
   未释放的环/scheduler；改后 30 次连跑全过。
3. **`Delivery.post` 投递后不 `announceReady` → 定时器投递静默滞留**。`send*` 四条路径都通知就绪，定时器
   那条（`after` → `Tick` → `Delivery.post` → `enqueue`）没有：池化 worker 的就绪是**环里的 token**，不是停在
   `recv` 的线程，于是这条消息一直躺到"碰巧有别的 `send`"为止 —— 只被定时器喂的 worker 就是永远。
   修法：投递成功后按与 `send*` 相同的规则通知就绪（投递失败的那条直接返回，不推 token）。
4. **并发 `shutdown()` 崩溃**。`Runtime.shutdown` 的文档写"幂等"，但它不是**线程安全**的：两个调用方都进
   函数体、都读到 `Scheduler.thread`、都 `t.join()` —— 第二次 join 同一个句柄是 `INVAL` → `unreachable` →
   **ABRT**（调用栈：`std.Thread.join` ← `Scheduler.shutdown` ← `Runtime.shutdown`），`workers` 列表也会被走
   两遍。修法：`Runtime.shutdown` 整体进 `shutdown_mu` + `shutdown_done`（后到者等做完就返回），
   `Scheduler.shutdown` 的 join 也串行化。**对照实验**：同一份测试源码（只用公开 API）在未改动的基线
   （worktree @ `dd6df20`）连跑 8 次 **8 次全挂**（同一个 `INVAL` 断言），在修后的树上 **8 次全过**。

- 新增测试：`scheduler: a producer waits out the slot its consumer is mid-release on` ·
  `scheduler: a hammered ring never eats a token` · `scheduler: two concurrent first starts spawn exactly one
  pool thread` · `Runtime: a timer's delivery to a pooled worker arms its ready token` ·
  `Runtime: two threads calling shutdown at once are safe`。
- **零分配契约未动**：`src/runtime/alloc_contract_test.zig` 的精确分配计数一个数字没改（环仍在
  `Scheduler.init` 处一次分配，`push` 的重试路径不分配）。`poolStats().ready_capacity` 的口径随容量一起变
  （声明上界非 2 的幂时比旧口径大一倍），既有判据 `ready_capacity >= max_pooled_workers` 仍成立。
- 文档：`docs/RUNTIME.md` 新增 **§12.11**（四处的机制、实测数字、修法与测试名）。

### Runtime Replay v1：每个 worker 的**投递轨** + 按全局 seq 重放（**破坏性：否**）

§11 的 `Recorder` 记的是 **L0 扇出**（`HotBus.publish` 之前）；它回答"生产者发布了什么"，
不回答"每个 worker **收到**了什么"—— `Handle.send` 的直达投递、`after(...)` 的定时器投递、
以及 `MpscRing` 的跨生产者交错，它一条都不覆盖。要重放一次运行，缺的正是后者。

- **取点在 `Handle` 的投递漏斗**（`enqueue` / `enqueueBlocking`）：`send*` 与
  `Handle.after` 的定时器投递**都**走它。只挂 `send*` 会漏掉定时器那一半 ——
  `Delivery.post` 直接写邮箱，`after` → `Tick` → `Delivery.post` 这条链**根本不经过 `publish`**，
  而它在流水线里往往是关键节拍（快照、结算、超时）。记录发生在**邮箱接受之后**：
  轨记的是"投递成功的那部分"，`error.Full`/`error.Closed` 不产生条目。
- **不引入任何 codec**：异构 `Message` 的解法不是序列化，而是**每 worker 一条同类型轨**——
  轨内部仍是 `E` 的有界环、值放进去，所以仍然零分配、仍然值语义。多轨靠 log 的
  **一个 `Sequencer`** 打**全局** `seq` 归并（轨内的槽位是本地计数器：`slot` 本地、`seq` 全局）。
  `Recorder` 的存储半边抽成 `Slots`（槽数组 + per-slot ready + 连续 published 前缀），两条轨共用它；
  `Recorder` 的 slot == seq 语义与 §11 的全部契约（`error.Full` 不覆盖不静默丢、
  `HotBus.attachRecorder` 行为逐位不变）一字未改。
- **声明即上界**：`.record = .{ .id = "book:BTC", .capacity = 4096 }` 在 **spawn 点**给，
  与 §12 的池"默认不创建"同一条纪律：**没有"默认全记"**，内存是 `Σ(capacity × sizeof(Message))`，
  由调用方声明。**worker 标识也是调用方给的**（不从模块名派生 —— 派生会做出一个"模块名唯一"的
  隐含假设）。`Runtime.deliveryLog()` 懒创建：没有任何 `.record` 就没有 log、没有环。
- **重放**：`DeliveryLog.replayer(&Clock.Manual)` → `bind("book:BTC", fresh_handle)` →
  `step()` 按 `seq` 归并、把时钟推到该条记录的 `clock_ms`、把载荷投给绑定的 handle。
  **`step()` 不等待任何人**（不 sleep、不自旋、不 join）；`replayAll()` 是同一个循环。
  目标 worker 的 `ctx.clock()` 就是被驱动的那个时钟，所以重放出来的 handler 读到的是**录制时的时间**。
- **有洞就不放**：轨满 `record` 返回 `error.Full`（不覆盖、不静默丢），但 `send*` **不因此失败**
  ——消息确实进了邮箱。`DeliveryLog.refusedCount()` 计数 + 一条 warn，`Replayer` 见
  `hasOverflowed` 直接 `error.LogIncomplete`，**连部分也不放**（§11.6 起写死的禁忌：
  有洞的 log 看起来完整）。
- **新增一条拒绝（实现时发现）**：`bind` 拒绝目标**就在被重放的 log 里**
  （`error.TargetIsInSourceLog`）。把轨重放回它自己的 worker 会把每条重放投递再记一遍，
  新条目落在游标之后 → `step()` 再取到 → 自我喂养、`replayAll()` 永不结束（被测试撞出来的）。
- **验收（§13.4）**：两个不同 `Message` 类型的两条轨 + 中间一条 `after(...)` 定时器投递，
  录制与重放两次的 **handler 调用序列（顺序 + 载荷指纹 + handler 读到的时钟）逐条一致**，
  且 20_000_000 ms（≈5.5 小时）的录制跨度在 **< 1 s 墙钟**内重放完（不 sleep）。
- **零分配契约不放宽**：`src/runtime/alloc_contract_test.zig` 对 `Handle.send*` 的**精确**分配次数
  断言一个数字都没改（没声明 `.record` 时是一次空判断；声明了也只是"一次间接调用 + 值拷进预分配环"）。
- **Breaking：否**。`SpawnConfig` 多一个可选 `.record`，`Handle` 多一个默认 `null` 的 `track`；
  `spawnConfig` 顺带**拒绝未知字段**（`.recrod = …` 这种拼错过去会被静默忽略 ——
  对一条"重放完整性"依赖的声明，静默忽略是最坏的失败）。
- 文档：`docs/RUNTIME.md` §13.6 三个待定项定稿（per-worker 容量 / 调用方给标识 / `step()` 为主）、
  **§13.7 落地形状**（与草案的差异、边界、新增的 `TargetIsInSourceLog`）。**未做**：落盘（Q4 第 2 档，
  `TrackRef.payload_codec` 是预留位）、跨进程、指标面（拒绝数只在 log 上，见 §13.7）。
### `TimerWheel x100K` 的数组索引代价：量到机制，不改代码（**破坏性：否**）

上一轮把 `nodes` 换成 `AutoArrayHashMapUnmanaged` 时留下一条自注的观察 —— "`x100K` 在 map 级测量里数组表贵
7–18%，门禁内 1.03×，余量不算大"。本轮把它当**待验证的假设**重测，而不是引用旧数字：同一台机器、交错 A/B、
每轮两种先后顺序各测一次（抵消"后测的那一臂占便宜"），并在**同一轮里**跑 A/A 对照（两臂是同一份代码）
当这台机器（10 核、负载均值 10–15、同时有别的构建在跑）的分辨率下限。10 万个键：

| 形状 | array / hash（配对中位数） | 同轮 A/A 对照 |
|---|---|---|
| 新建 map、**不含扩容**（预扩容，计时区内零分配） | **0.94×（快 6%）**，最好样本 12.65 / 14.04 ns | 0.995× |
| 新建 map、**含扩容**（= `Wheel.schedule` 的真实路径） | **1.25×** | 1.003× |
| 删除（`fetchSwapRemove` vs `fetchRemove`） | **1.73×** | 1.06× |

- **机制是扩容，不是探测距离或局部性**：数组表要维护**两份结构** —— entries 被复制（18 步 ×1.5 增长，合计 5.6 MB），
  index 每次重建都要新分配 header、`@memset` 之后把全部条目重插一遍（10 次，合计 3.7 MB）。同一份 10 万定时器整轮
  （计数 allocator）：数组表 34 次扩容分配 / 14.75 MB / 峰值 9.53 MB，旧哈希表 15 次 / 10.06 MB / 7.83 MB。
  数组表**活着**的索引本身就是 262144 × 8 B = **2.1 MB**（`Index(u32)` = `entry_index` + `entry_distance`），
  比旧哈希表整张桶数组（131072 × 16 B = 2.1 MB）还大。先把容量给足，数组表插入反而**快 6%** ——
  "占用 ≤60%" 正是它插入快的原因，扩容就是它的价。
- **判据面（`TimerWheel x100K`）的差值远小于 map 级**：整轮 = schedule 半边 + advance 半边，map 只是其中一部分。
  150 轮交错下 A/B 配对中位数 1.12–1.17，而**同轮 A/A 对照中位数 1.08**；换成固定缓冲（预触页、无 free、
  去掉分配器噪声）后最好样本 50.85 / 48.75 ns/op = **1.043×**。即差值在**低个位数百分比**，而对照本身就有
  6–8% 偏置 —— 在这台被共用的机器上这是分辨率下限，不是可判定的回退。
- **所以不动 `timer_wheel.zig`**：门禁余量仍接近 1.8×（基线 6.808 ms、阈值 2.0×），而任何
  "修法"都等于放弃数组表（= 退回 `TimerWheel churn x1M` 的 265 ms）或重写 std 的哈希表；代价只是"轮子长到
  10 万个活定时器时多付约 5 MB 扩容流量"。**没有跨宿主离散度就不动判据**：不调 `BENCH_THRESHOLD`、不改基线、
  不重录 —— 本轮三次实测（6.21 / 7.47 / 7.63 ms，同一份二进制、负载均值 25 / 15 / 12）对 6.808 ms 是
  0.91–1.12×，`check-bench.sh` 自己那次 27 条全绿（exit 0），仍然在 2.0× 窗口内。
- 守卫未动、仍然好：`Wheel: a long-lived wheel's lookups do not get slower as it ages` 单文件三种优化模式
  **19/19 全过**（Debug / ReleaseSafe / ReleaseFast 逐一跑）；同一份 A/B harness 上 `TimerWheel churn x1M` 形状
  29.81 ms 对改动前实现 277.23 ms（**9.3×**，方向与 9.6× 一致），门禁那次 28.76 ms 对基线 28.193 ms（1.02×）。
- 记录落在 `docs/BEST_PRACTICES.md`（`[pct]` 那节最后两条，含完整对照表与机制）与 `scripts/check-bench.sh`
  头部；顺带修掉两处因上一轮换表而**过期**的文档句子（`[pct]` 一节把 `nodes` 写成"哈希表…桶数组 ~3.5 MB"，
  `[alloc]` 一条把扩容次数写成 15）。

## [0.29.0] - 2026-09-19

### 定时轮：长生命周期轮的 id 查找不再随年龄退化（**破坏性：否**）

一轮 `[alloc]` 插桩分测顺手量到的东西，最后是一个**与生产形态直接相关**的缺陷：
基准里的轮是**每批新建**的，而运行时的轮**活整个进程**（`src/runtime/runtime.zig` 的 ticker 持有它）——
"复用"不是基准的特殊形态，它就是生产形态。同一份 1000 轮 × 100 定时器、两边交错测量的循环，本机实测
（`schedule` 半边，p50 / 最小）：

| 形状 | BEFORE（`AutoHashMapUnmanaged`） | AFTER（`AutoArrayHashMapUnmanaged`） |
|---|---|---|
| 每轮新建一个轮 | 28.3 / 24.2 ns/op | 27.1 / 20.4 ns/op |
| **同一个轮复用 1000 轮**（生产形态） | **233.8 / 59.2 ns/op** | **13.3 / 10.0 ns/op** |

即"复用/新建"从 **8.3×** 变成 **0.49×**，复用轮自身 233.8 → 13.3（**17.6×**）。

- **根因（`nodes` map，不是轮本身的代码）**：`std.AutoHashMapUnmanaged` 用墓碑删除，而它的增长预算
  （`available`）**把墓碑也算作可用**。于是"长生命周期 + 每次都是新 id"的 churn 会把表**排干成墓碑**：
  本机逐轮普查得到空槽 28 → 6 → 1 → 0，第 5 轮起就是 **128 个墓碑、0 个空槽**（表共 128 槽），
  此后每次 `put` 都要走完整个表（`avg miss probe` 从 10.8 步变成"走满容量"）。这个状态是**吸收态**：
  之后每次插入回收一个墓碑而不是消耗空槽；而增长要求 `size == max_load`，100 个活定时器永远到不了，
  所以**永不恢复**。
  对照实验排除掉的候选：**容量不回缩/缓存缺失**——把表预撑到 131072 槽（2MB）照样排干到 0 空槽，
  而 4194304 槽且有空槽的表比 256 槽无空槽的表**快 15 倍**；变的是"探测到第一个真空槽要走多远"。
- **修法**：`nodes` 换成 `std.AutoArrayHashMapUnmanaged`（后移删除，没有墓碑；索引重建保证占用 ≤60%，
  空槽是结构性保证而不是 churn 历史的函数）。生产形态 233.8 → **13.3 ns/op（p50，17.6×）**；
  `cancel` 侧 12.9 → 14.6 ns（+13%）；`advance` 不变（16.7 → 17.5 ns）。
- **契约没有放宽**：轮仍是 ticker-only（`claimOwner`/`assertOwner` 没动）；`src/runtime/alloc_contract_test.zig`
  的**精确**分配次数断言**一个数字都没改**（首次 `schedule` 仍是 2 次、`cancel`/`advance`/`drainAll` 仍是 0 次——
  数组哈希表在 ≤8 个条目时只分配 entries、索引头到第 9 个条目才出现，所以这些窗口内计数不变）。
  文件里原有 18 条用例一个没改、全部通过。
- **守住它**（这是本次的核心交付物）：新增 `timer_wheel.zig` 用例
  `a long-lived wheel's lookups do not get slower as it ages` —— 老实现下**红**
  （ReleaseFast 15.0 → 203.9 ns，**13.6×**；ReleaseSafe 10.6×；Debug 173.3 → 2143.9，**12.4×**），
  新实现下 0.65×–0.99×；以及基准新增 `[med3]` 指标 `TimerWheel churn x1M`（已进基线，
  老实现 265.46 ms → 新实现 27.57 ms，**9.6×**，判定阈值仍是 2.0×）。
- **`TimerWheel x100K` 不回退**：门禁测量 7.02 ms 对基线 6.808 ms（1.03×，判定 2.0×）。
- `docs/RUNTIME.md` §4 增加"为什么 id 索引是数组哈希表"；`scripts/check-bench.sh` 头部记录新条目的来源
  与"CI 基线暂未收录、别把本机值抄过去"的原因。

### 定时器"触发了但没投到"现在有计数（**破坏性：否**）

`Handle.after` 的投递回调（`Delivery.post`）在 `mailbox.send` 失败时**只打一行 debug 日志**：
定时器已经触发（`timer_fires` 动过），那条消息却没进目标邮箱，而**没有任何计数**记下它 ——
上一轮"丢弃必须可见"清单里剩下的最后一个洞。debug 日志在生产里默认关着，所以实际读数只有 0。

`send` 在这里有且只有两个失败出口，两个都覆盖并各有测试：`error.Closed`（那个 worker 已经停了）
与 `error.Full`（它的队列还满着）。

- **第四个原因，第四个数**：新增 `RuntimeStats.timer_deliveries_dropped`（运行时累加，
  `Handle` 侧没有对应字段）。它与既有三个数各不重叠：
  - `messages_dropped`（= `dropped_full`）：**生产者**在自己的调用点被满邮箱拒收 —— 调用方当场在场，
    消息从未被接受；`timer_deliveries_dropped` 是运行时替一个**已经跑完的定时器**丢消息，没有调用方在场。
    （`error.Full` 那一半会让两个数同时涨 —— 就是同一个 `send` 拒的 —— 这正是它存在的理由：
    只有这个读数能把"生产者在挨背压"和"定时器的消息没到"分成两件事。）
  - `messages_discarded_on_stop`：消息**被收下过**（`send` 返回过成功）然后被停机放弃；
    这里 `send` 从来没成功过，什么都不在队列里。
  - `timers_discarded`：定时器**没触发**就被释放（停机/取消）；这里 `timer_fires` 已经涨了。
- **停机窗口的典型形状**：worker 先停（邮箱关闭）、定时器随后到点 —— 于是它跳一次而
  `messages_dropped` 不动。持续增长则是另一回事：定时器在往一个长期跟不上的 worker 上投活儿。
- **第 17 条 gauge**：`zigmodu_runtime_timer_deliveries_dropped`（`Runtime.MetricsBridge`，
  16 → 17 条）。桥仍是鸭子类型（`createGauge` + `Gauge.set`），runtime 层不依赖 observability 层。
- **那行日志保留**（改的是 `catch |err| <计数 + 日志>`，不是退化成裸 `catch {}`）：日志回答"哪个 worker"，
  计数回答"多少次"。`scripts/check-production.sh` 照旧通过。
- **测试（先红后绿）**：两条生产路径各一条测试 —— 关闭邮箱（`error.Closed`）与满邮箱（`error.Full`，
  用一个不 `recv` 的 `run` 型 worker 制造，避免竞态）、外加一条 bridge gauge 注册 + 随运行变化的测试。
  未改生产代码时红（两种形式都贴过）：① 运行期守恒式
  `s.timer_fires == s.messages_received + s.timers_discarded` → `expected 1, found 0`；
  ② 补字段前 → `src/runtime/runtime.zig:1884:48: error: no field named 'timer_deliveries_dropped'
  in struct 'runtime.runtime.RuntimeStats'`。
- **零分配契约不变**：热路径（`Handle.send*` / `Runtime.scheduleAction`）与 `Handle.after` 的分配次数
  一行未动（计数是一次 `fetchAdd`），`src/runtime/alloc_contract_test.zig` 的断言一个字没放宽。
- **语义写进 `docs/RUNTIME.md`**：§5 第 2 条（四种原因各自的定义与"故意不合并"的理由）、§8（读数含义 +
  `timer_fires` 的配对读法）。

### 监督停机丢掉的剩余消息，现在有计数（**破坏性：否**）

`spawnActor` 判停时 dedicated worker 直接跳出接收循环，邮箱里剩下的消息**被丢弃且没有任何计数** ——
唯一一处不可见的静默丢弃（`HotBus.dropped` / `Mailbox.dropped_full` / `timers_discarded` 都计数）。
实测（同一 failing actor、8 条投递、`Clock.Manual`）：dedicated `handled=2/8`、停机时 `mailbox_len=6`、
`dropped_full=0`；pooled `handled=8/8`、`mailbox_len=0`。**停机行为不改**（正在停的 actor 不该继续干活），
补的是那个数字。

- **两个原因，两个数**：新增 `WorkerStats.discarded_on_stop` / `RuntimeStats.messages_discarded_on_stop`
  —— "收下了、然后被停机放弃"，与 `messages_dropped`（生产者被满邮箱拒收即 `error.Full`，消息从未被接受）
  **故意分开**。合并计数会把"调用方在挨背压"读成"某个 actor 停机扔了队列"，两者的处置相反。
  语义写进 `docs/RUNTIME.md` §5 第 2 条与 §8。
- **计数点两处，都是实测可复现的**：① dedicated 的循环出口（`Handle.countAbandoned`，
  监督停机时 `break` 走人那一条）；② `Runtime.shutdown` 的收尾 —— 先停池（§12.6），全部 join 完、
  destroy 之前把还压在邮箱里的条数记下（`Entry.abandon`；不放在 `join()` 里，因为 `join()` 可以被早调，
  那时池还活着，那个时刻还不是"没人能跑它们了"）。计数**只取增量**，所以收尾那趟对每个 worker 都跑、
  而 dedicated 已报过的 6 条不会变成 12；顺带兜住 `close()` 与 `send` 的竞态窗口（晚到的那一条在
  循环出口读不到，在收尾那次读得到）。两处都只 `+=` 计数，**不抽干**：那批消息是值，
  环随 handle 一起销毁，留着它们反而让 `mailbox_len` 诚实；抽干会顺带把它们记成 `received`，而
  `received` 的含义是"worker 取走准备处理的"。
- **计数按运行时累加，不按存活 worker 求和**（`messages_dropped` 是后者）：被放弃的消息**正是**
  在 `shutdown` join + destroy 的同一趟里发生的，求和写法会在能读到它之前归零。
  `RuntimeStats.messages_discarded_on_stop` 因此在 `shutdown()` 之后仍可读；`timers_discarded` 同形。
- **第 16 条 gauge**：`zigmodu_runtime_messages_discarded_on_stop`（`Runtime.MetricsBridge`），
  只在停机时跳一次，和随生产者压力动的 `messages_dropped` 是两条曲线。
- **测试（先红后绿）**：两条断言表本身的测试（dedicated 6 / pooled 0，含守恒式
  `sent == received + dropped_full + discarded_on_stop`，dedicated 那条再断言 `shutdown()` 不会把 6 报成 12）、
  一条"池先停、worker 手上还有 3 条"的测试（断言计数不随 worker 销毁消失）、
  一条 bridge gauge 注册 + 随运行变化的测试。
  未改生产代码时红：`expected 8, found 2`（守恒式右边少了那个计数）；补字段前红：
  `no field named 'discarded_on_stop' in struct 'WorkerStats'`。
- **零分配契约与停机路径不变**：热路径（`Handle.send*` / `scheduleAction`）一行未动，
  `src/runtime/alloc_contract_test.zig` 的断言一个字没放宽；停机顺序、`stop()` 语义、`join()` 契约照旧。

### WorkerPool Phase 1 —— `spawn(..., .{ .mode = .pooled })`：长尾 worker 共用一条池线程（**破坏性：否**）

`spawn` 一直是「一 worker 一线程」：`allocator.create(Handle)` + `std.Thread.spawn`。对
`行情 → 订单簿 → 风控 → 执行` 这种链是对的，对长尾（symbol / 房间 / 会话 / 指标扇入）到了顶 ——
"worker 数"变成"数据维数"，每个都吃一个栈、一个调度实体、一次上下文切换。Phase 1 落地
`docs/RUNTIME.md` §12 的设计：worker 还是那个 `W`（同一份 `handle`、同一个有界邮箱、同一套契约），
只是可以由**池线程**运行，状态独占从"按线程身份"换成"按排他声明"（`claimed`）。

```zig
var rt = try Runtime.initWithOptions(allocator, io, .{ .scheduler = .{ .max_pooled_workers = 64 } });
const audit = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
// 既有调用点一行不用改：第三参同时接受 `256` 与 `.{ .capacity = 256, .mode = .pooled }`
const book = try rt.spawn(OrderBook, .{}, 256);   // 仍是 .dedicated
```

- **API/兼容**：`spawn` / `spawnActor` / `spawnSupervised` 的最后一个参数改为 comptime 归一化
  （`spawnConfig`）：**位置容量（`256`）原样可用**，新增配置结构形态。`.dedicated` 是默认，
  行为逐位不变（`Handle.thread`、`join()`、`running` 语义在 dedicated 下与 v0.28 相同）。因此
  **不是源码级 Breaking** —— §12.9 第 2 条预期的迁移没有发生。
- **不能池化的形态是编译期错误**：`run` 型 worker 自带循环，池化等于让一条池线程被它独占；
  `spawn(..., .pooled)` 对它 `@compileError`（报错文本点名 `.dedicated` 与 `handle`）。
  这条守卫在测试套件里断言不了（触发它就是本文件编译失败），所以和 `check-tenant-scope.sh` 同形
  加了 `scripts/check-pool-guard.sh`：一个必须失败的 fixture + 两个必须通过的。
- **配置错误不留后门**：没在 `initWithOptions` / `Application.Config.max_pooled_workers` 里声明池就
  用 `.pooled` → `error.PoolNotConfigured`（不"顺手起一条线程"）；声明的上界是硬上限，
  第 `max+1` 个 `.pooled` spawn → `error.PoolCapacityExceeded`。
- **那条派生不变量**（§12 原文没点透，落地时必须成立）：**就绪环的容量 ≥ 可池化 worker 数**。
  D4（每 worker 在环上至多一项）⇒ 占用上界 = worker 数 ⇒ 容量取 `ceilPowerOfTwo(max_pooled_workers)`：
  **按声明的上界算出来，不是常数**。因为环里的 token 是"一个 worker 的调度权"，不是消息：
  丢 token = 那个 worker 永远不再运行（邮箱继续收、`send` 继续成功）。所以环满**不是背压**：
  `push` 失败要 `std.debug.assert` + `ready_push_failures` 计数（`Runtime.poolStats()`），
  绝不当普通满队列丢掉。
- **两处对设计草案的收紧（实测出来的，不改会丢 worker）**：① 认领失败要**重推** token（§12.4 写的
  "抢不到就跳过"）；② 批量结束只留**一条回执出口**，顺序固定 `清 queued → 清 claimed → 重查邮箱 →
  赢位才 push`（§12.4 的"保持 claimed 并重新入环"有一个 token 在环里而 claim 仍被持有的窗口，
  跳过的 token 会永久停掉一个 worker）。②里"赢位才 push"是被并发压力测试抓出来的：无条件 push
  会留下两个 token，而容量正是按"每 worker 一个"算的。
- **零分配契约不松**：`Handle.send*` 在池化下仍 **0 次分配**（新的 `alloc contract: a pooled Handle.send…`
  用例，`src/runtime/alloc_contract_test.zig`）；就绪环在构造时定容，推 token 是往槽里写一个值。
- **停机顺序多一步**（§12.6/§12.9-3）：`alive=false` → 停 ticker → **停池线程（join）** →
  断言没有 worker 还握着 `claimed` → request/join/destroy worker。池线程只在批次之间退出，
  所以"停机时它正在跑某个 worker"的窗口里 `handle` 会先跑完（worker 不返回就拖着停机，与 dedicated 一致）。
- **生命周期差异（写清以免误读）**：`.pooled` 的 `init` 钩子在**第一条消息的批次里**跑（池线程、
  claim 内），`deinit` 在 `shutdown()` destroy 前跑；从未收到消息的 pooled worker 两个钩子都不跑。
  `RuntimeStats.running` 对 pooled 表示"正被 claim"（上界 = 池线程数）。
- **测试**：协议在 `src/runtime/scheduler.zig` **不用线程**直接驱动（`step`/`runOne`），所以
  "同一 worker 不会被两条执行路径同时跑"和"handler 执行期间到达的消息不被丢"是单元级断言而不是
  "只有一条线程所以侥幸过"；端到端覆盖在同文件与 `src/runtime/runtime.zig`（含 3 生产者 × 200 条、
  `batch = 1` 把回执窗口打满、断言一条不丢；以及"停机时池线程正在跑"的 UAF 窗口）。
  `zig build test` 全绿。
- **没做（Phase 2 起）**：多池线程、`batch` 实测调优（16 是 D3 的设计起点，不是结论）、公平性加权、
  affinity/NUMA、per-worker batch 覆盖。见 `docs/RUNTIME.md` §12.10。
  （池的 Prometheus 指标原文也在这个清单里 —— 已被下面那条补上。）

### 补上 Phase 1 的三处 `TODO`：示例真跑池 · 池的 Prometheus 指标 · CLI 认识池（**破坏性：否**）

Phase 1（上一条）留下了三处"设计/单测都对，但没真跑过 / 没接出去"的缺口。这轮逐个补掉，
原则是**从运行中读出来的数**而不是常量：

- **示例真的跑池了**（`examples/runtime-workers`）：`audit` worker 改为
  `.{ .capacity = 64, .mode = .pooled }`，池的上界在 app builder 上声明
  （`b.withMaxPooledWorkers(1)`）。选它的理由对着 §12.5 的边界：消息驱动、故意慢、
  且不在 `feed → book → risk` 的延迟链上 —— 那条链每一跳都进关键路径，继续 `.dedicated`。
  运行时打印 `[pool] declared=1 threads=1 spawned=1 dispatched=N claimed=0 ready_len=0 push_failures=0`
  并**在 `dispatched == 0` 或 `push_failures != 0` 时以非零退出码结束**：编译过不算数，
  每次 `zig build run` 都验证"token 真的到了池线程"（`spawned` + `dispatches` 只能由池化路径抬高，
  dedicated worker 从不往就绪环里放 token）。示例的业务逻辑一行未改，只改执行模式与接线。
- **池进了 Prometheus**：`Runtime.MetricsBridge` 新增 6 条 gauge —— `zigmodu_runtime_pool_declared` /
  `pool_threads` / `pool_ready_len` / `pool_claimed` / `pool_dispatches` / `pool_ready_push_failures`
  （共 15 条）。`pool_dispatches` 是"池真的被用了"的远程可读证据，`pool_ready_push_failures`
  照旧是**必须恒 0** 的契约读数（§5 第 4 条：那不是背压，是调度器失联）。没声明池的 runtime
  这 6 条**报 0 而不是缺行**。鸭子类型契约没变（仍只要求 `createGauge` + `Gauge.set`）。
  读数来自 `Scheduler.Stats` 新增的 `pool_threads` / `claimed`（后者由 `step`/`runOne` 的
  claim 生命周期计数：批次的 claim 真的交还之后才减）。
- **`zmodu runtime` 认识池的两种写法**：`.max_pooled_workers = N` 与 `withMaxPooledWorkers(N)` 各报一条
  带 `file:line` 的事实，另加"有几条 spawn 写了 `.mode = .pooled`"（`spawn Audit mailbox 64 mode=pooled`）；
  `--json` 每个 worker 多一个 `mode` 字段（`null` = 该调用没写 mode —— API 默认是 `.dedicated`，
  但**默认值不是文本说的事**，所以不填）与顶层 `pool` 对象。仍然只报看得见的事实：不判断声明的池与
  `.pooled` 的 spawn 是否同一个 build，也不判断可达性。
- **顺手修掉一处真接线缺口**：`Application.Config.max_pooled_workers` 文档里承诺"`app.runtime()`
  创建的 runtime 按它 sizing"，但 `Application.init` 的结构体字面量**没有拷贝这个字段**、
  `ApplicationBuilder` 也没有对应方法 —— 即通过 builder/`Application` 路径**根本声明不了池**
  （恒为 0，`.pooled` 必然 `error.PoolNotConfigured`）。现在 `init` 会拷贝，
  builder 多了 `withMaxPooledWorkers(n)`，并补了端到端用例（模块在 `ctx.runtime()` 上 `.pooled` spawn、
  断言 `poolStats().max_pooled_workers` 与 `dispatches ≥ 1`）。这也是示例能声明池的前提。
- **顺带实测到一处两种模式不一致（只记进文档，未改行为）**：`spawnActor` 监督停机后，dedicated 的
  worker 直接 `break`（邮箱里剩下的消息被丢弃、且不计数），pooled 的 worker 会把邮箱**抽干**
  （每条剩余消息都再跑一次 `handle`）。同一个 8 条的探针：dedicated `handled=2/8`、pooled `handled=8/8`。
  §12.10 的生命周期表原本只写了"池把邮箱抽干后不再排 token"，没有点出**它与 dedicated 的差别**，
  现补一行实测记录与"Phase 1 不改"的理由（要统一得先决定丢弃的剩余消息是否该有计数）。

### `check-version.sh` 跳过 `test { … }` 块内的版本形字面量 —— 消除的是一类误报（**破坏性：否**）

tag `v0.27.0`（`1c705e5`）的 `bash scripts/check-version.sh` 红了**两条**，都在同一个文件里：

```
check-version: tools/ hard-codes version 0.26.0 -> tools/zmodu/src/incremental.zig:190:    try saveManifest(allocator, io, dir, &entries, "0.26.0");
check-version: tools/ hard-codes version 0.26.0 -> tools/zmodu/src/incremental.zig:232:    ...（同上）
```

两处都是 `test` 块里的 **fixture 值**（`saveManifest` 的 `version` 形参），不是版本**引用**。门禁的意图
是抓"包清单 / 文档 / 面向用户的字符串里写死的框架版本"—— 而 `test` 块里一个任意字符串既不发布也不生成
任何东西：值改成什么都能过，所以它是**误报**。修法落在门禁一侧：**tag 未移动、未新增 tag、未改发布内容**，
消除的是这一**类**误报（不是把那两个字面量改成别的字符串 —— 那只是修实例）。

- **只放宽这一处**：`scripts/check-version.sh` 第 2 节（"其它 0.x.y 字面量必须有意为之"）跳过 `test { … }`
  块内的命中 —— 只有这一个豁免。其余规则一字未动：第 1 节的 pin、第 3 节的 CLI 包版本、第 4 节的 WARN
  照旧。请求只发往 `.zig`（test 块只存在于 Zig 源码），其它文件照旧走 `grep`；且**只有确切回答
  "在 test 块里"才抑制命中**（文件被删/变短等异常一律保留命中），过滤器不会吃掉真引用。
- **不继承 `check-production.sh` 的宽豁免**：那个门禁的 `zig_skip()` 还跳"注释行"和 `\\…` 模板行（注释里的
  `// catch {}` 不是违规）。版本字面量没有这个理由 —— 模板行正是要写进生成项目的版本。所以共用的状态机
  `zig_in_test()`（花括号配对，顶层或缩进均可）只回答"这行在不在 test 块里"，`zig_skip()` 在它之上加那两个
  豁免：`check-production.sh` 用 `mode=catch`（= `zig_skip`），`check-version.sh` 用 `mode=at-test`
  （= `zig_in_test`），两处不可能漂移。实测本仓 `tools/` 的 33 处命中：**只有 2 处被丢**，都在 test 块里
  （`market.zig:516-517` 那段 `remote_json` fixture 的 `min_version`）；另有 7 处**注释/模板行在 test 块外**
  的命中**照旧被检查**（若继续用宽豁免，它们会被静默放过 —— 那才是削弱）。
- **`test {` 与 `test "name" {` 同一条规则**：`strip_code` 先把测试名（字符串字面量）抹掉，两种写法都变成
  `test  {`；先剥离字面量也让 test 里的 `"{}"` 不会打乱花括号配对。重构后对 `src/` + `tools/zmodu/src/`
  的 **284 个 .zig 文件逐一比对**新旧扫描器输出：**0 处差异**；`check-production.sh` 输出与改动前基线
  **逐字节相同**（`check-production: OK`，exit 0）。
- **反证（实跑，同一棵树，三种"非 test"形状都要照旧报红）**：在 `tools/zmodu/src/main.zig` 非 test 处插入
  一个注释行 `// probe-comment: legacy 0.31.7`、一个多行字符串行 `\\probe-prose 0.31.7`、一个普通代码行
  `pub const legacy_probe_pin = "0.31.7";` → `exit 1`，三行全部点名（`main.zig:27` / `:29` / `:31`）；
  把**同一个字面量**挪进 `test "cli submodule coverage gates …"` 内 → `exit 0` 且不再点名该文件。
  还原后 `shasum tools/zmodu/src/main.zig` = `87e3430a2f27b57eff76071677ff1c5e2f9b07cd`（与改动前一致）。
- **`v0.27.0` 现在绿**：重新 checkout `v0.27.0`（`1c705e5`）的 worktree，把改好的 `check-version.sh` 与
  `scripts/lib/zig-scan.awk` 复制进去（两边 `shasum` 一致：`27f525e9…` / `2da3b4a0…`），
  `bash scripts/check-version.sh` → `exit 0`（`check-version: OK (0.27.0 consistent across docs and tools/)`）；
  scaffold 依赖哈希那条 WARN 仍在 —— 它按设计如此（哈希只能在 tag 推出去之后重算）。**tag 未移动、未新增
  tag。**
- **不改发布记录**：另一条路是移动 `v0.27.0` 的 tag，但修复提交在该 tag 之后 12 个提交，移过去等于声称
  v0.27.0 包含整批后续加固；补一个 `v0.27.1` 也修不了 `v0.27.0`（那个 tag 仍旧红）。两条都歪曲发布内容。

### Benchmark 门禁：`RingBuffer SPSC x1M` 改用比值判据 —— 它是宿主的内存序实现，不是代码（**破坏性：否**）

`624b423` 的 CI Benchmark 闸门只红一条：

```
FAIL: 1 metric(s) slower than the baseline by more than 2.0x (lower is better):
  [absolute] RingBuffer SPSC x1M: baseline 1.090 ms → actual 2.336 ms (+114.3%)
```

该提交只动 `src/runtime/timer_wheel.zig`（`benchRingBuffer` 直接用 `rt.RingBuffer(u64, 1024)`，与时间轮
**不可达**）。逐条排除后，结论是：**这条指标的绝对毫秒判据不成立**，而 `1.090` **不是**被优化掉的伪值 ——
它是一条真实循环在另一种宿主上的真实数字。

- **代码被排除在指令级**：交叉编译 `facef4c` / `624b423` 两份 `x86_64-linux` benchmark 二进制
  （`zig build benchmark-build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Ddb=none`）逐指令比对：
  `benchRingBuffer` 内联进 `benchmark.main` 的三条展开副本（`0x106fd8a` 起）**编码与地址逐字节相同**，
  唯一差别是 call 重定位位移（链接布局挪了 `0x400`）；整份二进制的差异（374816 → 375046 条，
  改动 271/501 条）全部落在时间轮被内联的那段路径上。
- **不是被 LLVM 折掉的循环**（三条独立证据）：① 汇编里 slot 的 store 与 load 都在（`movq %rax,
  0x100(%rbx,%rsi,8)` / `movq 0x100(%rbx,%rdx,8), %rdx`），计数循环 `cmpq $0xf4240` 也在；
  ② 该循环**对 count 线性** —— 100K/1M/4M/16M = 1.035 / 10.840 / 42.775 / 173.171 ms（10.35-10.82 ns/iter）；
  ③ 把 sink 换成**不可能被折叠**的形式也不变：带内存 clobber 的指针形式 10.43 ms、把 pop 值累加进
  循环携带依赖的 `acc +%= v` 形式 10.98 ms（对生产形式 10.84 ms 在 ±3% 内）。
- **宿主档才是变量**：16 次 CI run 的记录里，同一份代码在**同一宿主上稳定到 3 位有效数字**
  （1.24 / 1.24 / 1.24 ms），跨宿主**台阶式**跳变：1.09（EPYC 9V74）、1.24（EPYC 7763）、1.26-1.57、
  **2.34（WestUS3 Intel Xeon Platinum 8370C）**—— 而红的那次 run 恰好就是唯一落在 Xeon 上的那次，
  同 run 的机器标尺 `atomic RMW x10M` 是 **60.58 ms**（EPYC 上 20.67 / 23.68 / 23.69）。折掉的循环不会
  随宿主变，所以这既是"没折"的反证，也是红的成因。
- **10× 倒挂的机制**：把 `src/runtime/ring.zig` **逐字复制**后只把 `.release`/`.acquire` 换成 `.monotonic`
  （其余一字不改），同一个 `benchRingBuffer` 循环在本机（M1 Pro）从 **11.70 ms → 0.954 ms**（12.3×），
  而 0.954 ms 正是 runner 上的那个数 —— x86 上 release store / acquire load 就是普通 `mov`，
  arm64 上是 `stlr`/`ldar`。所以这条指标量的是**宿主的 release/acquire 实现 + store-to-load forwarding
  延迟**（每轮的关键路径是 `tail`/`head` 各一条 store→load 链），不是框架代码。
- **修法（两条基线各一处）**：`RingBuffer SPSC x1M` 加入 `NORMALIZED_METRICS`，与那五条原子路径指标一样
  按 `指标 ÷ 'atomic RMW x10M'` 判比值（成员的准入规则从"每轮全是原子 RMW"改写为"每轮的关键路径是
  单个内存序原语"）。`scripts/bench-baseline.json` 只改这一条（`10.471 ms` → 比值
  `0.4976` = 10.706 ÷ 21.503，本机一次录制），其余 25 条按文件头部约定手工还原（`--update` 会全量重写）；
  `scripts/bench-baseline.ci.json` 同样只改这一条，比值 `0.0524` 取三次 **runner 实测对**的中位数
  （1.24/23.68、1.24/23.56、1.09/20.67），不是从本机推算的。**未改 `BENCH_THRESHOLD`（仍 2.0×），
  未整份重录基线**。
- **旧值为何不能留**：`1.090 ms` 是"某一档宿主的毫秒数"，被当成"代码的毫秒数"用；同一份二进制在 Xeon
  档上就是 `2.34 ms`。比值判据把宿主约掉（EPYC 0.0523-0.0527，Xeon 0.0386 —— 这条的比值只**近似**
  跟踪参考，26% 的离散度 vs 绝对值 2.15× 的离散度，仍远在 2.0× 窗口内），且**不削弱**对真回归的敏感度：
  循环里多一次分配/多一个原子都会把 `ms` 推上去，而分母同一轮不变，比值随之上升，闸门照旧报红。
- **更正 v0.28.0 段的一条记录**：那里写的"`RingBuffer SPSC x1M` 是唯一**不随机器缩放**的指标
  （runner 1.09 ms vs 本机 10.6 ms，慢机器上反而更快）"读法要改 —— 它**随宿主缩放**，只是缩放的是
  release/acquire 的实现成本，两个机器档在这条上相差约 10×，所以跨档比较依旧无意义（本机对 CI 基线
  仍然只红这一条，9.37×）。`scripts/check-bench.sh` 头部那段注释按实测机制重写。

### 时间轮的推进口径修正：非对齐 deadline 不再晚 640ms、也不再提前一格（**破坏性：否**）

`Wheel.advance` 的 level-0 槽 walk 有 off-by-one：它先 `index[0] += 1` 再走槽，却拿 `now_ms + slot_ms`
（该槽的**起点**）当触发阈值 —— 走在**下一个**槽上、阈值只到它的起点，于是槽内 deadline 大于该阈值的节点被
`expireSlot` 重新 `insert` 回**刚走过的那个槽**，要再等 64 个槽（64 × 10ms = **640ms**）才被看见。同一处偏差的
另一半是**提前触发**（阈值取的是上一轮的 `now_ms`）：`after(14)` 在第 4ms 就发出。两者都与
`docs/RUNTIME.md` §3（以及 `docs/UPGRADING.md` 的 v0.28.0 段）承诺的
`[delay_ms, delay_ms + 入队延迟 + tick_interval_ms]` 冲突 —— 而既有测试的 deadline 全是槽对齐的
（`after(50)`@1000→1050、`schedule(1050)`、5000/5030…），唯一的 ticker 用例自旋预算 4 亿次，所以一直没红。

- **新的推进口径**（`src/runtime/timer_wheel.zig`）：一次 `advance(now)` 先钉住 `now_ms = now`，然后
  ①**已经走过的槽**（`index[0] < target0`）**整槽过期**，阈值取**槽终点**（≤ `now`，槽里每个节点都已到期，
  因此不存在"被塞回刚走过的槽"这回事）；②**`now` 所在的槽**交给新的 `sweepDue`：**只发到期的那部分**，
  没到期的**留在槽里**（`next`/`prev`/`level`/`slot` 原样不动，`cancel`/`drainAll` 照样找得到），下一个 tick 再看。
  于是 `advance(now)` 严格等于"到期即发、不到期不发"，10ms 的槽粒度不再写进延迟上界（5ms tick 下偏差 ≤ 5ms）。
- **顺带修的同类偏差**：粗层（level ≥ 1）的 cascade 原本在"下层索引预增之后"执行，等于提前一格去清**下一个**
  粗槽，落在窗口头 10ms 的节点会被塞进刚走过的细槽、同样等一个旋转。现在级联发生**在走进新旋转之前**，
  要清的粗槽由「细索引 ÷ 64^l」直接推出，并只在"本层索引是 64 的倍数"时继续往上（层与层的窗口对齐是构造性的，
  不是靠增量维护）。
- **测试**：`src/runtime/timer_wheel.zig` 新增 8 条（裸轮复现 `schedule(24)`+`advance(40)`；5ms tick 网格下的
  unaligned 表；槽边界/槽终点/槽内各种偏移；level 提升（4096/4103/41000/41003）；多天延迟逐级级联
  （含 200,000,000ms ≈ 2.3 天）；200 条混合 batch 的逐条窗口断言；长停摆 + unaligned；部分走过的槽上的
  `cancel`/`drainAll`），`src/runtime/runtime.zig` 新增 1 条经**公开 API** 的用例（`Clock.Manual` + `rt.tick()`，
  不 sleep）验证 `after(delay)` 不早于 deadline、且落在下一个 tick 内。
- **兼容面：无 API 变化、无契约变化**（契约本来就是"**至少** `delay_ms`"），但**触发时刻会变**：
  非对齐 deadline 从"可能早最多 ~9ms、或晚最多 640ms"变成"恰好在 deadline 与下一个 tick 之间"。
  依赖旧的"提前几毫秒"做错峰的消费方会观察到差异；这正是它单独成条的理由。
- **未回归**：owner 单写者契约（`claimOwner`/`assertOwner`）、零分配契约
  （`src/runtime/alloc_contract_test.zig` 里 `Wheel.schedule/cancel/advance/drainAll` 的精确分配次数断言一字未改）、
  长停摆 `advanceCoarse` 路径、`TimerWheel x100K` benchmark（比值判据 < 2.0×）。

## [0.28.0] - 2026-09-19

> **本版说明**：给 v0.28 定的硬规定是「所有已有 public API 必须保持 source-compatible」，
> **本版有意偏离一次**，且只此一次 —— `Runtime.cancelTimer(id) bool` 被删除，拆成
> `requestCancelTimer` / `cancelTimerSync`。理由是它一旦异步化（时间轮改为 ticker-owned 后
> 必然如此）就无法再回答"是否已取消"，留着它就是**静默改义**，比删掉更危险；删除前已清点
> 全仓调用方（`examples/`、`tools/`、`docs/` 零引用，只有 `runtime.zig` 内部 1 处 + 1 个单测）。
> 迁移方式见 `docs/UPGRADING.md`。除这一处外，本版完全向后兼容。

### Benchmark 门禁：给"原子路径"指标加同轮机器参考（**破坏性：否**）

CI 的 Benchmark 闸门（`bash scripts/check-bench.sh`）在 `2462e70` 上稳定报红（两次 attempt 比值只差
1.3%），但红的是**宿主**不是代码。证据：受影响的是"每轮路径全是原子 RMW"的五条（`Mailbox post+drain`、
`Mailbox full-path`、`HotBus 8sub`、`Sequencer x10M`、`1L x10M events`），而同一次 run 里对照指标是
有记录以来最快的（前一次红则是反过来的形态：整机慢 1.09-1.45×，这五条只动 1.00-1.18×）；
`x86_64-linux` 上 base / head 两份二进制的计时循环**逐条指令相同**（`benchEventBus` 2683 条全等，
`benchmark.main` 只差 2 条且都在冷路径），两种 CPU 模型下都成立；本机 A/B（8 轮）与 Linux 交叉编译 A/B（5 轮）
全平（±1.5%）；12 套历史带里这五条从未超过自身最小值的 1.3×。

- **新指标 `atomic RMW x10M`**（`src/benchmark.zig` 的 `benchAtomicRmw`，runtime 分组第一条）：
  一次 `std.atomic.Value(u64).fetchAdd(1, .monotonic)` 的紧循环，10M 次，本机 ~22 ms。
  它**不是**框架指标，是"这台机器的原子路径有多快"的同轮标尺。
- **两种判据**：`Mailbox post+drain`、`Mailbox full-path`、`HotBus 8sub`、`Sequencer x10M`、
  `1L x10M events` 改成 `指标 ÷ 'atomic RMW x10M'`（同一轮的两个中位数相除）对**比值**用 2.0× 阈值；
  其余 21 条仍是绝对毫秒。比值把宿主换代约掉，绝对判据留下的部分会把它当成代码回归。
- **`atomic RMW x10M` 本身只报告、不判定**：给它绝对阈值等于"宿主换代就红"，正是这次要修的病因；
  它偏离记录值超过阈值时打印 host note（并说明这一条就是机器，不进入 verdict）。
- **基线格式向后兼容**：条目要么照旧 `{name, unit:"ms", value}`，要么
  `{name, unit:"ratio", value, normalized_by:"atomic RMW x10M"}`（`value` = 指标 ÷ 参考，均为同一轮中位数）。
  `value: null` 表示"这个机器档还没录比值"——闸门 WARN 并跳过（与"基线不认识的指标"同语义，不失败）；
  基线条目与判据清单不一致时**报 mismatch 而不是照比**（拿 0.77 去比 16.9 ms 会全过）。
- **闸门输出**：开头与 verdict 都打印 `region=… cpu=… cores=…`（region 取 `BENCH_REGION` → Azure IMDS →
  取不到打 `?`，**不因此失败**），并分开打印 `[absolute]` / `[ratio]` 两类判据（绿的时候也把 5 条比值和
  基线比值列出来）。
- **反证（真回归仍抓得到）**：给 `benchSequencer` 的每次取号插一对
  `harness_allocator.create/destroy`（热路径多一次分配）→ 闸门 **exit 1**，点名
  `[ratio] Sequencer x10M: baseline ratio 1.0310 → actual 6.7544（= 147.407 ms ÷ atomic RMW x10M
  21.824 ms）(+555.1%)`；还原后 `src/benchmark.zig` 的 sha256 逐字节一致。顺带测到：在
  `benchMailbox` 里插同样的分配只让比值 0.7902 → 1.09（+38%），**不触发** —— 2.0× 本来就是给量级滑落留的，
  这次改动没有降低它的灵敏度（比值阈值≈绝对阈值）。
- **基线**：`scripts/bench-baseline.json` 用 `--update`（未 `--force`）只动了 6 条（新增参考 + 5 条转比值），
  其余 20 条保持原值（`--update` 会全量重写，故按其头部约定手工还原了与本次无关的漂移）。
  `scripts/bench-baseline.ci.json` 无法在本地录：那 6 条写成 `value: null` 占位，CI 首次运行 **WARN 并跳过**，
  待 runner 上 `--update` 补录（**不要**整份重录）。本次实测该路径：本机对 CI 基线 exit 1 只报
  `RingBuffer SPSC x1M`（文件头部早有记载的跨平台差异），那 6 条按预期只 WARN。
- 文档：`scripts/check-bench.sh` 头部记下这轮证据与两种判据的取舍，`docs/BEST_PRACTICES.md`
  新增"性能门禁的两种判据"一节。生产代码公开签名未动。

### `shutdown()` 先停 ticker 再拆 worker —— 收掉停机窗口的 use-after-free（**破坏性：否**）

`shutdown()` 原来是"先 `request_stop`/join/`destroy` 所有 worker，再停 ticker"。夹在中间的那段窗口里
ticker **还在跑**：它每 5ms 醒一次，若这期间有一条定时器到期，`onTimerFire` → `post` 就会写到
**已经被 `destroy` 的 worker handle** 上 —— 定时器 payload 的投递目标恰恰是那个 handle 的邮箱
（`Handle.after` 的 `Delivery.post`）。窗口长度 = join 掉 N 个 worker 的耗时（毫秒级），不是理论值。

- **顺序**：`alive = false` → **停 ticker（broadcast + join）** → `request_stop` → join → `destroy` →
  `abandonTimerCommands()` → `drainWheel()`。ticker 退出前的最后一步本来就是 `drainWheel`（上一项），
  所以"先停 ticker"顺带把语义钉死：停机时还在轮里的定时器是**被 drop 掉**，而不是投给一个即将被
  释放的 handle（`alive = false` 之后那条消息本来也没有活着的收件人）。worker 之间的 "Ask first,
  join after" 与 `shutdown()` 的幂等性都没动。
- **纵深防御**：`onTimerFire` 在 `!alive` 时**只 drop 不 post**，并计入 `timers_discarded`（而非
  `timer_fires`）。这条覆盖"顺序管不到"的组合 —— 例如另一个线程的 `tick()` 与 `shutdown()` 并发
  （`docs/RUNTIME.md` §4 的 owner 契约本就禁止这种用法，但"写进已释放内存"对一次误用来说代价太大）。
- 公开签名不变；热路径只多一次 `alive` 的 acquire load。

**回归测试 2 条**（`src/runtime/runtime.zig`，都是确定性的，不靠"撞窗口"）：一条直接测 guard
（`alive = false` 后 `post` 不再被调用、`drop` 被调用、计数落在 `timers_discarded`）；一条测顺序不变量
—— worker 的 `deinit` 在退出时记录"轮是否已经空了"，两个 worker 都必须看到空轮（旧顺序下必红：
`expected 2, found 0`）。**红证据**：把生产代码临时还原成旧顺序 / 去掉 guard，两条测试分别稳定报红
（`expected 2, found 0` 与 `expected 1, found 2`）。

**UAF 红证据（一次性探针，不进套件）**：用 `std.heap.page_allocator` 启动 runtime，每次 `destroy`
直接 `munmap`，于是"post 打到已释放 handle"变成硬故障而不是静默写。250 轮 × 2 worker × 24 条
待触发定时器、`-OReleaseSafe`：未改生产代码时 **4/4 次** SIGSEGV（栈 `tickerMain → onTimerFire →
action.post → Mailbox.send → std/atomic.zig`）；修完在 Debug / ReleaseSafe 下均 0 崩溃。

### 定时器时间轮改为 ticker-owned：跨线程 arm 不再共享写（**破坏性：是**）

`docs/RUNTIME.md` §4 早就把 `Wheel(Payload)` 标成"单线程驱动"，但实现不是：时间轮零锁零原子，
而 `Handle.after`（任意线程）会一路走到 `wheel.schedule` 写 `nodes` 哈希表与 id 计数器，ticker 线程
同时 `advance`。两个线程同时进 `schedule` 时 `std.hash_map` 的 pointer-stability 断言
（`assert(l.state == .unlocked)`）直接 ABRT —— 这不是理论风险，见下面的复现规模。

修法不是"给它加一把锁"，而是把文档那句话变成真的：**时间轮变成 ticker-owned state machine**，
生产者与 owner 之间只通过一条定容命令队列交接。

**命令队列**：`Runtime` 内一条 `MpscRing(TimerCommand, 512)`。`arm` 与 `cancel` 走**同一条 FIFO**
—— 这样二者的线性化顺序由队列唯一确定（先 arm 后 cancel = 被取消；先 cancel 后 arm = 正常触发），
而不是两条队列下的掷骰子。`after`/`scheduleAction` 在调用线程上只做三件事：取 id（`Sequencer.next()`）、
按自己的时钟读算 `deadline`、入队。**入队不分配**（定容环），满则 `error.Full` —— 不静默丢。

- **`deadline` 在生产者侧算**：`after(50)` 仍是"从调用时刻起 +50"，与 ticker 忙不忙无关。
- **id 在生产者侧取**：`after` 立刻能返回一个 id（`!Id` 签名不变），不必等 ticker。
- ticker 与 `Runtime.tick()` 每轮**先 drain 命令、再 advance**；`tick()` 即声明自己是 owner。
- **`cancelTimer(id) bool` 已删除**（清点结果：只有框架内部 + 一个单测在用，无对外用户），替换为
  - `requestCancelTimer(id) !void` —— 热路径，语义是"**请求已交给 Runtime**"（约一个 tick 后生效）；
  - `cancelTimerSync(id) !bool` —— 控制面，等 owner 执行完并返回最终结果。
  旧名字的坏处正是它读起来像"已取消"，而它从来只是"请取消"。
- **`Wheel` 加 owner 断言**：`claimOwner()` 发布（第二次被别人抢 = panic），`assertOwner()` 在
  `schedule`/`scheduleWithId`/`cancel`/`cancelWith`/`advance` 上拦"第二个线程"，**只在 Debug/ReleaseSafe
  生效**（ReleaseFast 编译掉，基准不掉速）。未声明 owner 的裸时间轮（测试 / 基准 / 自持循环）不受影响。
- `now_ms` 只由 owner 写：`start()` 里那次赋值挪进 ticker 自己（`Wheel.alignNow`）。
- `shutdown()` 会把命令队列里没来得及执行的东西交出去（arm 调 `drop` 释放 payload、cancel 回报 false），
  停机不再漏掉"还在路上"的定时器 payload。

**回归测试 3 条**（`src/runtime/runtime.zig`，都是 §3 契约级、不是一次性脚本）：

- `T1`：32 线程 × 10_000 次 `after()`，**启动栅栏**同时开始，320k 个 id 必须互不相同。
  修复前：`std.hash_map` pointer-stability 断言失败 → **ABRT**（原始栈见 PR/文档记录）。
- `T2`：4 生产者并发 arm/cancel、同时驱动 `tick()`，末尾断言 `S = F + C + P`、同一 id 只 fire 一次、
  不许既 fire 又 cancel。修复前：ABRT（同上，栈落在 `timer_wheel.zig:98` 的 `nodes.put`）。
- `T3`：worker 在自己的 handler 里 `ctx.handle.after(...)`、ticker 在跑，断言那条消息最终到达
  （文档 §3 推荐的用法；修复前就是绿的，保留为回归网）。

**未附带**（现已补上，见下一项）：`Runtime.shutdown()` 当时仍不释放**已经进轮**的待触发 payload
（只释放命令队列里的）。

### `shutdown()` 释放已进时间轮的待触发 payload（**破坏性：否**）

上一项修完之后留下的缺口：`shutdown()` 只交出了**还在命令队列里**的请求，已经进轮的那些定时器
（`Wheel.nodes` 里的节点）只被 `wheel.deinit` 销毁节点本身，**payload 不释放** —— 停机时 armed 未触发的
定时器一律泄漏。修法遵守同一条单写者不变量：**drain 必须发生在 owner 线程上**，而不是让 `shutdown()`
（应用线程）去碰时间轮、把刚立起来的契约再破坏一次。

- **`Wheel.drainAll(ctx, on_drop) usize`**（`timer_wheel.zig`，owner-only + `assertOwner()`）：遍历全部
  slot，对每个 node 调 `on_drop(ctx, id, payload)`，销毁 node，清空 `nodes` map，返回释放条数。
  它是 fire/cancel 之外的**第三个出口**，用的是同一个 `drop` 钩子 —— 这正是"payload 恰好释放一次"
  在三条路径上都成立的原因。重复调用返回 0（幂等）。
- **有 ticker**：ticker 是 owner，所以由它在退出前 drain（`defer`，任何退出路径都覆盖），
  `shutdown()` 只负责 join —— drain 天然落在 owner 线程上。
- **没有 ticker**（调用方自己 `tick()` 自驱）：那条路径上调用方就是 owner，`shutdown()` 直接 drain。
  轮被**另一个**线程持有时不越界写它，而是 `std.log.warn` 出条数与 owner（不是静默丢）。
- **`shutdown()` 仍然幂等**：第二次调用发现轮里没有待触发项就直接返回，不 double-free。
- **丢弃可见**：`RuntimeStats` 新增 `timers_discarded`（按 `stats()` 既有的聚合写法加，`stats()` 里直接 load），命令队列里被丢弃的 arm
  与轮里被 drain 的定时器**同计**（对调用方而言都是"我 arm 的那次没跑"）；`Runtime.MetricsBridge` 出
  第 9 条 gauge `zigmodu_runtime_timers_discarded`。理由和 `messages_dropped` 一样：承诺过的活儿没发生，
  不能没有数字（`docs/RUNTIME.md` §3 / §8）。

**回归测试 4 条**（`src/runtime/runtime.zig`，`std.testing.allocator` 当泄漏 oracle，无需显式断言泄漏）+
1 条轮级单测（`timer_wheel.zig`）：ticker 路径 / 自驱路径各一条，断言 `timers_discarded == N` 且
`pendingCount() == 0`；幂等一条（连调两次 `shutdown()`，同一 `N`、不崩）；"已 fire 的不重复 drop" 一条
（正常触发一轮后 `timers_discarded == 0`）。**红证据**：未改生产代码时先跑这组测试，3 条失败
（`expected 0, found 64 / 16 / 8`）并报 88 leaks；实现后全绿。

### 新增：EventRecorder v1 —— 运行时投递流可录、可重放（**破坏性：否**）

`HotBus` 是**有意有损**的（满则丢并计数），运行时也没有全局顺序（每邮箱 FIFO），所以"这次运行
到底投递了什么、按什么顺序、在什么时刻"事后问不出来。v1 补上这一块：`src/runtime/recorder.zig`
的 `Recorder(E, capacity)`，opt-in、零分配、可重放。设计依据是 `docs/RUNTIME.md` §11（草案保留，
新增 §11.6 记录实际落地的形状与差异）。

```zig
var rec = runtime.Recorder(Trade, 4096).init(clock); // 与 Runtime.init 同一个 clock
try bus.attachRecorder(&rec);                        // 必须在 freeze() 之前
bus.freeze();
// …运行…
var manual = runtime.Clock.Manual{ .now_ms = 0 };
rec.replay(&manual, &harness, Harness.sink);         // 按 seq 推进 clock，不 sleep
```

**取点（对 §11.3 Q1 的更正）**：草案倾向"`Runtime` 内部、扇出之前"，但 `Handle.send` 直接写邮箱、
不经过 `Runtime`，那里没有取点。实际取点是 **`HotBus.publish` 的 sink 循环之前** —— 它正是扇出
本身，在它之前记录既不占 comptime 的订阅者槽位，也不会走 `dropped` 分支（`:128`）：那正是 §11
要避免的"丢记录"。**没 attach recorder 的 bus，`publish` 行为逐位不变**（只多一次 `?*anyopaque`
空判断，有测试守着 `attach` 前后的同一份断言）。

**溢出不是静默丢弃**：`record` 满环返回 `error.Full`，绝不覆盖；`entries()` 因此永远是 seq 升序
的完整前缀。`publish` 拿到拒绝后 `stats().record_dropped += 1` **并且返回 `false`**（签名仍是
`Error!bool`，examples 用的那个不动）—— 日志不完整不该读成成功；`Recorder.hasOverflowed()`
此后恒为真。

**实现要点**：`Sequencer` 的序号**就是槽位下标**（0,1,2,…），一次 `fetchAdd` 同时拿到顺序与空间，
多生产者不撞车；per-slot `ready` 标志 + `published` 前缀长度让 `entries()` 无锁、无等待地给出一段
完整前缀（领先的生产者写完自己那条就返回）。复用 `Clock`/`Clock.Manual` 做时间与重放驱动。

**测试 8 条**（`src/runtime/recorder.zig`）：record/replay 往返逐条相等；满环 = `error.Full` 且
`len` 未超（**反证**：把满环分支改成静默丢弃，这条立刻红）；seq 严格单调（含被拒的记录仍消耗
序号）；重放把 `Clock.Manual` 推到每条记录的 `clock_ms`（501 ms 的记录时间在墙钟上半秒内跑完，
即不 sleep）；attach 前后 `publish` 返回值一致；`freeze()` 之后 attach 返回 `error.Frozen`；
被拒的记录在 bus 上可见（`record_dropped` + 返回值 + `hasOverflowed`）；4 生产者 × 500 条并发
record 序号不丢不重。

**明确不做**：不做领域事件溯源（那是 `core/EventStore.zig`）；不做 `HotBus` 订阅者（会丢）；v1 只录
**单一事件类型 `E`** 的 `HotBus` 发布流，`Handle.send` 直达投递、`after` 定时器投递、多 worker
**异构**消息都不覆盖；不承诺进程级完全确定性（`spawn`/`init` 副作用、网络、墙钟、丢弃模式不重放）；
只有读注入 `Clock` 的代码参与重放。

**文档**：`docs/RUNTIME.md` §11.6（形状、与草案的差异表、未做边界）、README
「High-Performance Runtime」清单（英文）。

### 新增：Runtime worker trace context —— 消息可归属到发起它的请求（**破坏性：否**）

外部 review 的 v0.28 提案里，「Tracing — Worker trace context」是核对后仅剩的 3 个真实缺口之一。
在此之前运行时代码里没有任何追踪概念 —— 对 `HEAD` 逐文件核对，每个文件都是 0：

```text
$ for f in src/runtime/*.zig; do git show HEAD:$f | grep -cE "TraceId|trace_id|traceId|tracing"; done
0
0
0
0
0
0
0
0
```

（`timer_wheel.zig` 里出现过 `span`，那是时间轮的几何宽度，不是 trace span。）

HTTP 层有 `trace_id`（`http.Tracing`）、有 OTLP 导出，但请求触发的 worker 消息在追踪里是**孤儿**：
worker 报错只说得出"谁出错了"，说不出"哪一次请求造成的"。

**改动（集中在 `src/runtime/runtime.zig`）**

- 邮箱元素从裸 `Message` 换成文件内私有信封 `struct { trace: ?TraceId = null, message: Message }`。
  `TraceId` 从 `tracing/DistributedTracer.zig` **原样** re-export（`zigmodu.runtime.TraceId`，16 字节
  值类型），不另造平行结构。**零分配**：trace 跟着邮箱槽位走，不给 `Mailbox` / `RingBuffer` /
  `HotBus` / `send` 加 allocator 形参 —— 热路径上只是一个字段的拷贝。
- `Handle.send` / `sendBlocking` **签名不变**（内部发 `trace = null`）；新增
  `sendTraced(msg, trace)` 与 `sendBlockingTraced(msg, trace, timeout_ms)`。
- `WorkerContext.traceId()` 返回**当前正在处理的那条消息**的 trace —— 每条消息一份，不是每个 worker
  一份，生产者线程设的值不会串到别的消息上；`init` / `run` 阶段为 `null`。
- `Handle.after(...)` 在 handler 内（worker 自己的线程）调用时带上当前消息的 trace，定时器投递的消息
  保留归属；在别的线程上调则投无 trace 的消息（那里没有正在处理的请求，硬编一个反而是假的）。
- `supervise` 的两行错误日志与 `init` 失败那行带上 `trace=<hex>`，可直接 grep 回请求。
- `HotBus` / `Mailbox` / `Runtime.spawn` 的公开契约未动（`HotBus` 只做 `@hasField(H, "mailbox")`
  探测 + `h.send`，`send` 签名不变即无需改动）。

**测试 5 条**（`runtime.zig`）：`sendTraced` 与 `send` 的区别、traced/untraced 交替时各自的归属与顺序、
跨线程双生产者 2000 条零错配、`after` 保留调度时的 trace、`init`/`run` 阶段为 `null`。
跨线程那条是**反证**：把 trace 临时改存到 handle 上（而不是信封里）再跑同一份测试，
2000 条里 **802 条**归属错乱 —— 信封化不是形式主义，它买的就是这个。

**文档**：`docs/RUNTIME.md` §8.1（用法、逐条契约、错误日志、与 HTTP `ctx.traceId()` 的接法）、
§3 契约要点、README「High-Performance Runtime」清单（英文）。

### 修复：v0.27.0 的提交过不了自己的 `check-version.sh`

**背景**：`tools/zmodu/src/incremental.zig` 的两个测试把 `saveManifest(…, zmodu_version)`
的 fixture 值写成了当时的版本字面量 `"0.26.0"`。`scripts/check-version.sh` 会扫 `tools/`
下的 `0.x.y` 字面量并判为硬编码版本 —— 版本一 bump 到 0.27.0，这个闸门就红了。
它**只在 CI 里跑**（`ci.yml` 的 "Version consistency"），不在 `release.sh` 的闸门清单里，
于是本地发布全绿、推上去才红。

**修法**

- 两处 fixture 改成无版本含义的 `"test"`（测试只做 manifest 往返，不断言该字段的值）。
  生产侧本来就是对的：`main.zig:6301` 传的是 `ZMODU_VERSION`（源自 `build.zig.zon`）。
- `release.sh` 的闸门清单补齐为 **CI 阻断项的并集**：新增 `check-version.sh`、
  `check-tenant-scope.sh`、`zig build check-api`、`zig build check`（后者内部跑
  `check-production.sh`）。"本地绿、CI 红"的发布事故因此不会复发。
- scaffold 的 `zigmodu_zon_hash` 刷新到 **v0.27.0**
  （`zigmodu-0.27.0-U40vs9t8UgBlmRaJ7WNawmUCr_LZFk9H1XrKU44bvHk1`）。该 hash 必须在 tag
  存在之后才能算出，所以每次发布后都要补这一手；滞后期间 `check-version.sh` 只报 WARN
  （设计如此）。验证不看 hash 像不像，而是**真编译**一个钉住该 URL+hash 的生成工程，
  `zig build` exit 0 才算数。

### 修复：`check-tenant-scope.sh` 在 Linux 上必红（本次把它接进 CI 时暴露）

`ci.yml` 新增的 "Tenant-scope compile gate" 在 ubuntu-latest 上失败，`plain` fixture 报：

```
error: dependency on libc must be explicitly specified in the build command
    extern "c" fn clock_gettime(...)
referenced by: clock_gettime -> monotonicNow: src/core/Time.zig:46
```

`plain` fixture 可达的代码在 Linux 上经 **`src/core/Time.zig` 的 `monotonicNow`** 走到
`std.c.clock_gettime`，Zig 要求显式声明 libc 依赖；macOS 不走这条路径，所以本地一直是绿的。
`compile()` 加 `-lc` —— `-fno-emit-bin` 不产生二进制，该标志只满足这次分析。

**验证方式**：不靠"推上去看 CI"，而是本地用 `-target x86_64-linux-gnu` 跑同一份分析：
去掉 `-lc` 精确复现了 CI 的报错与调用链，加上 `-lc` 后 3/3 通过。

### 修复：Benchmark 闸门拿本机基线卡 CI —— 拆成两份基线

`ci.yml` 的 "Performance gate" 在 `88f082b` 上失败，报 CircuitBreaker 两个指标慢
2.14× / 2.18× —— 而该提交只改了一个 shell 脚本和 CHANGELOG。真因是**基线录制机器与
闸门运行机器不是同一台**：`scripts/bench-baseline.json` 录在维护者的 M1 Pro 上，
闸门却跑在 ubuntu-latest 上。

同一份代码，三次测量：

| 指标 | 本机基线 | 上一轮 CI（绿） | 本轮 CI（红） |
|---|---|---|---|
| CircuitBreaker x10M | 6.571 ms | 10.91 ms（1.66×） | 14.055 ms（2.14×） |
| CircuitBreaker x100M | 64.488 ms | 109.08 ms（1.69×） | 140.551 ms（2.18×） |

绿的那轮已经只剩约 18% 余量；而本轮 **23 个指标在同一次 CI 内部一致地慢约 1.3×** ——
这是整台机器档位的速度差，不是任何单个指标的回归。

**修法**：绝对时间基线不可能同时服务两个硬件档位，所以一档一份：

- `scripts/bench-baseline.json` —— 本机（默认）
- `scripts/bench-baseline.ci.json` —— **从一次绿的 CI run 的数字录成**，`ci.yml` 用
  `BENCH_BASELINE` 指过去

`check-bench.sh` 的 `BASELINE` 改为 `${BENCH_BASELINE:-scripts/bench-baseline.json}`，
`--update` 写哪一份由它决定。**阈值不动**（仍是 2.0×），两档各自保持满灵敏度。

**验证**：拿失败那轮的 23 个指标去比 CI 基线，比值全部落在 **1.21–1.36×**（最大 1.36×），
即修好后那一轮会通过；本机默认路径仍 exit 0。

**残留**：CI 基线录自某一个 runner 实例，换到明显更慢的实例仍可能逼近 2.0×；
这比修前（仅 18% 余量）稳健得多，真出现时按脚本提示重录，不要调阈值。

### 补齐 Runtime 验收表仅剩的两行：worker 启停 + 背压路径

外部 review 给了一份 "v0.28 Runtime Foundation" 提案，要求新建 `src/runtime/` 下的
Worker / Mailbox / RingBuffer / HotEventBus / Clock / Supervisor 等。**核对后确认这些在
v0.16/v0.17 就已交付**：`docs/RUNTIME.md` §9 的 roadmap 逐条对得上，`src/runtime/` 下已有
`runtime.zig` / `ring.zig` / `mailbox.zig` / `hot_bus.zig` / `timer_wheel.zig` / `clock.zig` /
`object_pool.zig` / `sequencer.zig`，`app.runtime()` 在 `Application.zig:274`。按提案字面
实施等于造第二套平行 runtime（正是该提案自己原则 2 所禁止），所以只做真正缺的部分。

**两条 benchmark** —— 提案 §19 验收表里仅剩未覆盖的行：

| 指标 | 实测（本机） | 覆盖的验收行 |
|---|---|---|
| `Worker spawn+join x1K` | 29.51 ms | worker startup / shutdown / 无泄漏 worker |
| `Mailbox full-path x10M` | 21.80 ms | Queue full → bounded（背压拒绝路径的成本）|

`Worker spawn+join x1K` 把运行时的分配器换成 `FailingAllocator` 并武装在 stop/join 半段，
比对 `alloc_index + resize_index`（`fail_index` 盖不住 `resize`/`remap` 增长），任何被加进停机
路径的分配都会直接失败，而不是变成一个稍慢的样本；循环结束后再断言
`stats().workers == 0 and running == 0`。`spawn` 本身必然分配，这一点没有假装。

提案 §19 其余各行本已满足：RingBuffer / Mailbox / HotBus 的收发路径**不接受 allocator 形参**
（固定容量，结构上不可能分配）；队列满、运行时停机、多线程竞态都有现成单测
（`RingBuffer moves values between two threads without loss`、
`Mailbox: many producers, one consumer, nothing lost`、`MpscRing accepts many producers`、
`Runtime: shutdown joins every worker and reports stats`）。

**文档**：README 的 Features 此前**完全没有 runtime 这一层**（`grep -i runtime` 只命中
"Agent Runtime" 与 "runtime error"）。补了「两种执行模型」的定位句、`### High-Performance
Runtime` 能力清单（Worker / Mailbox / RingBuffer / MpscRing / HotBus / TimerWheel / Clock /
Supervision / 指标桥），以及 Project Structure 里的 `src/runtime/`。英文 README 仍无中文。

**基线**：本机基线重录（23 → 25；无改名，21 条收紧、2 条 +0.9% / +0.5% 噪声漂移）。
CI 基线随后从真实 runner 补录了这 2 条（`Mailbox full-path x10M` 49.44 ms、
`Worker spawn+join x1K` 44.88 ms），**其余 23 条原样未动** —— 该轮 runner 比上一轮慢约 1.19×
（23 条的中位比值 1.19×，范围 0.97–1.50×），整份重录会把当天 runner 的速度烙进棘轮。
另记一条实测观察：`RingBuffer SPSC x1M` 是唯一**不随机器缩放**的指标（runner 1.09 ms vs
本机 10.6 ms，慢机器上反而更快），所以跨这两份基线比较它没有意义。

### 新增：`zmodu runtime` —— 运行时接线的静态盘点（**破坏性：否**）

v0.28 review 的 §二 提过"runtime diagnose/bench"。能做且诚实的只有一半：**读活的运行时状态**
静态 CLI 做不到（队列深度 / `dropped_full` / `timer_lag_ms` 是运行中进程的属性，已由
`Runtime.MetricsBridge` 导出成 8 条 Prometheus 指标，抓取配方在 `docs/RUNTIME.md` §8）；
能做的是把某个项目**已经声明**的 runtime 接线盘出来 —— 新增
`tools/zmodu/src/runtime.zig`，`zmodu runtime [dir] [--json]`。

报告六块（每条带 `file:line`）：是否用了 runtime、worker（`spawn`/`spawnActor`/`spawnSupervised`
的**类型名 + 邮箱容量**）、邮箱/队列原语（`Mailbox(`/`RingBuffer(`/`MpscRing(`/`ObjectPool(`/`HotBus(`）、
定时器调用点、录制/追踪引用、时钟选择，末尾一行汇总（如
`9 worker(s), 1 bus(es), 1 timer call site(s), recording: no, tracing: no`）。

容量**只在读得出来时**给数字：字面量直接用；`api.order_capacity` 这种顺着该文件自己的
`@import("api.zig")` 找到 `pub const` 再用；读不出来报 `?` 并附原表达式 —— 不猜。
遍历是**递归**的（`src/**/*.zig` + 根目录 `*.zig`），不像 `audit` 那样固定两层。
刻意**不做任何判据**：只报看得见的事实（`attachRecorder(` 在 `src/x.zig:42`），
不做静态不可靠的推断（"recorder 是否在 `freeze()` 之前挂上"），所以 `--json` 可以进 CI 而不产生假警报。
退出码 `0`/`1`（目录读不了）/`2`（用法错误）；**项目没用 runtime 也是 0**（报告说 `uses runtime: no`）。
文档：`docs/ZMODU_CLI_INTEGRATION.md` 新增一节（含"它不做什么"），README Commands 加一行。

## [0.27.0] - 2026-09-18

### 修复：`zmodu scaffold` 生成的工程过不了自己的 `zmodu ci`

追一条"grep 干净度"的尾巴时撞出来的真缺陷：**生成器产出的代码违反框架自己的审计规则**。

复现（修复前，v0.26.0 的 CLI）：

```
$ zmodu scaffold --sql schema.sql --name app --out ./app --with-agent --with-websocket
$ zmodu audit ./app
architecture: 0 violation(s), business: 3 violation(s)
  [b10] src/modules/im/service.zig:29  empty catch block swallows errors
  [b4]  src/modules/im/gateway.zig:90  @ptrCast on ctx.user_data
  [b4]  src/modules/im/api.zig:39      @ptrCast on ctx.user_data
summary: FAIL — 3 new violation(s)          # exit 1 → `zmodu ci` 开箱即红
```

三个根因，各自独立：

**1. 模板把 `catch {}` 写进生成物（b10）** — `generateAgentModule` 2 处、`generateImModule` 1 处。
改为带日志的 best-effort 忽略（`std.log.warn` + `@errorName`），审计与真实错误处理都正确。

**2. b4 对"取路由 State"误报** — 被点名的那两处是 WS `on_connect` 回调里的
`@ptrCast(@alignCast(ctx.user_data orelse return null))`，目标是 `*ImApi` / `*ImGateway`，
**正是 `user_data` 该有的用法**。误报的根源是 b4 写于 `auth_info` 与 `user_data` 分离之前
（`Server.zig` 现在注释明说二者已拆开），于是把合法的 State 取值也当成了 AuthInfo 反模式。

**新增 `Context.state(T)`**（`src/api/Server.zig`）作为 State 的正规入口：

```zig
// 之前：每个调用点手写 cast，且 `orelse unreachable` 在 ReleaseFast 是 UB
const self: *ImApi = @ptrCast(@alignCast(ctx.user_data orelse return null));
// 之后：cast 收在一处，缺 state 是具名错误
const self: *ImApi = ctx.state(ImApi) catch return null;
```

b4 的报错文案同步改为指向它（`use ctx.state(T) for the route state`）——规则命中后有了明确去处，
而不是只留一句"读 attrs"。**活代码里 3 个模板站点**全部改用 `ctx.state(T)`：im `api.zig` 的
WS `wsConnect`、im `gateway.zig` 的 `onConnect`、以及 agent/im `service.zig` 的 3 处
`catch {}` 改成带日志的 best-effort 忽略（见下条）。`main.zig` 里另有一处
legacy `RouteGroup` 扩展模板的 `resolve2` 也一并改成了 `ctx.state(T)`，
但那整块在 `if (false) { … } // ext/ removed`（`main.zig:5708-5824`，117 行）**死代码**里，
不参与生成——改它是为了一致性，不是修缺陷。

**3. `zmodu audit` 根本不看嵌套模块** — `collectBusiness` 的遍历是**固定两层、不递归**
（`src/modules/<模块名>/<文件名>.zig`），而生成器把 `--with-agent` 产出在
`src/modules/ai/agent/`——第 3 层。整个模块**从未被审计**，它的 `catch {}` 因此静默留在生成物里
（这就是同一次跑只报 im、不报 agent 的原因）。

改为一棵子树递归遍历（`lintModuleTree` / `collectModelStructsTree`），模块级标志
（b14 的"有无测试"）按子树聚合。**验证**：往 `src/modules/ai/agent/service.zig` 注入一条
`catch {}` → 现在被精确报出 `[b10] src/modules/ai/agent/service.zig:79`（修复前静默）。

**影响面**：本仓库的 `examples/` 无嵌套模块、框架自身无 `src/modules/`，所以该遍历收窄在本仓
零冲击；对**消费方**是行为变更——`zmodu audit` / `zmodu ci` 会开始报出此前看不见的嵌套模块违规。
修复后重新生成的工程：`business: 0 violation(s)` / `summary: PASS` / exit 0。

### 工具链自洁：`tools/zmodu/src/` 的 `catch {}` 字面量归零

`tools/zmodu/src/` 纳入 `check-production.sh` 的强制前缀（`SCAN_ROOTS`）后，该目录仍有 14 处
字面量命中。逐条核对后分两类：

- **3 处是真的** —— 生成器模板会把它发射进用户代码，即上面那节修的缺陷。
- **11 处是扫描器有意跳过的形态** —— `//` 注释 2、b10 规则自己的检测常量 1、喂给 linter 的
  测试 fixture 8。这些**不改语义**，只把拼写改成从两片拼起来
  （`const empty_catch_needle = "catch " ++ "{}";`，fixture 用
  `"… " ++ empty_catch_needle ++ ";\n"`），并重写了两条提到该模式的注释。
  改完 `grep -rn "catch {}" tools/zmodu/src` 与扫描器的判断**一致**，
  不再把 linter 自己的样例源码读成违规。

`src/` 下的同名命中（`std.testing` 清理、`defer … catch {}`，以及 `Middleware.zig` 中解释该规则
本身的注释）**保持原样**：扫描器按花括号配对跳过 `test` 块，测试清理里的空 catch 是惯用法。
判据始终是 `scripts/check-production.sh` 的退出码，不是 grep 计数。

### 工具链升级

- `0.17.0-dev.1970+67f39b551` → **`0.17.0-dev.2151+2ec5523d5`**（latest master dev build）。
  同步更新：`.github/workflows/ci.yml` 的 `ZIG_VERSION`、`README.md` / `README.zh.md` / `docs/QUICK-START.md`
  的安装示例。
- 升级前后**零代码改动**：`zig fmt --check src tools examples` 无漂移；`zig build test`
  **1167 passed / 21 skipped / 0 failed**（同一套数），无需为新工具链改任何源码或测试。

### 最佳实践文档修正与门禁收窄

一次针对 `docs/BEST_PRACTICES.md` 的自审发现"文档写的"与"机器查的"之间有落差，本轮把两边都收了。

**文档：7 处照抄即错的片段（`docs/BEST_PRACTICES.md`）**

- 「正确的内存管理」那段 `defer allocator.free(buffer)` 后 `return buffer` 是**静默 UAF**，
  改成两个真正确的形态（所有权随返回值移交 / `dupe` 出拷贝），原写法降级为显式反例。
- 并发范例用了 **Zig 0.17 已删除的 `std.Thread.Mutex`** 且 `Self` 未定义 → 改成 `std.Io.Mutex = .init`
  + 显式 `io` 字段 + `lock(io) catch return` / `unlock(io)`。
- `zigmodu.resilience.*` / `tracing.*` / `metrics.*` 三个**命名空间不存在** → 改为
  `zigmodu.CircuitBreaker` / `zigmodu.observability.DistributedTracer` 等真实路径。
- `CircuitBreaker.init(5, 30000)`、`.timeout_ms`（字段不存在）、`data.redis.Redis.init(allocator)`
  + `connect(host, port, .{})` 均为旧签名 → 按 `src/resilience/CircuitBreaker.zig`、
  `src/redis/redis.zig` 的真实签名重写。
- 部署节：`root_module.addDefine`（不存在）、`std.process.getEnvVarOwned`（已移除）、
  GitHub Action 的 `0.16.0` 版本矩阵 → 改成 `b.addOptions()` + `init.environ_map` + `ci.yml` 的 `ZIG_VERSION`。
- `zigmodu.extensions.ModuleTestContext` → `zigmodu.ModuleTestContext`；
  `zigmodu.extensions.AsyncEventBus`（**全仓无此类型**）整段删除，换成 `ThreadSafeEventBus` 真实示例。
- "examples 里没有任何代码用 `ai.Agent`" 等采样断言已失效 → 加时间标注并更新。

**文档：入册与口径**

- 补录 `TransactionJournal` / `recover()`、`SagaStep.timeout_seconds`（两条都写成"必须遵守"而非建议）、
  `jsonStruct`、`paramInt(T, key)`（**两参**）；`AGENTS.md` 补 `ai.AgentWorker`；
  `zmodu ci` 由 **5 步**更正为 **6 步**（含 `doctor`）。
- 版本口径三处互斥（v0.23 / v0.25 / 页脚"1.0"）统一到 **v0.26.0**；目录上移并补录 `## 🔄 现状复核`；
  纯伪码围栏加标注；自引用行号改成按内容定位。

**门禁：六处"写着但扫不到"全部收窄**

- `scripts/check-production.sh` 原先**扫到第一个 `test "` 即止** —— `Server.zig` 首个 test 在 1445 行、
  全文 4487 行，约 3000 行生产代码不检。改为**扫全文件 + 按大括号配平跳过 `test` 块**
  （先剥字符串/注释再计数，test 内的 `"{}"` 不会带偏）。副作用：在原本已强制的路径里新暴露 4 处并已修。
- 强制前缀 **7 → 10**（补 `src/ai/`、`src/extensions/`、`src/im/`），这 23 条裸 `catch {}`
  **逐条真实修复**（统一 `catch |err| std.log.debug/warn(...)`，行为不变），未使用豁免清单。
- 跨行 `catch {` + 换行 `}` 在 shell 与 `audit.zig` 两边都**可识别**了（此前只认单行）。
- `audit` b3 关键词补 `WITH`/`PRAGMA`/`TRUNCATE` 并加**词边界**（`withContext` 不再误判），
  同时抑制"纯常量比较"（`WHERE status = 'active'` 不再误报）。
- `audit` b17 改为**逐分配点判定**，消除"一处 `freeScanned` 洗白整个函数"。
- `check-deadcode.sh --update` 加**单调性断言**：超过基线时拒绝写入并 exit 非 0（需 `--force`）；
  `examples/**` 纳入扫描（当前 WARN 阶段）。

**HTTP / Testkit**

- `Testkit.dispatch` 新增 `DispatchOptions.query`。此前**任何 query 驱动路由都无法用 dispatch 测试** ——
  包括脚手架自己生成的 `list*`（读 `ctx.queryInt(usize,"pageNo",1)`）。收 percent-encoded 原样串，
  与 `path` 自带 `?…` 可共存（同名 key 后者胜）。

**修复：脚手架生成的 handler 从客户端分配器泄漏**

`generateModuleApi` 产出的 `list*` / `get*` 不释放 owned 返回值：

- `list*` → `repo.findPage()` 的 `PageResult.arena` 由 **`Client.allocator`（长生命周期）** 分配，
  而 `ctx.allocator` 是**每连接 arena**（`connFiber` 每请求 `reset()`）—— 回收不到它，属**永久泄漏**（每请求一页）。
- `get*` → `repo.findById()` → `Client.queryRow()`，其字符串字段按 `sqlx.zig` 自身注释
  "owned copies from the client's allocator and must be freed by the caller"。

实测（`std.testing.allocator` 下调 `queryRow` / `queryRowsOwned` 故意不释放）：`3 leaks`，
栈顶落在 `scanStruct(self.allocator, …)`，确认分配根在客户端分配器。

**关键陷阱**：`ArenaAllocator.free()` 是 no-op，所以用 `ctx.allocator` 去释放这些内存**不会报错、
也不会释放** —— 看起来修好了，实际照漏（我们的第一版修复正是这么写的）。正确做法是用**分配它的那个**
分配器：`list*` → `defer result.deinit(self.service.persistence.backend.allocator)`；
`get*` → `freeScanned(self.service.persistence.backend.allocator, …)`；
而 `create*`/`update*` 必须继续用 `ctx.allocator`（`bindJson` 从它深拷贝）。

**注意** `repo.insert` 返回入参的副本、字符串与入参**别名**，所以 `create*` 只 free 一次 ——
再 free `created` 就是双重释放。

**反证（生产形状）**：探针用 `std.testing.allocator` 作客户端分配器（可检测泄漏）、`Server` 拿到另一个
arena（复刻 `connFiber` 层次），真的 `dispatch` `list` 与 `get?id=1`：正确的释放 → **0 leak**；
`deinit(ctx.allocator)` + `get` 不释放 → **2 leaks**（`allocator.dupe(u8, str)` 的行字符串）。

**新增 API**：`PageResult.deinitArena()`（补 `QueryResult.deinitArena` 的对称缺口，后者此前全仓零使用）——
生成器**暂不使用**，因为 scaffold 出的项目 pin 已发布版本，用了会编译不过；等版本推进后再切。

**同类修复**：`examples/tenant-mgmt/src/modules/user/api.zig` 的 `getUser` / `listUsers` 有同样的
"拿 `ctx.allocator` 释放客户端内存"问题，一并改成 `backend.allocator` / `deinitArena()`。

**修复：脚手架模板 `test.zig.tpl` 是死模板**

`tools/zmodu/src/templates/orm/sqlx/test.zig.tpl` **从未被 `@embedFile`**（`orm_tpl.zig` 的 embed
列表里没有它），内容还是三个 `expect(true)` 空桩 —— 即"文档推荐、示例不示范、脚手架不产出"。
现在：`orm_tpl.sqlx_test` 嵌入该文件并在 `writeModuleFiles` 里为**单表模块**写出
`modules/<name>/test.zig`（`openMemorySqlite` 上的 repository 往返 + 一次打生成 POST 路由的
`dispatch` 断言），`generateScaffoldTestsZig` 同步写入 `test { _ = @import("modules/<name>/test.zig"); }`。
多表模块不产出（模板按 `model.<PascalModule>` 取类型，多表时类型名不成立）。
端到端验证：`zmodu scaffold` 单表 schema → 生成项目的 `zig build test` **7/7 pass**。

**示例**

- `examples/tenant-mgmt/src/tests.zig` 新增 3 条 `http.Testkit` 真用例：JWT 门（无 token 401 /
  正确 token 200 且 body 逐字节相等 / **换 secret 的同形 token 必须 401**）、权限门
  （`tenant:read` 403 → `tenant:suspend` 200 且状态真的落库）、**跨租户隔离**
  （token 的 `aud` 决定可见行；猜别租户的行 id 得 404；`X-Tenant-ID` 与 aud 冲突 403）。
- 顺带修 `examples/tenant-mgmt/src/modules/user/api.zig`：`getUser` 不释放 `queryRowPartial`
  返回的 owned 字符串（`std.testing.allocator` 抓到 3 处泄漏）。

**修复：`LogRotator` —— 公开导出但从未被编译**

`zigmodu.observability.LogRotator` 是正式导出的组件，但**全仓零调用**；Zig 惰性分析函数体，
所以 `rotate()` 里 0.17 之前的 `std.Io.Dir.cwd().rename(self.io, old, new)`（正确签名是 5 参
自由函数 `Dir.rename(old_dir, old_sub, new_dir, new_sub, io)`）一直没报错 —— **任何用户一调用
`write` 就编译失败**。`zig build test` 抓不到，因为"编译所有源文件"的测试只做文件级 import，
不进函数体。修法：改正 2 处 `rename`；新增 `initIn(allocator, io, dir, …)`（`init` 仍写 CWD，
`initIn` 指向 `tmpDir`），并**补一条真正实例化它的测试**（按大小轮转 + 断言各代内容 + 超代数文件
不存在），否则它会继续腐烂。

**门禁：补齐最后三处 + 两个盲区**

- `check-production.sh` 强制前缀补 `src/log/` 与 `src/runtime/`，并修掉这两处最后 3 条 WARN
  （`StructuredLogger` 轮转 rename 的静默 `catch {}` 改为"`FileNotFound` 静默、其余上报一行
  stderr 且不递归走自身 log"；`timer_wheel` 测试辅助里的 `catch unreachable` 改为 `@panic(…)`，
  消除 ReleaseFast 下的 UB）。**现在 0 warning。**
- **`catch {},` 盲区**：switch 分支 / 初始化列表里的尾随逗号既不是 `{}` 也不是 `{};`，被
  `body_kind` 判成 `other` 而**完全逃检**。shell 扫描器与 `audit.zig` 的 `catchBodyKind`
  两边都修，并各加反证用例（CLI 侧 b10 期望由 3 条升到 5 条）。
- `check-deadcode.sh`：`examples/**` 从 WARN **提升为强制**（`EXAMPLES_MODE` 删除），两个 scope
  各自独立扫描后比对基线；7 条既有死代码全部处置（6 条未使用的 `const std` 导入 + 1 个零读取的
  私有字段），基线保持 32 不变。JSON 解析失败改为 fail-closed。

**开发者体验**

- `zig build zmodu` 现在**同时安装**二进制。此前只 build+run，`zig-out/bin/zmodu` 会静默保留
  上一次 `zig build` 的旧版本，调用方驱动到陈旧 CLI（本轮就被这个坑过一次）。
- `http.Testkit` 删除查询解析的手工孪生实现，改为直接调 `Server.zig` 的 `parseQueryInto`
  （为此把 `parseQueryInto`/`percentDecode` 开放为 `pub`）—— 测试与线上**不可能**再对同一串
  查询参数有不同解读。

**示例目录收敛：删除 2 个重复样板**

`examples/` 由 20 个目录收到 **18 个（17 个示例 + `_shared`）**。判定标准是"每个目录必须唯一承载
一项框架能力"：

- 删 **`shopdemo-zent`** —— 结构性重复：与 `shopdemo/generated-sample` 是**同一个 `order` 模块**，
  只换 zent 持久化，而 zent 已由 `zent-modulith` 演示。
- 删 **`tenant-ai`** —— 与 `ai-ops`（AI 流水线 + HTTP 审批队列）和 `tenant-mgmt`（租户隔离）双向重叠。
  删前核实其"独有"的两项并不独有：`workflow.toMermaid`（`src/ai/workflow.zig` 单测）、
  `skill_export.toOpenApi/toSkillsJson`（`src/ai/skill_export.zig` 单测 + `zmodu ai` CLI smoke）、
  `SkillRegistry`（自有单测）—— **不留无人调用的公开 API**。
- **保留** `metaverse-creative`（结算链路无替代）与 `zmsaas`（含前端，`Preflight` + 池/积压接线参考）。

同步改动：`ci.yml` 的构建列表（两处）、`doctor` 循环、`test` 循环；`examples/README.md` 索引与段落；
`docs/AI_DEV_GUIDE.md` / `AI_SKILLS.md` / `AI_ORCHESTRATION.md` / `ZMODU_CLI_INTEGRATION.md` /
`PRODUCTION_ROADMAP.md` 中指向这两个示例的句子（改为描述能力或改指 `ai-ops`）；
`src/tests.zig` 里列举 `src/ai` 消费者的注释。历史审计记录里的提及**不改写**，只加口径说明。

**定位缺口：性能门禁与运行时观测**

- **性能第一次有了真门禁**。此前 CI 的 benchmark job 自己写着 "the gate (it must compile and complete)" ——
  threshold 比较因 repo 无 `gh-pages` 分支而 `continue-on-error`，**从不生效**；而且基准全是旧定位的微基准
  （`scanModules` / `App lifecycle` / `CircuitBreaker` / `RateLimiter` / health / `findById`），
  **四个护城河方向一条都没测**。现在：`src/benchmark.zig` 补 6 条运行时基准
  （`RingBuffer SPSC` / `Mailbox post+drain` / `TimerWheel` / `HotBus 8sub` / `ObjectPool` / `Sequencer`，
  整套 ReleaseFast 约 1.3 s，确定性、无 socket/线程/sleep），新增 **`scripts/check-bench.sh`**
  用 `scripts/bench-baseline.json` 做基线对比（默认 2.0× 放量，`BENCH_THRESHOLD` 可覆盖；
  基线有而本次没跑的只 WARN 不失败；`--update` 带单调性保护，超阈值须 `--force`）。
  基线对比在**临时目录**跑二进制，不会往工作树丢 `bench-results.json`（为此 `build.zig` 加了只编译不运行的
  `benchmark-build` step）。该门禁接进 CI 的 benchmark job 作为**硬失败**一步，放在历史 hook 之后 ——
  **随后被它自己抓到一次假阳性，并因此做了两处加固**（都写进了 `check-bench.sh` 的头部注释）：
  ① **每个指标取 median-of-3**（`src/benchmark.zig` 的 `median3`；`validateModules x100K` 同机同码三次实测
  446 / 292 / 295 ms，1.5× 的跨运行带宽落在 2.0× 判决窗口里，而被报的代码一行没改）；
  ② **把套件的日志流从测量关键路径上摘掉** —— `validateModules` 每次调用写一行 `info:`，
  每个样本约 7 MB，落到**文件**时 ~280 ms、走**管道**（有消费者）只要 ~63 ms：
  这几个指标此前测的是宿主机的 writeback，不是代码。改成管道过滤后它们降到 **0.23–0.25×**
  （`validateModules x100K` 276→68 ms），其余指标变动 ≤1.10×，基线随之重录。
  阈值仍是 2.0（**没有**为了让门禁变绿而放宽），且反证过：把基线除以 10 立刻 exit 1 并打印三个样本。
  剩余风险已写明：baseline 是绝对时间、录自本机（CI 的 `ubuntu-latest` 首次跑可能需在 runner 上重录）。
  失败步会跳过后续步骤，而回退时正是最需要那条历史数据的时候。
- **`RuntimeStats` 有了出口**。数据早就在（`messages_dropped` / `timer_lag_max_ms` / `handler_errors` …），
  但全仓只有 `rt.stats()` 结构体、实际消费是示例里 `print` —— 生产里**无法对邮箱积压、消息丢弃、
  定时器滞后告警**。新增 `Runtime.MetricsBridge(MetricsT)`：起服务时 `init(&rt, metrics)` +
  `metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge)`，抓取时采样 8 条 `zigmodu_runtime_*`。
  对 `MetricsT` 鸭子类型化，runtime 层不依赖 observability 层。
- **修掉一个 use-after-free（写这条桥的测试时撞出来的）**：`PrometheusMetrics` 的
  `counters`/`gauges`/`histograms`/`summaries` 四个 map 原先把实体**按值**存，
  而 `create*` 返回 `getPtr` 的地址 —— **后续任何一次 `create*` 触发扩容，此前发出的所有指针立刻悬垂**。
  现有示例只建 4 个 gauge，靠初始容量侥幸没触发。改成 map 存 `*T` + `allocator.create/destroy`，
  对外 API 不变（调用方无需改）。回归测试 `issued metric handles survive registry growth`
  一次建 64 个句柄、创建完再回头写入 —— **在修复前它会崩**（`write after free` / `0x5555…` 段错误）。

**数据层：补齐 sqlx 的能力缺口 + 清掉一套死抽象**

- **`sqlx.Transaction` 补齐相对 `Client` 的缺口**（`src/sqlx/sqlx.zig`）。此前 `Client` 有 58 个方法、
  `Transaction` 只有 16 个，同一操作两种签名，缺的方法直接让调用方撞编译错误。
  本次**只做加法、零签名改动**（真实消费者 `zigshop` 在用 Transaction：`page/persistence.zig`、
  `bargain/{service,persistence}.zig`、`trade/service.zig`）：
  补 `queryRowsPartial(Ctx)`、`queryScalar(Ctx)`、`queryRowBorrowed(Ctx)`、`queryRowPartialBorrowed(Ctx)`、
  `findOne(Partial)(Ctx)`、`findAll(Partial)(Ctx)`、`batchExec(Ctx)`、`ping(Ctx)`，以及 `queryRow/queryRowPartial/queryRows` 的 `*Ctx` 形式。
  `findOne*`/`findAll*` 的 SQL 拼接逐字照抄 Client 侧，`validateIdentifier` + `validateSqlFragment` 两道闸一行不少。
  另把"**为什么 Transaction 要多一个 `allocator`**"写进了方法文档：事务里扫出的行必须活过事务自己的扫描作用域，
  所以由调用方给分配器；`Client` 用池/客户端分配器代劳 —— 这个差异是**设计**不是遗漏，此前没人写下来过。
  新增对照测试：同一查询在 Client 与 Transaction 各写一遍断言逐字段一致（`:memory:` 下必须
  `max_open_conns = 1`，否则两侧拿到不同连接 = 两个空库，对照会退化成"拿空气对比"）。
- **删除 `src/persistence/Database.zig`** —— 一套遗留的 vtable 抽象（自带 `VTable`/`QueryParams`/`ParamValue`），
  与真正在用的 `Orm(Backend)` + `SqlxBackend` 并存却**没有从 `root.zig`/`data.zig` 导出**，
  全仓唯一引用是"编译所有源文件"那个测试。死抽象比缺抽象更贵：读者会把它当数据层入口。
- **文档纠正**：`docs/ZENT.md` 新增「与框架自带那条的关系」—— 框架自带的默认是 sqlx
  （`build.zig.zon` 的 `.dependencies = .{}`，**zent 不是框架依赖**），ZENT.md 的"默认选 zent"
  是**新项目选型建议**，不是框架默认值的变更；`src/data.zig` 的 `SqlxBackend`/`Repository`
  doc 加了指认；`AGENTS.md` 补一行"zent 是平行栈、不共享事务"。
  `docs/BEST_PRACTICES.md` 新增「`*Ctx` 后缀 vs `ctx` 字段」：**共享句柄（`Client`）只能传参/后缀**
  （把 per-request 的 `SqlContext` 塞成它的字段就是数据竞争），**按请求拷贝的副本（`SqlxBackend`）用字段**
  —— 看起来不一致，其实各自都对。

**脚手架：生成物端到端租户安全 + 单表 test.zig 的模型名错配**

- **`zmodu scaffold` 生成的代码现在端到端租户安全**。上一轮给了 `Repository` 编译期租户守卫，但生成的
  `api.zig` 仍在调 `*Unscoped`（显式绕过守卫），租户过滤还是靠人。现在：
  - `service.zig` 为租户表补 `create<X>ByTenant` / `update<X>ByTenant` / `delete<X>ByTenant`。
    其中 **create 的关键性质是"先按请求身份把租户列盖章、再插入"** —— 客户端在 body 里声称什么租户都不算数
    （否则任何客户端都能往别的租户插数据）；update/delete 走 `updateForTenant` / `deleteForTenant`。
  - `api.zig` 的租户表 handler 通过 `ctx.tenantId()`（JWT catalog 中间件写的 attr）取租户，
    **取不到就 401 拒绝，绝不回退无作用域方法** —— 缺身份 ≠ 放行。生成物里 `*Unscoped` 调用数为 **0**。
  - 新增 `test_tenant.zig.tpl`：给租户表单表模块加一条**跨租户隔离**测试（四断言：body 声称别的租户仍落在自己名下 /
    list 只有自己那行 / 猜别人的行 id 得 404 / 无租户 attr 得 401）。
  - **非租户表的生成物逐字节未变**（同一份非租户 schema，改动前后各生成一次 `diff -r` 无差异；
    唯一差异是 `build.zig.zon` 的 `.fingerprint`，那是该字段本身非确定 —— 同一个二进制连跑两次也不同）。
    **该非确定性已修**（见下方「脚手架：行数语义与可复现输出」）。
- **修掉一个真缺陷：单表模块的 `test.zig` 模型名错配**。模板在 6 处（`model.X` 与
  `svc.create/get/delete<X>`）用了模块名 `<<PASCAL_MODULE>>`，但那些名字是**表派生**的
  （`strip_prefix_len = commonTablePrefix(tables)` 是**全局**前缀，所以只要 schema 有共同前缀
  ——`shop_*`/`tbl_*` 这类**主流情况**——模型名就会剥掉前缀而模块名不会）。
  实测：模块 `shop/product` 的模型是 `model.Product`，而生成的却是 `model.ShopProduct` →
  `error: … has no member named 'ShopProduct'`。修法：加第三个占位符 `<<MODEL_NAME>>`
  （`orm_tpl.expandOrmTest`），只把**表派生**的 6 处换过去；模块派生的 `…Persistence`/`…Service`/`…Api`
  保持 `<<PASCAL_MODULE>>`。红绿：修复后生成的工程 `zig build test` 14/14 通过；把模板改回旧行为重新生成
  则 `RED_EXIT=1` 并报出上面那条 `no member named 'ShopProduct'`。

**脚手架：行数语义与可复现输出**

- **跨租户改/删不再谎报成功**。生成的 `update/delete<X>ByTenant` 原先把 `updateForTenant`/`deleteForTenant`
  的受影响行数 `_ =` 丢掉，handler 随后**无条件** `wrapSuccess` —— 而框架的契约明确写着
  "0 means the row belongs to another tenant (guarded no-op)"。现在这两个方法返回 `!u64`，handler 把 `0`
  映射成 **404**（并发事件只在 `rows > 0` 时才发）。无作用域路径保持原样。
  新断言：用租户 A 的身份改/删租户 B 的行必须得 404，且**读回逐列证明 B 的行没被改动**；
  反证（还原成无条件 200）→ `expected 404, found 0`，2 条测试变红。
- **脚手架输出可复现**。`.fingerprint` 原先是随机的，同一二进制、同一 schema 连跑两次 `diff -r` 就 exit 1。
  现在从包名**确定性派生**（`checksum = Crc32(清洗后的包名)`、`id = Wyhash(0, 包名)`，遵循工具链
  `Maker/Package.zig` 的 `validate` 要求）。实测两次生成 `diff -r` **exit 0**，且 `zig build` 既不报错
  也不改写它（md5 前后一致）。附带：zon 里已有 fingerprint 时不再为了取随机值跑一次 `zig build`
  （scaffold 更快、不需要网络）。
- **修掉生成的响应体是非法 JSON**：`shared/response.zig` 的 `wrapSuccess` 用了**普通字符串字面量**
  而不是 format string，`{{\"code\":0…` 原样落进响应体 → **每个生成项目的成功信封都是
  `{{"code":0,…}}`**，任何 JSON 解析器都拒。而生成的测试只做**子串**断言（`"code":0`），
  两种写法都能匹配 —— 所以这个 bug 一直没被自己的测试抓到。已改成单花括号。

**验证**：`zig fmt --check src tools examples` · `check-production` · `check-deadcode` ·
`check-version` · `check-tenant-scope` · `check-bench` 全部 exit 0；
`zig build test` **1293 / 1314 passed（21 skipped，0 failed）**（`Database.zig` 自带的那条用例随文件删除 −1，
新增对照测试 +2、租户生成器单测 +4）；新测试连跑 5 次稳定通过（同一位置 178/1206），确认不是
`:memory:` + 连接池 的 flaky。租户链路另有一次独立复现（带共同前缀的两表租户 schema → 生成 →
`zig build test` **16/16**，并用"让 handler 忽略请求租户"做了**行为级反证**：隔离测试红在
`expected 401, found 0`）。
`examples/tenant-mgmt` 6/6、`examples/shopdemo` 13/13；`bash scripts/check-bench.sh` exit 0。

**定位级接线：三处"两边都齐、中间没接"**

都是"机制早已在树里，缺的只是连线"，不是新功能。

- **请求预算送进存储**。`request_timeout_ms` 原先**只在 handler 返回后**比一下耗时、超了改发 408
  （`Server.zig` 的 `elapsed_ms > …`）—— **不打断任何东西**，慢查询照样跑完、照样占着连接池；
  而 `SqlContext`（唯一的截止机制）在 sqlx 里有 6+ 处检查点，却**从没有 HTTP 侧调用者**。
  现在：`Context` 在请求进入时 `setDeadline(request_timeout_ms)`，`ctx.sqlContext()` 一行接进数据层，
  新增 `Orm.withContext()` —— **一次覆盖该请求的所有查询**（而不是 19 个方法各加变体）；
  `SqlxBackend` 持一个 `ctx` 字段并改走 `*Ctx` 变体（补齐了缺失的 `queryScalarCtx` /
  `queryRowBorrowedCtx` / `queryRowPartialBorrowedCtx`）。默认 `.{}` = 无截止，**不接线时行为与改动前完全一致**。
  语义边界写进了文档：`isDone()` 只拒绝**尚未开始**的语句（sqlx 无飞行中取消），所以这是
  "防止预算耗尽后继续堆查询"，不是"到点砍掉正在跑的那条"。
- **多租户隔离变成编译期强制**。`Repository(T)` 的 17 个无作用域方法此前**零租户感知**，
  防线是"人记得调 `*ForTenant`"。现在模型声明 `sql_tenant_column` 即开启守卫：无作用域方法
  `@compileError`，错误信息点名对应的 `*ForTenant` 与逃生舱 `*Unscoped`（安全的名字最短）；
  **未声明的模型零影响**（`tenant_column orelse return`），既有项目升级不用改代码。
  `zmodu scaffold` 生成的 `model.zig` 默认带上该声明。新增 `scripts/check-tenant-scope.sh`
  用三个 fixture（守卫开火 / 逃生舱可用 / 未 opt-in 不受影响）锁死行为并进 CI。
- **trace id 与日志闭环**。框架的 `tracingMiddleware` 手里有 trace id，却**只写响应头不写 `ctx`**，
  所以 handler 读不到、日志也无法关联。现在它复用一个合规的入站 `X-Trace-Id`（长度与可打印性
  有界 —— 该头客户端可控），否则生成，并 `ctx.setTraceId()`；配套新增 `Context.logScope("module")`
  （一行拿到已带 id 的日志作用域）与 `LogScope.withField()`。**走 `ctx.logScope` 而不是
  `LogScope.scope` 是有意的**：后者不报错、只是静默少一个字段。
  `examples/tenant-mgmt` 删掉了自己那份替身中间件，改用框架的 —— 实测同一请求的两行日志带同一个 id。

**验证**：以上三件完成后 `zig fmt --check src tools examples` · `check-production` ·
`check-deadcode` · `check-version` · `check-tenant-scope` · `check-bench` 全部 exit 0；
`zig build test` **1280 / 1301 passed（21 skipped，0 failed）**，主库 1184、`zmodu` CLI 79；
`examples/tenant-mgmt` 6/6。关键改动均带反证：把 `SqlxBackend.queryRow` 退回非 ctx 变体后，
新测试立刻报 `expected error.Timeout, found .{ .id = 1, .name = "Alice", .age = 30 }`。
另有一次端到端验证：`zmodu scaffold` 生成单表项目 → 其 `zig build test` 跑真实 Testkit 用例
（repository 往返 + POST 路由 dispatch）**9/9 pass**，且在"客户端分配器可检测泄漏 + ctx 为独立 arena"
的生产形状下 **0 leak**；把释放改回 `ctx.allocator` 后同一探针立刻报 **2 leaks**。
`zig build zmodu` 的安装行为也做了红绿验证（删掉 `zig-out/bin/zmodu` 后重新生成成功）。

## [0.26.0] - 2026-09-18

> **⚠️ 行为变更**：`Tool.action` 默认值收紧的后果（内置技能已声明类别）、`Server.fromEnv` 签名变更、
> `MessageQueue` 的部分后端 `publish` 由"静默丢弃"改为返回错误、`zmodu verify` 对无表模块放宽、
> `zmodu ci` 改为读 `.zmodu/audit-baseline.json`（与 `zmodu audit` 口径一致）。

### 新用户第一公里（本次最大的一块）

- **`README.md` / `README.zh.md` / `docs/QUICK-START.md`**：工具链钉版从**已被 ziglang 镜像回收**的
  `dev.1567` 改成 CI 同款 `0.17.0-dev.1970+67f39b551`（并注明"dev 版会被回收，以 `ci.yml` 的 `ZIG_VERSION` 为准"）；
  `brew install zig`（stable）从主安装方式降为反例说明；模块写法改 `pub const UserModule` + 正确传递；
  **补上缺失的 `build.zig.zon` 依赖声明**（本地 `.path` 与 tag 两种 + `-Ddb=` 收窄说明）；补 `app` 的构造、
  `generateDocs` 的第 4 个参数、`build.zig` 缺失的 `-Ddb=` option 与 `run`/`test` step。
  **验证方式**：把修完的围栏**抽出落盘**在临时工程里真编译 —— QUICK-START 四段与 README 两段全部
  `zig build`/`run`/`test` 通过；无法脱离业务代码的片段显式标注为 fragment。
- **`AGENTS.md`**：`ctx.paramInt("id")` → `ctx.paramInt(i64, "id")`、`ctx.json(200, .{…})` → `ctx.jsonStruct(200, .{…})`
  （共 6 处 + `docs/elegant-code-patterns.md` 4 处）；并把那句夸大的"门禁会抽查文档"改成**准确列举**覆盖形态。
- **`DocSnippets` 门禁扩容**：新增两类检测（值形态 `ctx.json(<数字>, .{`、缺类型参数 `paramInt("`），
  配"检测器自身单测"（合法写法不误报）；围栏内整行 `//` 注释不再判定（注释是"关于代码"的说明，避免误报）。

### 框架内缺陷修复

- **`zmodu scaffold` 生成的项目现在真能编译**（此前 9 个编译错）：修模板 4 处 —— `shared.errors.BizCode`
  的枚举字面量、`?i64` 的比较、生成的 `tests.zig` 不可编译、`.nest` 非 fmt-clean。
  **实测：生成项目 `zig build` / `zig build test` / `zig fmt --check src` 全 exit=0。**
- **`zmodu verify`**：① 支持**无表模块**（读 `module.zig` 的 `pub const info` 即接受缺 `persistence.zig`，
  并在输出里声明宽松规则）→ `examples/tenant-shop` 的 `zmodu ci` 首次 PASS；② 修 **SIGABRT**
  （`checkCompileWith` 把字符串字面量塞进 `details` 后被 `free`）；③ `verify` 单跑现在打印逐条错误、支持 `-j/--json`。
- **`PluginManager`**：修 test 块 API 漂移（`realPathFileAlloc`、`close(io)`）并**接进测试根**（此前是死测试）。
  复活后暴露生产 bug：`unloadPlugin` 在 `remove` 前 `free` 了 map 的 key → **条目永久残留**（已记录，未改生产）；
  另发现 `loadAllPlugins` 引用不存在的 `self.io` 字段（该函数无法编译）。
- **`MessageQueue`**：`redis`/`kafka` 后端的 `Producer.publish` 原是**空臂 → 静默丢消息**，现返回
  `error.BackendUnimplemented`，文件头新增逐后端能力清单；新增测试锁定该错误。
- **ORM 模板不再生成未用 import**：service 模板改为条件 import（`<<STD_IMPORT>>`，只在真用 `std.mem.*` 时生成），
  persistence/api/types/tests 生成物去掉未用 import。**验证**：重新生成项目的 `zmodu deadcode` 从 `dead: 7` → **0**，
  且生成项目的 `zmodu ci` 从 FAIL 变 **PASS**（六种生成变体全验）。
- **`zmodu ci` 口径 bug**：`auditJsonFor` 不再硬编码"全部违规计入 added"，改为读 `.zmodu/audit-baseline.json`
  （复用既有 `compareBaseline`）→ `zmodu ci` 与 `zmodu audit` 口径一致。
- **`Server.fromEnv` 从死代码救活**：签名改为 `*const std.process.Environ.Map`（= `init.environ_map`），
  加 `envInt` 容错 + **2 个测试**；`examples/production-deploy/README.md` 同步（含 `enable_http2` → `setHttp2Enabled(true)`）。
- **AI 闸门**：22 处内置技能补 `.action`（读/提议/执行；不确定的留 `.execute` fail-closed）；新增
  `SkillRegistry.auditPolicy` + `ai.PolicyHealth`（按类别体检，`Guard.isInert()` 的盲区有兜底）；
  `Workflow` 加 `guard` 字段并透传到 `.agent` 步骤；`--with-agent` 模板改为带 `guard`（默认空 = 惰性）并注入
  `tenant_id`/`user_id`。
- **版本护栏覆盖 `tools/`**：`scripts/check-version.sh` 新增 4 项检查（含 scaffold 的钉版与依赖 hash 非占位），
  scaffold 的所有版本引用改为单一来源 `ZMODU_VERSION` + comptime hash 前缀断言。

### 示例与文档

- **示例 `zmodu ci` 从 9 FAIL → 17/18 PASS**：清掉 8 个示例的未用 import/字段/函数；`shopdemo`(99)、
  `shopdemo-zent`(4)、`metaverse-creative`(12) 的 b4/b13 经 CLI `-u` 收进各自 `.zmodu/audit-baseline.json`
  （b4 命中的全是 router State 回取 `@ptrCast(ctx.user_data)`，`AGENTS.md` 明确允许）。
- **导出孤儿定性**：12 个"root 导出但零消费者"的项逐个判定为 **(b) 用户面向公开 API**（`FrozenMap`/`LoadBalancer`/
  `MessageQueue`/`PluginManager`/`HotReloader`/`IntegrationTest`… 各有文档背书或"按设计不接"的理由），
  改动**纯注释**（`git diff -U0` 校验零代码改动），无一删除。
- **文档**：`docs/UPGRADING.md` 补 v0.22–v0.25；`docs/BEST_PRACTICES.md` 的审计清单回填 23 条 ✅（逐条带证据）；
  `docs/ZENT.md` §8 与示例对齐（`deinitRows`）+ 版本 → v0.67.0；`MODULE_LAYERS.md` 写清 `Backend` 与 tenant_id；
  `docs/README.md` 收录 3 篇孤儿文档；`examples/README.md` 补齐 test-step 清单。

### 其它

- 两点**已知未修**（记录在案）：`PluginManager.unloadPlugin` 的 free-before-remove（UAF）；
  多表 `scaffold` 不写 `root.zig` 且 `--with-events` 变体的 publish 写死 `.id`（PK 名推导缺失）。

## [0.25.0] - 2026-09-18

### 集群：门面 + 选主状态机补完

- **`ClusterBootstrap` 补成完整门面**：`tick()` 现在一次做完 `membership.runOnce()` → `view.sync()` →
  **`raft.tick()`**（此前从没人驱动选举）；配了 `.transport` 时 `start()` **启动入站监听**并把连接交给
  `RaftTransport.handleConnection` 分发（端口起不来就 `error.RaftInboundListenFailed`，不静默降级），`stop()` 对应停掉；
  新增 `pick(key)`（rendezvous 选点）与 `healthJson(allocator)`，请求路径不必再自己拼 view/health。
- **修一个真 bug**：`start()` 把 `ElectionTransport` 存在**栈局部**再取地址给 `RaftElection` → `start()` 一返回即悬垂，
  第一次选举会跳到死函数指针（新测试实测 `Bus error`）；改为存字段。
- **选主状态机**：单节点（`cluster_size == 1`）**首次 election 即当选**（此前永远选不出）；`max_append_entries` 真接上
  （落后量大时分批，`@max(1, config)` 防 0 卡死）；`appendEntry` 末尾补 `advanceCommitIndex()`（单节点写入不再等心跳）。
  口径保持"只数 peer 票"，写进了 `startElection`/`handleVoteResponse`/`hasQuorum` 注释。
- **修一个真 bug**：`randomElectionTimeout` 在 `min == max` 时 `% 0` → **panic: division by zero**（退化为 `max(1, min)`）。
- **LB 有意不接**：`LoadBalancer` 的数据源是 PeerDiscovery 的「服务名→Peer」+ canary/计数，与读侧的「成员 id→地址+健康」
  是两份事实；每 tick 镜像会破坏 `sync()` 稳态零分配。已在 `docs/DISTRIBUTED.md` 写明接入点与分工。

### 2PC 持久化协调日志（in-doubt 有解）

- 新增 `src/core/TransactionJournal.zig`（`zigmodu.TransactionJournal`）：append-only、**只 INSERT 不 UPDATE**、
  DDL 方言中立、走 `data.SqlxBackend` 领域缝；不配 backend 时退回内存。
- 写点：`begun`（带参与者名单）→ **`prepared` 先落盘再返回**（崩溃窗口）→ `committed`；`abortPhase` 先写 `aborted` 再回滚。
  配了日志即 **fail-closed**（写不进去就报错、不前进）。
- `recover()` **只报告不决策**：返回"prepared 且无终态"的事务 + 参与者，供调用方自行重试/回滚。
  8 个新测试，含"preparePhase 后丢掉协调者 → 新实例 recover 读出 in-doubt"的崩溃恢复用例。

### Workflow / Saga

- `SagaStep.timeout_seconds` **真正生效**：事后判定（步骤耗时超预算 → 持久化 → 逆序补偿**含该步** → 终态 `.timed_out`
  → 返回 `error.SagaStepTimeout`）；`0` 表示不做预算。字段注释、`SagaStatus` 注释与 `docs/WORKFLOW.md` 同步。

### alpha-engine 参考实现推进到 P1–P3

- **P1 观测与容错**：HotBus 扇出（慢 audit worker 被丢弃计数、O(1) metrics sink 一条不漏）+ 被监督停掉的
  `FaultyFillReporter` + 可见背压；**四条断言**（`bus.dropped > 0`、`dropped_full > 0`、`stopped_by_supervisor`、`timer_fires > 0`）。
- **P2 模块化**：拆成 `market → book → alpha → risk → exec` + `audit`（跨模块零 import，消息统一放 `contracts.zig`）；
  `zmodu doctor`（7 modules / architecture OK）与 `zmodu ci` 六步全 PASS。
- **P3 AI 提议侧**：日终快照 → `ai.AgentWorker`（**注入 executor**，离线确定性）→ `ai.ProposalPipeline`
  （`guard(.propose)` 允许 → `ai.RiskReview` → `guard(.execute)` 被拒 → `execute_not_permitted`）→ **非 agent 路径**的
  desk 授权后由 `PaperExchange` 成交。两条 P3 断言（`denied_execute_class > 0` 且 **`effect_reached = 0`**、提议→授权→成交闭环）。

### 示例与文档

- **`shopdemo` 的 12 个测试真正跑起来**（此前不在导入图里，Zig 从不编译）：新增测试根 + test step，
  顺带暴露并修掉一处腐坏（`generated-sample/service.zig` 引用不存在的 `OrderEvent`）；`zent-modulith` 加 test step（`smoke.sh` 43 checks）。
- CI 的 test-step 循环补 `shopdemo`；`doctor`/`audit`/`test` 三个子集循环各加一行"Subset by construction"说明。
- 元数据/文档一致性清扫：`metaverse-creative`、`tenant-mgmt` 的旧版本号；`docs/BEST_PRACTICES.md` 两份审计清单标 ✅ 并加图例；
  `docs/DISTRIBUTED.md` 的门面/2PC/选主播述全部改成事实。

## [0.24.0] - 2026-09-17

> **⚠️ 破坏性变更**：删除 7 个示例文件/目录（`examples/testing/`、`examples/deprecated/`、`examples/cluster-demo/`、
> `examples/example_tests.zig`）—— 内容已分别并入 `examples/basic/src/tests.zig`、`examples/distributed/README.md`，
> 或属零引用占位。其余为纯新增/修复。

### 文档与示例品质（2026-09 复核批次）

- **导出面文档**：`src/root.zig` + 六个领域 barrel（http/data/security/ai/observability/runtime）新增
  **463 行 `///`**，覆盖率从 root 14% / barrel 4% 提到 **100%**（每条一句话：是什么 + 什么时候用）。
- **两个"死旋钮"接线**（文档承诺行为、代码零读取）：`Application.Config.max_dependencies` 现在真的在启动期
  做超限告警（`warnOverDependencyLimit`）；`Server.Config.connection_stack_size` 真的用于 accept 线程
  （低于平台下限才抬升）。两者各有测试。
- **可执行文档修正**：`Application.init(io, allocator, name, modules, Config)` 的真签名示例、`app.runtime()` 的
  `try` / comptime capacity、`ClusterView` 的 refcount 表述、`tuneSocket` 的 keepalive 说明。
- **`DocSnippets` 门禁扩容**：新增两类模式（`try app.runtime().spawn(...)` 整链、`Application.init(allocator` 首参错），
  并把 markdown 扫描**递归到 `docs/**`**（跳过插件目录）；两处旧片段顺带修正。
- **大文件可导航**：Server(4392) / KafkaConnector / Middleware / GrpcTransport / Http2Server / ai-workflow /
  redis / sqlx 加 `//! §N` 目录 + 正文 `// ==== §N ====` 锚点（`grep "§3"` 可跳）。
- **公开 error set 全成员文档**：12/12（新补 8 个 set / 94 条成员注释）；5 处 `@compileError` / `@panic` 文案
  统一成"期望形态 + 怎么改"。

### 修复

- **outbox 占位符错配**（真 bug）：`8977184` 给 INSERT 加了 `tenant_id` 列与第 6 个 `?`，而全仓 13 处调用方
  一律按 5 参绑定 → 参数错位、`updated_at` 无人绑定 → `NOT NULL constraint failed: event_outbox.updated_at`。
  非租户 SQL 改为 `VALUES (?, ?, NULL, 0, 0, ?, ?, ?)`（占位符回到 5 个，与调用方逐一对齐），租户变体保留 6 个；
  两条复现测试（含"临时改回旧 SQL 必失败"的反证）。`examples/ai-ops` 的 test 因此恢复并接回 CI。
- **英文 README 中文污染清零** + 门禁：`README.md` 出现汉字即失败，反向断言 `README.zh.md` 必须是中文（防对调）。
- `examples/distributed` 的"多节点部署"改成事实（跨节点事件总线，**无选主**）；`http-stress-test` / `tenant-mgmt`
  README 与代码对齐；根 README 的 Distributed 行同样改准；`docs/dev/upgrade-roadmap.md` 的 `cluster-demo` 引用
  加现状说明（历史原文保留）。

### 示例与 CI

- **CI 两份示例构建清单统一**（此前漂移：`zent-modulith` 只在一侧，`shopdemo-zent` / `metaverse-creative` 两侧都没有）：
  现在两份**逐字一致（17 项 + `zmsaas/backend`）**，19 个示例逐个实测离线 `zig build` exit=0；不可构建的目录
  （docker / node / sibling 依赖）在两处都写明原因。
- 已有 test step 的示例接进 CI（ai-ops / basic / llm-policies / tenant-ai / web4 / zmsaas-backend）。
- **收敛重复示例**：`testing` 并入 `basic`（3 个 test 逐条保留 + 2 条从未跑过的 demo 改为真测试，
  顺带发现其中一条原断言为假）；`cluster-demo` 并进 `distributed`；删 `deprecated/` 与 `example_tests.zig`。
  `examples/README.md` 索引与目录一一对应（20/20，脚本校验）。
- `alpha-engine`（v0.23 的 P0 示例）进 CI 构建列表 + doctor 循环，并补 README；`runtime-workers` 补 README。
- `shopdemo-zent` / `metaverse-creative` 的 zent 依赖由 `.path` 改 **git tag pin（v0.67.0）**；9 个 `build.zig.zon`
  的 `minimum_zig_version` → `0.17.0`。

## [0.23.0] - 2026-09-17

- **`ClusterBootstrap` 可选自带 Raft 传输**：`BootstrapConfig.transport` 接受应用提供的
  `RaftElection.ElectionTransport`；给了它就**不再**要求 `.allow_stub_raft_transport`（默认 `raft_cluster_size = 3`
  也能启动）。框架仍然不内置真传输，但 seam 可用、契约写清了：出站用 `NetworkTransport.connect/send`、
  入站用 `ClusterServer.start(handler)` 分发到 `handleVoteRequest`/`handleAppendEntries`/`handleVoteResponse`/
  `handleInstallSnapshot` 并在同一连接回包；`sendVoteRequest` 是 fire-and-forget（应答走入站），
  `sendAppendEntries` 是同步的；丢包按"消息丢了"处理，别把节点判死。详见 `docs/DISTRIBUTED.md`
  「真选主要什么」。测试用一个自带 transport 的 3 节点配置锁定"给了传输就能启动"。
- **真选主传输落地**（`src/core/cluster/RaftTransport.zig`）：wire 格式（4 字节长度前缀 + 1 字节 tag）、
  peer→地址簿、出站投票（fire-and-forget）与日志复制（同步读回）、入站分发（`handleConnection` 把
  `handleVoteRequest`/`handleAppendEntries`/`handleVoteResponse`/`handleInstallSnapshot` 的返回值在同一连接回包）。
  4 个测试，其中两个是**真 TCP loopback**：3 个 listener → `tick()` → 真投票 → 2/3 quorum → `isLeader()`。
  **诚实边界（未做，属 `RaftElection` 内部状态机）**：`handleVoteResponse` 收到第一张票就 `becomeLeader()`（不数票，
  quorum 由调用方 `hasQuorum` 判）；`tick()` 发的是空条目心跳且 `prev_log_index = last_idx`，空日志 follower 会拒 →
  落后 follower 追不上；`ClusterBootstrap` 不自动起入站 server 与 `raft.tick()`；`InstallSnapshot` 只有入站。
  另：`NetworkTransport.connect` 是死代码且引用即编译不过（`ConnectOptions` 需 `.mode`），本次在 `RaftTransport`
  内自建拨号，未改该文件。
- **`examples/alpha-engine/`（P0）**：`feed → OrderBook → Alpha → Risk → Execution → PaperExchange` 的确定性离线
  流水线（内嵌 200 点价格序列，无随机数），`Pipeline` 模块在 `initWith` 里 `ctx.runtime()` spawn 全部 worker，
  快照定时器 + drain barrier + `rt.stats()`。`zig build run` 退出码 0，连跑数字一致。P1–P3 见
  `docs/dev/alpha-engine-spec.md`。
- **doctor 补三项检查 + `graph --dot`**：doctor 新增「未解析服务 / 消费者计数 / 事件拓扑」三项 **advisory** 检查
  （查不到就输出 `n/a (静态分析不可得)`，不编数字；阈值 `--max-consumers N`）；`zmodu graph --dot` 把
  `ModuleGraph.renderDot` 接进 CLI（DOT 与 Mermaid 共用 `--out`）。顺带修：**doctor 的测试此前从未被编译**
  （`main.zig` 未在测试上下文引用它）→ 已并入 CLI 覆盖率门禁；`moduleOfImport` 把 `std`/`zigmodu` 误判成模块名 →
  改为只认相对 import。

## [0.22.0] - 2026-09-17

> **0 breaking**（Agent 闸门接线 + 三段骨架）。既有字段与函数签名全部保留，新增字段都有默认值。

### Added
- **`Guard` 接进 `Agent.run`**：设了 `Agent.guard` 之后，**每次工具调用先过闸门再分派** —— 被拒时把
  `{"error":"ToolDenied","reason":…}` 当工具结果喂回模型（它可以改走"提议"分支），同时计
  `AgentMetrics.tool_denied` 并按具体原因写 audit。闸门排在 `hooks.on_tool_request` 之前：结构上不该
  发生的事不必先问人。走闸门时不扣 guard 预算（LLM 花费归 `Agent.budget`，同一个 token 不记两次账）。
- **`skill.Tool.action`（默认 `execute`）**：工具自己声明类别（`read` / `propose` / `execute`）。
  忘了声明的工具永远拿不到宽策略 —— fail-closed 的默认值。
- **`ai.AgentSpec`**（`agent.Spec` + `build()`）：身份 / 技能 / 记忆 / 权限收在一处声明；
  `isGuarded()` 与 `isInert()` 把"没有闸门（无界）"和"有闸门但什么都没授予（惰性）"分开，便于启动期断言。
- **`Agent.memory` / `memory_prefix` / `memory_limit`** + **`memory.recallBlockAlloc`**：记忆按本次运行的
  tenant + user 注入 system message。`recall` 把 `0` 当"任意"，所以身份缺失或为 0 时**一个字都不注入**
  （跨租户注入是沉默的、最坏的那种失败）。
- **`ai.ProposalPipeline`**（`src/ai/proposal.zig`）：把 `todo3.md` §八 的三段做成不能跳序的骨架 ——
  `guard(.propose)` → `risk.RiskReview` →（escalate 时）`approval.ApprovalFlow` → `guard(.execute)` → executor。
  `executeStage` 私有；没有审批链时 escalate 是硬停（agent 不自我批准）；风险结论在"能不能执行"之前产生，
  于是常态结局是 `execute_not_permitted` **带着风险结果**交给人工，而不是一句无权限的沉默失败。
- 测试 +8（**1096 passed / 21 skipped / 0 failed**）：记忆作用域拒绝、Pipeline 三条拒绝路径（含 sqlite
  风险规则）、审批链放行、`Agent.run` 走闸门的两个相位、`AgentSpec` 接线。

### Changed
- `Agent` 新增 `name` 字段（默认 `"agent"`），日志改为 `[Agent:<name>] …`，同进程多 agent 可分辨。
- `docs/AGENT_RUNTIME.md` 增补：闸门接线、`AgentSpec`、Pipeline 图与三个刻意决定、记忆的 `0` 语义。
- **Runtime 被框架真正采用**（v0.21 之后第一件"装配线"工作）：
  - `ModuleContext.runtime()`（`src/core/ModuleContext.zig`）—— 模块在 `initWith` 里 spawn worker/timer；
    `Application.stop()` **先**请求停止并 join 它们、**再** `Lifecycle.stopAll`（worker 可能正在调模块服务）。
    裸 harness（直接 `Lifecycle.startAllWith`）里返回 `error.RuntimeUnavailable`，明确失败而不是偷偷新建一个。
  - `Application.runtime()` 现在**首次调用即启动 ticker**：此前返回未启动的 runtime，`handle.after(...)` 会静默不触发；
    启动失败时清理已分配的内存（`errdefer rt.deinit()`）。
  - e2e 测试锁定两条不变量：`ctx.runtime() == app.runtime()`（同一个对象）、worker 随 `app.stop()` 被 join
    （`src/Application.zig`「a module spawns workers through ctx.runtime()」）。
  - **`examples/runtime-workers` 改走 app + module 路径**：管线在 `Pipeline.initWith` 里通过 `ctx.runtime()` 建好，
    `main` 只驱动与观察 —— 参考示例教的形态与文档一致，且 CI 每次都会跑这条路径。
  - `docs/RUNTIME.md` 新增 §3d「模块里怎么用」：四条规则（只借不还 / 停止顺序 / 别自己 shutdown / 测试用 Manual 时钟就别走 app）。
- **`ai.AgentWorker`（`src/ai/agent_worker.zig`）—— `Agent → Worker → Event` 接通**（`todo3.md` §八）：
  `Agent.run` 会阻塞调用线程整轮 LLM 往返（`ai.trigger.Trigger.fire` 就是这么调的，一个慢模型占住一个请求线程），
  现在可以把 agent 跑成运行时 worker —— 有界邮箱（满 → 生产方 `error.Full`）、生命周期（`stop()` join）、
  监督（`spawnActor` + 错误预算）、指标（`handle.stats()`）全部白拿。
  - 所有权明确：`agent_worker.post()` dupe 目标文本、worker 跑完释放；`on_result` 拿到的 `AgentResult` 是借用。
  - 失败不算 worker 错误：provider 挂掉走 `on_result(err)` 由 app 决定重试/DLQ/告警，监督器错误预算留给真 bug
    （`stats().handler_errors` 保持 0，有测试断言）。
  - `executor` 可注入：默认 `Agent.run`，测试用罐头执行器（两个新测试不碰网络）。
  - 边界：`runtime.zig` 作为领域缝加入 `src/test/AiBoundary.zig` 白名单，理由写进 `docs/AI_BOUNDARY.md`
    （单向：ai → runtime 允许，runtime → ai 由反向检查绝对禁止）。
- **Cluster 读侧接通**（`todo3.md` §七 的第一条装配线）：`src/cluster/MembershipView.zig` 把 membership（写侧
  hash map）喂给 `ClusterView`（读侧引用计数快照 + rendezvous），请求路径不再读写侧；`ClusterBootstrap` 自带
  一个 view 并新增 `tick()`（一次做 gossip/health + 刷新读侧；`error.ReadersBusy` 不是失败）与 `getView()`；
  `root.zig` 导出此前只能按文件路径拿的 `RaftElection` / `PeerDiscovery` / `LoadBalancer` / `ClusterHealth` /
  `AccrualFailureDetector`；`ClusterMembership` 新增只读的 `nodesSnapshot()`（读侧的取数缝）。
  - 顺带修掉 gossip 负载里的地址格式：`{any}` 打印的是结构体 dump（`.{ .ip4 = .{ .bytes = … } }`）→ 改 `{f}`
    （`host:port`），并把"被发现的节点按 `127.0.0.1` 记账"这条**跨主机限制**写进代码注释与 `docs/DISTRIBUTED.md`。
- **`zmodu module <name> --full`**：默认只写 `module.zig`（一个声明），`--full` 追加六件套
  （`model` / `persistence` / `service` / `api` / `root` / `module_test`），一次得到 `docs/MODULE_LAYERS.md`
  说的模块形状。生成物经 `zig fmt --check` 解析校验、无残留占位符；`api.zig` 的 `ping` 路由默认 `.jwt`
  （改 `.public` 应当是刻意的一行）。实测：`zmodu module order --full` → 7 个文件、全部解析通过。
- **`zmodu ci` 纳入 `doctor`**：`zmodu ci` 现在跑 6 步（compile → fmt → verify → audit → deadcode → **doctor**），
  架构健康检查（环依赖 + 源码级纠缠）与应用发布门禁合成一条命令，与 CI 里针对每个 example 跑的那条
  （`ci.yml` "Architecture health on the example apps"）口径一致。已按 CI 的调用方式在 `examples/basic` 上
  端到端验证：`[doctor] PASS` + `summary: PASS`（exit 0）。
- **孤儿原语收编**（复核里"存在但没人用"那一条）：
  - `runtime.Sequencer` 接上真实消费者：`ai/agent.zig` 的 run-id 序列原本是私有 `std.atomic.Value(u32)`，
    现在用 `Sequencer`（同一语义、有文档、还带 `nextBatch`；经 `runtime.zig` 领域桶导入，落在 AI 边界白名单内）。
  - `runtime.ObjectPool` 如实标注「暂无仓内消费者」：`src/im/ConnectionRegistry.zig` 有连接表专用的 free list
    （约束不同），所以这条是**文档而非接线** —— 它的头注释解释了为何用 SpinLock 而非 Treiber 栈（ABA），
    属于刻意写的公共原语，面向"有界池、满了就拒绝"的场景。
- **文档片段抽查 `src/test/DocSnippets.zig`**：扫 `AGENTS.md` / `README.md` / `README.zh.md` / `docs/**.md` 里的
  **围栏代码块**（`zig` 或无标签；散文与表格按速记处理），禁止把 builder 方法直接链在 `zmodu.builder(…)`
  临时值后面 —— 那个形状编译不过（`error: expected type '*T', found '*const T'`，此前 12 处都这么写）。
  带"检测器自身的单测"：坏形状必须被抓、`var b = …` 正确形状必须放行。
- **集群：多节点启动 fail-closed + 修掉一个段错误**：
  - `ClusterBootstrap` 的 Raft 传输是桩（投票发不出去、append 恒 false），`raft_cluster_size > 1` 时 `start()`
    现在返回 `error.RaftTransportUnavailable`（并说明怎么承认：`.allow_stub_raft_transport = true`，或单节点
    `raft_cluster_size = 1`）—— 不再静默选出一个没有 quorum 的 leader。
  - **修段错误**：`start()` 里 `disco.deinit()` 与 `deinitResolved(peers)` 的 defer 顺序反了（前者把结构体置
    `undefined`，后者仍要读 `self.allocator`）→ 只要带**一个 peer** 启动就崩在 `0xaaaa…`。空 peer 列表时循环体
    不执行，所以这条多节点路径此前从未被跑过；新测试现在覆盖它（`PeerDiscovery.deinitResolved` 的文档也写明了这个调用顺序要求）。

## [0.21.0] - 2026-09-17

> **0 breaking**（v0.21 = Agent 的运行时闸门）。纯新增，`Agent` / `SkillRegistry` / `Budget` 一字未动。

### Added
- **`src/ai/guard.zig`（`ai.Guard` / `ai.Permissions`）** —— 把 `todo3.md` §八 的硬规则
  （**AI Agent 默认不能直接交易**）变成可测试的代码，两条轴都是 fail-closed：
  - **类别轴**（`read` / `propose` / `execute`）：`execute` 需要 `allow_execute` **另外**再开一次开关 ——
    把 `order.submit` 写进 allow 不等于"这个 agent 可以下单"，配置写错不会静默交出交易接口。
  - **名字轴**：`allow` 默认**为空**（无策略的 agent 什么都不能做，`isInert()` 让调用方启动期就能大声失败）；
    `deny` 永远压过 `allow`，宽列表可被局部收回而不必重写。
  - 预算在**同一个 `check()`** 里扣：被拒绝的动作**不消耗预算**（否则配置错的 agent 会靠"试"把自己饿死），
    拒绝原因**分门别类计数**（not_listed / explicitly / execute_class / budget）——
    "看起来健康"的被拒 agent 正是这道闸门要防的东西。
  - 3 项测试：空策略三类别全拒且计数正确、列名之后 `execute` 仍需第二开关（且 `deny` 压过它）、
    拒绝免费 / 允许计费 / 超预算单独计数。
- **`docs/AGENT_RUNTIME.md`** —— 两条轴的表、接线示例（拒绝 `execute` 后落到 `propose` 分支，正是规则要的形状）、
  与 `security/` 的分工（这道闸门管 **agent 自身**的权限，不是终端用户鉴权），
  以及**还没做**的三件事（身份/记忆/技能尚无声明式包装、`Guard` 未接进 `Agent.run` 调用链、
  Proposal→Risk→Execution 只有 Proposal 侧入口）。

## [0.20.2] - 2026-09-17

> **0 breaking**（v0.20.2 = AI 与驱动层解耦完成）。纯 import 替换，无行为变化。

### Changed
- **`src/ai/**` 不再直接 import 驱动层**：56 处（`sqlx/sqlx.zig` 30 + `persistence/backends/**` 26，
  分布在 21 个文件）全部改为 `@import("../data.zig")`。`data.sqlx` 与 `data.SqlxBackend` 本来就是同一批
  模块的 re-export，所以这是**类型同一性不变、行为不变**的机械替换 —— 整个迁移用一个替换规则完成，
  全量测试 1085 全绿（含 AI 的持久化/审批/预算等用例）。
- 诚实记录：这 56 处里绝大多数是**测试脚手架**（`:memory:` 客户端与 backend 的构造），
  真实生产耦合小于这个数字；但一条替换就能清零，没有理由留着。
- `src/test/AiBoundary.zig` 的两个冻结上限从 30 / 26 调到 **0 / 0**，等于对驱动层 import 的绝对禁止：
  再新增一处就编译失败。`docs/AI_BOUNDARY.md` 的表格同步为迁移前/后对照，抽包条件由
  "两个计数到 0" 变成"保持为 0"。

## [0.20.1] - 2026-09-17

> **0 breaking**（v0.20.1 = 把 AI 抽包的边界变成机器检查）。纯新增测试 + 文档。

### Added
- **`src/test/AiBoundary.zig`** —— AI 边界的机器检查，两半：
  - **反向绝对禁止**：`src/{core,api,data,sqlx,http,security,messaging,runtime}` 下任何文件 import
    `ai/` 即失败（现在 `src/` 里只有 `root.zig` 一行 re-export，是唯一的缝）。
  - **正向 ratchet**：`src/ai/**` 只许 import 领域缝；直接 import 驱动层
    （`sqlx/sqlx.zig`、`persistence/backends/**`）被冻结在实测上限 **30 / 26**，**只能减不能增**；
    计数下降时会打印一行提醒把上限调低。
- **`docs/AI_BOUNDARY.md`** —— 实测数据（21 个文件里 56 处绕过 `data.zig` 的驱动层 import）、
  允许/禁止清单、每个文件的清理路径（`@import("../sqlx/sqlx.zig")` → `@import("../data.zig")`）、
  抽包条件（两个计数到 0 且测试持续为绿），以及**为什么要 ratchet 而不是一次性清理**
  （把 56 处 import 的迁移和边界定义混在一次提交里难以验证）。

### Why
v0.21 的 Agent Runtime 要求 AI 层能被别的包依赖 —— 而"能被依赖"的前提是它只依赖**稳定接口**
（领域缝），不是"当前那个驱动文件恰好长这样"。顺序必须是先收边界再加能力，否则耦合只会更多。

## [0.20.0] - 2026-09-17

> **0 breaking**（v0.20 = 长流程可恢复执行）。新增 `resumeInstance`，既有 `execute` / WAL 格式不变。

### Added
- **`SagaOrchestrator.resumeInstance(id)`** —— 继续一个被上一个进程留在半途的 saga（由
  `restoreFromWal` 装回来）。语义写进 `docs/WORKFLOW.md`：已 `completed` 的步**不重跑**、
  崩溃时**在飞**的那一步**重跑**（所以有副作用的步骤必须幂等）、终态实例（completed/compensated/
  failed/timed_out）与补偿中途（compensating）一律拒绝（`error.NothingToResume` / `UnknownInstance`）。
- 步进循环抽成 `runFrom(instance_id, start_index)`：`execute` 与 `resumeInstance` 共用一条路径，
  续跑的语义不可能与首次执行漂移。
- 2 项测试：崩溃续跑（手写一条"step index 1 在飞"的 `saga-state` WAL 记录当崩溃现场 → 恢复 →
  续跑只重跑在飞那步 + 之后各步，且不触发补偿）、恢复取**最新**状态（回归测试直接钉住下面第 1 条）。

### Fixed
- **恢复会复活已结束的实例**：`restoreFromWal` 原先逐条看记录，只要任意一条是 `running` 就恢复 ——
  而"失败并补偿完"的 saga 在 WAL 里正是 `running → running → compensated` 的链条，于是它会以
  `running` 回来，续跑即**重复补偿**。现在按实例取最后一条状态再决定。
- **`restoreFromWal` 每次启动泄漏**：`readFrom` 交出的条目（topic/payload/source_node）归调用方释放，
  它从不释放。之前没有测试调用过这条路径，所以没人发现。
- `pub fn resume` 无法编译：`resume` 是 Zig 关键字（`suspend`/`resume`）→ 改名 `resumeInstance`。

### Docs
- `docs/WORKFLOW.md`（新）：一步之内的语义表（什么重跑、什么拒绝、为什么）、WAL 接线样例、
  本版修掉的三个真问题、**刻意不做**的四件事（不加 DSL / 不做调度器 / 不做跨节点编排 /
  `ai/workflow.zig` 保留并说明分工）。
- `AGENTS.md`：文件地图加一行（长流程用 `resumeInstance`，副作用步骤必须幂等）。

## [0.19.0] - 2026-09-17

> **0 breaking**（v0.19 = 集群读侧）。纯新增：`ClusterView` 与既有 DistributedEventBus /
> ClusterMembership 并存，后者一行未动。

### Added
- **`zigmodu.ClusterView(N, G)`（`src/cluster/ClusterView.zig`）** —— 集群状态在**请求路径**上的安全读法：
  - **引用计数的成员快照**：写者（维护循环，单写者）`publish()` 整份替换；读者 `acquire()` → 用 →
    `release()`，全程无锁、无分配、无 GC。写者在复用槽位前等该槽读者清零，等不到返回
    `error.ReadersBusy` 而不是覆盖活数据（发布是秒级活动、读是微秒级活动，等是便宜的方向）。
  - **`pick(key)` / `pickRanked(key, rank)`**：rendezvous（最高随机权重）哈希选节点，主 + 至多 3 个备份。
    选它而不是 `core/eventbus/Partitioner.zig` 的一致性哈希环：环要重建、读要加锁，而 rendezvous
    无状态无锁，"成员变化只迁移它拥有的 key"这条性质同样成立；环仍留在批量写的事件总线路径。
  - `error.TooManyMembers`（超容量拒绝，计数）、`stats()`（publishes / generation / members /
    healthy / over_capacity / readers_busy）、`peek()`（诊断用，明确标注"可能被回收"）。
  - 6 项测试：发布即拥有字符串（调用方之后改原 buffer 不影响快照）、rendezvous 稳定性（同集合换序不换主、
    新增节点只迁移一部分 key）、不健康节点永不入选（全不健康 → null，而不是错的答案）、
    **并发**（20k 次发布 × 3 读者 → 0 次不一致读；写者按设计报 Busy 且 publishes+busy 计数守恒）、
    分代环复用后当前视图不丢、超容量拒绝且旧视图完好。

### Docs
- `docs/DISTRIBUTED.md`：新增「集群读侧：`ClusterView`」——为什么请求路径不该读写入侧的哈希表、
  回收没有 GC 靠引用计数、为什么用 rendezvous 而不是环、以及**本版刻意不做**的四件事
  （不发明协议 / 不做跨节点一致性 / Raft 与分布式事务仍 experimental / `weight` 留位未使用）。
- `AGENTS.md`：文件地图 + 两行 DO/DON'T（读侧 acquire/release；`ReadersBusy` 当作"下个 tick 再发"）。

## [0.18.0] - 2026-09-17

> **0 breaking**（v0.18 = 架构引擎）。唯一可能让工程"突然编译不过"的是新增的编译期图检查 ——
> 而它拦的正是**以前会在启动期 abort** 的那些图（环 / 缺失 / 自依赖 / 重名），
> 需要动态装配模块的场景可以 `.withCompileTimeGraphCheck(false)` 关掉。

### Added
- **编译期架构检查（`src/core/ModuleGraph.zig` + `ApplicationBuilder.build`）** —— 模块依赖图从
  "启动期校验"前移成"编译期数据"：
  - 检查：缺失依赖 / 自依赖 / 重名 / **环（DFS，报错信息里带完整路径 `a -> b -> a`）**。
  - 阻断性问题直接 `@compileError`，不再等到二进制跑起来第一件事就是 exit。
  - 关闭：`.withCompileTimeGraphCheck(false)`（仅用于动态装配的模块集，启动期 `validateModules` 仍在）。
  - 同一份分析在运行时也可用：`analyzeRuntime(allocator, nodes, limits)`（动态注册表可自检），
    与编译期版本共享 `Report`/`Finding`/渲染器。
  - 诚实边界：**"domain 不许 import 数据库"这类规则编译期无法检查** —— 模块声明里没有"某文件
    import 了什么"这个信息。声明无法执行的规则比不声明更糟，所以源码级纠缠交给 `zmodu doctor`。
- **`zmodu doctor`（CLI）** —— 不编译工程就能拿到架构健康报告：
  - 复用 `audit.collectModules` 的源码扫描，跑同一套图检查（环/缺失/自依赖/重名/依赖数阈值/孤儿）。
  - **新增跨模块直接 import 检测**：`src/modules/alpha/**` 里出现 `@import("../beta/service.zig")`
    即报纠缠并给出 `文件:行`（"declare the dependency, import the module barrel, or `--allow`"）。
  - `--json`（CI/看板）、`--max-deps N`、`--allow from->to`（承认一处纠缠，可重复）、`--skip-imports`。
  - 退出码：阻断性问题 → 1（可直接进 CI），纠缠 → warn 不影响退出码（设计味道，不是坏图）。
- 7 项 `ModuleGraph` 测试：健康图（含深度度量）、环（路径闭合）、自依赖+未知依赖、重名、
  阈值与孤儿是**告警不阻断**、两个渲染器（Mermaid/DOT/文本，含错误文本里点到点的通配）、
  以及运行时孪生（与编译期同结论）。CLI 侧另有 `moduleOfImport` 与 JSON 渲染的单元测试。

### Fixed
- **`mapOfImport` 的路径深度算术**（本版新写的第一版）：按"importing 文件的目录深度"扣 `..` 个数
  会**拒掉模块根文件写的 `../../other/x.zig`** —— 而这正是最常见写法。改成"剥掉前导 `..` 后取首段，
  再与已知模块名比对"，更简单也更难写错。
- **`analyzeRuntime` 返回的是 DFS 栈而不是环**（首版）：环体被建好后没交给调用者，返回值少一个元素
  且泄漏一份分配。现在通过出参回传，并有"环路径首尾同名"的断言兜住。
- **`@compileError` 的无条件分析**：`if (!report.ok()) @compileError(...)` 在条件未被 comptime 折叠时，
  分支体会被分析 —— 于是**所有**调用点（含健康图）都编译失败。用 `comptime {}` 块 + `inline ok()` 修正，
  并留注释说明原因（这类 bug 的症状是"检查器把好代码也判死"，很容易被误当成"太严"而关掉）。

### Changed
- `tools/zmodu` 与根 `build.zig` 都把框架的 `ModuleGraph` 暴露为命名模块 `module_graph`：
  CLI 与框架**共用一份**环/结论算法，而不是在工具里复制一份会漂移的实现。
  为此 `ModuleGraph.zig` 保持**零框架依赖**（只用 std），其测试夹具用本地 `Info` 结构而非 `api.Module`。

### Docs
- `docs/ARCHITECTURE.md`：新增「Architecture engine」——两半的输入/时机/检查项、三层强度
  （编译期挡住 / 启动期告警 / CLI 报告）、优先级约定（阻断 vs 告警），以及"为什么 import 级规则
  只能在 CLI 层"。
- `AGENTS.md`：文件地图加一行；DO/DON'T 加两行（依赖靠编译期检查拦住；交付前跑 `zmodu doctor`，
  别声明无法执行的架构规则）。

## [0.17.0] - 2026-09-17

> **0 breaking**（v0.17 = 运行时的监督与扇出，仍是纯新增）。v0.16 的 worker 语义一字未改：
> `rt.spawn(...)` 依旧"记录错误并继续"，新语义只在 `spawnActor` 上生效。

### Added
- **Actor 监督（`rt.spawnActor(W, init, cap, Supervision)`）** —— Actor 是"加了失败策略的 Worker"，
  不引入第二套生命周期：
  - `Supervision.strategy = .restart | .stop`：`.restart`（worker 语义，默认）只记录继续；
    `.stop` 首个错误即停（fail-fast，邮箱关闭、线程退出）。
  - `max_errors` / `window_ms`：**窗口错误预算**。窗口内超过 N 次即停，`0` = 不限。
    一个"每条消息都出错"的 actor 在"只记录"语义下会永远烧掉一个核而外部看起来健康 —— 预算把
    它变成"停止 + 一条 warn + 计数"。
  - `pub fn onError(self, err, ctx) Supervision.Strategy`（可选声明）：**现场决策并覆盖配置策略**
    （例如只有 `error.Fatal` 才停）。
  - 停止后 `stats().stopped_by_supervisor == true`、邮箱关闭（生产者拿到 `error.Closed`），**不会**
    退化成静默丢弃；`WorkerStats` 新增 `errors_in_window` / `stopped_by_supervisor`。
  - 诚实边界（写在 `docs/RUNTIME.md` §3b）：本版**不**实现"用干净状态重启 actor"（需要初始状态副本或
    `reset` 钩子，语义未定就不给）；父子关系目前只体现为**停止顺序**——`shutdown` 按 spawn 逆序 join，
    所以"先父后子"即"子先停"，真正的监督树留给后续版本。
- **`runtime.HotBus(E, N)`（L0 扇出）** —— 一个事件、多个消费者，而发布方不能等：
  - `subscribe(*Handle(W, cap))` 接 worker（消息类型不符是**编译期**错误）、`subscribeSink(Sink)`
    接非 worker 消费者（指标、广播器、测试记录器）。
  - `freeze()` 之后 `publish` 是一次**无锁、无分配**的切片遍历；未 freeze 就发布返回
    `error.NotFrozen`（接线 bug 应大声失败而不是竞争）。
  - 满的订阅者**丢该条并计数**（`stats().dropped`），慢消费者既不能拖慢发布方也不能吃光内存。
- **`runtime.Sequencer`** —— 无锁单调序列：`next()` / `nextBatch(n)`（原子预留一段连续值）/
  `peek()` / `advanceTo()`（只前进，不回退，供快照回放）。**不是时钟**：只在进程生命期内可比较。
- 12 项新测试：Actor 四条（worker 语义保持 / fail-fast / 预算耗尽 / `onError` 覆盖两个方向）、
  HotBus 五条（扇出顺序、慢订阅者丢弃并计数、未 freeze 与 freeze 后订阅、容量、真 worker 邮箱打满）、
  Sequencer 三条（唯一性、并发下区间不相交、`advanceTo` 不回退）。
- `examples/runtime-workers` 扩成 v0.17 形态：订单簿把每条 delta 发到 `HotBus`，扇出给
  **故意慢的审计 worker** + **O(1) 的指标 sink**，并跑一个必然失败、被预算停掉的 actor。实测
  `subscribers=2 published=261 delivered=330 dropped=192`（审计丢、指标一条不漏、订单簿从未阻塞）、
  `attempts=4 stopped_by_supervisor=true mailbox_closed=true`。CI 仍会构建并运行它。

### Docs
- `docs/RUNTIME.md`：新增 §3b（Actor 与监督，含"为什么不实现带状态重启"）、§3c（HotBus 两条规则
  与实测数据）、worker 契约表加 `onError`、原语表加 `Sequencer`/`HotBus`、路线图把 v0.17 标为已落地
  并把"真监督树/跨节点监督"明确列为**未承诺**。
- `AGENTS.md`：DO/DON'T 再加两行（持续失败用预算而不是永远记录；L0 扇出用 `HotBus` 而不是 L1 EventBus）。

## [0.16.0] - 2026-09-17

> **0 breaking**：本版只新增（v0.16 = 运行时底座，见 `docs/dev/todo3.1.md` 的兼容策略）。
> 不调用 `app.runtime()` 的应用，线程数、生命周期、行为与 v0.15.x 完全一致。

### Added
- **ZigModu Runtime（`zigmodu.runtime` + `app.runtime()`）** —— `Application`（架构单元：Module/DI/
  Lifecycle/EventBus/HTTP）旁边新增一条**可选**执行通道（执行单元：Worker/Mailbox/RingBuffer/
  TimerWheel），共享同一个 io / config / 可观测性。定位与契约见 `docs/RUNTIME.md`。
  - `RingBuffer(T, N)`：单生产者/单消费者**无锁**环（各自只读对方指针，无 CAS），N 必须 2 的幂。
  - `MpscRing(T, N)`：Vyukov 有界多生产者队列；**N ≥ 2 由编译期强制**（N=1 时序列号无法区分
    "空"与"未消费"，会覆盖未消费消息 —— 实测 `len` 涨到 2）。
  - `Mailbox(T, N)`：有界 + spin-then-block 交接。`send` 满即 `error.Full`（背压对生产者可见），
    `sendBlocking(msg, timeout)` 用延迟换不丢，`close()` 唤醒所有等待者并允许排空。
    无丢唤醒的保证写在实现里：消费者在**持锁**下复查空、生产者在**持锁**下 signal。
  - `Wheel(Payload)`：分层时间轮（5 层 × 64 槽 × 10ms，最长 ~124 天），O(1) 插入/取消；
    长停摆（ticker 被饿死）走 **O(pending) 扫描**而不是逐槽空转；`cancelWith` 带 drop 钩子，
    取消与触发都必须能释放 payload（否则取消即泄漏）。
  - `ObjectPool(T)`：定容对象池，`acquire` **不分配**、耗尽返回 null；`release` 校验归属并拒绝重复归还。
    自旋锁而非无锁栈：索引上的 Treiber 栈有 ABA 窗口会把同一对象发两次，而"发两次"没有测试能稳定复现。
  - `Clock`：`.monotonic`（生产）/ `.manual`（测试：推进一小时定时器不需要睡觉）。
  - `Runtime` + Worker 契约（comptime 探测，热路径无 vtable）：`pub const Message = T` + `handle(self, msg, ctx)`
    走消息驱动；`run(self, ctx)` 自带循环；`init`/`deinit` 为可选生命周期钩子。
    `rt.spawn(W, init, cap)` → `Handle`：`send` / `sendBlocking` / `stop` / `join` / `after(ms, msg)` / `stats`。
    `rt.start()` 起 ticker（或 `rt.tick()` 自驱）、`rt.shutdown()` 请求停止 → 唤醒 → join。
  - `RuntimeStats`：`workers / running / messages_sent / messages_received / messages_dropped /
    handler_errors / timer_fires / timer_lag_max_ms`；每 worker 明细在 `handle.stats()`。
- `Application.runtime()`：**首次调用才创建**（不调用 = 零线程、零定时器）；`stop()` 先
  `runtime.shutdown()`（join 所有 worker）**再**停模块 —— worker 可能正在调模块服务；
  `deinit()` 释放。`Application` 的既有 API 一字未动。
- `examples/runtime-workers/`：行情源 → 订单簿 worker → 风控 worker + 快照定时器的流水线。演示
  ①状态单线程独占（**全文件无锁**）②有界背压（5000 条里 4645 条在生产者侧被削掉、队列零增长）
  ③定时器只投消息（在 worker 线程上处理，不在 ticker 上跑业务）④优雅停机（屏障消息排水 + join）。
  CI 会构建**并运行**它。
- 31 项运行时测试，含真并发：4 生产者 × 5000 条零丢失、20 万条 SPSC 序贯、对象池 8 线程
  acquire/release 收支平衡、以及唯一一条真正启动 ticker 线程的端到端定时器用例。

### Fixed
写这套原语时被测试抓出的四个真 bug（都记在代码注释里，防止回退）：
- `Wheel.cancel` 不更新**槽头指针** → 取消槽内首个定时器后，下一次 `advance` 会遍历已释放节点
  （SafeAllocator 报 `write after free`）。现在 `unlink` 会修头指针，另有"取消中间节点"的回归用例。
- `MpscRing` 在 **capacity = 1** 时**静默覆盖未消费消息**（生产者写 `pos+1`、消费者写 `pos+capacity`，
  同一个数值无法区分状态）→ 编译期拒绝，并在文档写明替代方案。
- `Runtime.running` 把"ticker 已启动"与"运行时存活"混为一谈 → 不调用 `start()`（文档承认的受支持用法）
  时，`ctx.stopped()` 立刻为真，run-owned worker 一行没跑就退出（实测 `ticks = 0`）。
  拆成 `alive` 与 `ticker_running`。
- `timer_fires` 在**投递之后**才自增（计数器落后于自身效果 = 竞态）→ 先计数再投递；
  `timer_lag_max_ms` 此前从未被写入（假字段）→ 由每个 timer 的 deadline 真实计算。
- 另：`Mailbox.dropped_full` 不再被 `sendBlocking` 的内部重试污染（只统计非阻塞 `send` 的拒绝）。

### Docs
- **`docs/RUNTIME.md`**（新）：定位（Modulith + Runtime）、兼容 10 条、worker 三种声明方式、
  原语取舍表（含"为什么池用锁而不是 Treiber"）、背压三规则、事件分层 L0/L1/L2（**不替换现有
  EventBus**）、何时不要用运行时、可观测性、v0.16 → 1.0 路线图。
- `AGENTS.md`：文件地图加 `docs/RUNTIME.md`；DO/DON'T 加四行（worker 与邮箱、`error.Full` 必须显式处理、
  定时器只投消息、运行时是 opt-in 别给 CRUD 加 worker）。

## [0.15.47] - 2026-09-15

### Changed
- **zent 适配 v0.41.1 → v0.67.0**（26 个 minor，`examples/zent-modulith` 的 pin 升到
  `?ref=v0.67.0#e60d81e`）。编译级破坏只有一处：**`CrudService.create(entity, tenant_id)`
  双参**（zent v0.54.0）——旧签名从实体读租户列，而写循环会复制每个字段、拦截器又只填"缺失"的，
  于是调用方新建实体的租户字段为 0 时会写 `0`。本仓库 `zent_crud.CrudApi.create` 已改为
  `create(buildEntity(tenant, body), tenant)`。
- 语义级变更（编译通过但行为不同）已在 §14 记录并验证：**空 `dept_ids` 由"放行全表"改为拒绝**
  （zent v0.66.0 的安全修复，本仓库 smoke 已把"空 `dept_ids` → 空结果"钉成断言）、无谓词
  `BulkDelete` 报 `error.NoPredicate`、无 `last_insert_id` 报 `error.MissingLastInsertId`、
  MySQL 批量改逐行、MySQL 的 `String`/`Enum` 落 `VARCHAR(255)`、`driver.Error` 新增
  `ParamCountMismatch`/`PoolWaitTimeout`。

### Fixed
- **示例崩溃：`deinitRow` 与 `CrudService.get` 的分配器不匹配**（`GET /api/v1/products/{id}`
  命中一行即 `panic: free of invalid memory` 打死整个服务器）。根因不在 zent：
  `CrudService.get(allocator, …)` 返回的是 **`ownedCopy(allocator, …)`**（字符串归调用方传入的
  allocator，即请求 arena），而 `client.<entity>.deinitRow(&e)` 用 **client 的 allocator** 释放 →
  不匹配释放。这是上一轮（commit `23bd2e1`）把 `deinitEntity(…, ctx.allocator)` 机械替换成
  `deinitRow` 时引入的：旧写法传的是拥有者 arena，而 Zig 0.17 里 `ArenaAllocator.free` 是 no-op，
  所以无害；换成 client allocator 后同一个调用变成非法释放。修法：arena 拥有的 owned copy
  **不交给 `deinitRow`**（代码里留了 7 行注释说明契约，防止被"修回去"）。已核对全仓 30 处
  `deinitRow(s)`：其余都作用于驱动扫描出的行（builder `Save()` / `Query().All()`），契约正确。
- **升级验证被增量缓存欺骗**：pin 已改成 v0.67.0 后 `zig build` 仍"编译通过"，但崩溃栈里的源码
  路径是 `zent-0.41.1`——Zig 0.17-dev 的缓存沿用了旧 fetch 依赖。现在 §14/AGENTS.md 明确
  "改 pin 后先 `rm -rf .zig-cache`（并删 `zig-pkg/<旧版本>`）"，本轮即按此复现出真实的编译错误。

### Added
- **`examples/zent-modulith/smoke.sh`**：43 项运行时断言（真实服务器 + 真 sqlite 文件库），覆盖
  泛型 CRUD、原子扣减、事务下单、嵌套预加载、keyset 游标、批量软删、outbox、SSE、data-scope
  四种 scope 与"缺上下文 401"，并在结束时断言**服务器仍存活且日志无 panic**。
  **接入 CI**（Build Examples job）：编译示例证明不了集成正确——上一轮就是"编译通过"而一个请求
  就能打死进程。

### Docs
- `docs/ZENT.md`：版本口径 → v0.67.0；§14 新增 0.42–0.67 六条（含两条升级陷阱：`deinitRow` 与
  owned copy 的分配器匹配、增量缓存沿用旧依赖）；pin 片段改 `v0.67.0.tar.gz`；能力矩阵范围
  改 v0.30–v0.67。
- `AGENTS.md`：zent workspace 事实重写（v0.67.0 + 两条陷阱 + 0.54/0.57/0.58/0.66/0.67 的要点）。
- `examples/zent-modulith/README.md`：版本口径 + smoke 段指向脚本。
- `examples/shopdemo-zent`、`examples/metaverse-creative`（本地 path 依赖）对 **v0.67.0**
  编译通过；`examples/_shared` 同步确认。

## [0.15.46] - 2026-09-15

### Added
- **`http.UploadGuard` — 上传内容策略**（唯一被外部反馈认定为"真缺口"的一处）：框架此前只解析
  multipart 并限制体积，**没有任何内容校验**，于是每个收上传的应用各写一遍，而三种常见写法都有洞
  （只查扩展名 → 改名即绕过；只查 `Content-Type` → 客户端自填；放行 SVG → 脚本容器，从自己源站
  发出去就是 stored-XSS）。新增：
  - `sniff(bytes)`：JPEG/PNG/GIF/WebP/BMP/TIFF/PDF/ZIP/GZIP/**MP4（ISO-BMFF，校验 box size + `ftyp`）**
    /WebM/OGG/MP3/WAV，以及文本容器分类（`<svg`/`<!doctype html`/`<script` → 主动内容）。
  - `check(filename, data, policy)` / `checkForm(form, policy)`：判定顺序固定为
    **大小 → 主动内容 → 扩展名白名单 → 格式白名单 → 扩展名与内容一致**，因此错误可诊断：
    "`avatar.jpg` 里是 PHP" → `ContentNotAllowed`，"PNG 字节挂 `.jpg` 名" → `ExtensionContentMismatch`。
  - **SVG/HTML 默认拒绝**（`allow_active_content = true` 才放行），fail-closed。
- **`http.extractMultipart(ctx, config)`**：与 `extractJson*` 对齐的抽取器，失败直接产出 ProblemDetails
  —— 415（不是 multipart）/ 413（太大）/ 400（缺 boundary、畸形、part 过多）；`OutOfMemory` 不渲染。
- **`Multipart.Config.forBodyLimit(body_limit)`**：用同一个数字对齐"单 part ≤ 总量 ≤ 请求体上限"。
- `RateLimiterRegistry`：`max_keys`（`initWithCapacity`）+ LRU 淘汰、`remove(name)`、
  `retain(max_idle_seconds)`、`generateReport()`。
- `CircuitBreakerRegistry`：`count()`、`generateReport()`（真实 JSON）。
- `Context.requestParam(name)`：**form 优先、回退 query** 的取值器（Rails/Laravel/ThinkPHP `input()` 语义）。
- `Context.nestedParam(path)`：点号路径查找（原 `paramPath`，新名不再读起来像"路径参数"）。
- `CircuitBreaker`：`lastUsedAt()`；`PluginManager.dynamicLoadingSupported()`。
- `src/core/SpinLock.zig`：共享的短自适应自旋锁（自旋后 `yield`），供 io-free 热路径临界区复用。
- 测试：`http/UploadGuard.zig`（8 条：嗅探、ISO-BMFF 尺寸校验、主动内容、改名绕过、跨族改名、
  限额/扩展名、表单级）、`test/RouteTemplate.zig`（4 条：三条注册路径 + 未匹配）、
  `RateLimiterRegistry` 淘汰/LRU/retain 4 条、`CircuitBreakerRegistry` 指针稳定性 + 报告、
  `CapabilityRegistry.generateApiBoundaryReport`、`SpinLock` 2 条、`Multipart.Config.forBodyLimit`。

### Fixed
- **`ctx.route_template` 形状随注册方式而变**：`group.get("/health")` 得 `/health`、
  `group.get("health")` 得 `health`、ComptimeRouter `mountAll` 得 `orders/{id}`、
  `addRoute` 得 `/metrics` —— 同一套指标里两种拼法，写死的 dashboard 查询会漏一半流量。
  现在 `Router.addRoute` 里统一为"恰好一个前导斜杠"（该处本来就在 dupe 路径，零额外开销）；
  匹配逻辑不受影响（trie 按 `/` 切分，不用这个字符串）。
- **`CircuitBreakerRegistry` 与 `RateLimiterRegistry` 同族的两处缺陷**：按值存 breaker →
  `getOrCreate` 返回的内部指针**下一次插入 rehash 后失效**（悬垂指针，与 zent 连接池 UAF 同族）；
  且全程零同步。现改为堆分配指针 + 内部锁，指针在 registry 生命周期内稳定。
- **两个热路径锁是"纯自旋不让出"**：`http/AccessLog.zig`、`http/HttpMetrics.zig` 的
  `while (!mutex.tryLock()) spinLoopHint();` 在争用下烧 CPU。改用共享 `SpinLock`（自旋 32 次后
  `std.Thread.yield()`），并把 14 处 `self.mutex.state.store(...)` 的裸解锁换成 `mutex.unlock()`。
- **`Multipart.Config.max_total_bytes` 默认值永不生效**：`Server.Config.max_body_size`（默认 8 MB）
  在读体阶段先 413，`Multipart.parse` 不会被调用，所以默认 32 MB 的总量上限不可达。
  模块头/字段/`Context.multipart` 三处写明判定顺序，并新增 `forBodyLimit` 对齐工具。
  **默认值未改**（降成 8 MB 会静默改变"已抬 body 上限"的调用方行为）。
- **`generateReport` 占位串**（`RateLimiterRegistry`、`CircuitBreakerRegistry`、
  `CapabilityRegistry.generateApiBoundaryReport`）返回 `"pending … migration"`：改为真实 JSON 快照。
- **`PluginManager.loadPlugin` 是静默 no-op**（登记名字但不加载代码）：现在每次 warn 一行，
  并提供 `dynamicLoadingSupported() == false` 供调用方分支。
- `Transactional` 的日志串 `"Rollback transactionfailure: {}"` 缺空格；`core/Error.zig` /
  `ObjectValidator` / `SecurityScanner` / `ModuleBoundary` / `ApiVersioning` 中同一批"半翻译"注释
  （`ValidationRequired field`、`ValidationModule boundary`、`API versionRoute group` …）一并写清。
- `SecurityModule` 里错位的 `/// Validation JWT Token`（挂在 `setKeyring` 上方，与下一行冲突）删除。

### Changed
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` / `CircuitBreakerRegistry` /
  `AccessLog` / `HttpMetrics` 的锁统一为 `core/SpinLock.zig`**（同一份实现，避免多份自旋逻辑漂移）。
- `CircuitBreakerRegistry.breakers` 类型 `std.StringHashMap(CircuitBreaker)` →
  `std.StringHashMap(*CircuitBreaker)`（破坏性，仅影响直读该字段的代码）。
- `Context.paramPath` → **DEPRECATED**，改用 `nestedParam`（行为不变）。
- `ShardRouter.ShardedQuery` **移除**：只能 `return error.NotImplemented`，且全仓无调用点
  （物理分表由 DB 层负责，模块头已写明）。
- `Partitioner.zig` 文件头"tests are disabled pending integration"是过期描述——测试实际在跑且通过，
  注释改为实情（仍未接入 `DistributedEventBus`，这点保留）。

### Docs
- `BEST_PRACTICES.md`：新增「上传与 multipart」整节（三个问题、限额优先级表、三种错误写法、
  `UploadGuard` 判定顺序与错误表、支持嗅探的格式清单、落盘路径提醒）。
- `UPGRADING.md`：补 v0.15.46 段（含 `route_template` 标签值变化的升级动作、
  `CircuitBreakerRegistry` 字段类型变化、`paramPath` 弃用）。
- `ISSUES_FROM_ZIGSHOP.md`：追加第二轮 4 条核实矩阵（含 #3 的机制更正与真问题定位）与顺带发现清单。
- `API.md`：Multipart 限额顺序、Uploads（`extractMultipart` + `UploadGuard`）、
  `nestedParam`/`requestParam`、`route_template` 规整、registry 淘汰与报告。
- `AGENTS.md`：DO/DON'T 加"上传内容校验""上传限额对齐""取参数用对名字"三行；文件地图加上传一节。
- **全仓 628 行被 `[...]` 污染的注释修复**（35 个文件；这批注释是 `6316708`「翻译所有中文注释」
  那次自动化替换留下的残骸——中文被吞、英文技术名词残留，出现 `/// Module contract[...]`、
  `/// [...]publish/consume[...]Event[...]API[...]` 这类半句）。按 `6316708^` 的原文核对语义后用
  英文重写（与各文件现存语言一致）；`Page.zig` 里 JSON 示例的 `[...]` 是合法省略号，保留。
  校验：逐文件比对"非注释行"与 HEAD，**34/35 文件零代码改动**（另一个是我本批的改动），全量测试通过。

## [0.15.45] - 2026-09-15

### Added
- **进程级错误渲染器**：框架自产错误体有三条出口（链内 `ctx.sendError`、路由前裸 socket、
  handler 自写），此前只有第三条能被应用改。新增
  `http.useRfc7807Errors()`（一次把前两条统一成 RFC 7807，media type
  `application/problem+json`）、`http.setDefaultReject(?AuthRejectFn)`、
  `http.clearDefaultReject()`、`http.problemReject`、
  `http.setTransportErrorRenderer(?TransportErrorFn)` / `http.problemTransportBody`
  （路由前 408/413/431/503 的体）、`Context.sendErrorEnvelope()`（绕过渲染器）。
  `ModuleGateConfig` 补 `reject: AuthRejectFn`，**可保留 `.unknown = .deny` 同时改 404 体**。
  装渲染器后"链尾中间件改 404 体 + 放弃 `.deny`"的 workaround 可删。
- **handler 侧权限匹配**：`Context.permissionsCsv()`（与 `rolesCsv()` 同形）、
  `Context.permissionMatches(expr)`、`http.permissionMatchesContext(ctx, expr)`、
  `http.permissionMatchesWith(ctx, expr, config)`（与某个 gate 完全同语义）。
  与 gate 的 OR 语义（`portal:user|portal:shop`）共用同一实现 —— 匹配原语下沉到
  `ZigModu.security.Rbac.exprMatchesCsv` / `exprMatchesAuthInfo`，
  `permissionGateWith` 改为委托，杜绝 handler 与 gate 两套语义漂移。
- 测试：`src/test/ErrorShape.zig`（链内/路由前/未捕获 500 的形状矩阵，含"装 `defaultReject`
  为默认渲染器不得自递归"）、`src/test/PermissionMatch.zig`（OR 表达式、AuthInfo 权威性、
  `.roles`/`.rbac` 同语义）、`resilience/RateLimiter.zig` 两个并发用例
  （去守卫会放行 117/100 —— 有牙）、`redis.zig` 三个 RESP 分帧用例。
- 文档：`docs/UPGRADING.md`（逐版本 breaking / 影响面 / 一行改法）、
  `docs/ISSUES_FROM_ZIGSHOP.md`（第 1–13 条核实矩阵：属实/部分/已存在/不属实 + 依据）。

### Fixed
- **Redis 客户端四件套**：① `pool_size <= 1` 的共享单流分支**不加锁** → 命令交叠、
  流错位后端点永久挂起；② 每条命令只 `readSome` 一次 → 大回包截断且余字节留在流里污染
  后续命令；③ `read_timeout_ms` / `write_timeout_ms` 声明了但全仓无读取点 → 读可以永久阻塞；
  ④ 解析失败后连接原样放回池。现在：按 RESP 分帧读（`$`/`*` 先读长度再读体，**尾部 CRLF
  从流里消费并校验**）、无池分支由 `stream_mu` 串行化、读路径每次阻塞前 poll 到 deadline
  （超时 `RedisTimeout`）、写路径 `SO_SNDTIMEO`、任一失败即 `evictStream()` 摘除该连接。
- **`ProblemDetails.toJson` 不做 JSON 转义**：`detail`/`instance`/`type` 含引号即产出非法
  JSON（校验消息会带用户输入）。现全部经 `std.json.Stringify` 转义，
  `ValidationProblem` 同步；`statusTitle` 补全 402/411/413/414/415/416/418/428/431/451/501/505/507。
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` 无任何同步**：
  `current_tokens` 的读-改-写竞争会**同一枚令牌被两个线程花掉**（实测去掉守卫后 100 枚令牌
  放行 117 次）；registry 的 `StringHashMap.put` 会撕裂元数据。三类各加内部短守卫
  （先 `spinLoopHint`，32 次后 `std.Thread.yield()`；临界区只有一次 map 查找或两次浮点运算，
  故不自旋到死也不引入 `io` 参数）。
- **`RateLimiterRegistry` 按值存 `RateLimiter`**：`getOrCreate` 返回的 `*RateLimiter` 指向
  map 内部存储，**下一次插入触发 rehash 即悬垂**（与 zent 连接池 UAF 同族）。改为存
  `*RateLimiter`（堆分配），指针在 registry 生命周期内稳定 —— 有"插入 257 个 key 后旧指针
  仍可用"的测试。

### Changed
- `RateLimiterRegistry.limiters` 字段类型 `std.StringHashMap(RateLimiter)` →
  `std.StringHashMap(*RateLimiter)`（**破坏性**，仅影响直读该字段的代码；用
  `get`/`getOrCreate`/`count` 的调用方不受影响）。详见 `docs/UPGRADING.md`。
- `ctx.sendError` / `ctx.sendErrorResponse` 现在优先交给进程级渲染器；未装渲染器时行为
  与之前一致，仅 `msg` 改为 JSON 转义（含引号的消息此前会产出非法 JSON）。
  装渲染器后 `sendErrorResponse` 的业务 `code` 不被表达（RFC 7807 无业务码位）。
- `ModuleGateConfig.reject` 默认仍为 `defaultReject`（信封），但 `defaultReject` 经
  `ctx.sendError` 转发，故跟随进程级渲染器；`setDefaultReject(defaultReject)` 解析为
  "不装渲染器"，避免自递归。
- `RateLimiter.acquire` 标注 DEPRECATED（与 `tryAcquire` 同义）。
- `AGENTS.md` 测试计数不再抄写具体数字，改为"以 `zig build test` 输出为准"
  （`-Ddb` 收窄、平台、门控用例都会改变计数，抄下来必然漂移）。

### Docs
- `BEST_PRACTICES.md`：新增「错误响应形状：一条开关统一全框架」（三种形状 × 触发路径 ×
  三条守则）、「共享限流器 / 统计结构的线程安全」（三个自查问题）、
  「跨函数边界返回：必须具名类型」；「数据访问选型」补 sqlx `Client`/`Transaction`
  两套签名与 `Rows`/`ManagedRows`/`BorrowedRow`/`QueryResult` 所有权表（签名已与源码核对）。
- `API.md`：新增「Error response rendering」「Permission matching」两节，校正
  `RateLimiter`（`acquire` 返回 `bool`、补 `release`）、`RateLimiterRegistry`（补 `get`/`count`
  与指针稳定性）、补 `SlidingWindowRateLimiter`。
- `AGENTS.md`：文件地图加 `UPGRADING.md` / `ISSUES_FROM_*`；DO/DON'T 加错误体统一、
  单 gate 换形状、handler 问门户三行。

## [0.15.44] - 2026-09-12

### Changed
- **zent 适配 v0.39.2 → v0.41.1**（pin 升到发布 tag `?ref=v0.41.1#2611ade`）：
  - **采用 v0.40 的一行式释放**：示例里 23 处手写 `zent.codegen.deinitEntity(infos, info, &e, alloc)`
    （含 5 处 `for (...) deinitEntity; list.deinit()` 手写循环）全部改为生成客户端的
    `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)`；整页释放需要把 `const rows` 改为
    `var rows`（helper 会重置调用方的列表并使其可复用）。
  - v0.41.0：`crud_helpers.queryRows` 被明确为**裸路径**（与 `driver.query` 同类，不带你配的
    软删/隐私/拦截器），必须用 `zent.scope` 组合 —— 已补进 `docs/ZENT.md` §15。
  - v0.41.1：修复 0.40.0 把 `deinitRows(rows: anytype)` 收窄成只认值、导致传 `&rows` 编译失败的
    回归；这条与本仓库「anytype 形参的契约写法」的规矩同源，已写进 §14。
- 文档：`docs/ZENT.md` 版本口径 / §14 兼容表（新增 0.40/0.41 三条）/ §15 使用边界、
  `AGENTS.md`、示例 README 同步；四个 zent 示例全部重建通过，zent-modulith 运行时
  实测（嵌套预加载 / 列表释放 / 裸 SQL 搜索 / 事务）零错误。

## [0.15.43] - 2026-09-12

### Added
- **公开 API 错误集快照**（建议第 3 条）：`src/test/ErrorSetSnapshot.zig` 用
  `@typeInfo` 反射钉住 `verifyToken` / `Multipart.parse` / `Server.start` 的错误集——
  ①消费方 `switch` 依赖的错误必须仍在，②总数不得超过记录的上限（**放宽即破坏性变更**，
  必须在本文件里显式确认），③退化成 `anyerror` 直接失败。基线：三者当前都是窄集
  （22 / 7 / 19），**没有 anyerror**。
- **组合矩阵测试**（建议第 7 条）：`src/test/CombinationMatrix.zig` 覆盖
  `moduleGate(.unknown = .deny) × skip_prefixes`（目录内放行 / 目录外拒绝 /
  `health/*` 等跳过前缀放行）与 `tenantResolver × JWT aud × override_existing`
  （默认 aud 优先、显式覆盖时 header 优先、`require` 时无租户即拒绝、query 回退）。
- **基数纪律写成明文禁令**（建议第 8 条）：`OBSERVABILITY.md` 明确禁止把
  `tenant_id`/`user_id`/`order_id` 直接做标签（几千租户 = 几十万序列），给出两条正解
  （受限基数 family 仅用于小集合 / 租户维度留给日志与 trace），并指出"按租户分流 =
  把基数变成部署维度"。
- **升级自查从"读文档"变成"跑命令"**（建议第 4 条的一部分）：`docs/ZENT.md` §14 顶部
  给出三条命令（`zmodu audit` / `zig build check-production` / `zig build test`，
  含形态与错误集快照、文档一致性）与"升级后先删 `.zig-cache`"的硬提醒。

## [0.15.42] - 2026-09-12

### Added
- **文档 ↔ 代码一致性门禁**（建议第 6 条）：新增 `src/test/DocsConsistency.zig`，
  扫描 `docs/API.md` 里所有 `pub fn` / `pub const` 声明，逐个核对 `src/` 中是否存在
  该声明（大写名字按"类型构造器"写法放宽、忽略仅注释里出现的词），缺失即 CI 失败。
  首次运行抓出 **4 个纯虚构 API**：`TransportProtocol`、`MqttTransport`、
  `TaskScheduler`、`PasRaftAdapter`——它们从未存在于本仓库，却被当作可用能力写在
  API 参考里。已修正文档（Transport 段改为真实情况：HTTP/1.1 + h2c + gRPC，
  MQTT 明确"未提供"；Scheduler 改为真实的 `zigmodu.cron.Scheduler` 签名；
  Raft 指向 `core/cluster/RaftElection.zig` 并标注 experimental），另修掉把
  `Context.body` 字段写成方法的条目。
  范围只含 API.md：BEST_PRACTICES 有意展示**应用侧**示例代码（`OrdersApi` 等），
  扫它全是误报。

### Changed
- **`anytype` 形参的契约显式化**（建议第 1 条）：`Preflight.dbCheck` /
  `Preflight.EnvCheck.fromMap` / `PrometheusMetrics.registerMetricsRoute[Path]` /
  `Dashboard.registerRoutes` 现在
  ①doc comment 首句写明"必须是**指针**、需要哪些方法"，
  ②加 `@compileError`（含 `@typeName` 与实际修法）把错误提到**调用点**，
  ③配一条"鸭子类型替身"回归测试固定契约。
  最佳实践写法（含分类：对象指针 / 鸭子 client / 任意事件值 / comptime 元组）落在
  `docs/BEST_PRACTICES.md`「`anytype` 形参的契约写法」。

## [0.15.41] - 2026-09-12

### Added
- **`Auth.optional`：公开但可个性化的路由（一等能力）**。`Auth` 此前只有
  `inherit | public | jwt`：`public` 完全跳过验签、`ctx.userId()` 恒为空，而需要身份就等于
  `.jwt`（游客直接 401）。C 端用户中心这类"公开但想看是谁"的接口只能靠 handler 里手写
  token 检查。现在：

  ```zig
  pub const routes = [_]cr.RouteSpec(State){
      .{ .method = .GET, .path = "me", .handler = me, .meta = .{ .auth = .optional } },
  };
  ```
  语义：**有 token 就验并注入身份，token 缺失/非法/过期一律不影响请求**，永不 401。
  与 `.public` 的差别被显式化并可测试（矩阵用例覆盖 optional×{无/有效/坏 token}、
  public×有效 token、jwt×{无/有效 token}）。同时把此前只在 `authFromCatalog(AuthBackend)`
  一支存在的"尽力而为验签"抽成 `attachIdentityBestEffort`，三处中间件行为一致；
  `permissionGate` 的 public 短路不覆盖 `.optional`（这类路由仍可带 permission/roles 元数据）。

### Added

### Changed
- **CI 门禁 `check-production.sh` 覆盖全仓**：原来只扫 9 个硬编码热文件 + `src/security/*`，
  其余文件（含 auth/tracing 中间件）长期是盲区。现在按前缀分层：
  `src/api|core|http|metrics|messaging|scheduler|security` **强制**，其余
  （`ai/`、`extensions/`、`im/`、`log/`）先**告警**（28 处，作为待收紧清单）。
  扫描同时忽略注释行（文档里提到该模式不再误报）。

### Fixed
- **`catch unreachable` 的可达性收敛**（第 2 类"把环境失败当成不可能"）：8 处
  `page_allocator.create(...) catch unreachable`（中间件构造：CORS / jwtAuth /
  jwtAuthFromCatalog / …WithPermissions / authFromCatalog / tenantResolver / moduleGate /
  tracing）在 `ReleaseFast` 下是 UB，现改为 `catch @panic("<可读原因>: out of memory")`；
  2 处测试内的 `catch unreachable` 改为 `try` / `error.TestUnexpectedResult`；
  `SO_SNDTIMEO` 设置失败从静默改为 **warn**（那意味着慢客户端能无限阻塞写线程）。
- **`PrometheusMetrics` 直方图可能半初始化**：`createHistogramFamily` 里
  `counts.append(0) catch {}` 失败时会留下"有桶无计数"的直方图（`le` 行永久错误），
  现改为清理并降级到 overflow 序列，保证桶与计数始终同步。
- 重点路径上 15 处 `catch {}` 改为带上下文的 debug/warn（分布式锁回收与释放、
  HTTP/2 窗口与 RST、连接池回收与退避、outbox/cron 睡眠、access-log、
  auto-instrumentation），符合仓库既有的"不吞错误"规则。

## [0.15.40] - 2026-09-12

### Changed
- **zent 适配 v0.37.0 → v0.39.2**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`?ref=v0.39.2#1fbf86c`）。两个 minor 带来：
  - **BREAKING（0.38）**：`queryTargets` / `queryTargetsByValue` 改为 **fail-closed**
    （软删 → 隐私 → 拦截器，与 `WithEdge` 同契约）；旧的"仅软删"语义改名为
    `queryTargetsUnscoped` / `queryTargetsByValueUnscoped`。目标表带策略而无
    `privacy_ctx` 时返回 `error.PrivacyDenied` 而不是静默跳过过滤。
  - **安全（0.39）**：新增 `zent.scope`，让**手写 SQL** 也能拼上同一份读契约；
    此前裸 SQL 会静默绕过租户/隐私过滤。`<col>Like`（`Contains` 的诚实名字）、
    NULL 容忍扫描器（`scanRow*Lenient` / `queryAllLenient`）、`zent.version`。
- **文档同步**：`docs/ZENT.md` §4.7 补"裸 SQL 的安全前提（必须接 `zent.scope`）"，
  §14 兼容表新增 0.38/0.39 两条升级注意，§15 增加三条使用边界（scope、fail-closed
  邻居读取、宽松扫描器的适用面），版本口径与依赖示例更新到 v0.39.2。

## [0.15.39] - 2026-09-12

### Changed
- **`ctx.query` / `ctx.form` 升级为多值容器 `Params`**（zapi 反馈 P1-4）：重复键
  （`ids=1&ids=2`，即 `<select multiple>` / 复选框组的原生形态）不再被覆盖，括号键
  （`role_id[0]`、`tags[]`）按原样保留供上层解释。**兼容性**：`get()` 仍返回**最后**一次
  出现的值（与旧的单值 map 语义一致），消费侧 `ctx.query.get("page")` 无需改动。

  ```zig
  ctx.query.get("ids")            // 最后一次（历史语义）
  ctx.query.getFirst("ids")       // 第一次
  ctx.query.getAll("ids")         // 全部（到达顺序）
  ctx.queryArray(alloc, "ids")    // 重复键或 ids[0]/ids[]（索引排序）
  ctx.formArray(alloc, "role_id") // 表单同上
  ctx.paramPath("filter.tags")    // 点路径 → filter[tags]（form 优先、回退 query）
  ctx.bindForm(T) / bindQuery(T)  // 绑定契约不变；现也吃重复键与 role_id[0] 首元素
  ```
- **参数数量上限**：`Server.Config.max_params`（默认 1000，对标 PHP `max_input_vars`）。
  query 与 form 都按"出现次数"计数，超限返回 `error.TooManyParams`，**不静默截断**。

### Added
- `zigmodu.http.Params` 导出（`put`/`putOwned`/`get`/`getFirst`/`getAll`/`getArray`/
  `getPath`/`getSegments`/`count`/`totalValues`），6 个新测试覆盖重复键、括号数组
  （索引排序 + `[]` 追加 + 无括号回退）、点路径、参数上限与所有权转移。

## [0.15.38] - 2026-09-12

### Added
- **`multipart/form-data` 一等支持**（zapi 反馈 P1-5）：`src/http/Multipart.zig` +
  `ctx.multipart(cfg)` / `ctx.bindMultipart(T, cfg)`。

  ```zig
  var form = try ctx.multipart(.{});         // defer form.deinit();
  const title = form.value("title");         // 文本字段
  if (form.file("avatar")) |f| { ... }       // 文件：f.data / f.filename / f.content_type
  // 文本字段也可整批绑定：
  const Meta = struct { full_name: []const u8, age: i64 };
  const meta = try ctx.bindMultipart(Meta, .{});   // 与 bindForm 同一套 loose 绑定契约
  ```

  要点：文本查找**永不返回文件块**（`value()` 跳过带 filename 的 part）；「首次命中优先」
  与 `bindForm` 一致；整个 body 在内存中解析（框架本身已缓冲请求），因此防护是 `Config`
  限额 —— `max_parts` / `max_part_bytes` / `max_total_bytes`，超限分别返回
  `TooManyParts` / `PartTooLarge` / `PayloadTooLarge`，而非盲目分配。
  **不做流式落盘**（请求体已被缓冲，流式 API 只会假装省内存），落盘是应用决策。
  新增 5 个测试（boundary/Disposition 解析矩阵、混合表单含文件、四类拒绝路径、
  文本字段桥接、Context 端到端）。

### Added
- **静态文件服务**（`zigmodu.http.staticFiles` / `StaticFiles.staticMiddleware`，zapi 反馈 P1-6）：

  ```zig
  try zigmodu.http.staticFiles(io, &server, allocator, "/assets", "public", .{
      .cache_control = "public, max-age=3600",
  });
  ```

  实现为**中间件**而非路由：路由器现阶段的 `/prefix/*` 只匹配前缀本身，路由式挂载无法服务其下文件。
  行为约定：只服务 `GET`/`HEAD`（其余 405）；**不做目录索引/列表**（`/assets/` → 404）；
  路径先归一化再碰文件系统（`..`、绝对路径、反斜杠、`:`、NUL 一律拒绝）；
  `ETag`（size+mtime）支持 `If-None-Match` → 304；`Range` 支持 206 / 416（多段范围回落为整实体）；
  超过 `max_bytes`（默认 16 MiB）返回 413 而不是整文件读进内存；
  正文按 `chunk_bytes` 分块读取。挂载对象按进程生命周期分配（所有权契约写在文件头注释里）。

### Fixed
- **表单体的解码口径与 query 不一致**（`parseFormBody`，zapi 反馈 P0-1）：query 的
  key/value 都会 percent-decode，而 form body 原样 `dupe`。后果有两层：`formValue("name")`
  拿到的是 `%E5%BC%A0%E4%B8%89` 而不是 `张三`；更隐蔽的是 **key 也未解码**，浏览器把嵌套键
  编成 `role_id%5B0%5D`，于是 `formValue("role_id[0]")` 永远查不到。现在两条路径同一口径
  （`%XX` 与 `+`→空格 都在解析期处理）。
  ⚠️ **迁移提示**：消费侧若自己补了解码器（zapi 的 `contract/params.zig` 即此类），
  需要删掉，否则会对已经解过的值再解一次；这类解码器同时可删的还有"逐字符比较原始 key"
  的查找函数。
- **CORS 空 allowlist 的失败模式不可诊断**（`Middleware.cors`）：显式传空
  `allow_origins` 时所有跨域请求（含预检）一律 403 且无任何提示；现在启动时会 warn 一行。
  （默认值仍是 `&.{"*"}`，只有主动传空数组才会触发。）

### Added
- **`ctx.bindForm(T)` / `ctx.bindQuery(T)`**（zapi 反馈 P0-2）：表单与查询的声明式绑定，
  语义与所有权对齐 `bindJsonLoose` —— 字段名 loose 匹配（`role_id` ↔ `roleId`）、
  缺省值保留、字符串字段深拷贝（调用方统一 free）、缺必填字段返回 `error.MissingField`
  而不是静默零值。支持 `[]const u8` / 整数 / 浮点 / `bool`（`1/0/true/false/on/off`）
  及其 `?T`；其它类型是编译期错误（不静默跳过字段）。
  同时支持嵌套键的**首元素**绑定：字段 `role_id` 可直接吃下 `role_id[0]`。
- **`ctx.pathParam(name)`**：`param` 的显式别名，消除"路径参数 vs 任意参数"的误读。
- **`ctx.jsonValue(status, value)`**：`jsonStruct` 的别名。**注**：zapi 反馈称"框架只有
  `ctx.json(bytes)`"，实际 `jsonStruct(status, anytype)` 早已存在且正是"任意 Zig 值 →
  JSON"（P0-3 的真实缺口是命名可发现性，不是能力）。

### Added
- **Best-effort identity on `.public` routes.** `authFromCatalog` now verifies a
  presented token even when the catalog marks the route `.public` and attaches
  the resulting identity, instead of skipping verification outright. A missing,
  malformed, or expired token changes nothing — the route stays public and
  `verifyFn` never writes a response — but a *valid* one lets a public handler
  optionally personalize (`ctx.userId()` / `optionalPortalUser`). This closes
  the gap where a public-but-personalized endpoint (e.g. a C-end user center)
  always saw an anonymous caller, since the framework had no "optional auth"
  mode (`Auth` is `inherit | public | jwt`). Cost on public routes: one header
  lookup without a token, one JWT verification with one.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.15.37] - 2026-09-12

### Fixed
- **CI `Test (DB=postgres)` 失败**：新增的真实 PG 锁用例连不上 CI 的 service 容器。
  根因是 sqlx 的 PG 驱动默认 `sslmode=require`（安全默认，保持不改），而测试用
  service 不支持 TLS —— 仅在该 job 里设 `PGSSLMODE: disable`（一次性测试库）。
  已用同一条件在本地复现并验证。
- **CI `Benchmark` job 首次真正执行即失败**：`benchmark-action` 需要 `gh-pages`
  分支，仓库还没有 → 加 `skip-fetch-gh-pages: true` 让其自举（该 job 此前因
  分支条件写错从未运行，v0.15.36 修好条件后才暴露）。

## [0.15.36] - 2026-09-12

### Changed
- **zent 适配 v0.33.0 → v0.37.0**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`git+…?ref=v0.37.0#d36edb7`）。新版本带来：池 `max_wait_ms` 真正阻塞等待
  （默认 0 = 旧语义）、嵌套预加载每层一次查询（消除 N+1）、outbox 认领式派发
  （可并发 dispatcher）、迁移默认加锁 + checksum 校验、`StorageKey` 字段↔列名映射、
  `queryTargetsByValue`（UUID 主键也可遍历边）、`BulkInsert` 按参数上限分片、
  参数化原生谓词 `sql.RawArgs`、聚合助手、upsert 自定义表达式、边写入
  （`AddEdgeIDs`/`RemoveEdgeIDs`/`SetEdgeIDs`/`ClearEdge`）。
- **补齐 v0.36 的崩溃恢复语义**：`examples/zent-modulith` 的 dispatcher 每次派发前
  调 `Outbox.requeueStale(..., 300)`，把"认领后派发进程死掉"遗留的 `processing`
  行放回 `pending`（否则这些行永久卡住）。
- 文档同步：`docs/ZENT.md` 版本口径与 §14 兼容表（新增 0.34–0.37 四条升级注意）、
  `AGENTS.md` 已知事实、`examples/zent-modulith/README.md`、
  `examples/{shopdemo-zent,metaverse-creative}/build.zig.zon` 注释。

### Docs
- **最佳实践补全**：`docs/BEST_PRACTICES.md` 新增「生产就绪检查清单」（进程/HTTP/数据并发/
  可观测/验证发布五组，每条都标注承接它的能力）与「数据访问选型（zent / sqlx）」；
  修复目录与正文脱节（补上韧性/背压/预检/kid/迁移恢复/多副本/工具/陷阱/升级/协作等条目）并
  删除一处重复的「模块设计原则」标题残片。
- **`docs/ZENT.md` 新增 §15「v0.34–v0.37 实战用法与边界」**：逐能力给出"什么时候用 /
  什么时候不要用"，含 12 条易踩点（金额聚合用 `AggregateText`、边写入要包 `beginTx`、
  `requeueStale` 阈值须大于最长发布时间、池 `deinit` 静默期、预加载目标不带租户作用域、
  SQLite 表达式 upsert 换实现等）；§14 标题与目录对齐到 0.37。

### Added
- **故障注入测试**（`src/test/FaultInjection.zig`）：走完整 HTTP 链路验证韧性行为，
  而不只是状态机单测 —— 下游挂 → 两次失败后熔断 → **后续请求不再打下游**（断言
  调用计数不增长）→ 恢复窗口后半开探测 → 成功即闭合恢复；限流器 2 令牌后回 429。
- **契约门禁**（`src/test/ContractGate.zig`）：注册接口承诺（状态/响应体片段/头），
  经真实路由 dispatch 后逐条校验，漂移即构建失败；负例验证漂移会被报告而不是
  静默通过。`ContractVerificationResult` 新增 `deinit`（此前所有权无处释放）。
- **真实 PostgreSQL 的锁验证**：`DistributedLock` 的 `.postgres` 方言在 PG 17 上
  实测通过（双 owner 互斥、释放移交、过期回收）；经 `ZIGMODU_TEST_PG=1` 门控，
  CI 的 `test-postgres` job 已带上该变量与 PG 环境变量。
- **迁移失败恢复指引**：`docs/BEST_PRACTICES.md` 新增运维小节，写清 `success=false`
  重试语义、部分生效要求幂等、`ALTER TABLE` 失败被跳过的代价，及现场查询 SQL。
- **CI 夜间 soak job**：`schedule`（每天 03:17 UTC）+ 手动触发，
  `zig build soak -Dsoak-clients=64 -Dsoak-iterations=200`，带 30 分钟超时。
  跨租户泄漏与冻结注册表并发断言终于有了持续运行的场地（默认 push/PR 不跑，
  保持反馈速度）。
- **旗舰示例改用生产配置**：`examples/tenant-mgmt` 从手工拼中间件切到
  `http.productionProfile`（连接背压 + 安全/观测中间件 + `/metrics` +
  `/health/live` + `/health/ready`，删掉自带 health 路由避免重复）。
- **路由标签归一化**：ComptimeRouter 的模式不带前导 `/`，而 server 级路由带 ——
  指标标签统一补 `/`，避免同一接口裂成两条序列。
- **`zigmodu.Preflight`**（`src/core/Preflight.zig`）：启动预检，把"凌晨三点炸"变成
  "拒绝启动"。内置 `envCheck`（缺必填变量）/ `secretCheck`（占位或过短的 JWT
  secret）/ `dbCheck`（SELECT 1）/ `migrationCheck`（有待应用迁移）/
  `clockCheck`（时钟偏移）；`Severity.warn` 只告警，检查之间互不影响，不 panic。
  参考接线见 `examples/zmsaas/backend/src/main.zig`。
- **JWT 密钥轮换（kid）**：`SecurityModule.setKeyring(&JwksKeyRing)` —— 新 token 头部
  带 `kid`，验签按 `kid` 取密钥，旧密钥留在环里即可无缝轮换；未知 `kid` 返回
  `error.UnknownKeyId`（不退化成"用主密钥试一下"）。不设 keyring 时行为不变（无 kid）。
- **CORS 通配符告警**：`productionProfile` 在 `cors_origin = "*"` 时打 warn。
- **受限基数的指标标签**：`PrometheusMetrics.createCounterFamily` /
  `createHistogramFamily`（单标签 + 硬上限，超额统一进 `route="__other__"`）。
  `productionProfile` 的黄金信号全部按 **`ctx.route_template`**（匹配到的模式，
  不是带 id 的原始 path）打标签 —— 终于能回答"哪个接口在慢"。
  新增 `Context.route_template`，在两处分发点（`handleForTest` / connFiber）设置。
- **业务面黄金信号**：
  - `OutboxConsumer.setMetrics(metrics)` → `outbox_selected_total` /
    `outbox_delivered_total` / `outbox_failed_total` / `outbox_pending`；
    `pendingCount()` 查积压，`startPolling(io, interval_ms)` 内置后台轮询
    （取代手工 cron），失败计数 `consecutive_failures`。
  - `PrometheusMetrics.setScrapeHook(hook, userdata)`：**抓取时采样**，无需后台
    线程即可刷新连接池/积压等 gauge。
  - `Client.poolMetrics()`：暴露已有的 `ConnPool.PoolMetrics`
    （active / idle / waiters / 各项计数）。
- **`zigmodu.DistributedLock`**（`src/core/DistributedLock.zig`）：后台任务的跨实例互斥。
  接口 `Lock.tryAcquire(name, ttl_ms)` / `release(name)` + `NoopLock`（默认，保持
  单进程行为）+ `SqlLock(Client)`（表锁，`.sqlite` / `.postgres` 用
  `ON CONFLICT DO NOTHING`、`.mysql` 用 `INSERT IGNORE`，靠 `rows_affected`
  判定抢占，争用不是错误）。持有者崩溃后由 `ttl_ms` 过期回收。表名做标识符校验。
- **cron 跨实例互斥**：`Scheduler.setLock(lock, ttl_ms)` —— N 副本部署时每个 job
  每分钟只在一个副本上执行（`cron:<job>` 为锁名）；未设锁时行为与之前完全一致。
- **迁移跨实例锁**：`MigrationRunner.setLock(lock, ttl_ms)` —— 滚动发布时并发实例
  不会再抢着建历史表/执行 DDL；抢不到锁返回 `error.MigrationLocked`。
- **`http.productionProfile()`**（`src/http/Profiles.zig`，导出
  `zmodu.http.productionProfile` / `ProductionConfig` / `ProductionProfileState`）：
  一行接齐生产配置 —— 连接背压（`max_connections` / `over_limit_response` /
  `header_timeout_ms` / `request_timeout_ms`）、安全与观测中间件
  （CORS + request-id + recover + security headers + tracing + access log）、
  `GET /metrics`、`GET /health/live` + `/health/ready`、可选 dashboard。
  路径可配。**必须在 `router.mountAll` / `addRoute` 之前调用**（`addRoute` 会在
  注册时快照全局中间件链）。
- **黄金信号指标**：`productionProfile` 默认维护 `http_requests_total`、
  `http_responses_{2xx,3xx,4xx,5xx}_total` 与
  `http_request_duration_milliseconds` 直方图（1ms–5s 固定桶）。
- **`docs/OBSERVABILITY.md`** + **`docs/grafana/zigmodu-overview.json`**
  （7 面板）：PromQL 速查、告警阈值起点、Prometheus/K8s 抓取配置、上线自检。
- **生产部署参考** `examples/production-deploy/`：nginx / Envoy TLS 终结 +
  h2c 反代、docker-compose、K8s（探针/HPA/Prometheus 注解）、systemd
  （`Restart=always`）、多阶段 Dockerfile。
- **WebSocket 出站背压**：`Server.Config.ws_write_timeout_ms`（`SO_SNDTIMEO`，
  0 = 旧行为）+ `WsFramer.isWritable()` 水位探测。超时写返回
  `error.WriteTimeout` 并 shutdown 连接，慢客户端不再无限阻塞写线程。
- **`PrometheusMetrics.registerMetricsRoutePath`**：可自定义 metrics 路径。
- **`-Dnet-tests=false`**：沙箱环境跳过全部依赖 loopback 的测试（统一经
  `NetworkProbe.available()` 收口）。
- **`zmodu.NetworkProbe`** 导出。
- **连接级背压与慢连接防护**（`src/api/Server.zig`）：`Config.max_connections`
  （0 = 不限）+ `over_limit_response`（`.close` / `.unavailable` 回 503，走裸
  socket 写以免阻塞 accept 线程）、`Config.header_timeout_ms`（请求行 + header
  阶段总 deadline，超时回 408；header 读完后立即解除，不误杀慢速上传）。支持
  `HTTP_MAX_CONNECTIONS` / `HTTP_HEADER_TIMEOUT_MS` 环境变量。连接计数
  `active_connections` 在 accept 时预留、fiber 退出时释放。
- **并发浸泡测试**：`zig build soak`（`-Dsoak-clients` / `-Dsoak-iterations`）。
  真实 socket 的 N 并发 × M 租户压测，断言跨租户读取为 0、FrozenMap 在并发读 +
  拒写下不撕裂、连接计数回落 0。刻意不挂在 `zig build test` 上。
- **audit b22**：拦截 `.tenant_source = .query`（客户端可篡改的租户来源）。
- **`zmodu.NetworkProbe`** 导出（受限沙箱里 socket 测试的跳过探针）。
- **`FrozenMap` / `FrozenStringMap`**（`src/core/FrozenMap.zig`，导出
  `zmodu.FrozenMap/FrozenStringMap`）：启动期填充、`freeze()` 后只读的
  共享注册表容器。冻结后读无锁、任意并发安全；写返回 `error.Frozen`。
  针对 worker 池上并发 put/resize 撕裂 HashMap 元数据导致读者
  `panic: incorrect alignment` 的崩溃类别。
- **panic 钩子**（`src/api/PanicHook.zig`，导出 `zmodu.panicHook`）：
  Server 在 dispatch 前将当前请求 `METHOD /path` 写入 threadlocal，
  panic 时先输出该上下文（无分配、固定缓冲）再走
  `std.debug.defaultPanic`。应用 root 一行接入：
  `pub const panic = zmodu.panicHook;`。
- **`zmodu audit` 新规则**（`tools/zmodu/src/audit.zig`）：
  b19 请求路径裸 panic（`@panic` / 语句级 `unreachable;`）、
  b20 文件作用域共享可变 HashMap（建议 FrozenMap）、
  b21 请求路径裸 `@alignCast`（豁免 `ctx.user_data` 与
  `@alignCast(self)` 单例注册）。

### Security
- **zent-modulith 示例不再信任客户端租户**：`zent_crud.CrudApi` 的
  `.tenant_source` 由 `.query` 改为 `.attr`，products 五条路由接入
  `jwtAuthFromCatalog`（租户取自 JWT `aud` claim）。此前改一个 URL 参数
  `?tenant_id=` 即可跨租户读取。配套新增 dev-only 取 token 路由
  （`ZENT_DEV_TOKEN=1` 才挂载，明确标注为后门）与 README 更新。

### Fixed
- **CI benchmark job 从未执行**（`.github/workflows/ci.yml`）：`if` 只匹配
  `refs/heads/main`，而默认分支是 `master` → 性能回归门禁（`alert-threshold`
  150%）形同虚设。与其它 job 一致改为 `main || master`。
- **`HealthEndpoint.handleReadiness` 编译错误**（`const details` 却调用
  `components.deinit(*Self)`）——任何调用方都会编译失败，readiness 端点不可用。
- **`Dashboard.registerRoutes` 两处编译错误**：`handleModules` 的 `allocPrint`
  缺参数元组、`get` 需要 `*RouteGroup`。`productionProfile(.dashboard = true)`
  暴露了它们。
- **`config` 模块的 `readToEndAlloc` 失效 API**（`YamlToml` ×2 /
  `ConfigManager` / `TomlLoader`）：Zig 0.17 已移除该方法，`parseFile` /
  `loadJson` / `loadFile` 属于"导出但一用就编译失败"的公开 API，现改用
  `Dir.readFileAlloc`，并补 `YamlParser.parseFile` 端到端测试。
- **Server `stop()` 在 Linux 上唤醒阻塞的 `accept()`**（`src/api/Server.zig`
  `closeListener`）：先 `shutdown(SHUT_RDWR)` 再 close。Linux 下 close 不会
  中断阻塞中的 accept（内核为进行中的调用保持 socket 存活），accept 循环
  永不退出、`join` 死锁——ubuntu CI `Run tests` 曾因此挂起 50 分钟。
- **WS fiber 测试自定义栈 128KB → 2MB**（`src/api/Server.zig`）：glibc
  aarch64 `PTHREAD_STACK_MIN=131072` 恰为 128KB，TLS 无空间导致
  `pthread_create` EINVAL（std 内 unreachable panic）。
- **示例内存泄漏（audit b17）**：tenant-mgmt `getById` 结果在
  updateTier/suspendTenant/getTenant 三处从未释放；updateTier 混用静态
  字符串破坏 owned 语义（统一改为 dupe + defer freeTenant）。
  tenant-shop `Tx.priceCents` 改用 `freeScanned`。

### CI
- **CI 全链路修复并首次全绿**：job 级 `if` 误用 `env` 上下文导致工作流
  历史上从未调度（0s 失败）；mlugg/setup-zig 旧式 URL 404（改为直接从
  ziglang.org 下载 arch-first tarball，Zig pin 升至 0.17.0-dev.1970）；
  ubuntu 缺 `libmariadb-dev-compat`（`libmysqlclient.so` 由该包提供）；
  示例路径 `zfsaas`→`zmsaas` 改名未同步；integration / mysql /
  live-service 三个 job 失败时上传日志 artifact 便于诊断。

## [0.15.35] - 2026-09-03

### Security
- **`validateSqlFragment` 黑名单加固**（`src/sqlx/sqlx.zig`）：新增拒绝反引号
  （MySQL 标识符引用）、`#` 注释、`*/` 闭合注释，以及整词匹配（大小写不敏感）
  的语句关键字 `UNION` / `SELECT` / `INSERT` / `UPDATE` / `DELETE` / `DROP` /
  `ALTER` / `CREATE` / `ATTACH` / `DETACH` / `PRAGMA` / `EXEC` / `EXECUTE` /
  `TRUNCATE` / `GRANT` / `REVOKE` / `REPLACE`。标识符内子串（如
  `updated_at`、`selection`）不误伤；`IN (?, ?)` 等括号谓词不受影响。
  值仍必须走 `?` 占位符——此为纵深防御而非主防线。
- **JWT 空 `aud` 不再写入 `tenant_id` attr**（`src/api/Middleware.zig`）：
  原先空串 attr 会遮蔽 `X-Tenant-ID` 回退路径并让下游 int 解析失败；
  现在 `aud` 为空时 attr 缺省（`ctx.tenantId()` 返回 null）。

### Changed
- **EventBus 线程安全语义澄清**（`src/core/EventBus.zig`）：文件头原注释自称
  "Thread-safe" 与事实相反，已修正；`EventBus` / `TypedEventBus` /
  `UnifiedEventBus` 均显式标注 NOT thread-safe，并发场景指向
  `ThreadSafeEventBus`。`ThreadSafeEventBus` 新增 `publishedCount()`。
- **`CrudService.setEventBus` 改收 `*ThreadSafeEventBus`**（`src/data/CrudService.zig`）：
  CRUD 事件在 HTTP handler 线程发布，原 `*TypedEventBus` 无同步保护。
  zmodu 代码模板（`service_header.zig.tpl`、smoke 脚手架、`saas` 生成器）
  同步默认生成 `ThreadSafeEventBus`。
- **`tenant-mgmt` 示例落地真实租户隔离**：租户中间件从空壳改为
  JWT `aud` 优先、`X-Tenant-ID` 头回退（dev 路径）、两者冲突 403；
  user/subscription handler 改经 `requireTenantId(ctx)` 读 attr，
  不再信任 `?tenant_id=` query；`GET /subscriptions/{tenant_id}` 校验路径
  租户与上下文一致，跨租户 403。中间件顺序修正为 JWT → tenant。
  `ci-integration.sh` 新增三条租户隔离探针（401/200/403）。
- **`check-production.sh` 门禁覆盖全文**：`Server.zig` / `sqlx.zig` 的硬编码
  行号截断（1700/2739）改为与其它热路径一致的动态截断（首个 `test "` 行），
  消除后半文件不受约束的盲区；扩扫后当前零违规。
- **README**：`DistributedEventBus` / `SagaOrchestrator`（及 zh 版
  ClusterMembership & Raft）补 ⚠️ experimental 标注；`examples/README.md`
  移除四个不存在的幽灵示例章节（dependency-injection / architecture /
  v2-showcase / ecommerce）并同步学习路径与统计表。
- `gen-jwt-token` 支持 `JWT_AUD`（生成带 `aud` 的 token，供租户探针使用）。
- **EventBus / DI 接入 Application**（闭环"主推抽象未接线"）：新增
  `core/EventRegistry.zig`（按 `@typeName(T)` 类型擦除的 get-or-create
  注册表，只发放 `ThreadSafeEventBus`）与 `core/ModuleContext.zig`
  （`allocator`/`io`/`events`/`services`）。模块可选声明
  `pub fn initWith(ctx: *ModuleContext) !void`——`ModuleScanner` 编译期
  探测（`@hasDecl`）、`Lifecycle.startAllWith` 优先调用（与 `init` 并存时
  只调 `initWith`；仅 `initWith` 而无 ctx 时启动失败并回滚）。
  `Application` 持有 `events` + `services`，`start()` 完成后
  `services.freeze()`（之后 `get` 为无锁只读、注册报 `ContainerFrozen`）；
  新增 `app.eventBus(T)` / `app.service(T, name)` 与
  `Builder.withService(T, name, ptr)`（借用注册，容器不销毁实例）。
  `di.Container` 新增 `registerBorrowed`（修复栈指针注册被 deinit 销毁的
  所有权陷阱）。shopdemo 成为首个真实使用者：order 服务经
  `app.eventBus(OrderEvent)` 接线并在 create 时发布事件。最佳实践文档：
  `docs/EVENTS_DI.md`（MODULITH.md §2.3/§4 与 AGENTS.md 文档地图已交叉引用）。

### Changed
- **zent 适配 v0.32.3**（sqlite 连接访问串行化修复，公共 API 无签名变化）：
  `examples/zent-modulith` pin 升至 `v0.32.3` tag；`docs/ZENT.md`
  版本口径与远程 zon 样例同步，§14 新增升级条目（`Rows` 持锁至
  `deinit()`、遍历完立即释放）；`AGENTS.md` / 示例 zon 注释同步。
  `examples/metaverse-creative` 修复 libpq 链接：`src/db.zig` 引用
  `zent.sql_postgres`，而 zent 在检测到 libpq 头文件时接入 `pg_c` 却
  不链库本体——`_shared/db_link.zig` 新增 `linkDetected()`（检测到才
  链接），示例 build.zig 经它为 `zent_mod` 链接 pq。
  `examples/zent-modulith/README.md` 的 products 载荷补必填的
  `price`（Decimal 列）字段。
- **zent 适配 v0.33.0**（`UseInterceptor` 覆盖 Create/BulkInsert——create
  上 `whereEq` 语义为"缺省才填"，显式值保留）：`examples/zent-modulith`
  pin 升至 `v0.33.0` tag，并落地真实拦截器演示路由
  `GET/POST /api/v1/tenant-injection`（`features_demo.InterceptorApi`）：
  独立 client + 哨兵租户 777，create 缺省填充、查询透明限定，验证
  v0.33.0 写路径拦截在消费端生效（此前头注释宣称该演示但实际未实现）。
  `docs/ZENT.md` §14 新增升级条目（**存量拦截器升级后会开始影响写入，
  需先审计**）；README 补对应章节。⚠️ 排障记录：Zig 0.17-dev 增量缓存
  对 path/fetch 依赖的模块变更可能不失效——升级依赖后行为未变时先删
  示例的 `.zig-cache` 再重建（本次实测：symbol 探针证明二进制里是旧版
  zent，清缓存后一次性通过）。

### Removed
- **`persistence/Database.zig` 的 stub `Repository(T)`**：纯空壳
  （所有方法 no-op）且无任何租户变体，与 `Orm.zig` 的 `Repository(T)`
  同名并存易误用。零调用点，直接删除。规范入口仍是 `data.Repository(T)`。
- **`TenantContext.getDefault()`**：返回非原子可变全局指针、标注
  "non-concurrent use" 且零调用点，属待触发隐患。新增
  `TenantContext.fromAttr(?[]const u8) ?TenantContext` 桥接 HTTP attr
  通路与 TenantContext 类型（attr 缺失/非法/非正数 → null）。

## [0.15.34] - 2026-08-31

### Changed
- **zent 升级 v0.32.1 → v0.32.2**（纯修复，零 breaking）：v0.32.2 修复连接池
  use-after-free（`swapRemove` 移动尾元素导致借出指针被污染，空闲驱逐后
  health-check 段错误）、MySQL 非整数主键 upsert（字符串/UUID PK 回退
  `VALUES(pk)` 而非 `LAST_INSERT_ID`）、多线程池测试改用线程安全 allocator。
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.2`（hash
  `zent-0.32.2-oiur-xP7DwCyv9mm_lt74G6jR5qmlJYBW6hGBJ3bkXUv`），文档版本口径同步。

## [0.15.33] - 2026-08-31

### Fixed
- **accept 循环被 keep-alive 连接卡死（服务器整体停止 accept 的挂死）**：
  `Server.start` 原先用 `conn_group.async` 派发 connFiber。`std.Io.Threaded`
  的 `groupAsync` 在 `busy_count >= async_limit`（默认 cpu_count-1）时回退为
  `groupAsyncEager`——在 accept 线程上同步执行 connFiber。connFiber 是
  keep-alive 读循环，客户端挂机不发下一请求时永久阻塞在 `readv`，accept
  循环从此被占死、对所有新连接静默。修复：改用 `conn_group.concurrent`
  （默认 `concurrent_limit = .unlimited`，**不会 eager 回退**，超限时返回
  错误而非劫持调用线程）；超限时拒绝该连接并继续 accept。同类隐患一并修复：
  `WebSocket.zig` / `DistributedEventBus.zig` 的 accept 循环派发
  handleConnection 同样由 `async` 改为 `concurrent`。

### Changed
- **zent 升级 v0.32.0 → v0.32.1**（纯新增 + CI 修复，零 breaking）：v0.32.1
  新增 interceptor 多租户查询改写示例与 eager/upsert 基准，并修复四个既有
  CI 失败；已 pin zigmodu v0.15.32 并移除其 libc 补丁。`examples/zent-modulith`
  zon 锁定 `git+https#v0.32.1`（hash `zent-0.32.1-oiur-3jiDwAri-…`），
  文档版本口径同步 v0.32.1。

## [0.15.32] - 2026-08-27

### Added
- **sqlx 读写分离（read/write splitting）**：`Client.withReplica(&replica)`
  注册只读副本——`query`/`queryCursor` 及其派生（queryRow/queryRows/
  findOne 等）路由到副本，`exec`/`beginTx`/batch 写入恒走主库；副本读失败
  自动回退主库（降级为单主模式而非报错），副本自身的熔断器打开时直接用
  主库。附路由正确性与故障回退两组回归测试。
- **HTTP header 数量/总字节上限（header 炸弹 DoS 防护）**：
  `Server.Config.header_limits`（默认 100 个 header / 16KB 总量），超限返回
  `error.TooManyHeaders` → HTTP 431。此前 body 有 `max_body_size` 但 header
  无上限，攻击者可发大量合法小 header 耗尽请求 arena。

### Fixed
- **`zmodu` CLI 缺 `link_libc`**：`build.zig` 里 zmodu 模块未设
  `link_libc = true`，Zig 0.17-dev.813 起 `@cImport` 不再隐式链接 libc，
  依赖方（如 zent CI）需打补丁兜底。现已与框架主模块一致显式链接。
- **Cron scheduler `deinit` 潜在 UB**：mutex lock 失败被吞后继续 unlock
  （futex 后端下 unlock 未锁住的 mutex 是未定义行为）——现在 lock 失败时
  记录错误并跳过配对 unlock 与任务清理。
- WebSocket：pong 发送失败静默吞噬 → debug 日志（对端会由下次心跳暴露）；
  升级拒绝路径补 best-effort 注释。HttpClient 连接池回收路径同注释化。
- **`ComptimeRouter.wrapHandler` 双重缺陷**：`handler` 改为 comptime 参数并移除
  共享的容器级 `var Store`——旧实现里同一 `State` 的所有 wrapper 共享一个
  `Store.fn_ptr`（后写覆盖），`openApiRoutes` 的 `openapi.json`/`docs`/`scalar`
  三条路由会串台到最后注册的 handler；且在 `pub const routes` 等 comptime
  上下文中触发 `unable to evaluate comptime expression`。
  `openApiFromCatalog` 的运行时状态同步提升为容器级 `OpenApiRouteStore`
  （单 catalog 契约已注释声明），公共 API 签名不变。新增独立派发回归测试。
- **`zmodu orm --backend zent` 外键解析两处 bug**：表级
  `FOREIGN KEY (col) REFERENCES …` 的列名被截成 `col)`（右括号未剥）并再次被
  内联扫描重复抓取；内联 `col TYPE NOT NULL REFERENCES …` 回溯只吃一个类型词、
  把修饰词误当列名。修复：第二遍跳过 `)` 结尾的表级引用，回溯改为抓到行首/
  逗号后按「修饰词剥离 + 类型词丢弃」取列名。**同时新增外键 → edge 声明生成**
  （`edge.From("<name>", Ref).Field("col")`），两种 FK 书写形式均验证通过。

### Changed
- **OTLP / Vault 支持 HTTPS**（此前文档口径「待 stdlib」实际是滞后）：
  `OtlpExporter.exportSpans` 与 `SecretsManager.loadFromVault` 复用
  HttpClient 的 `std.http.Client` TLS 1.3 通道（系统 CA 信任库），
  移除 `OtlpTlsNotSupported` / `VaultTlsNotSupported` 短路；https 端点
  现在直达，证书链需入系统信任库。AGENTS 文档口径同步。
- **WebSocket 显式 `max_frame_size`**：`WebSocketServer.max_frame_size`
  （默认 4096）+ `setMaxFrameSize`，帧读取 buffer 按该值动态分配，替换原先
  隐含在 4KB 栈缓冲里的硬上限。
- **zent 升级 v0.29.8 → v0.32.0**（纯新增版本，零 breaking 验证）：
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.0`
  （hash `zent-0.32.0-oiur-4vYDwDyEvLh_lnPwxRmJdXAc5920URMil2NQatJ`），
  `examples/shopdemo-zent` 按本地 sibling v0.32.0 构建通过；新增能力可用：
  `SaveOrUpdateOn`/`SaveIgnore` upsert、`Row.tryGet*`、`field.Decimal`（精确
  金额列）、`WithEdgeOptions` inner-join eager loading、`beginTxFromDriver`、
  `managedEntity`/`dupeEntityTo` allocator 安全 teardown、v0.32 Interceptor
  运行时查询拦截、PreparedCache 字节级 key 比对（hash 碰撞修复）。
- **`zmodu orm --backend zent` 模板修复**（生成代码此前无法编译）：
  `client.zig` 返回类型改为泛型实例化 `zent.codegen.client.Client(infos)` 并
  导出 `pub const infos/Client`；schema 体改 `pub const` 并由 client 经
  `schemas.*` 引用；移除 zent 已不存在的 `.Required()` 链式调用（字段默认
  NOT NULL，nullable 列才 `.Optional()`）；`.Default` 按列类型发零值字面量
  （Int→`0`，旧 `""` 在 PG 上是非法 DDL）；zent 版 `module.zig` barrel 改为
  导出实际生成的 `schema`/`client`。生成结果已对 zent v0.32.0 实测编译通过。

### Documentation
- **`docs/ZENT.md` 升级为电商/社交主推组合指南**（版本口径 v0.32.0）：顶部新增
  主推定位；§2 决策表电商/社交默认 zent；新增 §4.8「电商 / 社交主推能力矩阵
  （v0.30–v0.32）」（`field.Decimal` 精确金额、`SaveOrUpdateOn`/`SaveIgnore`
  业务键幂等、`WithEdgeOptions(.inner)` 防 limit skew、`beginTxFromDriver`
  池上事务、`ManagedEntity`/`dupeEntityTo` 请求级 arena、`SelectExpr` 聚合
  DTO、`Row.tryGet*` NULL 安全）；§14 升级表补 v0.28–v0.31（含 ⚠️ v0.29
  `field.Time` 全方言改 BIGINT epoch 的 PG 存量表迁移提醒）。README /
  README.zh / docs/README / AGENTS 文档地图同步主推标注。
- `examples/zent-modulith` 新增 v0.30–v0.32 能力演示端点：`PUT /api/v1/sku-stock`
  （业务键 upsert + Decimal）、`GET /api/v1/feed2/authors-with-posts`
  （inner-join eager load + arena 深拷贝），并已在文档中注明 Interceptor
  接入位置。
- **文档基线校准**：`AGENTS.md` 测试计数 820→990/1009（19 skipped）、
  `docs/EVALUATION_REPORT.md` 与 `docs/PRODUCTION_ROADMAP.md` 版本口径/结论
  统一到 v0.15.32；`scripts/release.sh` 版本校验与 bump 范围扩到这两个
  长期被漏掉的文件。

## [0.15.31] - 2026-08-26

### Added
- **可插拔 AuthBackend + catalog 唯一 bypass 真相**（ISSUES_FROM_ZAPI M1/M3）：
  `http.authFromCatalog(&slot, backend, .{})` 包住任意 `AuthBackend`
  （`verifyFn(ctx) → ?Identity`），仅 `RouteMeta.auth == .public` 跳过验签；
  内置 `http.jwtBackend(&sec)` / `http.jwtBackendWithPermissions(&sec, loader)`
  （≡ `jwtAuthFromCatalogWithPermissions`）。消费端可删除并行 `public_paths` 清单。
- **认证拒绝信封钩子**（M4）：`JwtFromCatalogConfig.reject` /
  `PermissionGateConfig.reject` / `AuthFromCatalogConfig.reject` 接受
  `AuthRejectFn`；`http.envelopeReject(.thinkphp)` 让 401 产出
  `{code:-1,msg,data:null}`，无需 fork 中间件。
- **类型化身份与属性读取**（M5/M11）：`ctx.setIdentity` / `ctx.identity()` /
  `ctx.userId()` / `ctx.userIdInt(T)` / `ctx.requireUserId()` /
  `ctx.requireUserIdInt(T)` / `ctx.tenantId()` / `ctx.rolesCsv()`，及
  `ctx.getAttrInt(T, key)` / `ctx.getAttrEnum(E, key)`。
- **响应信封方言**（M6）：`http.EnvelopeDialect`（`.default` / `.thinkphp` /
  `.ruoyi`）+ `ctx.setEnvelope` + `ctx.ok` / `ctx.okValue` / `ctx.fail` /
  `ctx.failCode` / `ctx.unauth` / `ctx.paginated`（RuoYi 分页为
  `{code,msg,rows,total}`；msg 一律 JSON 转义）。
- **租户解析中间件**（M7）：`http.tenantResolver(.{ .require = … })` 按
  `AppID`/`appid`/`X-Tenant-Id` 头或 `app_id` query 写 `tenant_id` attr；
  JWT `aud` 已存在时默认优先（可 `override_existing`）。
- **路由级门户 roles**（M8）：`RouteMeta.roles = "admin|ops"`（`|` = OR），
  `permissionGateWith` 在细粒度 permission 之前按身份 roles 拦截；catalog
  新增 `rolesFor`。
- **Token 提取器**（M12）：`http.TokenSource` + `extractBearer` /
  `extractHeaderToken` / `extractQueryToken` / `extractFormToken` /
  `extractTokenAny`（Bearer / X-Token / query / form）。
- **meta ↔ runtime 认证审计**（M2）：`http.Testkit.auditAuthCoverage(alloc,
  &server, &slot)` 无凭证分发全部 catalog 路由，返回漂移清单（`{param}` 段
  以 `1` 分发；WS/SSE 跳过）；空切片 = 通过，可接入 CI。
- **OpenAPI securitySchemes**（M14）：`OpenApiGenerator.bearer_auth` +
  `ApiEndpoint.requires_auth`；catalog 导出自动标注非 public 路由
  `security: [{bearerAuth: []}]`，并生成
  `components.securitySchemes.bearerAuth`（http/bearer/JWT）。
  `OpenApiFromCatalogConfig.bearer_auth` 默认开启。

### Documentation
- `docs/ROUTE_TABLE.md` 新增 §7.2（AuthBackend / 身份 / 信封）与
  §7.3（Resilience profiles 接线，M9）。
- `docs/ISSUES_FROM_ZAPI.md` 状态更新：M1–M9、M11、M12、M14 landed；
  M10 deferred（dispatch 层改动大，M6 已覆盖主要诉求）、M13 declined（审美性）。

### Fixed
- **HttpMetricsCollector.generateReport 自死锁**：持锁（非递归自旋锁）期间调用
  会再次加锁的公开方法 `avgDuration()`，`tryLock` 失败导致 100% CPU 永久自旋
  （也是 `zig build test` 卡 853/929 的根因——该死锁长期掩盖了后续测试的真实
  结果）。改为持锁内联计算均值。
- **bindJsonLoose / extractJsonLoose 丢字段默认值**：原实现用
  `std.mem.zeroes(T)` 初始化，`"id": null` 或缺字段时声明的默认值（如
  `id: ?i64 = 7`）被抹成零值。改为两段式：先填匹配字段，再给未匹配字段
  回填**声明默认值**（切片默认值同样 deep-copy，返回值所有字段统一自有，
  可一致释放）。同步修复相关测试的字符串泄漏。

## [0.15.30] - 2026-08-17

### Fixed
- **SQLx pgDecodeNumeric base-10000 boundary**: PG stores numeric values in a compressed form that strips trailing zero base-10000 groups. For numbers like `100000` (= 10 * 10000^1), PG may send `ndigits=1, weight=1, digits=[10]` instead of `ndigits=2, weight=1, digits=[10, 0]`. The previous code only handled the non-stripped form correctly, mis-decoding stripped values (e.g. `100000 → '10'`). The integer-part writer now pads with the missing high-order zeros when `int_out < int_chars`, so both stripped and non-stripped encodings produce the same decimal string. No migration needed: DB data is unchanged.

## [0.15.29] - 2026-08-17

### Fixed
- **SQLx arena ownership clarity**: `QueryResult` (sqlx.zig) now documents the arena contract explicitly and exposes a new `deinitArena()` method that takes no allocator. The arena path of `deinit(allocator)` ignores the `allocator` argument and uses the arena's own backing allocator (captured at scan time). When callers mix allocator identities and pass a different allocator than the one backing the arena, `ReleaseSafe`'s `SafeAllocator` rejects the free; `deinitArena()` makes the intent explicit and removes the ambiguity that produced the heysen `len: 7` panic in nested-allocator chains.

## [0.15.28] - 2026-08-15

### Added
- **分布式限流**：`data.redis_rate_limit.RateLimiter` —— Redis INCR + 首次
  EXPIRE 固定窗口（跨实例共享），fail-closed（Redis 不可用 → error，不静默
  放行）。`max=0` 立即拒绝。
- **跨实例 WS fanout 接线文档**：`DistributedEventBus` 订阅 → 本地
  `WebSocketServer.broadcast`（任意实例 publish → 全集群广播），无需新组件。

## [0.15.27] - 2026-08-14

### Added
- **Repository INSERT 回填自增 id**：`insert` / `insertOmitNulls` 现在把
  DB 生成的 `last_insert_id`（SQLite/MySQL）或 Postgres `SELECT lastval()`
  写回 `entity.id`（上游 PR：heysen_saas `orm-insert-id` 补丁合并，含
  `@hasDecl(B, "dialect")` 守卫与更完整的 `insert` 覆盖）。
- **对称 rows_affected 守卫**：`deleteByIdReturning(id) !u64` 与
  `updateReturning(entity) !u64`——0 表示记录不存在（乐观锁/NotFound 守卫），
  对齐既有 `deleteForTenant`/`updateForTenant`。

## [0.15.26] - 2026-08-14

### Added
- **宽松 JSON 绑定**（camelCase 拒收 + id:null 两个 bug 的框架侧根治）：
  - `Context.bindJsonLoose(T)` — 字段名 snake_case↔camelCase 双向匹配
    （`user_name` ↔ `userName`），`null` 视为缺失（零值默认），缺字段不报
    MissingField。
  - `http.extractJsonLoose(ctx, T)` — 同语义的 canonical extractor。
  - 默认 `bindJson`/`extractJson` 保持严格语义不变；存量 handler 只需把
    方法名换成 Loose 变体（sed 即可）。

## [0.15.25] - 2026-08-13

### Added
- **Repository opt-in 部分写入**（方案 C）：
  - `insertOmitNulls(allocator, entity)` — nullable 且为 null 的列省略，
    让 DB `DEFAULT` 接管（默认 `insert` 仍写显式 NULL 全量覆盖）。
  - `updatePartial(allocator, entity)` — 只 SET 非 null 字段（null 保持
    原值），pk 恒用于 WHERE。
  - 文档：`docs/ZENT.md` §5.1 对照 zent（builder 模式天然规避此问题）。

## [0.15.24] - 2026-08-13

### Added
- **migration barrel 导出（F2）**: `zigmodu.migration` 全量导出
  MigrationRunner/Entry/Applied/Status/Loader——业务侧可弃用自研 migrate.sh。

### Fixed
- **zmodu CLI Windows 交叉编译 3 处修复**: `wallClockSeconds` 用
  `RtlGetSystemTimePrecise`（原 `GetSystemTimeAsFileTime` 已从 std 移除）；
  `std.c.getenv` → `init.environ_map`（避免 libc 依赖）；args 迭代
  `iterate()` → `iterateAllocator`（Windows UTF-16 需 allocator）+ deinit。

### Changed
- **CI**: 新增 `windows-cross` job（`-Ddb=none -Dtarget=x86_64-windows`
  守护 Windows 分支）；push/pull_request branches 补 `master`（默认分支）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.8**（benchmark canary
  + outbox/shard/mysql-driver 测试补强 + docs 治理）。

## [0.15.23] - 2026-08-11

### Added
- **Swagger UI / Scalar UI 路由**：`swaggerUiHandler` / `scalarUiHandler` /
  `openApiRoutes` / `wrapHandler`（ComptimeRouter + `http.zig` 导出）——OpenAPI
  文档可直接在浏览器渲染。
- **`Context.html(status, data)`**：HTML 响应助手（自动 `text/html; charset=utf-8`）。

### Changed
- **HTTP/2 增强**：Hpack / Http2Server / HttpClient 迭代（含客户端路径调整）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.5**（`git+https#v0.29.5`，
  hash `zent-0.29.5-oiur-70vDgA9kXdpRrJUN1MRmz721OldWiTrrOJKSNF6`，ORM 迭代与
  适配更新）。

## [0.15.22] - 2026-08-10

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.4**（pool UAF 修复——
  Rows 持有连接至 deinit；Sum f64；From edge FK 去重；codegen quota 1M）。

### Fixed
- **AccessLogger 线程安全**：全局中间件被所有连接线程共享，并发 `log()`
  append 同一 ArrayList 触发数据竞争 → SafeAllocator panic → 服务崩溃
  （并发 ≥10 即现）——已加锁。
- **HttpMetrics 线程安全**：`HttpMetricsCollector` 加自旋锁
  （beginRequest/endRequest/recordRequest/snapshot）；`metricsMiddleware`
  改用守卫的 begin/endRequest（原先裸改 `in_flight`）。
- **libpq 同步查询永久挂死**（Threaded Io）：`SO_RCVTIMEO` socket 读超时
  （`Config.query_timeout_ms`，默认 30s）+ `connect_timeout=10`——同步
  `PQexec*` 挂起不再永久卡死 fiber；超时后连接由池 ping / 重连回收。
- **ConnPool 等待不可中断**：acquire 池满等待改 50ms 分段 futex——响应
  fiber 取消与池关闭；slice 超时继续等待至 `max_wait_ms`（语义不变）。

## [0.15.21] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.3**（bool scan / WhereIn
  Zig 0.17 / defaultValueStr quota 修复）；改用 `git+https#v0.29.3` tag 依赖
  （tarball archive hash 不稳定，git tag 内容哈希稳定且锚定更规范）。

## [0.15.20] - 2026-08-07

### Added
- **Outbox 拆分出口治理**（对齐 Spring Modulith 决策记录）：
  - `OutboxPublisher.buildResubmit(policy)` 显式重发 API——failed/DLQ 条目按
    `max_attempts` / `older_than_seconds` / `tenant_id` 策略回 pending 重投
    （对齐 `FailedEventPublications.resubmit()` + Staleness Monitor）。
  - `OutboxPublisher.externalize(...)` 事件契约映射层——内部 topic →
    对外稳定契约 + `{"event","data"}` 信封（对齐 `@Externalized`）。
- **audit b17**：`collectModelStructs` 收集缩进局部 `const X = struct` 与
  单行 struct——函数内局部标量行类型误报消除（22 处边界收口）。

### Changed
- **docs**：EVALUATION_REPORT v5.8（Agent 流式化/tools_json/Metrics 原子化等
  实分重估）；BEST_PRACTICES 新增「Threaded Io 下同步阻塞」契约；
  PRODUCTION_ROADMAP 新增 gRPC「一等公民≠近期投入」与「拆分出口=事件契约+
  outbox」两条决策记录。

## [0.15.19] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖从本地 sibling path 改为固定 git
  tarball **zent v0.29.2**（含 migrate 生成 quota 运行时化修复）。
  `.gitignore` 忽略 zig 0.17 的 `zig-pkg/` 包缓存目录。

## [0.15.18] - 2026-08-07

### Fixed
- **tools_json 非法 JSON**: `SkillRegistry.toOpenAiFunctionsAlloc` 每个工具
  多输出一个 `}`（`appendSlice` 字面 `]}}}}` vs `print` 的 `{{` 转义混用），
  导致 DeepSeek/OpenAI 对工具定义报 400 → ProviderError。已改为 `]}}}`，
  并给生成器测试补 `std.json.parse` 合法性断言防回归。

## [0.15.17] - 2026-08-07

### Added
- **Metrics 快照读取**: `AiProvider.Metrics.toStats()` 与
  `AgentMetrics.toStats()` 返回普通字段快照——外部读取/日志不再逐字段
  `.load(.monotonic)`，也避免 `{d}` 直接传 `atomic.Value` 的编译错误。

## [0.15.16] - 2026-08-06

### Fixed
- **HttpClient.requestStream 本地 HTTP 挂起（根治）**: `executeRequestStream`
  写请求后漏 `flush`（请求停在缓冲、与 server 死锁）；流式读取改
  `waitForReadable + posix.read`（同步调用链兼容）。此前本地 HTTP mock
  全挂（真实 HTTPS 因走 std.http.Client 正常）——现本地 SSE mock 可用。

### Added
- **Agent 流式正式落地（TODO #4）**: `Agent.run` 主循环切换到
  `chatStream + DeltaBridge`——`AgentHooks.on_delta` 真实触发（旁路推送
  content/reasoning delta，内部仍聚合完整响应供 ReAct 决策）。Agent mock
  测试全部改为 SSE 响应并恢复通过。

## [0.15.15] - 2026-08-06

### Added
- **CircuitBreaker 上下文感知调用**: `callWithContext(ctx, operation)` —
  熔断有状态调用（如 `*AiProvider`），补上"函数指针无法捕获调用方状态"
  的缺口；`call` 保持兼容。含上下文透传/失败/trip 测试。

## [0.15.14] - 2026-08-06

### Added
- **JWT 凭据版本（服务端会话吊销）**: `JwtPayload.ver` claim +
  `generateTokenWithTenantAndVersion`（`generateTokenWithTenant` 委派
  ver=0 兼容）。应用侧可 `payload.ver != users.token_version` 判定吊销
  （踢人）。修复 `verifyToken` 重建 payload 时漏拷 `ver` 的隐藏 bug；
  含 ver 往返测试。

## [0.15.13] - 2026-08-06

### Changed
- **Agent 流式切换验证记录**: `Agent.run` 的 chatStream 切换已用真实 DeepSeek
  API 验证（content delta 旁路推送 + done + 聚合一致）；因框架 mock 基建
  无法驱动 requestStream（本地 HTTP 挂起，Content-Length/chunked 均复现，
  真实 HTTPS 正常——已记录为 requestStream 本地路径 bug 候选），切换保留
  TODO 待 SSE mock harness 或修复后落地。

## [0.15.12] - 2026-08-06

### Added
- **Metrics 原子化**: `AiProvider.Metrics` 与 `AgentMetrics` 全字段改
  `std.atomic.Value(usize)`（threaded io 多 fiber 并发计数不再丢更新）。
- **audit b18 伪事务拦截**: `beginTx()` 后同函数仍用池连接 `client/backend
  exec` 静态报错——事务内读写必须走 tx 句柄（`tx.exec`/`execTx`），否则
  rollback 无效（自动提交）。
- **`RateLimiterRegistry` barrel 导出**（此前漏导出）。

### Changed
- **Lifecycle 文档统一**: QUICK-START/API.md 主 API 改为
  `Application.start/stop`，`startAll/stopAll` 标注为底层 Lifecycle。

## [0.15.11] - 2026-08-06

### Fixed
- **Time.zig**: Windows 时钟改用 `ntdll.RtlQueryPerformanceCounter`（本版 std 已移除 `std.os.windows.QueryPerformanceCounter`）。
- **README 版本漂移**: release.sh 的 perl bump 静默失配导致 README 停在 v0.15.4；补版本引用一致性校验（release.sh + check-release-tag.sh）。
- **静默吞错补日志**: provider JSON 降级 / Agent 工具参数 / Workflow WAL 坏条目。
- **Migration**: `run()` 重复 version 现 fail-fast（`error.DuplicateVersion`）；`loadHistory` 改为 DB 权威快照（修 markApplied+run 双算）。

### Added
- **中间件多实例隔离**: cors/jwtAuth/jwtAuthFromCatalog*/moduleGate/rateLimitPerClient 配置改存 `user_data`（page_allocator 一次性分配），同进程多 Server 不再互相覆盖。
- **`Transaction.queryRowPartial`**（事务内缺失列置零）；**`RouteCatalog.allPermissions()`**（菜单↔路由权限比对）。
- **Migration `markApplied(version)`**（bootstrap 旧库，不执行 SQL）。
- **audit 行级豁免**（`// audit: ignore` / `// audit: ignore b13`）与 **b3 精确化**（空字符串字面量不误报注入）。
- **`AgentHooks.on_delta`** + `chatStream` model 透出 + run_audit `model` 列（AgentResult.model 联动）。
- **事务范式文档**（BEST_PRACTICES.md：伪事务警示 + transact/三件套两种范式）。

### Changed
- **examples/zent-modulith**: 适配 zent v0.29.1（实体序列化改 `toMaskedJson`，跳过 json_arena/Allocator 注入字段）。

## [0.15.10] - 2026-08-05

### Fixed
- **StructuredLogger**: struct-field keys（comptime 字面量）入 map 前 dupe，消除
  释放只读内存导致的 ABRT。
- **ForTenant × camelCase**: 租户字段检查按模型 camel_case 推导（新增
  `snakeToCamel`），`findPageForTenant` 等在 camelCase 模型上可用。
- **Migration 切分**: 替换裸 `;` 切分为状态机（引号/注释/美元引号感知），
  支持含 PL/pgSQL 函数、触发器、DO 块的迁移脚本。

### Added
- **Repository ForTenant 全方法集**: `findByIdForTenant` / `findAllForTenant` /
  `updateForTenant` / `deleteForTenant`（rows-affected 守卫：跨租户操作返回
  0 行，`== 0 → NotFound` 模式可用）；`Tx(B)` 提供事务内
  `deleteForTenant` / `updateForTenant`。
- **软删读过滤**: 模型含 `deleted` 字段时所有读方法（含 ForTenant 变体）自动
  追加 `AND deleted = 0`；无该字段的模型零影响。
- **自动时间戳（opt-in）**: 模型声明 `sql_auto_timestamps = true` 时 insert
  自动填 `create_time`/`update_time`、update 刷新 `update_time`。
- **SqlxBackend borrowed 透传 + queryScalar**: `queryRowBorrowed` /
  `queryRowPartialBorrowed` / `queryScalar`（字符串类型编译期拒绝、自动释放）；
  `typeHasStrings(T)` / `QueryResult(T).has_strings` 编译期元数据。
- **Outbox 方言化**: `migrationSqlWithDialect`（mysql/postgres/sqlite）。
- **PermissionGate `deny_by_default`**: 未标注 permission 的路由可配置 403。
- **audit b10**: 豁免 best-effort `sendError`（SSE 断连等）。

## [0.15.9] - 2026-08-05

### Added
- **AiProvider reasoning_content 支持**: `ChatResponse` 新增
  `reasoning_content` 字段（推理模型如 DeepSeek-R1 的思维链），非流式
  `message.reasoning_content` 与流式 `delta.reasoning_content` 均解析；
  `StreamDelta` 新增 `reasoning_delta`，`chatStream`/buffered fallback
  透出；`freeResponse` 同步释放。已用真实 deepseek-reasoner 集成验证。

## [0.15.8] - 2026-08-05

### Changed
- **AI 开发文档完善**: 新增 `docs/AI_DEV_GUIDE.md`（业务接入全链路：KeyManager →
  Provider → 自定义 Skill → Agent/Workflow → HTTP/cron/outbox/MCP 接线、
  技能所有权/权限/超时规范、安全清单、观测调试）；`docs/README.md` 索引补全
  AI 编排/技能/LLM 策略/MCP 文档；AGENTS.md 文档地图加「AI 业务接入」入口；
  AI.md 顶部指向新指南；AI_SKILLS.md 补「开发自定义技能」指引。
- **queryRow 系字符串所有权契约落地**: `queryRow` / `queryRowPartial` 文档
  明确返回 **owned** 字符串（dupe 进 client allocator，row arena 返回前已释放；
  调用方须 `freeScanned`，否则泄漏）；新增显式命名别名 `queryRowOwned` /
  `queryRowPartialOwned`；新增 arena-借用 RAII 变体 `queryRowBorrowed` /
  `queryRowPartialBorrowed`（`BorrowedRow.deinit()` 一次释放、无需逐字段
  free；CachedConn 提供无缓存直通）。
- **audit 规则修正**: b10 豁免 `errdefer` / `rollback` 上下文里的 best-effort
  空 `catch {}`（事务回滚不再误报为吞错）；新增 b17 检查 owned `queryRow*`
  结果在函数内既未 `freeScanned` 也未 `return` 委托的泄漏点。
- **CrudApi 多租户 attr 可配置**: `CrudOpts` 新增 `tenant_attr`（默认
  `"tenant_id"`，即 catalog JWT 中间件 aud→attr 标准桥）；多门户场景可配置
  其他 attr 名。
- **Outbox 多租户支持**: `event_outbox` 迁移 SQL 内置可空 `tenant_id` 列
  （向后兼容）；新增 `buildInsertForTenant(topic, payload, tenant_id)`；
  `OutboxEntry` 与 `buildSelectPending` 带 `tenant_id`。
- **Repository 租户感知查询**: 新增 `findPageForTenant` / `findByIdsForTenant`
  / `findPageFilteredForTenant` / `countForTenant`（comptime 列名；模型缺租户
  字段时编译期报错，fail-closed）；原有方法签名不变。
- **API.md 旧别名清理**: `zigmodu.http_server.*` 示例统一为 `zigmodu.http.*`。

## [0.15.7] - 2026-08-04

### Changed
- **Bulk writes（`Repository` + `data.bulk`）**: `Repository.insertMany` /
  `upsertMany` 一条多行 SQL（SQLite/PG `ON CONFLICT ("id") DO UPDATE SET`、
  MySQL `ON DUPLICATE KEY UPDATE`，冲突 SET 默认除 id 外全列）；
  `Repository.findByIds` 单次 round-trip `WHERE pk IN (…)` 取代循环单行；
  `data.bulk` 方言感知批量 INSERT builder + 参数扁平化，exec 目标兼容
  Client/Transaction/SqlxBackend（新增 `SqlxBackend.dialect()`）。空行 /
  空列 / all-conflict upsert 均有守卫 + 回归测试（套件 858 pass），
  docs/API.md 补 Repository + bulk 参考。
- **zent-modulith 示例按 zent v0.27 能力沉淀**: 原子表达式防超卖、两级预加载
  + 边过滤/每父排序限量、复合 keyset 游标（平局不丢）、嵌套事务（savepoint）
  + `afterCommit` 事务事件、uuidv7 主键 + 敏感字段掩码、审计/校验/投影/
  批量插入/批量软删全链路 HTTP 演示；`tx_demo.zig` 下单编排（库存不足 409
  且整单回滚、事件提交后恰好一次投递）。文档同步：docs/ZENT.md 版本口径升至
  zent **v0.27.0+**（远程依赖示例 v0.27.0，升级注意补 v0.21–v0.27 要点）；
  AGENTS.md 工作区事实更新；两个 zent 示例依赖注释指向 `#v0.27.0`。
- **`zmodu market` Phase 2：远程发现 + 安装闭环**: `market update`（std.http 拉取
  远程索引 → `.zmodu/market-index.json`，坏缓存自动忽略、tmp+rename 原子写入）、
  `list/search/info` 改为本地 + 远程合并浏览（按 id 去重）、`market install
  <id> --dir … [--dry-run] [--verify]`（递归复制源码树，跳过 node_modules/.git/
  .output/.zig-cache 等；verify 就地跑 `zig build`）。签名、build.zig.zon 自动
  写入、CI 回归钩子留在 ADR-016（Phase 2c）。4 个新单测（合并去重 + copyTree
  跳过 junk 目录），CLI 套件 50 pass。docs/ZMODU_CLI_INTEGRATION 更新阶段表。
- **`zmodu market` 模块市场（Phase 1 本地策展目录）**: `tools/zmodu/src/
  marketplace/catalog.json`（schema_version 1）登记 12 个策展条目（zmsaas /
  tenant-mgmt / ai-ops / llm-policies / mcp-server / web4 / tenant-shop /
  shopdemo / basic + wechat-pay / aliyun-oss / apns stub）；`zmodu market
  list|search <q>|info <id>` 支持 `--json` 与 `--catalog PATH` 外部目录。设计
  取舍（ADR-015 式）：Phase 1 只做可发现性，远程 registry/自动安装/签名包
  延后（质量门优先）。2 个单测并入 CLI 套件；docs/ZMODU_CLI_INTEGRATION 补
  章节。
- **zsaas — SaaS 业务框架（zigmodu 后端 + saas-solidjs 前端）**: 新增 `zsaas/`
  目录。同一份业务模型 JSON 生成两端：后端 `zmodu saas <model.json>` 产出
  org 隔离的 zigmodu 模块（model/persistence/service/api/module/root 六文件、
  参数化 SQL 强制 `org_id` 租户过滤、ComptimeRouter `.auth=.jwt` + permission
  门控、ctx.json、saas-schema.sql 迁移产物），生成模块已在真实 zigmodu 工程
  编译通过；前端 `scripts/gen-business.mjs` 生成 SolidStart 管理页（列表/新建/
  编辑/删除 + i18n + 导航）+ `zmoduFetch` REST client（`/api/v1/<entity>`，
  Bearer 鉴权），tsc 全绿；`scripts/check-gen.mjs` 自检。
  **一键新建前后端**：`scripts/create-project.mjs <model.json> --name <app>` 同时
  创建 zigmodu 后端工程（自动把 zigmodu 依赖指向本地仓库，规避 `zmodu new`
  的旧 tag 占位 hash）与 saas-solidjs 前端工程（模板复制 + 业务页面），端到端
  验证：后端 `zig build` 编译通过 + `zmodu verify` 全过、前端页面生成、零泄漏。
  顺带修复 `zmodu new` 的既有 bug：生成 main.zig 引用未定义 `project_name`、
  未使用 allocator/init，以及 `generateLifeDir` 两处 ArrayList 泄漏。
- **AI key 轮换 bug 修复（审查发现）**: (1) `AiProvider` 自动换 key 重试后，调用方
  旧 lease 指向已失败的 key——`mgr.onSuccess(lease)` 会把刚 429 的 key 重置回
  健康、撤销冷却；新增 `provider.reportSuccess()` / `reportError(kind)` 用当前
  key 反馈，providerFor 文档同步；(2) `RedisCooldownStore` 冷却标记（SET）与
  失败计数（INCR）共用同一 key，cool 会覆盖计数——拆分为 `:fail` 子键，失败数
  跨进程准确；(3) `chatWith` 传输层错误补上报 `.network` 给池（chatStream 已有）。
  新增外部共享 store 路由单测（套件 838 pass）。
- **跨进程 KeyPool cooldown（CooldownStore）**: 新增 `ai/cooldown_store.zig`——
  `CooldownStore` 接口（isCooling/cool/bumpFailures/reset）+ `MemoryCooldownStore`
  （默认，单进程零依赖）+ `RedisCooldownStore`（跨进程：SET EX / INCR+EXPIRE /
  DEL，fail-open 本地镜像回退，对齐 RedisRateLimiter 先例）。`KeyPool` 的冷却/
  失败/禁用状态改为经 store 读写（多实例共享 key 时协调一致），计数器仍留本地
  观测；`AiKeyManager.setSharedStore` 一键接入。3 个新单测（套件 837 pass），
  docs/LLM_POLICIES.md §8 补跨进程接线。

## [0.15.4] - 2026-08-02

### Changed
- **AI AiKeyManager（provider + key 轮换，四层结构）**: `ai/key_pool.zig`
  （key 池：round-robin、429/配额指数冷却、连续 401 禁用、恢复与观测）、
  `ai/provider_registry.zig`（provider 注册表：endpoint + key 池 + 模型路由 +
  fallback provider 链）、`ai/provider.zig` 挂池（`bindKeyPool` 后
  chat/chatWith 对 401/403/402/429 自动换 key 重试一次）、`ai/module.zig`
  （`AiKeyManager`：`ProviderConfig` api_keys 配置 + 生命周期 +
  `providerFor`）。簿记 `std.Io.Mutex` 保护、HTTP 调用不持锁，适合高并发；
  10 个单测并入框架套件（834 pass）。docs/LLM_POLICIES.md §8 更新为四层接线。
- **git 依赖打包修复 + catch 反模式规则**: (1) `build.zig.zon` 的 `.paths` 增加
  `examples/_shared`——git+https 依赖按 `.paths` 打包，此前 `_shared`（及整个
  examples/）不会出现在拉取包里，业务方换版本必须重打 zig-pkg workaround，现
  已根治（`zig fetch` 后包内自带 `db_link.zig` / `zent_helpers.zig`）；(2) audit
  新增 `b11` 规则：未使用 catch 捕获（`catch |err| { _ = err; }` / `catch |_|` →
  应写 `catch {`），并修复 `src/ai/provider.zig` 存量；(3) `scripts/release.sh`
  移除 fingerprint 重算步骤——按 Zig 文档 fingerprint 是包永久身份、同包永不改
  （改了有信任/安全影响）；docs/SQLX_DRIVERS.md 补充 git 消费者说明。

## [0.15.3] - 2026-08-02

### Changed
- **`zmodu audit` 业务最佳实践检查器**: 新 CLI 命令，两组规则——architecture
  （模块自依赖/循环依赖/缺失描述/命名规范/依赖上限/未知依赖/base 模块依赖，
  与 `zigmodu.ArchitectureTester` 默认规则对齐）与 business（handler/model 含
  SQL、非参数化 SQL、`@ptrCast(ctx.user_data)`、legacy sendSuccess/sendFail、
  banned 导入、已移除 Zig 0.17 API、跨模块直接文件导入）。支持 `-j` JSON、
  `--group`/`--max-deps`/`--base-modules`、`.zmodu/audit-baseline.json` 基线
  （与 deadcode 同语义，`--update` 收缩）；CLI 单测 4 个并入 `zig build test`。
  同时把 `zigmodu.ArchitectureTester` 导出到 root（修复与
  docs/AI_METHODOLOGY.md 的断点），docs/ZMODU_CLI_INTEGRATION.md 补章节。
- **zmodu 工具链增强（P0/P1 落地）**: (1) `zmodu ci` 一站式门禁——`zig build`
  → `fmt --check` → `verify` → `audit` → `deadcode`，单命令面向 CI；(2)
  `zmodu graph [dir] [--out]` 输出模块依赖 Mermaid 图；(3) `zmodu diff old.sql
  new.sql --migration <name>` 自动生成 Flyway 迁移 SQL（CREATE/ALTER/DROP），
  并修复迁移时间戳恒为 `V19700101000000` 的既有 bug（改用 REALTIME 时钟）；(4)
  audit 规则配置 `.zmodu/rules.json`（`max_deps` / `disabled`）与两条新规则
  `b9`（handler 手工解析 Authorization/Bearer）、`b10`（空 catch 吞错）；(5)
  MCP server 新增 `zmodu_audit` / `zmodu_graph` 工具；(6) 修复既有 bug：
  `verify` 字面量 details 被 free 导致的无效释放崩溃、`module_integrity` warn
  details 泄漏、`parseSqlSchema` 对 `CREATE TABLE IF NOT EXISTS` 的表名泄漏、
  sql_diff 测试 const 数组协变编译错误（此前 zmodu CLI 测试产物为缓存旧态）。

## [0.15.2] - 2026-08-02

### Changed
- **freeValue 内存安全审计**: 全代码审计 `std.json.Value` 树所有权（handler 返回树必须由
  `ctx.allocator` dup 全部 key/字符串，调用方统一 `freeValue`）。修复
  `ai.business.db.query` / `entity.list` 返回树使用字面量 key `"rows"`/`"count"`
  （`ObjectMap.put` 按引用存 key，`freeValue` 会释放字符串字面量 → 无效释放；新增
  `std.testing.allocator` 回归测试，修复前实测 crash），以及 `Agent.run` 工具结果在
  `Stringify.valueAlloc` 失败时未释放的 OOM 路径泄漏。
- **Agent composition tests + AI benchmark + optional real-provider CI**: (1) `Agent.run` integration tests for the composed paths — context auto-compaction (`ContextManager` summarize invoked mid-run), budget exhaustion (early stop + `budget_exhausted`), and cooperative cancel (requested from `on_step`, stops next iteration); (2) `zig build benchmark` gains an AI section (workflow 20-step × 100 ≈ 5 ms); (3) CI adds an optional `ai-real-provider` job that runs `examples/llm-policies` against a real LLM when `LLM_API_KEY` is configured (GitHub secret). AGENTS/AI_METHODOLOGY docs synced.
- **SkillRegistry → MCP bridge**: `zigmodu.ai.mcp` exposes registered AI skills as Model Context Protocol tools — `toMcpTools` (MCP `tools/list` payload with inputSchema derived from tool parameters), `handleToolCall` (dispatch to the registry, text content result) and `serveStdio` (JSON-RPC 2.0 MCP server over stdin/stdout). Applications serve a session `SkillContext` (tenant/user/permissions), so `required_permission` gates and admin.* allowlists still apply. docs/MCP.md documents wiring + security.
- **MCP 真实链路示例 + 客户端冒烟 + 泄漏修复**: new `examples/mcp-server` exposes `kpi.query` (in-memory SQLite) + `ping` over real MCP stdio; `scripts/mcp-client-test.py` drives a real session (initialize / tools/list / tools/call) asserting protocol 2024-11-05 and KPI sum — verified locally with zero leaks. Fixes a `handleToolCall` leak (response tree was never freed after stringify). Added to CI example builds.
- **Admin/ops AI skills (P2 落地)**: `zigmodu.ai.admin` — `admin.cache.invalidate` / `admin.cache.clear` (whitelisted caches, wildcard keys rejected, `all=true` opt-in for clears), `admin.config.get` / `admin.config.set` (ConfigStore with mutable-keys whitelist), `admin.audit.export` (RunAuditStore query with kind/tenant/limit filters) and `admin.user.manage` / `admin.tenant.provision` (app-callback delegation). Each requires its own permission code and **must be explicitly allowlisted** — off by default, per the controlled-execution posture.
- **Dead-code baseline gate**: `scripts/check-deadcode.sh` fails CI when the repo gains new dead declarations (identity `file:kind:name:parent`, so line moves don't false-positive); removals are allowed and `--update` shrinks the baseline (`scripts/deadcode-baseline.json`, 37 items). Wired into CI after the deadcode smoke.
- **Agent end-to-end test**: `Agent.run` driven against a loopback mock OpenAI endpoint — tool_calls → skill dispatch → final answer, asserting `answer`, `metrics.tool_calls`, tool hook invocation.
- **Workflow DAG approval-gate test**: a `.approval` step in a DAG stops the run with `pending_human` after dependencies complete; downstream steps never run.

## [0.15.1] - 2026-08-02

### Changed

- **Remaining zero-test coverage**: added tests for `src/util.zig` (`randomHex`/`randomUuid` length + hex charset, `pluralize` english rules incl. vowel-y, `hexEncode` + `HashKit` MD5/SHA-256 known vectors) and `sqlx.errors.sqlStateToError` (SQLState → kind mapping, unknown → Other) — which surfaced two missing mappings (`57014` Timeout, `53300` TooManyConnections) now added. The remaining zero-test files are barrels (http/observability/security/data/root/docs/outbox/im/extensions/ai/web4), C bindings (sqlite3_c/libpq_c/libmysql_c + stubs), platform-specific io_uring stubs and the usage `main.zig`/benchmark entry — none require unit tests.
- **Fluvio native transport + thin-component tests**: `messaging.FluvioNative.NativeTransport` replaces the `fluvio` CLI subprocess with a pluggable TCP transport (line protocol over a socket; loopback server for tests/dev — end-to-end createTopic/produce/consume/list verified). `FluvioConnector` gains a `transport` field so apps inject the native transport or a faithful Fluvio SC/SPU protocol implementation. Added tests for the remaining zero-test thin components: `core.Event` (tagged-union payloads), `log.ModuleLogger` (+ `LogScope`), `metrics.MetricsBackend` (vtable routing).
- **Zero-test component hardening**: added tests for `sqlx.CircuitBreaker` (open/half-open/closed state machine incl. timeout re-open and half-open failure), `core.EventPublisher` (TypedEventBus publish + event validation + metadata) and `core.ApplicationModuleListener` (subscribe + receive). Fixing them surfaced three more lazily-compiled broken implementations: `EventPublisherMixin` validated against the wrong bus type (`EventBus` vs `TypedEventBus`), `ModuleListener.subscribe` called a 2-arg `EventBus.subscribe` with one argument and wrapped the handler with the wrong signature — both now compile and pass tests. `FluvioConnector` CLI-fallback stub semantics confirmed covered by existing tests.
- **Productization pass (per component audit)**: (1) **Security consolidation** — `http_middleware.securityHeaders()` (default HSTS/X-Frame-Options/CSP/etc.) is the canonical security-header middleware; deleted the broken `security/SecurityHeaders.zig` middleware (wrong return type + wrong `next` call, never compiled) and the duplicate broken `security/Csrf.zig` (`CsrfProtection` — invalid API calls, never compiled); `Middleware.csrf()` is now the single CSRF implementation. Added tests for csrf allow/reject and security-header injection. (2) **EventStore productionized** — JSON event serialization, replay invoking the application handler, snapshot-based replay (state + events after snapshot), thread safety via `std.Io.Mutex`, owned metadata; tests cover append/serialize/replay and snapshot replay. (3) **Removed deprecated `ScheduledTask.zig`** (placeholder `start()`/`calculateNextCronRun`; AI bridge uses `Cron.zig`) — `zigmodu.TaskScheduler` export dropped. (4) **gRPC audit** — server/client/bidi/bidi-pump streaming are fully implemented and tested (corrects an earlier "streaming UNIMPLEMENTED" note). (5) PluginManager comment dedupe + HealthEndpoint test.
- **Web4 production hardening**: `web4.x402_store.X402Store` — persisted invoices (SQL) with exactly-once redemption (`redeem(invoice_id, tx_hash)` → redeemed / not_found / already_used / expired), wired into `x402Middleware` via `X402Config.store` (invoices created on 402, proofs redeemed once, replay → 410). `web4.challenge.ChallengeStore` — one-time DID challenges (issue + verifyAndConsume, TTL, anti-replay), wired into `didAuthMiddleware` via `DidAuthConfig.challenge_store`. `DidAuthConfig.jwt_issuer` issues a JWT (`x-did-token` header) after DID auth so clients continue on the framework's JWT/RBAC chain. Fixed pre-existing did.zig leaks (credential issue/verify buffers). `examples/web4` upgraded to the production path (402→200→410 replay rejection; DID challenge + JWT issuance); docs/WEB4.md documents the hardening.
- **Web4 middleware + example**: `zigmodu.web4.middleware` — `x402Middleware` (no proof → 402 + invoice, invalid → 403, valid → pass; fail-closed default verifier, optional per-route `path_prefix` + `on_invoice` pricing hook) and `didAuthMiddleware` (did:key signature verification → writes `did` / `user_id` attrs; per-route `path_prefix`). New `examples/web4` demonstrates both flows end-to-end (402→200 with proof, 401→200 with a generated did:key signature), `docs/WEB4.md` documents protocol + wiring + security defaults. Added to CI example builds.
- **LLM policy real-chain fixes**: `llmJson` now deep-copies the parsed response out of the parser arena before returning (callers `freeValue` it safely — previously the arena-resident tree caused invalid frees; only fake `json_fn` tests exercised that path until now). Added an end-to-end test that drives `llmApprove` through a real loopback mock OpenAI endpoint (provider.chat → llmJson → decision), plus fixed a dangling-pointer in `examples/llm-policies` (provider/http moved to function scope). Verified live against DeepSeek: llmApprove/llmRiskDecide/llmDiagnose/llmVerify all return real model decisions.
- **Write-operation AI skills (P1 落地)**: `zigmodu.ai.actions` — `entity.create/update` (whitelisted writable columns via `EntitySpec.writable`, tenant column forced from `SkillContext.tenant_id` and rejected from the model, PK forbidden, permission `entity:write`), `command.execute` (app-registered commands via the transactional outbox, idempotency key = `SkillContext.run_id`, permission `command:execute`) and `report.generate` (app-registered aggregations → CSV/JSON, row-capped). Closes the "AI 只读 → AI 可执行" gap; `EntitySpec` gains a `writable` field (backward compatible).
- **Dead-code analyzer fixes (`zmodu deadcode`)**: fixed two false-positive roots in the zdeadcode reference resolver — (1) a `test "name"` whose name equals a function name shadowed the function in `name_map`, so references resolved to the (already-live) test and the function was reported dead; (2) container members (enum variants/fields/methods) shadowed same-named top-level declarations (e.g. `const deadcode = @import(...)` + `enum { deadcode }`). Members no longer overwrite top-level names; both cases have regression tests. Also fixed an arena leak in the CLI adapter and wired the analyzer's own unit tests (analyze + scanner) into `zig build test` (was previously only compiled, not run). Repo scan dropped from 45 to 39 findings (0.4%), with the remaining items genuine unused imports/functions plus layout field `WALEntryHeader._pad` (kept).
- **Dead-code checker (`zmodu deadcode`)**: integrated the zdeadcode analyzer (rustc `dead_code`-style reachability: unused top-level fns/consts/vars, container fields, enum variants, methods, never-imported modules; `.gitignore`-aware scanning; human + JSON output; exit code 0/1/2 for CI). Its unit tests ship with the zmodu CLI test suite (framework suite now 825/843). CI adds a deadcode smoke asserting detection + valid JSON.

## [0.15.0] - 2026-08-01

### Changed
- **AI 编排栈完整化（本轮大版本主题）**：workflow 线性↔DAG 混合 + 人工审批门
  （`.approval` step、`pending_human`、resume 恢复不重提）+ WAL 恢复 + LLM
  反射验证（`ai.llm.llmVerify`）+ `WorkflowMetrics` 观测 + `toMermaid` 图导出；
  触发三源统一（cron / fire / outbox，`ai.bridge.OutboxWorkflowBridge`）；
  业务工具 11 件（reporter/alerts/ticket/refund/risk/recon/approval/notify/kpi/
  sla/diagnose）；审批技能桥 `approval.request`（`required_permission` 门控）；
  LLM 策略 + RAG 上下文（`ai.llm`，失败安全回退 escalate）；持久化审批队列
  （`PersistentApprovalQueue`，tenant_id 隔离）+ HTTP API；outbox 消费端
  （`OutboxConsumer`）；运行审计（`RunAuditStore`，workflow + agent）；
  AI 观测聚合（`AiMetrics`）；技能注册表 OpenAPI/CLI 导出
  （`ai.skill_export` + `zmodu ai`）；多租户 AI 示例（tenant-ai）、LLM 接线
  教程（docs/LLM_POLICIES.md）、AI 全链路示例（ai-ops）。

### Changed
- **AI hardening pass**: (1) `Agent.audit_store` — standalone agent runs now persist to `RunAuditStore` (kind=agent, status/steps/duration), closing the durable-audit gap next to workflow runs; (2) `Tool.required_permission` + `SkillContext.permissions` — dispatch refuses with `error.PermissionDenied` when the tool's required permission is not granted; `approval.request` now requires `approval:decide`; (3) `skill_export.toOpenApi` gains optional bearer security (`OpenApiOpts.security_scheme` → components.securitySchemes + per-operation security); (4) barrel integrity test asserts the public `ai.*` API surface and caught a missing `ai.schedule` export (fixed); (5) docs synced — `docs/AI_SKILLS.md` now lists implemented business skills (kpi.query / approval.request / notification.send) vs planned ones, `docs/AI.md` reflects the removed `TaskScheduler`; (6) CI adds a `zmodu ai export-skills + openapi` smoke test asserting valid JSON.
- **AI skill registry → OpenAPI + CLI**: `zigmodu.ai.skill_export` renders a `SkillRegistry` as a JSON catalog (`toSkillsJson`) or an OpenAPI 3.0 document (`toOpenApi`, one `POST /skills/{name}` per skill with schema derived from parameters). `zmodu ai export-skills --out` writes the built-in catalog and `zmodu ai openapi --in/--out` converts any catalog (built-in or app-exported) to OpenAPI. tenant-ai serves both at `GET /api/ai/skills` / `GET /api/ai/skills/openapi` (verified live).
- **LLM policy wiring guide + example**: new `docs/LLM_POLICIES.md` walks through wiring a real `AiProvider` into `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify` (LlmPolicyCtx, RAG, json_fn testing, behavior contract), with a companion runnable `examples/llm-policies` (real-model mode via env vars, fake-json fallback so tests stay network-free). Fixed `llmDiagnose` summary parsing (missing `.string`) surfaced by the example, with a regression test. Added to CI example builds.
- **Durable AI run audit**: `zigmodu.ai.run_audit.RunAuditStore` persists one row per workflow/agent/approval run (run_id, kind, status, tenant, steps, duration); attached via `Workflow.audit`, run/resume record automatically. `list(kind, tenant, limit)` filters history; tenant-ai serves it at `GET /api/ai/runs` (tenant-isolated, verified live). `zigmodu.Time` exported from the barrel.
- **AI observability aggregation**: `zigmodu.ai.observability.AiMetrics` merges `WorkflowMetrics` + `AgentMetrics` + `TokenQuota` into one Prometheus document (attach pointers + labels) for a single `/metrics` endpoint; tenant-ai serves it at `GET /api/ai/metrics` (verified live alongside workflow runs).
- **tenant-ai example extended**: workflow endpoints now carry `WorkflowMetrics` and a `GET /api/ai/workflow/graph` Mermaid export of the step pipeline (incl. the approval gate); `ai.WorkflowMetrics` re-exported from the barrel. Verified live.
- **Approval skill bridge**: `registerApprovalRequestSkills` exposes `approval.request` (subject + amount; chain + policy app-registered) so an Agent inside a workflow `.agent` step can submit approvals directly; the escalated run lands in the queue and `resumeRun` continues after the human decides.
- **Workflow graph export**: `Workflow.toMermaid` renders the step graph as a Mermaid `flowchart` — implicit order edges for linear runs, dependency edges for DAG runs, nodes annotated with their kind (llm/skill/agent/approval). Tests cover both layouts.
- **LLM-backed workflow verification**: `zigmodu.ai.llm.llmVerify` implements `VerifyFn` for `Workflow.reflection` — the model judges whether the final output meets the goal (`{"pass":...}`); failures and malformed responses conservatively return `false` (re-run / escalate). Tests cover pass, fail and provider-error paths.
- **Workflow approval gate resume lifecycle**: end-to-end test proving run → `.pending_human` (gate persisted to WAL) → human approves → `resumeRun` continues from the persisted gate and finishes the remaining steps — the human decision is not re-submitted on resume.
- **Workflow approval gate (human-in-the-loop)**: new `.approval` step kind (`{ subject, amount }`) driven by `Workflow.approval_flow` — approved continues, rejected fails the step, escalated stops the run with a new `.pending_human` status so the app can hand the queue to a human and `resumeRun` afterwards (the gate re-runs under the same policy). Test covers both approved → completed and escalated → pending_human.
- **Workflow observability**: `zigmodu.ai.WorkflowMetrics` attaches to `Workflow.metrics` and accumulates `runs` / `completed_steps` / `failed_steps` / `escalations` / `reviews` (reflection re-runs) on every run/resume — including DAG waves; `toPrometheusFormat` exports `zigmodu_ai_workflow_*` counters alongside `AgentMetrics` and `TokenQuota`.
- **Multi-tenant AI example**: `examples/tenant-ai` — two tenants share one app with tenant-scoped AI operations: per-tenant KPI (`kpi.query`), business reports, alert rules, an approval chain with a `PersistentApprovalQueue` that carries `tenant_id` (tenants cannot see or resolve each other's pending items), and a workflow running the registered skills. `ApprovalApi` + `PersistentApprovalQueue` gained optional tenant scoping (`listPending`/`resolve`/`count` take `?i64`); `ai.freeValue` is now exported from the barrel. Added to CI example builds.
- **AI orchestration P2 (RAG context for LLM policies)**: `LlmPolicyCtx` accepts an optional `retriever` + `retrieval_query`; `buildContext` injects top-k retrieved chunks (policies / history / playbooks) into the `llmDiagnose` / `llmApprove` / `llmRiskDecide` prompts so decisions are grounded in business context. Test: keyword retriever chunk appears in the approval prompt and drives the outcome.
- **AI orchestration P2 (persistent approval queue)**: `zigmodu.ai.approval_store.PersistentApprovalQueue` — SQL-backed human approval queue with the same interface as the in-memory one (`push` / `listPending` / `resolve` / `count`, `migrate()` DDL) and a `queuedEscalationPersistent` hook. `ApprovalApi` is now generic over the queue type, so both in-memory and persistent queues mount into the ComptimeRouter unchanged.
- **AI orchestration P2 (outbox→workflow bridge)**: `zigmodu.ai.bridge.OutboxWorkflowBridge` routes outbox entries (exact or prefix topic) into `ai.trigger.fire(input)` — cron / in-process fire / outbox events are now three unified trigger sources; run outcomes flow back through the trigger's outbox writeback.
- **AI orchestration P2 (human approval queue + HTTP API)**: `zigmodu.ai.approval_api` — `ApprovalQueue` (thread-safe in-memory queue), `queuedEscalation` hook for `ApprovalFlow.on_escalated`, and an `ApprovalApi` ComptimeRouter module exposing `GET /approvals/pending`, `POST /approvals/{id}/approve`, `POST /approvals/{id}/reject` (`approval:decide` permission).
- **AI orchestration P2 (LLM default policies)**: `zigmodu.ai.llm` provides `llmDiagnose` / `llmApprove` / `llmRiskDecide` — LLM-backed callbacks for DiagnosisFlow / ApprovalFlow / RiskReview via `LlmPolicyCtx` (`provider` + injectable `json_fn` + `system_hint`); model failures or malformed JSON fall back to escalate (never silently approve). `ApprovalFlow` gains an `on_escalated` hook (+ `escalated_userdata`).
- **End-to-end AI ops example**: `examples/ai-ops` chains the built-in business tools into one runnable pipeline — `BusinessAlert` detect → `DiagnosisFlow` diagnose → `ApprovalFlow` approve (auto-approve small / escalate large) → `NotificationHub` notify → `OutboxConsumer` audit; `zig build run` prints the trace and `zig build test` asserts every stage. Added to CI example builds and the examples README.
- **Built-in business tool (P1, anomaly diagnosis)**: `zigmodu.ai.diagnose.DiagnosisFlow` takes a detected anomaly (from alerts/recon/sla/app code), gathers evidence via configured SQL queries and hands symptom + evidence to a `diagnose` callback (LLM or rule engine) producing likely causes + recommended actions; the result is written to the outbox (`ai.diagnose`) for audit/automation.
- **Built-in business tool (P1, SLA tracker)**: `zigmodu.ai.sla.SlaTracker` tracks monotonic deadlines on business items (tickets/approvals/refunds); `check()` (cron-driven) fires a `warn` when an item enters the deadline window and a `breach` once past it — events go to an `on_sla` callback (e.g. route into `ai.notify`) and the outbox (`ai.sla`) for audit/automation.
- **Built-in business tool (P1, KPI metric queries)**: `zigmodu.ai.kpi` registers app-owned named metrics (name → SQL → value column); the `kpi.query` skill lets an Agent answer business questions like "本周营收多少" by name only, and a programmatic `Kpi.query` returns the metric value for dashboards/automation.
- **Outbox read side (consumer)**: `zigmodu.outbox.OutboxConsumer` polls pending entries (optional topic filter), dispatches to a registered handler (`userdata` + `call`; topic/payload handed over as call-scoped copies) and advances the lifecycle pending → processing → delivered, with `retry_count++` + `error_message` on failure and failed/DLQ after retries are exhausted. Closes the loop for the AI business-tool outbox writebacks (`ai.approval` / `ai.recon` / `ai.notify` / `ai.risk` / `ai.alert`).
- **Built-in business tool (P1, notification hub)**: `zigmodu.ai.notify.NotificationHub` delivers a message to named channels — webhook (via `HttpClient`, HTTP 2xx counts as delivered), custom sink (email/IM/in-app callback with `userdata`+`call`) or durable outbox fallback (`ai.notify`) when no channel matches; delivery failures propagate, nothing is silently dropped. `registerNotifySkills` exposes the `notification.send` skill bridge (LLM supplies channel/title/body; channel targets stay app-registered with an optional allowlist).
- **Built-in business tool (P1, approval chain)**: `zigmodu.ai.approval.ApprovalFlow` runs a request through a configured multi-level chain — each step is decided by a `policy` callback (LLM/RBAC/rule engine) as approved / escalated / rejected, stopping on first rejection or human escalation; every step + a final event is written to the transactional outbox (`ai.approval`). `registerApprovalSkills` exposes the `approval.submit` skill bridge (LLM supplies subject/amount/request only; chain + policy stay app-registered; safe default policy escalates to a human).
- **Built-in business tools (P1, risk + recon)**: `zigmodu.ai.risk.RiskReview` scores a subject via configurable SQL rules → level (low/medium/high) → decision (approve/escalate/reject, `DecideFn` hook for LLM/policy) → outbox writeback (`ai.risk`); `zigmodu.ai.recon.ReconCheck` compares source/target SQL snapshots by key (missing / extra / mismatch), fires per-diff `on_diff`, writes a CLEAN/DRIFT summary to the outbox (`ai.recon`) and renders a Markdown diff report (`renderReport`).
- **Built-in business tool (P1, refund with compensation)**: `zigmodu.ai.refund.RefundFlow` validates → approves → executes a refund as a transactional outbox command → notifies; notify failure auto-emits the compensation command (`refund.reverse`), plus app-initiated `compensate()`.
- **Built-in business tool (P1, ticket triage)**: `zigmodu.ai.ticket.TicketFlow` loads customer/order context, classifies, drafts a reply, runs an approval/send gate (`on_send`) and writes the outcome to the outbox.
- **Built-in business tools (P0)**: `zigmodu.ai.reporter.BusinessReporter` renders configured SQL queries as a Markdown report (cron + outbox = scheduled delivery); `zigmodu.ai.alerts.BusinessAlert` runs SQL rules and alerts (callback + outbox writeback) on any violation row.
- **Workflow linear ↔ DAG hybrid**: steps can declare `depends_on`; when any step has dependencies the runner switches to dependency-aware parallel waves (`max_parallel` via `std.Io.Group`) with cycle detection (`error.CyclicDependency`). Budget, WAL persistence, retry and escalation apply in DAG mode too; reflection stays on the linear final step.
- **AI orchestration P2 (runtime control)**: `zigmodu.ai.AgentHandle` cooperative cancel / pause / step progress (checked at step boundaries; `canceled` flag + metric); `Agent.tracer` + `parent_span` create a run-level span via `DistributedTracer`.
- **AI orchestration P2 (context management)**: `zigmodu.ai.context` auto-compacts long conversations by token threshold — older messages are summarized (via `SummarizeFn`) or dropped, prepended as a system message, keeping a recent window; wired into `Agent` (`Agent.context`, checked each loop iteration).
- **AI orchestration P1 (hierarchical)**: `zigmodu.ai.hierarchy` planner → concurrent executor (`std.Io.Group`, `max_parallel` waves) → aggregation; partial failures surface as `.partial_failed`. Planner/executor are callbacks wireable to `Agent`/`Workflow`.
- **AI orchestration P1 (AgentTrigger)**: `zigmodu.ai.trigger` unifies cron / event / webhook sources into `fire(input)` + `registerCron`; optional transactional-outbox writeback of `{run_id, ok, message}` when an `OutboxPublisher` + SQL backend are configured.
- **AI orchestration P1 (WAL persistence + resume)**: `Workflow.wal` + `run_id` persist each step record to the WAL; `resumeRun(run_id)` replays completed steps and continues from the first unpersisted one (crash recovery / idempotent replay).
- **AI orchestration P1 (reflection + escalation)**: `Workflow` gains a reflection quality gate (`VerifyFn` + `max_reviews` — re-runs the final step until verified) and a human-escalation hook (`on_escalate` on step failure after retries / budget exhaustion / persistent verification failure).
- **AI orchestration (P0)**: `zigmodu.ai.workflow` linear multi-step runner (`.llm` / `.skill` / `.agent` steps, per-step records, retry, stop-on-failure, shared budget) and `zigmodu.ai.Budget` (hard token reservation per step; `.stop`/`.warn` modes; wired into `Agent` — `budget_exhausted` flag + metric). Plan + roadmap in `docs/AI_ORCHESTRATION.md`.
- **sockread performance pass**: `readSome`/`readFull` drop the redundant `poll` (std.Io sockets are blocking, so a bare `read` already waits — syscall count halves); new `sockread.Reader` buffered reader collapses many small reads into one larger syscall, adopted by `WsFramer` frame parsing and the Kafka transport; new `sockread.writevAll` sends header+body in a single `writev` (adopted by `WsFramer.writeFrame`, `ClusterConnection.send`, Kafka `writeFrame`). HttpClient keeps its timeout `waitForReadable`.
- **Built-in business AI skills (P0)**: `zigmodu.ai.business` registers `db.query` (read-only parameterized SELECT, row-capped, rejects literals/comments), `entity.lookup` / `entity.list` (app-registered entity whitelist, tenant-scoped when configured) via `SkillContext.backend_ptr`. Scheduler bridge completed with `list_jobs` / `cancel_job` (`ScheduleCtx` via `SkillContext.userdata`). New `ai.freeValue` defines result ownership (handlers dupe keys/strings; callers deep-free). Plan + roadmap in `docs/AI_SKILLS.md`.
- **Raw socket reads for all long-blocking io read paths**: new `core/sockread` helper (`readSome`/`readFull`/`writeFull`, `posix.poll` + `posix.read`/`write`) now backs the reads that wait for peer data — Redis responses (16 call sites), NATS reads (4), Kafka `readExact`, `DistributedEventBus` connection loop, `ClusterConnection.recv` (fixes partial-header reads) and `send` (loops on partial writes so frames are never split), and `HttpClient` `readResponse`/streaming body reads. Same class of fix as the fiber-mode WebSocket read: with the Threaded Io shared across threads, io-based socket reads can block forever even with data in the kernel buffer.
- **Fiber-mode WebSocket read fixed**: `WsFramer.readFrame` / `WebSocketClient` reads now use raw `posix.poll + posix.read` instead of `io.operate(net_read)`. With the Threaded Io shared across the accept thread, worker fibers and clients, io-based socket reads block forever even when data is in the kernel buffer (reproduced: `poll` readable + `MSG_PEEK` shows bytes, `readv` hangs) — so WS client→server frames, ping/close handling and `on_close` never fired. Writes were unaffected. Added an end-to-end regression test (handshake → masked frame → `on_message` → client close → `on_close`).
- **AI ⇄ cron 薄桥**: `Cron.Scheduler` fixed — the background loop now ticks periodically (`std.Io.sleep`), `addJob` is thread-safe (mutex + name copy) with public `tick()` for deterministic scheduling; `every` is a blocking one-shot helper. New `zigmodu.ai.registerScheduleSkills` exposes `list_schedulable_tasks` / `schedule_job` tools so an Agent can attach pre-registered named tasks to cron expressions (LLM never supplies code). `ScheduledTask.TaskScheduler` marked deprecated (never looped; placeholder next-run math) for removal in v1.0.
- **`HttpClient` pure-HTTP path fixed**: the buffered request writer was never flushed, so the request never reached the peer and `request()` deadlocked in a plain `main` (misdiagnosed earlier as an event-loop dependency). `executeRequest` now flushes after writing headers/body. `timeout_ms` (previously stored but unused) is now honored via `posix.poll` in `readResponse` (`error.Timeout` on a stalled peer). Added loopback end-to-end tests: live request round-trip and stalled-peer timeout.
- **`ctx.header()` is now case-insensitive** (RFC 9110): mixed-case lookups like `"User-Agent"` or `"X-Tenant-ID"` resolve to the lowercased parse-time keys. Fixes latent null-header bugs in `AccessLog`, `middleware/Validation`, and the tenant-mgmt example.
- **Postgres `?N` placeholder bug fixed**: `convertPlaceholders` now consumes sqlite-style `?N` digits so `?1` maps to `$1` (previously `$11`, SQLSTATE 42P18), numbers placeholders sequentially, and skips `?` inside quoted strings/identifiers and `--`/`/* */` comments. Added unit tests covering `?`, `?N`, mixed forms, `?12`, literals and comments.
- **Engineering-quality pass**: repo-wide `zig fmt` (src/tools/examples); fixed `examples/zent-modulith` struct-field syntax error; `Server` global-middleware errors on unmatched routes are now logged; silent I/O/DB error swallows converted to logged catches in redis / ClusterMembership / RaftElection / Orm / WAL / Nats / EventBus / HealthEndpoint / ApplicationView / WorkerPool.
- **`check-production` gate extended** to hot-path modules (redis, Nats, ClusterMembership, DistributedEventBus, RaftElection, WAL, Orm) — previously only Server/sqlx/security were scanned.
- **`DistributedEventBus` connection read loop fixed** for the real `std.Io` (threaded) reader: `readSliceShort` returns a byte count, not a slice; the loop previously failed to compile when a real connection path was instantiated (surfaced by `examples/distributed`).
- **`HttpClient.ConnectionPool` tests now use a real loopback listener** instead of always skipping on `ConnectionRefused` to port 9999.
- **Network-dependent tests skip gracefully** in sandboxed/restricted environments via `src/test/NetworkProbe.zig` (raw-syscall probe) instead of crashing the whole test binary with `errnoBug` on `EPERM`.
- **CI hardening**: `ZIG_VERSION` pinned to `0.17.0-dev.1422+e863bf3be`; `zig fmt --check` now covers `src tools examples`; new `examples` job builds all nine examples (incl. `zent-modulith` with a sibling `zent` checkout); `test-live-services` adds a real Kafka broker (`apache/kafka:3.7.2` KRaft) via `KAFKA_BOOTSTRAP`.
- **Module test helpers are public API**: `zigmodu.ModuleTestContext` and `zigmodu.createMockModule` exported from `root.zig` (consistent with `IntegrationTest`/`Benchmark`/`ContractTest`); `examples/testing` updated off the deprecated `zigmodu.extensions` namespace.
- **Repo hygiene**: tracked `wal_test`/`wal_test2` artifacts removed; `.gitignore` covers `wal_test*` and `.codegraph/`.

### Added
- **WebSocket binary frames**: `on_message` receives text (0x1) **and** binary (0x2) with `WsFrameKind`; fiber + io_uring paths; `WsFramer.writeBinary` / `writeData`. Unblocks OpenIM-style protobuf over WS. **Breaking**: `WsMessageFn` gains `kind` parameter.
- **Selective SQL driver linking**: `-Ddb=all|sqlite|postgres|mysql` (comma-list) via `examples/_shared/db_link.zig`; `build_options.enable_*`; disabled drivers use C stubs (no link) and `Client.connect` returns `error.DriverNotEnabled` (also in `ZigModuError`, HTTP 400). Package consumers: `b.dependency("zigmodu", .{ .db = "sqlite" })`. Scaffold/`--from-db` maps DSN → `.db=`. Framework `zig build test` keeps default `all`; CI integration builds use `-Ddb=sqlite`. Guide: [`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md).

### Added
- **zent support — shared helper for examples**: `examples/_shared/zent_helpers.zig` provides `StoreEnv(Driver, Infos).open / inMemory / openWith` (RAII wrapper that replaces the open-driver + migrate + make-client dance) and `TestEnv(schemas).init / reset / deinit` (per-test in-memory SQLite with fresh migrations). Both `examples/zent-modulith/` and `examples/shopdemo-zent/` now use it; `examples/_shared/build.zig` runs the helper's own tests.
- **zent docs extended**: `docs/ZENT.md` adds `§6.1 Testing` (TestEnv pattern), `§6.2 Production: ConnPool` (production driver wrapping), `§6.3 Observability` (zent `sql_logger` → ZigModu logger adapter), and `§6.4 Transactions` (beginTx + savepoint). Shared helper callout at the top.
- **`examples/shopdemo-zent` runnable**: parallel of `examples/shopdemo/` using `zent` (ent-style schema-as-code ORM) instead of `zigmodu.data.sqlx`. Single `order` module with `Order` + `OrderItem` zent Schemas, `OrderStore` persistence, `OrderService` validation, and `OrderApi` exposing `POST/GET /api/v1/orders` plus `POST /api/v1/orders/{order_no}/items`. Demonstrates `docs/ZENT.md`'s orthogonal data-stack rule: each module picks one driver and does not mix or share transactions.
- **Completeness Phase 3 — distributed event bus wiring**: `DistributedEventBus` now actually routes through `Partitioner.route(topic)`, captures send failures in `DLQ` after `max_send_failures` threshold, drains DLQ via a retry fiber, and exposes `connectToNode` / `nodeId` / `clusterSize` for membership integration. `WAL.readFrom` is implemented so `replayFromWal` and `restoreFromWal` actually recover uncommitted entries. `ClusterMembership` keeps the partitioner ring in sync on join / leave / failure.
- **SQLx MySQL binary protocol hardening**: `mysqlFetchStringColumn` re-reads oversized values via `mysql_stmt_fetch_column` instead of silently truncating; `mysqlParseDecimal` / `mysqlParseDateTime` / `mysqlParseJson` validate input strictly (negative TIME allowed, fractional seconds `.[0-9]{1,6}`, JSON via `std.json.parseFromSlice`).
- **`examples/shopdemo` runnable**: `build.zig` / `build.zig.zon` / `src/main.zig` / `src/db/*` added; the single `order` module from `generated-sample/` is migrated with API compatibility fixes; `zig build run` starts the app and `GET /api/v1/orders` returns 200.
- **WorkerPool / EventBus observability**: `WorkerPool.WorkerPoolStats.toPrometheusFormat` renders pool stats as Prometheus text; `TypedEventBus` tracks `published_total` and `dropped_async_total` atomically with `publishedCount` / `droppedAsyncCount` getters.
- **Modulith QPS Phase 2 — async EventBus + WorkerPools**: `core.WorkerPool` (bounded queue, graceful stop, error isolation), `TypedEventBus.subscribeAsync` / `ThreadSafeEventBus.subscribeAsync`, `api.Module.RuntimeOptions.worker_count`, and per-module `WorkerPool` integration in `core.ModuleRuntime`. Includes cross-module pilot test and `max_worker_count = 128` guard (`error.ConfigurationError` for 0 or overflow).
- **Modulith QPS Phase 1 — per-module resource isolation**: `api.Module.RuntimeOptions`, `core.ModuleRuntime` (bulkhead + rate limiter + circuit breaker), `core.ModuleRegistry`, and `Application.getModuleRuntime()`. Thread-safe admission via `std.Io.Mutex`, overflow-safe quota validation, and full backward compatibility for modules without runtime options.
- **SQLx connection pool lifecycle**: per-connection `created_at`/`idle_since` timestamps, max-lifetime / max-idle-time eviction, FIFO waiter fairness, and `PoolMetrics` (acquired/released/created/closed/stale-evicted totals, wait time, max active/idle).
- **SQLx streaming cursor**: `Client.queryCursorEx(sql, args, .{ .mode = .streaming })` with driver-native streaming for MySQL (`mysql_use_result`) and PostgreSQL (`PQsendQueryParams` + `PQsetSingleRowMode`). SQLite falls back to buffered mode.
- **SQLx batch protocols**: `Client.batchInsertEx(table, columns, rows, .{ .mode = .protocol })` uses MySQL prepared-statement multi-execute and PostgreSQL `COPY ... FROM STDIN` (CSV). Falls back to multi-row `INSERT` SQL on failure or SQLite.

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.
- **SQLx**: Removed broken `withRows` helper from `data.zig` re-export (no in-tree callers; called `client.queryRows` without the `T` type parameter).

### Fixed
- **SSE Server lifecycle**: `http.sse` / `markSseResponse` sets `ctx.streaming` so Server does not double-`writeResponse` after the handler; `lastEventId(ctx)`; multiline `data:` splitting; `sendRetry` write-buffer alias fix.

### Added
- **zigmodu.ai Agent P0/P1**: `AiProvider.chatWith` + `tool_calls` parse; `SkillRegistry.toOpenAiFunctionsAlloc` / `dispatchAllowed` / `validateArgs`; first-class `ai.Agent` ReAct loop + `AgentHooks`/`AgentMetrics`; `chatStream` buffered shim; `MemoryStore` composite tenant/user keys + `dumpJson`/`loadJson`.
- **zigmodu.ai skill timeout skeleton**: `Tool.timeout_ms`, `SkillContext.deadline_ms` / `expired` / `checkDeadline`, `dispatchWith` → `error.ToolTimeout` (cooperative; not preemptive).
- **HttpClient.requestStream + AiProvider SSE chatStream**: chunked/content-length/EOF body streaming; OpenAI `data:` delta parse with buffered fallback.
- **MemoryStore file persistence + Agent tool timeout**: `saveToFile`/`loadFromFile`; `Agent.tool_timeout_ms` via `dispatchWith`.
- **HttpClient request wire**: auto `Host` + `Content-Length`; path+query; `https://` → `TlsNotSupported` (plain HTTP only, same posture as Vault/OTLP).
- **AI observability / RAG hooks**: `AgentAuditLog`; `Retriever` + `KeywordRetriever`; `Metrics.toPrometheusFormat` for provider and agent.
- **HttpClient HTTPS**: `https://` via `std.http.Client` (system CA, TLS 1.3); HTTPS `requestStream` incremental body read loop; finer transport errors (`TlsHandshakeFailed` / `DnsFailed` / `Timeout`).
- **Agent HITL + RAG wire-up**: `hooks.on_tool_request` / `ToolApproval`; optional `retriever` merges context into system prompt; scaffold `--with-agent` uses core `zigmodu.ai.Agent` + `AiProvider`.
- **AI stream tool_calls + quota**: `chatStream` accumulates streamed `delta.tool_calls`; `TokenQuota` per-tenant skeleton; scaffold `--with-aichat` uses `*AiProvider` + `chatStream` + shared quota; Agent scaffold persists `ai_agent_run`.
- **AiProvider HTTP status mapping**: `AuthError` / `RateLimited` / `UpstreamError` / transport errors.
## [0.14.17] - 2026-07-31

### Added
- **ComptimeRouter + catalog JWT/RBAC**: modules declare `pub const routes` + `mountAll`; `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`; `CatalogPermLoadInput{ sub, aud, roles }` for custom permission loaders.
- **HTTP ergonomics stack**: typed extractors, ProblemDetails/`respondErr`, scope middleware, Testkit, HTTP/resilience profiles, SSE (`http.sse` / `sse_routes`), OpenAPI param merge, outbox/idempotency barrels.
- **HTTP/2 / gRPC / Kafka depth**: H2 stream states + pump, PRIORITY scheduling, h2c Upgrade, WINDOW_UPDATE/SETTINGS, `Http2Tls` ALPN sidecar; ConnWriter write coalesce and GOAWAY/RST isolation; Kafka consumer-group assignors (incl. cooperative_sticky) + `acknowledgeRevocation`.
- **OTLP/HTTP exporter**: `OtlpExporter.exportSpans` POSTs JSON over plain `http://` with retries (`https://` → `OtlpTlsNotSupported`).

### Changed
- **Legacy JWT middleware**: `rbacJwtMiddleware*` / `jwtAuth*` write **`auth_info` only** (safe with ComptimeRouter `user_data` State); new apps prefer catalog Path A.
- **x402 payment verify**: fail-closed by default; inject `PaymentVerifier` / `verifyPaymentAllowAll` only for explicit dev paths.
- **Docs / AI guides**: `AGENTS.md` canonical agent entry (doc map + DO/DON'T); `CLAUDE.md` / `AI_METHODOLOGY` / `BEST_PRACTICES` / `ROUTE_TABLE` §7 aligned to Path A + ComptimeRouter.

### Fixed
- **OpenAPI JSON strings**: escape quotes/backslashes/control chars in title/version/description/summary via `emitJsonStr`.

## [0.14.16] - 2026-07-24

### Changed
- **SQLx circuit breaker Io handle**: `sqlx/breaker.CircuitBreaker` no longer stores `io`. `allow` / `recordSuccess` / `recordFailure` take `io: std.Io` from the caller (`Client` passes `self.io`), so futex waits always use the live Io handle instead of a copy captured at `Client.init`.

## [0.14.15] - 2026-07-24

### Fixed
- **SQLx `Client.open` pool self-pointer dangling after by-value return**: `ensurePool` stored `ConnPool.client = &local` then `return client` moved the struct, leaving `pool.client` pointing at the dead temporary (SIGSEGV at low addresses like `0x70` on next pool use). `open` no longer creates the pool; call `warmPool()` on the final `*Client` for idle warmup. `ensurePool` always rebinds `pool.client = self`.

## [0.14.14] - 2026-07-24

### Fixed
- **SQLx `Client.ensureBreaker` race / segfault**: `cb` was a lazily initialized `?CircuitBreaker`. Concurrent first-touch from worker fibers could tear the optional write (null/`Io.vtable` → segfault on next `allow`/`record*`, often at low addresses like `0x1a0`). `cb` is now a non-optional `CircuitBreaker` eagerly created in `Client.init`; `ensureBreaker` removed.

## [0.14.13] - 2026-07-24

### Fixed
- **SQLx PostgreSQL SafeAllocator panic (alloc=N+1 / free=N)**: `PostgresConn.stmt_cache` stored `allocZ` (`[:0]u8`) names as `[]const u8`, so LRU eviction / close freed without the sentinel. Cache values are now `CachedStmt([:0]u8)`. Same coerce bug fixed in `queryCursorFn` (`if (args.len==0) slice else [:0]`). `bufPrintZ` reserves the last byte for `\0`. `pgDecodeNumeric` no longer writes through a fixed `[256]u8` stack buffer (heap `ArrayList` + safe `dscale`/`lead_zeros` math).

## [0.8.2] - 2026-05-10

### Fixed
- **SecretsManager**: Inverted priority comparator (`<=` → `>=`) so env > file > vault > default works correctly.
- **SecretsManager**: Double-free in `setWithPriority` when replacing entries — old key freed before `HashMap.remove`.
- **ContractTest**: Double-free in `verifyContract` status check — `allocPrint` strings freed by both local `defer` and `deinit`.
- **LoadShedder**: `now_ms = 0` replaced with `Time.monotonicNowMilliseconds()` — rolling window now advances correctly.
- **Migration parse test**: Isolated with `ArenaAllocator` to prevent allocator-state corruption from prior tests.
- **Version sync**: All version strings unified to v0.8.x across `build.zig.zon`, `main.zig`, and `CHANGELOG.md`.

### Added
- **Graceful shutdown**: `Server.in_flight` request counter + `withGracefulDrain()` wired into `Application.run()` (30s drain timeout, SIGINT/SIGTERM handlers).
- **Prometheus /metrics**: `PrometheusMetrics.registerMetricsRoute()` — one-line `/metrics` in Prometheus text format.
- **Health check context**: `HealthCheck.check_fn` now takes `?*anyopaque` context; `databaseCheck`, `redisCheck`, `diskSpaceCheck` work with real connections.
- **Config validation**: `ExternalizedConfig.validateRequired()` returns missing keys for clear startup errors.
- **ThreadSafeEventBus**: `ThreadSafeEventBus(T)` wraps `TypedEventBus` with `std.Thread.Mutex`.
- **E2E tests**: Server middleware chain + error path, Application lifecycle smoke test, in-flight counter tracking.
- **API Migration Guide**: `docs/API-MIGRATION.md` — Simplified.zig → Application migration path.

### Changed
- **root.zig**: Reorganized from flat 297-line list into 14 named sections with clear category headers.
- **Emoji logs**: Removed all emoji prefixes from production log messages in Application, Lifecycle, ModuleValidator, docs.
- **README**: Updated test count (338 passed, 0 failed), honest production readiness score (84/100), experimental markers on gRPC/Cluster/DistTx/Plugin/WebMonitor/HotReload.
- **CI**: Removed broken `--test-filter` flags from lint job (unsupported by build.zig).

## [0.8.0] - 2026-05-08

### Added

#### Production Hardening (Phase 7)
- **Database Migrations** (`src/migration/Migration.zig`) — Flyway/Liquibase-style versioned migrations with SHA256 checksums, rollback support, status tracking (pending/applied/failed), DDL generation, and filename parsing (`V{timestamp}__{description}.sql`). 10 tests.
- **Secrets Manager** (`src/secrets/SecretsManager.zig`) — Multi-source secrets with priority resolution (env > file > vault > default). Supports K8s/Docker secrets, Vault placeholder, JSON/env content loading, getInt/getBool/getOrDefault/listKeys/exportAsEnv. 10 tests.
- **Docker Support** (`Dockerfile` + `docker-compose.yml`) — Multi-stage build (zig:0.16.0 → alpine:3.21), non-root user, health check. Compose stack includes PostgreSQL 17, Redis 7, Vault 1.18 (profile), Jaeger 1.65 (profile).
- **Timestamp Audit** — Verified all 16 production sites use `Time.monotonicNowSeconds()`. 9 remaining `timestamp=0` in test-only code.

#### Network Verification & Integration (Phase 8)
- **Idempotency Middleware** (`src/http/Idempotency.zig`) — `IdempotencyKey` header-based request deduplication with TTL store, automatic eviction, purge-expired. 5 tests.
- **Module Interaction Verifier** (`src/core/ModuleInteractionVerifier.zig`) — Spring Modulith `verify()`-style architecture validation. Checks circular dependencies, self-dependency, max dependencies, generates ASCII violation reports. 6 tests.
- **OpenAPI Generator** (`src/http/OpenApi.zig`) — Generates OpenAPI 3.0/3.1 JSON from route metadata. Supports endpoints, tags, path/query/header params, response schemas. 4 tests.

#### Modulith Deep Features (Phase 9)
- **gRPC Transport** (`src/core/GrpcTransport.zig`) — Full gRPC service registry with method registration, 16 standard status codes with HTTP mapping, proto file parser (service/method extraction), client stub with endpoint management. 6 tests.
- **Kafka Connector** (`src/core/KafkaConnector.zig`) — Producer with send/sendBatch/flush/close + per-topic statistics, Consumer with subscribe/unsubscribe/getSubscriptions, EventBridge for Kafka ↔ DistributedEventBus integration. Configurable acks, compression, auto_offset_reset. 7 tests.
- **Saga Orchestrator** (`src/core/SagaOrchestrator.zig`) — Automatic compensation with reverse-order rollback on step failure. Saga registration, step logging (started/completed/failed/compensated), instance tracking, active instance listing. 5 tests.
- **Contract Testing** (`src/test/ContractTest.zig`) — Consumer-Driven Contract (Pact-style) verification. Validates HTTP status, response body contains, and response headers against defined contracts. Generates ASCII pass/fail reports. 6 tests.
- **CI/CD Pipeline** (`.github/workflows/ci.yml`) — GitHub Actions workflow with matrix build (ubuntu + macOS), caching, fmt check, full test suite, architecture validation, security scan, benchmarks (ReleaseFast), multi-platform Docker build (amd64/arm64), GitHub Release with artifacts.

### Changed
- **`root.zig`** — Added 30+ new exports for Phases 7-9 modules in ADVANCED API section
- **`tests.zig`** — Added compilation gates for all new modules
- **`AGENTS.md`** — Updated with all new module conventions, middleware patterns, migration/secrets/saga/Kafka/gRPC usage examples
- **`README.md`** — Comprehensive update with new features, project structure, Docker quick start
- **`docs/API.md`** — Added API references for Migration, Secrets, Idempotency, OpenAPI, gRPC, Kafka, Saga, ContractTest
- **`docs/COMPLETENESS_REPORT.md`** — Updated scores: 93/100 production readiness
- **`docs/EVALUATION_REPORT.md`** — Final evaluation with Phase 7-9 coverage

### Test Results
- **282 passed**, 5 skipped, 2 failed (pre-existing)
- +53 new tests across Phases 7-9
- All timestamp-related bugs resolved; no `timestamp=0` in production code

## [0.7.0] - 2026-04-23

### ⚠️ Breaking Changes

- **`ModuleInfo.init()`** now takes 3 arguments `(name, desc, deps)` instead of 4. The `ptr` field is now `?*anyopaque` (nullable, default `null`). Update all call sites.
- **`ModuleInfo.init_fn` / `deinit_fn`** signatures changed from `fn(*anyopaque)` to `fn(?*anyopaque)`.

### Added

- **`core/Time.zig`** — Centralized monotonic time utility using `clock_gettime(CLOCK_MONOTONIC)`. Replaces all hardcoded `const now = 0` throughout the codebase (16 occurrences across 10 files).
- **`root.zig`** — Exports `time` module as `zigmodu.time`.
- **3 new tests** for Time.zig (monotonicity, positive values).

### Fixed

- 🔴 **Timestamp system**: All time-dependent subsystems now use real monotonic time:
  - `CircuitBreaker` — OPEN→HALF_OPEN timeout transition now works
  - `RateLimiter` — Token bucket refill now works with real elapsed time
  - `SlidingWindowRateLimiter` — Window cleanup now works
  - `CacheManager` — TTL expiration now works
  - `DistributedTracer` — Span durations now have real values
  - `TaskScheduler` / `Cron` — Scheduling now uses real time
  - `HttpClient.Connection.isAlive()` — Idle timeout detection now works
  - `ClusterMembership` — Health check timeout detection now works
  - `sqlx/breaker.zig` — Circuit breaker now works

- 🔴 **`ModuleInfo.ptr` UB**: Eliminated `undefined` initialization. Ptr is now nullable `?*anyopaque` with default `null`. Tests no longer trigger undefined behavior.

- 🔴 **Version inconsistency**: Unified version to `0.7.0` across `build.zig.zon`, `main.zig`, `CHANGELOG.md`, and `AGENTS.md`.

- 🔴 **build.zig test paths**: Replaced hardcoded macOS Homebrew paths with dynamic detection via `detectPqPaths()`/`detectMysqlPaths()`. Tests now work on Linux/CI.

- **`ApplicationModules.register()`**: Now invalidates cached `sorted_order` to prevent stale topological sort after module set changes.

### 修一条长期潜伏的 flake：等 `seen` 却读 `total`，两个 monotonic 写之间没有 release/acquire（**破坏性：否**）

Ubuntu CI 在修掉 `poll` 的 ABRT 之后露出第二条红（此前被 ABRT 提前打断、根本没跑到）：
`runtime: a timer's delivery to a pooled worker arms its ready token` →
**`expected 41, found 0`**。这条测试早于本轮（`d2a1cd6`），是长期潜伏的 flake：

worker 里先 `seen.fetchAdd(1, .monotonic)` 再 `total.fetchAdd(msg, .monotonic)`，而测试
**等的是 `seen`、读的是 `total`**。两个写都是 monotonic，读者在 x86 上可以合法地看到
`seen=1` 而 `total` 尚未传播——测试就是在负载较高的 runner 上踩到这个交错。

修法：把**最后写的那个计数器**作为发布点（`total.fetchAdd(msg, .release)`），测试改为
**等 `total`**（`Published(total, 41)`）再断言 `seen == 1`。这样 acquire 到 `total` 就必然
看到 `seen` 的增量，而测试原本要抓的"定时器投递没上 ready token"仍然抓得住（不修的话
`total` 永远到不了 41 → `WaitTimeout`）。

验证：本地该测试连跑 6 次稳定通过，`runtime.` 全组 162/162。顺带扫了同类形状——
`src/runtime/runtime.zig` 里其余 `waitUntil(Published(…))` 都是"等同一个计数器再断言它"，
不存在第二处。
