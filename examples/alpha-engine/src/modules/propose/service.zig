//! The propose module's workers, its policy state, and the run handler that
//! closes the loop.
//!
//! The flow, in the order the mailboxes carry it:
//!
//! ```text
//! book ──DayEndSnapshot──▶ Trigger ──goal text──▶ ai.AgentWorker
//!                                                      │ executor (canned, offline)
//!                                                      ▼
//!                                                  onResult
//!                                       guard(.propose) → risk → guard(.execute)
//!                                                      │ execute_not_permitted
//!                                                      ▼
//!                                              exec's desk inbox
//! ```
//!
//! Nothing here reaches the exchange, and nothing here *can*: the only thing the
//! agent side sends out is an envelope of numbers plus the verdict its own gate
//! produced. The order is built on the other side (`exec`'s `Authorizer`).
//!
//! Threading: the trigger worker and the agent worker are different threads, so
//! the hand-off between them is the agent worker's mailbox and nothing else. The
//! guard, the risk engine and the report belong to the *agent worker's* thread;
//! `main` reads them only after `agent_done`, which is where the happens-before
//! edge lives.

const std = @import("std");
const zmodu = @import("zigmodu");
const ai = zmodu.ai;
const data = zmodu.data;
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const model = @import("model.zig");

/// The injected executor — the `AgentWorker.executor` seam
/// (`docs/AGENT_RUNTIME.md` §六). It is the whole of the module's "AI": offline,
/// deterministic, and a pure function of the message that woke it.
///
/// Note what it does *not* do: it never touches the `agent` it is handed (there
/// is no provider behind this run, and no network in this example), and it
/// returns a *draft*. The gate is applied by `Run.onResult`, not here, because a
/// draft that has not been through the gate is not yet anything.
pub fn cannedAgent(
    allocator: std.mem.Allocator,
    agent: *ai.Agent,
    goal: ai.AgentGoal,
    max_steps: usize,
) anyerror!ai.AgentResult {
    _ = agent;
    _ = max_steps;
    var buf: [192]u8 = undefined;
    const answer = try model.cannedAgent(&buf, goal.text);
    // `AgentResult.answer` is owned by the worker, which frees it right after
    // `on_result` returns — so the stack buffer has to be copied out of.
    return .{ .answer = try allocator.dupe(u8, answer), .steps = 1, .owned_answer = true };
}

/// The effect the pipeline would call if the policy ever allowed execution.
///
/// It is unreachable by construction (`allow_execute = false`), and the counter
/// is what makes "unreachable" checkable: the report prints it, and a non-zero
/// value means the gate was opened, not that the venue filled.
var effects_reached: u64 = 0;

fn effect(_: ?*anyopaque, _: *ai.SkillContext, _: []const u8, _: []const u8) anyerror!void {
    effects_reached += 1;
    return error.AgentMayNotExecute;
}

pub fn effectsReached() u64 {
    return effects_reached;
}

/// What the module has to say for itself after the run. Written by the agent
/// worker's thread, read by `main` after `agent_done`.
pub const Report = struct {
    /// Legs that reached the gate.
    proposed: u64 = 0,
    /// The gate let the agent propose and refused the execution: handed over.
    not_permitted: u64 = 0,
    /// Risk said no before the execute check was reached.
    risk_rejected: u64 = 0,
    /// Any other verdict — `propose_refused`, `failures`, … Each one is a bug or
    /// a policy surprise, which is why they are counted rather than folded away.
    refused: u64 = 0,
    /// Answers that carried no leg at all.
    unparsed: u64 = 0,
    /// Runs that could not finish (the worker reports these out of band).
    run_failures: u64 = 0,
    /// Proposals that could not be handed over: the desk's mailbox was closed
    /// or full. A shed proposal is money that did not move, so it is a counter.
    desk_shed: u64 = 0,
};

/// The module's policy state, owned by the agent worker's thread.
///
/// One allocation rather than four file-scope globals because the pieces point
/// at each other (`pipeline.guard`, `pipeline.risk`, `review.backend`) and the
/// addresses have to stay put; a single heap value makes that a fact of the
/// layout instead of a hope about link order.
pub const State = struct {
    allocator: std.mem.Allocator,
    /// The risk engine's stage. Its rules are SQL, so the leg under review is
    /// written here first — and `:memory:` is enough, because the row is read
    /// once, inside the same run.
    client: data.sqlx.Client,
    backend: data.SqlxBackend,
    review: ai.risk.RiskReview,
    guard: ai.Guard,
    pipeline: ai.ProposalPipeline,
    report: Report = .{},

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*State {
        const self = try allocator.create(State);
        errdefer allocator.destroy(self);

        self.client = data.sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
        errdefer self.client.deinit();
        try self.client.connect();
        _ = try self.client.exec(api.stage_schema, &.{});

        self.allocator = allocator;
        self.backend = .{ .allocator = allocator, .client = &self.client };
        self.review = ai.risk.RiskReview.init(allocator, &self.backend);
        self.review.rules = &api.risk_rules;
        self.review.high_threshold = api.high_threshold;
        self.review.escalate_threshold = api.escalate_threshold;

        // The policy, in one literal: this action may be *proposed*, and no
        // action of this agent may be executed. `allow_execute` is a second
        // switch on purpose (`src/ai/guard.zig`) — listing `order.propose`
        // would not be enough to trade even if the name were `order.submit`.
        self.guard = ai.Guard.init(.{ .allow = &.{api.action}, .allow_execute = false });
        self.pipeline = ai.ProposalPipeline.init(&self.guard, effect);
        self.pipeline.risk = &self.review;
        // No approval chain: an escalated proposal stays `needs_human`, and an
        // agent never approves itself (`docs/AGENT_RUNTIME.md` §四).
        self.pipeline.approval = null;
        self.report = .{};
        return self;
    }

    pub fn deinit(self: *State) void {
        self.client.deinit();
        self.allocator.destroy(self);
    }

    /// Put the leg where the risk rules can score it.
    fn stageLeg(self: *State, leg: model.Leg) !void {
        _ = try self.client.exec(
            "INSERT OR REPLACE INTO staged_proposal (id, qty, side, price) VALUES (1, ?, ?, ?)",
            &.{
                .{ .int = leg.qty },
                .{ .string = @tagName(leg.side) },
                .{ .int = leg.price },
            },
        );
    }

    /// Hand one reviewed proposal to the desk — the only outbound edge of this
    /// module, and the reason the loop can close without the agent executing.
    ///
    /// `desk` is `anytype` because its type is exec's (`DeskInbox`), and this
    /// module is not allowed to import exec's files: the handle is passed in by
    /// the composition root, exactly like every other mailbox in this example.
    fn handOver(self: *State, desk: anytype, id: u64, leg: model.Leg, level: c.RiskLevel) void {
        desk.send(.{
            .id = id,
            .side = leg.side,
            .qty = leg.qty,
            .price = leg.price,
            .verdict = .execute_not_permitted,
            .risk_level = level,
        }) catch |err| switch (err) {
            error.Full, error.Timeout => self.report.desk_shed += 1,
            error.Closed => {},
        };
    }
};

/// One agent run's other half: the answer becomes proposals, and every proposal
/// goes through the gate before anything else sees it.
///
/// This runs on the **agent worker's thread** — the thread that owns the guard,
/// the risk engine and the counters — so it is the only place the pipeline may
/// be called from. `DeskInbox` is exec's published handle for it.
pub fn Run(comptime DeskInbox: type) type {
    return struct {
        state: *State,
        desk: *DeskInbox,
        done: *c.Latch,

        pub fn onResult(ud: ?*anyopaque, d: ai.AgentDone) void {
            // Provenance for the cast below: the worker was handed `&run`, a
            // file-scope value inside `Module` with static storage that nothing
            // moves, resizes or frees — the same shape `audit`'s sink uses.
            const self: *@This() = @ptrCast(@alignCast(ud.?)); // audit: ignore b21
            // Armed on both exits: the trigger path ends here, success or not,
            // and `main` waits on it rather than on a number it hopes to see.
            defer self.done.arm();

            if (d.err) |err| {
                self.state.report.run_failures += 1;
                std.log.err("[propose] the agent run failed: {s}", .{@errorName(err)});
                return;
            }

            const answer = d.result.?.answer;
            var legs: [model.max_legs]model.Leg = undefined;
            const parsed = model.parseLegs(answer, &legs);
            if (parsed.len == 0) {
                self.state.report.unparsed += 1;
                std.log.err("[propose] the answer carried no proposal: {s}", .{answer});
                return;
            }

            var ctx = ai.SkillContext{
                .allocator = self.state.allocator,
                .tenant_id = api.tenant_id,
                .user_id = api.user_id,
            };

            for (parsed) |leg| {
                self.state.report.proposed += 1;
                const id = self.state.report.proposed;
                var payload_buf: [96]u8 = undefined;
                const payload = model.statement(&payload_buf, id, leg) catch |err| {
                    std.log.err("[propose] cannot render proposal #{d}: {s}", .{ id, @errorName(err) });
                    continue;
                };

                self.state.stageLeg(leg) catch |err| {
                    // Without the staged row the rules score nothing, which
                    // would read as "risk approved" — so a failure here stops
                    // the leg instead of quietly turning into a trade.
                    self.state.report.refused += 1;
                    std.log.err("[propose] cannot stage proposal #{d} for risk: {s}", .{ id, @errorName(err) });
                    continue;
                };

                const outcome = self.state.pipeline.submit(self.state.allocator, &ctx, .{
                    .action = api.action,
                    .payload = payload,
                    .subject = payload,
                    // Money, not a judgement: the amount is what an approval
                    // chain would weigh, and `outcome.risk.score` is the
                    // judgement.
                    .amount = leg.qty * leg.price,
                }) catch |err| {
                    self.state.report.refused += 1;
                    std.log.err("[propose] proposal #{d} could not be reviewed: {s}", .{ id, @errorName(err) });
                    continue;
                };

                switch (outcome.verdict) {
                    // The normal ending: the agent asked, and it may not act.
                    // The conclusion — not a bare refusal — goes to the desk.
                    .execute_not_permitted => {
                        self.state.report.not_permitted += 1;
                        const level: c.RiskLevel = if (outcome.risk) |r| r.level else .low;
                        std.log.info("[propose] #{d} {s} {d} @ {d}: proposed, not permitted (risk={s})", .{
                            id, @tagName(leg.side), leg.qty, leg.price, @tagName(level),
                        });
                        self.state.handOver(self.desk, id, leg, level);
                    },
                    .risk_rejected => {
                        self.state.report.risk_rejected += 1;
                        const score = if (outcome.risk) |r| r.score else 0;
                        std.log.info("[propose] #{d} {s} {d} @ {d}: rejected by risk (score={d})", .{
                            id, @tagName(leg.side), leg.qty, leg.price, score,
                        });
                    },
                    else => {
                        self.state.report.refused += 1;
                        std.log.warn("[propose] #{d}: {s}", .{ id, @tagName(outcome.verdict) });
                    },
                }
            }
        }
    };
}

/// The day-end trigger: the book's snapshot arrives as a message on this
/// worker's thread, and the only thing it does is turn it into a goal for the
/// agent worker. Two workers rather than one because a mailbox message is the
/// only hand-off this example allows itself: the formatting happens here, the
/// run happens there, and neither thread touches the other's state.
pub fn Trigger(comptime AgentHandle: type) type {
    return struct {
        pub const Message = c.DayEndSnapshot;

        agent: *AgentHandle,
        allocator: std.mem.Allocator,
        fired: u64 = 0,
        shed: u64 = 0,

        pub fn handle(self: *@This(), snap: c.DayEndSnapshot, ctx: anytype) anyerror!void {
            _ = ctx;
            self.fired += 1;
            var buf: [192]u8 = undefined;
            const goal = model.goalText(&buf, snap) catch |err| {
                std.log.err("[propose] cannot render the day-end prompt: {s}", .{@errorName(err)});
                return;
            };
            // `post` dupes the text: the mailbox copies values and this frame is
            // about to disappear. A full box is a decision (count it), not a
            // reason to stall the book whose timer fired this.
            ai.agent_worker.post(self.allocator, api.agent_capacity, self.agent, goal, api.tenant_id, api.user_id) catch |err| switch (err) {
                error.Full, error.Timeout => self.shed += 1,
                error.Closed => {},
                else => std.log.err("[propose] goal not posted: {s}", .{@errorName(err)}),
            };
        }
    };
}
