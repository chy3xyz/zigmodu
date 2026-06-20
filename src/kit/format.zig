const std = @import("std");

/// Format file size in human-readable form (e.g. "1.5 MB").
pub fn formatFileSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }
    if (unit_idx == 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[unit_idx] });
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ size, units[unit_idx] });
}

/// Format number with comma separators (e.g. "1,234,567").
pub fn formatNumber(allocator: std.mem.Allocator, n: u64) ![]const u8 {
    const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
    if (s.len <= 3) return s;
    const commas = (s.len - 1) / 3;
    const result = try allocator.alloc(u8, s.len + commas);
    var ri: usize = result.len;
    var si: usize = s.len;
    var count: usize = 0;
    while (si > 0) {
        si -= 1;
        ri -= 1;
        result[ri] = s[si];
        count += 1;
        if (count == 3 and si > 0) {
            ri -= 1;
            result[ri] = ',';
            count = 0;
        }
    }
    allocator.free(s);
    return result;
}

/// Format duration in human-readable form (e.g. "2h 3m 15s").
pub fn formatDuration(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    const h = seconds / 3600;
    const m = (seconds % 3600) / 60;
    const s = seconds % 60;
    if (h > 0) return std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ h, m, s });
    if (m > 0) return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ m, s });
    return std.fmt.allocPrint(allocator, "{d}s", .{s});
}

test "formatFileSize" {
    const a = std.testing.allocator;
    const r = try formatFileSize(a, 1536);
    defer a.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "1.5 KB"));
}

test "formatNumber" {
    const a = std.testing.allocator;
    const r = try formatNumber(a, 1234567);
    defer a.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "1,234,567"));
}

test "formatDuration" {
    const a = std.testing.allocator;
    const r = try formatDuration(a, 3723);
    defer a.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "1h 2m 3s"));
}
