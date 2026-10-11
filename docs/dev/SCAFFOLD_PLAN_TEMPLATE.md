# ZigModu 项目开发计划

使用 ZigModu 框架开发项目的标准计划模板。

---

## 阶段 1: 项目初始化
- [ ] 使用 `zmodu new <项目名>` 创建项目
- [ ] 配置 build.zig 和 build.zig.zon
- [ ] 验证 `zig build` 和 `zig build test` 通过

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
- [ ] 运行 `zig build test` 验证

---

## 常见问题

### Q: 如何在模块间共享数据？
A: 使用 EventBus 进行模块间通信，避免直接依赖。

### Q: 如何管理数据库连接？
A: 使用 sqlx 模块，通过 DI Container 注入。

### Q: 模块依赖验证失败怎么办？
A: 检查 `info.dependencies` 声明的顺序，确保依赖在被依赖模块之前注册。
