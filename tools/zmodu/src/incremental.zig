// Incremental Generation — SHA256 hash tracking for generated file manifest
const std = @import("std");
const Io = std.Io;

pub const HASH_FILE_NAME = ".zmodu/generated_hashes.json";

pub const HashEntry = struct {
    path: []const u8,
    hash: [64]u8,
};

/// Compute SHA256 hex digest of content.
pub fn sha256Hex(content: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

/// Check if a file matches its stored hash in the manifest.
/// Returns true if unchanged (hash matches), false if modified or not in manifest.
pub fn isUnchanged(allocator: std.mem.Allocator, io: Io, project_dir: []const u8, relative_path: []const u8, manifest_files: *const std.StringHashMap([64]u8)) bool {
    const stored_hash = manifest_files.get(relative_path) orelse return false;

    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ project_dir, relative_path }) catch return false;

    const content = Io.Dir.cwd().readFileAlloc(io, full_path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch return false;
    defer allocator.free(content);

    const current_hash = sha256Hex(content);
    return std.mem.eql(u8, &stored_hash, &current_hash);
}

/// Save a hash manifest to the project's .zmodu/generated_hashes.json.
pub fn saveManifest(allocator: std.mem.Allocator, io: Io, project_dir: []const u8, entries: []const HashEntry, version: []const u8) !void {
    // Ensure .zmodu/ dir exists
    var dotmodu_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dotmodu_path = try std.fmt.bufPrint(&dotmodu_buf, "{s}/.zmodu", .{project_dir});
    Io.Dir.cwd().createDirPath(io, dotmodu_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, HASH_FILE_NAME });
    defer allocator.free(path);

    // Build JSON manually
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"generated_at\": \"2026-01-01T00:00:00Z\",\n  \"zmodu_version\": \"");
    try buf.appendSlice(allocator, version);
    try buf.appendSlice(allocator, "\",\n  \"files\": {\n");
    for (entries, 0..) |entry, i| {
        try buf.appendSlice(allocator, "    \"");
        // Escape path for JSON safety
        for (entry.path) |c| {
            switch (c) {
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '"' => try buf.appendSlice(allocator, "\\\""),
                else => try buf.append(allocator, c),
            }
        }
        try buf.appendSlice(allocator, "\": \"");
        try buf.appendSlice(allocator, &entry.hash);
        try buf.appendSlice(allocator, "\"");
        if (i < entries.len - 1) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\n");
    }
    try buf.appendSlice(allocator, "  }\n}\n");

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
}

/// Load hash manifest from disk. Returns an empty map if the file doesn't exist.
/// The map's keys are allocated: release them with `freeManifest`, not `deinit`.
pub fn loadManifest(allocator: std.mem.Allocator, io: Io, project_dir: []const u8) std.StringHashMap([64]u8) {
    var map = std.StringHashMap([64]u8).init(allocator);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ project_dir, HASH_FILE_NAME }) catch return map;

    const content = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch return map;
    defer allocator.free(content);

    parseManifest(allocator, content, &map) catch {
        map.clearRetainingCapacity();
    };

    return map;
}

/// Free a map from `loadManifest`: its keys are separate allocations that
/// `std.StringHashMap.deinit` does not know about.
pub fn freeManifest(allocator: std.mem.Allocator, map: *std.StringHashMap([64]u8)) void {
    var keys = map.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    map.deinit();
}

/// Read `"path": "<64 hex>"` pairs out of a manifest body. `saveManifest` writes
/// a flat object, so a pair-at-a-time scan suffices; members whose value is not
/// a 64-char string (`generated_at`, `zmodu_version`, or the `files` object
/// itself) are skipped.
fn parseManifest(allocator: std.mem.Allocator, content: []const u8, map: *std.StringHashMap([64]u8)) !void {
    var pos: usize = 0;
    while (nextJsonString(content, &pos)) |key| {
        var probe = pos;
        skipWhitespace(content, &probe);
        if (probe >= content.len or content[probe] != ':') continue;
        probe += 1;
        skipWhitespace(content, &probe);
        // `"files": {` opens the object holding the pairs — not a pair itself.
        if (probe >= content.len or content[probe] != '"') continue;
        pos = probe;

        const value = nextJsonString(content, &pos) orelse break;
        if (value.len != 64) continue;

        var hash: [64]u8 = undefined;
        @memcpy(&hash, value);
        try map.put(try allocator.dupe(u8, key), hash);
    }
}

/// Read the JSON string starting at `pos` (skipping anything before its opening
/// quote) and advance `pos` past its closing quote. Backslash escapes are kept
/// verbatim — hashes never contain one, and a path that does will simply not
/// match a manifest key.
fn nextJsonString(content: []const u8, pos: *usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, content, pos.*, '"') orelse return null;
    var i = open + 1;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\') {
            i += 1;
            continue;
        }
        if (content[i] == '"') {
            pos.* = i + 1;
            return content[open + 1 .. i];
        }
    }
    return null;
}

fn skipWhitespace(content: []const u8, pos: *usize) void {
    while (pos.* < content.len and std.ascii.isWhitespace(content[pos.*])) pos.* += 1;
}

// ── Tests ──

test "sha256Hex produces consistent 64-char hex" {
    const hash = sha256Hex("hello");
    try std.testing.expectEqual(@as(usize, 64), hash.len);
    const hash2 = sha256Hex("hello");
    try std.testing.expectEqualStrings(&hash, &hash2);
    const hash3 = sha256Hex("world");
    try std.testing.expect(!std.mem.eql(u8, &hash, &hash3));
}

test "sha256Hex different inputs produce different hashes" {
    const a = sha256Hex("aaa");
    const b = sha256Hex("bbb");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "manifest round-trips through saveManifest/loadManifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);

    const body = "pub const x = 1;\n";
    const entries = [_]HashEntry{
        .{ .path = "src/main.zig", .hash = sha256Hex(body) },
        .{ .path = "build.zig.zon", .hash = sha256Hex("zon") },
        .{ .path = ".claude/skills/a/SKILL.md", .hash = sha256Hex("skill") },
    };
    try saveManifest(allocator, io, dir, &entries, "0.26.0");

    var manifest = loadManifest(allocator, io, dir);
    defer freeManifest(allocator, &manifest);

    try std.testing.expectEqual(entries.len, manifest.count());
    for (entries) |entry| {
        try std.testing.expectEqualDeep(entry.hash, manifest.get(entry.path).?);
    }
    try std.testing.expect(manifest.get("generated_at") == null);
    try std.testing.expect(manifest.get("files") == null);
}

test "loadManifest reports nothing for an absent manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);

    var manifest = loadManifest(allocator, io, dir);
    defer freeManifest(allocator, &manifest);
    try std.testing.expectEqual(@as(usize, 0), manifest.count());
}

test "isUnchanged tells our file from an edited one" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);

    const original = "pub const untouched = true;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "model.zig", .data = original });

    const entries = [_]HashEntry{
        .{ .path = "model.zig", .hash = sha256Hex(original) },
        .{ .path = "missing.zig", .hash = sha256Hex("gone") },
    };
    try saveManifest(allocator, io, dir, &entries, "0.26.0");

    var manifest = loadManifest(allocator, io, dir);
    defer freeManifest(allocator, &manifest);

    try std.testing.expect(isUnchanged(allocator, io, dir, "model.zig", &manifest));
    try std.testing.expect(!isUnchanged(allocator, io, dir, "missing.zig", &manifest));
    try std.testing.expect(!isUnchanged(allocator, io, dir, "never-seen.zig", &manifest));

    // Hand edit → no longer ours.
    try tmp.dir.writeFile(io, .{ .sub_path = "model.zig", .data = "// mine\n" ++ original });
    try std.testing.expect(!isUnchanged(allocator, io, dir, "model.zig", &manifest));
}
