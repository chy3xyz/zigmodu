# UPGRADING — 逐版本升级注意

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

## v0.32.0

> **本版有 5 处破坏性变更，其中 3 处是编译错**（WS 路由声明、CSPRNG 的 `io` 参数、`Method.fromString` 返回类型）。
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

**Breaking?** 否（`paramPath` 保留为别名）。

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
