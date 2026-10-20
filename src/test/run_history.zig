//! One JSON line per run for the long-horizon harnesses (`soak`,
//! `soak-cluster`) — the same schema-v1 shape `runtime_stress.zig` writes.
//!
//! Why this exists: a night's soak log is an artifact; a line per commit in a
//! JSONL file is a *series*. `scripts/soak_trend.py` reads the file back, so a
//! slow RSS/thread regression shows up as a slope instead of a paragraph
//! somebody has to remember to compare.
//!
//! Contract, inherited from the stress history:
//!   * the path comes from the environment (`SOAK_HISTORY`,
//!     `SOAK_CLUSTER_HISTORY`); absent = the harness stays silent, so a local
//!     run writes nothing unless asked;
//!   * stack buffers only — the harnesses run under a leak-checked allocator,
//!     and history must not perturb the reading it is recording;
//!   * every failure is a warning: one lost data point must not fail a run
//!     that otherwise passed;
//!   * the commit is validated (hex, 7–64 chars) *before* it enters the line,
//!     which is the escaping strategy — no JSON escaping is needed for a
//!     string that cannot contain a quote.
//!
//! The append is positional-at-EOF rather than an `O_APPEND` stream: that is
//! what `runtime_stress.zig` measured as the portable call, and one writer per
//! path is the protocol on both sides (CI: one nightly runner; locally: the
//! developer's own file).

const std = @import("std");
const builtin = @import("builtin");

/// `NAME` from the environment, or null when unset/empty.
pub fn envPath(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const s = std.mem.span(raw);
    return if (s.len == 0) null else s;
}

pub fn validCommit(s: []const u8) bool {
    if (s.len < 7 or s.len > 64) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// `GIT_SHA` when it is a commit id, "unknown" otherwise. The nightly workflow
/// exports it; a local run without it still produces a readable line.
pub fn commit() []const u8 {
    const raw = std.c.getenv("GIT_SHA") orelse return "unknown";
    const s = std.mem.span(raw);
    return if (validCommit(s)) s else "unknown";
}

/// Opens the series and writes the header every line shares:
/// `{"v":1,"kind":"…","ts":…,"commit":"…","os":"…","arch":"…"`.
/// The caller appends its own fields and the closing brace.
pub fn writeHeader(w: *std.Io.Writer, io: std.Io, kind: []const u8) !void {
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    try w.print(
        "{{\"v\":1,\"kind\":\"{s}\",\"ts\":{d},\"commit\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\"",
        .{ kind, ts, commit(), @tagName(builtin.target.os.tag), @tagName(builtin.target.cpu.arch) },
    );
}

/// Append one already-terminated line. Returns the error so the caller can
/// decide (both harnesses turn it into a warning).
pub fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    const end = (try file.stat(io)).size;
    try file.writePositionalAll(io, line, end);
}

test "history: commit validation is the escaping strategy" {
    try std.testing.expect(validCommit("0006c85"));
    try std.testing.expect(validCommit("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!validCommit("0006c8"));
    try std.testing.expect(!validCommit("0006c85\""));
    try std.testing.expect(!validCommit("not-a-sha"));
    try std.testing.expect(!validCommit("0006c85/../../etc/passwd"));
}

test "history: appendLine appends instead of truncating" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/history.jsonl", .{tmp.sub_path[0..]});

    try appendLine(std.testing.io, path, "{\"v\":1,\"kind\":\"soak\"}\n");
    try appendLine(std.testing.io, path, "{\"v\":1,\"kind\":\"soak-cluster\"}\n");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    try std.testing.expectEqual(@as(usize, 0), lines.next().?.len);

    for ([_][]const u8{ l1, l2 }) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("v").?.integer);
    }
    try std.testing.expect(std.mem.indexOf(u8, l1, "\"soak\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2, "\"soak-cluster\"") != null);
}
