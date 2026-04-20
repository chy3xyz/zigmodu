# ZigModu Framework Development

使用 ZigModu 框架开发的最佳实践和模式。

---

## 必须遵循的约束

### 1. Zig 版本
- **必须严格使用 Zig 0.16.0**
- 不要使用更新或更旧的版本

### 2. build.zig.zon 格式
```zig
.{
    .name = .myapp,  // 必须是枚举字面量，不是字符串！
    .version = "0.1.0",
    .fingerprint = 0x7aa42d07b32f8d53,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zigmodu = .{
            .url = "https://github.com/chy3xyz/zigmodu/archive/refs/tags/v0.6.5.tar.gz",
            .hash = "1220xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### 3. build.zig 格式
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 使用 root_module，不是 root_source_file！
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 添加 zigmodu 依赖
    const zigmodu_dep = b.dependency("zigmodu", .{});
    exe.root_module.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    b.installArtifact(exe);
}
```

### 4. 模块定义
```zig
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "mymodule",                    // 唯一模块名
    .description = "我的模块",
    .dependencies = &.{"dependency1"},    // 依赖作为字符串字面量数组
    .is_internal = false,
};

pub fn init() !void {
    // 初始化逻辑
}

pub fn deinit() void {
    // 清理逻辑
}
```

### 5. 应用入口点
```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const mymodule = @import("mymodule.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    
    // 必须的顺序：
    var modules = try zigmodu.scanModules(allocator, .{ mymodule });
    defer modules.deinit();
    
    try zigmodu.validateModules(&modules);
    try zigmodu.generateDocs(&modules, "modules.puml", allocator);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
}
```

---

## 常见模式

### 使用 zmodu 代码生成工具
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

### EventBus 使用
```zig
const OrderCreated = struct {
    order_id: u64,
    total: f64,
};

var bus = zigmodu.EventBus(OrderCreated).init(allocator);
try bus.subscribe(handleOrderCreated);
bus.publish(.{ .order_id = 123, .total = 99.99 });
```

### DI Container 使用
```zig
var container = zigmodu.Container.init(allocator);
try container.register(Database, "db", &db);
const db = container.get(Database, "db");
```

---

## 验证检查清单

开发完成后，请验证：
- [ ] `zig build` 编译成功
- [ ] `zig build test` 所有测试通过
- [ ] `zig build run` 运行正常
- [ ] 模块 init/deinit 函数正确调用
- [ ] 内存正确清理

---

## 快速命令参考

- `zig build` - 编译项目
- `zig build test` - 运行测试
- `zig build run` - 运行示例应用
- `zmodu new <name>` - 创建新项目
- `zmodu module <name>` - 生成模块
- `zmodu orm --sql <file>` - 从 SQL 生成 ORM
