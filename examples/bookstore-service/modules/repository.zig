const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Repository Pattern - 仓储模式基础模块
/// 提供通用的数据访问抽象
/// ============================================
/// 通用仓储接口
pub fn Repository(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        table_name: []const u8,
        items: std.ArrayList(T),
        id_counter: u64,

        pub fn init(alloc: std.mem.Allocator, table: []const u8) !Self {
            return Self{
                .allocator = alloc,
                .table_name = try alloc.dupe(u8, table),
                .items = std.ArrayList(T){},
                .id_counter = 1,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.table_name);
            self.items.deinit(self.allocator);
        }

        /// 插入实体
        pub fn insert(self: *Self, entity: T) !T {
            var new_entity = entity;

            // 自动设置ID
            if (@hasField(T, "id")) {
                if (new_entity.id == 0) {
                    new_entity.id = self.id_counter;
                    self.id_counter += 1;
                }
            }

            // 自动设置时间戳
            if (@hasField(T, "created_at")) {
                new_entity.created_at = std.time.timestamp();
            }
            if (@hasField(T, "updated_at")) {
                new_entity.updated_at = std.time.timestamp();
            }

            try self.items.append(self.allocator, new_entity);

            std.log.info("[repository] Inserted into {s}: id={d}", .{ self.table_name, new_entity.id });

            return new_entity;
        }

        /// 根据ID查找
        pub fn findById(self: *Self, id: u64) ?*T {
            for (self.items.items) |*item| {
                if (@hasField(T, "id")) {
                    if (item.id == id) {
                        return item;
                    }
                }
            }
            return null;
        }

        /// 查找所有
        pub fn findAll(self: *Self) []T {
            return self.items.items;
        }

        /// 条件查找
        pub fn findBy(self: *Self, comptime field: []const u8, value: anytype) ![]T {
            var results = std.ArrayList(T){};

            for (self.items.items) |item| {
                if (@hasField(T, field)) {
                    const field_value = @field(item, field);
                    if (std.meta.eql(field_value, value)) {
                        try results.append(self.allocator, item);
                    }
                }
            }

            return results.toOwnedSlice(self.allocator);
        }

        /// 更新实体
        pub fn update(self: *Self, id: u64, updater: fn (*T) void) !?T {
            var entity = self.findById(id) orelse return null;

            updater(entity);

            if (@hasField(T, "updated_at")) {
                entity.updated_at = std.time.timestamp();
            }

            std.log.info("[repository] Updated {s}: id={d}", .{ self.table_name, id });

            return entity.*;
        }

        /// 删除实体
        pub fn delete(self: *Self, id: u64) !bool {
            for (self.items.items, 0..) |item, index| {
                if (@hasField(T, "id")) {
                    if (item.id == id) {
                        _ = self.items.orderedRemove(index);
                        std.log.info("[repository] Deleted from {s}: id={d}", .{ self.table_name, id });
                        return true;
                    }
                }
            }
            return false;
        }

        /// 计数
        pub fn count(self: *Self) usize {
            return self.items.items.len;
        }

        /// 分页查询
        pub fn findPage(self: *Self, page: u32, page_size: u32) []T {
            const start = page * page_size;
            const end = @min(start + page_size, self.items.items.len);

            if (start >= self.items.items.len) {
                return &[_]T{};
            }

            return self.items.items[start..end];
        }

        /// 执行原生查询（模拟）
        pub fn executeQuery(self: *Self, sql: []const u8, params: anytype) !void {
            _ = self;
            _ = sql;
            _ = params;
            // 实际实现会执行SQL
        }
    };
}

/// 事务管理器
pub const TransactionManager = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(Operation),
    is_active: bool,

    const Operation = union(enum) {
        insert: struct { table: []const u8, data: []const u8 },
        update: struct { table: []const u8, id: u64, data: []const u8 },
        delete: struct { table: []const u8, id: u64 },
    };

    pub fn init(alloc: std.mem.Allocator) TransactionManager {
        return TransactionManager{
            .allocator = alloc,
            .operations = std.ArrayList(Operation){},
            .is_active = false,
        };
    }

    pub fn deinit(self: *TransactionManager) void {
        for (self.operations.items) |*op| {
            switch (op.*) {
                .insert => |insert| self.allocator.free(insert.data),
                .update => |update| self.allocator.free(update.data),
                .delete => {},
            }
        }
        self.operations.deinit(self.allocator);
    }

    /// 开始事务
    pub fn begin(self: *TransactionManager) !void {
        if (self.is_active) {
            return error.TransactionAlreadyActive;
        }
        self.is_active = true;
        self.operations.clearRetainingCapacity();
        std.log.info("[transaction] Transaction started", .{});
    }

    /// 提交事务
    pub fn commit(self: *TransactionManager) !void {
        if (!self.is_active) {
            return error.NoActiveTransaction;
        }

        // 实际实现会在这里执行所有操作
        std.log.info("[transaction] Transaction committed with {d} operations", .{self.operations.items.len});

        self.is_active = false;
        self.operations.clearRetainingCapacity();
    }

    /// 回滚事务
    pub fn rollback(self: *TransactionManager) !void {
        if (!self.is_active) {
            return error.NoActiveTransaction;
        }

        // 清理操作记录
        for (self.operations.items) |*op| {
            switch (op.*) {
                .insert => |insert| self.allocator.free(insert.data),
                .update => |update| self.allocator.free(update.data),
                .delete => {},
            }
        }
        self.operations.clearRetainingCapacity();
        self.is_active = false;

        std.log.info("[transaction] Transaction rolled back", .{});
    }

    /// 添加插入操作
    pub fn addInsert(self: *TransactionManager, table: []const u8, data: []const u8) !void {
        if (!self.is_active) {
            return error.NoActiveTransaction;
        }

        const op = Operation{
            .insert = .{
                .table = try self.allocator.dupe(u8, table),
                .data = try self.allocator.dupe(u8, data),
            },
        };

        try self.operations.append(self.allocator, op);
    }

    /// 添加更新操作
    pub fn addUpdate(self: *TransactionManager, table: []const u8, id: u64, data: []const u8) !void {
        if (!self.is_active) {
            return error.NoActiveTransaction;
        }

        const op = Operation{
            .update = .{
                .table = try self.allocator.dupe(u8, table),
                .id = id,
                .data = try self.allocator.dupe(u8, data),
            },
        };

        try self.operations.append(self.allocator, op);
    }

    /// 添加删除操作
    pub fn addDelete(self: *TransactionManager, table: []const u8, id: u64) !void {
        if (!self.is_active) {
            return error.NoActiveTransaction;
        }

        const op = Operation{
            .delete = .{
                .table = try self.allocator.dupe(u8, table),
                .id = id,
            },
        };

        try self.operations.append(self.allocator, op);
    }

    /// 获取操作数量
    pub fn operationCount(self: *TransactionManager) usize {
        return self.operations.items.len;
    }

    /// 是否处于活动状态
    pub fn isActive(self: *TransactionManager) bool {
        return self.is_active;
    }
};

/// 查询构建器
pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    conditions: std.ArrayList(Condition),
    order_by_field: ?[]const u8,
    order_desc: bool,
    limit_count: ?u32,
    offset_count: ?u32,

    const Condition = struct {
        field: []const u8,
        operator: []const u8,
        value: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator, table: []const u8) !QueryBuilder {
        return QueryBuilder{
            .allocator = alloc,
            .table_name = try alloc.dupe(u8, table),
            .conditions = std.ArrayList(Condition){},
            .order_by_field = null,
            .order_desc = false,
            .limit_count = null,
            .offset_count = null,
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        for (self.conditions.items) |cond| {
            self.allocator.free(cond.field);
            self.allocator.free(cond.operator);
            self.allocator.free(cond.value);
        }
        self.conditions.deinit(self.allocator);
        self.allocator.free(self.table_name);
        if (self.order_by_field) |field| {
            self.allocator.free(field);
        }
    }

    /// WHERE 条件
    pub fn where(self: *QueryBuilder, field: []const u8, operator: []const u8, value: []const u8) !*QueryBuilder {
        const cond = Condition{
            .field = try self.allocator.dupe(u8, field),
            .operator = try self.allocator.dupe(u8, operator),
            .value = try self.allocator.dupe(u8, value),
        };

        try self.conditions.append(self.allocator, cond);
        return self;
    }

    /// ORDER BY
    pub fn orderBy(self: *QueryBuilder, field: []const u8, desc: bool) !*QueryBuilder {
        if (self.order_by_field) |f| {
            self.allocator.free(f);
        }
        self.order_by_field = try self.allocator.dupe(u8, field);
        self.order_desc = desc;
        return self;
    }

    /// LIMIT
    pub fn limit(self: *QueryBuilder, count: u32) *QueryBuilder {
        self.limit_count = count;
        return self;
    }

    /// OFFSET
    pub fn offset(self: *QueryBuilder, count: u32) *QueryBuilder {
        self.offset_count = count;
        return self;
    }

    /// 构建SQL
    pub fn buildSql(self: *QueryBuilder) ![]const u8 {
        var sql = std.ArrayList(u8){};

        try sql.appendSlice(self.allocator, "SELECT * FROM ");
        try sql.appendSlice(self.allocator, self.table_name);

        // WHERE 子句
        if (self.conditions.items.len > 0) {
            try sql.appendSlice(self.allocator, " WHERE ");
            for (self.conditions.items, 0..) |cond, i| {
                if (i > 0) {
                    try sql.appendSlice(self.allocator, " AND ");
                }
                try sql.appendSlice(self.allocator, cond.field);
                try sql.appendSlice(self.allocator, " ");
                try sql.appendSlice(self.allocator, cond.operator);
                try sql.appendSlice(self.allocator, " ?");
            }
        }

        // ORDER BY
        if (self.order_by_field) |field| {
            try sql.appendSlice(self.allocator, " ORDER BY ");
            try sql.appendSlice(self.allocator, field);
            if (self.order_desc) {
                try sql.appendSlice(self.allocator, " DESC");
            }
        }

        // LIMIT
        if (self.limit_count) |count| {
            try sql.appendSlice(self.allocator, " LIMIT ");
            const limit_str = try std.fmt.allocPrint(self.allocator, "{d}", .{count});
            defer self.allocator.free(limit_str);
            try sql.appendSlice(self.allocator, limit_str);
        }

        // OFFSET
        if (self.offset_count) |count| {
            try sql.appendSlice(self.allocator, " OFFSET ");
            const offset_str = try std.fmt.allocPrint(self.allocator, "{d}", .{count});
            defer self.allocator.free(offset_str);
            try sql.appendSlice(self.allocator, offset_str);
        }

        return sql.toOwnedSlice(self.allocator);
    }
};

// 测试用例
test "Repository" {
    const TestEntity = struct {
        id: u64,
        name: []const u8,
        created_at: i64,
        updated_at: i64,
    };

    var repo = try Repository(TestEntity).init(std.testing.allocator, "test_entities");
    defer repo.deinit();

    // 插入实体
    const entity = try repo.insert(.{
        .id = 0,
        .name = "Test",
        .created_at = 0,
        .updated_at = 0,
    });

    try std.testing.expectEqual(@as(u64, 1), entity.id);

    // 查找实体
    const found = repo.findById(1);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Test", found.?.name);

    // 更新实体
    _ = try repo.update(1, struct {
        fn updater(e: *TestEntity) void {
            e.name = "Updated";
        }
    }.updater);

    const updated = repo.findById(1);
    try std.testing.expect(updated != null);
    try std.testing.expectEqualStrings("Updated", updated.?.name);

    // 删除实体
    const deleted = try repo.delete(1);
    try std.testing.expect(deleted);

    const not_found = repo.findById(1);
    try std.testing.expect(not_found == null);
}

test "TransactionManager" {
    var tm = TransactionManager.init(std.testing.allocator);
    defer tm.deinit();

    // 开始事务
    try tm.begin();
    try std.testing.expect(tm.isActive());

    // 添加操作
    try tm.addInsert("users", "{\"name\":\"test\"}");
    try tm.addUpdate("users", 1, "{\"name\":\"updated\"}");

    try std.testing.expectEqual(@as(usize, 2), tm.operationCount());

    // 提交事务
    try tm.commit();
    try std.testing.expect(!tm.isActive());
}

test "QueryBuilder" {
    var qb = try QueryBuilder.init(std.testing.allocator, "users");
    defer qb.deinit();

    _ = try qb.where("age", ">", "18")
        .orderBy("name", false)
        .limit(10)
        .offset(0);

    const sql = try qb.buildSql();
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT * FROM users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE age > ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 0") != null);
}
