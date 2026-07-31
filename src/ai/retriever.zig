//! Optional retrieval interface for RAG-style context (embedding store is external).

const std = @import("std");

pub const RetrievedChunk = struct {
    id: []const u8 = "",
    text: []const u8,
    score: f64 = 0,
    /// Optional source URI / table key.
    source: []const u8 = "",
};

/// Application-supplied retriever. Framework does not ship a vector DB.
pub const Retriever = struct {
    ptr: *anyopaque,
    retrieveFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, top_k: usize) anyerror![]RetrievedChunk,
    freeFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void = defaultFree,

    pub fn retrieve(self: Retriever, allocator: std.mem.Allocator, query: []const u8, top_k: usize) ![]RetrievedChunk {
        return self.retrieveFn(self.ptr, allocator, query, top_k);
    }

    pub fn free(self: Retriever, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void {
        self.freeFn(self.ptr, allocator, chunks);
    }

    fn defaultFree(_: *anyopaque, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void {
        for (chunks) |c| {
            if (c.id.len > 0) allocator.free(c.id);
            if (c.text.len > 0) allocator.free(c.text);
            if (c.source.len > 0) allocator.free(c.source);
        }
        allocator.free(chunks);
    }
};

/// Tiny keyword retriever for tests / demos (not a vector index).
pub const KeywordRetriever = struct {
    allocator: std.mem.Allocator,
    docs: std.ArrayList(Doc),

    pub const Doc = struct {
        id: []const u8,
        text: []const u8,
        source: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator) KeywordRetriever {
        return .{ .allocator = allocator, .docs = .empty };
    }

    pub fn deinit(self: *KeywordRetriever) void {
        for (self.docs.items) |d| {
            self.allocator.free(d.id);
            self.allocator.free(d.text);
            if (d.source.len > 0) self.allocator.free(d.source);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn add(self: *KeywordRetriever, id: []const u8, text: []const u8, source: []const u8) !void {
        try self.docs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .text = try self.allocator.dupe(u8, text),
            .source = if (source.len > 0) try self.allocator.dupe(u8, source) else "",
        });
    }

    pub fn asRetriever(self: *KeywordRetriever) Retriever {
        return .{
            .ptr = self,
            .retrieveFn = retrieveImpl,
            .freeFn = Retriever.defaultFree,
        };
    }

    fn retrieveImpl(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, top_k: usize) anyerror![]RetrievedChunk {
        const self: *KeywordRetriever = @ptrCast(@alignCast(ptr));
        var scored: std.ArrayList(RetrievedChunk) = .empty;
        defer scored.deinit(allocator);

        for (self.docs.items) |d| {
            if (!containsIgnoreCase(d.text, query) and !containsIgnoreCase(d.id, query)) continue;
            try scored.append(allocator, .{
                .id = try allocator.dupe(u8, d.id),
                .text = try allocator.dupe(u8, d.text),
                .source = if (d.source.len > 0) try allocator.dupe(u8, d.source) else "",
                .score = 1.0,
            });
            if (scored.items.len >= top_k) break;
        }
        return try scored.toOwnedSlice(allocator);
    }

    /// Format chunks into a system-prompt block. Caller frees.
    pub fn formatContext(allocator: std.mem.Allocator, chunks: []const RetrievedChunk) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "Retrieved context:\n");
        for (chunks) |c| {
            try buf.appendSlice(allocator, "- ");
            try buf.appendSlice(allocator, c.text);
            try buf.appendSlice(allocator, "\n");
        }
        return try buf.toOwnedSlice(allocator);
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "KeywordRetriever retrieve and format" {
    const a = std.testing.allocator;
    var kr = KeywordRetriever.init(a);
    defer kr.deinit();
    try kr.add("1", "Order 42 ships tomorrow", "orders");
    try kr.add("2", "Refund policy is 14 days", "policy");

    const r = kr.asRetriever();
    const chunks = try r.retrieve(a, "order", 5);
    defer r.free(a, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);

    const ctx = try KeywordRetriever.formatContext(a, chunks);
    defer a.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Order 42") != null);
}
