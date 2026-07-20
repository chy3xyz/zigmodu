//! Open zent driver: default Postgres, SQLite for local/CI smoke.
//! Client is bound after Db is in its final stack location (Driver ptr must not dangle).
const std = @import("std");
const zent = @import("zent");
const schema = @import("schema.zig");

pub const DriverKind = enum { postgres, sqlite };

pub const Db = struct {
    kind: DriverKind,
    allocator: std.mem.Allocator,
    sqlite: ?zent.sql_sqlite.SQLiteDriver = null,
    postgres: ?zent.sql_postgres.PostgresDriver = null,
    client: schema.Client = undefined,
    client_ready: bool = false,

    pub fn open(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Db {
        const kind = parseKind(env.get("ZENT_DRIVER") orelse "postgres");
        var self: Db = .{
            .kind = kind,
            .allocator = allocator,
        };

        switch (kind) {
            .sqlite => {
                const path = env.get("SQLITE_PATH") orelse ":memory:";
                self.sqlite = try zent.sql_sqlite.SQLiteDriver.open(allocator, path);
                std.log.info("[db] sqlite at {s}", .{path});
            },
            .postgres => {
                self.postgres = try openPostgres(allocator, env);
                std.log.info("[db] postgres connected", .{});
            },
        }
        return self;
    }

    /// Call once after `var db = try open(...)` so Driver ptr targets `db` itself.
    pub fn migrateAndBind(self: *Db) !void {
        const drv = self.driver();
        try zent.sql_schema.migrateSchema(self.allocator, drv, schema.infos);
        self.client = zent.codegen.client.makeClient(schema.infos, self.allocator, drv);
        self.client_ready = true;
        std.log.info("[db] migrated zent schema ({d} types)", .{schema.infos.len});
    }

    pub fn deinit(self: *Db) void {
        if (self.sqlite) |*s| s.close();
        if (self.postgres) |*p| p.close();
    }

    pub fn driver(self: *Db) zent.sql_driver.Driver {
        return switch (self.kind) {
            .sqlite => self.sqlite.?.asDriver(),
            .postgres => self.postgres.?.asDriver(),
        };
    }
};

fn parseKind(s: []const u8) DriverKind {
    if (std.mem.eql(u8, s, "sqlite")) return .sqlite;
    return .postgres;
}

fn openPostgres(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !zent.sql_postgres.PostgresDriver {
    if (env.get("PGCONNINFO") orelse env.get("DATABASE_URL")) |conninfo| {
        return zent.sql_postgres.PostgresDriver.connect(allocator, conninfo);
    }
    const host = env.get("PGHOST") orelse "127.0.0.1";
    const port_s = env.get("PGPORT") orelse "5432";
    const port = std.fmt.parseInt(u16, port_s, 10) catch 5432;
    const dbname = env.get("PGDATABASE") orelse "metaverse";
    const user = env.get("PGUSER") orelse "postgres";
    const password = env.get("PGPASSWORD") orelse "postgres";
    return zent.sql_postgres.PostgresDriver.connectDb(allocator, host, port, dbname, user, password);
}
