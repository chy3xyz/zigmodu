const std = @import("std");

/// Module-specific logger with context
pub const ModuleLogger = struct {
    const Self = @This();

    module_name: []const u8,

    pub fn init(module_name: []const u8) Self {
        return .{
            .module_name = module_name,
        };
    }

    pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.debug("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.info("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.warn("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.err("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    /// The framework log scope: `scope("module")` returns a namespace whose
    /// lines are prefixed with `[module]`, and `withField` binds borrowed
    /// fields onto every line it emits — the trace-id hook (see `ScopeImpl`).
    pub const LogScope = ScopeImpl;
};

/// The log scope, reachable as `ModuleLogger.LogScope` — the path
/// `zigmodu.observability.LogScope` re-exports for consumers.
const ScopeImpl = struct {
    pub const default_level = std.log.Level.info;

    /// One field bound to a scope. Both halves are **borrowed**: nothing is
    /// copied, and no ownership moves to the scope.
    pub const Field = struct {
        key: []const u8,
        value: []const u8,
    };

    /// How many fields one `withField` chain can bind. Bindings past this are
    /// dropped (see `Bound.withField`) rather than failing the caller: a
    /// logger must never be the reason a request fails.
    pub const max_fields = 8;

    /// Stack buffer size `Bound.fieldSuffix` renders its `" key=value …"` into.
    /// A suffix that does not fit is cut at the last whole field.
    pub const suffix_capacity = 256;

    /// Emits one line through the framework's `zigmodu` log scope. `level` is
    /// comptime so `std.log`'s compile-time filtering still applies.
    fn emitAt(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
        const scoped_log = std.log.scoped(.zigmodu);
        switch (level) {
            .debug => scoped_log.debug(fmt, args),
            .info => scoped_log.info(fmt, args),
            .warn => scoped_log.warn(fmt, args),
            .err => scoped_log.err(fmt, args),
        }
    }

    pub fn scope(comptime module: []const u8) type {
        return struct {
            const module_prefix = "[" ++ module ++ "] ";

            pub const default_level = std.log.Level.info;

            /// Textual prefix of every line this scope emits — the anchor a
            /// consumer greps or splits on.
            pub const prefix = module_prefix;

            /// A `scope(...)` with fields bound to it, so the fields land on
            /// *every* line the scope emits — that is what makes a log line
            /// findable from a trace and vice versa:
            ///
            /// ```zig
            /// const log = zigmodu.observability.LogScope.scope("payments")
            ///     .withField("trace_id", ctx.traceId() orelse "");
            /// log.info("charged {d}", .{amount});
            /// ```
            ///
            /// `withField` borrows both halves; the caller guarantees `value`
            /// (and `key`) stay valid for as long as the bound scope is used.
            pub const Bound = struct {
                /// All-empty default, so an unbound scope carries no
                /// `undefined` bytes even though it never reads them.
                const empty_fields: [max_fields]Field = blk: {
                    var out: [max_fields]Field = undefined;
                    for (&out) |*field| field.* = .{ .key = "", .value = "" };
                    break :blk out;
                };

                fields: [max_fields]Field = empty_fields,
                field_count: usize = 0,

                /// Binds `key` to `value` — or **overwrites** the value when
                /// `key` is already bound, keeping the field's original
                /// position. Silent per-key override, not an error, so a
                /// handler can rebind a scope it was handed.
                pub fn withField(self: Bound, key: []const u8, value: []const u8) Bound {
                    var out = self;
                    for (out.fields[0..out.field_count]) |*field| {
                        if (std.mem.eql(u8, field.key, key)) {
                            field.value = value;
                            return out;
                        }
                    }
                    if (out.field_count < max_fields) {
                        out.fields[out.field_count] = .{ .key = key, .value = value };
                        out.field_count += 1;
                    }
                    return out;
                }

                /// The `" key=value"` suffix this scope appends to the message.
                /// Empty when nothing is bound — which is why an unbound scope
                /// emits exactly the pre-binding line. Values are written
                /// verbatim, so keep spaces out of a value you intend to parse
                /// by splitting on spaces.
                pub fn fieldSuffix(self: Bound, buf: []u8) []const u8 {
                    var used: usize = 0;
                    for (self.fields[0..self.field_count]) |field| {
                        const written = std.fmt.bufPrint(buf[used..], " {s}={s}", .{
                            field.key, field.value,
                        }) catch return buf[0..used];
                        used += written.len;
                    }
                    return buf[0..used];
                }

                pub fn debug(self: Bound, comptime fmt: []const u8, args: anytype) void {
                    self.emit(.debug, fmt, args);
                }

                pub fn info(self: Bound, comptime fmt: []const u8, args: anytype) void {
                    self.emit(.info, fmt, args);
                }

                pub fn warn(self: Bound, comptime fmt: []const u8, args: anytype) void {
                    self.emit(.warn, fmt, args);
                }

                pub fn err(self: Bound, comptime fmt: []const u8, args: anytype) void {
                    self.emit(.err, fmt, args);
                }

                fn emit(self: Bound, comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
                    if (self.field_count == 0) {
                        // No binding: emit the format string this scope emitted
                        // before fields existed, with the caller's args untouched.
                        emitAt(level, module_prefix ++ fmt, args);
                        return;
                    }
                    var buf: [suffix_capacity]u8 = undefined;
                    const suffix = self.fieldSuffix(&buf);
                    emitAt(level, module_prefix ++ fmt ++ "{s}", args ++ .{suffix});
                }
            };

            /// Bind a field to this scope (see `Bound.withField`).
            pub fn withField(key: []const u8, value: []const u8) Bound {
                const empty: Bound = .{};
                return empty.withField(key, value);
            }

            pub fn debug(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).debug(module_prefix ++ fmt, args);
            }

            pub fn info(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).info(module_prefix ++ fmt, args);
            }

            pub fn warn(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).warn(module_prefix ++ fmt, args);
            }

            pub fn err(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).err(module_prefix ++ fmt, args);
            }
        };
    }
};

test "ModuleLogger and LogScope construct and log" {
    const logger = ModuleLogger.init("order");
    try std.testing.expectEqualStrings("order", logger.module_name);
    logger.debug("debug {d}", .{1});
    logger.info("info {s}", .{"x"});
    logger.warn("warn {d}", .{2});

    const Scope = ModuleLogger.LogScope.scope("payments");
    Scope.info("scoped {d}", .{3});
    Scope.debug("scoped debug", .{});
}

test "LogScope.withField renders bound fields into the line" {
    const Scope = ModuleLogger.LogScope.scope("payments");
    var buf: [ModuleLogger.LogScope.suffix_capacity]u8 = undefined;

    // One field, then two, in binding order.
    const trace = Scope.withField("trace_id", "4bf92f3577b34da6a3ce929d0e0e4736");
    try std.testing.expectEqualStrings(
        " trace_id=4bf92f3577b34da6a3ce929d0e0e4736",
        trace.fieldSuffix(&buf),
    );
    const both = trace.withField("user_id", "42");
    try std.testing.expectEqualStrings(
        " trace_id=4bf92f3577b34da6a3ce929d0e0e4736 user_id=42",
        both.fieldSuffix(&buf),
    );

    // Rebinding a key overwrites its value, keeping the field's position.
    const rebound = both.withField("trace_id", "0000");
    try std.testing.expectEqualStrings(" trace_id=0000 user_id=42", rebound.fieldSuffix(&buf));

    // Past `max_fields` extra bindings are dropped, not fatal.
    var overflow: Scope.Bound = .{};
    for ([_][]const u8{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9" }) |key| {
        overflow = overflow.withField(key, "v");
    }
    try std.testing.expectEqual(ModuleLogger.LogScope.max_fields, overflow.field_count);

    // And a bound scope really emits its line.
    both.info("charged {d}", .{7});
}

test "LogScope without fields emits the historical line" {
    // The compat promise: an unbound scope hands `std.log` the same format
    // string it always did (`prefix ++ fmt`) and the caller's args untouched —
    // no `{}`, no appended key. `Bound` with no binding is that scope.
    const Scope = ModuleLogger.LogScope.scope("orders");
    var buf: [ModuleLogger.LogScope.suffix_capacity]u8 = undefined;
    const unbound: Scope.Bound = .{};

    try std.testing.expectEqualStrings("[orders] ", Scope.prefix);
    try std.testing.expectEqual(0, unbound.field_count);
    const empty = unbound.fieldSuffix(&buf);
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "trace_id") == null);

    unbound.info("unscoped line", .{});
    Scope.info("bare scope line", .{});
}
