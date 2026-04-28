const std = @import("std");

/// Module metadata definition
/// Used to annotate business modules in Zig
pub const Module = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    is_internal: bool = false,
};

/// Application-level configuration
/// Defines the modular application structure
pub const Modulith = struct {
    name: []const u8,
    base_path: []const u8,
    validate: bool = true,
    generate_docs: bool = true,
};

/// Module trait - compile-time interface for modules
/// Any struct with these fields can be used as a module
pub fn ModuleTrait(comptime T: type) type {
    return struct {
        pub const has_info = @hasDecl(T, "info");
        pub const has_init = @hasDecl(T, "init");
        pub const has_deinit = @hasDecl(T, "deinit");
    };
}
