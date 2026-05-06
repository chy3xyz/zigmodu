# ShopDemo 技术开发文档

> **项目**: ShopDemo — ZigModu 全栈多租户电商演示
> **框架**: ZigModu v0.7.0 | Zig 0.16.0 | MySQL 5.6
> **规模**: 152 张表 · 42 模块 · 5 营销子模块 · 790+ API 端点 · 484 Zig 源文件

---

## 目录

- [一、项目概述](#一项目概述)
- [二、架构设计](#二架构设计)
- [三、模块详解](#三模块详解)
- [四、业务逻辑层](#四业务逻辑层)
- [五、营销模块组](#五营销模块组)
- [六、热加载与插件系统](#六热加载与插件系统)
- [七、能力阶梯](#七能力阶梯)
- [八、AI 编程支持](#八ai-编程支持)
- [九、模块开发规范](#九模块开发规范)
- [十、构建与部署](#十构建与部署)
- [十一、数据库设计](#十一数据库设计)
- [十二、最佳实践参考](#十二最佳实践参考)

---

## 一、项目概述

### 1.1 生成命令

```bash
zmodu scaffold \
  --sql init.sql \
  --name shopdemo \
  --with-events \
  --with-resilience \
  --with-cluster \
  --with-marketing \
  --force
```

### 1.2 项目规模

| 指标 | 数值 |
|------|------|
| 数据库表 | 152 |
| 模块数 | 42 |
| 营销子模块 | 5 (coupon/promotion/points/affiliate/recommendation) |
| API 端点 | 790+ (每表 5 个标准端点 × 152 张表 + 自定义) |
| Zig 源文件 | 484 |
| 业务逻辑文件 | 3 (enums / commission / order_flow) |
| 架构测试 | 126 (每模块 3 个) |

### 1.3 技术栈

| 层级 | 技术 |
|------|------|
| 语言 | Zig 0.16.0 |
| 框架 | ZigModu v0.7.0 |
| 数据库 | MySQL 5.6.48（兼容 SQLite via SqlxBackend） |
| HTTP | ZigModu http_server（fiber 模型 / trie 路由 / 中间件） |
| 事件 | TypedEventBus（编译期类型安全） |
| 韧性 | CircuitBreaker + RateLimiter（令牌桶） |
| 集群 | DistributedEventBus + ClusterMembership |
| 热加载 | HotReloader（文件监视） |
| 插件 | PluginManager（动态注册） |

---

## 二、架构设计

### 2.1 目录结构总览

```
shopdemo/
├── build.zig                         # Zig 0.16.0 构建系统
├── build.zig.zon                     # 依赖管理（本地 zigmodu 路径）
├── init.sql                          # MySQL 初始化脚本（152 张表）
├── .env.example                      # 环境变量模板
├── README.md                         # 项目说明
├── DEVELOPMENT.md                    # 本文档
│
├── src/
│   ├── main.zig                      # 项目入口（42 模块完整装配）
│   ├── modules/                      # 模块目录
│   │   ├── order/                    # 订单模块（11 张表）★ 示范模块
│   │   │   ├── module.zig            # 声明层
│   │   │   ├── model.zig             # 数据结构
│   │   │   ├── persistence.zig       # ORM 仓库
│   │   │   ├── service.zig           # CRUD 委托 ★ AI 生成
│   │   │   ├── api.zig               # HTTP 路由 ★ AI 生成
│   │   │   ├── service_ext.zig       # 扩展业务逻辑 ★ 手写
│   │   │   ├── api_ext.zig           # 扩展路由 ★ 手写
│   │   │   ├── root.zig              # barrel 导出
│   │   │   ├── test.zig              # 烟雾测试
│   │   │   ├── _ai.zig               # AI 上下文索引
│   │   │   └── _arch_test.zig        # 架构测试
│   │   ├── user/                     # 用户模块（17 张表）
│   │   ├── agent/                    # 分销模块（12 张表）
│   │   ├── supplier/                 # 供应商模块（18 张表）★ 多租户
│   │   ├── product/                  # 商品模块（6 张表）
│   │   ├── marketing/                # 营销模块组
│   │   │   ├── coupon/model.zig      # 优惠券
│   │   │   ├── promotion/model.zig   # 促销
│   │   │   ├── points/model.zig      # 积分
│   │   │   ├── affiliate/model.zig   # 推荐
│   │   │   └── recommendation/model.zig # 推荐引擎
│   │   └── ...                       # 其余 36 个模块
│   └── business/                     # 纯业务逻辑层
│       ├── root.zig                  # barrel
│       ├── enums.zig                 # 业务枚举（精确匹配 DB 值）
│       ├── commission.zig            # 分佣计算（纯函数）
│       └── order_flow.zig            # 订单状态机
│
├── hot_reload/                       # 热加载目录
│   ├── targets/
│   │   ├── coupon_rules.zig          # 优惠券规则（热更新）
│   │   ├── promotion_rules.zig       # 促销规则（热更新）
│   │   └── ab_test_config.zig        # A/B 测试（热更新）
│   └── watcher.zig                   # HotReloader 监视器
│
├── plugins/                          # 插件市场
│   ├── manifest.zig                  # 插件注册中心
│   ├── premium/                      # 付费插件区
│   └── community/                    # 社区插件区
│
└── .ai/                              # AI 编程支持
    ├── prompts/
    │   └── add_module.md             # "新增模块" Prompt 模板
    └── context.md                    # 项目级 AI 上下文
```

### 2.2 三层架构

每个模块遵循统一的三层架构：

```
┌─────────────────────────────────────┐
│  API Layer (api.zig)                │  ← HTTP 路由 / JSON 序列化 / 参数校验
│  - registerRoutes()                 │
│  - listXX / getXX / createXX / ...  │
│  - ctx.bindJson / ctx.sendErrorResponse │
├─────────────────────────────────────┤
│  Service Layer (service.zig)        │  ← CRUD 委托 / 事件钩子 / 业务编排
│  - list/get/create/update/delete    │
│  - afterCreate / afterUpdate        │
│  → service_ext.zig (扩展点)         │
├─────────────────────────────────────┤
│  Persistence Layer (persistence.zig)│  ← ORM 仓库 / 查询构造 / 连接管理
│  - xxRepo() → Repository<T>         │
│  - findPage / findById / insert     │
│  → SqlxBackend                      │
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│  Model Layer (model.zig)            │  ← 数据结构 / 表映射 / JSON 序列化
│  - sql_table_name                   │
│  - jsonStringify()                  │
└─────────────────────────────────────┘
```

**API 层示例**（`order/api.zig`）：

```zig
pub const OrderApi = struct {
    service: *service.OrderService,

    pub fn registerRoutes(self: *OrderApi, group: *zigmodu.http_server.RouteGroup) !void {
        try group.get("/zmodu_orders", listZmoduOrders, @ptrCast(@alignCast(self)));
        try group.get("/zmodu_orders/:id", getZmoduOrder, @ptrCast(@alignCast(self)));
        try group.post("/zmodu_orders", createZmoduOrder, @ptrCast(@alignCast(self)));
        try group.put("/zmodu_orders/:id", updateZmoduOrder, @ptrCast(@alignCast(self)));
        try group.delete("/zmodu_orders/:id", deleteZmoduOrder, @ptrCast(@alignCast(self)));
    }

    fn createZmoduOrder(ctx: *zigmodu.http_server.Context) !void {
        const self: *OrderApi = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
        const entity = ctx.bindJson(model.ZmoduOrder) catch {
            std.log.warn("[order] create: invalid body", .{});
            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), "invalid body");
            return;
        };
        const created = try self.service.createZmoduOrder(entity);
        try ctx.jsonStruct(201, created);
    }
};
```

**Service 层示例**（`order/service.zig`）：

```zig
pub const OrderService = struct {
    persistence: *persistence.OrderPersistence,
    // event_bus: zigmodu.TypedEventBus(OrderEvent),  ← 事件驱动桩

    pub fn createZmoduOrder(self: *OrderService, entity: model.ZmoduOrder) !model.ZmoduOrder {
        var repo = self.persistence.zmoduOrderRepo();
        return try repo.insert(entity);
    }
    // afterCreate / afterUpdate / afterDelete 钩子就绪
};
```

**扩展层示例**（`order/service_ext.zig` — 手写，永不被覆盖）：

```zig
pub const OrderServiceExt = struct {
    svc: *order_svc.OrderService;
    backend: zigmodu.SqlxBackend;

    pub fn cancelOrder(self: *OrderServiceExt, order_id: i64) !void {
        const order = try self.svc.getZmoduOrder(order_id) orelse return error.NotFound;
        const current_status: business.enums.OrderStatus = @enumFromInt(order.order_status);
        if (!business.order_flow.isValidTransition(current_status, .cancelled)) {
            return error.InvalidTransition;
        }
        var updated = order;
        updated.order_status = @intFromEnum(business.enums.OrderStatus.cancelled);
        try self.svc.updateZmoduOrder(updated);
    }
};
```

### 2.3 模块路由注册

`main.zig` 中 42 个模块按 Persistence → Service → API 链式装配：

```
DB → SqlxBackend → Persistence(42) → Service(42) → API(42) → HTTP Server
                     ↑ EventBus          ↑ CircuitBreaker  ↑ RateLimiter
                                        ↑ DistributedEventBus
```

---

## 三、模块详解

### 3.1 核心模块

| 模块 | 表数 | 职责 | 关键业务 |
|------|------|------|----------|
| `order` | 11 | 订单管理 | 状态机、退款、预售、结算 |
| `user` | 17 | 用户系统 | 注册、积分、等级、优惠券 |
| `product` | 6 | 商品管理 | SKU、规格、图片、虚拟商品 |
| `agent` | 12 | 分销体系 | 三级分佣、等级升级、提现 |
| `supplier` | 18 | 多商户 | 入驻、保证金、服务费、提现 |

### 3.2 营销模块

| 模块 | 表数 | 职责 |
|------|------|------|
| `seckill` | 4 | 秒杀活动 |
| `bargain` | 5 | 砍价 |
| `assemble` | 4 | 拼团 |
| `advance` | 2 | 预售商品 |
| `lottery` | 3 | 抽奖 |
| `balance` | 2 | 余额充值 |
| `point` | 2 | 积分商城 |
| `coupon` | 1 | 优惠券 |

### 3.3 基础设施模块

| 模块 | 表数 | 职责 |
|------|------|------|
| `delivery` | 4 | 配送模板、运费规则 |
| `express` | 1 | 快递公司 |
| `region` | 1 | 地区数据 |
| `sms` | 1 | 短信服务 |
| `upload` | 2 | 文件上传/分组 |
| `message` | 3 | 站内消息、模板消息 |
| `chat` | 3 | 客服聊天 |
| `printer` | 1 | 小票打印 |

### 3.4 模块文件规范

每个模块的标准文件清单：

| 文件 | 生成方式 | 可修改 | 职责 |
|------|----------|--------|------|
| `module.zig` | `zmodu` 生成 | ✗ | 模块声明（info / init / deinit） |
| `model.zig` | `zmodu` 生成 | ✗ | 数据结构 + `sql_table_name` + `jsonStringify` |
| `persistence.zig` | `zmodu` 生成 | ✗ | `SqlxBackend` ORM 仓库 |
| `service.zig` | `zmodu` 生成 | ✗ | CRUD 委托 + EventBus 桩 + AI 元数据 |
| `api.zig` | `zmodu` 生成 | ✗ | HTTP 路由 + JSON 处理器 |
| `root.zig` | `zmodu` 生成 | ✗ | barrel 导出 |
| `test.zig` | `zmodu` 生成 | ✓ | 烟雾测试（可扩展） |
| `_ai.zig` | `zmodu` 生成 | ✗ | AI 上下文索引 |
| `_arch_test.zig` | `zmodu` 生成 | ✓ | 架构验证测试 |
| `service_ext.zig` | 手动编写 | ✓ | **扩展业务逻辑**（永不被覆盖） |
| `api_ext.zig` | 手动编写 | ✓ | **扩展 HTTP 端点**（永不被覆盖） |

> **重要原则**：标记为 ✗ 的文件由 `zmodu orm --force` 重新生成时覆盖。标记为 ✓ 的文件永不覆盖。

---

## 四、业务逻辑层

### 4.1 设计原则

```
业务逻辑层 = 纯函数 + 无副作用 + 无 DB 访问 + 零分配
```

- 所有业务计算都在 `src/business/` 中实现
- 业务函数可直接导入到任意模块
- Service 层调用业务函数获得结果，再通过 Persistence 层写入 DB
- 业务逻辑层的测试无需任何基础设施

### 4.2 业务枚举 (`business/enums.zig`)

```zig
pub const OrderStatus = enum(i32) {
    pending = 10,   // 待付款
    paid = 20,      // 已付款
    shipped = 30,   // 已发货
    received = 40,  // 已收货
    completed = 50, // 已完成
    cancelled = 60, // 已取消
    refunding = 70, // 退款中
};

pub const PayType = enum(i32) {
    wechat = 10,    // 微信支付
    alipay = 20,    // 支付宝
    bank = 30,      // 银行卡
    balance = 40,   // 余额支付
};
```

枚举值精确匹配数据库中的 `tinyint` 常量，保证 PHP ↔ Zig ↔ MySQL 数据一致性。

### 4.3 分佣计算 (`business/commission.zig`)

```zig
pub fn calculate(
    order_amount: f64,
    first_rate: f64,   // 一级百分比 (0-100)
    second_rate: f64,  // 二级百分比
    third_rate: f64,   // 三级百分比
) CommissionResult {
    return .{
        .first_money = @round(order_amount * (first_rate / 100.0) * 100.0) / 100.0,
        .second_money = @round(order_amount * (second_rate / 100.0) * 100.0) / 100.0,
        .third_money = @round(order_amount * (third_rate / 100.0) * 100.0) / 100.0,
        .total = @round((first + second + third) * 100.0) / 100.0,
    };
}
```

含 3 个单元测试：基本分佣、等级加成、零订单。

### 4.4 订单状态机 (`business/order_flow.zig`)

```zig
pub fn isValidTransition(from: OrderStatus, to: OrderStatus) bool {
    return switch (from) {
        .pending   => to == .paid or to == .cancelled,
        .paid      => to == .shipped or to == .refunding,
        .shipped   => to == .received or to == .refunding,
        .received  => to == .completed or to == .refunding,
        .refunding => to == .cancelled,
        .completed, .cancelled => false,  // 终态
    };
}
```

含 4 个单元测试：合法转换、非法转换、退款资格、终态检查。

---

## 五、营销模块组

### 5.1 架构

```
src/modules/marketing/
├── coupon/model.zig         # 优惠券模型 (isValid 方法)
├── promotion/model.zig      # 促销模型 (满减/折扣/买赠)
├── points/model.zig         # 积分规则模型 (earn_rate/spend_rate)
├── affiliate/model.zig      # 推荐链接模型 (click_count/commission_rate)
└── recommendation/model.zig # 推荐配置模型 (score/reason)
```

### 5.2 热加载规则

营销规则支持运行时热更新，无需重启服务：

```
hot_reload/targets/
├── coupon_rules.zig         # → HotReloader 监视
├── promotion_rules.zig      # → HotReloader 监视
└── ab_test_config.zig       # → HotReloader 监视
```

`hot_reload/watcher.zig` 定义监视器和变更回调：

```zig
pub fn initWatcher(allocator: std.mem.Allocator, io: std.Io) !zigmodu.HotReloader {
    var reloader = zigmodu.HotReloader.init(allocator, io);
    try reloader.watchPath("hot_reload/targets/");
    reloader.onChange(struct {
        fn cb(path: []const u8) void {
            std.log.info("[HotReload] Marketing rules changed: {s}", .{path});
        }
    }.cb);
    return reloader;
}
```

---

## 六、热加载与插件系统

### 6.1 插件注册中心 (`plugins/manifest.zig`)

```zig
pub const PluginEntry = struct {
    name: []const u8,
    version: []const u8,
    license_key: ?[]const u8 = null,
    init_fn: *const fn () anyerror!void,
};

pub fn register(name: []const u8, entry: PluginEntry) !void {
    try registry.put(name, entry);
    std.log.info("[Plugin] Registered: {s} v{s}", .{ name, entry.version });
}
```

### 6.2 插件目录

```
plugins/
├── manifest.zig         # 注册中心
├── premium/             # 付费插件
│   └── (第三方扩展)
└── community/           # 社区插件
    └── (社区扩展)
```

---

## 七、能力阶梯

ShopDemo 通过 `zmodu scaffold` 的 `--with-*` 标志，实现 5 个能力阶段的一键切换：

| 阶段 | 标志 | 能力 | 框架组件 |
|------|------|------|----------|
| **A** | (默认) | 单体 CRUD | Persistence / Service / API 三层 |
| **B** | `--with-events` | 事件驱动 | `TypedEventBus` |
| **C** | `--with-resilience` | 服务治理 | `CircuitBreaker` + `RateLimiter` |
| **D** | `--with-cluster` | 分布式集群 | `DistributedEventBus` + 端口 9091 |
| **E** | `--with-marketing` | 平台化 | 营销子模块 + `hot_reload` + `plugins` |

### 7.1 main.zig 中的能力代码

```zig
// -- EventBus (Stage B) --
const event_bus = zigmodu.TypedEventBus(struct { id: i64, name: []const u8 }).init(allocator);
defer event_bus.deinit();

// -- Resilience (Stage C) --
var breaker = try zigmodu.CircuitBreaker.init(allocator, "db",
    .{ .failure_threshold = 5, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 3 });
defer breaker.deinit();
var limiter = try zigmodu.RateLimiter.init(allocator, "api", 1000, 100);
defer limiter.deinit();

// -- Cluster (Stage D) --
const node_id = try std.fmt.allocPrint(allocator, "node-{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
var dist_bus = try zigmodu.DistributedEventBus.init(allocator, init.io, node_id);
defer dist_bus.deinit();
try dist_bus.start(9091);
```

### 7.2 演进决策

```
当前 DAU？
├─ <1,000  → 阶段 A（单体，无需标志）
├─ 1k-10k  → 阶段 B（+ 事件驱动）
├─ 10k-100k → 阶段 C（+ 熔断限流）
├─ 100k-1M → 阶段 D（+ 分布式集群）
└─ >1M     → 阶段 E（+ 平台化插件）
```

---

## 八、AI 编程支持

### 8.1 模块级 AI 上下文 (`_ai.zig`)

每个模块的 `_ai.zig` 提供结构化元数据，AI 读此文件即可理解模块全貌：

```zig
// ═══════════════════════════════════════════════════════════
// AI Context: order module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_order — 71 columns
//   zmodu_order_address — 11 columns
//   ...
// Public API: service.zig
//   listZmoduOrders / getZmoduOrder / createZmoduOrder / ...
// Extension points:
//   service_ext.zig — custom business logic
//   api_ext.zig — custom HTTP endpoints
// File map:
//   module.zig → model.zig → persistence.zig → ...
// ═══════════════════════════════════════════════════════════
```

### 8.2 AI Metadata 注释块

Service 层和 Module 层包含结构化 AI 元数据：

```zig
// ╔═══════════════════════════════════════════════════════════╗
// ║  AI Metadata: module=order | layer=service                ║
// ║  role=CRUD delegation | extends=service_ext.zig           ║
// ╚═══════════════════════════════════════════════════════════╝
```

### 8.3 Prompt 模板 (`.ai/prompts/`)

```
.ai/
├── prompts/
│   └── add_module.md       # "为项目新增一个模块：..."
└── context.md              # 项目级 AI 上下文
```

### 8.4 AI 开发工作流

```
1. 读取 .ai/context.md — 理解项目全貌
2. 读取 src/modules/<name>/_ai.zig — 理解目标模块
3. 在 service_ext.zig 中编写业务代码
4. 在 api_ext.zig 中添加路由
5. zig build test → 验证
6. git commit → 发布
```

---

## 九、模块开发规范

### 9.1 声明层 (`module.zig`)

```zig
pub const info = zigmodu.api.Module{
    .name = "order",
    .description = "order module",
    .dependencies = &.{},         // ← 显式声明依赖（FK 自动推断）
    .is_internal = false,          // ← 公开模块
};

pub const Config = struct {
    // 模块专属配置 — 从 env 或 config 文件加载
};

pub fn init() !void {
    std.log.info("order module initialized", .{});
}

pub fn deinit() void {
    std.log.info("order module cleaned up", .{});
}
```

### 9.2 错误处理规范

```zig
// ✅ 正确：使用 sendErrorResponse + HttpCode 常量 + log.warn
ctx.bindJson(model.X) catch {
    std.log.warn("[order] create: invalid body", .{});
    try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), "invalid body");
    return;
};

// ✅ 正确：nil-safe 类型转换
const self: *OrderApi = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));

// ❌ 错误：使用原始字符串 + 200 状态码
try ctx.json(200, "{\"code\":0,\"msg\":\"error\"}");
```

### 9.3 命名规范

| 元素 | 规范 | 示例 |
|------|------|------|
| 模块名 | 小写 + 领域名 | `order`, `user`, `product` |
| 模型名 | PascalCase + SQL 表名 | `ZmoduOrder`, `UserProfile` |
| 函数名 | camelCase | `createOrder`, `listUsers` |
| 路由 | snake_case + SQL 表名 | `/zmodu_orders`, `/user_profiles` |
| 变量 | snake_case | `order_id`, `page_size` |

### 9.4 架构测试

每个模块的 `_arch_test.zig` 包含 3 个标准测试：

```zig
test "order - architecture: no self dependency"
test "order - architecture: naming convention"
test "order - architecture: dependency limit (10)"
```

运行架构测试：
```bash
zig build test
```

---

## 十、构建与部署

### 10.1 构建

```bash
cd shopdemo
zig build              # 编译 debug 版本
zig build -Doptimize=ReleaseSafe  # 编译 release 版本
```

### 10.2 运行

```bash
# 设置环境变量
export DB_HOST=127.0.0.1
export DB_PORT=3306
export DB_USER=root
export DB_PASS=secret
export DB_NAME=zmodu_shop_multi_demo
export HTTP_PORT=8080

zig build run
```

### 10.3 测试

```bash
zig build test                         # 运行所有测试
zig build test -- --test-filter order  # 只运行 order 模块测试
```

### 10.4 数据库初始化

```bash
mysql -u root -p < init.sql
# 或
sqlite3 shopdemo.db < init.sql
```

### 10.5 CI/CD 配置

```yaml
# .github/workflows/ci.yml
name: ShopDemo CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with: { version: "0.16.0" }
      - run: zig build test
```

---

## 十一、数据库设计

### 11.1 命名约定

```
表名格式: zmodu_{domain}_{entity}

zmodu_order              → order 模块
zmodu_order_product      → order 模块
zmodu_user_address       → user 模块
zmodu_agent_apply        → agent 模块
zmodu_supplier_capital    → supplier 模块
```

### 11.2 公共字段

所有表统一包含：

| 字段 | 类型 | 说明 |
|------|------|------|
| `app_id` | int(10) | 多租户标识（小程序 id） |
| `create_time` | int(11) | 创建时间戳 |
| `update_time` | int(11) | 更新时间戳 |

### 11.3 类型映射

| SQL Type | Zig Type |
|----------|----------|
| INT / BIGINT / SERIAL | `i64` |
| VARCHAR / TEXT / JSON | `[]const u8` |
| BOOLEAN / TINYINT(1) | `bool` |
| DECIMAL(10,2) | `f64` |
| TIMESTAMP / DATETIME | `[]const u8` |

---

## 十二、最佳实践参考

### 12.1 五条铁律

1. **声明即契约** — 模块间依赖必须在 `info.dependencies` 中声明
2. **编译即反馈** — 每次代码变更后立即运行 `zig build test`
3. **模块是原子** — 一次只修改一个模块
4. **显式胜于隐式** — allocator 显式传递，错误显式处理
5. **渐进即设计** — 按能力阶梯逐步解锁框架功能

### 12.2 参考文件

| 文档 | 路径 |
|------|------|
| 架构指南 | `../docs/ARCHITECTURE.md` |
| 最佳实践 | `../docs/BEST_PRACTICES.md` |
| AI 方法论 | `../docs/AI_METHODOLOGY.md` |
| 评估报告 | `../docs/EVALUATION_REPORT.md` |
| 框架规范 | `../AGENTS.md` |
| zmodu 命令 | `../tools/zmodu/README.md` |
| zmodu 实践 | `../tools/zmodu/BEST_PRACTICES.md` |

### 12.3 示范模块

`src/modules/order/` 是项目中最完整的示范模块：

- ✅ 11 个数据模型
- ✅ 完整 Persistence / Service / API 三层
- ✅ 3 个扩展业务方法（cancelOrder / confirmReceipt / applyCommission）
- ✅ AI 上下文索引
- ✅ 架构验证测试
- ✅ 事件钩子桩（可启用）

*其他模块应以此为模板进行开发。*

---

**最后更新**: 2025-05  
**维护者**: ZigModu Team  
**问题反馈**: 在 GitHub Issues 中提交，同时引用本文件路径 `shopdemo/DEVELOPMENT.md`
