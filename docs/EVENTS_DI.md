# EventBus 与 DI：Application 内置接入最佳实践

> 适用范围：zigmodu v0.15.34+（`Application` 内置 `EventRegistry` 与 `di.Container`）。
> 本文回答三件事：模块间怎么通信、共享服务怎么注入、哪些场景**不该**用它们。
> 配套阅读：[MODULITH.md](MODULITH.md) §2.3 通信规则 · [MODULE_LAYERS.md](MODULE_LAYERS.md)（分层纪律）。

---

## 1. 为什么接入 Application

接入前，`EventBus` 与 `di.Container` 是"文档里的特性"：框架不提供，应用各自手工接线，
且裸 `EventBus` 非线程安全、DI 容器无并发保护。接入后二者成为 Application 的默认设施，
并获得三条**结构性**保证（不是约定，是类型/机制强制）：

| 保证 | 机制 |
|------|------|
| 并发安全 | `app.eventBus(T)` 只发放 `*ThreadSafeEventBus(T)`；裸 `EventBus` 无法从 Application 获取 |
| 启动期 fail-fast | 模块在 `initWith(ctx)` 取服务，缺失即启动失败，而不是第一个请求 500 |
| 运行期只读 | `app.start()` 完成后 DI 容器 `freeze()`，再注册报 `error.ContainerFrozen`；读路径无锁 |

---

## 2. 核心范式

三种使用位置，按角色分工：

```
main（组装者）          模块（initWith）            handler / 运行期
─────────────          ────────────────            ────────────────
builder.withService    ctx.service(T, name) 取服务  app.service(T, name) 只读
app.eventBus(T)        ctx.eventBus(T) 取总线       app.eventBus(T) 订阅/发布
订阅 listener          service.withEvents(bus) 注入  容器已 freeze，禁止注册
注入 service           注册模块产出的服务（freeze 前）
```

### 2.1 模块：`initWith(ctx)` 接收框架设施

模块契约在经典 `init()` 之外新增可选入口：

```zig
pub fn init() !void { ... }                              // 经典入口，仍然有效
pub fn initWith(ctx: *zmodu.ModuleContext) !void {       // 新增：需要总线/服务时声明
    const bus = try ctx.eventBus(OrderEvent);            // 取/建共享总线（ThreadSafe）
    const cfg = ctx.service(AppConfig, "config") orelse
        return error.MissingService;                     // 缺服务 → 启动失败，fail-fast
    ...
}
```

规则：

- `init` 与 `initWith` **同时声明时只调用 `initWith`**（需要无上下文能力时自行降级）。
- 只声明 `initWith` 的模块**不能**脱离 Application 启动（`Lifecycle.startAll` 无 ctx 会直接失败并 warn）——单元测试里请用 `startAllWith` 或改用 `init`。
- `ctx` 还提供 `allocator` 与 `io`，模块不必再各自持有全局副本。

### 2.2 main：组装者接线

```zig
var app = try zmodu.builder(allocator, io)
    .withName("shop")
    .withService(AppConfig, "config", &config)   // 借用注册：容器不销毁 &config
    .build(.{ UserModule, OrderModule });
defer app.deinit();

try app.start();        // 模块 initWith 运行 → 之后容器 freeze
defer app.stop();

// 应用级共享总线：订阅副作用 listener，注入给 service
const order_bus = try app.eventBus(order_mod.service.OrderEvent);
try order_bus.subscribe(auditListener);
order_svc.withEvents(order_bus);
```

完整可运行样例见 `examples/shopdemo/src/main.zig`。

### 2.3 service：只发事件，不知道听众

```zig
pub const OrderEvent = union(enum) {
    created: struct { id: i64, total: f64 },
    updated: struct { id: i64 },
    deleted: struct { id: i64 },
};

event_bus: ?*zmodu.ThreadSafeEventBus(OrderEvent) = null,

pub fn withEvents(self: *Self, bus: *zmodu.ThreadSafeEventBus(OrderEvent)) void {
    self.event_bus = bus;
}

// 写路径成功后：
if (self.event_bus) |bus| bus.publish(.{ .created = .{ .id = id, .total = total } });
```

要点：事件定义为模块 `service.zig` 里的**具名 union 类型**（下游 import 事件类型而非模块实现）；
`withEvents` 是显式注入点，单测传一个收集型 listener 即可断言副作用。

---

## 3. DI 容器规则

### 3.1 生命周期：启动期注册 → freeze → 运行期只读

```
build() 注入 withService  ──▶  start() 模块 initWith 注册/读取  ──▶  freeze()  ──▶  运行期 get() 无锁只读
                                                                        ▲
                                              此后 register → error.ContainerFrozen
                                              remove → warn + no-op
```

- **应用级单例语义**：容器存放配置、连接池句柄、共享服务这类进程级对象。
- **请求级状态不走容器**：per-request 数据走 `ctx` attrs 或请求 arena（见 MODULITH.md §3.1）。
- `get` / `contains` 在 freeze 后是并发安全的只读；**不要在 handler 里注册**。

### 3.2 所有权：`register` vs `registerBorrowed`

| API | 所有权 | 用途 |
|-----|--------|------|
| `register(T, name, ptr)` | 容器**拥有**，deinit 时 destroy | 容器自己 `create` 出来的堆对象 |
| `registerBorrowed(T, name, ptr)` | 容器**不销毁** | 栈对象、main 持有的长生命周期对象、`builder.withService` |

`ApplicationBuilder.withService` 一律走借用注册——main 里的 `config`、`db_client` 等由 main 管理
生命周期，容器只是目录。把栈指针交给 `register`（拥有语义）会得到悬垂指针，这是旧 API 的已修陷阱。

### 3.3 命名

- name 用稳定字符串字面量（`"config"`、`"db"`、`"redis"`），模块间通过文档约定；
- 同一类型多个实例用 name 区分（如 `"db_primary"` / `"db_replica"`）；
- 编译期已知的查找可用 `getComptime(T, "name")`。

---

## 4. EventBus 规则

### 4.1 DO / DON'T

| DO | DON'T |
|----|-------|
| 从 `app.eventBus(T)` / `ctx.eventBus(T)` 取总线 | 自行 `EventBus(T).init(...)` 造一条私有总线（听众/发布者不在同一条总线上=事件丢失） |
| 事件类型定义为 service 层的具名 union | 用 `*anyopaque` / 字符串 topic / map 传事件 |
| 事件只承载"已发生的事实"（id + 关键字段） | 在事件里塞 ORM 实体指针、DB 连接等不可跨边界对象 |
| listener 里快速失败/落 Outbox | listener 里做重活、阻塞 I/O（publish 是同步调用） |
| 单线程局部场景才用裸 `EventBus` / `TypedEventBus` | 在并发 handler 里共享裸 EventBus（非线程安全） |

### 4.2 publish 的语义边界

- **fire-and-forget**：publish 同步调用 listener，无持久化、无重试。进程崩溃即丢失。
- **需要可靠投递** → 先写 Outbox（同事务），由 relay 异步转发；见 MODULITH.md §2.3。
- **需要跨实例** → RobustMQ / Kafka wire，不是进程内总线。
- **需要强一致** → 同 DB 事务 + 兄弟模块 `persistence.Tx`，事件只做"事后通知"。

---

## 5. 不适用场景（刻意不用）

| 场景 | 用什么 |
|------|--------|
| 下单 + 扣库存必须原子 | 单 DB 事务 / `persistence.Tx` 编排，**不是**事件 |
| 跨进程/跨机器事件 | Outbox relay / RobustMQ |
| 请求级状态传递 | `ctx` attrs（`user_id` / `tenant_id`）或请求 arena |
| handler 需要同步拿到结果 | 直接调 service；事件没有返回值 |
| 模块启动期的重活 | `initWith` 应快速完成；重初始化用 lazy + 首次请求触发或后台任务 |

---

## 6. 测试

```zig
test "order service publishes created event" {
    const allocator = std.testing.allocator;
    var registry = zmodu.EventRegistry.init(allocator, std.testing.io);
    defer registry.deinit();

    const bus = try registry.bus(OrderEvent);
    var received: ?OrderEvent = null;
    try bus.subscribe(struct {
        fn capture(e: OrderEvent) void { received = e; }
    }.capture);

    var svc = OrderService.init(&persist);
    svc.withEvents(bus);
    _ = try svc.create(...);

    try std.testing.expect(received != null);
}
```

- service 单测注入收集型 listener，断言事件载荷——不 mock 下游模块。
- 模块 `initWith` 逻辑用 `Lifecycle.startAllWith(modules, &ctx)` 覆盖。
- 并发浸泡测试（N 并发 publish/subscribe）值得进 CI；`ThreadSafeEventBus` 的正确性由框架测试保证，
  应用侧测的是**你自己的 listener 在并发下的行为**。

---

## 7. 迁移指南（旧代码 → 新范式）

| 旧写法 | 新写法 |
|--------|--------|
| `var bus = zmodu.EventBus(E).init(alloc)`（全局/手工传递） | `const bus = try app.eventBus(E)` |
| `CrudService.setEventBus(*TypedEventBus)` | `setEventBus(*ThreadSafeEventBus)`（API 已收窄） |
| 模块 `init()` 里各自打开共享资源 | `initWith(ctx)` + `ctx.service` / `ctx.eventBus` |
| main 里手工把依赖塞给每个模块 | `builder.withService` → 模块 `initWith` 自取 |
| 运行期中途 `container.register(...)` | 启动期完成注册；运行期注册会 `ContainerFrozen` |

向后兼容：只声明 `init()` 的模块行为不变；DI/事件接入是增量 opt-in，不要求一次性改完。
