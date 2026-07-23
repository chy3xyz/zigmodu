const std = @import("std");
const zent = @import("zent");

/// RAII wrapper for the standard zent store lifecycle:
/// open driver -> migrate schema -> make client -> close on deinit.
pub fn StoreEnv(comptime Driver: type, comptime Infos: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        driver: Driver,
        client: zent.codegen.client.Client(Infos),
        owns_driver: bool,

        const Self = @This();

        /// Open a file-backed store with default migrate options.
        pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
            return openWith(allocator, path, .{});
        }

        /// Open an in-memory store (single connection).
        pub fn inMemory(allocator: std.mem.Allocator) !Self {
            return open(allocator, ":memory:");
        }

        /// Open with explicit MigrateOptions.
        pub fn openWith(
            allocator: std.mem.Allocator,
            path: []const u8,
            opts: zent.sql_schema.MigrateOptions,
        ) !Self {
            var driver = try Driver.open(allocator, path);
            errdefer driver.close();

            try zent.sql_schema.migrateSchemaWithOptions(
                allocator,
                driver.asDriver(),
                Infos,
                opts,
            );

            return .{
                .allocator = allocator,
                .driver = driver,
                .client = zent.codegen.client.makeClient(Infos, allocator, driver.asDriver()),
                .owns_driver = true,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.owns_driver) {
                self.driver.close();
                self.owns_driver = false;
            }
        }
    };
}

/// Test environment factory: each instance is an isolated in-memory SQLite
/// store with fresh migrations. `reset()` drops all schema tables and
/// re-migrates them while retaining the same single SQLite connection.
pub fn TestEnv(comptime schemas: anytype) type {
    const Store = StoreEnv(zent.sql_sqlite.SQLiteDriver, schemas);

    return struct {
        allocator: std.mem.Allocator,
        store: Store,

        pub const Client = zent.codegen.client.Client(schemas);

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var store = try Store.inMemory(allocator);
            errdefer store.deinit();
            return .{ .allocator = allocator, .store = store };
        }

        /// Drop every schema table and the migration history, then migrate.
        pub fn reset(self: *Self) !void {
            const driver = self.store.driver.asDriver();
            inline for (schemas) |info| {
                const drop_sql = "DROP TABLE IF EXISTS \"" ++ info.table_name ++ "\"";
                _ = try driver.exec(drop_sql, &.{});
            }
            _ = try driver.exec("DROP TABLE IF EXISTS \"zent_schema_migrations\"", &.{});
            try zent.sql_schema.migrateSchema(self.allocator, driver, schemas);
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
        }
    };
}

comptime {
    if (!@hasDecl(zent.sql_schema, "migrateSchemaWithOptions")) {
        @compileError("zent_helpers requires zent.sql_schema.migrateSchemaWithOptions");
    }
}
