const std = @import("std");

/// Validate that JSON does not exceed max_depth nesting before parsing.
/// Prevents stack-overflow DoS from deeply nested JSON payloads.
pub fn validateDepth(json: []const u8, max_depth: usize) !void {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    for (json) |ch| {
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                continue;
            }
            if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.JsonDepthExceeded;
            },
            '}', ']' => {
                if (depth == 0) return error.JsonDepthExceeded;
                depth -= 1;
            },
            else => {},
        }
    }
}

test "validateDepth shallow" {
    try validateDepth("{\"a\":1}", 10);
}

test "validateDepth exceeds" {
    try std.testing.expectError(error.JsonDepthExceeded, validateDepth("[[[[]]]]", 2));
}

test "validateDepth ignores strings" {
    try validateDepth("{\"key\":\"[[[[\"}", 1);
}
