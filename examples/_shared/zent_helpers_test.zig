const std = @import("std");
const zent = @import("zent");
const helpers = @import("zent_helpers");

const field = zent.core.field;
const Schema = zent.core.schema.Schema;
const TestEntity = Schema("TestEntity", .{
    .fields = &.{field.String("name")},
});
const graph = zent.codegen.graph.buildGraph(&.{TestEntity});
const infos = graph.types;

fn countRows(driver: zent.sql_driver.Driver) !i64 {
    var rows = try driver.query("SELECT COUNT(*) FROM test_entity", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRows;
    return row.getInt(0) orelse return error.InvalidCount;
}

test "TestEnv initializes and deinitializes an isolated store" {
    const Env = helpers.TestEnv(infos);
    var env = try Env.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(@as(i64, 0), try countRows(env.store.driver.asDriver()));
}

test "StoreEnv inMemory migrates a tiny schema" {
    const Env = helpers.StoreEnv(zent.sql_sqlite.SQLiteDriver, infos);
    var env = try Env.inMemory(std.testing.allocator);
    defer env.deinit();

    var rows = try env.driver.asDriver().query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'test_entity'",
        &.{},
    );
    defer rows.deinit();
    try std.testing.expect(rows.next() != null);
}

test "TestEnv reset clears data before re-migrating" {
    const Env = helpers.TestEnv(infos);
    var env = try Env.init(std.testing.allocator);
    defer env.deinit();

    _ = try env.store.driver.asDriver().exec(
        "INSERT INTO test_entity (name) VALUES (?)",
        &.{.{ .string = "before reset" }},
    );
    try std.testing.expectEqual(@as(i64, 1), try countRows(env.store.driver.asDriver()));

    try env.reset();
    try std.testing.expectEqual(@as(i64, 0), try countRows(env.store.driver.asDriver()));
}

test "StoreEnv deinit is idempotent" {
    const Env = helpers.StoreEnv(zent.sql_sqlite.SQLiteDriver, infos);
    var env = try Env.inMemory(std.testing.allocator);
    env.deinit();
    env.deinit();
}
