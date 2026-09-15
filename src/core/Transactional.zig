const std = @import("std");

/// Declarative transaction support
/// Provides Spring @Transactional-style transaction management
/// High-priority architecture improvement item
pub const Transactional = struct {
    const Self = @This();

    /// Transaction propagation behavior
    pub const Propagation = enum {
        /// REQUIRED: join the current transaction if one exists, otherwise create a new one (default)
        REQUIRED,

        /// SUPPORTS: join the current transaction if one exists, otherwise run without a transaction
        SUPPORTS,

        /// MANDATORY: join the current transaction if one exists, otherwise raise an error
        MANDATORY,

        /// REQUIRES_NEW: create a new transaction, suspending the current one if it exists
        REQUIRES_NEW,

        /// NOT_SUPPORTED: run without a transaction, suspending the current one if it exists
        NOT_SUPPORTED,

        /// NEVER: run without a transaction, raising an error if one exists
        NEVER,

        /// NESTED: run inside a nested transaction if one exists, otherwise create a new one
        NESTED,
    };

    /// Transaction isolation level
    pub const Isolation = enum {
        /// DEFAULT: Use database default isolation level
        DEFAULT,

        /// READ_UNCOMMITTED: reads changes made by other uncommitted transactions
        READ_UNCOMMITTED,

        /// READ_COMMITTED: only sees changes committed by other transactions
        READ_COMMITTED,

        /// REPEATABLE_READ: repeated reads of the same row return the same value
        REPEATABLE_READ,

        /// SERIALIZABLE: transactions behave as if executed one after another
        SERIALIZABLE,
    };

    /// Transaction definition
    pub const Definition = struct {
        /// Transaction name (optional, used for monitoring and logs)
        name: []const u8 = "",

        /// Propagation behavior
        propagation: Propagation = .REQUIRED,

        /// Isolation level
        isolation: Isolation = .DEFAULT,

        /// Timeout in seconds, -1 means use the default
        timeout: i32 = -1,

        /// Whether the transaction is read-only
        read_only: bool = false,

        /// Exceptions that trigger a rollback (empty means all RuntimeException)
        rollback_for: []const []const u8 = &.{},

        /// Which exceptions to not rollback on
        no_rollback_for: []const []const u8 = &.{},
    };

    /// Transaction status
    pub const Status = struct {
        definition: Definition,
        is_new_transaction: bool,
        is_rollback_only: bool,
        is_completed: bool,
        start_time: i64,
    };

    /// Transaction callback interface
    pub const TransactionCallback = struct {
        ctx: *anyopaque,
        execute_fn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Transaction manager interface
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

    /// Transaction template - simplifies transaction execution
    pub const TransactionTemplate = struct {
        transaction_manager: TransactionManager,
        definition: Definition,

        /// Execute a callback inside a transaction
        pub fn execute(self: TransactionTemplate, callback: TransactionCallback) !void {
            const status = try self.transaction_manager.begin(self.definition);
            errdefer {
                if (!status.is_completed) {
                    self.transaction_manager.rollback(status) catch |e| {
                        std.log.err("Rollback transaction failed: {}", .{e});
                    };
                }
            }

            callback.execute_fn(callback.ctx) catch |err| {
                // Check whether a rollback is needed
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
            // By default all errors trigger a rollback
            _ = definition;
            _ = @errorName(err);
            return true;
        }
    };

    /// Declarative transaction attribute (for code generation or metadata)
    pub const Attribute = struct {
        definition: Definition,
        target_method: []const u8,
        target_type: []const u8,
    };

    /// Transaction interceptor
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

        /// Register a transaction attribute for a method
        pub fn register(self: *Interceptor, method_signature: []const u8, definition: Definition) !void {
            try self.attributes.put(method_signature, definition);
        }

        /// Intercept a method call
        pub fn invoke(self: *Interceptor, method_signature: []const u8, comptime ResultType: type, action: fn () anyerror!ResultType) !ResultType {
            const definition = self.attributes.get(method_signature) orelse {
                // No transaction configured, execute directly
                return action();
            };

            const template = TransactionTemplate{
                .transaction_manager = self.transaction_manager,
                .definition = definition,
            };

            // Use a struct to carry the result
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

    /// In-memory transaction manager (for tests)
    pub const InMemoryTransactionManager = struct {
        const TMContext = struct {
            transactions: std.array_list.Managed(Status),
            allocator: std.mem.Allocator,
        };

        ctx: *TMContext,
        manager: TransactionManager,

        pub fn init(allocator: std.mem.Allocator) !InMemoryTransactionManager {
            const ctx = try allocator.create(TMContext);
            errdefer allocator.destroy(ctx);
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

            // Remove the transaction from the tracked list
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }

        fn rollbackTransaction(ctx: *anyopaque, status: Status) !void {
            const tm_ctx = @as(*TMContext, @ptrCast(@alignCast(ctx)));

            std.log.info("[Transaction] rollback: {s}", .{status.definition.name});

            // Remove the transaction from the tracked list
            if (tm_ctx.transactions.items.len > 0) {
                _ = tm_ctx.transactions.pop();
            }
        }
    };

    /// Convenience helper: run an operation inside a transaction
    /// Usage example:
    /// ```zig
    /// try Transactional.run(tm, .{ .name = "createOrder" }, struct {
    ///     fn exec() !void {
    ///         // business logic
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

    // Test a successful commit
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

    // Test rollback
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
