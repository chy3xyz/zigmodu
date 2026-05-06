//! ZigModu module `product` (zmodu: `zmodu module` or `zmodu orm` sqlx).
//! Template: tools/zmodu/src/templates/orm/sqlx/module.zig.tpl
//!
//! ╔═══════════════════════════════════════════════════════════╗
//! ║  AI Metadata: module=product | layer=declaration  ║
//! ║  role=module contract | deps=&.{}                     ║
//! ╚═══════════════════════════════════════════════════════════╝

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "product",
    .description = "product module",
    .dependencies = &.{},
    .is_internal = false,
};

// ── Configuration ──────────────────────────────────────────────
/// Module-level configuration — populate from env or config file.
pub const Config = struct {
    // Add module-specific settings here
};

var config: Config = .{};

// ── Lifecycle ──────────────────────────────────────────────────
pub fn init() !void {
    std.log.info("{s} module initialized", .{"product"});
}

pub fn deinit() void {
    std.log.info("{s} module cleaned up", .{"product"});
}
