//! Cooperative runtime control for agent runs.
//!
//! Zig fibers are not preemptible, so cancel/pause are cooperative: the agent
//! checks the handle between steps. requestCancel stops at the next step
//! boundary; setPaused blocks the agent thread until unpaused.
const std = @import("std");

pub const AgentHandle = struct {
    cancel_requested: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    steps_done: std.atomic.Value(usize) = .init(0),

    pub fn init() AgentHandle {
        return .{};
    }

    pub fn requestCancel(self: *AgentHandle) void {
        self.cancel_requested.store(true, .monotonic);
    }

    pub fn isCanceled(self: *const AgentHandle) bool {
        return self.cancel_requested.load(.monotonic);
    }

    pub fn setPaused(self: *AgentHandle, paused: bool) void {
        self.paused.store(paused, .monotonic);
    }

    pub fn isPaused(self: *const AgentHandle) bool {
        return self.paused.load(.monotonic);
    }

    pub fn stepsDone(self: *const AgentHandle) usize {
        return self.steps_done.load(.monotonic);
    }

    pub fn recordStep(self: *AgentHandle) void {
        _ = self.steps_done.fetchAdd(1, .monotonic);
    }

    /// Cooperative pause: block the calling (agent) thread until unpaused.
    pub fn waitIfPaused(self: *AgentHandle) void {
        while (self.paused.load(.monotonic)) {
            std.atomic.spinLoopHint();
        }
    }
};

test "AgentHandle cancel and progress" {
    var h = AgentHandle.init();
    try std.testing.expect(!h.isCanceled());
    try std.testing.expectEqual(@as(usize, 0), h.stepsDone());
    h.recordStep();
    h.recordStep();
    try std.testing.expectEqual(@as(usize, 2), h.stepsDone());
    h.requestCancel();
    try std.testing.expect(h.isCanceled());
}

test "AgentHandle waitIfPaused unblocks when unpaused" {
    var h = AgentHandle.init();
    h.setPaused(true);
    const th = try std.Thread.spawn(.{}, struct {
        fn run(hh: *AgentHandle) void {
            hh.waitIfPaused();
        }
    }.run, .{&h});
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    h.setPaused(false);
    th.join();
    try std.testing.expect(!h.isPaused());
}
