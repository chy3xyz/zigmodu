//! Write-Ahead Log (WAL) for DistributedEventBus
//!
//! Durable message storage with segment-based rotation and binary serialization.
//! Uses std.Io.Dir / std.Io.File for Zig 0.16 compatibility.
//!
//! Key features:
//! - Segment-based storage with automatic rotation
//! - Sequence numbers for idempotent delivery
//! - Binary format: [seq][timestamp][topic_len][topic][payload_len][payload][source_len][source]
//! - fsync for durability per sync_mode config

const std = @import("std");
const Time = @import("../Time.zig");

pub const MAX_SEGMENT_SIZE: u64 = 64 * 1024 * 1024; // 64MB

pub const WALConfig = struct {
    dir_path: []const u8 = "data/wal",
    max_segment_size: u64 = MAX_SEGMENT_SIZE,
    max_segments: usize = 0,
    sync_mode: SyncMode = .fsync,
};

pub const SyncMode = enum { fsync, segment_sync, none };

pub const WAL = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    config: WALConfig,

    segments: std.ArrayList(*Segment),
    current_segment: *Segment,
    next_segment_id: u64,
    wal_index: u64 = 0,
    committed_index: u64 = 0,

    pub const Segment = struct {
        id: u64,
        file: std.Io.File,
        path: []const u8,
        start_index: u64,
        end_index: u64,
        size_bytes: u64,
    };

    pub const Entry = struct {
        index: u64,
        timestamp_ms: i64,
        topic: []const u8,
        payload: []const u8,
        source_node: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: WALConfig) !Self {
        // Ensure directory exists
        std.Io.Dir.cwd(io).createDirPath(io, config.dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const segments = std.ArrayList(*Segment).empty;

        // Create initial segment
        const current = try createSegment(allocator, io, config.dir_path, 0);

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .segments = segments,
            .current_segment = current,
            .next_segment_id = 1,
            .wal_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.segments.items) |seg| {
            seg.file.sync(self.io) catch |err| std.log.err("[WAL] Failed to sync segment {d}: {}", .{ seg.id, err });
            seg.file.close(self.io);
            self.allocator.free(seg.path);
            self.allocator.destroy(seg);
        }
        self.current_segment.file.sync(self.io) catch |err| std.log.err("[WAL] Failed to sync current segment: {}", .{err});
        self.current_segment.file.close(self.io);
        self.allocator.free(self.current_segment.path);
        self.allocator.destroy(self.current_segment);
        self.segments.deinit(self.allocator);
    }

    pub fn append(self: *Self, entry: WALEntry) !u64 {
        self.wal_index +%= 1;
        const seq = self.wal_index;

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        try serializeEntry(entry, seq, self.allocator, &buffer);

        _ = try self.current_segment.file.seekTo(self.io, self.current_segment.size_bytes);
        _ = try self.current_segment.file.writeStreamingAll(self.io, buffer.items);
        self.current_segment.end_index = seq;
        self.current_segment.size_bytes +%= buffer.items.len;

        if (self.config.sync_mode == .fsync) {
            try self.current_segment.file.sync(self.io);
        }

        if (self.current_segment.size_bytes >= self.config.max_segment_size) {
            try self.rotateSegment();
        }

        return seq;
    }

    pub fn markCommitted(self: *Self, seq: u64) void {
        self.committed_index = @max(self.committed_index, seq);
    }

    pub fn lastIndex(self: Self) u64 {
        return self.wal_index;
    }

    pub fn lastCommittedIndex(self: Self) u64 {
        return self.committed_index;
    }

    pub fn readFrom(self: *Self, start_seq: u64) ![]Entry {
        _ = self;
        _ = start_seq;
        return &[_]Entry{};
    }

    pub fn getUncommittedEntries(self: *Self) ![]Entry {
        return self.readFrom(self.committed_index + 1);
    }

    pub fn cleanup(self: *Self, before_seq: u64) !usize {
        var removed: usize = 0;
        while (self.segments.items.len > 1) {
            const oldest = self.segments.items[0];
            if (oldest.end_index >= before_seq) break;
            if (oldest == self.current_segment) break;
            try removeSegment(self.allocator, self.io, oldest);
            _ = self.segments.orderedRemove(self.allocator, 0);
            removed += 1;
        }
        return removed;
    }

    // ── private ──

    fn rotateSegment(self: *Self) !void {
        try self.current_segment.file.sync(self.io);
        self.current_segment.file.close(self.io);

        const new_seg = try createSegment(self.allocator, self.io, self.config.dir_path, self.next_segment_id);
        self.next_segment_id +%= 1;
        try self.segments.append(self.allocator, self.current_segment);
        self.current_segment = new_seg;

        while (self.config.max_segments > 0 and self.segments.items.len >= self.config.max_segments) {
            const oldest = self.segments.orderedRemove(self.allocator, 0);
            try removeSegment(self.allocator, self.io, oldest);
        }
    }
};

// ── file helpers ──

fn createSegment(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, id: u64) !*WAL.Segment {
    const path = try std.fmt.allocPrint(allocator, "{s}/{:0>20}.wal", .{ dir, id });
    errdefer allocator.free(path);

    const file = try std.Io.Dir.cwd(io).createFile(io, path, .{ .truncate = false, .read = true });
    errdefer file.close(io);

    const seg = try allocator.create(WAL.Segment);
    seg.* = .{ .id = id, .file = file, .path = path, .start_index = 0, .end_index = 0, .size_bytes = 0 };
    return seg;
}

fn removeSegment(allocator: std.mem.Allocator, io: std.Io, seg: *WAL.Segment) !void {
    seg.file.close(io);
    std.Io.Dir.cwd(io).deleteFile(io, seg.path) catch {};
    allocator.free(seg.path);
    allocator.destroy(seg);
}

/// Packed binary header for WAL entries (28 bytes). Zig 0.16 packed struct
/// replaces manual writeInt calls with a single @bitCast copy.
const WALEntryHeader = packed struct {
    seq: u64,
    timestamp_ms: i64,
    topic_len: u32,
    payload_len: u32,
    source_len: u32,
};

fn serializeEntry(entry: WALEntry, seq: u64, alloc: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    const header = WALEntryHeader{
        .seq = seq,
        .timestamp_ms = entry.timestamp_ms,
        .topic_len = @intCast(entry.topic.len),
        .payload_len = @intCast(entry.payload.len),
        .source_len = @intCast(entry.source_node.len),
    };
    const header_bytes: [@sizeOf(WALEntryHeader)]u8 = @bitCast(header);
    try buf.appendSlice(alloc, &header_bytes);
    try buf.appendSlice(alloc, entry.topic);
    try buf.appendSlice(alloc, entry.payload);
    try buf.appendSlice(alloc, entry.source_node);
}

pub const WALEntry = struct {
    topic: []const u8,
    payload: []const u8,
    source_node: []const u8,
    timestamp_ms: i64 = 0,
};

// ── Tests ──

test "WAL init and basic append" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config = WALConfig{ .dir_path = "wal_test", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, config);
    defer wal.deinit();

    try std.testing.expectEqual(@as(u64, 0), wal.lastIndex());

    const seq = try wal.append(.{ .topic = "test", .payload = "hello", .source_node = "n1" });
    try std.testing.expectEqual(@as(u64, 1), seq);
}

test "WAL multi-append and commit tracking" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config = WALConfig{ .dir_path = "wal_test2", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, config);
    defer wal.deinit();

    for (0..5) |i| {
        const payload = try std.fmt.allocPrint(allocator, "msg-{d}", .{i});
        defer allocator.free(payload);
        _ = try wal.append(.{ .topic = "test", .payload = payload, .source_node = "n1" });
    }

    try std.testing.expectEqual(@as(u64, 5), wal.lastIndex());

    wal.markCommitted(3);
    try std.testing.expectEqual(@as(u64, 3), wal.lastCommittedIndex());
}
