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

/// What a record's text fields become when their copies cannot be allocated.
/// Deliberately loud: `record` must never leave behind an entry that reads like a
/// genuine call by an unnamed tool. Never freed — see `owned` below.
const unallocated_text = "(unallocated)";

/// Fixed-capacity ring of audit events (oldest overwritten).
pub const AgentAuditLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    events: []AuditEvent,
    /// Per slot: whether `events[i].tool_name`/`.detail` are heap copies this log
    /// owns. A slot that fell back to `unallocated_text` is not, and freeing those
    /// statics in `deinit` would be a bad free.
    owned: []bool,
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !AgentAuditLog {
        const cap = if (capacity == 0) 64 else capacity;
        const events = try allocator.alloc(AuditEvent, cap);
        errdefer allocator.free(events);
        for (events) |*e| e.* = .{ .kind = .run_start };
        const owned = try allocator.alloc(bool, cap);
        for (owned) |*o| o.* = false;
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .events = events,
            .owned = owned,
        };
    }

    pub fn deinit(self: *AgentAuditLog) void {
        for (self.events, self.owned) |e, owned| {
            if (!owned) continue;
            self.allocator.free(e.tool_name);
            self.allocator.free(e.detail);
        }
        self.allocator.free(self.events);
        self.allocator.free(self.owned);
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
        // Uncancelable: an audit entry is the record that a tool was refused
        // (`.tool_denied` from `agent.zig:490,517`) or ran, and `record` returns
        // `void` — a canceled lock wait swallowed here drops it with nobody told.
        // The critical section is one slot write.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Both copies are made *before* the slot is touched, so a failed
        // allocation cannot leave a half-written entry behind. If either fails the
        // event is still written, with both text fields replaced by the static
        // `unallocated_text`: dropping a security event is worse than recording
        // one that says its copy was lost, and the old `dupe catch ""` wrote a
        // record that read as a real call by an unnamed tool.
        const name_copy: ?[]u8 = self.allocator.dupe(u8, tool_name) catch null;
        const detail_copy: ?[]u8 = self.allocator.dupe(u8, detail) catch null;
        const complete = name_copy != null and detail_copy != null;
        if (!complete) {
            if (name_copy) |n| self.allocator.free(n);
            if (detail_copy) |d| self.allocator.free(d);
        }

        const slot = &self.events[self.next];
        if (self.owned[self.next]) {
            self.allocator.free(slot.tool_name);
            self.allocator.free(slot.detail);
        }

        slot.* = .{
            .kind = kind,
            .tool_name = if (complete) name_copy.? else unallocated_text,
            .detail = if (complete) detail_copy.? else unallocated_text,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .at_ms = Time.monotonicNowMilliseconds(),
        };
        self.owned[self.next] = complete;
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

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// This is a security path: the entries it loses include the `.tool_denied` a
// guard or an approval hook just refused (`agent.zig:490,517`). `record` returns
// `void`, so a canceled lock wait swallowed as `catch return` drops the entry with
// nobody told; the critical section is one slot write, so it waits
// (`lockUncancelable`).
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return;` the first
// assertion below fails — `expected 1, found 0`, the cancelled `.tool_denied`
// never reached the ring.
test "canceled lock wait does not drop an audit entry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var log = try AgentAuditLog.init(a, io, 4);
    defer log.deinit();

    const RecordRead = struct {
        fn read(l: *AgentAuditLog) void {
            l.record(.tool_denied, "dangerous_tool", "denied_execute_class", 1, 2);
        }
    };
    try readUnderCanceledLockWait(AgentAuditLog, &log, &log.mutex, io, RecordRead.read);

    const snap = try log.snapshot(a);
    defer AgentAuditLog.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expect(snap[0].kind == .tool_denied);
    try std.testing.expectEqualStrings("dangerous_tool", snap[0].tool_name);
    try std.testing.expectEqualStrings("denied_execute_class", snap[0].detail);
}

// A failed copy must not leave an entry that *reads* real: with `dupe catch ""`
// the ring stored a `.tool_denied` with a blank tool name — an audit record that
// looks like a genuine call by an unnamed tool. The record is still written (a
// dropped security entry is worse), but its text fields say so out loud, and the
// placeholder is never freed (per-slot ownership).
//
// Red evidence: with `dupe catch ""` the `expectEqualStrings` below fails —
// `expected "(unallocated)", found ""`. The literal is deliberate: the test pins
// the exact text `record` writes.
test "an audit entry whose copies cannot be allocated is visibly not real" {
    const a = std.testing.allocator;

    var fa = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var log = try AgentAuditLog.init(a, std.testing.io, 4);
    defer log.deinit();
    // Only the record's two copies go through the failing allocator; the ring
    // itself and the snapshot below keep the real one.
    log.allocator = fa.allocator();

    log.record(.tool_denied, "dangerous_tool", "denied", 1, 2);
    log.record(.tool_ok, "ping", "pong", 1, 2); // same allocator: also placeholder

    const snap = try log.snapshot(a);
    defer AgentAuditLog.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expect(snap[0].kind == .tool_ok);
    try std.testing.expectEqualStrings("(unallocated)", snap[0].tool_name);
    try std.testing.expectEqualStrings("(unallocated)", snap[0].detail);
    try std.testing.expectEqualStrings("(unallocated)", snap[1].tool_name);
}
