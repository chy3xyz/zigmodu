//! The propose module's domain: the day-end prompt, the canned stand-in for a
//! model, and the parsing of its answer back into legs.
//!
//! Everything here is a pure function of its input — no socket, no clock, no
//! RNG — which is what lets the example assert on agent-shaped behaviour while
//! staying offline and deterministic (`docs/dev/alpha-engine-spec.md` §5).
//!
//! The two halves are deliberately split the way a real run is: `goalText` is
//! what goes into the mailbox, `cannedAgent` is what an `AiProvider` would
//! answer, `parseLegs` is the app reading that answer back. When a provider is
//! wired in, only the middle one changes.

const std = @import("std");
const c = @import("../../contracts.zig");

/// How many legs one answer may carry. An answer with more is truncated — the
/// mailbox copy has to be a value, so the ceiling is comptime.
pub const max_legs = 4;

/// One leg of the agent's answer: a direction, a size, a price. Not an order —
/// it has no id, no origin and no venue, because the agent does not address the
/// venue.
pub const Leg = struct {
    side: c.Side,
    qty: i64,
    price: i64,
};

/// How many contracts the first leg sizes to at most. Typed on purpose: in this
/// Zig, arithmetic whose other operand is a comptime literal *narrows* the result
/// type (`@min(x, 3)` is a `u2`), so the constant is spelled with its type.
pub const max_first_leg: i64 = 3;

/// What the agent will size as its "conviction" leg: at least this many
/// contracts, always. Deliberately inside the whale band — a proposal that
/// risk reviews and rejects has to exist, or "risk runs before execution"
/// would be an untested claim.
pub const conviction_floor: i64 = 8;

/// The day-end prompt. The agent is handed the tape as *text* — no handle to the
/// book, no exchange, no client. What it does with the numbers is the model's
/// business; what it can do with them is this module's.
pub fn goalText(buf: []u8, s: c.DayEndSnapshot) ![]const u8 {
    return std.fmt.bufPrint(buf, "day-end snapshot bid={d} ask={d} mid={d} vwap={d} prints={d}", .{
        s.bid, s.ask, s.mid, s.vwap, s.prints,
    });
}

/// The prompt's payload for the pipeline: a subject a risk rule can be written
/// against and a payload the (never reached) executor would receive.
pub fn statement(buf: []u8, id: u64, leg: Leg) ![]const u8 {
    return std.fmt.bufPrint(buf, "proposal-{d} {s} {d} @ {d}", .{ id, @tagName(leg.side), leg.qty, leg.price });
}

/// The canned "model": mean reversion against the day's own reference.
///
/// `vwap - mid` is how stretched the touch is against what the day averaged to;
/// below the average is a buy, above it a sell, and the distance sizes the first
/// leg. The second leg is the same view at conviction size. Both are a
/// deterministic function of the snapshot, so the example can be asserted on.
///
/// A real deployment replaces this function with the provider-backed default
/// (`ai.AgentWorker.executor`) and nothing else in the module changes — that is
/// what the injection seam is for.
pub fn cannedAgent(buf: []u8, goal: []const u8) ![]const u8 {
    const s = try parseSnapshot(goal);
    const pull: i64 = s.vwap - s.mid;
    const side: c.Side = if (pull >= 0) .buy else .sell;
    // Negative-first, because `@abs` would turn the type into `u64` halfway
    // through the arithmetic.
    const stretched: i64 = if (pull >= 0) pull else -pull;
    const size: i64 = 1 + @min(@divTrunc(stretched, @as(i64, 2)), max_first_leg);
    const conviction: i64 = conviction_floor + size;
    return std.fmt.bufPrint(buf, "leg side={s} qty={d} price={d}\nleg side={s} qty={d} price={d}", .{
        @tagName(side), size,       s.mid,
        @tagName(side), conviction, s.mid,
    });
}

/// Read the snapshot back out of the prompt. Total, and it fails loudly: a goal
/// this function cannot read is a wiring bug, not a model quirk.
pub fn parseSnapshot(goal: []const u8) !c.DayEndSnapshot {
    const prints = try intField(goal, "prints");
    return .{
        .bid = try intField(goal, "bid"),
        .ask = try intField(goal, "ask"),
        .mid = try intField(goal, "mid"),
        .vwap = try intField(goal, "vwap"),
        .prints = if (prints > 0) @intCast(prints) else 0,
    };
}

/// Read an answer back into legs. Unlike `parseSnapshot` this is deliberately
/// tolerant: a model's output is not a contract, and an unparsable answer must
/// end as "no proposal", never as a panic or as a trade.
pub fn parseLegs(answer: []const u8, out: *[max_legs]Leg) []Leg {
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, answer, '\n');
    while (lines.next()) |line| {
        if (count == out.len) break;
        const side_text = field(line, "side") orelse continue;
        const qty = std.fmt.parseInt(i64, field(line, "qty") orelse continue, 10) catch continue;
        const price = std.fmt.parseInt(i64, field(line, "price") orelse continue, 10) catch continue;
        out[count] = .{
            .side = if (std.mem.eql(u8, side_text, "buy")) .buy else .sell,
            .qty = qty,
            .price = price,
        };
        count += 1;
    }
    return out[0..count];
}

/// `key=value` lookup over whitespace-delimited tokens — the whole grammar the
/// prompt and the answer share.
fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\n");
    while (tokens.next()) |token| {
        const eq = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        if (std.mem.eql(u8, token[0..eq], key)) return token[eq + 1 ..];
    }
    return null;
}

fn intField(text: []const u8, key: []const u8) !i64 {
    const raw = field(text, key) orelse return error.MalformedPrompt;
    return std.fmt.parseInt(i64, raw, 10) catch error.MalformedPrompt;
}
