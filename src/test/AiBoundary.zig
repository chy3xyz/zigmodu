//! AI boundary — the machine-checked half of `docs/AI_BOUNDARY.md`.
//!
//! `src/ai/` is the largest optional surface in the tree (~12k lines) and the one
//! most likely to become its own package. Extraction is blocked by exactly one
//! thing: AI code that imports the **driver layer** directly
//! (`sqlx/sqlx.zig`, `persistence/backends/**`) instead of going through the
//! `data` domain seam. Measured when this test was written: **30** direct
//! `sqlx/sqlx.zig` imports and **26** direct `persistence/backends` imports across
//! 21 files.
//!
//! Fixing all of them is a refactor; *stopping the rot* is a test. So:
//!
//! * the reverse direction (core → ai) is enforced **absolutely**: `src/` outside
//!   `ai/` may not import `ai/` at all, except the single root export;
//! * the forward coupling is **ratcheted**: the counts below are a frozen ceiling
//!   and may only go down. Adding one more direct driver import fails the build,
//!   which is what makes "we'll clean it up later" true instead of aspirational.
//!
//! The allowlist is deliberately generous where the seam is legitimate (SSE for
//! streaming, `core/Time`, the `data`/`http` domain barrels, messaging for the
//! broker connectors AI jobs already use) and empty where it is not (the driver
//! layer).

const std = @import("std");

/// Frozen ceilings. Lower them as the refactor lands; never raise them.
const baseline_direct_sqlx = 30;
const baseline_direct_backends = 26;

/// Import targets `src/ai/**` may use without any further justification: they are
/// domain seams, not driver internals.
const allowed_prefixes = [_][]const u8{
    "core/",
    "http/", // Sse.zig — streaming is AI's own transport concern
    "http.zig", // the http domain barrel
    "data.zig", // the data domain barrel (the seam AI *should* use)
    "messaging/",
    "scheduler/",
    "resilience/",
    "tracing/",
    "redis/",
    "api/", // Server.zig Context type — one-file dependency, see below
    "security/",
    "test/", // test helpers (NetworkProbe etc.), gated by -Dnet-tests in the runner
};

/// Targets that must not appear at all (checked separately from the allowlist so
/// the failure message can name the violated rule).
const forbidden_prefixes = [_][]const u8{
    "sqlx/sqlx.zig",
    "persistence/backends/",
};

fn classify(target: []const u8) enum { allowed, forbidden, unknown } {
    for (forbidden_prefixes) |p| {
        if (std.mem.startsWith(u8, target, p)) return .forbidden;
    }
    for (allowed_prefixes) |p| {
        if (std.mem.startsWith(u8, target, p)) return .allowed;
    }
    return .unknown;
}

fn stripUpward(target: []const u8) []const u8 {
    var t = target;
    while (std.mem.startsWith(u8, t, "../")) t = t[3..];
    return t;
}

test "AI boundary: imports stay inside the allowlist (root export is the only way in)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ai_dir = std.Io.Dir.cwd().openDir(std.testing.io, "src/ai", .{ .iterate = true }) catch |err| {
        // A tree without src/ai is not a boundary violation.
        std.log.debug("[ai-boundary] src/ai unreadable ({s}), skipped", .{@errorName(err)});
        return;
    };
    defer ai_dir.close(std.testing.io);

    var direct_sqlx: usize = 0;
    var direct_backends: usize = 0;
    var unknown: usize = 0;
    var iter = ai_dir.iterate();
    while (try iter.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const path = try std.fs.path.join(allocator, &.{ "src/ai", entry.name });
        const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(1 << 20)) catch continue;

        var rest = content;
        while (std.mem.indexOf(u8, rest, "@import(")) |at| {
            rest = rest[at + "@import(".len ..];
            if (rest.len == 0 or rest[0] != '"') continue;
            const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse break;
            const raw = rest[1 .. 1 + end];
            rest = rest[1 + end ..];

            if (raw.len == 0 or !std.mem.startsWith(u8, raw, ".")) continue; // package import ("std", "zigmodu")
            const target = stripUpward(raw);
            switch (classify(target)) {
                .forbidden => {
                    if (std.mem.startsWith(u8, target, "sqlx/sqlx.zig")) {
                        direct_sqlx += 1;
                    } else {
                        direct_backends += 1;
                    }
                },
                .allowed => {},
                .unknown => {
                    unknown += 1;
                    std.debug.print("[ai-boundary] {s}: '{s}' is not in the allowlist — add it to docs/AI_BOUNDARY.md first\n", .{ path, target });
                },
            }
        }
    }

    if (unknown > 0) {
        std.debug.print("[ai-boundary] {d} import(s) outside the documented boundary\n", .{unknown});
        return error.AiBoundaryViolation;
    }

    // Ratchet: the counts may only shrink.
    if (direct_sqlx > baseline_direct_sqlx) {
        std.debug.print(
            "[ai-boundary] direct `sqlx/sqlx.zig` imports grew: {d} > frozen {d}.\n" ++
                "  src/ai must reach the database through the `data` domain barrel, not the driver.\n" ++
                "  (Lower the baseline in this test as the refactor lands.)\n",
            .{ direct_sqlx, baseline_direct_sqlx },
        );
        return error.AiBoundaryViolation;
    }
    if (direct_backends > baseline_direct_backends) {
        std.debug.print(
            "[ai-boundary] direct `persistence/backends/**` imports grew: {d} > frozen {d}.\n" ++
                "  Same rule: use `data.zig`; a backend is a driver detail.\n",
            .{ direct_backends, baseline_direct_backends },
        );
        return error.AiBoundaryViolation;
    }

    // A shrinking count is progress, not a failure — but say so, so the baseline
    // gets lowered instead of quietly drifting.
    if (direct_sqlx < baseline_direct_sqlx or direct_backends < baseline_direct_backends) {
        std.debug.print(
            "[ai-boundary] coupling shrank (sqlx {d}/{d}, backends {d}/{d}) — lower the frozen baseline to lock it in\n",
            .{ direct_sqlx, baseline_direct_sqlx, direct_backends, baseline_direct_backends },
        );
    }
}

test "AI boundary: the core does not depend on src/ai (one-way seam)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var violations: usize = 0;
    const dirs = [_][]const u8{ "src/core", "src/api", "src/data", "src/sqlx", "src/http", "src/security", "src/messaging", "src/runtime" };
    for (dirs) |dir| {
        var d = std.Io.Dir.cwd().openDir(std.testing.io, dir, .{ .iterate = true }) catch continue;
        defer d.close(std.testing.io);
        var it = d.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const path = try std.fs.path.join(allocator, &.{ dir, entry.name });
            const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(1 << 20)) catch continue;
            if (std.mem.indexOf(u8, content, "@import(\"../ai/") != null or
                std.mem.indexOf(u8, content, "@import(\"ai/") != null)
            {
                std.debug.print("[ai-boundary] {s} imports src/ai — the seam runs the other way (root.zig exports it)\n", .{path});
                violations += 1;
            }
        }
    }
    if (violations > 0) return error.AiBoundaryViolation;
}
