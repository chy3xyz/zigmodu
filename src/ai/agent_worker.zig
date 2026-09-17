//! Agent as a runtime worker — the `Agent → Worker → Event` edge of
//! `todo3.md` §八, wired to the runtime that already exists.
//!
//! Why: `Agent.run` blocks its calling thread for the whole LLM round-trip. Called
//! inline from a webhook handler or a cron tick (`ai.trigger.Trigger.fire` does
//! exactly that), one slow model stalls a request thread. Running the agent as a
//! **worker** gets, for free, what the runtime already promises:
//!
//! * a **bounded mailbox** (full → `error.Full` at the producer, not an
//!   unbounded queue behind a slow model);
//! * a **lifecycle** — `Application.stop()` / `rt.shutdown()` joins it;
//! * **supervision** — `spawnActor` + `Supervision` gives an error budget;
//! * **stats** — `handle.stats()` / `RuntimeStats` for queue depth and drops.
//!
//! The result comes back through `on_result`, **on the worker's thread**. That
//! callback is where the app closes the loop: publish an L1 event, enqueue an
//! outbox row (L2), push an SSE delta, or write to its own queue.
//!
//! Ownership, because a mailbox copies values and the sender's stack is gone:
//! `post()` dupes the goal text and the **worker frees it**; the `AgentResult`
//! handed to `on_result` is **borrowed** — copy what you keep, it is released
//! right after the callback returns.

const std = @import("std");
const runtime = @import("../runtime.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const AgentResult = agent_mod.AgentResult;
const SkillContext = @import("skill.zig").SkillContext;

/// One request for one agent run.
pub const Goal = struct {
    /// Goal text. The worker owns this and frees it after the run — use `post`,
    /// which dupes for you.
    text: []u8,
    /// Identity for this run (`SkillContext`), so memory recall / audit / quota
    /// see the right tenant and user.
    tenant_id: ?i64 = null,
    user_id: ?i64 = null,
};

/// What came back. `result` is owned by the worker and released the moment
/// `on_result` returns; `goal` borrows the message.
pub const Done = struct {
    goal: []const u8,
    result: ?AgentResult = null,
    err: ?anyerror = null,
};

/// Delivery hook. Runs on the worker's thread — keep it short (enqueue, don't
/// process) or the mailbox backs up behind it.
pub const ResultFn = *const fn (ud: ?*anyopaque, done: Done) void;

/// Pluggable executor. The default runs the real agent; tests inject a canned
/// one, and an app can swap in its own (workflow, multi-step, dry-run).
pub const ExecutorFn = *const fn (
    allocator: std.mem.Allocator,
    agent: *Agent,
    goal: Goal,
    max_steps: usize,
) anyerror!AgentResult;

fn runAgent(allocator: std.mem.Allocator, agent: *Agent, goal: Goal, max_steps: usize) anyerror!AgentResult {
    var sctx = SkillContext{
        .allocator = allocator,
        .tenant_id = goal.tenant_id,
        .user_id = goal.user_id,
    };
    return agent.run(allocator, goal.text, &sctx, max_steps);
}

pub const AgentWorker = struct {
    pub const Message = Goal;

    allocator: std.mem.Allocator,
    agent: *Agent,
    on_result: ResultFn,
    ud: ?*anyopaque = null,
    /// Steps per run (the ReAct loop's bound).
    max_steps: usize = 6,
    executor: ExecutorFn = runAgent,

    /// Runs finished, split by outcome. A run that failed is *not* counted as a
    /// worker error: a provider outage is not a bug in this worker, and the
    /// supervisor's error budget must stay for real ones.
    ran: u64 = 0,
    failed: u64 = 0,

    pub fn handle(self: *@This(), goal: Goal, ctx: anytype) anyerror!void {
        _ = ctx;
        defer self.allocator.free(goal.text);

        var result = self.executor(self.allocator, self.agent, goal, self.max_steps) catch |err| {
            self.failed += 1;
            self.on_result(self.ud, .{ .goal = goal.text, .err = err });
            return;
        };
        self.ran += 1;
        self.on_result(self.ud, .{ .goal = goal.text, .result = result });
        result.deinit(self.allocator);
    }
};

/// Hand a goal to the worker: dupes `text` (the worker frees it) and sends.
///
/// `handle` must be `*runtime.Handle(AgentWorker, capacity)` with `capacity`
/// spelled at the call site, e.g. `post(allocator, 32, handle, "…", 1, 7)`.
/// A full mailbox returns `error.Full` and nothing is leaked.
pub fn post(
    allocator: std.mem.Allocator,
    comptime capacity: usize,
    handle: *runtime.Handle(AgentWorker, capacity),
    text: []const u8,
    tenant_id: ?i64,
    user_id: ?i64,
) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try handle.send(.{ .text = owned, .tenant_id = tenant_id, .user_id = user_id });
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const FakeExec = struct {
    var calls: usize = 0;
    var fail: bool = false;

    fn run(
        allocator: std.mem.Allocator,
        agent: *Agent,
        goal: Goal,
        max_steps: usize,
    ) anyerror!AgentResult {
        _ = agent; // the canned executor never reaches provider/registry
        _ = goal;
        _ = max_steps;
        calls += 1;
        if (fail) return error.ProviderDown;
        return .{ .answer = try allocator.dupe(u8, "canned"), .steps = 1, .owned_answer = true };
    }
};

const Sink = struct {
    done: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    last_err: ?anyerror = null,
    first_goal: [32]u8 = @splat(0),
    first_len: usize = 0,
    first_steps: usize = 0,

    fn collect(ud: ?*anyopaque, d: Done) void {
        const self: *Sink = @ptrCast(@alignCast(ud.?));
        if (d.err) |e| {
            self.last_err = e;
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        }
        const r = d.result.?;
        const n = @min(d.goal.len, self.first_goal.len);
        if (self.done.load(.monotonic) == 0) {
            @memcpy(self.first_goal[0..n], d.goal[0..n]);
            self.first_len = n;
            self.first_steps = r.steps;
        }
        _ = self.done.fetchAdd(1, .monotonic);
    }

    fn reset(self: *Sink) void {
        self.done.store(0, .monotonic);
        self.failed.store(0, .monotonic);
        self.last_err = null;
        self.first_len = 0;
        self.first_steps = 0;
        self.first_goal = @splat(0);
    }
};

test "AgentWorker: goals run as worker messages and come back with their result" {
    const allocator = std.testing.allocator;
    var clk = runtime.Clock.Manual{ .now_ms = 0 };
    var rt = runtime.Runtime.init(allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var agent = Agent{ .provider = undefined, .registry = undefined };
    var sink = Sink{};
    sink.reset();
    FakeExec.calls = 0;
    FakeExec.fail = false;

    const worker = try rt.spawn(AgentWorker, .{
        .allocator = allocator,
        .agent = &agent,
        .on_result = Sink.collect,
        .ud = &sink,
        .executor = FakeExec.run,
    }, 8);

    try post(allocator, 8, worker, "goal one", 1, 7);
    try post(allocator, 8, worker, "goal two", 1, 7);

    var spins: usize = 0;
    while (sink.done.load(.monotonic) != 2 and spins < 100_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(usize, 2), sink.done.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), FakeExec.calls);
    // The goal reached the handler intact (posted through `post`, which dupes).
    try std.testing.expectEqualStrings("goal one", sink.first_goal[0..sink.first_len]);
    try std.testing.expectEqual(@as(usize, 1), sink.first_steps);
    try std.testing.expectEqual(@as(u64, 2), worker.state.ran);
    try std.testing.expectEqual(@as(u64, 0), worker.state.failed);
    // The worker itself never errored — the runtime's error counters stay clean.
    try std.testing.expectEqual(@as(u64, 0), worker.stats().handler_errors);

    worker.stop();
    worker.join();
}

test "AgentWorker: a failed run is reported to the app, not charged to the supervisor" {
    const allocator = std.testing.allocator;
    var clk = runtime.Clock.Manual{ .now_ms = 0 };
    var rt = runtime.Runtime.init(allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var agent = Agent{ .provider = undefined, .registry = undefined };
    var sink = Sink{};
    sink.reset();
    FakeExec.fail = true;

    const worker = try rt.spawn(AgentWorker, .{
        .allocator = allocator,
        .agent = &agent,
        .on_result = Sink.collect,
        .ud = &sink,
        .executor = FakeExec.run,
    }, 4);

    try post(allocator, 4, worker, "will fail", null, null);
    var spins: usize = 0;
    while (sink.failed.load(.monotonic) != 1 and spins < 100_000_000) : (spins += 1) std.atomic.spinLoopHint();

    try std.testing.expectEqual(@as(usize, 1), sink.failed.load(.monotonic));
    try std.testing.expectEqual(error.ProviderDown, sink.last_err.?);
    try std.testing.expectEqual(@as(u64, 1), worker.state.failed);
    try std.testing.expectEqual(@as(u64, 0), worker.state.ran);
    // Design choice: an outage is the app's to handle (retry / DLQ / alert), so
    // it does not consume the supervisor's error budget.
    try std.testing.expectEqual(@as(u64, 0), worker.stats().handler_errors);

    FakeExec.fail = false;
    worker.stop();
    worker.join();
}
