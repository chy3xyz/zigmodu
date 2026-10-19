//! RAG building blocks: a UTF-8-safe chunker, an in-memory vector index that
//! enforces tenant scope, and a `Retriever` over it.
//!
//! Embeddings are supplied by the application (`EmbedFn`): an embedding model
//! is a provider-specific HTTP call and the framework does not invent vectors.
//! What the framework *does* own is the part that leaks when left to callers —
//! chunk boundaries that split a UTF-8 sequence, and a search that returns
//! another tenant's documents as context for the model.

const std = @import("std");
const retriever_mod = @import("retriever.zig");

pub const Retriever = retriever_mod.Retriever;
pub const Scope = retriever_mod.Scope;
pub const RetrievedChunk = retriever_mod.RetrievedChunk;

pub const ChunkOptions = struct {
    /// Hard cap on one chunk, in bytes.
    max_chars: usize = 800,
    /// How many bytes consecutive chunks share (so a sentence cut by a
    /// boundary still appears whole in one of them).
    overlap_chars: usize = 80,
    /// Prefer a whitespace/newline break within this many bytes of the cap over
    /// cutting at the byte boundary.
    break_window: usize = 160,
};

pub const Chunk = struct {
    /// Borrowed from the input text (the caller owns the buffer).
    text: []const u8,
    /// Byte offset of `text` in the input, for citations.
    start: usize,
};

/// Split `text` into overlapping chunks, never through a UTF-8 sequence.
/// Chunks are slices of `text`; the returned slice is allocated with
/// `allocator`. Empty/whitespace-only chunks are skipped, and the last chunk
/// always reaches the end of the input.
pub fn chunkText(allocator: std.mem.Allocator, text: []const u8, opts: ChunkOptions) ![]Chunk {
    if (opts.max_chars == 0) return error.InvalidChunkOptions;
    if (opts.overlap_chars >= opts.max_chars) return error.InvalidChunkOptions;

    var out = std.ArrayList(Chunk).empty;
    errdefer out.deinit(allocator);

    if (text.len <= opts.max_chars) {
        if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
            try out.append(allocator, .{ .text = text, .start = 0 });
        }
        return try out.toOwnedSlice(allocator);
    }

    var pos: usize = 0;
    while (pos < text.len) {
        var end = @min(pos + opts.max_chars, text.len);
        if (end < text.len) end = preferredBreak(text, pos, end, opts.break_window, opts.overlap_chars);
        // Never cut through a multi-byte character. `end == text.len` is a
        // complete cut (there is no byte at that index to inspect).
        while (end > pos and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
        if (end == pos) end = @min(pos + 1, text.len);

        const raw = text[pos..end];
        const lead = std.mem.trimStart(u8, raw, " \t\r\n").len;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            try out.append(allocator, .{ .text = trimmed, .start = pos + (raw.len - lead) });
        }
        if (end >= text.len) break;
        // Overlap, but always make progress (overlap < max_chars is enforced,
        // yet a break may have produced a very short chunk). The next start
        // can land inside a multi-byte character — move it forward to the
        // boundary, or the next chunk begins with continuation bytes.
        const next = if (end > opts.overlap_chars) end - opts.overlap_chars else end;
        var next_pos = if (next > pos) next else end;
        while (next_pos < text.len and (text[next_pos] & 0xC0) == 0x80) next_pos += 1;
        pos = if (next_pos < end) next_pos else end;
    }
    return try out.toOwnedSlice(allocator);
}

/// The split point at or before `end`: a whitespace boundary inside
/// `break_window`, else `end` itself. Never returns at or before `pos`.
fn preferredBreak(text: []const u8, pos: usize, end: usize, break_window: usize, overlap: usize) usize {
    const window_start = if (end > break_window) end - break_window else 0;
    const floor = @max(pos + 1, @max(window_start, pos + overlap + 1));
    var i = end;
    while (i > floor) : (i -= 1) {
        switch (text[i - 1]) {
            ' ', '\t', '\n', '\r' => return i - 1,
            else => {},
        }
    }
    return end;
}

/// Embed one text. `ctx` is the implementation's own state.
pub const EmbedFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror![]f32;

/// In-memory vector index.
///
/// Every entry carries the tenant it was stored for, and `search` only returns
/// entries whose tenant **equals** the requested one. That equality is the
/// whole isolation mechanism: an unscoped search (`tenant_id` null/0) sees only
/// entries stored without a tenant, never "all of them" — the failure mode the
/// approval queue had before it was fixed. `user_id` is recorded for callers
/// that filter further; the index does not split tenants by user.
pub const VectorIndex = struct {
    allocator: std.mem.Allocator,
    dims: usize,
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        tenant_id: i64,
        user_id: i64,
        id: []const u8,
        text: []const u8,
        source: []const u8,
        vector: []f32,
    };

    pub fn init(allocator: std.mem.Allocator, dims: usize) !VectorIndex {
        if (dims == 0) return error.InvalidDimensions;
        return .{ .allocator = allocator, .dims = dims, .entries = .empty };
    }

    pub fn deinit(self: *VectorIndex) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.id);
            self.allocator.free(e.text);
            if (e.source.len > 0) self.allocator.free(e.source);
            self.allocator.free(e.vector);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const VectorIndex) usize {
        return self.entries.items.len;
    }

    /// Copy one document (and its vector) into the index, under `scope`.
    pub fn add(
        self: *VectorIndex,
        scope: Scope,
        id: []const u8,
        text: []const u8,
        source: []const u8,
        vector: []const f32,
    ) !void {
        if (vector.len != self.dims) return error.DimensionMismatch;
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);
        const vec_copy = try self.allocator.dupe(f32, vector);
        errdefer self.allocator.free(vec_copy);
        try self.entries.append(self.allocator, .{
            .tenant_id = scope.tenant_id orelse 0,
            .user_id = scope.user_id orelse 0,
            .id = id_copy,
            .text = text_copy,
            .source = source_copy,
            .vector = vec_copy,
        });
    }

    /// Top-`top_k` chunks by cosine similarity, restricted to `scope`'s tenant.
    /// Returned strings are copies — release with `Retriever.free`.
    pub fn search(
        self: *const VectorIndex,
        allocator: std.mem.Allocator,
        scope: Scope,
        query: []const f32,
        top_k: usize,
    ) ![]RetrievedChunk {
        if (query.len != self.dims) return error.DimensionMismatch;
        const want_tenant = scope.tenant_id orelse 0;

        const Scored = struct { score: f64, idx: usize };
        var scored = std.ArrayList(Scored).empty;
        defer scored.deinit(allocator);
        for (self.entries.items, 0..) |e, i| {
            if (e.tenant_id != want_tenant) continue;
            try scored.append(allocator, .{ .score = cosine(query, e.vector), .idx = i });
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn gt(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score;
            }
        }.gt);

        const n = @min(top_k, scored.items.len);
        var out = try allocator.alloc(RetrievedChunk, n);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |c| freeChunk(allocator, c);
            allocator.free(out);
        }
        for (scored.items[0..n]) |s| {
            const e = self.entries.items[s.idx];
            out[built] = .{
                .id = try allocator.dupe(u8, e.id),
                .text = try allocator.dupe(u8, e.text),
                .source = try allocator.dupe(u8, e.source),
                .score = s.score,
            };
            built += 1;
        }
        return out;
    }
};

fn cosine(a: []const f32, b: []const f32) f64 {
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * @as(f64, y);
        na += @as(f64, x) * @as(f64, x);
        nb += @as(f64, y) * @as(f64, y);
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

fn freeChunk(allocator: std.mem.Allocator, c: RetrievedChunk) void {
    if (c.id.len > 0) allocator.free(c.id);
    if (c.text.len > 0) allocator.free(c.text);
    if (c.source.len > 0) allocator.free(c.source);
}

/// A `Retriever` over a `VectorIndex`: embeds the query with `embed_fn`, then
/// searches under the run's scope. Both the scoped and the legacy callback are
/// wired, so `Agent` prefers the scoped one whenever the run has an identity.
pub const IndexRetriever = struct {
    index: *VectorIndex,
    embed_ctx: *anyopaque,
    embed_fn: EmbedFn,

    pub fn retriever(self: *IndexRetriever) Retriever {
        return .{
            .ptr = self,
            .retrieveFn = retrieveUnscoped,
            .retrieveScopedFn = retrieveScoped,
        };
    }

    fn retrieveScoped(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        scope: Scope,
        query: []const u8,
        top_k: usize,
    ) anyerror![]RetrievedChunk {
        const self: *IndexRetriever = @ptrCast(@alignCast(ptr));
        const vec = try self.embed_fn(self.embed_ctx, allocator, query);
        defer allocator.free(vec);
        return self.index.search(allocator, scope, vec, top_k);
    }

    fn retrieveUnscoped(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
        top_k: usize,
    ) anyerror![]RetrievedChunk {
        return retrieveScoped(ptr, allocator, .{}, query, top_k);
    }
};

// ---- tests ----------------------------------------------------------------

test "chunkText keeps UTF-8 intact and always reaches the end" {
    const allocator = std.testing.allocator;

    // Long CJK text: no spaces to break on, so the byte cap decides.
    const unit = "数据治理是平台工程的核心能力，检索增强需要保证切片不破坏字符边界。";
    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);
    for (0..8) |_| try text_buf.appendSlice(allocator, unit);
    const cjk = text_buf.items;
    const chunks = try chunkText(allocator, cjk, .{ .max_chars = 50, .overlap_chars = 10, .break_window = 20 });
    defer allocator.free(chunks);
    try std.testing.expect(chunks.len > 1);
    for (chunks) |c| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(c.text));
        try std.testing.expect(c.start < cjk.len);
        // The chunk really is the slice its start advertises.
        try std.testing.expectEqualStrings(c.text, std.mem.trim(u8, cjk[c.start .. c.start + c.text.len], " \t\r\n"));
    }
    // The last chunk covers the tail.
    const last = chunks[chunks.len - 1];
    try std.testing.expect(last.start + last.text.len <= cjk.len);
    try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, cjk[last.start + last.text.len ..], " \t\r\n").len);
}

test "chunkText prefers whitespace and overlaps neighbours" {
    const allocator = std.testing.allocator;
    const text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron";
    const chunks = try chunkText(allocator, text, .{ .max_chars = 24, .overlap_chars = 8, .break_window = 12 });
    defer allocator.free(chunks);
    try std.testing.expect(chunks.len >= 2);
    // Consecutive chunks overlap: the next one starts before the previous ends.
    for (chunks[0 .. chunks.len - 1], chunks[1..]) |a, b| {
        try std.testing.expect(b.start < a.start + a.text.len);
        try std.testing.expect(b.start > a.start);
    }
    // No chunk starts or ends with whitespace.
    for (chunks) |c| {
        try std.testing.expect(!std.ascii.isWhitespace(c.text[0]));
        try std.testing.expect(!std.ascii.isWhitespace(c.text[c.text.len - 1]));
    }
}

test "chunkText: short and whitespace-only inputs" {
    const allocator = std.testing.allocator;
    const one = try chunkText(allocator, "hello world", .{});
    defer allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("hello world", one[0].text);

    const none = try chunkText(allocator, "   \n\t ", .{});
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    try std.testing.expectError(error.InvalidChunkOptions, chunkText(allocator, "x", .{ .max_chars = 10, .overlap_chars = 10 }));
}

test "VectorIndex isolates tenants and ranks by similarity" {
    const allocator = std.testing.allocator;
    var index = try VectorIndex.init(allocator, 2);
    defer index.deinit();

    try index.add(.{ .tenant_id = 7 }, "a", "tenant seven, close", "s1", &.{ 1.0, 0.0 });
    try index.add(.{ .tenant_id = 7 }, "b", "tenant seven, far", "s2", &.{ 0.0, 1.0 });
    try index.add(.{ .tenant_id = 9 }, "c", "tenant nine, closest", "s3", &.{ 1.0, 0.0 });
    // A global document is only visible to an unscoped search.
    try index.add(.{}, "g", "global", "s4", &.{ 1.0, 0.0 });

    const seven = try index.search(allocator, .{ .tenant_id = 7 }, &.{ 1.0, 0.0 }, 10);
    defer {
        for (seven) |c| freeChunk(allocator, c);
        allocator.free(seven);
    }
    try std.testing.expectEqual(@as(usize, 2), seven.len);
    try std.testing.expectEqualStrings("a", seven[0].id); // exact match ranks first
    try std.testing.expectEqualStrings("b", seven[1].id);
    for (seven) |c| try std.testing.expect(c.id.len == 1 and (c.id[0] == 'a' or c.id[0] == 'b'));

    // Unscoped sees only the global row — never "every tenant".
    const global = try index.search(allocator, .{}, &.{ 1.0, 0.0 }, 10);
    defer {
        for (global) |c| freeChunk(allocator, c);
        allocator.free(global);
    }
    try std.testing.expectEqual(@as(usize, 1), global.len);
    try std.testing.expectEqualStrings("g", global[0].id);

    // Tenant 9 sees exactly one document (its own), not tenant 7's.
    const nine = try index.search(allocator, .{ .tenant_id = 9 }, &.{ 1.0, 0.0 }, 10);
    defer {
        for (nine) |c| freeChunk(allocator, c);
        allocator.free(nine);
    }
    try std.testing.expectEqual(@as(usize, 1), nine.len);
    try std.testing.expectEqualStrings("c", nine[0].id);

    try std.testing.expectError(error.DimensionMismatch, index.add(.{ .tenant_id = 7 }, "x", "x", "", &.{1.0}));
    try std.testing.expectError(error.DimensionMismatch, index.search(allocator, .{ .tenant_id = 7 }, &.{1.0}, 1));
}

test "IndexRetriever embeds the query and keeps the run's scope" {
    const allocator = std.testing.allocator;
    var index = try VectorIndex.init(allocator, 3);
    defer index.deinit();
    try index.add(.{ .tenant_id = 7 }, "d7", "seven", "s7", &.{ 1.0, 0.0, 0.0 });
    try index.add(.{ .tenant_id = 9 }, "d9", "nine", "s9", &.{ 1.0, 0.0, 0.0 });

    const Ctx = struct {
        fn embed(_: *anyopaque, a: std.mem.Allocator, _: []const u8) anyerror![]f32 {
            return a.dupe(f32, &.{ 1.0, 0.0, 0.0 });
        }
    };
    var impl = IndexRetriever{ .index = &index, .embed_ctx = undefined, .embed_fn = Ctx.embed };
    const r = impl.retriever();

    const scoped = try r.retrieveScoped(allocator, .{ .tenant_id = 9 }, "q", 5);
    defer r.free(allocator, scoped);
    try std.testing.expectEqual(@as(usize, 1), scoped.len);
    try std.testing.expectEqualStrings("d9", scoped[0].id);

    // The legacy entry point is the unscoped one: no global rows stored here,
    // so it answers nothing rather than crossing tenants.
    const unscoped = try r.retrieve(allocator, "q", 5);
    defer r.free(allocator, unscoped);
    try std.testing.expectEqual(@as(usize, 0), unscoped.len);
}
