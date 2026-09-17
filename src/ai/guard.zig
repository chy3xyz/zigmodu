//! Agent guard — the rule that an agent is **not allowed to act by default**.
//!
//! `todo3.md` §八 states the product requirement this file implements:
//!
//! > Agent → Proposal → Risk → Execution —— **AI Agent 默认不能直接交易**
//!
//! Everything else an agent needs (identity, memory, skills, budgets, hooks,
//! metrics) already exists in this directory. What did not exist was the *gate*:
//! a place where "which actions may this agent take, and who said so" is decided
//! once, explicitly, and cannot be forgotten by a handler that calls a tool
//! directly.
//!
//! ## Two axes, both fail-closed
//!
//! 1. **Class.** Actions are typed: `read` (look at data), `propose` (produce a
//!    request for a human or another system), `execute` (change the world). The
//!    class carries its own default: `execute` is denied unless the policy turns
//!    it on *and* names the action — a settings typo can therefore not silently
//!    hand an agent the trading API.
//! 2. **Name.** The allow list is empty by default, i.e. **an agent with no policy
//!    can do nothing**. Adding a name is a deliberate, reviewable line; `deny`
//!    always wins over `allow`, so a broad allow can be carved back without
//!    re-listing everything.
//!
//! Budget is the third check, in the same function, because "the agent stopped
//! because it ran out of tokens" must not depend on the caller remembering to ask.
//!
//! ## What this is not
//!
//! It is not an authorization system for *end users* — that is `security/` (JWT,
//! RBAC, catalog permissions). This gate is about **the agent's own authority**:
//! what is this automated actor permitted to do at all, before any question of
//! which user it acts for.

const std = @import("std");
const budget_mod = @import("budget.zig");

/// What kind of thing the agent is trying to do. The class decides which default
/// applies, so the "execute everything" mistake has to be made explicitly.
pub const Action = enum {
    /// Read data the agent was pointed at.
    read,
    /// Produce a proposal / draft / order request for someone else to accept.
    propose,
    /// Take an effect (submit, cancel, transfer, publish).
    execute,
};

pub const Decision = enum {
    allowed,
    /// Not on the allow list (which is empty by default).
    denied_not_listed,
    /// Explicitly denied (and `deny` beats `allow`).
    denied_explicitly,
    /// An `execute` action that *is* listed, while the policy still forbids
    /// execution. (An unlisted execute is reported as `denied_not_listed`: that
    /// is the reason that would still stand after flipping `allow_execute`.)
    denied_execute_class,
    /// Token budget exhausted.
    denied_budget,
};

pub const Permissions = struct {
    /// Actions this agent may perform. **Empty means none** — an agent without an
    /// explicit policy is inert.
    allow: []const []const u8 = &.{},
    /// Always wins over `allow`; lets a broad list be narrowed without rewriting it.
    deny: []const []const u8 = &.{},
    /// Execution is a second switch on purpose: listing "order.submit" in `allow`
    /// is not enough, someone has to say "this agent may execute" too.
    allow_execute: bool = false,

    /// Pure decision, no accounting. `Guard.check` is the accounting version.
    ///
    /// The reported reason is the one that is actually binding: `deny` first
    /// (it overrides everything), then the listing, then the execute class. So an
    /// unlisted `execute` says `denied_not_listed` even when `allow_execute` is
    /// also off — turning that switch on would change nothing, and naming it
    /// would send an operator to the wrong knob.
    pub fn permits(self: Permissions, action: Action, name: []const u8) Decision {
        if (contains(self.deny, name)) return .denied_explicitly;
        if (!contains(self.allow, name)) return .denied_not_listed;
        if (action == .execute and !self.allow_execute) return .denied_execute_class;
        return .allowed;
    }

    pub fn isInert(self: Permissions) bool {
        return self.allow.len == 0;
    }
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// A permission policy plus the accounting that makes refusals visible: a denied
/// agent that looks healthy is exactly the failure this gate exists to prevent.
pub const Guard = struct {
    permissions: Permissions = .{},
    budget: budget_mod.Budget = budget_mod.Budget.init(0),
    allowed: u64 = 0,
    denied_not_listed: u64 = 0,
    denied_explicitly: u64 = 0,
    denied_execute_class: u64 = 0,
    denied_budget: u64 = 0,

    pub fn init(permissions: Permissions) Guard {
        return .{ .permissions = permissions };
    }

    /// Decide, and count. Returns the decision instead of an error so a caller can
    /// log *why* (the counters make that distinction visible across the process).
    ///
    /// `estimated_tokens` is charged only when the action is allowed — a refused
    /// action must not cost budget, or a misconfigured agent would starve itself
    /// by trying.
    pub fn check(self: *Guard, action: Action, name: []const u8, estimated_tokens: u64) Decision {
        const decision = self.permissions.permits(action, name);
        switch (decision) {
            .denied_not_listed => self.denied_not_listed += 1,
            .denied_explicitly => self.denied_explicitly += 1,
            .denied_execute_class => self.denied_execute_class += 1,
            .allowed => {},
            .denied_budget => unreachable, // produced below, not by `permits`
        }
        if (decision != .allowed) return decision;

        if (estimated_tokens > 0) {
            if (!self.budget.tryConsume(estimated_tokens)) {
                self.denied_budget += 1;
                return .denied_budget;
            }
        }
        self.allowed += 1;
        return .allowed;
    }

    /// True when every action would be allowed — the policy grants nothing, so the
    /// agent cannot act at all. Callers use it to fail a misconfiguration loudly at
    /// startup instead of discovering it as "the agent does nothing".
    pub fn isInert(self: *const Guard) bool {
        return self.permissions.isInert();
    }

    pub fn stats(self: *Guard) Stats {
        return .{
            .allowed = self.allowed,
            .denied_not_listed = self.denied_not_listed,
            .denied_explicitly = self.denied_explicitly,
            .denied_execute_class = self.denied_execute_class,
            .denied_budget = self.denied_budget,
            .tokens_used = self.budget.usedTokens(),
            .tokens_remaining = self.budget.remainingTokens(),
        };
    }

    pub const Stats = struct {
        allowed: u64,
        denied_not_listed: u64,
        denied_explicitly: u64,
        denied_execute_class: u64,
        denied_budget: u64,
        tokens_used: u64,
        tokens_remaining: u64,
    };
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "Guard: an agent with no policy can do nothing" {
    var guard = Guard.init(.{});
    try std.testing.expect(guard.isInert());
    try std.testing.expectEqual(Decision.denied_not_listed, guard.check(.read, "market.quote", 0));
    try std.testing.expectEqual(Decision.denied_not_listed, guard.check(.propose, "order.draft", 0));
    try std.testing.expectEqual(Decision.denied_not_listed, guard.check(.execute, "order.submit", 0));
    try std.testing.expectEqual(@as(u64, 3), guard.stats().denied_not_listed);
    try std.testing.expectEqual(@as(u64, 0), guard.stats().allowed);
}

test "Guard: reading and proposing need listing; executing needs a second switch" {
    var guard = Guard.init(.{
        .allow = &.{ "market.quote", "order.draft", "order.submit" },
    });

    try std.testing.expectEqual(Decision.allowed, guard.check(.read, "market.quote", 0));
    try std.testing.expectEqual(Decision.allowed, guard.check(.propose, "order.draft", 0));
    // Listed, but the policy never said "this agent may execute".
    try std.testing.expectEqual(Decision.denied_execute_class, guard.check(.execute, "order.submit", 0));

    guard.permissions.allow_execute = true;
    try std.testing.expectEqual(Decision.allowed, guard.check(.execute, "order.submit", 0));

    // And deny still wins over the (now execution-capable) allow list.
    guard.permissions.deny = &.{"order.submit"};
    try std.testing.expectEqual(Decision.denied_explicitly, guard.check(.execute, "order.submit", 0));

    const s = guard.stats();
    try std.testing.expectEqual(@as(u64, 3), s.allowed);
    try std.testing.expectEqual(@as(u64, 1), s.denied_execute_class);
    try std.testing.expectEqual(@as(u64, 1), s.denied_explicitly);
}

test "Guard: a refused action costs no budget; an allowed one is charged" {
    var guard = Guard.init(.{ .allow = &.{"market.quote"}, .allow_execute = false });
    guard.budget = budget_mod.Budget.init(100);

    try std.testing.expectEqual(Decision.denied_not_listed, guard.check(.read, "secret.read", 50));
    try std.testing.expectEqual(@as(u64, 0), guard.stats().tokens_used); // refusal is free

    try std.testing.expectEqual(Decision.allowed, guard.check(.read, "market.quote", 60));
    try std.testing.expectEqual(@as(u64, 60), guard.stats().tokens_used);

    // The next allowed action cannot fit: budget denies it, and says so separately.
    try std.testing.expectEqual(Decision.denied_budget, guard.check(.read, "market.quote", 50));
    try std.testing.expectEqual(@as(u64, 1), guard.stats().denied_budget);
    try std.testing.expectEqual(@as(u64, 60), guard.stats().tokens_used); // unchanged by the refusal

    // Within budget it still works, and the accounting is visible.
    try std.testing.expectEqual(Decision.allowed, guard.check(.read, "market.quote", 40));
    try std.testing.expectEqual(@as(u64, 100), guard.stats().tokens_used);
    try std.testing.expectEqual(@as(u64, 0), guard.stats().tokens_remaining);
}
