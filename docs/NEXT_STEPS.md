# ZigModu 功能对比与行动计划

## 📊 核心差距分析

基于与 Spring Modulith 的深入对比，以下是关键发现：

### ✅ 已实现 (65%)
- 基础模块系统（定义、扫描、生命周期）
- 事件总线（类型安全）
- 架构验证（循环依赖、规则检查）
- 文档生成（PlantUML、C4 模型）
- 依赖注入（基础容器）
- 应用管理（新 API）

### ❌ 缺失 (35%)
1. **编译时模块边界检查** - 无法阻止非法导入
2. **声明式事件系统** - 缺少 @PublishedEvent、自动监听
3. **完整测试框架** - 缺少 @ModulithTest、事件断言
4. **事务性事件** - 无 ACID 保证
5. **事件外部化** - 无消息队列集成
6. **事件存储** - 无回放能力
7. **持久化集成** - 无数据库支持
8. **高级配置** - 仅 JSON，无类型安全

---

## 🎯 立即行动项

### 本周任务 (高优先级)

#### 1. 修复现有问题
- [ ] ModuleInfo 使用指针存储（HashMap resize 问题）
- [ ] 添加更多错误类型和上下文
- [ ] 完善日志记录

#### 2. 编译时边界检查 MVP
```zig
// src/core/ModuleBoundary.zig
pub fn validate(comptime module: type) void {
    // 检查：只导出允许的符号
    // 检查：不直接导入其他模块内部
}
```

**预期产出**: 能检测非法导出的基础验证器

### 下周任务 (高优先级)

#### 3. 声明式事件发布
```zig
// 目标 API
const OrderService = struct {
    pub fn completeOrder(...) !Order {
        // 业务逻辑
        return order;  // 自动发布 OrderCompleted
    }
};
```

**实现思路**: 
- 编译时代码生成
- 返回类型元数据
- EventBus 集成

#### 4. 自动监听器注册
```zig
// 目标 API
const OrderListener = struct {
    pub fn handleOrderCompleted(self: *Self, event: OrderCompleted) !void {
        // 自动注册到 EventBus
    }
};
```

**实现思路**:
- 编译时扫描方法
- 按优先级排序
- 启动时注册

---

## 📋 技术决策

### 决策 1: 编译时 vs 运行时检查

**选项 A**: 纯编译时（推荐初期）
- ✅ 零运行时开销
- ✅ 即时反馈
- ❌ 无法检查动态依赖

**选项 B**: 混合模式（长期）
- ✅ 更灵活
- ✅ 支持动态场景
- ❌ 复杂度增加

**决策**: 先实现编译时检查，后续考虑运行时验证

### 决策 2: 事件系统架构

**选项 A**: 集成 zio（推荐）
- ✅ 成熟异步运行时
- ✅ 与现有依赖一致
- ❌ 学习曲线

**选项 B**: 自建简单执行器
- ✅ 零额外依赖
- ✅ 完全控制
- ❌ 维护成本

**决策**: 使用 zio 实现异步事件

### 决策 3: 配置格式

**选项 A**: TOML（推荐）
- ✅ Zig 生态标准
- ✅ 类型安全
- ✅ 易读易写

**选项 B**: 自定义 DSL
- ✅ 完全控制
- ❌ 生态工具少

**决策**: 实现 TOML 配置支持

---

## 🚀 快速实施指南

### Step 1: 创建边界检查 (2 天)

```bash
# 创建文件
touch src/core/ModuleBoundary.zig

# 实现基础检查
# 1. 检查模块是否有 info 声明
# 2. 检查导出是否符合规范
# 3. 在 scanModules 中调用
```

### Step 2: 增强事件系统 (3 天)

```bash
# 修改 EventBus
# 1. 添加元数据支持
# 2. 实现发布者 trait
# 3. 实现监听器自动注册

# 添加示例
touch examples/event-driven/main.zig
```

### Step 3: 测试框架 (2 天)

```bash
# 创建测试框架
touch src/test/ModulithTest.zig

# 实现
# 1. 模块隔离
# 2. 事件捕获
# 3. 断言 DSL
```

---

## 📈 成功指标

完成这些功能后：

1. **编译时安全**: 非法模块导入无法编译
2. **事件系统**: 支持声明式和命令式发布
3. **测试**: 模块隔离测试正常工作
4. **文档**: 所有功能有完整文档和示例

**预期完成度**: 65% → 85%

---

## 💡 关键代码模式

### 模式 1: 编译时验证
```zig
comptime {
    // 验证模块
    const violations = analyzeModule(OrderModule);
    if (violations.len > 0) {
        @compileError("Module boundary violations");
    }
}
```

### 模式 2: 声明式事件
```zig
// 元数据标记
pub const EventMetadata = struct {
    pub const published_events = &[_]type{OrderCompleted};
};

// 自动发布
pub fn completeOrder(...) !Order {
    // 编译时生成：发布后处理逻辑
    defer publishEvent(OrderCompleted{...});
    return order;
}
```

### 模式 3: 测试隔离
```zig
test "scenario" {
    var ctx = try ModulithTest(.{Module1}).init(allocator);
    defer ctx.deinit();
    
    // 自动启动、捕获事件、验证
}
```

---

## 🎓 学习资源

### Spring Modulith 参考
- [官方文档](https://spring.io/projects/spring-modulith)
- [示例项目](https://github.com/spring-projects/spring-modulith)

### Zig 相关
- [Comptime 指南](https://ziglang.org/documentation/master/#comptime)
- [元编程模式](https://ziglang.org/learn/samples/)

---

## 🤝 贡献指南

想帮助实现这些功能？

1. 从 **ModuleBoundary** 开始（入门级）
2. 查看 `docs/P0_IMPLEMENTATION_PLAN.md` 了解详情
3. 提交 PR 前运行 `zig build test`
4. 添加文档和示例

---

## 📞 下一步

1. **审查**: 评审功能对比文档
2. **优先级**: 确认 P0 功能优先级
3. **分工**: 分配实现任务
4. **迭代**: 每周检查进度

**目标**: 6 周内达到 85% 功能完成度

---

*最后更新: 2025-01-09*
*版本: v0.2.0 规划*
