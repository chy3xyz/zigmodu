# Bookstore Service Backend - Enterprise Edition

基于 ZigModu 框架的企业级模块化书店服务后端，采用**事件驱动架构**和**仓储模式**。

## 🎯 核心特性

### 架构模式
- **模块化架构**: 12个独立模块，职责清晰分离
- **事件驱动通信**: 模块间通过事件总线解耦通信
- **仓储模式**: 统一的数据访问抽象层
- **事务管理**: 支持跨模块事务一致性

### 技术亮点
- **Repository Pattern**: 通用CRUD操作抽象
- **Event Bus**: 发布-订阅模式的事件系统
- **Query Builder**: 类型安全的查询构建器
- **Transaction Manager**: 事务管理和回滚
- **Cross-Module Events**: 跨模块事件监听与响应

## 🏗️ 系统架构

### 模块依赖关系

```
                    API Gateway
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
    │  User   │◄──►│  Order  │◄──►│ Catalog │
    │ Module  │    │ Module  │    │ Module  │
    └────┬────┘    └────┬────┘    └────┬────┘
         │              │              │
    ┌────▼──────────────▼──────────────▼────┐
    │           Event Bus Module            │
    │    (跨模块事件通信总线)                │
    └────┬──────────────┬──────────────┬────┘
         │              │              │
    ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
    │Payment  │    │Inventory│    │  Cart   │
    │ Module  │    │ Module  │    │ Module  │
    └────┬────┘    └─────────┘    └─────────┘
         │
    ┌────▼──────────────────────────────────┐
    │      Repository & Database Layer      │
    │  ┌──────────┐  ┌──────────┐          │
    │  │  Book    │  │  Order   │          │
    │  │Repository│  │Repository│          │
    │  └──────────┘  └──────────┘          │
    │  ┌──────────┐  ┌──────────┐          │
    │  │  User    │  │Inventory │          │
    │  │Repository│  │Repository│          │
    │  └──────────┘  └──────────┘          │
    └───────────────────────────────────────┘
```

### 事件驱动通信流程

```
用户操作
    ↓
模块业务逻辑
    ↓
发布事件 (EventBus.publish)
    ↓
┌─────────────────────────────────────┐
│        事件总线 (Event Bus)          │
│  ┌──────────┬──────────┬──────────┐│
│  │ order_   │ payment_ │ stock_   ││
│  │ created  │ completed│ updated  ││
│  └────┬─────┴────┬─────┴────┬─────┘│
└───────┼──────────┼──────────┼──────┘
        ↓          ↓          ↓
   ┌────────┐ ┌────────┐ ┌────────┐
   │Inventory│ │Notification│ │  Audit   │
   │ Module  │ │  Module    │ │  Module  │
   │自动预留库存│ │发送邮件通知│ │记录审计日志│
   └────────┘ └────────┘ └────────┘
```

## 📦 模块清单

### 核心模块 (8个)

| 模块 | 职责 | 依赖 | 监听事件 |
|------|------|------|----------|
| **config** | 配置管理 | - | - |
| **database** | 数据库连接 | - | - |
| **repository** | 数据访问抽象 | database | - |
| **eventbus** | 事件总线 | database | - |
| **catalog** | 图书管理 | repository, eventbus | stock_updated |
| **user** | 用户认证 | repository | - |
| **inventory** | 库存管理 | repository, eventbus | order_created |
| **cart** | 购物车 | - | order_created |

### 业务模块 (4个)

| 模块 | 职责 | 依赖 | 监听事件 |
|------|------|------|----------|
| **order** | 订单处理 | repository, eventbus | payment_completed |
| **payment** | 支付处理 | repository, eventbus | - |
| **notification** | 通知服务 | eventbus | order_created, order_shipped |
| **audit** | 审计日志 | eventbus | user_registered, payment_completed |

### 接口模块 (1个)

| 模块 | 职责 | 依赖 |
|------|------|------|
| **api** | HTTP接口 | 所有业务模块 |

## 🔄 事件类型定义

### 用户事件
```zig
user_registered     // 用户注册
user_logged_in      // 用户登录
user_updated        // 用户信息更新
```

### 购物车事件
```zig
cart_item_added     // 添加商品到购物车
cart_item_removed   // 从购物车移除商品
cart_checked_out    // 购物车结算
```

### 订单事件
```zig
order_created       // 订单创建
order_confirmed     // 订单确认
order_paid          // 订单支付
order_shipped       // 订单发货
order_delivered     // 订单送达
order_cancelled     // 订单取消
```

### 支付事件
```zig
payment_initiated   // 支付发起
payment_completed   // 支付完成
payment_failed      // 支付失败
refund_processed    // 退款处理
```

### 库存事件
```zig
stock_reserved      // 库存预留
stock_released      // 库存释放
stock_updated       // 库存更新
low_stock_alert     // 低库存告警
```

## 💾 数据访问层

### Repository Pattern

```zig
// 通用仓储接口
pub fn Repository(comptime T: type) type {
    return struct {
        pub fn insert(self: *Self, entity: T) !T
        pub fn findById(self: *Self, id: u64) ?*T
        pub fn findAll(self: *Self) []T
        pub fn findBy(self: *Self, field: []const u8, value: anytype) ![]T
        pub fn update(self: *Self, id: u64, updater: fn (*T) void) !?T
        pub fn delete(self: *Self, id: u64) !bool
        pub fn findPage(self: *Self, page: u32, page_size: u32) []T
    };
}

// 使用示例
var book_repo = try Repository(Book).init(allocator, "books");
const book = try book_repo.insert(.{
    .title = "The C Programming Language",
    .price = 59.99,
});
```

### Query Builder

```zig
// 构建复杂查询
var query = try QueryBuilder(Book).init(allocator, "books");
const results = try query
    .where("price", .gte, 20.0)
    .where("category_id", .eq, 1)
    .orderBy("created_at", true)
    .limit(10)
    .execute(&book_repo);
```

### Transaction Manager

```zig
// 事务管理
var tx = TransactionManager.init(allocator);
try tx.begin();

// 执行业务操作
try tx.logOperation(.{ .insert = .{ .table = "orders", .data = order_data } });
try tx.logOperation(.{ .update = .{ .table = "inventory", .id = 1, .data = stock_data } });

// 提交或回滚
try tx.commit();
// 或 try tx.rollback();
```

## 🎯 跨模块通信示例

### 场景：用户下单流程

```
1. Cart Module (购物车模块)
   └── 用户点击"结算"
   └── 发布 cart_checked_out 事件
       
2. Event Bus (事件总线)
   └── 路由事件到订阅者
       
3. Order Module (订单模块) [订阅者]
   └── 接收 cart_checked_out 事件
   └── 创建订单
   └── 发布 order_created 事件
       
4. Inventory Module (库存模块) [订阅者]
   └── 接收 order_created 事件
   └── 自动预留库存
   └── 发布 stock_reserved 事件
       
5. Notification Module (通知模块) [订阅者]
   └── 接收 order_created 事件
   └── 发送订单确认邮件
       
6. Audit Module (审计模块) [订阅者]
   └── 接收 order_created 事件
   └── 记录操作审计日志
```

### 代码实现

```zig
// 1. 订阅事件 (在模块初始化时)
try eventbus.EventBusModule.subscribe(
    .order_created,           // 事件类型
    onOrderCreated,           // 处理器函数
    "inventory"               // 目标模块
);

// 2. 实现处理器
fn onOrderCreated(event: Event) !void {
    // 解析事件数据
    const payload = try std.json.parseFromSlice(
        OrderCreatedPayload,
        allocator,
        event.payload,
        .{} 
    );
    
    // 执行业务逻辑
    try inventory_module.reserveStock(
        payload.book_id,
        payload.quantity,
        payload.order_id
    );
}

// 3. 发布事件
 try eventbus.EventBusModule.publish(
    .order_created,
    .{
        .order_id = 100,
        .user_id = 1,
        .total_amount = 150.00,
    },
    "order"
);
```

## 🚀 快速开始

### 1. 安装依赖

```bash
# 确保已安装 Zig 0.15.2
zig version
```

### 2. 构建项目

```bash
cd examples/bookstore-service
zig build
```

### 3. 运行服务

```bash
zig build run
```

### 4. 运行测试

```bash
zig build test
```

## 📡 API 端点

### 图书管理
```
GET    /api/books              # 图书列表 (支持分页)
GET    /api/books/:id          # 图书详情
POST   /api/books              # 创建图书
PUT    /api/books/:id          # 更新图书
DELETE /api/books/:id          # 删除图书
GET    /api/books/search?q=keyword&category=1&min_price=10&max_price=100
```

### 购物车
```
GET    /api/cart                    # 查看购物车
POST   /api/cart/items              # 添加商品
PUT    /api/cart/items/:id          # 更新数量
DELETE /api/cart/items/:id          # 删除商品
GET    /api/cart/checkout           # 结算预览
POST   /api/cart/checkout           # 确认结算
```

### 订单管理
```
GET    /api/orders              # 订单列表
POST   /api/orders              # 创建订单
GET    /api/orders/:id          # 订单详情
POST   /api/orders/:id/pay      # 支付订单
POST   /api/orders/:id/cancel   # 取消订单
GET    /api/orders/:id/track    # 物流跟踪
```

## 📊 系统监控

### 事件统计
```
GET /api/admin/events/stats    # 事件处理统计
GET /api/admin/events/queue    # 事件队列状态
```

### 审计日志
```
GET /api/admin/audit/logs      # 审计日志查询
GET /api/admin/audit/stats     # 审计统计
```

## 🔧 配置管理

### 配置文件 (config/app.json)

```json
{
  "server": {
    "host": "0.0.0.0",
    "port": 8080,
    "max_connections": 1000
  },
  "database": {
    "driver": "sqlite",
    "host": "localhost",
    "database": "bookstore.db",
    "max_connections": 10
  },
  "event_bus": {
    "async_processing": true,
    "max_queue_size": 10000,
    "retry_attempts": 3
  }
}
```

## 🧪 测试策略

### 单元测试
每个模块包含独立的单元测试：

```bash
zig test modules/catalog.zig
zig test modules/order.zig
zig test modules/eventbus.zig
```

### 集成测试
测试跨模块通信：

```bash
# 启动服务
zig build run &

# 运行集成测试
./scripts/integration_test.sh
```

## 📈 性能优化

### 数据库优化
- 连接池管理
- 查询缓存
- 索引优化
- 读写分离

### 事件处理优化
- 异步事件处理
- 批量事件处理
- 事件持久化
- 死信队列

### 缓存策略
- 热点数据缓存
- 分布式缓存
- 缓存失效策略

## 🔐 安全特性

### 认证授权
- JWT Token 认证
- 角色权限控制 (RBAC)
- API 限流

### 数据安全
- SQL 注入防护
- XSS 防护
- CSRF 防护
- 敏感数据加密

## 📚 文档

- [架构设计文档](docs/ARCHITECTURE.md)
- [API 文档](docs/API.md)
- [数据库设计](docs/DATABASE.md)
- [部署指南](docs/DEPLOYMENT.md)

## 🤝 贡献指南

1. Fork 项目
2. 创建特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件

---

**Built with [ZigModu](https://github.com/yourusername/zigmodu)** - A modular application framework for Zig
