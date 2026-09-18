//! alpha-engine (P3) — a replay-driven trading pipeline on the ZigModu runtime,
//! split into modules and assembled in exactly one place, with an AI agent that
//! may **propose** and may not **trade**.
//!
//! ```text
//!  market        book          alpha          risk          exec
//!  replay feed ─▶ top of book ─▶ mean rev  ─▶  limits    ─▶  adapter  ─▶ PaperExchange
//!  (thread)       mailbox 64     mailbox 256   mailbox 256   mailbox 256     │
//!                     │                                                      ▼
//!                     ├─▶ audit: HotBus(Delta) ─▶ audit worker (slow)   FaultyFillReporter
//!                     │     frozen             └─▶ metrics sink (O(1))   (supervised actor)
//!                     │
//!                     └─▶ propose: DayEndSnapshot ─▶ ai.AgentWorker ─▶ guard(.propose) ─▶ risk
//!                                                       (canned,            │
//!                                                        offline)          └─ guard(.execute) ✗
//!                                                                              │
//!                                                            exec: desk worker ◀┘ (the authorized side)
//!                                                                  │
//!                                                                  └─▶ order ─▶ PaperExchange
//! ```
//!
//! Every stage is a module under `src/modules/`, declared with
//! `zmodu.api.Module` — a name, a description and **dependencies by module
//! name** — and wired by *type*: `main` instantiates the chain
//! (`risk.Module(exec.Module)`, `book.Module(alpha.Module(risk…), audit.Module)`),
//! each module's `initWith` spawns its own workers through the application
//! runtime, and no module imports another module's files. The shapes two modules
//! exchange live outside the module tree, in `contracts.zig`.
//!
//! What the run proves, in the order `docs/RUNTIME.md` introduces it:
//!
//! 1. **State ownership** — every worker's fields are touched by exactly one
//!    thread. There is no mutex in the example; the mailbox is the only hand-off.
//! 1b. **Fan-out (`HotBus`)** — the book publishes every accepted print to a bus
//!    wired at startup and `freeze()`d before traffic, so publishing is a
//!    lock-free slice walk. The audit worker is slow *by design*: it drops, and
//!    `bus.stats().dropped` counts it, instead of stalling the book. The metrics
//!    sink is the O(1) control group that always accepts.
//! 1c. **Supervision (`spawnActor`)** — `FaultyFillReporter` errors on every fill
//!    with a 3-error budget: the runtime stops it and closes its mailbox instead
//!    of logging forever, and routing continues. That is the difference between
//!    `spawn` and `spawnActor`.
//! 2. **Bounded backpressure** — the feed deliberately outruns the book (2,000
//!    points into a 64-slot mailbox), so `book.stats().dropped_full > 0` is part
//!    of the contract, not an accident. The queue is comptime-bounded: it can
//!    shed, it can never grow.
//! 3. **Timers deliver messages** — the snapshot is a timer message, so it runs
//!    on the book's thread with the book's state, never on the ticker's.
//! 4. **Lifecycle** — the workers belong to the module lifecycle
//!    (`initWith`/`ctx.runtime()`), so `app.stop()` joins them all and `main`
//!    only assembles and observes.
//! 5. **Module boundaries (P2)** — the declared graph has no cycle, and no module
//!    reaches into another's files: `zmodu doctor examples/alpha-engine` says so,
//!    and CI runs it.
//! 6. **An agent that may propose and may not trade (P3)** — the day-end snapshot
//!    wakes `ai.AgentWorker`; its answer becomes proposals; `ai.ProposalPipeline`
//!    puts each one through `guard(.propose)` → risk → `guard(.execute)`; that
//!    last check is refused (`allow_execute = false`) and the proposal ends as
//!    `execute_not_permitted`. It then leaves the agent's side as an envelope to
//!    `exec`'s desk, and *that* — a worker with no handle to the agent — is what
//!    builds an order. The agent never had a channel to the exchange, which is
//!    the whole point (`docs/AGENT_RUNTIME.md`).
//!
//! The six `[assert]` lines at the end are the acceptance gate
//! (`docs/dev/alpha-engine-spec.md` §4): each prints PASS/FAIL and any FAIL exits
//! the process non-zero.
//!
//! Run: `zig build run`.

const std = @import("std");
const zmodu = @import("zigmodu");

/// The run's output *is* its report: the six `[assert]` lines are the acceptance
/// gate, and framework chatter below `info` (module teardown, timer deliveries)
/// would push them out of a `tail`. Nothing this example asserts on is logged at
/// debug, so the level costs no evidence.
pub const std_options: std.Options = .{ .log_level = .info };

// ── the modules ──────────────────────────────────────────────────────────────
// Barrels only: `main` may see a module's published surface, never its inside.

const market = @import("modules/market/root.zig");
const book = @import("modules/book/root.zig");
const alpha = @import("modules/alpha/root.zig");
const risk = @import("modules/risk/root.zig");
const exec = @import("modules/exec/root.zig");
const audit = @import("modules/audit/root.zig");
const propose = @import("modules/propose/root.zig");

// ── the composition ──────────────────────────────────────────────────────────
// Every module is parameterised by the module it feeds, so "who may talk to
// whom" is the declared dependency graph — spelled once, here, and checked at
// compile time by `build(.{…})` (cycle / missing / self / duplicate names).

const Exec = exec.Module;
const Propose = propose.Module(Exec);
const Risk = risk.Module(Exec);
const Alpha = alpha.Module(Risk);
const Audit = audit.Module;
const Book = book.Module(Alpha, Audit, Propose);
const Market = market.Module(Book);

/// How long `main` waits for the drain barrier and the snapshot timer before it
/// reports what it has. A stuck stage has to end as a truncated report, not as a
/// hung example.
const report_timeout_ms: i64 = 5_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("alpha-engine: market -> book -> alpha -> risk -> exec -> paper exchange", .{});

    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("alpha-engine").build(.{ Market, Book, Alpha, Risk, Exec, Audit, Propose });
    defer app.deinit();
    try app.start(); // each module's initWith spawned its workers via ctx.runtime()
    defer app.stop();

    const rt = try app.runtime();

    try Market.drive(); // replay feed thread, joined — marker included

    // Drain barrier. The marker travels market → book → alpha → risk → exec and
    // every mailbox is FIFO per producer, so once the tail stages have armed
    // their latches, every earlier point has been handled by the whole chain —
    // no sleep, no guessing at a count that shed messages could never reach.
    // Acquiring those latches is also what orders the state reads below after the
    // writes they report on.
    const deadline = rt.clock.nowMs() + report_timeout_ms;
    Risk.drained.await(io, rt.clock, deadline);
    Exec.drained.await(io, rt.clock, deadline);

    // The snapshot timer is a message too, so it lands on the book's thread
    // after the replay ended; waiting for it is what makes `timer_fires > 0`
    // part of the run rather than a hope.
    Book.snapshot_taken.await(io, rt.clock, deadline);

    // P3's own barrier, in causal order and for the same reason: the snapshot
    // woke the agent (the book sent the day-end message *before* arming its
    // latch), the run ended — proposals gated, risk reviewed, survivors handed
    // to the desk — and the desk's order came back through the router as a fill.
    // Each await is the happens-before edge for the state read after it.
    Propose.agent_done.await(io, rt.clock, deadline);
    Exec.authorized_done.await(io, rt.clock, deadline);

    // The reporter errors on every fill, so its 3-error budget is spent almost
    // immediately; waiting for the mailbox to close is what orders the
    // `stopped_by_supervisor` read below after the supervisor's write (the flag
    // is set before `stop()` closes the mailbox).
    const reporter = Exec.reporter.?;
    while (!reporter.mailbox.isClosed()) {
        if (rt.clock.nowMs() > deadline) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    const book_handle = Book.inbox.?;
    const exec_handle = Exec.inbox.?;
    const alpha_handle = Alpha.inbox.?;
    const risk_handle = Risk.inbox.?;
    const audit_handle = Audit.inbox.?;
    const propose_state = Propose.state.?;
    const desk_handle = Exec.desk.?;

    std.log.info("[snapshot] bids={d} asks={d} best_bid={d} best_ask={d} mid={d} vwap={d} fills={d} pnl={d} timer_snapshots={d}", .{
        book_handle.state.bids,
        book_handle.state.asks,
        book_handle.state.top.best_bid,
        book_handle.state.top.best_ask,
        book_handle.state.top.mid(),
        book_handle.state.tape.vwap(),
        exec_handle.state.exchange.fills,
        exec_handle.state.exchange.pnl(),
        book_handle.state.snapshots,
    });

    const bus_stats = Audit.bus.stats();
    std.log.info("[fanout] bus: subscribers={d} published={d} delivered={d} dropped={d} | sink deltas={d} | audit kept={d}", .{
        bus_stats.subscribers,   bus_stats.published,
        bus_stats.delivered,     bus_stats.dropped,
        Audit.sink.tally.deltas, audit_handle.state.trail.kept,
    });
    std.log.info("[supervision] fill reporter: attempts={d} stopped_by_supervisor={} mailbox_closed={} | exec report_shed={d}", .{
        reporter.state.attempts,
        reporter.stats().stopped_by_supervisor,
        reporter.mailbox.isClosed(),
        exec_handle.state.report_shed,
    });

    const s = rt.stats();
    std.log.info("[stats] workers={d} sent={d} received={d} dropped={d} handler_errors={d} timer_fires={d} timer_lag_max_ms={d}", .{
        s.workers,        s.messages_sent, s.messages_received, s.messages_dropped,
        s.handler_errors, s.timer_fires,   s.timer_lag_max_ms,
    });
    const bs = book_handle.stats();
    std.log.info("[book] mailbox cap={d} len={d} dropped_full={d} coalesced={d} | alpha signals={d} shed={d} | risk rejected={d}", .{
        bs.mailbox_capacity,         bs.mailbox_len,             bs.dropped_full,
        book_handle.state.coalesced, alpha_handle.state.signals, alpha_handle.state.shed,
        risk_handle.state.rejected,
    });

    // P3, read across the two latches awaited above: the agent's own accounting
    // (guard, risk, counters) and the desk's. `effect_reached` is the interesting
    // zero — the pipeline's executor is the one function the agent may not
    // reach, and the gate is what keeps it at 0.
    const gs = propose_state.guard.stats();
    const pr = propose_state.report;
    const authorized_fills = exec_handle.state.authorized_fills;
    std.log.info("[agent] guard: allowed={d} denied_execute_class={d} denied_not_listed={d} denied_explicitly={d} denied_budget={d} | pipeline effect_reached={d}", .{
        gs.allowed,           gs.denied_execute_class, gs.denied_not_listed,
        gs.denied_explicitly, gs.denied_budget,        propose.service.effectsReached(),
    });
    std.log.info("[propose] trigger fired={d} shed={d} | proposals={d} execute_not_permitted={d} risk_rejected={d} refused={d} | handed_to_desk={d} desk_shed={d}", .{
        Propose.inbox.?.state.fired, Propose.inbox.?.state.shed,
        pr.proposed,                 pr.not_permitted,
        pr.risk_rejected,            pr.refused,
        pr.not_permitted,            pr.desk_shed,
    });
    std.log.info("[desk] authorized={d} declined={d} shed={d} | exec authorized_fills={d} of {d} fills", .{
        desk_handle.state.approved, desk_handle.state.declined,       desk_handle.state.shed,
        authorized_fills,           exec_handle.state.exchange.fills,
    });

    // The P1 acceptance gate, kept as the P2 regression contract
    // (`docs/dev/alpha-engine-spec.md` §4): these are assertions, not vibes —
    // each prints its verdict and any FAIL exits non-zero.
    const ok_bus = bus_stats.dropped > 0;
    const ok_book = bs.dropped_full > 0;
    const ok_faulty = reporter.stats().stopped_by_supervisor;
    const ok_timers = s.timer_fires > 0;
    std.log.info("[assert] bus.stats().dropped > 0: {s} (dropped={d})", .{ if (ok_bus) "PASS" else "FAIL", bus_stats.dropped });
    std.log.info("[assert] book.stats().dropped_full > 0: {s} (dropped_full={d})", .{ if (ok_book) "PASS" else "FAIL", bs.dropped_full });
    std.log.info("[assert] faulty.stats().stopped_by_supervisor == true: {s} (attempts={d})", .{ if (ok_faulty) "PASS" else "FAIL", reporter.state.attempts });
    std.log.info("[assert] rt.stats().timer_fires > 0: {s} (timer_fires={d})", .{ if (ok_timers) "PASS" else "FAIL", s.timer_fires });
    if (!(ok_bus and ok_book and ok_faulty and ok_timers)) return error.P1AssertionFailed;

    // The P3 acceptance gate: the agent tried to execute and was refused, and
    // the loop closed anyway — proposals outlived the refusal because the
    // authorized side is a different path, not a different permission.
    const ok_gate = gs.denied_execute_class > 0;
    const ok_loop = pr.proposed > 0 and authorized_fills > 0;
    std.log.info("[assert] agent.guard.stats().denied_execute_class > 0: {s} (denied_execute_class={d}, effect_reached={d})", .{
        if (ok_gate) "PASS" else "FAIL", gs.denied_execute_class, propose.service.effectsReached(),
    });
    std.log.info("[assert] proposals > 0 and authorized fills > 0: {s} (proposals={d}, authorized_fills={d})", .{
        if (ok_loop) "PASS" else "FAIL", pr.proposed, authorized_fills,
    });
    if (!(ok_gate and ok_loop)) return error.P3AssertionFailed;

    app.stop(); // requests stop, wakes blocked recvs, joins
    std.log.info("[done] every worker joined", .{});
}
