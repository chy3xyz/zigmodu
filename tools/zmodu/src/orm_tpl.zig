//! Embedded text templates under `tools/zmodu/src/templates/{orm, module}/`.
const std = @import("std");

pub const sqlx_model_header = @embedFile("templates/orm/sqlx/model_header.zig.tpl");
pub const sqlx_persistence_header = @embedFile("templates/orm/sqlx/persistence_header.zig.tpl");
pub const sqlx_persistence_footer = @embedFile("templates/orm/sqlx/persistence_footer.zig.tpl");
pub const sqlx_service_header = @embedFile("templates/orm/sqlx/service_header.zig.tpl");
pub const sqlx_service_footer = @embedFile("templates/orm/sqlx/service_footer.zig.tpl");
pub const sqlx_api_header = @embedFile("templates/orm/sqlx/api_header.zig.tpl");
pub const sqlx_api_footer = @embedFile("templates/orm/sqlx/api_footer.zig.tpl");
pub const sqlx_module_zig = @embedFile("templates/orm/sqlx/module.zig.tpl");
pub const sqlx_root_zig = @embedFile("templates/orm/sqlx/root.zig.tpl");
pub const sqlx_test_zig = @embedFile("templates/orm/sqlx/test.zig.tpl");

/// Architecture test template (per-module architecture verification).
pub const sqlx_arch_test_zig = @embedFile("templates/orm/sqlx/arch_test.zig.tpl");

/// Zent backend (`zmodu orm --backend zent`)
pub const zent_schema_header = @embedFile("templates/orm/zent/schema_header.zig.tpl");
pub const zent_schema_imports = @embedFile("templates/orm/zent/schema_imports.zig.tpl");
pub const zent_client_header = @embedFile("templates/orm/zent/client_header.zig.tpl");
pub const zent_client_footer = @embedFile("templates/orm/zent/client_footer.zig.tpl");
pub const zent_root_zig = @embedFile("templates/orm/zent/root.zig.tpl");
pub const zent_module_zig = @embedFile("templates/orm/zent/module.zig.tpl");

/// `zmodu module <name>` — minimal `root.zig` next to `module.zig`.
pub const module_minimal_root_zig = @embedFile("templates/module/root.zig.tpl");

/// `zmodu event <name>` — event handler template.
pub const event_tpl = @embedFile("templates/event.zig.tpl");

/// `zmodu api <name>` — standalone API template.
pub const api_standalone_tpl = @embedFile("templates/api_standalone.zig.tpl");

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
