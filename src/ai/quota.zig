//! Per-tenant token quota skeleton for multi-tenant AI chat / agent.

const std = @import("std");

pub const TokenQuota = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    /// tenant_id → bucket
    buckets: std.AutoHashMap(i64, Bucket),
    default_limit: usize,

    pub const Bucket = struct {
        limit: usize,
        used: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, default_limit: usize) TokenQuota {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .buckets = std.AutoHashMap(i64, Bucket).init(allocator),
            .default_limit = if (default_limit == 0) 1_000_000 else default_limit,
        };
    }

    pub fn deinit(self: *TokenQuota) void {
        self.buckets.deinit();
        self.* = undefined;
    }

    pub fn setLimit(self: *TokenQuota, tenant_id: i64, limit: usize) !void {
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);
        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = limit, .used = 0 };
        } else {
            gop.value_ptr.limit = limit;
        }
    }

    /// Consume tokens for a tenant. Returns `error.QuotaExceeded` when over limit.
    pub fn tryConsume(self: *TokenQuota, tenant_id: i64, tokens: usize) !void {
        if (tokens == 0) return;
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);

        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = self.default_limit, .used = 0 };
        }
        const b = gop.value_ptr;
        if (b.used + tokens > b.limit) return error.QuotaExceeded;
        b.used += tokens;
    }

    pub fn record(self: *TokenQuota, tenant_id: i64, prompt_tokens: usize, completion_tokens: usize) !void {
        const total = prompt_tokens +% completion_tokens;
        try self.tryConsume(tenant_id, total);
    }

    pub fn used(self: *TokenQuota, tenant_id: i64) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return 0;
        return b.used;
    }

    pub fn remaining(self: *TokenQuota, tenant_id: i64) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return self.default_limit;
        if (b.used >= b.limit) return 0;
        return b.limit - b.used;
    }

    pub fn toPrometheusFormat(self: *TokenQuota, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zigmodu_ai_token_quota_used Tokens consumed per tenant.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_token_quota_used gauge\n", .{});
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            try buf.print(allocator, "zigmodu_ai_token_quota_used{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.used });
            try buf.print(allocator, "zigmodu_ai_token_quota_limit{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.limit });
        }
        return try buf.toOwnedSlice(allocator);
    }
};

test "TokenQuota tryConsume and exceed" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 100);
    defer q.deinit();
    try q.record(7, 40, 40);
    try std.testing.expectEqual(@as(usize, 80), q.used(7));
    try std.testing.expectEqual(@as(usize, 20), q.remaining(7));
    try std.testing.expectError(error.QuotaExceeded, q.tryConsume(7, 30));
    try q.setLimit(7, 200);
    try q.tryConsume(7, 30);
    try std.testing.expectEqual(@as(usize, 110), q.used(7));
}

test "TokenQuota prometheus" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 50);
    defer q.deinit();
    try q.record(1, 10, 5);
    const out = try q.toPrometheusFormat(a);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "tenant_id=\"1\"") != null);
}
