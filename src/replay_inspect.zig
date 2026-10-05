//! `replay-inspect` — offline incident inspection for a delivery-log
//! directory (docs/RUNTIME.md §13.9–§13.12).
//!
//! Invocation: `zig build` installs it as `zig-out/bin/replay-inspect`;
//! `zig build replay-inspect` runs it (but the pinned 0.17 toolchain removed
//! `b.args`, so CLI args after `--` never arrive — pass them to the installed
//! binary).
//!
//! ## What this is
//!
//! `src/runtime/delivery_log.zig` is a *storage layer*: it appends records to
//! segment files and reads them back verified, and it deliberately ships no CLI
//! (its "Deliberately not here" list said so until this file landed). This file
//! is the read-only half of that CLI gap — the §13.10 D7 "CLI" item. It answers
//! the questions an incident replay starts with, without starting a runtime:
//!
//! * how many segments / verified records are here, and which `seq` range;
//! * which tracks and kinds are in the log, and how much of each;
//! * where the sequence chain has **holes** (a ring overflow or a drain cursor
//!   that fell behind — §13.9 D3 says these must be visible, never silent);
//! * what stopped the scan: a torn tail (a write that did not finish —
//!   repairable) or a corrupt record (fully written, does not verify — a
//!   human's decision, `repair` refuses it).
//!
//! With `--from`/`--to` it lists the records inside one `[from, to)` window —
//! the same endpoint semantics `ReplayFromLog.open` documents in §13.12:
//! `from` inclusive, `to` exclusive, `from >= to` an empty window and not an
//! error. `--track NAME` (repeatable, union) narrows the listing to named
//! tracks and `--limit N` caps how many rows are printed; both narrow only
//! what is *listed* — per-track counts, holes and damage always cover the
//! whole log, and what a filter screens out is counted
//! (`skipped unselected`), never invisible. A `--track` name the log does not
//! mention is refused (`error.UnknownTrack`, exit 1): a typo is not an empty
//! window.
//!
//! ## What this is not
//!
//! * **Not a replayer.** It never decodes payloads and never touches a
//!   `Handle`: payload bytes are reported by length. Replaying is
//!   `ReplayFromLog`'s job (§13.10); this tool is what tells you *which* window
//!   is worth replaying and whether the log under it is whole.
//! * **Not a writer.** It opens nothing for writing. Repair stays an explicit
//!   `delivery_log.repair` call in code — the report names it, on purpose, so
//!   the operator's next step is a decision and not a flag.
//! * **Not a follower.** Like `ReplayFromLog` (§13.10 D4) this is
//!   load-then-report: it reads the directory as it is right now and does not
//!   track a writer that is still appending. Beside a live writer the worst
//!   case is a torn tail — reported as such, with its byte count.
//!
//! ## Exit codes
//!
//! | code | meaning |
//! |---|---|
//! | 0 | the log scanned clean (`Damage.none`) |
//! | 1 | usage error or I/O failure (including "directory not found") |
//! | 2 | torn tail — a partial write at the end; `delivery_log.repair` truncates it |
//! | 3 | corrupt record — fully written bytes that do not verify; `repair` refuses these |
//!
//! The config used for reading is `delivery_log.Config`'s default with
//! `dir_path` replaced: a frame above the default `max_record_bytes` (8 MiB)
//! is reported as corruption (`frame_too_large`), which is the reader's bound
//! doing its job — not a guess.

const std = @import("std");
const dlog = @import("runtime/delivery_log.zig");

/// The `[from, to)` listing window — §13.12's semantics, verbatim: `from`
/// inclusive, `to` exclusive, and `to` a *stop* (records at or past it are
/// counted as skipped-after, never listed). All four fields null/default means
/// "no window": the report is a summary and `rows` is empty.
///
/// `tracks` narrows the listing to the named tracks (union; the slice is the
/// caller's and must outlive the report build). What it screens out is counted
/// (`skipped_unselected`), never invisible — the same discipline
/// `ReplayFromLog.onlyTracks` has, with one deliberate difference: the filter
/// here decides *what is listed*, never what is true. Track counts, holes and
/// damage still cover the whole log.
///
/// `limit` caps how many rows are listed; everything past the cap counts as
/// skipped-after. `0` lists nothing, which is an answer, not an error.
pub const Window = struct {
    from: ?u64 = null,
    to: ?u64 = null,
    limit: ?u64 = null,
    tracks: ?[]const []const u8 = null,

    pub fn active(self: Window) bool {
        return self.from != null or self.to != null or self.limit != null or self.tracks != null;
    }

    fn selects(self: Window, track_id: []const u8) bool {
        const tracks = self.tracks orelse return true;
        for (tracks) |id| {
            if (std.mem.eql(u8, id, track_id)) return true;
        }
        return false;
    }
};

/// A gap in the verified sequence chain: the record after `after` that the log
/// actually holds is `before`, so `after + 1 ..= before - 1` never made it to
/// disk. §13.9 D3's two sources (ring overflow, drain cursor left behind) both
/// surface here.
pub const Hole = struct {
    after: u64,
    before: u64,

    pub fn missing(self: Hole) u64 {
        return self.before - self.after - 1;
    }
};

pub const TrackCount = struct {
    track_id: []u8,
    count: u64,
};

/// One record inside the listing window. `track_id` is owned by the `Report`;
/// the payload is *not* kept — its length is all the report prints.
pub const Row = struct {
    seq: u64,
    track_id: []u8,
    kind: dlog.Kind,
    recorded_ns: i64,
    payload_len: u32,
};

pub const Report = struct {
    /// Segment files the scan walked (by name, ascending id).
    segments: usize,
    /// Verified records — the prefix `scan` guarantees. A damaged record is
    /// never in here, and neither is anything after one.
    records: usize,
    seq_first: ?u64,
    seq_last: ?u64,
    kind_message: u64,
    kind_timer: u64,
    /// Deterministic order: count descending, then track id ascending, so the
    /// printed report is stable enough to diff and to grep.
    tracks: []TrackCount,
    holes: []Hole,
    /// Verified records whose `seq` did not increase over the previous record.
    /// `Writer.append` refuses that (`error.SeqNotIncreasing`), so a non-zero
    /// count means the file was not produced by one writer — reported, not
    /// folded into the holes.
    out_of_order: u64,
    damage: dlog.Damage,

    window: Window,
    /// Records inside the window, in log order. Empty when the window is
    /// inactive.
    rows: []Row,
    skipped_before: u64,
    skipped_after: u64,
    /// Records inside the window the track filter screened out.
    skipped_unselected: u64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.tracks) |t| allocator.free(t.track_id);
        allocator.free(self.tracks);
        allocator.free(self.holes);
        for (self.rows) |r| allocator.free(r.track_id);
        allocator.free(self.rows);
        self.* = undefined;
    }

    /// The process exit code this report maps to (see the module doc).
    pub fn exitCode(self: *const Report) u8 {
        return switch (self.damage) {
            .none => 0,
            .torn => 2,
            .corrupt => 3,
        };
    }
};

/// Read the whole log under `dir_path` and build the report. Errors are
/// `scan`'s own (`error.BadMagic` / `UnsupportedVersion` / `CorruptHeader` for
/// a segment that cannot be identified at all, `error.FileNotFound` for a
/// missing directory) plus allocation failure.
pub fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    window: Window,
) !Report {
    var scanned = try dlog.scan(allocator, io, .{ .dir_path = dir_path });
    defer scanned.deinit(allocator);

    const segments = blk: {
        const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        const ids = try dlog.segmentIds(allocator, io, dir);
        defer allocator.free(ids);
        break :blk ids.len;
    };

    var track_counts: std.StringHashMap(u64) = .init(allocator);
    defer {
        var it = track_counts.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        track_counts.deinit();
    }
    var holes: std.ArrayList(Hole) = .empty;
    defer holes.deinit(allocator);
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |r| allocator.free(r.track_id);
        rows.deinit(allocator);
    }

    var kind_message: u64 = 0;
    var kind_timer: u64 = 0;
    var out_of_order: u64 = 0;
    var skipped_before: u64 = 0;
    var skipped_after: u64 = 0;
    var skipped_unselected: u64 = 0;

    // A track filter names tracks *of this log*: a name it does not mention is
    // a typo, not an empty answer — refused like `ReplayFromLog.onlyTracks`
    // refuses it, because "the window you asked for does not exist" must never
    // read as "the window was empty".
    if (window.tracks) |tracks| {
        for (tracks) |id| {
            var found = false;
            for (scanned.records) |r| {
                if (std.mem.eql(u8, r.track_id, id)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownTrack;
        }
    }

    for (scanned.records, 0..) |r, i| {
        switch (r.kind) {
            .message => kind_message += 1,
            .timer => kind_timer += 1,
        }
        // Intern the key: `r.track_id` dies with the scan, so the map owns a
        // dupe — but only the first time each id is seen (the defer below frees
        // exactly the keys the map ends up holding).
        const entry = try track_counts.getOrPut(r.track_id);
        if (!entry.found_existing) {
            entry.key_ptr.* = allocator.dupe(u8, r.track_id) catch |err| {
                // getOrPut already stored the borrowed slice; take it back out
                // so the defer below never frees memory the map does not own.
                _ = track_counts.remove(r.track_id);
                return err;
            };
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;

        if (i > 0) {
            const prev = scanned.records[i - 1].seq;
            if (r.seq > prev + 1) {
                try holes.append(allocator, .{ .after = prev, .before = r.seq });
            } else if (r.seq <= prev) {
                out_of_order += 1;
            }
        }

        if (window.active()) {
            if (window.from) |f| {
                if (r.seq < f) {
                    skipped_before += 1;
                    continue;
                }
            }
            if (window.to) |t| {
                if (r.seq >= t) {
                    skipped_after += 1;
                    continue;
                }
            }
            if (!window.selects(r.track_id)) {
                skipped_unselected += 1;
                continue;
            }
            if (window.limit) |cap| {
                if (rows.items.len >= cap) {
                    skipped_after += 1;
                    continue;
                }
            }
            try rows.append(allocator, .{
                .seq = r.seq,
                .track_id = try allocator.dupe(u8, r.track_id),
                .kind = r.kind,
                .recorded_ns = r.recorded_ns,
                .payload_len = @intCast(r.payload.len),
            });
        }
    }

    var tracks: std.ArrayList(TrackCount) = .empty;
    errdefer {
        for (tracks.items) |t| allocator.free(t.track_id);
        tracks.deinit(allocator);
    }
    {
        var it = track_counts.iterator();
        while (it.next()) |e| {
            try tracks.append(allocator, .{
                .track_id = try allocator.dupe(u8, e.key_ptr.*),
                .count = e.value_ptr.*,
            });
        }
    }
    std.mem.sort(TrackCount, tracks.items, {}, struct {
        fn lt(_: void, a: TrackCount, b: TrackCount) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.track_id, b.track_id);
        }
    }.lt);

    return .{
        .segments = segments,
        .records = scanned.records.len,
        .seq_first = if (scanned.records.len > 0) scanned.records[0].seq else null,
        .seq_last = if (scanned.records.len > 0) scanned.records[scanned.records.len - 1].seq else null,
        .kind_message = kind_message,
        .kind_timer = kind_timer,
        .tracks = try tracks.toOwnedSlice(allocator),
        .holes = try holes.toOwnedSlice(allocator),
        .out_of_order = out_of_order,
        .damage = scanned.damage,
        .window = window,
        .rows = try rows.toOwnedSlice(allocator),
        .skipped_before = skipped_before,
        .skipped_after = skipped_after,
        .skipped_unselected = skipped_unselected,
    };
}

// ── CLI ─────────────────────────────────────────────────────────────────────

const usage =
    \\Usage: replay-inspect <dir> [--from N] [--to N] [--limit N] [--track NAME]...
    \\
    \\  (`zig build replay-inspect` builds and runs this tool, but the pinned
    \\  toolchain does not forward args after `--` — invoke the installed
    \\  binary: `zig build` once, then `zig-out/bin/replay-inspect <dir> …`)
    \\
    \\Read a delivery-log directory (docs/RUNTIME.md §13.9) and report what an
    \\incident replay starts from: verified records, the seq range, per-track
    \\and per-kind counts, holes in the sequence chain, and the damage that
    \\stopped the scan. Never writes.
    \\
    \\  <dir>        directory holding delivery-<id>.log segments
    \\  --from N     list records with seq >= N (inclusive)
    \\  --to N       stop listing at seq N (exclusive; §13.12 window semantics)
    \\  --limit N    list at most N records (the rest counts as skipped-after)
    \\  --track NAME list only this track; repeatable (union). A NAME the log
    \\               does not mention is refused — a typo is not an empty window.
    \\
    \\Filtering narrows only what is *listed*: per-track counts, holes and
    \\damage always cover the whole log.
    \\
    \\Exit codes: 0 clean · 1 usage/I-O error · 2 torn tail · 3 corrupt record.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    {
        // Windows args need an allocator (UTF-16 -> UTF-8); init() is a
        // compile error there.
        var iter = try init.minimal.args.iterateAllocator(allocator);
        defer iter.deinit();
        while (iter.next()) |arg| try args.append(allocator, arg);
    }

    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;

    var dir_path: ?[]const u8 = null;
    var window: Window = .{};
    var tracks: std.ArrayList([]const u8) = .empty;
    defer tracks.deinit(allocator);
    var i: usize = 1; // args[0] is the executable name
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.items.len) return usageError("missing value after --from");
            window.from = std.fmt.parseInt(u64, args.items[i], 10) catch
                return usageError("--from needs a non-negative integer");
        } else if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.items.len) return usageError("missing value after --to");
            window.to = std.fmt.parseInt(u64, args.items[i], 10) catch
                return usageError("--to needs a non-negative integer");
        } else if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.items.len) return usageError("missing value after --limit");
            window.limit = std.fmt.parseInt(u64, args.items[i], 10) catch
                return usageError("--limit needs a non-negative integer");
        } else if (std.mem.eql(u8, a, "--track")) {
            i += 1;
            if (i >= args.items.len) return usageError("missing value after --track");
            try tracks.append(allocator, args.items[i]);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try out.writeAll(usage);
            try out.flush();
            return;
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(a);
        } else if (dir_path == null) {
            dir_path = a;
        } else {
            return usageError(a);
        }
    }
    if (tracks.items.len > 0) window.tracks = tracks.items;

    const dir = dir_path orelse {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(1);
    };

    var report = inspect(allocator, io, dir, window) catch |err| {
        if (err == error.UnknownTrack) {
            try out.writeAll("replay-inspect: ");
            try out.writeAll(dir);
            try out.writeAll(": unknown --track (not in this log):");
            for (window.tracks.?) |id| {
                try out.writeAll(" ");
                try out.writeAll(id);
            }
            try out.writeAll("\n");
        } else {
            try out.print("replay-inspect: {s}: {s}\n", .{ dir, @errorName(err) });
        }
        try out.flush();
        std.process.exit(1);
    };
    defer report.deinit(allocator);

    try printReport(out, dir, &report);
    try out.flush();
    std.process.exit(report.exitCode());
}

fn usageError(detail: []const u8) noreturn {
    // stderr via std.debug.print: it cannot fail, so the error path carries no
    // `catch {}` (banned, scripts/check-production.sh) — and a usage error
    // belongs on stderr anyway.
    std.debug.print("replay-inspect: bad arguments near '{s}'\n{s}", .{ detail, usage });
    std.process.exit(1);
}

fn printReport(out: anytype, dir: []const u8, report: *const Report) !void {
    try out.print("replay-inspect: {s}\n", .{dir});
    try out.print("segments: {d}\n", .{report.segments});
    try out.print("records: {d} verified\n", .{report.records});
    if (report.seq_first) |first| {
        try out.print("seq: {d}..{d}\n", .{ first, report.seq_last.? });
    } else {
        try out.writeAll("seq: (none)\n");
    }
    try out.print("kinds: message={d} timer={d}\n", .{ report.kind_message, report.kind_timer });
    try out.print("tracks ({d}):", .{report.tracks.len});
    for (report.tracks) |t| try out.print(" {s}={d}", .{ t.track_id, t.count });
    try out.writeAll("\n");

    try out.print("holes: {d}\n", .{report.holes.len});
    for (report.holes) |h| {
        try out.print("  hole: after seq {d}, before seq {d} ({d} missing)\n", .{ h.after, h.before, h.missing() });
    }
    if (report.out_of_order != 0) {
        try out.print("out-of-order records: {d} (a single Writer never produces these)\n", .{report.out_of_order});
    }

    switch (report.damage) {
        .none => try out.writeAll("damage: none\n"),
        .torn => |bytes| try out.print(
            "damage: torn tail — {d} byte(s) after the last complete record (a write that did not finish; delivery_log.repair truncates it)\n",
            .{bytes},
        ),
        .corrupt => |c| try out.print(
            "damage: corrupt — segment={d} offset={d} index={d} reason={s} (fully written bytes that do not verify; repair refuses these)\n",
            .{ c.segment_id, c.offset, c.index, @tagName(c.reason) },
        ),
    }

    if (report.window.active()) {
        if (report.window.from) |f| {
            if (report.window.to) |t| {
                try out.print("window [{d}, {d}): ", .{ f, t });
            } else {
                try out.print("window [{d}, end): ", .{f});
            }
        } else if (report.window.to) |t| {
            try out.print("window [start, {d}): ", .{t});
        } else {
            try out.writeAll("window [start, end): ");
        }
        if (report.window.tracks) |tracks| {
            try out.writeAll("tracks {");
            for (tracks, 0..) |id, k| {
                if (k != 0) try out.writeAll(", ");
                try out.writeAll(id);
            }
            try out.writeAll("} ");
        }
        if (report.window.limit) |cap| try out.print("limit {d} ", .{cap});
        try out.print("{d} record(s) listed (skipped {d} before, {d} after, {d} unselected)\n", .{
            report.rows.len,
            report.skipped_before,
            report.skipped_after,
            report.skipped_unselected,
        });
        for (report.rows) |r| {
            try out.print("  seq={d} track={s} kind={s} recorded_ns={d} payload={d}B\n", .{
                r.seq, r.track_id, @tagName(r.kind), r.recorded_ns, r.payload_len,
            });
        }
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

/// A unique log directory per test call (the same `std.testing.tmpDir` pattern
/// `delivery_log.zig`'s tests use, and for the same reason: parallel test
/// binaries must not collide on a fixed relative path).
const TestDir = struct {
    tmp: std.testing.TmpDir,
    path_buf: [160]u8 = undefined,

    fn init() TestDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn path(self: *TestDir) ![]const u8 {
        return std.fmt.bufPrint(&self.path_buf, ".zig-cache/tmp/{s}/delivery", .{self.tmp.sub_path[0..]});
    }

    fn deinit(self: *TestDir) void {
        self.tmp.cleanup();
    }
};

fn testConfig(dir_path: []const u8) dlog.Config {
    return .{ .dir_path = dir_path, .sync_mode = .none };
}

const test_records = [_]struct { seq: u64, track: []const u8, kind: dlog.Kind, payload: []const u8 }{
    .{ .seq = 0, .track = "book", .kind = .message, .payload = "aaaa" },
    .{ .seq = 1, .track = "risk", .kind = .timer, .payload = "bb" },
    .{ .seq = 2, .track = "book", .kind = .message, .payload = "cccc" },
    .{ .seq = 10, .track = "risk", .kind = .message, .payload = "d" },
    .{ .seq = 11, .track = "book", .kind = .timer, .payload = "eeeee" },
};

fn writeTestLog(io: std.Io, dir_path: []const u8) !void {
    var writer = try dlog.Writer.open(std.testing.allocator, io, testConfig(dir_path));
    defer writer.deinit();
    for (test_records, 0..) |r, i| {
        try writer.append(.{
            .seq = r.seq,
            .track_id = r.track,
            .kind = r.kind,
            .recorded_ns = @intCast(i * 1000),
            .payload = r.payload,
        });
    }
}

fn readSegment(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, id: u64) ![]u8 {
    const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    return dir.readFileAlloc(io, try std.fmt.bufPrint(&name_buf, "delivery-{d:0>20}.log", .{id}), allocator, .limited(1 << 20));
}

fn writeSegment(io: std.Io, dir_path: []const u8, id: u64, bytes: []const u8) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const file = try dir.createFile(io, try std.fmt.bufPrint(&name_buf, "delivery-{d:0>20}.log", .{id}), .{ .truncate = true, .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

test "replay-inspect: a clean log reports segments, tracks, kinds and one hole" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    var report = try inspect(allocator, io, dir_path, .{});
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.segments);
    try std.testing.expectEqual(@as(usize, 5), report.records);
    try std.testing.expectEqual(@as(?u64, 0), report.seq_first);
    try std.testing.expectEqual(@as(?u64, 11), report.seq_last);
    try std.testing.expectEqual(@as(u64, 3), report.kind_message);
    try std.testing.expectEqual(@as(u64, 2), report.kind_timer);
    try std.testing.expectEqual(@as(u64, 0), report.out_of_order);

    // The seq chain is 0,1,2,10,11: exactly one hole, 3..=9 never made it.
    try std.testing.expectEqual(@as(usize, 1), report.holes.len);
    try std.testing.expectEqual(@as(u64, 2), report.holes[0].after);
    try std.testing.expectEqual(@as(u64, 10), report.holes[0].before);
    try std.testing.expectEqual(@as(u64, 7), report.holes[0].missing());

    // Equal counts sort by track id, so the report is byte-stable.
    try std.testing.expectEqual(@as(usize, 2), report.tracks.len);
    try std.testing.expectEqualStrings("book", report.tracks[0].track_id);
    try std.testing.expectEqual(@as(u64, 3), report.tracks[0].count);
    try std.testing.expectEqualStrings("risk", report.tracks[1].track_id);
    try std.testing.expectEqual(@as(u64, 2), report.tracks[1].count);

    try std.testing.expectEqual(dlog.Damage.none, report.damage);
    try std.testing.expectEqual(@as(u8, 0), report.exitCode());
    try std.testing.expectEqual(@as(usize, 0), report.rows.len);
}

test "replay-inspect: the window lists [from, to) and counts what it skipped" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    var report = try inspect(allocator, io, dir_path, .{ .from = 1, .to = 10 });
    defer report.deinit(allocator);

    // [1, 10) holds seq 1 and 2; seq 0 is before, seq 10/11 are after. The
    // window is a *listing* window: the hole report still covers the whole log.
    try std.testing.expectEqual(@as(usize, 2), report.rows.len);
    try std.testing.expectEqual(@as(u64, 1), report.rows[0].seq);
    try std.testing.expectEqualStrings("risk", report.rows[0].track_id);
    try std.testing.expectEqual(dlog.Kind.timer, report.rows[0].kind);
    try std.testing.expectEqual(@as(u32, 2), report.rows[0].payload_len);
    try std.testing.expectEqual(@as(u64, 2), report.rows[1].seq);
    try std.testing.expectEqual(@as(u64, 1), report.skipped_before);
    try std.testing.expectEqual(@as(u64, 2), report.skipped_after);
    try std.testing.expectEqual(@as(usize, 1), report.holes.len);

    // A window that starts at the log's first record skips nothing before.
    var rest = try inspect(allocator, io, dir_path, .{ .from = 0, .to = 11 });
    defer rest.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), rest.rows.len);
    try std.testing.expectEqual(@as(u64, 0), rest.skipped_before);
    try std.testing.expectEqual(@as(u64, 1), rest.skipped_after);

    // from >= to is an empty window, not an error (§13.12).
    var empty = try inspect(allocator, io, dir_path, .{ .from = 10, .to = 10 });
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.rows.len);

    // One-sided: only --to lists from the log's start; only --from to its end.
    var head = try inspect(allocator, io, dir_path, .{ .to = 2 });
    defer head.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), head.rows.len);
    try std.testing.expectEqual(@as(u64, 0), head.skipped_before);
    try std.testing.expectEqual(@as(u64, 3), head.skipped_after);
    var tail = try inspect(allocator, io, dir_path, .{ .from = 10 });
    defer tail.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), tail.rows.len);
    try std.testing.expectEqual(@as(u64, 3), tail.skipped_before);
    try std.testing.expectEqual(@as(u64, 0), tail.skipped_after);
}

test "replay-inspect: a torn tail is reported with its byte count and exit code 2" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    const full = try readSegment(io, allocator, dir_path, 0);
    defer allocator.free(full);
    try writeSegment(io, dir_path, 0, full[0 .. full.len - 3]);

    var report = try inspect(allocator, io, dir_path, .{});
    defer report.deinit(allocator);

    // The last record lost 3 payload bytes: four verified records survive, and
    // the torn byte count is the whole partial frame that is left — 32-byte
    // record header + 4-byte track id ("book") + 2 of the 5 payload bytes,
    // because the reader cannot know a frame's first byte from its last.
    try std.testing.expectEqual(@as(usize, 4), report.records);
    try std.testing.expectEqual(@as(u64, 38), report.damage.torn);
    try std.testing.expectEqual(@as(u8, 2), report.exitCode());
    // The verified prefix is intact: the hole is still the one real hole.
    try std.testing.expectEqual(@as(usize, 1), report.holes.len);
}

test "replay-inspect: a flipped byte is corruption with a location and exit code 3" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    const full = try readSegment(io, allocator, dir_path, 0);
    defer allocator.free(full);
    const damaged = try allocator.dupe(u8, full);
    defer allocator.free(damaged);
    // First record's first payload byte: 12-byte file header + 32-byte record
    // header + 4-byte track id ("book").
    damaged[12 + 32 + 4] ^= 0xff;
    try writeSegment(io, dir_path, 0, damaged);

    var report = try inspect(allocator, io, dir_path, .{});
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.records);
    const c = report.damage.corrupt;
    try std.testing.expectEqual(dlog.CorruptReason.crc_mismatch, c.reason);
    try std.testing.expectEqual(@as(u64, 0), c.segment_id);
    try std.testing.expectEqual(@as(usize, 0), c.index);
    try std.testing.expectEqual(@as(u64, 12), c.offset);
    try std.testing.expectEqual(@as(u8, 3), report.exitCode());
}

test "replay-inspect: an empty log is 0 records, no seq range, clean" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    {
        var writer = try dlog.Writer.open(allocator, io, testConfig(dir_path));
        writer.deinit();
    }

    var report = try inspect(allocator, io, dir_path, .{});
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.segments);
    try std.testing.expectEqual(@as(usize, 0), report.records);
    try std.testing.expectEqual(@as(?u64, null), report.seq_first);
    try std.testing.expectEqual(@as(?u64, null), report.seq_last);
    try std.testing.expectEqual(@as(usize, 0), report.tracks.len);
    try std.testing.expectEqual(@as(usize, 0), report.holes.len);
    try std.testing.expectEqual(dlog.Damage.none, report.damage);
    try std.testing.expectEqual(@as(u8, 0), report.exitCode());
}

test "replay-inspect: a missing directory is an error, not an empty report" {
    const io = std.testing.io;
    try std.testing.expectError(
        error.FileNotFound,
        inspect(std.testing.allocator, io, ".zig-cache/tmp/replay-inspect-no-such-dir", .{}),
    );
}

test "replay-inspect: --track narrows the listing, never the truth" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    // One track: book holds seq 0, 2, 11; the two risk records are counted,
    // not hidden — and the hole report still covers the whole log.
    const one = [_][]const u8{"book"};
    var book = try inspect(allocator, io, dir_path, .{ .tracks = &one });
    defer book.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), book.rows.len);
    try std.testing.expectEqual(@as(u64, 0), book.rows[0].seq);
    try std.testing.expectEqual(@as(u64, 2), book.rows[1].seq);
    try std.testing.expectEqual(@as(u64, 11), book.rows[2].seq);
    try std.testing.expectEqual(@as(u64, 2), book.skipped_unselected);
    try std.testing.expectEqual(@as(u64, 0), book.skipped_before);
    try std.testing.expectEqual(@as(u64, 0), book.skipped_after);
    try std.testing.expectEqual(@as(usize, 1), book.holes.len);
    try std.testing.expectEqual(@as(usize, 2), book.tracks.len); // counts unfiltered
    try std.testing.expectEqual(@as(usize, 5), book.records);

    // The union of both tracks is the whole log.
    const both = [_][]const u8{ "book", "risk" };
    var all = try inspect(allocator, io, dir_path, .{ .tracks = &both });
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), all.rows.len);
    try std.testing.expectEqual(@as(u64, 0), all.skipped_unselected);

    // A track the log never mentions is a typo, not an empty window.
    const typo = [_][]const u8{"bok"};
    try std.testing.expectError(
        error.UnknownTrack,
        inspect(allocator, io, dir_path, .{ .tracks = &typo }),
    );
}

test "replay-inspect: --limit caps the listing and counts the rest as after" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();
    try writeTestLog(io, dir_path);

    // The cap lists the window's first N records in log order; what does not
    // fit is skipped-after, exactly like records past `--to`.
    var two = try inspect(allocator, io, dir_path, .{ .limit = 2 });
    defer two.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), two.rows.len);
    try std.testing.expectEqual(@as(u64, 0), two.rows[0].seq);
    try std.testing.expectEqual(@as(u64, 1), two.rows[1].seq);
    try std.testing.expectEqual(@as(u64, 3), two.skipped_after);

    // 0 lists nothing, which is an answer, not an error.
    var none = try inspect(allocator, io, dir_path, .{ .limit = 0 });
    defer none.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), none.rows.len);
    try std.testing.expectEqual(@as(u64, 5), none.skipped_after);

    // Combined with a track filter: unselected and past-cap count separately.
    // risk holds seq 1 and 10; the cap keeps seq 1, seq 10 is after, and the
    // three book records are unselected.
    const risk = [_][]const u8{"risk"};
    var combo = try inspect(allocator, io, dir_path, .{ .tracks = &risk, .limit = 1 });
    defer combo.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), combo.rows.len);
    try std.testing.expectEqual(@as(u64, 1), combo.rows[0].seq);
    try std.testing.expectEqualStrings("risk", combo.rows[0].track_id);
    try std.testing.expectEqual(@as(u64, 3), combo.skipped_unselected);
    try std.testing.expectEqual(@as(u64, 1), combo.skipped_after);
    try std.testing.expectEqual(@as(u64, 0), combo.skipped_before);
}
