//! Per-Application module state.
//!
//! Modules used to keep their state in file-level `pub var`s, which survives
//! every `Application` instance: a test suite building four apps, or an app
//! that runs several phases (replay → live), had to hand-reset every module.
//! This registry gives a module a slot **keyed by (module name, type)** whose
//! lifetime is the Application's:
//!
//! ```zig
//! pub fn initWith(ctx: *ModuleContext) !void {
//!     const st = try ctx.state(BookState); // created once per app
//!     _ = st;
//! }
//! ```
//!
//! `T{}` must be constructible (defaults for every field); use `stateWith` for
//! anything else. Teardown runs in reverse creation order when the Application
//! is deinitialized: `pub fn deinit(self: *T) void` is called when declared,
//! then the slot is freed. The context is borrowed — do not retain it.

const std = @import("std");

pub const ModuleState = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    /// Keys in creation order; teardown walks this in reverse.
    order: std.ArrayList([]const u8),

    pub const Entry = struct {
        ptr: *anyopaque,
        deinit_fn: ?*const fn (*anyopaque) void = null,
        destroy_fn: *const fn (std.mem.Allocator, *anyopaque) void,
    };

    pub fn init(allocator: std.mem.Allocator) ModuleState {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
            .order = .empty,
        };
    }

    pub fn deinit(self: *ModuleState) void {
        var i = self.order.items.len;
        while (i > 0) {
            i -= 1;
            const key = self.order.items[i];
            if (self.entries.get(key)) |entry| {
                if (entry.deinit_fn) |f| f(entry.ptr);
                entry.destroy_fn(self.allocator, entry.ptr);
            }
            self.allocator.free(key);
        }
        self.entries.deinit();
        self.order.deinit(self.allocator);
        self.* = undefined;
    }

    /// Create (or return) the slot for `T` belonging to `module`. The initial
    /// value is only used on creation.
    pub fn getOrCreate(self: *ModuleState, comptime T: type, module: []const u8, initial: T) !*T {
        var buf: [512]u8 = undefined;
        const key_stack = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ module, @typeName(T) }) catch
            return error.StateKeyTooLong;
        if (self.entries.get(key_stack)) |entry| {
            return @ptrCast(@alignCast(entry.ptr));
        }

        const key = try self.allocator.dupe(u8, key_stack);
        errdefer self.allocator.free(key);
        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = initial;

        try self.entries.put(key, .{
            .ptr = ptr,
            .deinit_fn = if (@hasDecl(T, "deinit")) struct {
                fn f(p: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    typed.deinit();
                }
            }.f else null,
            .destroy_fn = struct {
                fn f(a: std.mem.Allocator, p: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    a.destroy(typed);
                }
            }.f,
        });
        errdefer _ = self.entries.remove(key);
        try self.order.append(self.allocator, key);
        return ptr;
    }

    /// The slot for `T`, or null when it was never created.
    pub fn get(self: *ModuleState, comptime T: type, module: []const u8) ?*T {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ module, @typeName(T) }) catch return null;
        const entry = self.entries.get(key) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub fn count(self: *const ModuleState) usize {
        return self.entries.count();
    }
};

test "ModuleState keys by (module, type) and tears down in reverse" {
    const allocator = std.testing.allocator;
    const Counter = struct {
        value: usize = 0,
        var deinits: usize = 0;
        pub fn deinit(self: *@This()) void {
            _ = self;
            deinits += 1;
        }
    };

    var states = ModuleState.init(allocator);
    const a1 = try states.getOrCreate(Counter, "alpha", .{});
    const a2 = try states.getOrCreate(Counter, "alpha", .{ .value = 99 });
    const b1 = try states.getOrCreate(Counter, "beta", .{ .value = 7 });
    try std.testing.expect(a1 == a2); // same module + type → same slot
    try std.testing.expect(a1 != b1); // different module → different slot
    try std.testing.expectEqual(@as(usize, 0), a1.value); // initial wins only on creation
    try std.testing.expectEqual(@as(usize, 7), b1.value);
    try std.testing.expectEqual(@as(usize, 2), states.count());

    states.deinit();
    try std.testing.expectEqual(@as(usize, 2), Counter.deinits);
}

test "ModuleState.get returns null for an unseen slot and a second deinit is safe" {
    const allocator = std.testing.allocator;
    const S = struct { n: u8 = 1 };

    var states = ModuleState.init(allocator);
    try std.testing.expect(states.get(S, "m") == null);
    _ = try states.getOrCreate(S, "m", .{});
    try std.testing.expect(states.get(S, "m") != null);
    states.deinit();
}
