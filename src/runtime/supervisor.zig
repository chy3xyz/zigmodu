//! Supervision groups — the tree half of `Supervision` (docs/RUNTIME.md §14).
//!
//! §3b supervises **one** actor: it counts its own errors and decides whether to
//! stop. What it cannot say is "and then what" — a stopped member is terminal,
//! and nothing outside polling `stats()` ever learns it happened. A `Group` adds
//! both halves:
//!
//! * **A policy** for a member that is going down: rebuild that one
//!   (`.one_for_one`), rebuild every member (`.one_for_all`), rebuild it and the
//!   ones spawned after it (`.rest_for_one`), or take the whole group down
//!   (`.stop_group`).
//! * **An intensity** — a restart budget, the same idea as `Supervision`'s error
//!   budget and for the same reason: a member that dies on every message must
//!   become a counted stop, not an `init` loop that burns a core with a log line
//!   attached.
//!
//! ## Who runs what
//!
//! There is no supervisor thread and no supervisor actor. The executor is **the
//! failing member's own thread**: it is already the only thread that owns that
//! member's state, and the group action is nothing but atomics on its peers'
//! handles, which is exactly what `Handle.stop()` already is. A peer that is
//! told to rebuild notices on its own thread (at its loop top, or at its pool
//! claim) and does its own teardown — the alternative, rebuilding another
//! thread's state, is the one thing §4's ownership contract forbids.
//!
//! ## Locks
//!
//! Each group has one spinlock, and it guards **only** the budget fields. Member
//! iteration holds it too, so adding a member cannot race a failure. Escalation
//! releases the child's lock *before* recursing into the parent, so nested locks
//! are only ever taken parent → child and a cycle is impossible.

const std = @import("std");

/// What the group does about a member that is going down.
///
/// Deliberately OTP's vocabulary rather than `restart`: `Supervision.Strategy`
/// already spends the word `restart` on "log the error and keep serving", and
/// two meanings for one word in the same configuration reads as one meaning.
pub const Policy = enum {
    /// Rebuild the failing member; its group-mates are not touched.
    one_for_one,
    /// Rebuild every member of the group.
    one_for_all,
    /// Rebuild the failing member and every member spawned after it. Members
    /// spawned before it are left alone, which is what makes "this one depends
    /// on that one" expressible: a failure propagates forward and never back.
    rest_for_one,
    /// Never rebuild. A failure takes the whole group down — for members that
    /// are only useful together.
    stop_group,
};

/// How many times a group may rebuild inside `window_ms` before it gives up.
///
/// `max_restarts = 0` means "no rebuilds at all": a group that is not allowed to
/// restart is the same as `.stop_group`, and saying it this way keeps "0 = none"
/// rather than borrowing `max_errors`' "0 = unlimited" (for restarts, unlimited
/// *is* the CPU black hole this exists to prevent).
pub const Intensity = struct {
    max_restarts: u32 = 3,
    window_ms: i64 = 60_000,
};

/// What a group can ask of one member, type-erased so a member list can hold any
/// `Handle(W, capacity)`.
pub const WorkerRef = struct {
    ptr: *anyopaque,
    name: []const u8,
    /// Idempotent. Sets the member's restart flag; the member's own thread does
    /// the teardown and the rebuild.
    request_restart: *const fn (*anyopaque) void,
    /// `Handle.stop()`: set the stop flag and close the mailbox.
    request_stop: *const fn (*anyopaque) void,
};

pub const Member = union(enum) {
    worker: WorkerRef,
    group: *Group,
};

/// What the failing member must do with itself once the group has had its say.
pub const SelfAction = enum { rebuild, stop };

pub const Lock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// The shape is `core/SpinLock.zig`'s, and for the reason it documents: an
    /// unconditional `swap(true, .acquire)` *writes* on every call, dirtying the
    /// line even when the lock is free and nobody is contending — which is the
    /// common case here (a group's budget is touched once per failure, its member
    /// list once per spawn). A weak compare-exchange that only claims the free →
    /// held transition leaves the line alone when there is nothing to contend
    /// for, and measured under contention it is the difference between ~25–34 and
    /// ~73–97 ns per acquire (4 threads, `-OReleaseFast`).
    ///
    /// Bounded, too: 32 rounds of spinning, then the time slice is yielded, so a
    /// holder that is doing real work inside the critical section degrades to
    /// polite waiting instead of burning a core. The critical sections are small
    /// by construction (budget fields and member iteration, no callbacks into
    /// worker code), which is what keeps "spin then yield" the right answer here
    /// rather than `std.Io.Mutex`.
    pub fn acquire(self: *Lock) void {
        var spins: u32 = 0;
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins < 32) {
                std.atomic.spinLoopHint();
            } else {
                // A failed yield is benign (we just retry the acquire), but it is
                // still an error — surface it at debug rather than swallowing it.
                std.Thread.yield() catch |err| std.log.debug(
                    "[supervisor] lock wait: yield failed ({s}), retrying",
                    .{@errorName(err)},
                );
            }
        }
    }

    pub fn release(self: *Lock) void {
        self.flag.store(false, .release);
    }
};

pub const Group = struct {
    policy: Policy,
    intensity: Intensity = .{},
    /// Order matters: `rest_for_one` uses it, and it is spawn order.
    members: std.ArrayList(Member) = .empty,
    /// The group this one escalates to. Set by `addSubgroup` on the child, so
    /// the edge only ever points parent-ward even though actions walk down.
    parent: ?*Group = null,
    lock: Lock = .{},
    restarts_in_window: u32 = 0,
    window_start_ms: i64 = 0,

    pub fn init(policy: Policy, intensity: Intensity) Group {
        return .{ .policy = policy, .intensity = intensity };
    }

    /// Append a worker member. Returns the index to remember: it is what
    /// `rest_for_one` needs to tell "spawned after" from "spawned before".
    pub fn add(self: *Group, allocator: std.mem.Allocator, member: Member) !usize {
        self.lock.acquire();
        defer self.lock.release();
        try self.members.append(allocator, member);
        return self.members.items.len - 1;
    }

    pub fn addSubgroup(self: *Group, allocator: std.mem.Allocator, child: *Group) !usize {
        child.parent = self;
        return self.add(allocator, .{ .group = child });
    }

    pub fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
    }

    /// Undo an `add` for the member that was just appended — the only case that
    /// arises: a spawn that failed after joining has just appended the member it
    /// must take back. Only the tail is removable, because the list *is*
    /// `rest_for_one`'s ordering and a hole in the middle would silently
    /// renumber it. A no-op if the tail is not `member`, which is what makes it
    /// safe to run unconditionally from an `errdefer`.
    pub fn removeLast(self: *Group, member: Member) void {
        self.lock.acquire();
        defer self.lock.release();
        if (self.members.items.len == 0) return;
        if (!sameMember(self.members.items[self.members.items.len - 1], member)) return;
        _ = self.members.pop();
    }

    fn sameMember(a: Member, b: Member) bool {
        return switch (a) {
            .worker => |w| switch (b) {
                .worker => |v| w.ptr == v.ptr,
                .group => false,
            },
            .group => |g| switch (b) {
                .group => |v| g == v,
                .worker => false,
            },
        };
    }

    pub fn len(self: *const Group) usize {
        return self.members.items.len;
    }

    fn indexOfGroup(self: *const Group, child: *const Group) ?usize {
        for (self.members.items, 0..) |m, i| switch (m) {
            .group => |g| if (g == child) return i,
            .worker => {},
        };
        return null;
    }

    /// The group is told "the member at `index` is going down". Called on that
    /// member's own thread, which is what `SelfAction` is addressed to.
    ///
    /// `now_ms` comes from the caller's clock (`Runtime.clock`), so a test's
    /// `Manual` clock drives the budget window.
    pub fn onMemberDown(self: *Group, index: usize, now_ms: i64) SelfAction {
        // `.stop_group` is a declaration, not a budget: the caller already
        // decided these members are only useful together, so there is nothing to
        // escalate — the subtree goes down and that is the whole answer.
        if (self.policy == .stop_group) {
            self.stopSubtree();
            return .stop;
        }

        if (self.charge(now_ms) == .exhausted) {
            // Out of budget. This one *is* escalated: an unplanned failure to
            // recover is exactly the case where the parent should decide, and
            // the shape is OTP's — the parent applies its own policy to this
            // whole subtree, which is the child supervisor giving up.
            //
            // The child's lock is released by now (`charge` took and dropped
            // it), which is what keeps nested locking parent → child only.
            if (self.parent) |p| {
                if (p.indexOfGroup(self)) |pi| return p.onMemberDown(pi, now_ms);
            }
            self.stopSubtree();
            return .stop;
        }

        switch (self.policy) {
            .stop_group => unreachable, // handled above
            .one_for_one => self.restartMembers(index, index + 1),
            .one_for_all => self.restartMembers(0, self.members.items.len),
            .rest_for_one => self.restartMembers(index, self.members.items.len),
        }
        return .rebuild;
    }

    const Charge = enum { allowed, exhausted };

    /// Take one restart out of the window's budget. Holds the lock for the
    /// read-modify-write only; the actions that follow run outside it.
    fn charge(self: *Group, now_ms: i64) Charge {
        self.lock.acquire();
        defer self.lock.release();
        if (self.intensity.window_ms > 0 and now_ms - self.window_start_ms > self.intensity.window_ms) {
            self.window_start_ms = now_ms;
            self.restarts_in_window = 0;
        }
        if (self.restarts_in_window >= self.intensity.max_restarts) return .exhausted;
        self.restarts_in_window += 1;
        return .allowed;
    }

    /// Ask `members[start..end]` to rebuild. The failing member itself is inside
    /// that range on purpose: it is about to rebuild anyway and clears its own
    /// flag when it does, and leaving it out would make `one_for_all` say two
    /// different things depending on which member failed.
    ///
    /// Does **not** reset this group's budget — `charge` just spent one, and a
    /// group that resets its own budget has no budget.
    pub fn restartMembers(self: *Group, start: usize, end: usize) void {
        self.lock.acquire();
        defer self.lock.release();
        const hi = @min(end, self.members.items.len);
        for (self.members.items[start..hi]) |m| switch (m) {
            .worker => |w| w.request_restart(w.ptr),
            // A child group asked to rebuild resets its own budget too: the
            // parent rebuilding a subtree is a fresh start for that subtree's
            // supervisor, which is the only thing that keeps a doubly-exhausted
            // tree from escalating forever.
            .group => |g| g.restartSubtree(),
        };
    }

    /// Rebuild everything below this group, budget included. Used when a *parent*
    /// restarts this group as one of its members.
    pub fn restartSubtree(self: *Group) void {
        self.resetBudget();
        self.restartMembers(0, self.members.items.len);
    }

    /// Take the whole subtree down. Each member's own thread does its own stop,
    /// and each counts itself — this only sets the flags.
    pub fn stopSubtree(self: *Group) void {
        self.lock.acquire();
        defer self.lock.release();
        for (self.members.items) |m| switch (m) {
            .worker => |w| w.request_stop(w.ptr),
            .group => |g| g.stopSubtree(),
        };
    }

    pub fn resetBudget(self: *Group) void {
        self.lock.acquire();
        defer self.lock.release();
        self.restarts_in_window = 0;
    }

    /// Restarts this group has spent inside the current window. For tests and
    /// for a caller that wants to read the budget without spending one.
    pub fn restartsInWindow(self: *Group) u32 {
        self.lock.acquire();
        defer self.lock.release();
        return self.restarts_in_window;
    }
};

/// A member stand-in that records what it was asked to do, so a policy can be
/// checked without a Runtime, a thread or a mailbox.
const Probe = struct {
    restarts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stops: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn ref(self: *Probe) Member {
        return .{ .worker = .{
            .ptr = @ptrCast(self),
            .name = "probe",
            .request_restart = restarted,
            .request_stop = stopped,
        } };
    }

    fn restarted(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        _ = self.restarts.fetchAdd(1, .monotonic);
    }

    fn stopped(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        _ = self.stops.fetchAdd(1, .monotonic);
    }
};

test "Supervisor: one_for_one rebuilds only the member that failed" {
    const a = std.testing.allocator;
    var probes: [3]Probe = .{ .{}, .{}, .{} };
    var g = Group.init(.one_for_one, .{});
    defer g.deinit(a);
    for (&probes) |*p| _ = try g.add(a, p.ref());

    try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(1, 1_000));
    try std.testing.expectEqual(@as(u32, 0), probes[0].restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probes[1].restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), probes[2].restarts.load(.monotonic));
}

test "Supervisor: one_for_all rebuilds every member, the failing one included" {
    const a = std.testing.allocator;
    var probes: [3]Probe = .{ .{}, .{}, .{} };
    var g = Group.init(.one_for_all, .{});
    defer g.deinit(a);
    for (&probes) |*p| _ = try g.add(a, p.ref());

    try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(2, 1_000));
    for (&probes) |*p| try std.testing.expectEqual(@as(u32, 1), p.restarts.load(.monotonic));
}

test "Supervisor: rest_for_one rebuilds the failing member and the ones after it, never before" {
    const a = std.testing.allocator;
    var probes: [4]Probe = .{ .{}, .{}, .{}, .{} };
    var g = Group.init(.rest_for_one, .{});
    defer g.deinit(a);
    for (&probes) |*p| _ = try g.add(a, p.ref());

    try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(2, 1_000));
    try std.testing.expectEqual(@as(u32, 0), probes[0].restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), probes[1].restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probes[2].restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probes[3].restarts.load(.monotonic));
}

test "Supervisor: stop_group never rebuilds and takes every member down" {
    const a = std.testing.allocator;
    var probes: [3]Probe = .{ .{}, .{}, .{} };
    var g = Group.init(.stop_group, .{});
    defer g.deinit(a);
    for (&probes) |*p| _ = try g.add(a, p.ref());

    try std.testing.expectEqual(SelfAction.stop, g.onMemberDown(0, 1_000));
    for (&probes) |*p| {
        try std.testing.expectEqual(@as(u32, 1), p.stops.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), p.restarts.load(.monotonic));
    }
}

test "Supervisor: the budget is spent after max_restarts rebuilds, and a root group then stops everything" {
    const a = std.testing.allocator;
    var probes: [2]Probe = .{ .{}, .{} };
    var g = Group.init(.one_for_all, .{ .max_restarts = 3, .window_ms = 60_000 });
    defer g.deinit(a);
    for (&probes) |*p| _ = try g.add(a, p.ref());

    // Three rebuilds are affordable...
    for (0..3) |_| {
        try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(0, 1_000));
    }
    try std.testing.expectEqual(@as(u32, 3), g.restartsInWindow());
    try std.testing.expectEqual(@as(u32, 3), probes[0].restarts.load(.monotonic));

    // ...the fourth is not, and with no parent the subtree stops. The failing
    // member is told to stop itself *and* returns `.stop` — `stopSubtree` walks
    // every member including the one that raised the failure, which is the
    // honest reading: it is going down either way, and asking it is idempotent.
    try std.testing.expectEqual(SelfAction.stop, g.onMemberDown(0, 1_001));
    try std.testing.expectEqual(@as(u32, 1), probes[0].stops.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probes[1].stops.load(.monotonic));
}

test "Supervisor: max_restarts = 0 means no rebuild at all" {
    const a = std.testing.allocator;
    var probes: [1]Probe = .{.{}};
    var g = Group.init(.one_for_one, .{ .max_restarts = 0 });
    defer g.deinit(a);
    _ = try g.add(a, probes[0].ref());

    try std.testing.expectEqual(SelfAction.stop, g.onMemberDown(0, 1_000));
    try std.testing.expectEqual(@as(u32, 0), probes[0].restarts.load(.monotonic));
}

test "Supervisor: a lapse longer than the window gives the budget back" {
    const a = std.testing.allocator;
    var probes: [1]Probe = .{.{}};
    var g = Group.init(.one_for_one, .{ .max_restarts = 1, .window_ms = 1_000 });
    defer g.deinit(a);
    _ = try g.add(a, probes[0].ref());

    try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(0, 0));
    try std.testing.expectEqual(SelfAction.stop, g.onMemberDown(0, 1)); // same window: spent
    // Past the window the counter starts over, so this one rebuilds again —
    // "how many times in a row" is the question, not "how many ever".
    try std.testing.expectEqual(SelfAction.rebuild, g.onMemberDown(0, 2_000));
}

test "Supervisor: an exhausted child group escalates, and the parent's policy decides" {
    const a = std.testing.allocator;
    // `cluster` holds two subgroups. The first is repeatedly killed; once it is
    // out of budget it escalates, and `cluster`'s `one_for_all` rebuilds the
    // whole tree — the sibling subtree included.
    var cluster = Group.init(.one_for_all, .{ .max_restarts = 8 });
    defer cluster.deinit(a);
    var left = Group.init(.one_for_one, .{ .max_restarts = 1, .window_ms = 60_000 });
    defer left.deinit(a);
    var right = Group.init(.one_for_one, .{ .max_restarts = 8 });
    defer right.deinit(a);
    var l_probe = Probe{};
    var r_probe = Probe{};
    _ = try left.add(a, l_probe.ref());
    _ = try right.add(a, r_probe.ref());
    _ = try cluster.addSubgroup(a, &left);
    _ = try cluster.addSubgroup(a, &right);

    // `left` spends its single restart on itself; `right` is untouched.
    try std.testing.expectEqual(SelfAction.rebuild, left.onMemberDown(0, 0));
    try std.testing.expectEqual(@as(u32, 1), l_probe.restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), r_probe.restarts.load(.monotonic));

    // Now `left` is out of budget: it escalates to `cluster`, whose
    // `one_for_all` rebuilds both subtrees — and `left`'s own budget is reset on
    // the way down, which is what stops the next escalation from being immediate.
    try std.testing.expectEqual(SelfAction.rebuild, left.onMemberDown(0, 1));
    try std.testing.expectEqual(@as(u32, 2), l_probe.restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), r_probe.restarts.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), left.restartsInWindow());
}

test "Supervisor: an exhausted root with no parent stops its whole subtree, deepest members included" {
    const a = std.testing.allocator;
    var root = Group.init(.one_for_all, .{ .max_restarts = 0 }); // out of budget immediately
    defer root.deinit(a);
    var child = Group.init(.one_for_all, .{ .max_restarts = 0 }); // likewise
    defer child.deinit(a);
    var deep = Probe{};
    var shallow = Probe{};
    _ = try child.add(a, deep.ref());
    _ = try root.add(a, shallow.ref());
    _ = try root.addSubgroup(a, &child);

    // The child escalates (it is out of budget) and the root is too, with no
    // parent above it: the subtree stops — the root's own member and, through
    // the child, the deepest one.
    try std.testing.expectEqual(SelfAction.stop, child.onMemberDown(0, 0));
    try std.testing.expectEqual(@as(u32, 1), deep.stops.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), shallow.stops.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), deep.restarts.load(.monotonic));
}

test "Supervisor: stop_group does not escalate — the declaration is the answer" {
    const a = std.testing.allocator;
    var parent = Group.init(.one_for_all, .{ .max_restarts = 8 });
    defer parent.deinit(a);
    var child = Group.init(.stop_group, .{});
    defer child.deinit(a);
    var mate = Probe{};
    var inside = Probe{};
    _ = try parent.add(a, mate.ref());
    _ = try child.add(a, inside.ref());
    _ = try parent.addSubgroup(a, &child);

    try std.testing.expectEqual(SelfAction.stop, child.onMemberDown(0, 0));
    try std.testing.expectEqual(@as(u32, 1), inside.stops.load(.monotonic));
    // The parent was *not* asked, so the sibling is untouched: a stop_group
    // subtree stops and says so, rather than handing the decision upward.
    try std.testing.expectEqual(@as(u32, 0), mate.stops.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), mate.restarts.load(.monotonic));
}
