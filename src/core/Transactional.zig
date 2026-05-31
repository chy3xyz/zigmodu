const std = @import("std");

/// [...]Transaction[...]
/// [...] Spring @Transactional [...]Transaction[...]
/// High-priority architecture improvement item
pub const Transactional = struct {
    const Self = @This();

    /// Transaction[...]
    pub const Propagation = enum {
        /// REQUIRED: [...]Transaction[...]Transaction[...]Transaction[...]
        REQUIRED,

        /// SUPPORTS: [...]Transaction[...]Transaction[...]Transaction[...]
        SUPPORTS,

        /// MANDATORY: [...]Transaction[...]Transaction[...]
        MANDATORY,

        /// REQUIRES_NEW: [...]Transaction[...]Transaction[...]Transaction
        REQUIRES_NEW,

        /// NOT_SUPPORTED: [...]Transaction[...]Transaction[...]Transaction
        NOT_SUPPORTED,

        /// NEVER: [...]Transaction[...]Transaction[...]
        NEVER,

        /// NESTED: [...]Transaction[...]Transaction[...]Transaction
        NESTED,
    };

    /// Transaction[...]
    pub const Isolation = enum {
        /// DEFAULT: Use database default isolation level
        DEFAULT,

        /// READ_UNCOMMITTED: [...]
        READ_UNCOMMITTED,

        /// READ_COMMITTED: [...]
        READ_COMMITTED,

        /// REPEATABLE_READ: [...]
        REPEATABLE_READ,

        /// SERIALIZABLE: [...]
        SERIALIZABLE,
    };

    /// Transaction[...]
    pub const Definition = struct {
        /// Transaction[...]for[...]
        name: []const u8 = "",

        /// [...]
        propagation: Propagation = .REQUIRED,

        /// [...]
        isolation: Isolation = .DEFAULT,

        /// [...]-1 [...]
        timeout: i32 = -1,

        /// [...]Transaction
        read_only: bool = false,

        /// [...]RuntimeException[...]
        rollback_for: []const []const u8 = &.{},

        /// Which exceptions to not rollback on
        no_rollback_for: []const []const u8 = &.{},
    };

    /// Transaction[...]
    pub const Status = struct {
        definition: Definition,
        is_new_transaction: bool,
        is_rollback_only: bool,
        is_completed: bool,
        start_time: i64,
    };

    /// Transaction[...]
    pub const TransactionCallback = struct {
        ctx: *anyopaque,
        execute_fn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Transaction[...]
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

    /// Transaction[...] - [...]Transaction[...]
    pub const TransactionTemplate = struct {
        transaction_manager: TransactionManager,
        definition: Definition,

        /// [...]Transaction[...]
        pub fn execute(self: TransactionTemplate, callback: TransactionCallback) !void {
            const status = try self.transaction_manager.begin(self.definition);
            errdefer {
                if (!status.is_completed) {
                    self.transaction_manager.rollback(status) catch |e| {
                        std.log.err("Rollback transactionfailure: {}", .{e});
                    };
                }
            }

            callback.execute_fn(callback.ctx) catch |err| {
                // Check if[...]
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
            // [...]Error[...]
            _ = definition;
            _ = @errorName(err);
            return true;
        }
    };

    /// [...]Transaction[...]for[...]
    pub const Attribute = struct {
        definition: Definition,
        target_method: []const u8,
        target_type: []const u8,
    };

    /// Transaction[...]
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
            self.* = undefined;
        }

        /// [...]Transaction[...]
        pub fn register(self: *Interceptor, method_signature: []const u8, definition: Definition) !void {
            try self.attributes.put(method_signature, definition);
        }

        /// [...]call
        pub fn invoke(self: *Interceptor, method_signature: []const u8, comptime ResultType: type, action: fn () anyerror!ResultType) !ResultType {
            const definition = self.attributes.get(method_signature) orelse {
                // [...]Transaction[...]
                return action();
            };

            const template = TransactionTemplate{
                .transaction_manager = self.transaction_manager,
                .definition = definition,
            };

            // [...]
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

    /// [...]Transaction[...]forTests[...]
    pub const InMemoryTransactionManager = struct {
        const TMContext = struct {
            transactions: std.array_list.Managed(Status),
            allocator: std.mem.Allocator,
        };

        ctx: *TMContext,
        manager: TransactionManager,

        pub fn init(allocator: std.mem.Allocator) !InMemoryTransactionManager {
            const ctx = try allocator.create(TMContext);
            ctx.* = .{
                .transactions = std.array_list.Managed(Status).init(allocator),
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
            self.* = undefined;
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
                .start_time = 0,
            };

            try tm_ctx.transactions.append(status);

            std.log.info("[Transaction] begin: {s}, propagation: {s}, isolation: {s}", .{
                definition.name,
                @tagName(definition.propagation),
                @tagName(definition.isolation),
            });

            return status;
        }

        fn commitTransaction(ctx: *anyopaque, status: Status) !void {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            if (status.is_rollback_only) {
                std.log.warn("[Transaction] marked rollback-only, rolling back", .{});
                return rollbackTransaction(ctx, status);
            }

            std.log.info("[Transaction] commit: {s}", .{status.definition.name});

            // [...]Transaction
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }

        fn rollbackTransaction(ctx: *anyopaque, status: Status) !void {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            std.log.info("[Transaction] rollback: {s}", .{status.definition.name});

            // [...]Transaction
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }
    };

    /// [...]Transaction[...]
    /// [...]:
    /// ```zig
    /// try Transactional.run(tm, .{ .name = "createOrder" }, struct {
    ///     fn exec() !void {
    /// // [...]
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

// Tests
test "Transactional basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tm = try Transactional.InMemoryTransactionManager.init(allocator);
    defer tm.deinit();

    const definition = Transactional.Definition{
        .name = "test_tx",
        .propagation = .REQUIRED,
    };

    // Testssuccess[...]
    try Transactional.run(tm.getManager(), definition, struct {
        fn exec() !void {
            std.log.info("execute business logic", .{});
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

    // Tests[...]
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
