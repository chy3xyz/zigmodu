//! Docs ↔ code consistency: every `pub fn` / `pub const` a doc file shows must
//! exist somewhere in `src/`.
//!
//! This is the cheap half of the "docs say A, code does B" problem: it cannot
//! tell whether a *signature* is still accurate, but it does catch the case
//! that actually bites consumers — a documented symbol that was renamed or
//! never existed (`TransportProtocol`, `MqttTransport`, `TaskScheduler`,
//! `PasRaftAdapter` were all documented in `docs/API.md` while absent from the
//! tree). A symbol check is noisy-free, so it can be a hard gate.

const std = @import("std");

/// Documents whose fenced code blocks are treated as API promises.
///
/// Only the API reference: BEST_PRACTICES deliberately shows *application*
/// code (`OrdersApi`, `createOrder`, `AppError` …) that must not exist in the
/// framework, so scanning it would be all false positives.
const DOC_FILES = [_][]const u8{"docs/API.md"};

const Declaration = struct {
    name: []const u8,
    /// `fn` or `const`, used to build the source-side search pattern.
    kind: enum { function, constant },
    /// file:line for the failure message.
    where: []const u8,
};

test "every symbol documented in docs/ exists in src/" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var decls: std.ArrayListUnmanaged(Declaration) = .empty;
    defer {
        for (decls.items) |d| {
            allocator.free(d.name);
            allocator.free(d.where);
        }
        decls.deinit(allocator);
    }

    for (DOC_FILES) |doc_path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, doc_path, allocator, std.Io.Limit.limited(4 << 20)) catch |err| {
            // A missing doc is a different problem; do not turn it into a
            // confusing consistency failure.
            std.log.debug("[docs-consistency] {s} unreadable ({s}), skipped", .{ doc_path, @errorName(err) });
            continue;
        };
        defer allocator.free(content);

        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            line_no += 1;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "pub fn ") and !std.mem.startsWith(u8, trimmed, "pub const ")) continue;

            const is_fn = std.mem.startsWith(u8, trimmed, "pub fn ");
            const rest = trimmed[if (is_fn) "pub fn ".len else "pub const ".len..];
            var end: usize = 0;
            while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
            if (end == 0) continue;

            const name = try allocator.dupe(u8, rest[0..end]);
            errdefer allocator.free(name);
            const where = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ doc_path, line_no });
            try decls.append(allocator, .{
                .name = name,
                .kind = if (is_fn) .function else .constant,
                .where = where,
            });
        }
    }

    try std.testing.expect(decls.items.len > 50); // the check must actually see the docs

    const found = try allocator.alloc(bool, decls.items.len);
    defer allocator.free(found);
    @memset(found, false);

    var src_dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);
    try scanDir(io, src_dir, allocator, decls.items, found);

    var missing: usize = 0;
    for (decls.items, 0..) |d, i| {
        if (found[i]) continue;
        missing += 1;
        std.debug.print("docs consistency: '{s}' is documented at {s} but 'pub {s} {s}' is nowhere in src/\n", .{
            d.name, d.where, if (d.kind == .function) "fn" else "const", d.name,
        });
    }
    if (missing > 0) {
        std.debug.print("docs consistency: {d} documented symbol(s) not found — fix the doc or restore the symbol\n", .{missing});
        return error.DocumentedSymbolMissing;
    }
}

// A documented root alias must be *importable*, not merely present in `src/`:
// `zigmodu.<Name>` is what a consumer writes, and it resolves only through
// `root.zig`. Importing the root file from here sees exactly what
// `@import("zigmodu")` sees — `pub` declarations only — so dropping one of
// these aliases fails this test at compile time, not at the user's call site.
test "documented root aliases are importable" {
    const zigmodu = @import("../root.zig");
    const allocator = std.testing.allocator;

    const Params = zigmodu.Params;
    var params = Params.init(allocator);
    defer params.deinit();
    try params.put("ids", "1");
    try params.put("ids", "2");
    try std.testing.expectEqualStrings("2", params.get("ids").?);
    try std.testing.expectEqual(@as(usize, 2), params.totalValues());

    const ScopedContainer = zigmodu.ScopedContainer;
    var scoped = ScopedContainer.init(allocator, "request", null);
    defer scoped.deinit();
    const Service = struct { n: u32 = 7 };
    const service = try allocator.create(Service);
    service.* = .{};
    try scoped.register(Service, "svc", service);
    try std.testing.expectEqual(@as(u32, 7), scoped.get(Service, "svc").?.n);

    const SlidingWindowRateLimiter = zigmodu.SlidingWindowRateLimiter;
    var window = try SlidingWindowRateLimiter.init(allocator, "api", 60, 1);
    defer window.deinit();
    try std.testing.expect(window.tryAcquire());
    try std.testing.expect(!window.tryAcquire());
    try std.testing.expectEqual(@as(usize, 1), window.currentCount());

    const ConfigManager = zigmodu.ConfigManager;
    var config = ConfigManager.init(allocator);
    defer config.deinit();
    try config.set("app.name", .{ .string = "demo" });
    try std.testing.expectEqualStrings("demo", config.getString("app.name").?);
    try std.testing.expect(config.has("app.name"));

    // The store loads JSON itself; TOML reaches it through the loader alias.
    // Exercised end to end: file → `TomlLoader.loadFile` → typed reads.
    const TomlLoader = zigmodu.TomlLoader;
    const toml_path = "zigmodu_root_alias_test.toml";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, toml_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "[server]\nport = 8080\ndebug = true\n");
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, toml_path) catch {};

    var toml_loader = TomlLoader.init(allocator);
    try toml_loader.loadFile(toml_path, &config);
    try std.testing.expectEqual(@as(i64, 8080), config.getInt("server.port").?);
    try std.testing.expectEqual(true, config.getBool("server.debug").?);
}

fn scanDir(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    decls: []const Declaration,
    found: []bool,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try scanDir(io, sub, allocator, decls, found);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const content = dir.readFileAlloc(io, entry.name, allocator, std.Io.Limit.limited(2 << 20)) catch continue;
                defer allocator.free(content);
                for (decls, 0..) |d, i| {
                    if (found[i]) continue;
                    // Search for a declaration-shaped occurrence, not just the
                    // bare word, so a comment mentioning the name does not pass.
                    // Doc style writes a type's constructor as
                    // `pub fn TypeName(...)`; Zig has no such declaration, so an
                    // upper-case name is checked as a type as well.
                    const is_type = std.ascii.isUpper(d.name[0]);
                    const fn_pattern = try std.fmt.allocPrint(allocator, "fn {s}(", .{d.name});
                    defer allocator.free(fn_pattern);
                    if (std.mem.indexOf(u8, content, fn_pattern) != null) {
                        found[i] = true;
                        continue;
                    }
                    if (d.kind == .constant or is_type) {
                        const const_pattern = try std.fmt.allocPrint(allocator, "const {s}", .{d.name});
                        defer allocator.free(const_pattern);
                        if (std.mem.indexOf(u8, content, const_pattern) != null) found[i] = true;
                    }
                }
            },
            else => {},
        }
    }
}
