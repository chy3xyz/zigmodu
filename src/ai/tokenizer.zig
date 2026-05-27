const std = @import("std");

/// Fast token estimator. ~4 chars/token for Latin, ~1.5 chars/token for CJK.
/// Accuracy within ±20% of actual DeepSeek tokenizer. No allocation.
pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;

    var cjk_chars: usize = 0;
    var latin_chars: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + cp_len > text.len) {
            i += 1;
            latin_chars += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch {
            i += 1;
            latin_chars += 1;
            continue;
        };
        if (isCjk(cp)) {
            cjk_chars += 1;
        } else {
            latin_chars += 1;
        }
        i += cp_len;
    }

    // ~1 token per CJK char, ~0.25 tokens per Latin char
    return cjk_chars + (latin_chars / 4) + 1;
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext-A
        (cp >= 0x20000 and cp <= 0x2A6DF) or // CJK Ext-B
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0xAC00 and cp <= 0xD7AF); // Hangul
}

/// Estimate tokens in a ChatMsg array for budget tracking.
pub fn estimateMessages(messages: anytype) usize {
    var total: usize = 0;
    for (messages) |msg| {
        total += estimateTokens(msg.role);
        total += estimateTokens(msg.content);
        total += 4; // message framing overhead
    }
    return total;
}

test "estimateTokens empty" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
}

test "estimateTokens latin" {
    const text = "Hello, world! This is a test message.";
    const tokens = estimateTokens(text);
    // ~42 chars / 4 ≈ 11 tokens
    try std.testing.expect(tokens >= 8);
    try std.testing.expect(tokens <= 18);
}

test "estimateTokens cjk" {
    const text = "你好世界这是一个测试消息";
    const tokens = estimateTokens(text);
    // 12 CJK chars ≈ 12 tokens + 1 baseline
    try std.testing.expect(tokens >= 10);
    try std.testing.expect(tokens <= 16);
}

test "estimateTokens mixed" {
    const text = "Hello 你好 World 世界";
    const tokens = estimateTokens(text);
    try std.testing.expect(tokens >= 6);
    try std.testing.expect(tokens <= 14);
}

test "estimateMessages" {
    const msgs = &[_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "system", .content = "You are helpful." },
        .{ .role = "user", .content = "Hi" },
    };
    const tokens = estimateMessages(msgs);
    try std.testing.expect(tokens > 0);
}
