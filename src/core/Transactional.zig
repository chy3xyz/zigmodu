const std = @import("std");

/// 声明式事务支持
/// 提供类似 Spring @Transactional 的事务管理能力
/// 这是架构评估中的高优先级改进项
pub const Transactional = struct {
    const Self = @This();

    /// 事务传播行为
    pub const Propagation = enum {
        /// REQUIRED: 如果当前存在事务，则加入该事务；否则创建新事务（默认）
        REQUIRED,

        /// SUPPORTS: 如果当前存在事务，则加入该事务；否则以非事务方式运行
        SUPPORTS,

        /// MANDATORY: 如果当前存在事务，则加入该事务；否则抛出异常
        MANDATORY,

        /// REQUIRES_NEW: 创建新事务，如果当前存在事务，则挂起当前事务
        REQUIRES_NEW,

        /// NOT_SUPPORTED: 以非事务方式运行，如果当前存在事务，则挂起当前事务
        NOT_SUPPORTED,

        /// NEVER: 以非事务方式运行，如果当前存在事务，则抛出异常
        NEVER,

        /// NESTED: 如果当前存在事务，则在嵌套事务内执行；否则创建新事务
        NESTED,
    };

    /// 事务隔离级别
    pub const Isolation = enum {
        /// DEFAULT: 使用数据库默认隔离级别
        DEFAULT,

        /// READ_UNCOMMITTED: 读未提交
        READ_UNCOMMITTED,

        /// READ_COMMITTED: 读已提交
        READ_COMMITTED,

        /// REPEATABLE_READ: 可重复读
        REPEATABLE_READ,

        /// SERIALIZABLE: 串行化
        SERIALIZABLE,
    };

    /// 事务定义
    pub const Definition = struct {
        /// 事务名称（可选，用于监控和日志）
        name: []const u8 = "",

        /// 传播行为
        propagation: Propagation = .REQUIRED,

        /// 隔离级别
        isolation: Isolation = .DEFAULT,

        /// 超时时间（秒），-1 表示使用默认
        timeout: i32 = -1,

        /// 是否只读事务
        read_only: bool = false,

        /// 遇到哪些异常时回滚（空数组表示所有RuntimeException）
        rollback_for: []const []const u8 = &.{},

        /// 遇到哪些异常时不回滚
        no_rollback_for: []const []const u8 = &.{},
    };

    /// 事务状态
    pub const Status = struct {
        definition: Definition,
        is_new_transaction: bool,
        is_rollback_only: bool,
        is_completed: bool,
        start_time: i64,
    };

    /// 事务回调接口
    pub const TransactionCallback = struct {
        ctx: *anyopaque,
        execute_fn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// 事务管理器接口
    pub const TransactionManager = struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            begin: *const fn (ctx: *anyopaque, definition: Definition) anyerror!Status,
            commit: *const fn (ctx: *anyopaque, status: Status) anyerror!void,
            rollback: *const fn (ctx: *anyopaque, status: Status) anyerror!void,
        };

        pub fn begin(self: TransactionManager, definition: Definition) !Status {
            return self.vtable.begin(self.ctx, definition);
        }

        pub fn commit(self: TransactionManager, status: Status) !void {
            return self.vtable.commit(self.ctx, status);
        }

        pub fn rollback(self: TransactionManager, status: Status) !void {
            return self.vtable.rollback(self.ctx, status);
        }
    };

    /// 事务模板 - 简化事务执行
    pub const TransactionTemplate = struct {
        transaction_manager: TransactionManager,
        definition: Definition,

        /// 执行带事务的回调
        pub fn execute(self: TransactionTemplate, callback: TransactionCallback) !void {
            const status = try self.transaction_manager.begin(self.definition);
            errdefer {
                if (!status.is_completed) {
                    self.transaction_manager.rollback(status) catch |e| {
                        std.log.err("回滚事务失败: {}", .{e});
                    };
                }
            }

            callback.execute_fn(callback.ctx) catch |err| {
                // 检查是否需要回滚
                if (shouldRollback(self.definition, err)) {
                    try self.transaction_manager.rollback(status);
                } else {
                    try self.transaction_manager.commit(status);
                }
                return err;
            };

            try self.transaction_manager.commit(status);
        }

        fn shouldRollback(definition: Definition, err: anyerror) bool {
            // 默认情况下，所有错误都回滚
            _ = definition;
            _ = err;
            return true;
        }
    };

    /// 声明式事务属性（用于代码生成或元数据）
    pub const Attribute = struct {
        definition: Definition,
        target_method: []const u8,
        target_type: []const u8,
    };

    /// 事务拦截器
    pub const Interceptor = struct {
        allocator: std.mem.Allocator,
        transaction_manager: TransactionManager,
        attributes: std.StringHashMap(Definition),

        pub fn init(allocator: std.mem.Allocator, tm: TransactionManager) Interceptor {
            return .{
                .allocator = allocator,
                .transaction_manager = tm,
                .attributes = std.StringHashMap(Definition).init(allocator),
            };
        }

        pub fn deinit(self: *Interceptor) void {
            self.attributes.deinit();
        }

        /// 为方法注册事务属性
        pub fn register(self: *Interceptor, method_signature: []const u8, definition: Definition) !void {
            try self.attributes.put(method_signature, definition);
        }

        /// 拦截方法调用
        pub fn invoke(self: *Interceptor, method_signature: []const u8, comptime ResultType: type, action: fn () anyerror!ResultType) !ResultType {
            const definition = self.attributes.get(method_signature) orelse {
                // 没有事务配置，直接执行
                return action();
            };

            const template = TransactionTemplate{
                .transaction_manager = self.transaction_manager,
                .definition = definition,
            };

            // 使用结构体包装结果
            const Context = struct {
                result: ?ResultType,
                action_error: ?anyerror,
            };

            var ctx = Context{
                .result = null,
                .action_error = null,
            };

            const callback = TransactionCallback{
                .ctx = &ctx,
                .execute_fn = struct {
                    fn execute(ptr: *anyopaque) !void {
                        const c = @as(*Context, @ptrCast(@alignCast(ptr)));
                        c.result = action() catch |err| {
                            c.action_error = err;
                            return err;
                        };
                    }
                }.execute,
            };

            template.execute(callback) catch |err| {
                if (ctx.action_error) |ae| {
                    return ae;
                }
                return err;
            };

            return ctx.result.?;
        }
    };

    /// 内存事务管理器（用于测试）
    pub const InMemoryTransactionManager = struct {
        const TMContext = struct {
            transactions: std.ArrayList(Status),
            allocator: std.mem.Allocator,
        };

        ctx: *TMContext,
        manager: TransactionManager,

        pub fn init(allocator: std.mem.Allocator) !InMemoryTransactionManager {
            const ctx = try allocator.create(TMContext);
            ctx.* = .{
                .transactions = std.ArrayList(Status).init(allocator),
                .allocator = allocator,
            };

            const vtable = &TransactionManager.VTable{
                .begin = beginTransaction,
                .commit = commitTransaction,
                .rollback = rollbackTransaction,
            };

            return .{
                .ctx = ctx,
                .manager = .{
                    .ctx = ctx,
                    .vtable = vtable,
                },
            };
        }

        pub fn deinit(self: *InMemoryTransactionManager) void {
            self.ctx.transactions.deinit();
            const allocator = self.ctx.allocator;
            allocator.destroy(self.ctx);
        }

        pub fn getManager(self: *InMemoryTransactionManager) TransactionManager {
            return self.manager;
        }

        fn beginTransaction(ctx: *anyopaque, definition: Definition) !Status {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            const status = Status{
                .definition = definition,
                .is_new_transaction = true,
                .is_rollback_only = false,
                .is_completed = false,
                .start_time = std.time.timestamp(),
            };

            try tm_ctx.transactions.append(status);

            std.log.info("[事务] 开始: {s}, 传播行为: {s}, 隔离级别: {s}", .{
                definition.name,
                @tagName(definition.propagation),
                @tagName(definition.isolation),
            });

            return status;
        }

        fn commitTransaction(ctx: *anyopaque, status: Status) !void {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            if (status.is_rollback_only) {
                std.log.warn("[事务] 事务标记为仅回滚，执行回滚", .{});
                return rollbackTransaction(ctx, status);
            }

            std.log.info("[事务] 提交: {s}", .{status.definition.name});

            // 移除事务
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }

        fn rollbackTransaction(ctx: *anyopaque, status: Status) !void {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            std.log.info("[事务] 回滚: {s}", .{status.definition.name});

            // 移除事务
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }
    };

    /// 便捷宏：执行带事务的操作
    /// 使用示例:
    /// ```zig
    /// try Transactional.run(tm, .{ .name = "createOrder" }, struct {
    ///     fn exec() !void {
    ///         // 业务逻辑
    ///     }
    /// }.exec);
    /// ```
    pub fn run(tm: TransactionManager, definition: Definition, comptime action: fn () anyerror!void) !void {
        const template = TransactionTemplate{
            .transaction_manager = tm,
            .definition = definition,
        };

        const callback = TransactionCallback{
            .ctx = @constCast(&action),
            .execute_fn = struct {
                fn execute(ctx: *anyopaque) !void {
                    const act = @as(*const fn () anyerror!void, @ptrCast(@alignCast(ctx)));
                    try act();
                }
            }.execute,
        };

        try template.execute(callback);
    }
};

// 测试
test "Transactional basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tm = try Transactional.InMemoryTransactionManager.init(allocator);
    defer tm.deinit();

    const definition = Transactional.Definition{
        .name = "test_tx",
        .propagation = .REQUIRED,
    };

    // 测试成功提交
    try Transactional.run(tm.getManager(), definition, struct {
        fn exec() !void {
            std.log.info("执行业务逻辑", .{});
        }
    }.exec);
}

test "Transactional rollback" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tm = try Transactional.InMemoryTransactionManager.init(allocator);
    defer tm.deinit();

    const definition = Transactional.Definition{
        .name = "test_rollback",
        .propagation = .REQUIRED,
    };

    // 测试回滚
    const result = Transactional.run(tm.getManager(), definition, struct {
        fn exec() !void {
            return error.TestError;
        }
    }.exec);

    try testing.expectError(error.TestError, result);
}

test "TransactionTemplate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tm = try Transactional.InMemoryTransactionManager.init(allocator);
    defer tm.deinit();

    const template = Transactional.TransactionTemplate{
        .transaction_manager = tm.getManager(),
        .definition = .{
            .name = "template_test",
        },
    };

    var executed = false;
    const callback = Transactional.TransactionCallback{
        .ctx = &executed,
        .execute_fn = struct {
            fn execute(ctx: *anyopaque) !void {
                const flag = @as(*bool, @ptrCast(@alignCast(ctx)));
                flag.* = true;
            }
        }.execute,
    };

    try template.execute(callback);
    try testing.expect(executed);
}
