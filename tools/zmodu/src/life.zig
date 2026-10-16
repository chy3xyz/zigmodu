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

// ===================== file store =====================
// Format (spec §5.1): `---` frontmatter (strings double-quoted + escaped,
// enums/times bare) → blank line → body markdown → optional `## Repro`
// (raw key:value lines) → optional `## Comments` (`- <iso> <author>: <text>`).
// loadIssue's returned slices point into an internally-read buffer owned by
// the caller's allocator — use an arena whose lifetime covers the Issue.

pub fn epochToIsoUtc(buf: *[20]u8, epoch_secs: i64) []const u8 {
    const days0 = @divFloor(epoch_secs, 86400);
    var rem = @mod(epoch_secs, 86400);
    const hh: u64 = @intCast(@divFloor(rem, 3600));
    rem = @mod(rem, 3600);
    const mm: u64 = @intCast(@divFloor(rem, 60));
    const ss: u64 = @intCast(@mod(rem, 60));
    // civil_from_days (Howard Hinnant)
    const days = days0 + 719468;
    const era = @divFloor(days, 146097);
    const doe = days - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year: u64 = @intCast(if (m <= 2) y + 1 else y);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, @as(u64, @intCast(m)), @as(u64, @intCast(d)), hh, mm, ss,
    }) catch unreachable;
}

pub fn isoToEpoch(s: []const u8) ?i64 {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hh > 23 or mm > 59 or ss > 60) return null;
    // days_from_civil
    var y = year;
    const m = month;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss;
}

fn quoteValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

fn unquoteValue(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len < 2 or t[0] != '"' or t[t.len - 1] != '"') return t;
    var out = std.ArrayList(u8).empty;
    var i: usize = 1;
    while (i < t.len - 1) : (i += 1) {
        if (t[i] == '\\' and i + 1 < t.len - 1) {
            i += 1;
            switch (t[i]) {
                'n' => try out.append(alloc, '\n'),
                else => try out.append(alloc, t[i]),
            }
        } else try out.append(alloc, t[i]);
    }
    return out.items;
}

pub fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    return out.items;
}

fn issuePath(buf: []u8, dir: []const u8, seq: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/.life/issues/LI-{d:0>4}.md", .{ dir, seq }) catch unreachable;
}

pub fn formatIssue(alloc: std.mem.Allocator, issue: *const model.Issue) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var tbuf: [20]u8 = undefined;
    try out.appendSlice(alloc, "---\n");
    try out.appendSlice(alloc, "id: LI-");
    var nbuf: [16]u8 = undefined;
    try out.appendSlice(alloc, std.fmt.bufPrint(&nbuf, "{d:0>4}", .{issue.seq}) catch unreachable);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "title: ");
    try quoteValue(&out, alloc, issue.title);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "status: ");
    try out.appendSlice(alloc, model.statusToString(issue.status));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "category: ");
    try out.appendSlice(alloc, model.categoryToString(issue.category));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "priority: ");
    try out.appendSlice(alloc, model.priorityToString(issue.priority));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "source: ");
    try out.appendSlice(alloc, model.sourceToString(issue.source));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "reporter: ");
    try quoteValue(&out, alloc, issue.reporter);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "assignee: ");
    try quoteValue(&out, alloc, issue.assignee);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "created_at: ");
    try out.appendSlice(alloc, epochToIsoUtc(&tbuf, issue.created_at));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "updated_at: ");
    try out.appendSlice(alloc, epochToIsoUtc(&tbuf, issue.updated_at));
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "resolution: ");
    try quoteValue(&out, alloc, issue.resolution);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "fix_ref: ");
    try quoteValue(&out, alloc, issue.fix_ref);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "linked_id: ");
    try quoteValue(&out, alloc, issue.linked_id);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "internal_note: ");
    try quoteValue(&out, alloc, issue.internal_note);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "fingerprint: ");
    try quoteValue(&out, alloc, issue.fingerprint);
    try out.appendSlice(alloc, "\n---\n\n");
    try out.appendSlice(alloc, issue.body);
    if (issue.repro_lines.len > 0) {
        try out.appendSlice(alloc, "\n\n## Repro\n\n");
        try out.appendSlice(alloc, issue.repro_lines);
        try out.append(alloc, '\n');
    }
    if (issue.comments.len > 0) {
        try out.appendSlice(alloc, "\n## Comments\n\n");
        for (issue.comments) |c| {
            try out.appendSlice(alloc, "- ");
            try out.appendSlice(alloc, epochToIsoUtc(&tbuf, c.at));
            try out.appendSlice(alloc, " ");
            try out.appendSlice(alloc, c.author);
            try out.appendSlice(alloc, ": ");
            try out.appendSlice(alloc, c.text);
            try out.append(alloc, '\n');
        }
    }
    return out.items;
}

pub fn parseIssue(alloc: std.mem.Allocator, text: []const u8) !model.Issue {
    var issue = model.Issue{ .seq = 0, .title = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadIssueFile;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return error.BadIssueFile;
    var in_frontmatter = true;
    var body = std.ArrayList(u8).empty;
    var repro = std.ArrayList(u8).empty;
    var comments = std.ArrayList(model.Comment).empty;
    var section: enum { body, repro, comments } = .body;
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (in_frontmatter) {
            if (std.mem.eql(u8, line, "---")) {
                in_frontmatter = false;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadIssueFile;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const raw = line[colon + 1 ..];
            if (std.mem.eql(u8, key, "id")) {
                const v = try unquoteValue(alloc, raw);
                if (v.len < 4 or !std.mem.startsWith(u8, v, "LI-")) return error.BadIssueFile;
                issue.seq = std.fmt.parseInt(u32, v[3..], 10) catch return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "title")) {
                issue.title = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "status")) {
                issue.status = model.statusFromString(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "category")) {
                issue.category = model.categoryFromString(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "priority")) {
                issue.priority = model.priorityFromString(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "source")) {
                issue.source = model.sourceFromString(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "reporter")) {
                issue.reporter = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "assignee")) {
                issue.assignee = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "created_at")) {
                issue.created_at = isoToEpoch(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "updated_at")) {
                issue.updated_at = isoToEpoch(std.mem.trim(u8, raw, " \t")) orelse return error.BadIssueFile;
            } else if (std.mem.eql(u8, key, "resolution")) {
                issue.resolution = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "fix_ref")) {
                issue.fix_ref = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "linked_id")) {
                issue.linked_id = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "internal_note")) {
                issue.internal_note = try unquoteValue(alloc, raw);
            } else if (std.mem.eql(u8, key, "fingerprint")) {
                issue.fingerprint = try unquoteValue(alloc, raw);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "## Repro")) {
            section = .repro;
            continue;
        }
        if (std.mem.startsWith(u8, line, "## Comments")) {
            section = .comments;
            continue;
        }
        switch (section) {
            .body => {
                try body.appendSlice(alloc, line);
                try body.append(alloc, '\n');
            },
            .repro => {
                try repro.appendSlice(alloc, line);
                try repro.append(alloc, '\n');
            },
            .comments => {
                if (std.mem.startsWith(u8, line, "- ") and line.len > 23) {
                    const at = isoToEpoch(line[2..22]) orelse continue;
                    const rest = line[23..];
                    const colon = std.mem.indexOf(u8, rest, ": ") orelse continue;
                    try comments.append(alloc, .{
                        .at = at,
                        .author = rest[0..colon],
                        .text = rest[colon + 2 ..],
                    });
                }
            },
        }
    }
    if (in_frontmatter) return error.BadIssueFile;
    if (issue.seq == 0) return error.BadIssueFile;
    // Trim the surrounding blank lines the formatter puts after frontmatter,
    // the `## Repro` heading, and each section's trailing newline.
    issue.body = std.mem.trim(u8, body.items, "\n");
    issue.repro_lines = std.mem.trim(u8, repro.items, "\n");
    issue.comments = comments.items;
    return issue;
}

fn loadIssue(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, seq: u32) !?model.Issue {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = issuePath(&pbuf, dir, seq);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parseIssue(alloc, text);
}

fn saveIssue(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, issue: *const model.Issue) !void {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const issues_dir = std.fmt.bufPrint(&dbuf, "{s}/.life/issues", .{dir}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(io, issues_dir);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = issuePath(&pbuf, dir, issue.seq);
    const text = try formatIssue(alloc, issue);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

fn issueSeqFromName(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "LI-") or !std.mem.endsWith(u8, name, ".md")) return null;
    return std.fmt.parseInt(u32, name[3 .. name.len - 3], 10) catch null;
}

fn listIssues(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) ![]model.Issue {
    var out = std.ArrayList(model.Issue).empty;
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const issues_dir = std.fmt.bufPrint(&dbuf, "{s}/.life/issues", .{dir}) catch unreachable;
    var d = std.Io.Dir.cwd().openDir(io, issues_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const seq = issueSeqFromName(entry.name) orelse continue;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = issuePath(&pbuf, dir, seq);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1 << 20));
        try out.append(alloc, try parseIssue(alloc, text));
    }
    std.mem.sort(model.Issue, out.items, {}, struct {
        fn lessThan(_: void, a: model.Issue, b: model.Issue) bool {
            return a.seq < b.seq;
        }
    }.lessThan);
    return out.items;
}

fn nextSeq(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !u32 {
    const all = try listIssues(alloc, io, dir);
    var max: u32 = 0;
    for (all) |iss| max = @max(max, iss.seq);
    return max + 1;
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

test "iso round trip with known anchors" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", epochToIsoUtc(&buf, 0));
    try std.testing.expectEqualStrings("2000-01-01T00:00:00Z", epochToIsoUtc(&buf, 946684800));
    try std.testing.expectEqualStrings("2024-02-29T12:00:00Z", epochToIsoUtc(&buf, 1709208000));
    try std.testing.expectEqual(@as(?i64, 0), isoToEpoch("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 946684800), isoToEpoch("2000-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1709208000), isoToEpoch("2024-02-29T12:00:00Z"));
    try std.testing.expect(isoToEpoch("2026-13-40T99:99:99Z") == null);
    try std.testing.expect(isoToEpoch("not a date") == null);
}

test "issue file round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var iss = model.Issue{
        .seq = 1,
        .title = "say \"hi\" \\ ok",
        .body = "some *markdown*\nbody",
        .status = .confirmed,
        .priority = .p1,
        .source = .ci,
        .reporter = "agent:ci",
        .assignee = "bob",
        .created_at = 1760601600,
        .updated_at = 1760601600,
        .fingerprint = "sha256:abc",
        .repro_lines = "version: 0.39.13\ncommand: zig build",
        .comments = &.{.{ .at = 1760601700, .author = "alice", .text = "status new → triaged" }},
    };
    try saveIssue(alloc, io, dir, &iss);
    const got = (try loadIssue(alloc, io, dir, 1)).?;
    try std.testing.expectEqualStrings(iss.title, got.title);
    try std.testing.expectEqualStrings(iss.body, got.body);
    try std.testing.expectEqual(iss.status, got.status);
    try std.testing.expectEqual(iss.priority, got.priority);
    try std.testing.expectEqualStrings(iss.reporter, got.reporter);
    try std.testing.expectEqualStrings(iss.fingerprint, got.fingerprint);
    try std.testing.expectEqualStrings(iss.repro_lines, got.repro_lines);
    try std.testing.expectEqual(@as(usize, 1), got.comments.len);
    try std.testing.expectEqualStrings("alice", got.comments[0].author);
    try std.testing.expectEqualStrings("status new → triaged", got.comments[0].text);
    const all = try listIssues(alloc, io, dir);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectEqual(@as(u32, 2), try nextSeq(alloc, io, dir));
}

test "empty store nextSeq is 1 and list empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    try std.testing.expectEqual(@as(u32, 1), try nextSeq(arena.allocator(), io, dir));
    try std.testing.expectEqual(@as(usize, 0), (try listIssues(arena.allocator(), io, dir)).len);
    try std.testing.expect((try loadIssue(arena.allocator(), io, dir, 7)) == null);
}

test "parse rejects malformed files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadIssueFile, parseIssue(arena.allocator(), "no frontmatter here"));
    try std.testing.expectError(error.BadIssueFile, parseIssue(arena.allocator(), "---\nid: WRONG\n---\n"));
    try std.testing.expectError(error.BadIssueFile, parseIssue(arena.allocator(), "---\nstatus: bogus\n---\n"));
}

test "jsonEscape covers control chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try jsonEscape(arena.allocator(), "a\"b\\c\nd\re\tf");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\re\\tf", got);
}
