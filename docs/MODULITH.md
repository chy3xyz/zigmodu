# Modulith 高并发最佳实践

**适用**：ZigModu v0.14+ · Zig 0.17  
**定位**：项目第一天如何按 modulith 边界开发，并平滑支撑高并发——**一个进程、多个清晰模块**，先可拆分地写，再按流量加池化 / 缓存 / 消息，而不是一上来微服务。

相关文档：

| 文档 | 内容 |
|------|------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 模块概念、分层、通信模式 |
| [MODULE_LAYERS.md](MODULE_LAYERS.md) | **model / persistence / service / Tx 分层细则** |
| [BEST_PRACTICES.md](BEST_PRACTICES.md) | 按 DAU 阶段演进（1K → 1M+）+ JWT 可执行清单 |
| [ROUTE_TABLE.md](ROUTE_TABLE.md) | ComptimeRouter + catalog JWT / RBAC |
| [AGENTS.md](../AGENTS.md) | **AI 操作手册**（DO/DON'T） |
| [elegant-code-patterns.md](elegant-code-patterns.md) | 五文件布局与代码样例 |
| [DISTRIBUTED.md](DISTRIBUTED.md) | 多实例 / RobustMQ / 集群注意点 |
| [MODULITH_TENANT_SHOP.md](MODULITH_TENANT_SHOP.md) | **蓝图**：多租户店依赖图 + 目录清单 |
| [ZENT.md](ZENT.md) | **zent**：schema-as-code ORM 与 ZigModu 正交集成 |
| [SQLX_DRIVERS.md](SQLX_DRIVERS.md) | **sqlx**：`-Ddb=` / `.db=` 选择性驱动链接 |
| [best-practices-heysen-lessons.md](best-practices-heysen-lessons.md) | 生产踩坑（sqlx / ORM） |

---

## 1. 核心原则

ZigModu modulith = **单二进制部署 + 模块级边界**（Spring Modulith 思路）：

1. **边界第一天就定**，比中间件选型更重要。
2. **同进程直接调 service** 做强一致；**跨域副作用用 EventBus / Outbox**。
3. **高并发先吃单机 fiber + 连接池**，状态外置（Redis / RobustMQ）；自研 Cluster/Raft 不当主路径。
4. **只有边界清晰且独立扩展收益明确时**，才把模块拆成独立进程。

```
┌─────────────────────────────────────────────────────────┐
│                 Application (一个进程)                    │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐            │
│  │ user   │ │product │ │ order  │ │payment │  ← 模块边界 │
│  └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘            │
│      └──────────┴──── EventBus ───────┘                 │
│  DB pool · Redis · RobustMQ · JWT / 限流 / 熔断           │
└─────────────────────────────────────────────────────────┘
         ▲ 水平扩展：多实例 + LB（模块代码不变）
```

---

## 2. 第一天就定边界

### 2.1 固定五文件（禁止 `ext/`）

```
modules/<domain>/
  model.zig         — 数据结构、表映射、JSON 名
  persistence.zig   — 仅 SQL / 参数绑定
  service.zig       — 业务规则与编排
  api.zig           — HTTP 注册与 handler
  module.zig        — info + init/deinit + 依赖
  root.zig          — 可选 barrel 导出
```

| 层 | 职责 | 禁区 |
|----|------|------|
| `api` | 解析入参、鉴权上下文、`ctx.json` | 业务规则、事务编排、裸 SQL |
| `service` | 校验、编排、发事件、开事务 | 直接碰 HTTP / Context |
| `persistence` | 参数化 SQL、`?` 占位符；跨表同事务用 `pub const Tx` | if/else 业务分支 |
| `module` | `info`、生命周期、依赖名 | 业务逻辑 |
| `model` | 纯数据 | 业务方法 |

完整样例见 [elegant-code-patterns.md](elegant-code-patterns.md)；**Tx / Cmd / Outbox 细则**见 [MODULE_LAYERS.md](MODULE_LAYERS.md)。

### 2.2 模块契约

```zig
pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Order management",
    .dependencies = &.{"user", "product"}, // 模块名，不是 import 路径
};

pub fn init() !void {}
pub fn deinit() void {}
```

启动时用 `validateModules` 卡住环依赖与缺失依赖。

### 2.3 通信规则

| 场景 | 方式 | 说明 |
|------|------|------|
| 同事务、强一致 | service 编排 + 依赖模块 **`persistence.Tx`** | 例如下单预留库存；见 [MODULE_LAYERS.md](MODULE_LAYERS.md) |
| 跨域副作用 | **EventBus** / Outbox | 例如 `OrderCreated` → 发邮件、积分；接线规则见 [EVENTS_DI.md](EVENTS_DI.md) |
| 跨实例异步 | **RobustMQ**（Kafka wire） | 见 [DISTRIBUTED.md](DISTRIBUTED.md) |

禁止：业务模块互相 `import` 对方的非 Tx persistence 做随意读写；禁止 handler 里写 SQL。同事务工作流可 import 兄弟模块的 **`persistence.Tx`（仅 SQL）**。

---

## 3. 高并发：先单机 fiber，再外置状态

并发模型是 **单二进制 + fiber HTTP**（kqueue / io_uring），不是「每模块一个服务」。

### 3.1 Day-1 就该打开

1. **DB `ConnPool`** — 按核数设 `max_open` / `max_idle`；禁止每请求 `Client.open`。
2. **请求级 arena** — handler 分配跟 `Context` 生命周期走；service 不藏全局 allocator 做长生命周期对象（除非明确 ownership）。
3. **无阻塞 handler** — 请求路径禁止长时间阻塞；重活进 Outbox / RobustMQ。
4. **幂等写** — 支付、下单、扣库存用业务幂等键；消费者可安全重试。
5. **背压** — 限流 middleware、熔断、队列满则快速失败，不无限堆连接。

### 3.2 刻意后移

| 后移项 | 原因 |
|--------|------|
| 自研 Cluster / Raft 当主路径 | 先用多实例 + LB + Redis / RobustMQ |
| 模块间同步 RPC / 服务网格 | 同进程直接调；跨实例用消息 |
| 物理拆分 `Server.zig` / `sqlx.zig` | 用 § 分区维护；见 [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md) |

### 3.3 规模阶梯

| 阶段 | 形态 | 关键动作 |
|------|------|----------|
| 0–1k DAU | 单机 modulith + SQLite/单库 | 模块边界 + EventBus |
| 1k–10k | 同进程垂直扩展 | 连接池、Redis、热点缓存 |
| 更高 | 多实例无状态 + 外置中间件 | JWT/会话外置、RobustMQ、只读副本 |
| 再往后 | 按模块抽独立进程（可选） | 仅当边界已清晰且扩展收益明确 |

更细的配置与指标见 [BEST_PRACTICES.md](BEST_PRACTICES.md)「渐进式架构演进」。

---

## 4. 启动骨架

```zig
const zmodu = @import("zigmodu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // io 来自 Zig 0.17 Init / 应用约定

    var app = try zmodu.builder(allocator, io)
        .withName("shop")
        .build(.{ UserModule, ProductModule, OrderModule, PaymentModule });
    defer app.deinit();

    // 基础设施在 main / foundation 注入，业务模块只拿接口
    // try wireDb(&app); try wireRedis(&app); try registerRoutes(...);
    // 共享服务/事件总线：builder.withService + 模块 initWith(ctx)，见 docs/EVENTS_DI.md

    try app.start();
    defer app.stop();
    // 或 try app.run(); — SIGINT/SIGTERM 优雅排空 in-flight
}
```

要点：

- **main 只做组装**：池、路由、中间件、模块列表。
- 基础设施（DB、Redis、Kafka）在 foundation 创建，**业务模块不各自 `open`**。
- 关停顺序：停接新请求 → drain in-flight → 关池 → `deinit` **逆依赖序**。

---

## 5. 并发与正确性硬规矩（Zig 0.17）

| 规则 | 做法 |
|------|------|
| 互斥 | `std.Io.Mutex` + `io`；不要用 OS 线程硬扛 `Io.Mutex`（易死锁） |
| 列表 | `ArrayList(T).empty`，方法显式传 allocator |
| 时间 | `Time.monotonicNowMilliseconds()`，不用已删除的 `milliTimestamp` |
| 请求头 | `Context.headers` 键为**小写**（`authorization`） |
| SQL | 仅 `?` 占位符；标识符校验，禁止拼接用户输入进表名 |
| 安全 | 密码 / CSRF → `zmodu.security`；JWT 门禁 → catalog 栈（`ROUTE_TABLE.md` §7） |
| HTTP 响应 | `ctx.json(status, body)`，不用已弃用的 `sendSuccess`/`sendFail` |
| 观测 | Prometheus `/metrics` + 关键路径延迟；压测用 `examples/http-stress-test` |

---

## 6. 何时拆成独立进程

**同时**满足再考虑把某模块独立部署：

1. 已有清晰 API + 事件契约；
2. 独立扩展收益明显（CPU/IO 与其它模块不成比例）；
3. 团队需要独立发布节奏。

否则保持 **modulith 多实例水平扩展** 更便宜，也更符合框架设计。

---

## 7. 第一周 Checklist

- [ ] 域模块五文件布局 + `info.dependencies`
- [ ] `main` 只组装：池、路由、中间件、模块列表
- [ ] 写路径：service 事务 + 可选 Outbox；读路径可缓存
- [ ] 全局中间件：recover / requestId / 限流 / catalog JWT+permissionGate（按需，见 `ROUTE_TABLE.md` §7）
- [ ] 单测按模块；集成 smoke（参考 `examples/tenant-mgmt`）
- [ ] 文档写清：同步依赖 vs 异步事件各用在哪
- [ ] `zig build test` 与 `bash scripts/ci-integration.sh` 可跑通

---

## 8. 反模式速查

| 反模式 | 正确做法 |
|--------|----------|
| 微服务拆太早 | 单进程模块 + 多实例 |
| handler 里写 SQL | `api` → `service` → `persistence` |
| 模块互扒 persistence | 依赖 service API 或事件 |
| 每请求新建 DB 连接 | 共享 `ConnPool` / `data.Client` |
| 请求路径同步调外部慢 API | Outbox / RobustMQ 异步 |
| 自造分布式成员当默认 | LB + 无状态实例 + 外置 Redis/MQ |
| 用 `std.Thread` + `Io.Mutex` 驱动 gossip | `runOnce` / fiber + 正确解锁后再 publish |

---

## 9. 参考示例

| 示例 | 用途 |
|------|------|
| [MODULITH_TENANT_SHOP.md](MODULITH_TENANT_SHOP.md) | **多租户店蓝图**：依赖图 + 目录清单 |
| `examples/tenant-mgmt/` | 旗舰可运行演示（CI 集成） |
| `examples/http-stress-test/` | 高并发压测二进制 |
| `examples/shopdemo/` | 生成代码 / schema 参考 |

命令基线：

```bash
zig build
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
zig build check-api
bash scripts/ci-integration.sh
```
