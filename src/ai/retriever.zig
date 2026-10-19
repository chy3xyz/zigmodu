//! Optional retrieval interface for RAG-style context (embedding store is external).

const std = @import("std");

pub const RetrievedChunk = struct {
    id: []const u8 = "",
    text: []const u8,
    score: f64 = 0,
    /// Optional source URI / table key.
    source: []const u8 = "",
};

/// Who a retrieval runs for. The framework forwards the run's identity so an
/// implementation can partition (one collection per tenant, a mandatory
/// metadata filter) instead of hoping a shared index never leaks: retrieval is
/// the one place where a missing filter returns another tenant's documents as
/// *context for the model*, which no downstream check can undo.
pub const Scope = struct {
    tenant_id: ?i64 = null,
    user_id: ?i64 = null,

    pub fn scoped(self: Scope) bool {
        return (self.tenant_id orelse 0) != 0;
    }
};

/// Application-supplied retriever. Framework does not ship a vector DB.
pub const Retriever = struct {
    ptr: *anyopaque,
    retrieveFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, top_k: usize) anyerror![]RetrievedChunk,
    freeFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void = defaultFree,
    /// Scope-aware form. Set this when the index is shared between tenants;
    /// `Agent` prefers it and passes the run's identity. Without it, a run that
    /// **has** an identity falls back to `retrieveFn` and logs one warning per
    /// process — the framework cannot filter an index it does not own, and
    /// silently trusting the unscoped form is how cross-tenant context leaks.
    retrieveScopedFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, scope: Scope, query: []const u8, top_k: usize) anyerror![]RetrievedChunk = null,

    pub fn retrieve(self: Retriever, allocator: std.mem.Allocator, query: []const u8, top_k: usize) ![]RetrievedChunk {
        return self.retrieveFn(self.ptr, allocator, query, top_k);
    }

    /// Scoped retrieval: uses the scope-aware callback when present, otherwise
    /// falls back to the unscoped one (see `retrieveScopedFn`).
    pub fn retrieveScoped(self: Retriever, allocator: std.mem.Allocator, scope: Scope, query: []const u8, top_k: usize) ![]RetrievedChunk {
        if (self.retrieveScopedFn) |f| return f(self.ptr, allocator, scope, query, top_k);
        return self.retrieveFn(self.ptr, allocator, query, top_k);
    }

    pub fn free(self: Retriever, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void {
        self.freeFn(self.ptr, allocator, chunks);
    }

    fn defaultFree(_: *anyopaque, allocator: std.mem.Allocator, chunks: []RetrievedChunk) void {
        for (chunks) |c| freeChunk(allocator, c);
        allocator.free(chunks);
    }
};

/// Release one chunk's owned strings — the same fields in the same order as
/// `Retriever.defaultFree`, minus the slice. `id` / `source` are only ever the
/// shared empty literal when the producer did not copy one, which is why each
/// free is length-guarded.
fn freeChunk(allocator: std.mem.Allocator, c: RetrievedChunk) void {
    if (c.id.len > 0) allocator.free(c.id);
    if (c.text.len > 0) allocator.free(c.text);
    if (c.source.len > 0) allocator.free(c.source);
}

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
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        const source_copy = if (source.len > 0) try self.allocator.dupe(u8, source) else "";
        errdefer if (source_copy.len > 0) self.allocator.free(source_copy);
        try self.docs.append(self.allocator, .{ .id = id_copy, .text = text_copy, .source = source_copy });
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
        errdefer {
            for (scored.items) |c| freeChunk(allocator, c);
            scored.deinit(allocator);
        }

        for (self.docs.items) |d| {
            if (!containsIgnoreCase(d.text, query) and !containsIgnoreCase(d.id, query)) continue;
            try appendChunk(allocator, &scored, d);
            if (scored.items.len >= top_k) break;
        }
        return try scored.toOwnedSlice(allocator);
    }

    /// Copy one matching doc into `scored`, which owns the copies from here.
    ///
    /// The three copies used to be built inside the `append` argument, so a
    /// failed `text` / `source` copy stranded the `id` copy and a failed
    /// `append` stranded all three; an `errdefer` in the loop would instead
    /// stay armed for the rest of the loop and free what `scored` already owns.
    /// The list-level guard above is what releases the entries appended before
    /// a later iteration (or the `toOwnedSlice`) fails.
    fn appendChunk(allocator: std.mem.Allocator, scored: *std.ArrayList(RetrievedChunk), d: Doc) !void {
        const id = try allocator.dupe(u8, d.id);
        errdefer allocator.free(id);
        const text = try allocator.dupe(u8, d.text);
        errdefer allocator.free(text);
        const source = if (d.source.len > 0) try allocator.dupe(u8, d.source) else "";
        errdefer if (source.len > 0) allocator.free(source);
        try scored.append(allocator, .{ .id = id, .text = text, .source = source, .score = 1.0 });
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

// The docs are added with the test allocator before the scan, so the failing
// allocator covers the chunk copies, the growth of the list and the final
// `toOwnedSlice`.
test "KeywordRetriever.retrieve hands back its chunks at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var kr = KeywordRetriever.init(allocator);
    defer kr.deinit();
    try kr.add("doc-1", "Order 42 ships tomorrow", "orders");
    try kr.add("doc-2", "Order 43 is refunded", "");

    const Scan = struct {
        fn run(a: std.mem.Allocator, r: *KeywordRetriever) !void {
            const retriever = r.asRetriever();
            const chunks = try retriever.retrieve(a, "order", 10);
            defer retriever.free(a, chunks);
            try std.testing.expectEqual(@as(usize, 2), chunks.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{&kr});
}

// `add` copies into the retriever's own allocator, which the caller chooses
// (not an arena), so a failure after the `id` copy must hand it back.
test "KeywordRetriever.add hands back its copies at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(a: std.mem.Allocator) !void {
            var kr = KeywordRetriever.init(a);
            defer kr.deinit();
            try kr.add("doc-1", "Order 42 ships tomorrow", "orders");
            try std.testing.expectEqual(@as(usize, 1), kr.docs.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
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

test "Retriever.retrieveScoped prefers the scoped callback and passes the scope" {
    const A = struct {
        var saw_tenant: ?i64 = null;
        fn unscoped(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize) anyerror![]RetrievedChunk {
            return error.UnscopedCalled;
        }
        fn scoped(_: *anyopaque, allocator: std.mem.Allocator, scope: Scope, _: []const u8, _: usize) anyerror![]RetrievedChunk {
            saw_tenant = scope.tenant_id;
            const out = try allocator.alloc(RetrievedChunk, 1);
            out[0] = .{ .text = try allocator.dupe(u8, "doc") };
            return out;
        }
    };
    var instance: A = .{};
    const r = Retriever{
        .ptr = &instance,
        .retrieveFn = A.unscoped,
        .retrieveScopedFn = A.scoped,
    };
    const chunks = try r.retrieveScoped(std.testing.allocator, .{ .tenant_id = 7, .user_id = 42 }, "q", 1);
    defer r.free(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(?i64, 7), A.saw_tenant);
}

test "Retriever.retrieveScoped falls back to the unscoped form when no scoped callback exists" {
    const A = struct {
        fn unscoped(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: usize) anyerror![]RetrievedChunk {
            const out = try allocator.alloc(RetrievedChunk, 1);
            out[0] = .{ .text = try allocator.dupe(u8, "fallback") };
            return out;
        }
    };
    var instance: A = .{};
    const r = Retriever{ .ptr = &instance, .retrieveFn = A.unscoped };
    const chunks = try r.retrieveScoped(std.testing.allocator, .{ .tenant_id = 7 }, "q", 1);
    defer r.free(std.testing.allocator, chunks);
    try std.testing.expectEqualStrings("fallback", chunks[0].text);
}

test "Scope.scoped treats the zero default as unscoped" {
    try std.testing.expect(!(Scope{}).scoped());
    try std.testing.expect(!(Scope{ .tenant_id = 0 }).scoped());
    try std.testing.expect((Scope{ .tenant_id = 1 }).scoped());
}
