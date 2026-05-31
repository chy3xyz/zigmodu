//! Path traversal protection — sanitize user-supplied file paths.
//!
//! Rejects paths containing "..", null bytes, or absolute paths.
//! Returns sanitized basename-only path for safe file operations.

const std = @import("std");

/// Validate and sanitize a user-supplied path for safe file operations.
/// Returns the sanitized path (may point into input or be the original).
/// Rejects paths containing "..", null bytes, leading slashes, or backslashes.
pub fn sanitizePath(path: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidPath;

    // Reject null bytes (path truncation attack)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    // Reject path traversal sequences
    if (std.mem.containsAtLeast(u8, path, 1, "..")) return error.InvalidPath;

    // Reject backslash path separators (Windows-style traversal)
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;

    // Reject absolute paths
    if (path[0] == '/') return error.InvalidPath;

    // Strip leading ./
    var sanitized = path;
    while (sanitized.len > 2 and sanitized[0] == '.' and sanitized[1] == '/') {
        sanitized = sanitized[2..];
    }

    return sanitized;
}

test "rejects path traversal" {
    try std.testing.expectError(error.InvalidPath, sanitizePath("../etc/passwd"));
    try std.testing.expectError(error.InvalidPath, sanitizePath("foo/../../bar"));
    try std.testing.expectError(error.InvalidPath, sanitizePath(".."));
}

test "rejects null bytes" {
    try std.testing.expectError(error.InvalidPath, sanitizePath("foo\x00bar"));
}

test "rejects absolute paths" {
    try std.testing.expectError(error.InvalidPath, sanitizePath("/etc/passwd"));
}

test "rejects backslash" {
    try std.testing.expectError(error.InvalidPath, sanitizePath("foo\\bar"));
}

test "accepts safe paths" {
    try std.testing.expectEqualStrings("foo/bar.txt", try sanitizePath("foo/bar.txt"));
    try std.testing.expectEqualStrings("file.txt", try sanitizePath("./file.txt"));
    try std.testing.expectEqualStrings("subdir/file.txt", try sanitizePath("subdir/file.txt"));
}

test "rejects empty path" {
    try std.testing.expectError(error.InvalidPath, sanitizePath(""));
}
