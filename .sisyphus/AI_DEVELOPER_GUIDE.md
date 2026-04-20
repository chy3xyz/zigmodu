# ZigModu AI Developer Guide

让 AI 更流畅、更方便地使用 ZigModu 框架开发。

## 1. 项目配置文件

在使用 ZigModu 的项目中，创建以下文件让 AI 自动识别：

### `.sisyphus/skills/zigmodu.md` (技能)

```markdown
# ZigModu 开发技能

使用 ZigModu 框架开发的最佳实践和模式。

## 必须遵循的约束

- **Zig 版本**: 必须严格使用 Zig 0.16.0
- **build.zig.zon**: `.name` 必须是枚举字面量（`.myapp`），不是字符串（`"myapp"`）
- **build.zig**: 使用 `root_module = b.createModule(...)` 而不是 `root_source_file`
- **模块定义**: 模块必须有 `info` 和 `init()/deinit()` 函数

## 常见模式

### 创建新模块

```zig
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "mymodule",
    .description = "我的模块",
    .dependencies = &.{"dependency1"},
};

pub fn init() !void {
    // 初始化逻辑
}

pub fn deinit() void {
    // 清理逻辑
}
```

### 应用入口点

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const mymodule = @import("mymodule.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    
    var modules = try zigmodu.scanModules(allocator, .{ mymodule });
    defer modules.deinit();
    
    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
}
```
```

### `.sisyphus/plans/zigmodu-development.md` (计划模板)

```markdown
# ZigModu 项目开发计划

## 概述
使用 ZigModu 框架开发项目的标准流程。

## 阶段 1: 项目初始化
- [ ] 使用 `zmodu new <项目名>` 创建项目
- [ ] 配置 build.zig 和 build.zig.zon
- [ ] 验证 zig build 和 zig build test 通过

## 阶段 2: 模块设计
- [ ] 识别业务领域，划分模块边界
- [ ] 定义模块依赖关系
- [ ] 使用 `zmodu module <模块名>` 生成模块骨架

## 阶段 3: 实现
- [ ] 实现模块 init/deinit 函数
- [ ] 添加业务逻辑
- [ ] 集成 EventBus 实现事件驱动
- [ ] 使用 DI Container 管理依赖

## 阶段 4: 测试
- [ ] 使用 ModuleTestContext 编写模块测试
- [ ] 运行 zig build test 验证
```

---

## 2. 代码生成工具

使用已有的 `zmodu` 命令行工具快速生成代码：

```bash
# 创建新项目
zmodu new myproject

# 生成模块
zmodu module user

# 生成事件
zmodu event order-created

# 生成 API
zmodu api users --module user

# 从 SQL 生成完整 ORM 模块
zmodu orm --sql schema.sql --out src/modules
```

---

## 3. 让 AI 使用这些文件的步骤

1. 在项目根目录创建 `.sisyphus/` 文件夹
2. 将上述技能和计划模板放入相应子文件夹
3. AI 会自动识别并遵循 ZigModu 的最佳实践
4. 使用 `zmodu` 命令生成代码骨架，AI 填充业务逻辑

---

## 4. 额外的 AI 提示

在向 AI 提问时，可以加上：

> "使用 ZigModu 框架的最佳实践。参考 AGENTS.md 和 .sisyphus/skills/zigmodu.md。"

这会让 AI 自动遵循框架约定。
