# Spring Modulith vs ZigModu 深度功能对比

## 📊 功能完成度总览

| 类别 | Spring Modulith | ZigModu | 完成度 | 优先级 |
|------|----------------|---------|--------|--------|
| **核心模块系统** | 100% | 85% | 🟡 高 | P0 |
| **事件系统** | 100% | 65% | 🔴 中 | P0 |
| **测试支持** | 100% | 50% | 🔴 低 | P1 |
| **文档生成** | 100% | 90% | 🟢 高 | - |
| **架构验证** | 100% | 80% | 🟡 中 | P1 |
| **持久化集成** | 100% | 0% | ⚪ 低 | P2 |
| **事件回放** | 100% | 0% | ⚪ 低 | P2 |
| **配置管理** | 100% | 40% | 🔴 中 | P1 |

---

## 🔍 详细功能对比

### 1. 核心模块系统 (@ApplicationModule)

#### Spring Modulith 功能
```java
@ApplicationModule(
    allowedDependencies = {"inventory", "shipping"},
    type = Module.Type.OPEN,  // OPEN, CLOSED, INVALID
    displayName = "Order Management"
)
package com.example.order;
```

**特性清单：**
- ✅ 模块元数据（名称、描述、版本）
- ✅ 显式依赖声明
- ✅ 模块类型（OPEN/CLOSED）
- ✅ **包级别注解**（Java 特有）
- ✅ **编译时边界检查** - 防止非法导入
- ✅ 内部 API 标记 (@Internal)
- ✅ **Spring Boot 自动配置集成**

#### ZigModu 现状
```zig
pub const info = api.Module{
    .name = "order",
    .description = "订单模块",
    .dependencies = &."inventory"},
    .is_internal = false,
};
```

**已实现：**
- ✅ 基础元数据
- ✅ 依赖声明
- ✅ 内部/外部标记
- ✅ 运行时验证

**缺失功能：**
- ❌ **编译时边界检查** - 无法阻止直接导入模块内部
- ❌ 模块类型定义（OPEN/CLOSED）
- ❌ 版本管理
- ❌ 自动配置集成

**实现建议：**
```zig
// 需要编译时检查
const order = @import("order/module.zig");
// 应该检查：不能访问 order/internal/*.zig

// 模块类型
pub const ModuleType = enum {
    open,      // 允许其他模块访问
    closed,    // 只允许通过 API 访问
    internal,  // 仅限内部使用
};
```

---

### 2. 事件系统

#### Spring Modulith 功能

**1. 事件发布 (@PublishedEvent)**
```java
@Service
public class OrderService {
    
    @PublishedEvent  // 自动发布 OrderCompleted 事件
    public Order completeOrder(OrderId id) {
        // ... 业务逻辑
        return order;  // 返回类型即为事件类型
    }
    
    // 显式发布
    @Autowired ApplicationEventPublisher publisher;
    
    public void process(Order order) {
        publisher.publishEvent(new OrderProcessed(order));
    }
}
```

**2. 事件监听 (@ApplicationModuleListener)**
```java
@Component
public class OrderEventListener {
    
    @ApplicationModuleListener
    void on(OrderCompleted event) {
        // 自动处理
    }
    
    @ApplicationModuleListener(
        async = true,                    // 异步执行
        transactional = true,            // 事务性
        condition = "#event.amount > 100" // SpEL 条件
    )
    void onHighValueOrder(OrderCompleted event) {
        // 处理高价值订单
    }
}
```

**3. 事件外部化 (Event Externalization)**
```java
@Configuration
class EventConfig {
    
    @Bean
    EventExternalizationConfiguration eventConfig() {
        return EventExternalizationConfiguration
            .externalize(OrderCompleted.class)
            .to(Kafka.outgoing("orders"))
            .build();
    }
}
```

**特性清单：**
- ✅ **声明式事件发布** (@PublishedEvent)
- ✅ **自动事件监听注册**
- ✅ 异步事件处理 (async)
- ✅ 事务性事件 (transactional)
- ✅ 条件过滤 (condition)
- ✅ 事件外部化 (Kafka, RabbitMQ)
- ✅ 事件序列化/反序列化
- ✅ **事件回放/重放**
- ✅ 事件存储 (Event Store)

#### ZigModu 现状
```zig
// 1. 基础 EventBus
var bus = EventBus(OrderEvent).init(allocator);
try bus.subscribe(handleOrder);
bus.publish(.{ .order_id = 123 });

// 2. ModuleListener (初级实现)
pub fn ApplicationModuleListener(comptime EventType: type) type {
    return struct {
        config: Config,
        handler: *const fn (EventType) anyerror!void,
        
        pub const Config = struct {
            async_mode: bool = true,
            transactional: bool = false,
            condition: ?[]const u8 = null,
        };
    };
}

// 3. EventExternalization (接口定义，未实现)
pub const EventExternalization = struct {
    externalizers: std.ArrayList(Externalizer),
    // ... 仅定义，无具体实现
};
```

**已实现：**
- ✅ 基础事件总线（类型安全）
- ✅ 订阅/发布机制
- ✅ ModuleListener 接口定义

**缺失功能：**
- ❌ **声明式事件发布** - 需要方法拦截
- ❌ **自动监听器注册** - 需要编译时扫描
- ❌ **真正的异步执行** - 需要集成 zio
- ❌ **事务性事件** - 需要 ACID 支持
- ❌ **条件表达式** - 需要表达式解析
- ❌ **事件外部化实现** - 需要消息队列集成
- ❌ **事件回放** - 需要事件存储

**实现建议：**
```zig
// 声明式事件发布 - 使用编译时代码生成
pub fn PublishedEvent(comptime T: type) type {
    return struct {
        pub fn publish(self: *T, bus: *EventBus(T)) void {
            // 自动发布
            bus.publish(self.*);
        }
    };
}

// 使用示例
const OrderService = struct {
    pub fn completeOrder(self: *OrderService, id: u64) !Order {
        const order = // ...
        // 自动发布 OrderCompleted 事件
        try order.publish(self.event_bus);
        return order;
    }
};

// 异步执行集成 zio
const zio = @import("zio");

pub fn subscribeAsync(self: *Self, listener: Listener) !void {
    const executor = zio.Executor.init(self.allocator);
    try self.async_listeners.append(.{
        .listener = listener,
        .executor = executor,
    });
}
```

---

### 3. 测试支持 (@ModulithTest)

#### Spring Modulith 功能
```java
@ModulithTest
class OrderModuleTest {
    
    @Test
    void completesOrder() {
        // 自动启动应用上下文
        // 只加载 Order 模块及其依赖
    }
    
    @Test
    @Scenario("order-completion")
    void orderCompletionScenario() {
        // 基于场景测试
    }
}

// 事件测试
@ApplicationModuleTest
class OrderEventTest {
    
    @Test
    void publishesOrderCompletedEvent() {
        var order = orderService.complete(orderId);
        
        // 验证事件已发布
        assertThat(events)
            .contains(OrderCompleted.class)
            .matching(evt -> evt.orderId().equals(orderId));
    }
}
```

**特性清单：**
- ✅ **@ModulithTest** - 自动配置测试上下文
- ✅ **模块隔离** - 只加载目标模块
- ✅ **事件捕获/验证**
- ✅ **场景测试** - BDD 风格
- ✅ **文档测试** - 测试即文档
- ✅ **快照测试** - 架构变更检测

#### ZigModu 现状
```zig
// 基础测试上下文
pub const ModuleTestContext = struct {
    allocator: std.mem.Allocator,
    modules: ApplicationModules,
    
    pub fn start(self: *Self) !void {
        // 启动模块
    }
};

// 使用示例
test "order module" {
    var ctx = try extensions.ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    try ctx.start();
}
```

**缺失功能：**
- ❌ **自动模块扫描** - 需要编译时检测
- ❌ **事件验证** - 需要事件捕获机制
- ❌ **模块隔离** - 需要细粒度控制
- ❌ **场景测试 DSL**
- ❌ **快照测试**
- ❌ **文档生成集成**

**实现建议：**
```zig
// 声明式测试
pub fn ModulithTest(comptime modules: anytype) type {
    return struct {
        app: Application,
        captured_events: EventCapture,
        
        pub fn init(allocator: Allocator) !@This() {
            return .{
                .app = try Application.init(allocator, "test", modules, .{}),
                .captured_events = EventCapture.init(allocator),
            };
        }
        
        pub fn expectEvent(self: *@This(), comptime T: type) !T {
            // 验证事件
        }
    };
}

// 使用
test "order completion" {
    var test_ctx = try ModulithTest(.{OrderModule}).init(allocator);
    defer test_ctx.deinit();
    
    try test_ctx.app.start();
    
    // 执行业务操作
    // 自动捕获事件
    
    const event = try test_ctx.expectEvent(OrderCompleted);
    try std.testing.expectEqual(event.order_id, 123);
}
```

---

### 4. 架构验证 (ArchUnit 风格)

#### Spring Modulith 功能
```java
@ApplicationModuleTest
class ArchitectureTest {
    
    @Test
    void verifiesModuleStructure() {
        modules.verify();
    }
    
    // 自定义规则
    @Test
    void orderModuleShouldNotDependOnPayment() {
        modules.verify(
            ModulithArchitecture.builder()
                .module(OrderModule.class)
                .shouldNotDependOn(PaymentModule.class)
                .build()
        );
    }
}
```

**内置规则：**
- ✅ 循环依赖检测
- ✅ 非法依赖检测
- ✅ 命名规范验证
- ✅ API 暴露验证
- ✅ **文档一致性检查**
- ✅ **变更检测** - 与上次快照对比

#### ZigModu 现状
```zig
// ArchitectureTester - 已实现大部分功能
pub const ArchitectureTester = struct {
    pub fn ruleNoCircularDependencies(self: *Self) !void {}
    pub fn ruleNoSelfDependency(self: *Self) !void {}
    pub fn ruleLimitedDependencies(self: *Self, max: usize) !void {}
    pub fn ruleBaseModulesShouldNotDependOnOthers(self: *Self, base: []const []const u8) !void {}
};
```

**缺失功能：**
- ❌ **文档一致性** - 验证代码与文档匹配
- ❌ **API 暴露验证** - 检查 public API 是否合规
- ❌ **快照对比** - 检测架构演进
- ❌ **自定义规则 DSL**

---

### 5. 持久化集成

#### Spring Modulith 功能
```java
// JDBC 模块
@JdbcRepository
interface OrderRepository extends CrudRepository<Order, OrderId> {
    
    @Query("""
        SELECT * FROM orders 
        WHERE status = :status
        """)
    List<Order> findByStatus(OrderStatus status);
}

// 事件存储
@EventPublicationRegistry
interface OrderEventStore {
    // 自动存储所有领域事件
}
```

**特性：**
- ✅ JDBC 模块支持
- ✅ JPA 集成
- ✅ MongoDB 模块
- ✅ **事件存储** - 自动持久化事件
- ✅ **领域事件回放**
- ✅ **CQRS 支持**

#### ZigModu 现状
**完全缺失** - 需要基于 Zig 生态实现

**实现建议：**
```zig
// Zig 风格的事件存储
pub const EventStore = struct {
    pub fn append(self: *Self, comptime T: type, event: T) !void;
    pub fn replay(self: *Self, comptime T: type, handler: fn(T) void) !void;
    pub fn snapshot(self: *Self) !void;
};

// 集成 SQLite/PostgreSQL
pub const JdbcModule = struct {
    pub fn init(db: *Database) !JdbcModule;
    pub fn query(self: *Self, sql: []const u8, args: anytype) !QueryResult;
};
```

---

### 6. 配置管理

#### Spring Modulith 功能
```yaml
# application.yml
spring:
  modulith:
    events:
      externalization:
        enabled: true
        kafka:
          bootstrap-servers: localhost:9092
      republishing:
        enabled: true
    documentation:
      enabled: true
      output: docs/
```

**特性：**
- ✅ 外部化配置
- ✅ 事件配置
- ✅ 文档生成配置
- ✅ 重放配置

#### ZigModu 现状
```zig
// ConfigLoader - 基础 JSON 支持
pub const ConfigLoader = struct {
    pub fn loadJson(self: *Self, path: []const u8) !std.json.Parsed(std.json.Value);
};
```

**缺失：**
- ❌ TOML/YAML 支持
- ❌ 类型安全配置属性
- ❌ 环境变量集成
- ❌ 配置验证

---

## 🎯 优先级排序

### P0 - 核心功能（必须实现）

1. **编译时模块边界检查**
   - 阻止非法模块导入
   - 验证 public API 合规性
   - **复杂度：高**

2. **事件系统完善**
   - 声明式事件发布
   - 自动监听器注册
   - 集成 zio 异步执行
   - **复杂度：高**

3. **测试框架增强**
   - @ModulithTest 风格
   - 事件捕获/验证
   - 模块隔离
   - **复杂度：中**

### P1 - 重要功能（强烈建议）

4. **事务性事件**
   - ACID 保证
   - 失败重试
   - **复杂度：高**

5. **事件外部化**
   - Kafka/RabbitMQ 集成
   - 序列化/反序列化
   - **复杂度：中**

6. **配置管理**
   - TOML 支持
   - 类型安全配置
   - **复杂度：低**

### P2 - 增强功能（可选）

7. **事件存储与回放**
   - 事件持久化
   - 快照/回放
   - **复杂度：高**

8. **持久化集成**
   - JDBC/Zig 数据库集成
   - Repository 模式
   - **复杂度：高**

9. **架构快照测试**
   - 变更检测
   - CI/CD 集成
   - **复杂度：中**

---

## 🚀 实施路线图

### Phase 1: 核心稳定 (2-3 周)
- [ ] 编译时模块边界检查
- [ ] 完善事件系统基础
- [ ] 测试框架 MVP

### Phase 2: 功能完善 (3-4 周)
- [ ] 异步事件处理
- [ ] 配置管理升级
- [ ] 架构验证增强

### Phase 3: 生态集成 (4-6 周)
- [ ] 消息队列集成
- [ ] 事件存储
- [ ] 数据库集成

### Phase 4: 高级特性 (持续)
- [ ] 快照测试
- [ ] CQRS 支持
- [ ] 分布式模块

---

## 💡 关键设计决策

### 1. 编译时检查 vs 运行时检查

**Spring Modulith**: 编译时（Java APT）+ 运行时（Spring AOP）
**ZigModulith**: 编译时（comptime）+ 可选运行时

**建议：**
```zig
// 编译时检查模块边界
comptime {
    // 验证模块只导出 public API
    const order = @import("order/module.zig");
    const exports = @typeInfo(order).Struct.decls;
    
    // 确保没有直接导入内部模块
    const internal_imports = checkInternalImports(order);
    if (internal_imports.len > 0) {
        @compileError("Module imports internal packages");
    }
}
```

### 2. 事件系统架构

**选项 A**: 集成 zio（推荐）
- 优势：成熟异步运行时
- 劣势：额外依赖

**选项 B**: 自建异步执行器
- 优势：零依赖
- 劣势：复杂度增加

### 3. 配置管理

**推荐方案**:
```zig
// 编译时配置生成
pub const Config = @import("config").fromFile("app.toml", .{
    .database = struct {
        url: []const u8,
        pool_size: u32 = 10,
    },
    .modules = struct {
        order: OrderConfig,
    },
});
```

---

## 📋 总结

| 维度 | Spring Modulith | ZigModu | 差距 |
|------|----------------|---------|------|
| **成熟度** | 生产级 | Beta | 12-18 个月 |
| **功能覆盖** | 100% | 65% | 35% |
| **易用性** | 优秀 | 良好 | 可接受 |
| **性能** | 一般 | 优秀 | 领先 |
| **生态** | 丰富 | 初期 | 差距大 |

**结论**: ZigModu 已达到 **功能完备度的 65%**，核心功能可用。需要重点补齐：
1. 编译时模块边界检查
2. 完整的事件系统
3. 完善的测试支持

建议优先实现 **P0 功能**，使框架达到生产可用水平。
