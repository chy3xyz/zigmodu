//! `zmodu life issue|release|sync` — the file-adapter CLI for the life
//! governance system (spec: docs/superpowers/specs/2026-10-16-life-issue-release-design.md).
//!
//! Storage: `.life/issues/LI-%04d.md` (frontmatter markdown) + `.life/releases/`.
//! The state machine/validators live in the shared `life_core` module
//! (framework src/life/) — this file is IO + argument parsing only.
//! Exit codes: 0 ok / 1 runtime error / 2 usage.

const std = @import("std");
const life_core = @import("life_core");

const model = life_core.model;
const state = life_core.state;

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    return runAt(io, allocator, args, ".");
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var err_file = std.Io.File.stderr();
    var err_writer = err_file.writer(io, &buf);
    const stderr = &err_writer.interface;
    stderr.print(fmt, args) catch return;
    stderr.writeAll("\n") catch return;
    stderr.flush() catch return;
}

pub fn runAt(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, dir: []const u8) u8 {
    _ = allocator;
    _ = dir;
    if (args.len == 0) {
        printUsage();
        return 2;
    }
    if (std.mem.eql(u8, args[0], "issue") or
        std.mem.eql(u8, args[0], "release") or
        std.mem.eql(u8, args[0], "sync"))
    {
        printErr(io, "life: {s} not implemented yet", .{args[0]});
        return 1;
    }
    printUsage();
    return 2;
}

fn printUsage() void {
    std.log.info(
        \\life — issue & release tracking (.life/)
        \\
        \\  zmodu life issue new|list|show|transition|comment ...
        \\  zmodu life release draft|publish ...
        \\  zmodu life sync                 consistency check
        \\  zmodu life tree|fingerprint|evolve   (evolution tree, unchanged)
    , .{});
}

test "usage on empty args returns 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];
    try std.testing.expectEqual(@as(u8, 2), runAt(io, arena.allocator(), &.{}, dir));
    try std.testing.expectEqual(@as(u8, 1), runAt(io, arena.allocator(), &.{"issue"}, dir));
    try std.testing.expectEqual(@as(u8, 2), runAt(io, arena.allocator(), &.{"bogus"}, dir));
}
