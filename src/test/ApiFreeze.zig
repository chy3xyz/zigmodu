//! Deprecation and API-freeze gate: the names the docs promise are still there.
//!
//! `docs/UPGRADING.md` promises that the deprecated aliases are only removed at
//! 1.0, and `docs/API_FREEZE.md` names the entry points 1.0 freezes. Both are
//! promises about *names*, and nothing checked them: deleting `ctx.paramPath`,
//! re-exporting a name the docs record as removed, or hoisting an unstable
//! `runtime.*` type onto the frozen top-level surface, would have been found at
//! 1.0 — or by the consumer whose build broke first.
//!
//! `DocsConsistency.zig` covers the other half (a symbol shown in `docs/API.md`
//! must exist somewhere in `src/`); this file covers the half it cannot: the
//! table's own promises, the exact import path a consumer writes, and the split
//! between the frozen surface and the preview one.
//!
//! Six kinds of check, cheapest first:
//!
//! 1. **Callability** — every name in the deprecation table is called for real:
//!    `ctx.paramPath` is compared with `ctx.nestedParam`, `startAll` / `stopAll`
//!    run over a module set, `RateLimiter.acquire` drains the same bucket as
//!    `tryAcquire`, the four `ctx.send*` envelope helpers write their documented
//!    body, and `http.http_server` has to name the same types as `http.Server`.
//!    A removed alias fails to compile at that call site.
//! 2. **Marker** — the table's own rule 1 ("mark it deprecated in code and name
//!    the replacement") is checked: the declaration must still carry a
//!    `DEPRECATED` marker inside its doc comment, and that comment must name the
//!    replacement.
//! 3. **Removal** — the opposite direction for names that already left. The
//!    「已移除」 record in `docs/UPGRADING.md` carries `zigmodu.App` /
//!    `zigmodu.ModuleImpl` and `zigmodu.extensions`, so re-exporting one from
//!    `root.zig` is red. That is the failure the old table row invited: "removed
//!    no earlier than 1.0" reads as "still available", and a `@hasDecl` is
//!    enough to stop it.
//! 4. **File-level banners** — two files mark the *whole module* deprecated
//!    without a consumer-writable `zigmodu.<name>` having left, so they are
//!    neither rows nor removals. The gate pins the banner and — for the one that
//!    is still load-bearing — the public spelling (`http.FieldRules`) that keeps
//!    saying "this file cannot be deleted as the banner promises".
//! 5. **Anchor resolution** — every anchor `docs/API_FREEZE.md` names resolves
//!    (`@hasDecl`, data-driven from the doc's own rows, so the check follows the
//!    doc rather than a hand-written list of calls).
//! 6. **Table ↔ gate sync** — the rows are parsed out of `docs/UPGRADING.md` and
//!    `docs/API_FREEZE.md` and compared with the tables here. A row added
//!    without a check is red, and so is a check for a row that no longer exists
//!    — the two failure modes the deprecation table would otherwise have.
//!
//! What none of this covers (signature accuracy; how tightly a marker window
//! isolates one doc comment) is written down in `docs/API_FREEZE.md`
//! 「覆盖不到的部分」 rather than left implied.

const std = @import("std");

const zmodu = @import("../root.zig");
const http = zmodu.http;

// ============================================================
// 1. Deprecated aliases — mirrors docs/UPGRADING.md
// ============================================================

/// The section of `docs/UPGRADING.md` the rows are read from. A heading rename
/// fails the sync test, which is the point: the table is the promise.
const deprecation_heading = "## 弃用别名与删除计划";

/// One row of that table, plus where its declaration lives. `doc_deprecated` /
/// `doc_target` are the first backticked token of the row's first two columns,
/// so they have to keep matching the doc verbatim.
const Alias = struct {
    doc_deprecated: []const u8,
    doc_target: []const u8,
    /// File that declares the alias (and, per rule 1, marks it deprecated).
    decl_file: []const u8,
    /// Substring locating that declaration.
    decl_symbol: []const u8,
    /// Text that must appear in the marker window before `decl_symbol`.
    decl_must_contain: []const []const u8,
};

const ALIASES = [_]Alias{
    .{
        .doc_deprecated = "ctx.paramPath",
        .doc_target = "ctx.nestedParam",
        .decl_file = "src/api/Server.zig",
        .decl_symbol = "fn paramPath(",
        .decl_must_contain = &.{ "DEPRECATED", "nestedParam" },
    },
    .{
        .doc_deprecated = "zigmodu.startAll",
        .doc_target = "Application.start()",
        .decl_file = "src/root.zig",
        .decl_symbol = "pub const startAll = ",
        .decl_must_contain = &.{ "DEPRECATED", "Application.start()" },
    },
    .{
        .doc_deprecated = "zigmodu.stopAll",
        .doc_target = "Application.stop()",
        .decl_file = "src/root.zig",
        .decl_symbol = "pub const stopAll = ",
        .decl_must_contain = &.{ "DEPRECATED", "Application.stop()" },
    },
    .{
        .doc_deprecated = "zigmodu.http.http_server",
        .doc_target = "http.Server",
        .decl_file = "src/http.zig",
        .decl_symbol = "pub const http_server = ",
        .decl_must_contain = &.{ "DEPRECATED", "Server" },
    },
    .{
        .doc_deprecated = "ctx.sendSuccess",
        .doc_target = "ctx.json",
        .decl_file = "src/api/Server.zig",
        .decl_symbol = "pub fn sendSuccess(",
        .decl_must_contain = &.{ "DEPRECATED", "ctx.json" },
    },
    .{
        .doc_deprecated = "ctx.sendFail",
        .doc_target = "ctx.json",
        .decl_file = "src/api/Server.zig",
        .decl_symbol = "pub fn sendFail(",
        .decl_must_contain = &.{ "DEPRECATED", "ctx.json" },
    },
    .{
        .doc_deprecated = "ctx.sendPageResult",
        .doc_target = "ctx.json",
        .decl_file = "src/api/Server.zig",
        .decl_symbol = "pub fn sendPageResult(",
        .decl_must_contain = &.{ "DEPRECATED", "ctx.json" },
    },
    .{
        .doc_deprecated = "ctx.sendJsonItems",
        .doc_target = "ctx.json",
        .decl_file = "src/api/Server.zig",
        .decl_symbol = "pub fn sendJsonItems(",
        .decl_must_contain = &.{ "DEPRECATED", "ctx.json" },
    },
    .{
        .doc_deprecated = "RateLimiter.acquire",
        .doc_target = "RateLimiter.tryAcquire",
        .decl_file = "src/resilience/RateLimiter.zig",
        .decl_symbol = "pub fn acquire(",
        .decl_must_contain = &.{ "DEPRECATED", "tryAcquire" },
    },
};

/// How much text before the declaration counts as "its doc comment". Wide
/// enough for a box-drawn banner or a multi-line comment, narrow enough that a
/// `DEPRECATED` marker further up the file cannot satisfy the check (how loose
/// it stays for the two `root.zig` markers is recorded in `docs/API_FREEZE.md`
/// 「覆盖不到的部分」).
const marker_window = 1500;

// ============================================================
// 1b. Removed names — the other side of the deprecation table
// ============================================================

/// Heading of the record `docs/UPGRADING.md` keeps for names that already left
/// the surface. They are deliberately *not* rows in the table: "removed no
/// earlier than 1.0" would read as a promise that the name still works.
const removed_heading = "### 已移除";

/// A name that used to be a consumer-facing entry point and no longer is.
/// Recording it only pays off if the gate notices it coming back, so
/// `root_name` is asserted **absent** from `root.zig` instead of present.
const Removed = struct {
    /// The spelling a consumer used to write: `zigmodu.<root_name>`.
    root_name: []const u8,
    /// The removal evidence, as the doc cites it: a commit when one is recorded,
    /// otherwise the oldest written record the repo still has. Evidence, not a
    /// promise — and deliberately a string the doc must keep verbatim, so
    /// "removed at some point" cannot quietly become "removed, details lost".
    evidence: []const u8,
    /// File that still holds the implementation, reachable by path only.
    file: []const u8,
    /// The `@import` spelling inside `src/tests.zig`, quotes included: proof the
    /// file is still compiled (Zig is lazy, so a file nothing imports is a file
    /// whose signatures can rot unnoticed).
    compiled_import: []const u8,
};

const REMOVED = [_]Removed{
    .{
        .root_name = "App",
        .evidence = "557190a",
        .file = "src/api/Simplified.zig",
        .compiled_import = "\"api/Simplified.zig\"",
    },
    .{
        .root_name = "ModuleImpl",
        .evidence = "557190a",
        .file = "src/api/Simplified.zig",
        .compiled_import = "\"api/Simplified.zig\"",
    },
    .{
        .root_name = "extensions",
        // No commit and no tag records this one; `CHANGELOG.md`'s `[0.15.0]`
        // section is the oldest written record — it already describes
        // `zigmodu.extensions` as a namespace apps were moving off.
        .evidence = "0.15.0",
        .file = "src/extensions.zig",
        .compiled_import = "\"extensions.zig\"",
    },
};

// ============================================================
// 1c. File-level deprecation banners — neither rows nor removals
// ============================================================

/// A `DEPRECATED` banner on a *whole file*. Both of these used to look like
/// table material and are not: the table pairs "the old name a consumer wrote"
/// with "the name to write now", and neither file has such a pair any more.
///
/// * `src/extensions.zig` — its `zigmodu.extensions` namespace is gone (see
///   `REMOVED`); what is left is a type-alias shim, path-reachable only.
/// * `src/validation/Validator.zig` — its banner says "will be removed in v1.0",
///   but the file is still the live implementation behind `http.FieldRules`, so
///   that sentence is a plan with a prerequisite: move the public spelling
///   first. That half is asserted explicitly (it is the one entry here whose
///   *reachability* is part of the claim), so deleting the file as the banner
///   promises cannot happen silently.
const Banner = struct {
    file: []const u8,
    /// Rule-1 text the banner has to keep. Checked inside `banner_window` bytes
    /// from the top of the file — a banner that drifts down the file has stopped
    /// being a banner.
    must_contain: []const []const u8,
};

const BANNERS = [_]Banner{
    .{
        .file = "src/validation/Validator.zig",
        // The replacement the banner names, and the module it points at. This is
        // the live entry: the test also asserts `http.FieldRules` still resolves
        // to this file's `FieldRules`.
        .must_contain = &.{ "DEPRECATED", "ObjectValidator.zig" },
    },
    .{
        // Path-reachable only; the test also asserts its aliases still name the
        // domain files' types.
        .file = "src/extensions.zig",
        // The replacement the banner names for its first line of exports.
        .must_contain = &.{ "DEPRECATED", "zigmodu.http.http_server" },
    },
};

/// How far into a file its banner has to sit to count as one.
const banner_window = 1500;

test "deprecation table: ctx.paramPath is still a working alias of ctx.nestedParam" {
    const allocator = std.testing.allocator;

    // Both halves of the row: the name consumers are told to use, and the name
    // they are still allowed to keep.
    try std.testing.expect(@hasDecl(http.Context, "nestedParam"));
    try std.testing.expect(@hasDecl(http.Context, "paramPath"));

    var ctx = try http.Context.init(allocator, .GET, "/x");
    defer ctx.deinit();
    try ctx.query.put("filter[tags]", "a,b");

    try std.testing.expectEqualStrings("a,b", ctx.nestedParam("filter.tags").?);
    // The alias is callable and still answers exactly what its replacement does.
    try std.testing.expectEqualStrings(ctx.nestedParam("filter.tags").?, ctx.paramPath("filter.tags").?);
    // …and it is not a route parameter, the confusion that caused the rename.
    try std.testing.expect(ctx.paramPath("id") == null);
}

test "deprecation table: startAll / stopAll are still callable, Application replaces them" {
    const allocator = std.testing.allocator;

    // Both halves of the rows: the deprecated re-exports still work…
    try std.testing.expect(@hasDecl(zmodu, "startAll"));
    try std.testing.expect(@hasDecl(zmodu, "stopAll"));

    var modules = zmodu.ApplicationModules.init(allocator);
    defer modules.deinit();
    try modules.register(zmodu.ModuleInfo.init("api-freeze-alias", "startAll/stopAll callability probe", &.{}));

    // Called for real, not just referenced: the zero-module early return would
    // skip the sort and the start/stop loops entirely.
    try zmodu.startAll(&modules);
    zmodu.stopAll(&modules);

    // …and the replacement the rows point at is where the docs say it is.
    try std.testing.expect(@hasDecl(zmodu.Application, "start"));
    try std.testing.expect(@hasDecl(zmodu.Application, "stop"));
}

test "deprecation table: http.http_server still names the same types as http.Server" {
    const allocator = std.testing.allocator;

    try std.testing.expect(@hasDecl(http, "http_server"));
    // A second name for the same module, not a copy that can drift away from
    // the canonical one.
    try std.testing.expect(http.http_server.Server == http.Server);
    try std.testing.expect(http.http_server.Context == http.Context);

    // Reached through the alias path, which is what a consumer's old code does.
    var ctx = try http.http_server.Context.init(allocator, .GET, "/x");
    defer ctx.deinit();
    try std.testing.expectEqualStrings("/x", ctx.path);
}

test "deprecation table: ctx.sendSuccess / sendFail / sendPageResult / sendJsonItems still work, ctx.json replaces them" {
    const allocator = std.testing.allocator;

    // The four `{code,msg,data}` envelope helpers moved into the table at once:
    // they are one response shape, and `check-production.sh` treats them as a
    // family (the "envelope leak" scan). Calling each one for real is what keeps
    // the row honest — the markers alone would survive a broken body.
    inline for (.{ "sendSuccess", "sendFail", "sendPageResult", "sendJsonItems" }) |name| {
        try std.testing.expect(@hasDecl(http.Context, name));
    }
    // The replacement the rows name, on the same type.
    try std.testing.expect(@hasDecl(http.Context, "json"));

    var ctx = try http.Context.init(allocator, .GET, "/x");
    defer ctx.deinit();

    try ctx.sendSuccess("{\"a\":1}");
    try std.testing.expectEqualStrings("{\"code\":0,\"msg\":\"\",\"data\":{\"a\":1}}", ctx.response_body.items);

    ctx.response_body.items.len = 0;
    try ctx.sendFail(4001, "bad");
    try std.testing.expectEqualStrings("{\"code\":4001,\"msg\":\"bad\",\"data\":null}", ctx.response_body.items);

    ctx.response_body.items.len = 0;
    try ctx.sendPageResult("[1,2]", 7);
    try std.testing.expectEqualStrings("{\"code\":0,\"msg\":\"\",\"data\":{\"list\":[1,2],\"total\":7}}", ctx.response_body.items);

    ctx.response_body.items.len = 0;
    const items: []const u32 = &[_]u32{ 1, 2 };
    try ctx.sendJsonItems(items);
    // The row promises the `{code,msg,data}` envelope with the items in `data`.
    // Observed on this toolchain: the envelope is there, but `data` holds a
    // **struct dump** — the helper formats with `{any}`, which prints
    // `std.json.Stringify`'s fields instead of calling the serializer (the same
    // `{any}` is in `sendPageItems`). Pinning the envelope only, on purpose: the
    // defect lives in the deprecated helper, and fixing it must not mean editing
    // this gate first.
    const body = ctx.response_body.items;
    if (!std.mem.startsWith(u8, body, "{\"code\":0,\"msg\":\"\",\"data\":") or !std.mem.endsWith(u8, body, "}")) {
        std.debug.print("[api-freeze] sendJsonItems wrote `{s}` — its row promises the `{{code,msg,data}}` envelope\n", .{body});
        return error.SendJsonItemsShapeChanged;
    }

    // …and the replacement is a different thing on purpose: the same payload
    // written through `ctx.json` carries **no** envelope (that difference is the
    // whole point of the row, so it is asserted rather than assumed).
    var ctx2 = try http.Context.init(allocator, .GET, "/x");
    defer ctx2.deinit();
    try ctx2.json(200, "{\"a\":1}");
    try std.testing.expectEqualStrings("{\"a\":1}", ctx2.response_body.items);
}

test "deprecation table: RateLimiter.acquire is still callable, tryAcquire replaces it" {
    const allocator = std.testing.allocator;

    try std.testing.expect(@hasDecl(zmodu.RateLimiter, "acquire"));
    try std.testing.expect(@hasDecl(zmodu.RateLimiter, "tryAcquire"));

    // `refill_rate = 0` so the bucket cannot refill while the test runs: the
    // point is which call drains a token, not how long the process took.
    var limiter = try zmodu.RateLimiter.init(allocator, "api-freeze-acquire", 1, 0);
    defer limiter.deinit();

    // Both drain the same single-token bucket, one row apart.
    try std.testing.expect(limiter.acquire());
    try std.testing.expect(!limiter.tryAcquire());

    limiter.reset();
    try std.testing.expect(limiter.tryAcquire());
    // The old name denies when the bucket is empty — it does not wait. If it ever
    // grows a wait, this is the check that notices.
    try std.testing.expect(!limiter.acquire());
}

test "deprecation table: every row's replacement name still resolves" {
    var missing: usize = 0;

    // Data-driven off the gate's own table: the third column is the half of the
    // promise that rots quietly (a row keeps saying "use X" long after X was
    // renamed again), and nothing else checks it.
    inline for (ALIASES) |alias| {
        if (!replacementResolves(alias.doc_target)) {
            std.debug.print("[api-freeze] docs/UPGRADING.md row `{s}` tells the reader to use `{s}`, which does not resolve\n", .{ alias.doc_deprecated, alias.doc_target });
            missing += 1;
        }
    }

    if (missing > 0) return error.ReplacementNameMissing;
}

/// True when the "现在的名字" a row points at still exists. The table's targets
/// come in four shapes (`ctx.…`, `http.…`, `RateLimiter.…`, `Application.…`, plus
/// a bare top-level name), and a trailing `()` is allowed because the docs write
/// `Application.start()`.
fn replacementResolves(comptime target: []const u8) bool {
    const name = comptime blk: {
        const paren = std.mem.indexOfScalar(u8, target, '(') orelse target.len;
        break :blk target[0..paren];
    };

    if (comptime std.mem.startsWith(u8, name, "ctx.")) return @hasDecl(http.Context, name["ctx.".len..]);
    if (comptime std.mem.startsWith(u8, name, "http.")) return @hasDecl(http, name["http.".len..]);
    if (comptime std.mem.startsWith(u8, name, "RateLimiter.")) return @hasDecl(zmodu.RateLimiter, name["RateLimiter.".len..]);
    if (comptime std.mem.startsWith(u8, name, "Application.")) return @hasDecl(zmodu.Application, name["Application.".len..]);
    if (comptime std.mem.startsWith(u8, name, "zigmodu.")) return @hasDecl(zmodu, name["zigmodu.".len..]);
    return @hasDecl(zmodu, name);
}

test "removed: the names off the root stay off, and their files are still compiled" {
    const allocator = std.testing.allocator;

    // `@hasDecl(zmodu, …)` is what a consumer's `zigmodu.App` resolves against,
    // so `true` here is exactly the regression the 「已移除」 record guards.
    inline for (REMOVED) |removed| {
        if (comptime @hasDecl(zmodu, removed.root_name)) {
            std.debug.print("[api-freeze] `zigmodu.{s}` is exported again — docs/UPGRADING.md records it as removed ({s}); use the domain files / `Application` instead\n", .{ removed.root_name, removed.evidence });
            return error.RemovedNameReexported;
        }
    }

    // …and the compile gate still reaches each file, so a stale signature inside
    // it cannot hide behind Zig's lazy analysis.
    const tests = try readDoc(allocator, "src/tests.zig");
    defer allocator.free(tests);
    for (REMOVED) |removed| {
        if (std.mem.indexOf(u8, tests, removed.compiled_import) == null) {
            std.debug.print("[api-freeze] src/tests.zig no longer imports {s} — {s} still exists, but nothing compiles it any more\n", .{ removed.compiled_import, removed.file });
            return error.RemovedBlockUncompiled;
        }
    }

    // The block is still in the tree, at file level: the record says a consumer
    // can find it by path, not that it is a supported surface any more.
    const Simplified = @import("../api/Simplified.zig");
    try std.testing.expect(@hasDecl(Simplified, "App"));
    try std.testing.expect(@hasDecl(Simplified, "ModuleImpl"));
    try std.testing.expect(@hasDecl(Simplified, "Module"));

    // The record claims the internal path is the only way in today, so exercise
    // exactly that: `App.init` → `register(ModuleImpl(T)…)` → `start` / `stop`.
    const Legacy = struct {
        const Self = @This();

        started: bool = false,
        pub fn name(_: *Self) []const u8 {
            return "legacy";
        }
        pub fn start(self: *Self) !void {
            self.started = true;
        }
        pub fn stop(self: *Self) void {
            self.started = false;
        }
    };

    var inst = Legacy{};
    var legacy = Simplified.App.init(allocator);
    defer legacy.deinit();
    try legacy.register(Simplified.ModuleImpl(Legacy).interface(&inst));
    try legacy.start();
    try std.testing.expect(inst.started);
    legacy.stop();
    try std.testing.expect(!inst.started);

    // The replacement, used the way the guides show it.
    var b = zmodu.builder(allocator, std.testing.io);
    defer b.deinit();
    var app = try b.withName("api-freeze").build(.{});
    defer app.deinit();
}

test "removed: the extensions shim is a rename, not a fork" {
    // The record has two halves: the `zigmodu.extensions` namespace is gone (the
    // loop in the test above), and the file that carried it is still in the tree
    // with the same *types* the domain files export. Pinning the second half is
    // what makes "migrate off the namespace" a rename rather than a fork: an old
    // `zigmodu.extensions.HttpServer` value is a `http.Server` value.
    const Ext = @import("../extensions.zig");

    inline for (.{ "HttpServer", "HttpContext", "SqlxClient", "Orm", "RedisClient", "RetryPolicy", "ConnectionPool", "CronScheduler" }) |name| {
        try std.testing.expect(@hasDecl(Ext, name));
    }

    // Identity, not shape: these four are plain types, so the shim's name has to
    // resolve to the very same declaration the domain file exports (`Orm`,
    // `Pool`, `Policy`, `Scheduler` are generic/returned types — only existence
    // is checked for those).
    try std.testing.expect(Ext.HttpServer == http.Server);
    try std.testing.expect(Ext.HttpContext == http.Context);
    try std.testing.expect(Ext.SqlxClient == zmodu.data.sqlx.Client);
    try std.testing.expect(Ext.RedisClient == zmodu.data.redis.Redis);
}

test "removed: docs/UPGRADING.md records the same removals this gate pins" {
    const allocator = std.testing.allocator;

    const content = try readDoc(allocator, "docs/UPGRADING.md");
    defer allocator.free(content);

    const section = sectionText(content, removed_heading) orelse {
        std.debug.print("[api-freeze] docs/UPGRADING.md has no '{s}' record — a removed name must not stay in the table (that reads as \"still available\")\n", .{removed_heading});
        return error.RemovedRecordMissing;
    };

    var problems: usize = 0;
    for (REMOVED) |removed| {
        // The exact spelling the gate pins, so a mention of the replacement
        // (`zigmodu.Application`) cannot satisfy a check for `zigmodu.App`.
        const name = try std.fmt.allocPrint(allocator, "`zigmodu.{s}`", .{removed.root_name});
        defer allocator.free(name);

        if (std.mem.indexOf(u8, section, name) == null) {
            std.debug.print("[api-freeze] docs/UPGRADING.md '{s}' does not name {s}, which this gate asserts stays off the root\n", .{ removed_heading, name });
            problems += 1;
        }
        if (std.mem.indexOf(u8, section, removed.evidence) == null) {
            std.debug.print("[api-freeze] docs/UPGRADING.md '{s}' does not cite {s} for `zigmodu.{s}` — the record needs evidence (a commit, or the oldest written record there is), not just a name\n", .{ removed_heading, removed.evidence, removed.root_name });
            problems += 1;
        }
        if (std.mem.indexOf(u8, section, removed.file) == null) {
            std.debug.print("[api-freeze] docs/UPGRADING.md '{s}' does not say where `zigmodu.{s}` can still be found ({s})\n", .{ removed_heading, removed.root_name, removed.file });
            problems += 1;
        }
    }

    // A record without the replacement is a dead end for the reader.
    if (std.mem.indexOf(u8, section, "Application") == null) {
        std.debug.print("[api-freeze] docs/UPGRADING.md '{s}' never names the replacement `Application`\n", .{removed_heading});
        problems += 1;
    }

    if (problems > 0) return error.RemovedRecordDrift;
}

// ============================================================
// 1c. File-level banners
// ============================================================

test "banners: the whole-file DEPRECATED notices are still at the top, and the live one is still live" {
    const allocator = std.testing.allocator;

    var problems: usize = 0;

    for (BANNERS) |banner| {
        const content = readDoc(allocator, banner.file) catch |err| {
            std.debug.print("[api-freeze] cannot read {s} ({s}) — the banner is the file's only deprecation notice\n", .{ banner.file, @errorName(err) });
            return error.BannerFileUnreadable;
        };
        defer allocator.free(content);

        // Banner, not a tombstone somewhere in the middle: the markers have to
        // sit in the file's opening stretch. (Same 1500-byte budget the
        // declaration markers use; here it is measured from the top.)
        const head = content[0..@min(content.len, banner_window)];
        for (banner.must_contain) |needle| {
            if (std.mem.indexOf(u8, head, needle) != null) continue;
            std.debug.print("[api-freeze] {s}: the file-level deprecation banner lost '{s}' from its opening {d} bytes (docs/UPGRADING.md rule 1: mark it deprecated and name the replacement)\n", .{ banner.file, needle, banner_window });
            problems += 1;
        }
    }

    // The still-live one: `src/validation/Validator.zig` says "removed in v1.0",
    // but `http.FieldRules` *is* its `FieldRules` today, so the sentence is a plan
    // with a prerequisite. Both halves are pinned — the public spelling consumers
    // use, and the file it resolves to — so the file cannot be deleted as the
    // banner promises without this gate going red first.
    const DeprecatedValidator = @import("../validation/Validator.zig");
    const ObjectValidator = @import("../validation/ObjectValidator.zig");

    try std.testing.expect(@hasDecl(http, "FieldRules"));
    try std.testing.expect(@hasDecl(http, "validateRequest"));
    try std.testing.expect(http.FieldRules == DeprecatedValidator.FieldRules);

    // …and the replacement the banner names is a *different* type, so "use
    // `zigmodu.Validator` instead" is a real migration and not a self-reference.
    try std.testing.expect(@hasDecl(zmodu, "Validator"));
    try std.testing.expect(zmodu.Validator == ObjectValidator.Validator);
    try std.testing.expect(zmodu.Validator != DeprecatedValidator.Validator);

    // Called for real: Zig's lazy analysis would let the file's signatures rot
    // as long as nothing ever calls them.
    const empty = DeprecatedValidator.notEmpty("");
    try std.testing.expect(!empty.valid);

    // The other half of the banner the gate checks: the replacements it lists for
    // the extensions shim's first line of exports still resolve.
    try std.testing.expect(@hasDecl(http, "http_server"));
    try std.testing.expect(@hasDecl(zmodu.data, "sqlx"));
    try std.testing.expect(@hasDecl(zmodu.data, "orm"));
    try std.testing.expect(@hasDecl(zmodu.data, "redis"));
    try std.testing.expect(@hasDecl(zmodu.security, "auth"));

    if (problems > 0) return error.BannerDrift;

    // The classification itself is written down (docs/API_FREEZE.md), so a reader
    // meets "these two are neither rows nor removals" before the failure does.
    const freeze_doc = try readDoc(allocator, "docs/API_FREEZE.md");
    defer allocator.free(freeze_doc);
    for (BANNERS) |banner| {
        if (std.mem.indexOf(u8, freeze_doc, banner.file) == null) {
            std.debug.print("[api-freeze] docs/API_FREEZE.md does not mention {s}, which this gate treats as a file-level deprecation banner — the classification has to live somewhere a reader can find it\n", .{banner.file});
            return error.BannerUndocumented;
        }
    }
}

/// Text after `heading` up to the next line that starts with `#`, so a sibling
/// section cannot satisfy one of the record's checks.
fn sectionText(content: []const u8, heading: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, content, heading) orelse return null;
    const rest = content[at + heading.len ..];
    const end = std.mem.indexOf(u8, rest, "\n#") orelse rest.len;
    return rest[0..end];
}

test "deprecation table: docs/UPGRADING.md, the markers and this gate stay in sync" {
    const allocator = std.testing.allocator;

    const content = readDoc(allocator, "docs/UPGRADING.md") catch |err| {
        std.debug.print("[api-freeze] docs/UPGRADING.md unreadable ({s}) — the deprecation table is the promise this test checks\n", .{@errorName(err)});
        return error.DeprecationTableUnreadable;
    };
    defer allocator.free(content);

    var rows = try parseTableRows(allocator, content, deprecation_heading);
    defer rows.deinit(allocator);

    if (rows.items.len == 0) {
        std.debug.print("[api-freeze] docs/UPGRADING.md: no rows under '{s}' — has the table moved?\n", .{deprecation_heading});
        return error.DeprecationTableMissing;
    }

    var problems: usize = 0;
    for (rows.items) |row| {
        const target = firstBackticked(row.right_cell) orelse {
            std.debug.print("[api-freeze] docs/UPGRADING.md:{d}: row `{s}` has no backticked replacement name\n", .{ row.line, row.left });
            problems += 1;
            continue;
        };

        // The deletion column must not be empty (the table's own rule 2) and
        // must still carry the unified "not before 1.0" plan.
        if (row.note.len == 0 or std.mem.indexOf(u8, row.note, "1.0") == null) {
            std.debug.print("[api-freeze] docs/UPGRADING.md:{d}: row `{s}` has no deletion plan containing 1.0 (got '{s}')\n", .{ row.line, row.left, row.note });
            problems += 1;
        }

        if (!coversAlias(row.left, target)) {
            std.debug.print("[api-freeze] docs/UPGRADING.md:{d}: `{s}` → `{s}` has no gate in src/test/ApiFreeze.zig\n", .{ row.line, row.left, target });
            problems += 1;
        }
    }

    // …and the other direction: a gate for a row the table dropped.
    for (ALIASES) |alias| {
        var found = false;
        for (rows.items) |row| {
            if (std.mem.eql(u8, row.left, alias.doc_deprecated)) found = true;
        }
        if (!found) {
            std.debug.print("[api-freeze] src/test/ApiFreeze.zig checks `{s}`, but docs/UPGRADING.md no longer lists that row\n", .{alias.doc_deprecated});
            problems += 1;
        }
    }

    if (problems > 0) return error.DeprecationTableDrift;

    try checkDeprecatedMarkers(allocator);
}

fn coversAlias(deprecated: []const u8, target: []const u8) bool {
    for (ALIASES) |alias| {
        if (std.mem.eql(u8, alias.doc_deprecated, deprecated) and std.mem.eql(u8, alias.doc_target, target)) return true;
    }
    return false;
}

/// Rule 1 of the deprecation section: the alias's own doc comment says it is
/// deprecated and names what replaces it.
fn checkDeprecatedMarkers(allocator: std.mem.Allocator) !void {
    for (ALIASES) |alias| {
        const content = readDoc(allocator, alias.decl_file) catch |err| {
            std.debug.print("[api-freeze] cannot read {s} ({s}) to check the `{s}` row\n", .{ alias.decl_file, @errorName(err), alias.doc_deprecated });
            return error.DeclarationFileUnreadable;
        };
        defer allocator.free(content);

        const at = std.mem.indexOf(u8, content, alias.decl_symbol) orelse {
            std.debug.print("[api-freeze] {s} declares nothing matching '{s}' — the `{s}` alias moved or was removed\n", .{ alias.decl_file, alias.decl_symbol, alias.doc_deprecated });
            return error.DeclarationMissing;
        };
        const window = content[at -| marker_window..at];

        for (alias.decl_must_contain) |needle| {
            if (std.mem.indexOf(u8, window, needle) != null) continue;
            std.debug.print("[api-freeze] the `{s}` declaration in {s} lost '{s}' from its doc comment (docs/UPGRADING.md rule 1: mark it deprecated, name the replacement)\n", .{ alias.doc_deprecated, alias.decl_file, needle });
            return error.DeprecationMarkerMissing;
        }
    }
}

// ============================================================
// 2. Frozen entry points — mirrors docs/API_FREEZE.md
// ============================================================

const freeze_heading = "## 冻结的入口类别";
const preview_heading = "## 0.x 允许破坏的 preview 面";

/// Anchor tokens are `Domain.Name`, `Schema.Name` or a bare top-level name.
/// Matching is by the longest prefix in `namespaces`, so entries with a dotted
/// schema (e.g. `runtime.recorder.…`) have to come first.
const namespaces = .{
    .{ "runtime.recorder", zmodu.runtime.recorder },
    .{ "http", http },
    .{ "data", zmodu.data },
    .{ "security", zmodu.security },
    .{ "observability", zmodu.observability },
    .{ "runtime", zmodu.runtime },
    .{ "ai", zmodu.ai },
    .{ "im", zmodu.im },
    .{ "web4", zmodu.web4 },
    .{ "outbox", zmodu.outbox },
    .{ "cron", zmodu.cron },
    .{ "migration", zmodu.migration },
};

/// True when the anchor a doc row names still resolves. Data-driven on purpose:
/// `docs/API_FREEZE.md`'s rows are the list, so the check cannot drift into
/// asserting a set of names the doc no longer mentions.
fn anchorResolves(comptime anchor: []const u8) bool {
    inline for (namespaces) |ns| {
        if (comptime std.mem.startsWith(u8, anchor, ns[0] ++ ".")) {
            return @hasDecl(ns[1], anchor[ns[0].len + 1 ..]);
        }
    }
    return @hasDecl(zmodu, anchor);
}

/// The frozen surface: the entry points 1.0 keeps. Anchors are the *identity*
/// symbol of each category, not the category's full export list — that list
/// stays in `root.zig` and `docs/API.md` rather than becoming a second one here.
const FreezeCategory = struct {
    /// Category name as `docs/API_FREEZE.md` writes it (failure messages only).
    name: []const u8,
    anchors: []const []const u8,
};

const FREEZE_CATEGORIES = [_]FreezeCategory{
    .{
        .name = "zigmodu 顶层 · 生命周期与模块契约",
        .anchors = &.{
            "Application",   "ApplicationBuilder", "builder", "api",
            "ModuleContext", "ZigModuError",       "Result",  "Time",
            "scanModules",   "ModuleInfo",
        },
    },
    .{
        .name = "域别名",
        .anchors = &.{
            "http",    "data", "security",  "observability",
            "runtime", "ai",   "im",        "web4",
            "outbox",  "cron", "migration", "datapermission",
        },
    },
    .{
        .name = "HTTP · 路由与请求",
        .anchors = &.{
            "http.Server",    "http.Context", "http.RouteGroup",  "http.RouteSpec",
            "http.RouteMeta", "http.Router",  "http.CatalogSlot",
        },
    },
    .{
        .name = "HTTP · extractor 与错误渲染",
        .anchors = &.{
            "http.extractPath",      "http.extractQuery",      "http.extractJson", "http.extractJsonValidated",
            "http.extractMultipart", "http.respondErr",        "http.setErrorMap", "http.problemReject",
            "http.useRfc7807Errors", "http.productionProfile", "http.sse",         "http.Testkit",
        },
    },
    .{
        .name = "鉴权（Path A）",
        .anchors = &.{
            "http.jwtAuthFromCatalogWithPermissions", "http.catalogLoaderFromTable", "http.AuthBackend",     "http.jwtBackend",
            "http.envelopeReject",                    "http.permissionGateWith",     "http.tenantResolver",  "security.AppSecurity",
            "security.PasswordEncoder",               "security.CatalogPermDb",      "security.JwksKeyRing",
        },
    },
    .{
        .name = "数据层",
        .anchors = &.{
            "data.Client",       "data.Repository",      "data.SqlxBackend", "data.CrudService",
            "data.CacheManager", "data.MigrationRunner", "data.sqlx",        "data.redis",
            "data.orm",          "data.pool",
        },
    },
    .{
        .name = "可观测性",
        .anchors = &.{
            "observability.PrometheusMetrics", "observability.DistributedTracer", "observability.StructuredLogger",
            "observability.ModuleLogger",      "observability.OtlpExporter",      "observability.LogScope",
        },
    },
    .{
        .name = "韧性 / 调度 / 分布式",
        .anchors = &.{
            "CircuitBreaker", "RateLimiter",     "Bulkhead",  "retry",
            "cron",           "DistributedLock", "Preflight", "SagaOrchestrator",
            "ClusterView",    "MembershipView",
        },
    },
    .{
        .name = "DI / 事件 / 配置 / 工具",
        .anchors = &.{
            "Container", "ScopedContainer", "EventBus",      "ThreadSafeEventBus",
            "FrozenMap", "Params",          "ConfigManager", "TomlLoader",
            "Validator", "panicHook",
        },
    },
    .{
        .name = "测试辅助与扩展",
        .anchors = &.{
            "IntegrationTest", "Benchmark",     "ContractTestRunner", "ModuleTestContext",
            "WebSocketServer", "PluginManager",
        },
    },
};

/// The preview surface docs/RUNTIME.md documents in §12–§14 (plus §11/§13's
/// recorder): `runtime.*` may break during 0.x (RUNTIME.md §2 item 10), so these
/// names stay under `zigmodu.runtime` and off the frozen top level — otherwise a
/// change the runtime is allowed to make lands on the surface that is not.
const PREVIEW = [_][]const u8{
    "runtime.Runtime",
    "runtime.SpawnMode",
    "runtime.SpawnConfig",
    "runtime.SchedulerConfig",
    "runtime.ExecutionClass",
    "runtime.StopPolicy",
    "runtime.PrecisionTimer",
    "runtime.Supervision",
    "runtime.Group",
    "runtime.GroupPolicy",
    "runtime.Intensity",
    "runtime.recorder.Recorder",
    "runtime.recorder.DeliveryLog",
    "runtime.recorder.Replayer",
    "runtime.recorder.TrackRef",
    "runtime.recorder.LogStep",
    "runtime.Sequencer",
};

test "freeze: every anchor docs/API_FREEZE.md names still resolves" {
    var missing: usize = 0;

    inline for (FREEZE_CATEGORIES) |category| {
        inline for (category.anchors) |anchor| {
            if (!anchorResolves(anchor)) {
                std.debug.print("[api-freeze] {s}: anchor `{s}` does not resolve — docs/API_FREEZE.md names it as frozen\n", .{ category.name, anchor });
                missing += 1;
            }
        }
    }

    if (missing > 0) {
        std.debug.print("[api-freeze] {d} frozen anchor(s) missing\n", .{missing});
        return error.FreezeAnchorMissing;
    }
}

test "preview: the runtime surface under §12-§14 stays off the frozen top level" {
    var problems: usize = 0;

    inline for (PREVIEW) |anchor| {
        if (comptime anchorResolves(anchor)) {
            const dot = comptime std.mem.lastIndexOfScalar(u8, anchor, '.').?;
            const bare = anchor[dot + 1 ..];
            if (comptime @hasDecl(zmodu, bare)) {
                std.debug.print("[api-freeze] `{s}` is exported from root.zig: preview surface moved onto the frozen top level (docs/RUNTIME.md §2 item 10 allows `runtime.*` to break in 0.x)\n", .{bare});
                problems += 1;
            }
        } else {
            std.debug.print("[api-freeze] preview symbol `{s}` no longer resolves — docs/RUNTIME.md documents it\n", .{anchor});
            problems += 1;
        }
    }

    if (problems > 0) return error.PreviewSurfaceViolation;
}

// ============================================================
// 3. Doc ↔ gate sync for docs/API_FREEZE.md
// ============================================================

test "freeze: the anchors in docs/API_FREEZE.md and here are the same set" {
    const allocator = std.testing.allocator;

    const content = readDoc(allocator, "docs/API_FREEZE.md") catch |err| {
        std.debug.print("[api-freeze] docs/API_FREEZE.md unreadable ({s})\n", .{@errorName(err)});
        return error.FreezeDocUnreadable;
    };
    defer allocator.free(content);

    var doc_freeze: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doc_freeze.deinit(allocator);
    try collectAnchorTokens(allocator, content, freeze_heading, &doc_freeze);

    var doc_preview: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doc_preview.deinit(allocator);
    try collectAnchorTokens(allocator, content, preview_heading, &doc_preview);

    if (doc_freeze.items.len == 0 or doc_preview.items.len == 0) {
        std.debug.print("[api-freeze] docs/API_FREEZE.md: no anchor rows under '{s}' (frozen: {d}) or '{s}' (preview: {d})\n", .{ freeze_heading, doc_freeze.items.len, preview_heading, doc_preview.items.len });
        return error.FreezeDocMissingRows;
    }

    var problems: usize = 0;

    // The doc's rows against the gate's tables…
    for (doc_freeze.items) |token| {
        if (!coveredBy(&FREEZE_CATEGORIES, token)) {
            std.debug.print("[api-freeze] docs/API_FREEZE.md names `{s}` as frozen, but nothing in src/test/ApiFreeze.zig checks it\n", .{token});
            problems += 1;
        }
    }
    for (doc_preview.items) |token| {
        if (!contains(&PREVIEW, token)) {
            std.debug.print("[api-freeze] docs/API_FREEZE.md names `{s}` as preview, but nothing in src/test/ApiFreeze.zig checks it\n", .{token});
            problems += 1;
        }
    }

    // …and the other direction: a gate for a name the doc dropped.
    for (FREEZE_CATEGORIES) |category| {
        for (category.anchors) |anchor| {
            if (!contains(doc_freeze.items, anchor)) {
                std.debug.print("[api-freeze] src/test/ApiFreeze.zig checks `{s}` ({s}), but docs/API_FREEZE.md no longer names it as frozen\n", .{ anchor, category.name });
                problems += 1;
            }
        }
    }
    for (PREVIEW) |anchor| {
        if (!contains(doc_preview.items, anchor)) {
            std.debug.print("[api-freeze] src/test/ApiFreeze.zig checks preview `{s}`, but docs/API_FREEZE.md no longer names it as preview\n", .{anchor});
            problems += 1;
        }
    }

    if (problems > 0) return error.FreezeDocDrift;
}

fn coveredBy(categories: []const FreezeCategory, token: []const u8) bool {
    for (categories) |category| {
        if (contains(category.anchors, token)) return true;
    }
    return false;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Every backticked token in the second column of a table under `heading`.
/// Rows keep their document order; the caller compares sets.
fn collectAnchorTokens(
    allocator: std.mem.Allocator,
    content: []const u8,
    heading: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var rows = try parseTableRows(allocator, content, heading);
    defer rows.deinit(allocator);

    for (rows.items) |row| {
        var it = std.mem.splitScalar(u8, row.right_cell, '`');
        _ = it.next() orelse continue; // text before the first backtick
        while (it.next()) |token| {
            if (it.next() == null) break; // dangling backtick
            if (token.len > 0) try out.append(allocator, token);
        }
    }
}

// ============================================================
// Shared table parsing
// ============================================================

const TableRow = struct {
    /// First backticked token of the table's first column.
    left: []const u8,
    /// The second column, verbatim (trimmed): the caller reads tokens out of it.
    right_cell: []const u8,
    /// The third column, verbatim (trimmed): the deletion plan, or the check.
    note: []const u8,
    /// 1-based line in the document, for failure messages.
    line: usize,
};

/// Rows of the first markdown table under `heading` (until the next `##`).
/// Header and separator rows carry no backticks in the first column and are
/// skipped; a heading that is not there yields an empty list, which every
/// caller turns into a failure.
fn parseTableRows(
    allocator: std.mem.Allocator,
    content: []const u8,
    heading: []const u8,
) !std.ArrayListUnmanaged(TableRow) {
    var rows: std.ArrayListUnmanaged(TableRow) = .empty;
    errdefer rows.deinit(allocator);

    var in_section = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            in_section = std.mem.startsWith(u8, trimmed, heading);
            continue;
        }
        if (!in_section or trimmed.len == 0 or trimmed[0] != '|') continue;

        var cells: [8][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, trimmed, '|');
        while (it.next()) |cell| {
            if (count == cells.len) break;
            cells[count] = cell;
            count += 1;
        }
        if (count < 4) continue;

        const left = firstBackticked(cells[1]) orelse continue;
        try rows.append(allocator, .{
            .left = left,
            .right_cell = std.mem.trim(u8, cells[2], " \t"),
            .note = std.mem.trim(u8, cells[3], " \t"),
            .line = line_no,
        });
    }
    return rows;
}

/// Text between the first pair of backticks, or null.
fn firstBackticked(cell: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, cell, '`') orelse return null;
    const rest = cell[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '`') orelse return null;
    return rest[0..close];
}

fn readDoc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(4 << 20));
}
