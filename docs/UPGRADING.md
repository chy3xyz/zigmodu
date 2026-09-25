# UPGRADING — 逐版本升级注意

## 弃用别名与删除计划

**回答的是一个具体问题：「这个旧名字我什么时候必须改完？」** 此前每条弃用只写"保留为别名"、
不写删除时点，消费方每次升级都要重新确认一遍该用哪个 —— 那是纯成本。

**统一口径：弃用别名**不早于 1.0** 删除。** 依据是本仓库的兼容性原则（破坏性变更保留给 1.0），
所以在那之前**任何小版本升级都不需要为下面这些名字动代码**；1.0 那次会一次性删掉，并在
本节的表格里逐条标出来。

| 弃用名 | 现在的名字 | 计划删除 |
|---|---|---|
| `ctx.paramPath` | `ctx.nestedParam` | 不早于 1.0 |
| `Simplified` API（整块入口） | `Application`（见 [`API-MIGRATION.md`](API-MIGRATION.md)） | 不早于 1.0 |

新增弃用项要同时做三件事（否则这张表会变成第二个没人维护的清单）：
1. 在**代码**的文档注释里写明它已弃用并指向新名；
2. 在**本表**加一行，删除列不要留空；
3. 在**它自己那版**的条目里指回本节。


> 每条变更标注 **Breaking?** / **影响面** / **一行改法**。
> 只记"会咬人"的：行为变化、公开签名变化、默认值变化、需要动手删代码的地方。
> 完整变更列表见 [`../CHANGELOG.md`](../CHANGELOG.md)；框架级迁移（Simplified → Application）
> 见 [`API-MIGRATION.md`](API-MIGRATION.md)。

自查命令（升级后先跑这两条）：

```bash
zig build test                          # 框架自测必须默认 -Ddb=all
bash scripts/check-production.sh        # 分层门禁（含热路径裸 catch、信封泄漏）
zmodu ci                                # 业务项目：build + fmt + verify + audit + deadcode
```

---

## v0.33.6（未发布）

> **本版无破坏性变更**：新增 `zigmodu.TomlLoader`、`ScopedContainer` 的三个方法、`zigmodu.runtime.affinity`
> （CPU pin 原语），删除一个从没实现过的空壳 `TransactionalEvent`。**第 31 批也是无公开 API 变化的一批**
> （一个内部存储层 + 两组实测），但它的结论会改变你读 §12 的方式 —— 见本节最后一条。
> 另有两条**消费者应当知道的口径**：① `PrecisionTimer` 的 10 µs 中位数界是**宿主的**、不是机制的 ——
> 共享 runner/容器上要按下面的表调 knob；② 弃用别名表里的删除时点仍是"不早于 1.0"。

**新增公开 API（additive，无破坏性）**

- **`zigmodu.TomlLoader`** —— 上一版补了 `ConfigManager` 的导出，但 TOML 还是读不了（loader 本身没导出）。
  现在 `var loader = zigmodu.TomlLoader.init(allocator); try loader.loadFile("app.toml", &config);`，
  `[server]` + `port` 落成 `server.port`，类型保留（`getInt`/`getBool`/`getFloat` 可用）。
  **一行改法**：以前只能自己 `@import` 框架内部文件路径的，改从 `zigmodu` 导入。`root.zig` 的
  "文档里出现的符号必须可导入"测试里加了一条 TOML 端到端（文件 → `loadFile` → 读值），漏加导出让测试红。
- **`ScopedContainer.registerBorrowed` / `remove` / `serviceCount`** —— 补齐与 `Container` 的差集。
  **语义要点：改/查两半的穿透规则不同** ——`get`/`contains` 查本作用域再下沉 `parent`；
  `register`/`registerBorrowed`/`remove`/`serviceCount` **只作用于本作用域**。`remove` 永不下沉：
  作用域注销一个共享服务，会让 parent 容器的其它读者拿到已销毁的实例。`serviceCount` 只数本层
  （同名可在两层都注册，跨层计数会重复）。**一行改法**：以前为了"改本层"而绕开 `ScopedContainer`、
  直接对 `Container` 动手的代码可以收回来。
- **`zigmodu.runtime.affinity`** —— `supported`（comptime 常量）与 `pinCurrentThread(cpu_index)`：
  Linux 走 `sched_setaffinity(0, …)`（pin 的是**调用线程**），**macOS 与 Windows 返回 `error.Unsupported`**，
  平台有 API 但内核拒绝时返回 `error.PinFailed`。**它绝不假报成功** —— 这是刻意的：
  "静默忽略的声明是比没声明更坏的失败模式"。**注意这不等于 `spawn` 上有了 `.affinity` 字段**：
  那个声明判定为**缓做**，阻塞点是 dedicated 路径还没有父子启动握手（见 CHANGELOG 第 30 批）。

**删除：`src/core/TransactionalEvent.zig`（249 行的空壳）** —— 上一版已判定它不是公开 API（`root.zig`
从未导出、`docs/API.md` 那节已改为 internal）。这次连文件一起删掉，因为留着它就是留一份"看起来能用"的假实现
（`stageEvent`/`addEvent` 都是 `_ = event;`）。**影响面**：只有**越路径**导入框架内部文件的代码
（`@import("zigmodu/src/core/TransactionalEvent.zig")`）会**编译错**；公开面没有任何变化。
**一行改法**：`zigmodu.outbox.*`（真实 outbox）或 `zigmodu.SagaOrchestrator`。

**测量口径（非破坏，但会改变你在别的机器上看到的数字）：`PrecisionTimer` 的 10 µs 界是宿主相关的。**
它的用例曾在 GitHub 的 macOS runner 上红两条，原因是那台机器的 `nanosleep` **比自旋窗口还粗**：

| 宿主 | `nanosleep(100 µs)` 实际迟到 | `nanosleep(500 µs)` | 出厂配置 @1 ms 的 p50 |
|------|------|------|------|
| 本仓开发机（Apple Silicon macOS） | ~55 µs | ~257 µs | **0 ns** |
| GitHub `macos-latest` | **+818 µs** | **+4 031 µs** | **+3 531 000 ns** |

等待循环睡的是 `remaining - spin_window_ns`，只有这次唤醒落在窗口内，自旋才有 deadline 可收口；一旦内核把
唤醒推过 deadline，剩下的延迟就全是宿主的。所以**出厂的两个 knob（窗口 200 µs / 分块上限 500 µs）是按本仓
开发机的过冲梯子定的**。**一行改法**：把 `PrecisionTimer` 搬到容器/共享 CI/云主机上之前，先跑一次它自己的
测量用例（每个用例都会打印 min/p50/p99/max 与 spun 占比），粗粒度宿主上把 `spin_window_ns` 调大
（或设 `0` 明确表示不要这个精度）。`Runtime` 的 5 ms 时间轮不受影响。详见 `docs/RUNTIME.md` §12.15。

**第 31 批（同样无公开 API 变化，但有两件你应当知道的事）**

- **`batch` 的默认值保持不变，而且现在有实测依据。** `docs/RUNTIME.md` §12.16 把设计期那句
  "批量 16 是起点不是结论"收口了：6 个点 × 3 种形状、每点 27 轮，结论是 **保持 16**
  （1 是唯一被数据否掉的默认值；8/16/32/64 落在同一片噪声带里，16 是这片平台上最小的一点）。
  顺带量出一条你会更用得上的：**池化 worker 的延迟尾巴属于 `idle_wait_ms = 1` 的 park 轮询，不属于
  `batch`** —— `batch` 从 1 调到 64，p99 一点没动（三个形状、每个点都是 ~1 ms）。所以想压 p99 就别动
  `batch`；反过来，"不饿死"的上界**就是 `batch` 本身**（实测：一个永远忙的 worker 最多耽误对端
  一个 batch 的消息数，与宿主快慢无关）。**你的代码不需要改任何东西**，除了"别再照 §12.9 的说法
  把 16 当成未验证的先验"。
- **投递轨落盘：盘上那一半有了，进盘那一半没有。** 新增 `src/runtime/delivery_log.zig`（分段日志：
  magic + 显式版本 + 每帧 CRC32 + 撕裂尾部可判可修 + append 零分配）。它**尚未从 `runtime.zig`/
  `root.zig` 导出，也还没有任何消费者** —— 把一条投递记录变成字节的 **codec 契约**与 recorder 侧的接线
  **仍未做**，所以 `Runtime Replay` 现在**依然不能跨进程/跨重启**（§13.5 的边界没变，只是 Q4 第 2 档
  从"未动"变成"存储层已落地"）。不要按"已经能落盘重放了"去设计你的回测。

---

## v0.33.4 + v0.33.5（均已发布）

> 本节标题此前一直写着「（未发布）」，而 `v0.33.4`/`v0.33.5` 的 tag 早就推了 —— 下面这些内容**是已发布**的。
> 原因记在这里免得复发：`scripts/release.sh` 只 bump 版本引用，**不碰 `docs/UPGRADING.md`**，
> 所以"（未发布）"这层标签是纯手工维护的；发布后请把它改成版本号（下一个版本另起一节）。

> **本版有 2 处破坏性变更（都是编译错）**：口令校验不再返回裸 `bool`、
> `Middleware.attachIdentityBestEffort` 改成 `!void`。另有 8 处**行为变化**值得确认：Redis 不可达时不再
> 静默返回 `0`/`false`、表单解析超限从 200 变 400、`CachedConn` 的坏缓存条目从 `DatabaseError` 变成
> "缓存未命中 + 修复"、`BufferPool` 的取消语义、认证中间件对"我们这侧失败"改回 500、API key 比较改恒定
> 时间、MySQL 的 NULL 元数据不再读成"零行"。
> 逐条背景见 [`../CHANGELOG.md`](../CHANGELOG.md) 的 `[Unreleased]` 段。

**破坏 ②：`Middleware.attachIdentityBestEffort` 由 `void` 变成 `!void`。** 它以前在构建 `roles` 属性失败时
**静默返回**，留下一个"有 `user_id`/`tenant_id`、没有 `roles`"的身份继续处理请求（role gate 一律 403，
而把"无角色"当匿名看的 handler 则行为未定义）。现在先把 roles CSV 建好再写任何属性，任一写失败即
`return err`（fail-closed）。
**Breaking?** 是（编译错）· **影响面**：直接调用它的中间件代码（仓库内只有本库自己） · **一行改法**：
`attachIdentityBestEffort(ctx, claims, alloc);` → `try attachIdentityBestEffort(ctx, claims, alloc);`。
用 `http.addMiddleware(http.jwtAuthFromCatalog(...))` 这类常规接线的消费者**不需要改**。

**行为变化（非破坏）⑤：认证中间件不再把"我们这侧出错"答成 401。** `jwtBackend`、旧路径
`jwtAuth*`、`authFromCatalog` 与 `security.AuthMiddleware` 的 `verifyToken` 失败以前一律 401（或
`false`）。现在 **token 级失败**（签名/过期/算法/格式）仍是 401；**我们这侧的失败**（分配失败、
自定义 `AuthBackend` 的存储故障）→ **500** + warn 日志；**未知 `kid`** 仍是 401（`kid` 由客户端控制，
答 5xx 等于给未认证调用者一个制造 5xx 的开关）但会打一条 warn，让运维看到"密钥轮换漏了一把"。
`authFromCatalog` 在 `.public`/`.optional` 路由上，我们这侧的失败现在**让请求失败**（以前是记一条日志
后当作匿名继续）。若你的客户端把 500 当成"重试即可"，这正是想要的；若你的监控按 401 统计失败登录，
现在它不再包含我们的内部故障。

**行为变化（非破坏）⑥：API key 比较改为恒定时间。** `security.ApiKeyAuth.validateKey` 不再用
`std.mem.eql`（实测"错在第一个字节"与"错在最后一个字节"的耗时差约 **3560×**；改后差 0.8%）并且不再
提前返回。语义不变，只是耗时不再泄漏匹配长度。
> `ApiKeyLoaderConfig.loader` 的类型仍是 `*const fn ([]const u8) bool`，**存储故障与"key 不存在"同形**；
> 文档现在要求 loader 自己 fail-closed 并旁路上报。计划改成 `anyerror!bool`（与 `PermissionLoader` 对齐），
> 但那是公开字段的破坏性变更，本版**没有**做。

**行为变化（非破坏）⑦：`BufferPool.release` / `available` / `stats` 的锁等待不再可被取消。** 以前取消即
返回：`release` 丢掉缓冲区（`allocated` 永久虚高 → 以后报**假** `PoolExhausted`），`available`/`stats`
给出伪造读数（会被 scrape/健康检查当成事实）。`acquire` 仍然返回 `error.Canceled`。

**破坏：`RedisCluster.init` 多一个 `io` 参数。** `redis.RedisCluster.init(allocator)` →
`init(allocator, io)`。原因：它内部用 `std.testing.io` 建节点，而 `std.testing.io` 在非 test 构建里是
`@compileError("not testing")` —— 所以**此前任何调用 `addNode` 的应用都编译不过**（实测：一个普通
`main` 调 `init`+`addNode`，修前 `error: not testing`，修后编译并真实连库成功）。
**Breaking?** 是（编译错）· **影响面**：用到 `RedisCluster` 的应用（本仓库内无调用点）· **一行改法**：
`var c = RedisCluster.init(alloc);` → `var c = RedisCluster.init(alloc, io);`（`io` 就是你启动时拿到的那个
`std.process.Init` 的 io；`addNode` 签名不变）。

**行为变化（非破坏）：`SkillRegistry.register` 对重复名字是"替换"且超容量不再 panic。**
以前 `initCapacity` 用完后再注册会 `panic: integer overflow`（不是报错），重复注册还会漏掉被替换工具的
参数数组。现在重复名**替换**（与原 docstring 一致，"注册即设置"的 40+ 处调用不受影响），超容量走正常的
可失败分配路径并如实返回错误。若你的代码依赖"超容量必定 panic"或"重复注册保留旧工具"，需要改。

**破坏：无类型 `EventBus(T).subscribe` 现在返回错误。** 它以前是 `void`，却用 `getOrPutAssumeCapacity` /
`addAssumeCapacity` 在"只记了日志"的预留上写入 —— 预留不足时会**写越界**（同一事件类型第 5 个回调就会
触发，因为初始预留是 4）。现在与同文件的 `TypedEventBus`/`ThreadSafeEventBus` 一致，是 `!void`
（`docs/API.md` 一直就是这么写的）。
**Breaking?** 是（编译错）· **影响面**：直接调 `bus.subscribe(...)` 的应用代码 · **一行改法**：
`bus.subscribe(MyEvent, handler);` → `try bus.subscribe(MyEvent, handler);`（模块监听器走
`ApplicationModuleListener.subscribe()`，那个签名本来就是 `!void`，不需要改）。
另：**同名 `ProviderRegistry.register` 不再立刻释放被替换的 provider**（改为 retired，推迟到 `deinit`；
`retiredCount()` 可观测），所以旧租约继续把反馈写进它自己的池，而不是串到替换者身上。若你的代码依赖
"替换后旧条目立即释放"，这条是行为变化；若你只是热加载同名配置，这条修掉的正是 use-after-free。

**行为变化（非破坏，但你的 dump 可能被判为损坏）**：`MemoryStore.loadJson` / `loadFromFile` 现在**拒绝**
一份作用域不可用的记忆 dump（`error.InvalidMemoryScope`），而不是把缺失或类型错误的 `tenant_id`/`user_id`
静默当成 `0`。这条修的是一个**安全**问题：`0` 在 `recall(prefix, 0, …)` 里的含义是 **"any scope"**，所以
一份损坏的 dump 会把那些行变成任何租户都读得到。**由本框架自己写出的 dump 不受影响**（`dumpJson` 一直把
这两个字段写成整数，显式写出的 `0` 仍然合法），需要动作的只有手工编辑过、被截断或来自别处的文件 —— 它们
现在会整份失败并逐条 warn 出下标/字段/实际类型，请修好那一行（或删掉该条目）再加载。
**Breaking?** 否（`loadJson` 的声明签名未变，只是推断错误集多了一个成员；仓内没有按错误名分支的调用方）。

**行为变化（非破坏，但会改变晚期注册的行为）**：`PrometheusMetrics` 的注册现在**在首次抓取后被封**：
`toPrometheusFormat` 一跑（或你显式 `freeze()`），之后所有 `createCounter`/`createGauge`/`createHistogram`/
`createSummary`/`createCounterFamily`/`createHistogramFamily` 都返回 **`error.Frozen`** 且不插入任何东西。
原因：注册级容器是无锁遍历的，而 `create*` 会 `put`（rehash 会释放遍历正走着的 bucket 数组）——与上一批
修掉的 per-family `render` 是同一个 use-after-free。**树内的注册全是启动期接线**（`productionProfile`、
`MetricsBridge.init`、`OutboxConsumer.setMetrics`、`AutoInstrumentation.init`、`ModuleMetricsCollector.init`），
请求线程创建的 per-label series 走 `CounterFamily.get`（有锁），所以正常应用不受影响。若你在**运行期**
懒创建指标，请把它移到第一次抓取之前，或改用 `getCounter`/`getGauge`（追加 label 值）而不是 `create*`。
`freeze()`/`isFrozen()` 是新增的公开方法。
**注意这层封条不是互斥**：它把"启动期注册"从假设变成会报错的契约，但在封条落定前通过检查的 `create*`
仍可能与第一次抓取交错；真正的互斥需要一把锁，本版没有加。

**行为变化（非破坏）⑩：同名重复的 `create*` 现在是错误，抓取后的注册也是错误。** `PrometheusMetrics` 的六个
`create*` 现在返回 `CreateError`（`error.Frozen` | `error.DuplicateName` | `std.mem.Allocator.Error`）：
① 注册（第一次抓取或 `freeze()` 之后）被封 —— 晚期注册返回 `error.Frozen` 且不插入任何东西；
② **一个名字在整个 exposition 命名空间里只能用一次** —— 不只是"同一种类注册第二次"，**跨种类**（counter 与
gauge 同名）与 **histogram 的生成名**（`createHistogram("x")` 之后再 `createCounter("x_count")`）都会返回
`error.DuplicateName`。以前这些都会被接受，然后渲染出 Prometheus **整份拒收**的抓取；以前同种类重复注册还会把
第一个对象留在堆上没人释放、把已发出的旧句柄变成孤儿。若你以前依赖"重复注册就换一个"，请改成在首次抓取之前注册一次，或用
`getCounter`/`getGauge` 追加 label 值。`Counter.labels`/`Gauge.labels` 与 `Summary` 的
`quantiles`/`max_age_seconds`/`age_buckets` 三个"声明了没人读"的字段已删除。

**行为变化（非破坏）：`WebSocketClient` 的写失败不再叫 `NotConnected`，且 pong 失败即断连。**
`sendText`/`sendJson` 的推断错误集现在是 `{error.NotConnected, error.WriteFailed}`：前者只表示"这个客户端已经
已知是死的、一个字节都没写"，后者是真正的写失败（真实原因记在日志里）并会**立刻**把 `is_connected` 置 false。
若你的代码穷举匹配旧错误集，会**编译错**（响亮）；若你把任何失败都当"对端断了"处理，那条路径现在的语义更准确。
另外：pong 写失败现在会让读循环在下一次检查时退出，而不是一直等到一个读错误。

**行为变化（非破坏）：集群的节点回调是**边沿触发**的。** `on_leader_change_cb` 只在 leader **真的变化**时触发
（以前每个 `.leader_election` 事件都触发，即使 leader 没变）；`on_node_leave_cb` 只在从"在役"
（`.healthy`/`.suspect`）转出去时触发一次（以前按状态触发，一个已宣告失败或已 `.leaving` 的对端再说一次再见会
**宣告两次**）。与既有契约一致：**一次 `leave` 对应一次 `join`**。如果你的回调以前依赖"每次选举心跳也来一次"，
那正是这条要修掉的。

**行为变化（非破坏）：集群恢复现在会触发 `on_node_join_cb`。** `ClusterMembership` 以前只在失败/`leave` 时发
`on_node_leave_cb`，恢复只翻状态、不发回调。现在**一次 `leave` 对应一次 `join`**（`join` 是 "这个 peer 是你应当持有
状态的成员"，是 **upsert** 而不是"首次见到"）；`.suspect` → `.healthy` 两个方向都**不发**（没有 `leave` 被宣告过）。
如果你的回调在 `join` 时建了每对端状态，这条修掉的正是"建了却没人拆/拆了却没人建"的不对称。

**行为变化（非破坏，测试工具）：`test.IntegrationTest.InstrumentationContext` 改为原地构造且不可拷贝。**
`init(allocator) !InstrumentationContext` → `init(self: *InstrumentationContext, allocator) !void`（先
`allocator.create` 再原地构造），因为旧实现把 `metrics`/`tracer` 在栈上建好、把指针交给 instrumentation、再**按值**
返回 —— 那个指针指向已失效的栈帧。只影响直接用这个测试工具的类型（`IntegrationTest.instrumentation` 字段也变成
`?*InstrumentationContext`）。

**新增公开 API（additive，无破坏性）**：`zigmodu.Params`、`zigmodu.ScopedContainer`、
`zigmodu.SlidingWindowRateLimiter`、`zigmodu.ConfigManager` 四个符号以前**只存在于 `src/` 里、没有公开导入路径**
（文档写了它们但消费者 import 不到），现在从 `root.zig` 再导出，文档路径同步改正。
`zigmodu.TransactionalEvent` **不再**是公开 API（那一节从文档里删掉了）：它是个空壳，真身是 `zigmodu.outbox.*` 与
`zigmodu.SagaOrchestrator`。另新增 `zigmodu.runtime.PrecisionTimer`（亚毫秒 deadline 队列，调用方提供缓冲、
类型内零分配；不要用它替代普通定时器 —— 10 ms 以上的 deadline 仍旧用 scheduler 的 wheel，后者几乎不花 CPU）
与 `RaftTransport.connectTimeout`（POSIX 有界 dial）。
**顺带一条给所有人的警告**：`IpAddress.ConnectOptions.timeout` 在本工具链上会让进程**直接 abort**
（`std/Io/Threaded.zig` 里的 `@panic("TODO implement netConnectIpPosix with timeout")`，实测 `exit=134`），
所以既不要传它、也不要指望它 —— 要界就用 `connectTimeout`。

**行为变化（非破坏）⑨：一批"取消被当成成功/默认值"的路径改成等待或报错。** 涉及 `EventBus`
（`publish`/`unsubscribe`/`subscriberCount`/`publishedCount` 改不可取消的等待；**`subscribe`/`subscribeAsync`
现在会返回 `error.Canceled`** —— 以前它们**返回成功却没注册**）、`EventStore`
（`getVersion`/`SnapshotStore.load` 改等待；**并且修掉了 `replayFromSnapshot` 只读一次 256 条事件、
长流静默丢尾部**）、`cache`（`Lru.set` 现在会返回 `error.Canceled`，`delete`/`clear`/`size`/`get` 改等待）、
`Runtime.shutdown`/`Mailbox`（关停与唤醒不再被取消吞掉）、`redis` 的池释放/逐出（池槽不再永久丢失）、
`ai` 的 `key_pool.onError`/`onSuccess`、`memory.remember`/`forget`/`count`、`skill.register`/`get`/`count`/`names`、
`audit.record`、`quota.used`/`remaining`。**错误集变化**（用 `try` 的调用方不受影响，只有穷举错误集匹配
需要加/改一支）：`Lru.set`、`EventBus.subscribe(Async)` 增 `error.Canceled`；**`src/ai/*` 里那批自造的名字
已经删掉** —— `MemoryStore.remember` 的 `error.LockFailed`、`SkillRegistry.register` 的
`error.RegistryLockFailed`、`Quota` 的 `error.QuotaLockFailed`、`AiProvider` 的
`error.RateLimitLockFailed` 全部换成 `error.Canceled`（`std.Io.Mutex.lock` 唯一的错误就是它；
把取消说成"锁机制失败"是撒谎）。**按名字 `catch` 这些旧标签的代码会编译不过**（仓内没有，外部可能有）。
**结构变化**：`AgentAuditLog` 新增公开字段 `owned: []bool`（用字面量构造会编译不过；请用
`AgentAuditLog.init`）。另外 `Preflight` 的失败计数改为**先计数后记录**，所以"有致命失败却
`report.ok() == true`"这条不再可能。

**行为变化（非破坏）⑧：MySQL 的 `NULL` 结果集元数据不再被读成"零行"。** 语句有字段却拿不到元数据时
（libmysql 的分配失败）以前返回空结果集，现在返回映射后的错误；`field_count == 0` 这条真实子情形仍是
空结果集（记一条 debug 日志）。

**破坏：口令校验返回错误联合。** `PasswordEncoder.matches` 与 `SecurityModule.verifyPassword` 由
`bool` 变成 `PasswordError!bool`（`error{MalformedStoredHash} || std.mem.Allocator.Error`）。
以前**存储哈希不可解码**或**解码时分配失败**都被答成"口令不匹配"，调用方只能回 401 —— 把"我们这边
出错"记成"口令错"，也让失败登录计数说谎。
**Breaking?** 是（编译错）· **影响面**：消费者的登录 handler · **一行改法**：
```zig
const ok = encoder.matches(input, stored) catch |err| switch (err) {
    error.OutOfMemory => return err,                                    // → 5xx
    error.MalformedStoredHash => { log.err("unusable stored hash", .{}); return err; },
};
if (!ok) return unauthorized();
```
仓库内没有调用方（只有本文件测试），改的是消费者侧。**顺带修掉一条真漏洞**：旧代码用
`expected_hash[0..32]` 做**前缀比较**，所以"32 字节真实摘要 + 1 字节垃圾"的存储记录会被判定通过；
现在长度必须**恰好**等于派生 key 长度。若你的库里有 PBKDF2 派生 key 长度 > 32 的历史记录并依赖旧的
前缀接受，它们现在会被拒（那正是修复本身）。

**行为变化（非破坏）①：Redis 不可达不再是一个"数据答案"。** `setNX`/`lock` 返回 `false`、`del` 返回
`0`、`exists` 返回 `false`、`ttl` 返回 `-1`（"存在且永不过期"）、`unlock` 静默返回 —— 这些以前在连接/池/
锁失败时也会发生，于是调用方读到一个看起来正常的答案。现在基础设施故障一律抛错，**服务端真实回答的语义
不变**（真 `-1`、真 `false`、真 `nil` 仍是值）。`RedisRateLimiter`、`RedisCooldownStore` 等调用方因此
会在 Redis 不可达时看到错误而不是静默的 `0`/`false`；请确认你的调用点有处理。

**行为变化（非破坏）②：超限的表单体从 200 变 400，解析时的分配失败变 500。**
`application/x-www-form-urlencoded` 的字段数超过 `Server.Config.max_params` 以前会**以空表单继续处理并
回 200**（H1 与 H2 都是），现在回 400；解析时我们的分配失败以前被读成"没有表单体"（200），现在回 500。
请求边界上的同类塌陷也一并分开（查询串解析的分配失败现在 500）。

**行为变化（非破坏）③：`CachedConn` 读到坏缓存条目时不再报 `DatabaseError`。** 现在它当作**缓存未命中**
继续查库，并在同一次调用里用 `setCache` 把该条目修好（记一条 warn）；只有**分配失败**才冒泡
`error.OutOfMemory`。按 `error.DatabaseError` 分支处理 `CachedConn` 的消费者需要改。

**行为变化（非破坏）④：`BufferPool.acquire` 的锁等待被取消时返回 `error.Canceled`**（以前是
`error.OutOfMemory`）；顺带：`HttpClient` 的 `ConnectionPool.release` / `discard` 改成不可取消的锁等待
（以前取消即丢一条连接），`OutboxConsumer` 遇到解析不了的行会**死信化**（`status = 3` + warn + 计数），
而不是每次 poll 都重新选中它、永远不排空。数据权限在 OOM 下现在是**收紧**（匹配不到任何行）而不是放宽。

---

## v0.33.3

> **本版有 2 处破坏性变更，都是编译错**（`Cursor.next` 的错误联合、`csrf()` 要求中间件拿到
> `CsrfConfig`），另有 1 处**默认行为收紧**（CSRF 不再采信 `X-Forwarded-Host`）。逐条背景见
> [`../CHANGELOG.md`](../CHANGELOG.md) 的 `[0.33.3]` 段。

**破坏 ①：`Cursor.next` 返回错误联合。** `sqlx.Cursor.next` 从 `?*Row` 变成
`errors.ResultT(?*Row)`——**流中途的驱动/服务器错误以前被折叠成 `null`**，即"查询坏了"和"结果取完"
不可区分，调用方会把**被截断的结果当成完整结果**（PG 实测：`SELECT 100/(3-i) …` 在第 3 行报
`22012`，循环却"正常"结束在第 2 行）。
**Breaking?** 是（编译错）· **影响面**：所有直接迭代游标的消费方 · **一行改法**：
`while (cursor.next()) |row|` → `while (try cursor.next()) |row|`；`cursor.next() == null` →
`(try cursor.next()) == null`。
仓库内 39 处（19 个文件）已按此改完。另外这一版还修了 PG 流式游标的一个 use-after-free
（列名曾分配在每行重置的 arena 里，`row.get("col")` 读到的是已释放内存）——与上面的签名变化
同批落地，不需要消费方额外动作。

**破坏 ②：`csrf()` 现在要求中间件在 `user_data` 上拿到 `CsrfConfig`。**
`csrf()` 变成 `csrfWith(.{})` 的别名；手动 `mw.func(ctx, next, null)` 会 panic。
**Breaking?** 是（运行时 panic，不是编译错）· **影响面**：只有手工调用中间件 `func` 的代码
（按 `http.addMiddleware(http.csrf())` 常规用法不受影响）· **一行改法**：
`mw.func(ctx, next, null)` → `mw.func(ctx, next, mw.user_data)`（把中间件自己的 `user_data`
传下去，别丢）。另外**默认不再采信 `X-Forwarded-Host`/`Proto`**（客户端可伪造）：
反代部署要显式 `csrfWith(.{ .trust_forwarded_host = true })`，且代理必须**每个请求都覆写**这两个头；
已有 `sign_key` 可让 cookie 里的 token 变 `nonce.HMAC-SHA256`（`csrfMintSignedToken` 签发）。

**行为变化（非破坏）**：`sqlx.Builder` 的 `where` / `join` / `groupBy` / `having` / `orderBy` /
`selectColumns` 在分配失败时不再**静默丢弃**该子句（那会让 `WHERE` 消失、查询被悄悄放宽）——错误现在
由 `toSql()` 返回。**签名没变**，链式写法 `_ = b.where(...)` 照旧可用；只要你的代码处理了 `toSql()` 的
错误（本来就该处理），就不需要改动。

**行为变化（非破坏）**：`OtlpExporter` / `SecretsManager` 改为持有常驻 `HttpClient`。`max_connections`
的口径从"每次调用的 N 条"变成"**每个组件实例的 N 条**"，同一实例上超过 N 个并发请求可能拿到
`error.PoolExhausted`；两个 `deinit` **不得与在飞请求并发**（在等待导出/读取线程结束后再 `deinit`）。

**行为变化（非破坏）**：H1 与 H2 的请求路径补齐——H2 现在也解析 `application/x-www-form-urlencoded`
表单体（并遵守 `max_params`）、运行 `path_rewriter`、把 `:path` 里的查询串拆进 `ctx.query`（拆不动时
返回 400 而不是带着缺失参数继续路由）、`ctx.allocator` 改为**每请求** arena；`ctx.stream` 在 H2 上仍为
`null`，流式处理器得到明确的 **501** 而不是把 H1 chunk 头当成 body 发出去。

**行为变化（非破坏）**：H2 现在**把 handler 设置的响应头都发出去**（以前只发 `content-type`，
`Set-Cookie` / `Location` / `Retry-After` / CORS 头在 H2 上会静默消失）。注意三件事：
① 违反 RFC 9113 §8.2.2 的连接相关字段（`connection` / `keep-alive` / `proxy-connection` /
`transfer-encoding` / `upgrade`）**不会**被转发，只记一条 warn —— 与 H1 的"整响应 500"不同；
② handler 自己设的 `content-length` 与 body 不符时也不转发（H2 里那是 malformed），H1 的行为未动；
③ 响应头有预算（peer 的 `SETTINGS_MAX_HEADER_LIST_SIZE`、字段数、编码后 ≤ peer
`SETTINGS_MAX_FRAME_SIZE`），超出的字段被丢掉并记一条 warn，而不是发一个对端必须拒绝的帧。
如果没有依赖"某个头在 H2 上恰好不发"的行为，就不需要改动。

**修复（非破坏）**：h2c 升级路径此前**不派发 stream 1**，真实客户端 `curl --http2` 升级后拿不到任何
响应（prior-knowledge 不受影响）。现在按 RFC 7540 §3.2 把**携带升级的那个请求**当作 stream 1 派发
一次，并先应用 `HTTP2-Settings`；此后客户端再发 `HEADERS(1)` 会收到 `RST_STREAM(STREAM_CLOSED)`。
若你的客户端一直在用 h2c 升级，这条修好之前它大概什么都没收到。升级同时**放开了方法限制**（此前只认
`GET`，而 RFC 对方法没有限制）：`POST`/`HEAD`/`OPTIONS` 升级现在都能进。

**行为变化（非破坏）**：`HEAD` 的响应**不再带 body**（H1 与 H2 都是）。以前 H1 会给 HEAD 写出 body
字节，与 `Content-Length` 自相矛盾。已知未覆盖：H1 的 `startChunked` 流式路径仍会写 chunk，
`writeErrorResponse`（解析错误 / WS 握手失败 / 拒绝头 500 / 503 甩负载）仍会给 HEAD 写 body。

**修复（非破坏）**：H1 的 `Content-Length` 以前会被**写两遍**（handler 自己声明过一次、服务端再加一次），
`HEAD` 上更会出现 `Content-Length: 5120` 紧跟 `Content-Length: 0` 这种自相矛盾（`StaticFiles` 会声明文件
长度，所以这在真实路由上存在）。重复的定界头是走私邻域的形状。现在**只有一个定界字段**，chunked 时两边都
不写；`HEAD` 用 handler 声明的值；其余情况只用 handler 的值——**且仅当它等于即将写出的字节数**（与 H2
已有规则一致）。若你的 handler 依赖"自己写的 `Content-Length` 一定会原样发出"，而它与实际 body 不符，
这条之后会被服务端自己的值替换。

**行为变化（非破坏，但值得确认你的接线方式）**：**一个进程里跑两个 `Server` 现在真的互不干扰了。**
`openApiFromCatalog` 的结果以前写在一份**进程级** store 里（第二个注册覆盖第一个 → A 的
`/openapi.json` 会服务 B 的 catalog），`catalogLoaderFromTable` 以前用模块级的 `Holder.tbl`
（第二个 loader 会改掉**第一个** app 的授权表，是执法路径）。现在分别按 `*CatalogSlot` 与
`RolePermissionTable` 指针去重：同一 slot / 同一张表仍是同一份状态（**有意共享**），不同则完全隔离。
**你要确认的只有一件事**：这两个入口现在都是**接线期** API —— `catalogLoaderFromTable` 有 64 个槽、
`openApiFromCatalog` 有 16 个，**耗尽即 panic**（panic 文本会告诉你抬高哪个常量）。
一次性接线（每个 app 一张表 / 一个 slot）不受影响；如果你的代码在**循环或请求路径**里反复调用它们
（旧版会静默互相覆盖，所以那样用本来也没对），请改成接线期各领取一次。

**修复（非破坏）**：PG 上"分配失败"与"驱动失败"以前都表现为 `?*PGresult` 的 `null`，于是 OOM 会被报成
`error.DatabaseError`（`toErrorContext` 落到 `UnknownError`、metrics 记的错误名也是错的）。现在
`null` 只表示"驱动没有交回 `PGresult`"，分配失败一律如实抛 `error.OutOfMemory`。两个可见的副作用：
① OOM 下 PG 查询的错误名变了；② 语句缓存键/插入的分配失败**不再**回退到"未缓存路径"再执行一次。
公开签名未变。

---

## v0.33.1

> 本版无破坏性变更。以下为 additive 亮点；完整列表见 [CHANGELOG](../CHANGELOG.md)。

**新增：校验失败的结构化错误体与消息本地化（opt-in）。** `Validation` 中间件新增
`structured_errors` 与 `message_hook` 选项（`withStructuredErrors()` /
`withMessageHook()` 链式入口）。开启结构化后，422 响应的 `data` 位携带
`errors: [{field, rule, message}]`（每失败字段一条），`msg` 仍是首条消息。
`Validator.validateStructCollect` 返回全部违规（`Violation`/`Violations`，一次
deinit），`Validator.MessageHook` 可本地化默认规则消息（`FieldRules.message`
覆写仍优先）。**默认值完全不变**：平坦字符串消息、业务码 4220。装了 RFC 7807
`error_renderer` 时渲染器收到首条消息（该形状无 `data` 槽）。
**Breaking?** 否 · **影响面**：用到 `validateRequest` 的消费方可选接入 · **一行改法**：
`validation_middleware.withStructuredErrors(true)`。

**新增**：`zig build soak-cluster`（cluster/bus 长时正确性 soak）、benchmark 套件
的 `alloc/op` CI 门禁、首批 fuzz 目标（`zig build --fuzz test`）。均无消费方改法。

---

## v0.32.0

> **本版有 7 处破坏性变更，其中 3 处是编译错**（WS 路由声明、CSPRNG 的 `io` 参数、`Method.fromString` 返回类型）。
> v0.29.0–v0.31.0 **没有**破坏性变更，所以本节是 v0.28.0 之后的唯一一段。
> 逐条背景见 [`../CHANGELOG.md`](../CHANGELOG.md) 的 `[0.32.0]` 段。

### WebSocket 路由必须显式声明 `.meta.auth = .public`（**编译错**）

**Breaking?** 是 —— **编译不过**，不是运行期拒绝。

WS 升级在 `Server` 里是**在 `router.match` 之前、在任何全局中间件之前**被应答的，所以 `ws_routes` 上的
`auth` / `permission` / `roles` **没有任何执行点**：它们被记进 catalog，然后没人查。声明本身是**骗人的** ——
脚手架的 IM 网关把身份取自查询串（`?userId=<任意人>`），而同一份模板里那条路由写着 `.auth = .jwt`。

**一行改法**：WS 路由加 `.meta = .{ .auth = .public }`，身份在 `on_connect` 里用 `ctx` 自己验
（`docs/RUNTIME.md` §12.14）。**没声明** `.meta`（`.auth` 默认 `.inherit`）、**非 `.public`** 的 auth、
以及挂 `permission`/`roles` —— 三种都编译不过。

```zig
pub const ws_routes = [_]http.WsSpec(State){
    .{ .path = "ws", .on_connect = …, .on_message = …, .meta = .{ .auth = .public } },
};
```

**脚手架生成物已经改成 fail-closed**：`ImGateway.verifier` 默认 `null`，没接验签器时**拒连**（不再回落
到信任客户端给的 id）；HTTP 侧身份改成 `ctx.requireUserIdInt(T)`。已实编译验证过。

### CSPRNG 改为 `std.Io.randomSecure`，熵入口要传 `io`（**编译错**）

**Breaking?** 是 —— 签名变了，**忘了传 `io` 编译不过**。这是有意的：运行期用弱盐比编译不过糟得多。

原种子是「毫秒 + 常量 42 + 栈地址 + 毫秒×1000」，全部来源非秘密、低熵、且**同一进程内共享**，
观测到一个输出就能枚举其余。现在每次走系统调用，失败即 `error.EntropyUnavailable`，**没有回落**。

**一行改法**：

```zig
// 旧（已改）                                     // 新
ApiKeyGenerator.generate(allocator)              ApiKeyGenerator.generate(allocator, io)
PasswordEncoder.init(allocator)                  PasswordEncoder.init(allocator, io)
PasswordEncoder.initWithIterations(a, n)         PasswordEncoder.initWithIterations(a, io, n)
kit.random.uuid(allocator)                       kit.random.uuid(allocator, io)
```

> 审计建议的 `std.crypto.random.bytes()` **在本工具链上不存在**（实测 `struct 'crypto' has no member
> named 'random'`）。也**不要**改用 `std.Io.random` —— 它的文档明写失败时回落到 pid + 墙钟 + ASLR，
> 那正是这条修掉的缺陷类别。

### `db.query` 有租户上下文而没声明列时**拒绝**（行为变化）

**Breaking?** 是 —— 对多租户应用是**新的运行期拒绝**。

`db.query` 以前没有租户边界（兄弟技能 `entity.*` 有）。现在有租户上下文时，框架把整条语句**外层包裹**：

```sql
SELECT * FROM ( <模型原样 SQL> ) AS _zt_tenant_scope WHERE _zt_tenant_scope.<col> = ?
```

租户值**只以 `?` 绑定**，一个字节都不进 SQL 文本；模型的 `OR`/`1=1` 都削弱不了外层谓词。
**没声明列 → `error.TenantScopeUnavailable`（拒绝，不是不过滤）。**

**一行改法**：默认入口 `registerBusinessSkills(&registry, &.{})` 把列留成 `null`，所以多租户应用必须改走显式入口：

```zig
try ai.business.registerBusinessSkillsWith(&registry, &.{}, .{
    .db_query_tenant_column = "tenant_id",   // 按你自己 schema 的列名
});
```

另外**你的 SELECT 必须把租户列放进结果集**，否则外层报 "no such column"（报错、不出数据）。
副作用（方向安全）：模型自己的 `LIMIT` 在内层先生效，可能少返回几行。

### HTTP 请求边界加固：畸形请求一律 4xx/501，不再静默接受（**行为 + 签名**）

**Breaking?** 是。三处解析与 RFC 不符**合起来**允许与按规范解析的前置代理产生 **CL/TE 请求走私**。

| 形状 | 之前 | 现在 |
|---|---|---|
| 无空格的合法头（`Host:x`、`Content-Length:5`） | 静默丢弃（＝该头不存在） | 正确解析 → `ctx.header` 从 `null` 变真值 |
| `Transfer-Encoding` | 全文零处理（chunked 体不消费，残留在 reader 里被当成下一个请求行） | **400** |
| `CL` + `TE` 并存 / 重复 / 冲突 / 非十进制 `CL` | 最后一次生效 | **400** |
| 未知方法（含 `PROPFIND` 这类合法扩展方法） | 折成 `.GET` 处理 | **501** |
| 请求行非 3 段 / 版本非 `HTTP/1.x` | 不校验 | **400** |

**签名变化**：`http.Method.fromString` 现在返回 **`?Method`**（未知 → `null`）。折成 `.GET` 本身就是
走私面的一部分，所以这个变化是修复的要点，不是副作用。

**一行改法**：升级后跑一遍真实流量（或 `examples/production-deploy/` 拓扑），确认没有走 `TE` 的客户端 ——
本服务器**没有 chunked 请求解码器**，所以带 `TE` 的请求以前也是错的，只是错得无声。

### 三处「默认为放行」改成 fail-closed（行为变化）

**Breaking?** 是（对依赖宽松默认值的应用是行为变化；③ 的**调用方形态一字未改**）。

- **`.dept_custom` 的空/坏 `dept_ids`**：`ids.len == 0` 与解析失败以前都 `return null`，而 `null` 按契约是
  "**不过滤**"。现在给 `deny_clause = "1 = 0"`，**只有 `.all` 才能产生 `null`**。
- **`permissionGateWith` 的配置存在函数级全局**：一个进程里跑两个 server 时第二次调用会覆盖第一次的
  **catalog 与配置**（若目标路径在对方 catalog 里是 `.public`，权限检查被跳过）。改成**每调用一份**，
  并把**空 catalog 改成 fail-closed**。legacy `jwtAuth` 的 `stored_security` 同形，一并改掉。
- **`tenantClause` 的租户谓词没有括号**：`WHERE owner_id = ? OR is_public = 1` 会按优先级变成
  `… OR is_public = 1 AND tenant_id = ?` —— **租户隔离对 `OR` 的第一个分支失效**且**没有任何报错**。
  现在把调用方那段谓词包起来。

### `handleAppendEntries` 的错误集多了一个成员（**编译错，仅下游穷尽 switch**）

**Breaking?** 是。为修 `entry.index == 0` 的无符号下溢（一个无需认证的帧就能打死/越界读节点），
`RaftElection.handleAppendEntries` 新增 `error.InvalidLogIndex`，现在共 2 个错误。

**影响面**：只影响**直接调用它并对 `err` 写穷尽 `switch`** 的代码；用 `catch |err|` 兜住的不受影响。
仓内无此类调用点。已按 `src/test/ErrorSetSnapshot.zig` 自己的契约登记进快照并把上限钉在 2。

**一行改法**：给 `switch` 加一个 `error.InvalidLogIndex` 分支（按"对端发了畸形帧、丢弃"处理）。

### `.peers` 在多节点集群里必须带 `@id`，否则**拒绝启动**（**运行期拒绝**）

**Breaking?** 是 —— 对**多节点**部署是新的启动错误（`error.PeerIdRequired`）；单节点不受影响。

`BootstrapConfig.peers` 的静态语法现在是 `"<id>@<host>:<port>"`（`@<id>` 可省）。省掉时 `id` 回落成 host，
而 `ClusterBootstrap` 曾用 `addPeer(p.host)` 把 peer 的 id 记成 host 字符串 —— Raft 只把票记给
`raft.peers[].id`，节点在线上自报的却是自己的 `node_id`，所以**这类集群的票一张也计不进来，永远选不出 leader**
（`docs/dev/cluster-auth-design.md` §10）。现在多节点 + 有 peer 没写 id → `start()` 直接拒（`log.warn` + 返回错误）。

**影响面**：`raft_cluster_size > 1` 且 `.peers` 里有不带 `@id` 的项的部署，升级后**启动失败**（拒绝，不是静默降级）。
`PeerDiscovery.Peer` 也多了一个 `id` 字段，手工构造它的代码（`registerService` 调用方、
`LoadBalancer.addCanaryPeer` 内部）要补 `.id`。

**一行改法**（每个 peer 一次）：

```zig
// 旧（多节点集群）                            // 新：`@` 前写对端的 node_id
.peers = &.{"127.0.0.1:9001"}                 .peers = &.{"node-b@127.0.0.1:9001"}
```

单节点（`raft_cluster_size = 1`）**不用改** —— 没有票要计。

### 顺带（**破坏性：否**）

- `getStatusText` 增加了 `501`；畸形请求的日志从 `log.err` **降为** `log.warn`
  （客户端过错不是服务端故障）。
- 新增 `zig build runtime-stress`（长时不变式压测）与 `docs/dev/READING_NUMBERS.md` 的读数约定。
- `ready_high_water` 的无符号下溢修掉 —— 一个被发布的指标此前会永久撒谎。

## v0.28.0

### `Runtime.cancelTimer(id) bool` 删除，拆成两个入口

**Breaking?** 是 —— **本版唯一一处**。全仓只有 `runtime.zig` 内部 1 处 + 1 个单测引用过它
（`examples/`、`tools/`、`docs/` 零引用）。

**为什么删而不是保留**：时间轮改为 ticker-owned 后，取消必然变成"投一条命令给 ticker"，
调用返回时取消还没发生。`bool` 再也无法表示"它确实还挂着"——保留它只有一个后果：
**静默改义**，调用方一个字节都不用改、行为悄悄变了。那比删掉危险。

**一行改法**：

```zig
// 旧（已删）
if (rt.cancelTimer(id)) { ... }          // 语义是"它确实还挂着"

// 新：热路径 —— 含义是"请求已交给 Runtime"，约一个 tick（5ms）后生效
try rt.requestCancelTimer(id);

// 新：控制面 —— 等 owner 执行完，返回最终结果
if (try rt.cancelTimerSync(id)) { ... }  // true = 调用那一刻它还在 pending
```

**顺带的能力**：`after` 的表现语义变成"**至少** delay_ms 后"，上界是
`delay_ms + 入队延迟 + tick_interval_ms`（tick 是 5ms）。deadline 由**调用方**算
（`clock.nowMs() + delay`），所以 `after(50)` 仍是相对调用时刻 +50，不是相对 ticker 收到 +50。
命令队列满时 `after` 返回 `error.Full`，不静默丢。

## v0.26.0+（未发布批次）

### `zmodu audit` / `zmodu ci` 现在会审计嵌套模块

**Breaking?** 是 —— 对消费方是**新增报错**，可能让原本绿的 `ci` 变红。

**背景**：`collectBusiness` 的目录遍历是固定两层（`src/modules/<模块>/<文件>.zig`），
而 `zmodu scaffold --with-agent` 把模块产出在 `src/modules/ai/agent/` —— 第 3 层。
那个模块**从未被审计过**，里面的违规一直不可见。

**影响面**：模块平铺在 `src/modules/<name>/` 的手写项目不受影响；受影响的是**嵌套模块**
（`src/modules/a/b/…`）以及 `--with-agent` 的生成物。

**一行改法**：升级后重跑 `zmodu audit .`，修掉新出现的违规；确属误报的用行级豁免
`// audit: ignore <rule>`。

### 取路由 State 用 `ctx.state(T)`

**Breaking?** 否 —— 新增 API。旧写法仍能编译，但会被 `zmodu audit` 的 b4 点名。

```zig
// 旧（b4 会报）
const self: *MyApi = @ptrCast(@alignCast(ctx.user_data orelse unreachable));
// 新
const self: *MyApi = ctx.state(MyApi) catch return null;
```

`user_data` 放的一直是 ComptimeRouter 的 `*State`（身份在另一个字段 `auth_info` 上）。
`ctx.state(T)` 在缺 state 时返回具名错误 `error.NoRouteState`，而不是让
`orelse unreachable` 在 ReleaseFast 下变成 UB。WS 的 `on_connect` / `on_close`
与 legacy `RouteGroup` 回调同样适用。

### 生成的 `catch {}` 改为带日志的忽略

**Breaking?** 否 —— `zmodu scaffold --with-agent` / `--with-websocket` 生成物的行为微变：
原本静默吞掉的审计写入 / 中继发送失败，现在会打一条 `std.log.warn`。
重新生成即可拿到。

### 生成的脚手架代码：跨租户 update/delete 从 `200 OK` 改为 `404`

**Breaking?** 是（只影响**用 `zmodu scaffold` 生成过、且表带租户列**的项目，重新生成后行为变化）。

**背景**：`updateForTenant` / `deleteForTenant` 的契约一直写着"0 行 = 这行属于别的租户（guarded no-op）"，
但生成的 `update/delete<X>ByTenant` 把行数 `_ =` 丢掉了，handler 随后无条件 `wrapSuccess` ——
于是"改别人的行"会被回答 **200 OK**（没有数据泄漏，但应用无法区分"改到了"与"不是你的行"）。

**一行改法**：重新生成（`zmodu scaffold …`），或手工把 handler 改成

```zig
const rows = try self.service.updateXByTenant(tenant_id, entity);
if (rows == 0) { try R.wrapErr(ctx, .not_found, "not found"); return; }
try R.wrapSuccess(ctx);
```
（delete 同形。）**附带**：租户 update/delete 现在**只有 `rows > 0` 时才发事件**。

### 生成的 `shared/response.zig` 的成功信封曾是**非法 JSON**

**Breaking?** 是（生成的响应体变了）。`wrapSuccess` 用了普通字符串字面量而不是 format string，
`{{\"code\":0…` 原样落进响应体 → 每个生成项目的成功信封都是 `{{"code":0,…}}`，任何 JSON 解析器都拒。
**一行改法**：重新生成即可（现在产出 `{"code":0,"msg":"","data":null}`）。
自查：`curl … | python3 -m json.tool` —— 以前这里会报解析错误。

### 脚手架输出现在**可复现**（`.fingerprint` 从包名确定性派生）

**Breaking?** 否，但**重新生成会改写 `build.zig.zon` 的 `.fingerprint` 一次**（从随机值换成本地派生值）。
此后同一 `--name` + 同一 schema 的两次生成**逐字节相同**（`diff -r` exit 0），重新生成不再制造 diff。
Zig 接受该值且**不会**在 `zig build` 时改写它（实测 md5 前后一致）。

### `sqlx.Transaction` 补齐了相对 `Client` 的方法

**Breaking?** 否，纯新增：`queryRowsPartial(Ctx)` / `queryScalar(Ctx)` / `queryRowBorrowed(Ctx)` /
`queryRowPartialBorrowed(Ctx)` / `findOne(Partial)(Ctx)` / `findAll(Partial)(Ctx)` / `batchExec(Ctx)` /
`ping(Ctx)`，以及 `queryRow/queryRowPartial/queryRows` 的 `*Ctx` 形式。既有签名**一字未改**。

### 删除 `src/persistence/Database.zig`

**Breaking?** 否（它没有从 `root.zig`/`data.zig` 导出，全仓唯一引用是"编译所有源文件"那个测试）。
数据层的入口是 `data.sqlx` / `data.Repository`（`Orm(Backend)`），见 [`ZENT.md`](ZENT.md) §1。

---

## v0.25.0

### `ClusterBootstrap.tick()` 也驱动 `raft.tick()`；配 `.transport` 时 `start()` 起入站监听

**Breaking?** 否（此前 `raft.tick()` **没人驱动**，选举根本不发生 —— 接上之后行为才符合文档）。

**影响面**：所有用 `ClusterBootstrap` 的进程。`tick()` 一次做完 `membership.runOnce()` → `view.sync()` →
`raft.tick()`；配了 `.transport` 时 `start()` 还会在 `config.port` 上开入站监听（端口起不来返回
`error.RaftInboundListenFailed`，不静默降级），`stop()` 对应停掉。**别把同一个 `port` 再给
`DistributedEventBus.start(port)`**。

**改法**：让 `tick()` 真的在循环里跑起来（此前只驱动 gossip 也算"能用"，现在选举/心跳依赖它）：

```zig
// before: 只在别处手工调 membership，raft 从未被 tick
// after
_ = try worker.after(1000, .tick);   // runtime 定时器 → Worker.handle → cluster.tick()
```

### Raft 计票口径：只数 peer 票，单节点首次选举即当选

**Breaking?** 否，是修 bug。`hasQuorum`/`startElection` 的口径明确为"只数 peer 票"（自己的票不重复计入）；
`cluster_size == 1` 时首次 election 立即当选（此前永远选不出 leader）。

**影响面**：依赖"单节点集群会自己成为 leader"的启动逻辑现在能成立；断言过旧行为（永远 follower）的测试会变红。

### `SagaStep.timeout_seconds` 真正生效

**Breaking?** 是（行为变化）：预算超时的步骤现在会被判定并补偿。

**影响面**：所有写了 `timeout_seconds` 的 saga。步骤耗时超预算 → 持久化 → **逆序补偿（含该步）** →
终态 `.timed_out` → 返回 `error.SagaStepTimeout`；`0` 表示不做预算（与旧行为一致）。

**改法**：`run` 的调用点要能接住新错误：

```zig
wf.run(allocator, &ctx) catch |err| switch (err) {
    error.SagaStepTimeout => { /* 已补偿，读 instance 的终态 */ },
    else => return err,
};
```

### 2PC 新增 `TransactionJournal`（in-doubt 有解）

**Breaking?** 否，纯新增（`zigmodu.TransactionJournal`）。append-only、只 INSERT、DDL 方言中立；
不配 backend 时退回内存。配了日志即 **fail-closed**（写不进去就报错、不前进）。`recover()` **只报告不决策**，
返回"prepared 且无终态"的事务供调用方自行重试/回滚。

**影响面**：用 `DistributedTransaction` 的应用不再需要自己造协调日志。

---

## v0.24.0

### 删除 7 个示例文件/目录（示例收敛）

**Breaking?** 是，只对**引用这些路径**的脚本/文档/CI 成立。

**影响面**：`examples/testing/`、`examples/deprecated/`、`examples/cluster-demo/`、`examples/example_tests.zig`
已不存在 —— 内容分别并入 `examples/basic/src/tests.zig` 与 `examples/distributed/README.md`。

**改法**：

```bash
# before: zig build test -Dexample=testing
# after
zig build test -Dexample=basic          # 合并后的测试根
```

### `build.zig.zon` 的 `minimum_zig_version` → `0.17.0`

**Breaking?** 否，但旧工具链会被 Zig 直接拦下（这正是不再支持 0.16 的表述）。

**影响面**：框架与 9 个示例的 `build.zig.zon`（含 `examples/*` 里 pin zent 的示例）。

### CI 两份示例构建清单统一

**Breaking?** 否。此前两份清单漂移（`zent-modulith` 只在一侧，`metaverse-creative` 两侧都没有），
现在两份**逐字一致（17 项 + `zmsaas/backend`）**；不可构建的目录（docker / node / sibling 依赖）在两处都写明原因。
（2026-09-18：`shopdemo-zent` 与 `tenant-ai` 两个示例删除后，两份清单为 **15 项 + `zmsaas/backend`**。）

---

## v0.23.0

### `ClusterBootstrap` 多节点 fail-closed（`raft_cluster_size > 1` 需 `.transport` 或显式承认）

**Breaking?** 是：**多节点**配置的 `start()` 现在会返回 `error.RaftTransportUnavailable`（v0.22 引入检查，v0.23 给出
`.transport` 这条出路）。此前静默选出一个没有 quorum 的"leader"。

**影响面**：所有 `raft_cluster_size > 1` 的启动路径（默认值就是 3）。

**改法**：三选一 —— 自带传输 / 显式承认只跑 membership + 读侧 / 单节点：

```zig
var cluster = try zmodu.ClusterBootstrap.init(allocator, io, .{
    .node_id = "node-1",
    .port = 9000,
    .transport = my_raft_transport,          // 真传输（v0.23 起的推荐路径）
    // .allow_stub_raft_transport = true,    // 或：承认「选举在别处，或干脆不选」
    // .raft_cluster_size = 1,               // 或：单节点
});
```

### `RaftTransport` 落地（真选主传输）

**Breaking?** 否，纯新增（`src/core/cluster/RaftTransport.zig`）：4 字节长度前缀 + 1 字节 tag 的 wire 格式、
peer→地址簿、出站投票（fire-and-forget）与日志复制（同步读回）、入站分发（`handleConnection` 在同一连接回包）。
`NetworkTransport.connect` 仍是死代码（引用即编译不过），拨号在 `RaftTransport` 内自建。

**影响面**：想接真选主的应用 —— 自带传输只需管**发**，入站由 `ClusterBootstrap.start()` 监听 `port` 并分发
（契约见 `docs/DISTRIBUTED.md`「真选主要什么」）。

---

## v0.22.0

### `ModuleContext.runtime()` 接线（模块内建 worker/timer 的唯一入口）

**Breaking?** 否，但**裸 harness** 下行为是显式失败。

**影响面**：模块在 `initWith` 里 `ctx.runtime()` spawn worker；`Application.stop()` **先** join worker、**再**
`Lifecycle.stopAll`（worker 可能正在调模块服务）。直接 `Lifecycle.startAllWith` 的裸 harness 返回
`error.RuntimeUnavailable`，不会偷偷新建一个 runtime。`Application.runtime()` 现在**首次调用即启动 ticker**
（此前 `handle.after(...)` 会静默不触发）。

**改法**：别在模块里自己 `Runtime.init` / `rt.shutdown()`：

```zig
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const rt = ctx.runtime() catch |err| return err;   // 同一个 app.runtime()
    _ = rt;                                            // rt.spawn(...) / handle.after(...)
}
```

### `skill.Tool.action`（默认 `.execute`）

**Breaking?** 否，但**默认值是 fail-closed 的**：忘了声明的工具永远是 `execute`，拿不到宽策略。

**影响面**：所有内置技能此前全落 `.execute`（`skill.zig:150` 的转发）；按 `AGENT_RUNTIME.md` §二 配
`allow = 读工具 + allow_execute = false` 会**全拒**。读类工具要显式标 `.action = .read` / `.propose`。

### `Agent.memory` 注入规则（身份缺失即一个字都不注入）

**Breaking?** 否，纯新增（`Agent.memory` / `memory_prefix` / `memory_limit` + `memory.recallBlockAlloc`）。
记忆按本次运行的 **tenant + user** 注入 system message；`recall` 把 `0` 当"任意"，所以身份缺失或为 0 时
**一条记忆都不注入**（跨租户注入是沉默且最坏的失败）。**别**用 `MemoryStore.formatContext` 直接给 agent 喂记忆。

### `DocSnippets` 门禁（文档代码块会被编译/形状校验）

**Breaking?** 否，但**文档里的 `zig` 围栏代码块现在会被门禁扫**（`src/test/DocSnippets.zig`，递归到 `docs/**`，
跳过插件目录）。最常被抓的是把 builder 方法直接链在 `zmodu.builder(…)` 临时值后面 —— 那个形状编译不过。

**改法**（坏形状与好形状分开看 —— 历史形状用 `text` 围栏，避免门禁把它当成推荐的写法）：

```text
// 编译不过：临时值是 *const
var app = try zmodu.builder(allocator, io).withName("app").build(.{});
```

```zig
var b = zmodu.builder(allocator, io);
defer b.deinit();
var app = try b.withName("app").build(.{});
```

---

## v0.15.46

### 上传内容策略（**新增，可选**）

**Breaking?** 否。

**影响面**：所有收文件上传的端点。此前框架只解析 multipart（`http.Multipart`）并限制**体积**，
没有任何**内容**校验，于是每个应用各写一遍，而三种常见写法都有洞：只查扩展名（改名即绕过）、
只查 `Content-Type`（客户端自填）、放行 SVG（脚本容器 → stored-XSS）。

**改法**：

```zig
const mp = zigmodu.http.Multipart.Config.forBodyLimit(64 << 20);
var form = try zigmodu.http.extractMultipart(ctx, mp);      // 415/413/400 → ProblemDetails
defer form.deinit();
try zigmodu.http.UploadGuard.checkForm(&form, .{
    .extensions = &.{ "jpg", "jpeg", "png" },
    .formats = &.{ .jpeg, .png },
    .max_bytes = 5 << 20,
});
```

判定顺序（决定你拿到哪个错误）：大小 → 主动内容（SVG/HTML 默认拒绝）→ 扩展名白名单 →
格式白名单 → 扩展名与内容一致。细节见 `BEST_PRACTICES.md`「上传与 multipart」。

### `http.extractMultipart`（**新增**）

`ctx.multipart` 是裸解析器（错误由调用方映射）；新抽取器与 `extractJson*` 对齐，
失败直接产出 ProblemDetails：415（不是 multipart）/ 413（太大）/ 400（缺 boundary、畸形、part 过多）。

### `Multipart.Config.max_total_bytes` 默认值不可达（**文档修正 + 新 helper**）

**Breaking?** 否，但如果你**以为**设了 `max_total_bytes` 就限住了上传，请检查 `max_body_size`。

服务端在 `content_len > max_body_size`（默认 8 MB）时先 413，`Multipart.parse` 不会被调用 ——
所以默认 `max_total_bytes = 32 MB` 永远不触发。新增 `Multipart.Config.forBodyLimit(n)` 用同一个数字
对齐"单 part ≤ 总量 ≤ body"。

### `ctx.paramPath` → `ctx.nestedParam`（**弃用旧名，行为不变**）

**Breaking?** 否（`paramPath` 保留为别名 —— 删除时点见锚点：**§ 弃用别名与删除计划**）。

三个近义名此前各自语义不同，读代码的人会猜错：

| 调用 | 读什么 |
|------|--------|
| `ctx.param` / `ctx.pathParam` | **只读路由占位符**（`/orders/{id}`） |
| `ctx.queryParam` / `ctx.formValue` | 只读 query / 只读 form |
| `ctx.requestParam`（新增） | **form 优先，回退 query**（"客户端放哪都行"） |
| `ctx.nestedParam`（原 `paramPath`） | form/query 里的点号路径（`filter.tags`） |

### `ctx.route_template` 统一带前导斜杠（**标签值变化**）

**Breaking?** 对指标标签是——同一路由的 label 取值会变。

此前模板形状取决于**注册方式**：`group.get("/health")` 带斜杠，`group.get("health")` 与
ComptimeRouter 的 `mountAll`（`nest` + `spec.path`）都不带，于是同一套指标里既有
`/metrics` 又有 `orders/{id}`，写死的 dashboard 查询会漏掉一半。现在注册期统一规整为
`/...` 形式（`Router.addRoute` 的 `normalizeRoutePath`），匹配逻辑不受影响。
**升级动作**：如果 dashboard / 告警里按旧形状（无前导斜杠）过滤，改成带斜杠的形式。

### `CircuitBreakerRegistry` 指针化 + 加锁（**行为修复，一处类型变化**）

**Breaking?** 一处：`breakers` 字段类型 `std.StringHashMap(CircuitBreaker)` →
`std.StringHashMap(*CircuitBreaker)`（仅影响直接读该字段的代码；用 `getOrCreate`/`get` 的不受影响）。

修的是与 `RateLimiterRegistry` 同族的两处缺陷：按值存导致 `getOrCreate` 返回的内部指针在**下一次插入
rehash 后失效**（悬垂指针），以及全程无同步。现在指针在 registry 生命周期内稳定，且所有访问持内部锁。
新增 `count()`；`generateReport()` 从占位串改为真实 JSON。

### `http.UploadGuard` / `SpinLock` 之外的小项

- `RateLimiterRegistry`：新增 `max_keys`（`initWithCapacity`）与 LRU 淘汰、`remove(name)`、
  `retain(max_idle_seconds)`、`generateReport()`。**`max_keys` 默认 0 = 行为不变**；但按 IP 建 key 的
  部署建议设上限：registry 以前只增不减。
- `ShardRouter.ShardedQuery`：**移除**（只能返回 `error.NotImplemented`，且无调用点）。物理分表仍由
  DB 层负责，模块头已写明。
- `PluginManager.loadPlugin`：仍只登记名字、不加载代码，但现在会 **warn 一行**并提供
  `dynamicLoadingSupported() == false`，便于调用方分支（以前是静默 no-op）。
- `ModuleCapabilities.generateApiBoundaryReport` / `CircuitBreakerRegistry.generateReport` /
  `RateLimiterRegistry.generateReport`：占位字符串改为真实 JSON 快照。
- `http.AccessLog` / `http.HttpMetrics`：手写的 `tryLock` 纯自旋（不让出 CPU）改为共享 `SpinLock`
  （自旋后 `yield`）。

---

## v0.15.45

### 错误体可全局统一为 RFC 7807（**行为变化，需显式开启**）

**Breaking?** 否 —— 不调用新 API 时行为**一字未变**。

**影响面**：所有依赖框架自产错误体的地方。修复前有三种形状、只有一种能挂钩：

| 形状 | 触发路径 |
|------|---------|
| `{"code":status,"msg":…,"data":null}` | `ctx.sendError`/`sendErrorResponse`（moduleGate、CSRF、413、408、未捕获 handler 500、静态文件） |
| `{"error":"…"}` | 路由之前写裸 socket（400/408/413/431、accept 线程超额 503） |
| `{status,title,detail,instance}` | `http.respondErr` 等 |

**改法**（启动期一次）：

```zig
// 链内 + 路由前，全部 RFC 7807（media type application/problem+json）
zigmodu.http.useRfc7807Errors();
```

只想要其中一半：

```zig
zigmodu.http.setDefaultReject(zigmodu.http.problemReject);          // 仅链内
zigmodu.http.setTransportErrorRenderer(zigmodu.http.problemTransportBody); // 仅路由前
zigmodu.http.setDefaultReject(null);                                 // 复位
```

- 单个 gate 想自行决定：`.reject = problemReject` / `.reject = envelopeReject(.thinkphp)`；`ModuleGateConfig` 新增 `reject`，**`.unknown = .deny` 可保留**。
- 单条响应想保留旧形状：`ctx.sendErrorEnvelope(status, code, msg)`。
- 装 `useRfc7807Errors()` 后，应用侧"链尾中间件改 404 体"的 workaround 可以删除。
- `ProblemDetails.toJson` 现在正确转义字符串（`detail` 可安全携带校验消息等不可信文本），`statusTitle` 补全 402/411/413/414/415/416/418/428/431/451/501/505/507。

### handler 侧权限匹配（**新增，可选**）

**Breaking?** 否。

**影响面**：路由 meta 用 OR（`portal:user|portal:shop`）而 handler 又需要区分门户的地方 —— 此前只能在 handler 里重写门户检查，窄化一处就 403 一整类用户。

**改法**：

```zig
// before：handler 自己拼门户判断，只认其中一个分支 → 另一门户整类 403
//   （反馈方的真实故障：路由 meta 是 portal:user|portal:shop，
//      handler 复用了只认 .shop 的 requireAppAuth）
if (!shopOnlyAuth(ctx)) { try zigmodu.http.respondErr(ctx, error.Forbidden); return; }

// after：用与路由声明完全相同的表达式问"我是哪一边"
if (!ctx.permissionMatches("portal:user|portal:shop")) {
    try zigmodu.http.respondErr(ctx, error.Forbidden);
    return;
}
// 需要与某个 gate 完全同语义（.roles 只看 roles；.rbac 有 AuthInfo 时以它为准）：
const ok = zigmodu.http.permissionMatchesWith(ctx, "portal:shop", .{ .mode = .rbac });
```

配套新增 `ctx.permissionsCsv()`（与 `rolesCsv()` 同形）。

### Redis 客户端：分帧读 + 单流加锁 + 真超时（**bug 修复**）

**Breaking?** 否（除非依赖了"大回包被截断"的行为，那本就不是契约）。

**影响面**：`RedisConfig.pool_size <= 1`（共享单流）的部署、>4KB 的回复、Redis 不响应时的挂起。修复内容：按 RESP 分帧读到完整回包、无池分支加锁、`read_timeout_ms`/`write_timeout_ms` 真正生效、解析失败即 `close()` 该连接并摘出池。

### `RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` 线程安全（**bug 修复**）

**Breaking?** 是，一处：`RateLimiterRegistry.limiters` 字段类型由 `std.StringHashMap(RateLimiter)` 变为 `std.StringHashMap(*RateLimiter)`。

**影响面**：只有直接读 `.limiters` 的代码（框架内无）。用 `get`/`getOrCreate`/`count` 的调用方不受影响 —— 反而修好了"插入后旧 `*RateLimiter` 失效"的隐患。

**改法**（若你直读过该字段）：

```zig
// before
const lim = registry.limiters.getPtr("key").?;
// after
const lim = registry.get("key").?;            // 或 getOrCreate("key")
```

### `ProblemDetails.statusTitle` 补全状态码

**Breaking?** 否，除非断言过 `statusTitle(418) == "Unknown Error"`（现为 `"I'm a Teapot"`）。新增 402/411/413/414/415/416/418/428/431/451/501/505/507。

---

## v0.15.41

### `Auth.optional` 一等化

**Breaking?** 否。`Auth = inherit | public | jwt` 新增 `.optional`：有 token 就验、失败忽略、**永不 401**，供"公开但可个性化"的接口（C 端用户中心）使用，替代在 `.public` 分支里手写尽力而为的验签。

---

## v0.15.36

### `route_template` 指标标签

**Breaking?** 否，但**建议**把指标 label 从 `ctx.path` 换成 `ctx.route_template`：`path` 带 id，会把 Prometheus 基数打爆。

### 韧性默认值（限流/熔断/背压）

**影响面**：新增连接级背压与慢连接防护；`max_connections` / `over_limit_response` / `header_timeout_ms` 语义见 `BEST_PRACTICES.md`「韧性」。

---

## 模板

```markdown
## vX.Y.Z

### <变更一句话>

**Breaking?** 是/否（若是：一句话说清什么会编译不过或行为改变）

**影响面**：谁会受影响（调用点类型/数量、版本区间）

**改法**：

```zig
// before
// after
```
```
