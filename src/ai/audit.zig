//! Ring-buffer audit trail for agent tool calls and run lifecycle.

const std = @import("std");
const Time = @import("../core/Time.zig");

pub const AuditKind = enum {
    run_start,
    tool_ok,
    tool_err,
    tool_denied,
    run_finish,
    run_max_steps,
};

pub const AuditEvent = struct {
    kind: AuditKind,
    tool_name: []const u8 = "",
    detail: []const u8 = "",
    tenant_id: i64 = 0,
    user_id: i64 = 0,
    at_ms: i64 = 0,
};

/// Fixed-capacity ring of audit events (oldest overwritten).
pub const AgentAuditLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    events: []AuditEvent,
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !AgentAuditLog {
        const cap = if (capacity == 0) 64 else capacity;
        const events = try allocator.alloc(AuditEvent, cap);
        for (events) |*e| e.* = .{ .kind = .run_start };
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .events = events,
        };
    }

    pub fn deinit(self: *AgentAuditLog) void {
        for (self.events) |e| {
            if (e.tool_name.len > 0) self.allocator.free(e.tool_name);
            if (e.detail.len > 0) self.allocator.free(e.detail);
        }
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn record(
        self: *AgentAuditLog,
        kind: AuditKind,
        tool_name: []const u8,
        detail: []const u8,
        tenant_id: i64,
        user_id: i64,
    ) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        const slot = &self.events[self.next];
        if (slot.tool_name.len > 0) self.allocator.free(slot.tool_name);
        if (slot.detail.len > 0) self.allocator.free(slot.detail);

        slot.* = .{
            .kind = kind,
            .tool_name = self.allocator.dupe(u8, tool_name) catch "",
            .detail = self.allocator.dupe(u8, detail) catch "",
            .tenant_id = tenant_id,
            .user_id = user_id,
            .at_ms = Time.monotonicNowMilliseconds(),
        };
        self.next = (self.next + 1) % self.events.len;
        if (self.count < self.events.len) self.count += 1;
    }

    /// Newest-first copy. Caller frees tool_name/detail and the slice.
    pub fn snapshot(self: *AgentAuditLog, allocator: std.mem.Allocator) ![]AuditEvent {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        var out = try allocator.alloc(AuditEvent, self.count);
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.next + self.events.len - 1 - i) % self.events.len;
            const e = self.events[idx];
            out[i] = .{
                .kind = e.kind,
                .tool_name = try allocator.dupe(u8, e.tool_name),
                .detail = try allocator.dupe(u8, e.detail),
                .tenant_id = e.tenant_id,
                .user_id = e.user_id,
                .at_ms = e.at_ms,
            };
        }
        return out;
    }

    pub fn freeSnapshot(allocator: std.mem.Allocator, events: []AuditEvent) void {
        for (events) |e| {
            if (e.tool_name.len > 0) allocator.free(e.tool_name);
            if (e.detail.len > 0) allocator.free(e.detail);
        }
        allocator.free(events);
    }
};

test "AgentAuditLog record and snapshot" {
    const a = std.testing.allocator;
    var log = try AgentAuditLog.init(a, std.testing.io, 4);
    defer log.deinit();

    log.record(.tool_ok, "ping", "pong", 1, 2);
    log.record(.tool_err, "x", "ToolTimeout", 1, 2);

    const snap = try log.snapshot(a);
    defer AgentAuditLog.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expect(snap[0].kind == .tool_err);
    try std.testing.expectEqualStrings("x", snap[0].tool_name);
}
