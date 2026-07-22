//! Embedded text templates under `src/templates/{orm, module}/`.
const std = @import("std");

pub const sqlx_model_header = @embedFile("templates/orm/sqlx/model_header.zig.tpl");
pub const sqlx_persistence_header = @embedFile("templates/orm/sqlx/persistence_header.zig.tpl");
pub const sqlx_persistence_footer = @embedFile("templates/orm/sqlx/persistence_footer.zig.tpl");
pub const sqlx_service_header = @embedFile("templates/orm/sqlx/service_header.zig.tpl");
pub const sqlx_service_header_noev = @embedFile("templates/orm/sqlx/service_header_noev.zig.tpl");
pub const sqlx_service_footer = @embedFile("templates/orm/sqlx/service_footer.zig.tpl");
pub const sqlx_api_header = @embedFile("templates/orm/sqlx/api_header.zig.tpl");
pub const sqlx_api_footer = @embedFile("templates/orm/sqlx/api_footer.zig.tpl");
pub const sqlx_module_zig = @embedFile("templates/orm/sqlx/module.zig.tpl");
pub const sqlx_root_zig = @embedFile("templates/orm/sqlx/root.zig.tpl");

/// `zmodu module <name>` — minimal `root.zig` next to `module.zig`.
pub const module_minimal_root_zig = @embedFile("templates/module/root.zig.tpl");

/// `zmodu api <name>` — standalone API template.
pub const api_standalone_tpl = @embedFile("templates/api_standalone.zig.tpl");

/// `zmodu event <name>` — event handler template.
pub const event_tpl = @embedFile("templates/event.zig.tpl");

/// Zent backend (`zmodu orm --backend zent`)
pub const zent_schema_header = @embedFile("templates/orm/zent/schema_header.zig.tpl");
pub const zent_schema_imports = @embedFile("templates/orm/zent/schema_imports.zig.tpl");
pub const zent_client_header = @embedFile("templates/orm/zent/client_header.zig.tpl");
pub const zent_client_footer = @embedFile("templates/orm/zent/client_footer.zig.tpl");
pub const zent_root_zig = @embedFile("templates/orm/zent/root.zig.tpl");
pub const zent_module_zig = @embedFile("templates/orm/zent/module.zig.tpl");

fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Replace `<<MODULE_NAME>>` then `<<PASCAL_MODULE>>` (all ORM / module templates).
pub fn expandOrm(allocator: std.mem.Allocator, template: []const u8, module_name: []const u8, pascal_module: []const u8) ![]const u8 {
    const s1 = try replaceAll(allocator, template, "<<MODULE_NAME>>", module_name);
    defer allocator.free(s1);
    return replaceAll(allocator, s1, "<<PASCAL_MODULE>>", pascal_module);
}

/// Replace `{{KEY}}` placeholders with values. Keys and values are paired in order.
pub fn expandTemplate(allocator: std.mem.Allocator, template: []const u8, keys: []const []const u8, values: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, template);
    for (keys, values) |key, value| {
        const cur = try buf.toOwnedSlice(allocator);
        const next = try replaceAll(allocator, cur, key, value);
        allocator.free(cur);
        buf = .empty;
        try buf.appendSlice(allocator, next);
        allocator.free(next);
    }
    return buf.toOwnedSlice(allocator);
}

// ── Tests ──

test "replaceAll basic substitution" {
    const allocator = std.testing.allocator;
    const result = try replaceAll(allocator, "hello WORLD world", "world", "zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello WORLD zig", result);
}

test "replaceAll no match returns original" {
    const allocator = std.testing.allocator;
    const result = try replaceAll(allocator, "hello", "xyz", "abc");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replaceAll multiple occurrences" {
    const allocator = std.testing.allocator;
    const result = try replaceAll(allocator, "aabbcc", "b", "X");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("aaXXcc", result);
}

test "replaceAll empty replacement" {
    const allocator = std.testing.allocator;
    const result = try replaceAll(allocator, "remove-this-word", "-this-word", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("remove", result);
}

test "expandOrm substitutes both placeholders" {
    const allocator = std.testing.allocator;
    const tpl = "const T = struct { pub const table = \"<<MODULE_NAME>>\"; pub const Name = <<PASCAL_MODULE>>; };";
    const result = try expandOrm(allocator, tpl, "user_profile", "UserProfile");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "const T = struct { pub const table = \"user_profile\"; pub const Name = UserProfile; };",
        result,
    );
}

test "expandOrm with no placeholders" {
    const allocator = std.testing.allocator;
    const result = try expandOrm(allocator, "no placeholders here", "mod", "Mod");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no placeholders here", result);
}

test "expandTemplate with multiple keys" {
    const allocator = std.testing.allocator;
    const tpl = "fn {{NAME}}(ctx: *{{TYPE}}) !void { return {{NAME}}Impl(ctx); }";
    const keys = [_][]const u8{ "{{NAME}}", "{{TYPE}}" };
    const vals = [_][]const u8{ "handleRequest", "Context" };
    const result = try expandTemplate(allocator, tpl, &keys, &vals);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "fn handleRequest(ctx: *Context) !void { return handleRequestImpl(ctx); }",
        result,
    );
}

test "expandTemplate with no keys" {
    const allocator = std.testing.allocator;
    const result = try expandTemplate(allocator, "unchanged", &.{}, &.{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("unchanged", result);
}

test "embedded templates are non-empty" {
    // Verify all @embedFile templates loaded correctly
    try std.testing.expect(sqlx_model_header.len > 0);
    try std.testing.expect(sqlx_persistence_header.len > 0);
    try std.testing.expect(sqlx_service_header.len > 0);
    try std.testing.expect(sqlx_api_header.len > 0);
    try std.testing.expect(sqlx_module_zig.len > 0);
    try std.testing.expect(sqlx_root_zig.len > 0);
    try std.testing.expect(module_minimal_root_zig.len > 0);
    try std.testing.expect(api_standalone_tpl.len > 0);
    try std.testing.expect(event_tpl.len > 0);
    try std.testing.expect(zent_schema_header.len > 0);
    try std.testing.expect(zent_client_header.len > 0);
    try std.testing.expect(zent_module_zig.len > 0);
}

test "sqlx_model_header contains MODULE_NAME placeholder" {
    try std.testing.expect(std.mem.indexOf(u8, sqlx_model_header, "<<MODULE_NAME>>") != null);
}
