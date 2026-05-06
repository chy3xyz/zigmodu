# ZigModu AI 编程方法论

> 基于 Spring Modulith 架构哲学 + Zig 编译期能力 + AI 协作实践
>
> 版本：1.0 | ZigModu v0.7.0 | Zig 0.16.0

---

## 目录

1. [哲学基础：三个支柱的交汇](#一哲学基础三个支柱的交汇)
2. [模块：AI 编程的最小可信单元](#二模块ai-编程的最小可信单元)
3. [编译期即规范引擎](#三编译期即规范引擎)
4. [渐进式 AI 开发四阶段](#四渐进式-ai-开发四阶段)
5. [Zig 特有的 AI 编程优势](#五zig-特有的-ai-编程优势)
6. [AI 常见反模式与纠正](#六ai-常见反模式与纠正)
7. [工具链：zmodu × AI 工作流](#七工具链zmodu--ai-工作流)
8. [五条铁律](#八五条铁律)

---

## 一、哲学基础：三个支柱的交汇

### 1.1 Modulith 哲学 → 显式边界

Spring Modulith 的核心洞察：**模块边界必须显式声明，而非靠约定或文档维持**。

在 ZigModu 中，这个原则被编码为编译器可强制执行的规则：

```zig
// 这不是注释或文档——这是编译期可验证的契约
pub const info = api.Module{
    .name = "order",
    .description = "订单模块",
    .dependencies = &.{"inventory"},   // ← 显式边界：编译器检查
    .is_internal = false,              // ← 公开/内部：架构测试可验证
};
```

Modulith 哲学告诉 AI：**你不需要猜测模块间的关系——它们已被声明为机器可读的数据**。

### 1.2 Zig 哲学 → 编译期即契约

Zig 的三条核心原则直接适配 AI 编程：

| Zig 原则 | AI 编程含义 |
|----------|------------|
| 无隐藏控制流 | AI 生成的代码路径可预测、可审查 |
| 无隐藏分配 | 内存问题在编译期暴露，AI 可快速修复 |
| 编译期执行 (`comptime`) | 验证逻辑在构建时运行，形成即时反馈循环 |

```zig
// comptime 的力量：这段代码在编译期运行，0 运行时开销
inline for (modules) |mod| {
    const init_fn = if (@hasDecl(mod, "init"))   // ← 编译期反射
        struct { fn wrapper(ptr: ?*anyopaque) anyerror!void {
            _ = ptr; try mod.init();
        }}.wrapper
    else null;
    // init_fn 在编译期被确定——没有虚表，没有反射开销
}
```

### 1.3 AI 协作哲学 → 可验证性优先

AI 生成代码的质量瓶颈不是"生成速度"，而是**验证速度**。

ZigModu 的设计目标之一：**让 AI 生成的每一行代码都能被编译器立即检查**。

```
传统 AI 编程循环：
  AI 生成 → 人工审查 → 运行测试 → 发现 bug → AI 修复 → 循环

ZigModu AI 编程循环：
  AI 生成 → comptime 验证 → 编译错误精确指示 → AI 修复 → 循环
             ↑                                    ↑
        0 人工介入                          0 人工介入
```

---

## 二、模块：AI 编程的最小可信单元

### 2.1 为什么模块是 AI 的理想工作单元

AI 的上下文窗口和推理能力有一个"甜蜜点"：**约 100-300 行的单一职责代码**。

ZigModu 的模块结构天然匹配这个粒度：

```
src/modules/order/
├── module.zig      ←  30-50 行：声明层（info + init/deinit 骨架）
├── api.zig         ←  50-100行：公开接口
├── handler.zig     ←  100-200行：业务逻辑
└── test.zig        ←  50-100行：模块级测试
```

每个文件都在 AI 的 context sweet spot 内。

### 2.2 模块的"三明治结构"

ZigModu 模块遵循一个 AI 友好的三层结构：

```
┌──────────────────────────────────────┐
│  1. 声明层 (Declaration Layer)       │  ← AI 生成：定义你是谁
│     info: Module { name, deps }      │     编译期验证：依赖存在？
│     init() !void                     │
│     deinit() void                    │
├──────────────────────────────────────┤
│  2. 实现层 (Implementation Layer)    │  ← AI 生成：定义你做什么
│     公开函数 → api.zig               │     人工审查：业务逻辑正确性
│     内部函数 → internal.zig          │
│     事件处理 → handler.zig           │
├──────────────────────────────────────┤
│  3. 测试层 (Verification Layer)      │  ← AI 生成：证明你正确
│     test "模块名 - 场景"             │     zig build test 自动运行
│     ModuleTestContext 集成测试       │
└──────────────────────────────────────┘
```

### 2.3 AI 生成模块的标准模板

让 AI 生成一个新模块时，使用此模板作为 prompt 的"骨架"：

```zig
// ═══════════════════════════════════════════════════════════
// 模块：[模块名]
// 职责：[一句话描述]
// 依赖：[列出依赖模块]
// ═══════════════════════════════════════════════════════════

const std = @import("std");
const zigmodu = @import("zigmodu");

// ── 声明层 ─────────────────────────────────────────────────
pub const info = zigmodu.api.Module{
    .name = "[模块名]",
    .description = "[描述]",
    .dependencies = &.{ [依赖列表] },
};

// ── 配置 ───────────────────────────────────────────────────
const Config = struct {
    // 模块专属配置
};

var config: Config = .{};

// ── 生命周期 ───────────────────────────────────────────────
pub fn init() !void {
    std.log.info("[模块名] 初始化", .{});
    // TODO: 初始化资源
}

pub fn deinit() void {
    std.log.info("[模块名] 释放", .{});
    // TODO: 清理资源
}

// ── 公开 API ───────────────────────────────────────────────
// TODO: 公开函数

// ── 事件处理 ───────────────────────────────────────────────
// TODO: 事件订阅/发布

// ── 测试 ───────────────────────────────────────────────────
test "模块名 - 基本初始化" {
    // TODO
}
```

**AI prompt 建议**：
> "基于 ZigModu 框架，创建一个 [模块名] 模块。依赖：[列表]。生成完整的 module.zig 文件，包含 info 声明、init/deinit 骨架、配置结构体、以及单元测试支架。"

---

## 三、编译期即规范引擎

### 3.1 依赖声明 → 自动校验

这是 ZigModu 对 AI 编程最关键的贡献：**依赖关系的声明与验证形成闭环**。

```zig
// 1. AI 生成模块时声明依赖（声明层）
pub const info = api.Module{
    .name = "order",
    .dependencies = &.{"inventory", "payment"},
};

// 2. 框架在编译期验证（0 运行时开销）
// ModuleScanner: 提取所有模块的 info
// ModuleValidator: 检查每个声明的依赖是否存在
//                 检查循环依赖
//                 检查自引用

// 3. 验证失败 → 编译错误（精确指向问题）
// error: Module 'order' is missing dependency: 'payment'
// error: Circular dependency detected: a -> b -> a
```

**对 AI 的意义**：AI 不需要"记住"约定——它只需遵循 `info.dependencies` 的模式，编译器会告诉它是否正确。

### 3.2 `scanModules` 的 AI 价值

`scanModules` 是 ZigModu 的"编译期反射"机制：

```zig
// 应用入口：声明模块列表
var modules = try zigmodu.scanModules(allocator, .{
    UserModule,
    OrderModule,
    PaymentModule,   // ← 添加新模块只需加一行
});

// scanModules 在编译期做：
// 1. inline for 遍历每个模块
// 2. @hasDecl 检测 init/deinit 是否存在
// 3. 生成类型擦除的函数包装器
// 4. 构建 ModuleInfo 注册表
```

**对 AI 的意义**：
- AI 添加新模块 → 加一行到 `scanModules` 调用 → 编译 → 立即可验证
- 不需要修改任何配置文件、注册表、DI 容器
- "加一行，编译，通过" 是最短的 AI 反馈循环

### 3.3 `validateModules` 的即时反馈

```zig
// 编译期验证（在 startAll 之前）
try zigmodu.validateModules(&modules);
// 检查项：
// ✅ 所有声明的依赖模块都已注册
// ✅ 无模块依赖自身
// ✅ 无循环依赖（DFS 检测）
// ✅ 模块名非空
```

**AI 工作流**：
```
AI 生成模块 → zig build → 编译错误: "Module 'order' is missing dependency: 'cache'"
AI 修复：添加 cache 依赖或移除依赖声明 → zig build → ✅ 通过
```

---

## 四、渐进式 AI 开发四阶段

### 阶段 1：骨架生成（AI 主力，人工监督）

**目标**：定义模块边界和依赖关系

**AI 输入**：
```
"为 ZigModu 项目创建以下模块骨架：
1. user 模块：用户管理，依赖 auth
2. order 模块：订单管理，依赖 user, inventory
3. payment 模块：支付处理，依赖 order

每个模块遵循 ZigModu 标准模板：info 声明 + init/deinit 骨架 + 测试支架"
```

**AI 输出**：3 个 `module.zig` 文件，每个约 40 行

**验证**：`zig build` → `validateModules` 自动检查依赖完整性

**人工审查点**：依赖关系是否合理，模块粒度是否恰当

### 阶段 2：业务实现（AI 辅助，人工驱动）

**目标**：填充模块的业务逻辑

**模式**：每个模块按"内部函数 → 公开 API → 事件处理"顺序实现

```zig
// AI 生成业务逻辑的典型 prompt：
// "在 order 模块中实现 createOrder 函数：
//  1. 验证请求参数（product_id 非空，quantity > 0）
//  2. 调用 inventory.checkStock
//  3. 创建订单实体
//  4. 发布 OrderCreatedEvent
//  使用 Zig 标准错误处理模式，每个步骤返回具体错误"
```

**验证**：`zig build test` → 单元测试

**关键原则**：
- **先写函数签名，再让 AI 填实现**：签名是契约，AI 填充细节
- **一个函数 = 一个 prompt**：保持 AI 上下文聚焦
- **每次 AI 生成后立即编译**：编译错误是 AI 最好的反馈

### 阶段 3：事件集成（AI 生成骨架，人工定义协议）

**目标**：模块间通过 EventBus 解耦通信

```zig
// AI 生成事件发布端（在 order 模块中）
pub fn createOrder(ctx: *Context, req: OrderRequest) !Order {
    const order = try createOrderEntity(ctx.allocator, req);

    // AI 生成的模式：发布事件
    try ctx.event_bus.publish(OrderCreatedEvent{
        .order_id = order.id,
        .user_id = req.user_id,
        .total = order.total,
    });

    return order;
}

// AI 生成事件订阅端（在 notification 模块中）
pub fn init() !void {
    try event_bus.subscribe(OrderCreatedEvent, |event| {
        // AI 填充：发送通知
        _ = sendNotification(event.user_id, "订单已创建");
    });
}
```

**验证**：集成测试 → `ModuleTestContext` + 事件断言

### 阶段 4：架构验证（自动化，0 人工）

**目标**：确保持续符合模块化架构原则

```zig
// ArchitectureTester：自动验证模块边界
test "architecture - no illegal dependencies" {
    var tester = zigmodu.ArchitectureTester.init(allocator);
    defer tester.deinit();

    // AI 写规则，框架自动检查
    try tester.verifyNoCyclicDependencies();
    try tester.verifyModuleBoundary("order", &.{"inventory", "user"});
    try tester.verifyNoInternalAccess("order", "inventory.internal");
}
```

**AI 的价值**：生成架构测试规则，框架自动执行，形成持续保障。

---

## 五、Zig 特有的 AI 编程优势

### 5.1 comptime 类型信息：AI 不需要猜测

```zig
// AI 生成这段代码时，不需要记住 MyEvent 的字段
// comptime 提供完整的类型信息
pub fn TypedEventBus(comptime T: type) type {
    return struct {
        // T 的类型信息在编译期完全已知
        // AI 可以依赖编译器的类型检查
        pub fn publish(self: *Self, event: T) void { ... }
    };
}

// 使用时：
var bus = TypedEventBus(OrderCreatedEvent).init(allocator);
bus.publish(.{ .order_id = 1, ... });  // ← AI 生成：字段名由编译器校验
```

### 5.2 显式 allocator：AI 不会隐藏内存问题

```zig
// AI 生成的代码中，allocator 是显式参数
// 没有隐式 new，没有 GC，没有隐藏分配
pub fn processOrder(allocator: std.mem.Allocator, req: OrderRequest) !Order {
    const buffer = try allocator.alloc(u8, 1024);  // ← 显式分配
    defer allocator.free(buffer);                    // ← 必须显式释放

    // AI 忘记 defer？编译通过但测试会暴露（内存泄漏检测）
    // AI 忘记 allocator.free？这也是一个可检测的模式
}
```

### 5.3 Arena 模式：AI 的批量内存管理捷径

```zig
// HTTP Server 的请求处理使用 Arena
// AI 不需要逐块管理内存——整个请求的生命周期由 Arena 管理
fn connFiber(server: *Server, stream: std.Io.net.Stream, allocator: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();   // ← 一行释放所有请求级分配

    // AI 生成的代码在 arena 上下文中运行
    // 所有 allocPrint、dupe 等操作都通过 arena
    // 请求结束 → arena.deinit() → 全部释放
}
```

**对 AI 生成代码的影响**：AI 了解 "arena 上下文" 后，可以安全地生成更多分配密集型代码，无需担心逐块释放。

### 5.4 编译错误即精确指导

Zig 的编译错误信息精确指向问题，这使 AI 可以自主修复：

```
// Zig 编译错误示例：
src/modules/order/module.zig:15:32: error: expected type '[]const u8', found 'i32'
    .name = 42,
            ^~
src/modules/order/module.zig:15:32: note: expected type '[]const u8'

// AI 看到这个错误 → 立即知道：name 应该是字符串 → 修复
```

---

## 六、AI 常见反模式与纠正

### 6.1 反模式：循环依赖

**AI 容易犯的错误**：模块 A 依赖 B，模块 B 依赖 A

```zig
// ❌ AI 可能生成这样的代码：
// order/module.zig
pub const info = api.Module{
    .name = "order",
    .dependencies = &.{"inventory"},    // order → inventory
};

// inventory/module.zig
pub const info = api.Module{
    .name = "inventory",
    .dependencies = &.{"order"},        // inventory → order ← 循环！
};
```

**ZigModu 的防护**：
```zig
try zigmodu.validateModules(&modules);
// → error: Circular dependency detected: order → inventory → order
```

**纠正策略**：
1. 引入事件解耦（下单发布 `OrderCreatedEvent`，库存订阅）
2. 提取共同接口到第三方模块
3. 合并紧密耦合的模块

### 6.2 反模式：上帝模块

**AI 容易犯的错误**：因为 prompt 描述了一个大功能，就生成一个包罗万象的模块

```zig
// ❌ AI 生成：一个模块做所有事
pub const info = api.Module{
    .name = "shop",
    .dependencies = &.{ "db", "cache", "http", "email", "queue", "payment_gateway" },
};
```

**纠正 prompt**：
> "将 shop 功能拆分为独立模块：user（用户管理）、order（订单）、payment（支付）、notification（通知）。每个模块只依赖其直接需要的模块。为每个模块单独生成文件。"

### 6.3 反模式：隐式依赖

**AI 容易犯的错误**：在代码中直接使用其他模块的类型，但没有在 `dependencies` 中声明

```zig
// ❌ AI 生成：使用了 inventory 但没有声明依赖
pub const info = api.Module{
    .name = "order",
    .dependencies = &.{},    // ← 声明无依赖
};

pub fn createOrder() !void {
    // 但代码中调用了 inventory.checkStock()
    const stock = try inventory.checkStock(product_id);  // ← 隐式依赖！
}
```

**纠正规则**：任何 `@import("其他模块")` 都必须在 `dependencies` 中声明。

**AI prompt 提示**：
> "生成代码时，确保每个 `@import` 的外部模块都在 `info.dependencies` 中声明。`validateModules` 会在编译期检查这一点。"

### 6.4 反模式：类型擦除滥用

**AI 容易犯的错误**：过度使用 `anyopaque` / `@ptrCast` 绕过类型系统

```zig
// ❌ AI 生成：不必要的类型擦除
pub fn process(ptr: *anyopaque) void {
    const order: *Order = @ptrCast(@alignCast(ptr));  // 危险：无类型保证
}

// ✅ 正确：保持类型信息
pub fn process(order: *Order) void {
    // 编译器保证类型安全
}
```

**原则**：只在框架边界使用 `anyopaque`（如 `ModuleScanner` 生成的包装器），业务代码保持强类型。

---

## 七、工具链：zmodu × AI 工作流

### 7.1 代码生成器 + AI 的分工

`zmodu` CLI 生成**结构**，AI 填充**逻辑**：

```bash
# zmodu 生成骨架（确定性）
zmodu module user          # → src/modules/user/module.zig
zmodu api users --module user  # → src/modules/user/api.zig

# AI 填充实现（创造性）
# Prompt: "在 src/modules/user/module.zig 中实现 init 函数：
#   连接数据库，初始化缓存，订阅 UserLoginEvent"
```

### 7.2 标准 AI 工作流

```
┌─────────────────────────────────────────────────────────┐
│               ZigModu AI 开发工作流                       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  1. zmodu module <name>                                 │
│     ↓ 生成骨架                                          │
│  2. AI: 填充 info 声明 + 依赖                           │
│     ↓                                                    │
│  3. zig build  →  validateModules 检查依赖             │
│     ↓ ✅ 编译通过                                       │
│  4. AI: 生成 init/deinit 实现                           │
│     ↓                                                    │
│  5. zig build test → 单元测试运行                       │
│     ↓ ✅ 测试通过                                       │
│  6. AI: 生成业务逻辑 + 事件处理                         │
│     ↓                                                    │
│  7. zig build test → 集成测试                           │
│     ↓ ✅ 全部通过                                       │
│  8. AI: 生成 ArchitectureTester 规则                    │
│     ↓                                                    │
│  9. zig build test → 架构验证                           │
│     ↓ ✅ 持续保障                                       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 7.3 AI 友好的目录约定

```
src/modules/<name>/
├── module.zig       ← AI 必读：模块声明和生命周期
├── api.zig          ← AI 必读：公开接口定义
├── handler.zig      ← AI 生成：事件处理器
├── internal.zig     ← AI 可读：内部实现（不暴露）
├── types.zig        ← AI 可读：模块专属类型定义
└── test.zig         ← AI 生成：测试用例
```

**AI prompt 公约**：在 prompt 中引用模块时，使用路径 `src/modules/<name>/module.zig`，AI 能定位到声明层和实现层。

---

## 八、五条铁律

### 铁律 1：声明即契约

```
模块的 info.dependencies 是机器可验证的契约。
AI 生成的任何模块间引用，必须在 dependencies 中声明。
编译器是法官，"我忘了声明"不是借口。
```

### 铁律 2：编译即反馈

```
zig build 的编译错误是 AI 最好的反馈信号。
永远在 AI 生成代码后立即编译。
编译通过 ≠ 正确，但编译不通过 = 一定不正确。
```

### 铁律 3：模块是原子

```
AI 一次只改一个模块。
跨模块的变更分批进行：先改依赖方，编译通过，再改被依赖方。
每个模块有独立的测试，变更后只跑受影响的测试。
```

### 铁律 4：显式胜于隐式

```
allocator 必须显式传递。
类型必须明确声明。
依赖必须在 info 中列出。
"AI 应该知道的" → 不存在这个概念，所有约定必须编码为编译器可检查的规则。
```

### 铁律 5：渐进即设计

```
不要一开始就做分布式。
阶段 1（单体）→ 阶段 2（缓存+池）→ 阶段 3（分布式EventBus）
每个阶段都有对应的框架能力解锁。
AI 生成的代码应匹配当前阶段，不过度工程化。
```

---

## 附录 A：AI Prompt 模板库

### 模板 1：创建新模块
```
基于 ZigModu 框架，创建模块 [模块名]。
职责：[一句话描述]
依赖：[列出依赖模块，用逗号分隔]

生成 module.zig 文件，包含：
1. zigmodu.api.Module info 声明
2. init() 和 deinit() 函数骨架
3. 模块级 Config 结构体
4. 一个单元测试支架

遵循 ZigModu 的三明治结构（声明层 → 实现层 → 测试层）。
```

### 模板 2：添加业务函数
```
在 src/modules/[模块名]/module.zig 中添加函数 [函数名]。
参数：[列出参数和类型]
返回：[返回类型和错误类型]
功能：[描述业务逻辑]

要求：
- 使用 std.mem.Allocator 作为第一个参数
- 每个错误路径返回具体的 ZigModuError 变体
- 使用 defer 确保资源释放
- 添加对应的单元测试
```

### 模板 3：添加事件集成
```
在模块 [模块A] 中发布事件 [事件名]，在模块 [模块B] 中订阅。
使用 zigmodu.TypedEventBus 编译期类型安全。
事件结构体包含字段：[列出字段名和类型]

要求：
- 发布端：在业务函数中发布事件
- 订阅端：在 init() 中订阅，deinit() 中取消订阅
- 添加集成测试验证事件传递
```

### 模板 4：架构验证
```
为项目生成 ArchitectureTester 规则：
1. 验证无循环依赖
2. 验证 order 模块只依赖 {inventory, user}
3. 验证 payment 模块不直接访问 order 的内部实现
4. 生成 PlantUML 模块图

所有规则编码为 zig build test 可执行的测试。
```

---

## 附录 B：AI 自我检查清单

AI 每生成一段代码后，应自问：

- [ ] 所有 `@import` 的外部模块是否在 `info.dependencies` 中声明？
- [ ] 是否有 `allocator.free` 匹配每个 `allocator.alloc`？
- [ ] `init()` 中的资源是否有对应的 `deinit()` 清理？
- [ ] 模块是否只做一件事（单一职责）？
- [ ] 函数是否在 50 行以内？
- [ ] 是否避免使用不必要的 `anyopaque` / `@ptrCast`？
- [ ] 是否添加了测试？
- [ ] `zig build test` 是否通过？

---

## 参考

- [ZigModu Architecture Guide](ARCHITECTURE.md)
- [ZigModu Best Practices](BEST_PRACTICES.md)
- [Zig 0.16.0 Language Reference](https://ziglang.org/documentation/0.16.0/)
- [Spring Modulith Reference](https://docs.spring.io/spring-modulith/reference/)
- [Hayashibara et al. "The φ Accrual Failure Detector"](https://www.researchgate.net/publication/221034039_The_φ_Accrual_Failure_Detector)

---

*方法论是一个活文档。每次 AI 协作中发现新模式或反模式，应更新本文档。*
