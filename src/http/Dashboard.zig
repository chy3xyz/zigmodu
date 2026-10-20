//! Built-in human dashboard (`/`, `/dashboard`) plus its JSON feeds
//! (`GET /api/dashboard/*`).
//!
//! Counter semantics — what each rendered number actually counts:
//!   * `stats.modules` / `tests.*` — static numbers the app writes at boot
//!     into `system_info` (the HTTP layer has no module graph / test runner
//!     of its own); `tests.total` is the sum of the three counters.
//!   * `stats.routes` / `stats.middleware` — counted live from the wired
//!     `DataSource.server` on **every** request: routes walk the server's
//!     route trie (`Server.listRoutes`), middleware reads the global chain
//!     length. Both include the dashboard's own 5 routes / the chain that
//!     serves them, and grow for routes registered after the dashboard
//!     mounts (the trie is read, not snapshotted).
//!   * `stats.http` (present only when `DataSource.http_metrics` is wired) —
//!     cumulative request counters plus an in-flight snapshot from
//!     `HttpMetricsCollector`; they include the dashboard's own polling when
//!     the collector middleware sits in the chain. `r2xx`/`r4xx`/`r5xx` are
//!     the collector's status buckets (indices 1/3/4 of its count array).
//!   * `stats.uptime_seconds` — `Time.monotonicNowSeconds() - started_at`;
//!     the app must set `system_info.started_at` at boot, otherwise the
//!     value is meaningless (monotonic-clock origin, not wall time).
//!   * `modules[]` — exactly the `DataSource.modules` slice the app filled
//!     from its module graph; unwired means an empty list — entries are
//!     never fabricated.
//!   * `events` — reserved, always 0: the HTTP layer has no event-bus feed.

const std = @import("std");
const RouteRegistrar = @import("../api/RouteRegistrar.zig").RouteRegistrar;
const builtin = @import("builtin");
const build_options = @import("build_options");
const Time = @import("../core/Time.zig");
const Server = @import("../api/Server.zig");
const Context = Server.Context;
const HttpMetricsCollector = @import("HttpMetrics.zig").HttpMetricsCollector;

/// Framework version, comptime-rendered from `build.zig.zon` (single source of
/// truth) — the dashboard never hardcodes it.
pub const framework_version = std.fmt.comptimePrint("{f}", .{build_options.version});
/// Toolchain version this binary was compiled with.
pub const zig_version = std.fmt.comptimePrint("{f}", .{builtin.zig_version});

/// System information rendered by the dashboard (version, uptime, counters).
pub var system_info = SystemInfo{
    .version = framework_version,
    .zig_version = zig_version,
    .started_at = 0,
    .module_count = 0,
    .test_passed = 0,
    .test_failed = 0,
    .test_skipped = 0,
};

pub const SystemInfo = struct {
    version: []const u8,
    zig_version: []const u8,
    started_at: i64,
    module_count: usize,
    test_passed: usize,
    test_failed: usize,
    test_skipped: usize,
};

/// One application module row rendered by `GET /api/dashboard/modules`.
/// Field names match the wire format (`desc` is the module's one-liner).
pub const ModuleEntry = struct {
    name: []const u8,
    desc: []const u8 = "",
    status: []const u8 = "UP",
    deps: usize = 0,
};

/// Real data feeds the dashboard renders from. Wired via
/// `registerRoutesWith`; every field is optional, and the endpoints degrade
/// to honest zeros / empty lists when a feed is absent — the dashboard never
/// invents values to fill the page.
pub const DataSource = struct {
    /// Live server: `stats.routes` / `stats.middleware` are counted from its
    /// route trie and global middleware chain on every request.
    server: ?*Server.Server = null,
    /// Collector fed by `http.httpMetricsMiddleware`: adds the `stats.http`
    /// block (cumulative request counters + in-flight snapshot).
    http_metrics: ?*HttpMetricsCollector = null,
    /// Application modules, filled by the app from its module graph. The
    /// HTTP layer cannot enumerate modules on its own — without this slice
    /// the modules endpoint truthfully reports an empty list.
    modules: []const ModuleEntry = &.{},
};

/// Dashboard routes: the HTML pages and the JSON endpoints.
/// Register the dashboard routes.
///
/// Accepted form: **a pointer** to anything with
/// `get(path, handler, user_data)` — a `*Scoped` (e.g. `&router.scope("")`).
/// A bare `Server` does not have `get`; runtime registration goes through
/// `Router.scope(...)`, which is what the caller passes here.
///
/// Equivalent to `registerRoutesWith(server_or_group, null)`: the JSON feeds
/// serve `system_info` numbers and zero out every count that needs a live
/// feed. Wire `registerRoutesWith` to get real routes / middleware / request
/// counters / module rows.
pub fn registerRoutes(server_or_group: anytype) !void {
    return registerRoutesWith(server_or_group, null);
}

/// Same routes as `registerRoutes`, but the JSON handlers read their numbers
/// from `source` (routes, middleware, request counters, module rows). The
/// pointer must outlive the server; `source == null` degrades gracefully.
pub fn registerRoutesWith(server_or_group: anytype, source: ?*DataSource) !void {
    const T = @TypeOf(server_or_group);
    if (@typeInfo(T) != .pointer or !@hasDecl(@typeInfo(T).pointer.child, "get")) {
        @compileError("dashboardRoutes expects a *pointer* to something with `get(path, handler, user_data)` (e.g. `&router.scope(\"\")` or `&RouteRegistrar.init(&server, \"\")`); got " ++ @typeName(T));
    }
    const opaque_source: ?*anyopaque = @ptrCast(source);
    // HTML page, served at both "/" and "/dashboard"
    try server_or_group.get("/", handleIndex, null);
    try server_or_group.get("/dashboard", handleIndex, null);

    // API endpoints — the route user_data carries the data feed (null = the
    // handlers fall back to system_info + honest zeros).
    try server_or_group.get("/api/dashboard/modules", handleModules, opaque_source);
    try server_or_group.get("/api/dashboard/stats", handleStats, opaque_source);
    try server_or_group.get("/api/dashboard/system", handleSystem, opaque_source);
}

/// The data feed stashed in the route's `user_data`, if one was wired.
fn sourceFrom(ctx: *Context) ?*DataSource {
    const raw = ctx.user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Handle GET / and GET /dashboard — serve the dashboard HTML page.
fn handleIndex(ctx: *Context) !void {
    try ctx.text(200, DASHBOARD_HTML);
}

/// API: module list — exactly the rows the app wired into `DataSource.modules`
/// (empty list when unwired; entries are never fabricated here).
fn handleModules(ctx: *Context) !void {
    const source = sourceFrom(ctx);
    const modules: []const ModuleEntry = if (source) |s| s.modules else &.{};

    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .modules = modules,
        .count = modules.len,
    }, .{});
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// API: aggregate stats — modules, routes, middleware, uptime, test counters
/// and (when wired) request counters. See the file-top doc for the counting
/// semantics of each field.
fn handleStats(ctx: *Context) !void {
    const now = Time.monotonicNowSeconds();
    const uptime = now - system_info.started_at;
    const source = sourceFrom(ctx);

    var routes: usize = 0;
    var middleware: usize = 0;
    if (source) |s| {
        if (s.server) |srv| {
            const infos = try srv.listRoutes(ctx.allocator);
            routes = infos.len;
            for (infos) |info| {
                ctx.allocator.free(info.method);
                ctx.allocator.free(info.path);
            }
            ctx.allocator.free(infos);
            middleware = srv.global_middleware.items.len;
        }

        if (s.http_metrics) |collector| {
            const snap = collector.snapshot();
            const json = try ctx.allocator.print(
                \\{{"modules":{d},"routes":{d},"middleware":{d},"events":0,"uptime_seconds":{d},"tests":{{"passed":{d},"failed":{d},"skipped":{d},"total":{d}}},"http":{{"requests":{d},"in_flight":{d},"r2xx":{d},"r4xx":{d},"r5xx":{d}}}}}
            , .{
                system_info.module_count,
                routes,
                middleware,
                uptime,
                system_info.test_passed,
                system_info.test_failed,
                system_info.test_skipped,
                system_info.test_passed + system_info.test_failed + system_info.test_skipped,
                snap.request_count,
                snap.in_flight,
                // Status buckets follow HttpMetricsCollector.StatusBucket:
                // 1 = 2xx, 3 = 4xx, 4 = 5xx.
                snap.status_counts[1],
                snap.status_counts[3],
                snap.status_counts[4],
            });
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
            return;
        }
    }

    const json = try ctx.allocator.print(
        \\{{"modules":{d},"routes":{d},"middleware":{d},"events":0,"uptime_seconds":{d},"tests":{{"passed":{d},"failed":{d},"skipped":{d},"total":{d}}}}}
    , .{
        system_info.module_count,
        routes,
        middleware,
        uptime,
        system_info.test_passed,
        system_info.test_failed,
        system_info.test_skipped,
        system_info.test_passed + system_info.test_failed + system_info.test_skipped,
    });
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// API: System information — version, Zig toolchain, OS, uptime. Values are
/// all build-time or monotonic-clock derived; no live feed needed.
fn handleSystem(ctx: *Context) !void {
    const now = Time.monotonicNowSeconds();
    const uptime = now - system_info.started_at;

    const json = try ctx.allocator.print(
        \\{{"version":"{s}","zig":"{s}","started_at":{d},"uptime_seconds":{d},"status":"healthy",
        \\"allocator":"gpa","os":"{s}"}}
    , .{
        system_info.version,
        system_info.zig_version,
        system_info.started_at,
        uptime,
        @tagName(builtin.target.os.tag),
    });
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// Inline dashboard HTML page (Alpine.js + TailwindCSS CDN). The page polls
/// the JSON feeds every 5 s and renders real values — no placeholders.
const DASHBOARD_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en" class="dark">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1.0">
    \\<title>zmodu Dashboard</title>
    \\<script src="https://cdn.tailwindcss.com"></script>
    \\<script>tailwind.config={darkMode:'class'}</script>
    \\<script>
    \\function dash(){
    \\  return {
    \\    dark:true, tab:'overview',
    \\    stats:{modules:0,routes:0,middleware:0,uptime_seconds:0,tests:{passed:0,failed:0,skipped:0,total:0},http:null},
    \\    sys:{version:'',zig:'',os:'',status:''},
    \\    modules:[],
    \\    init(){ this.refresh(); setInterval(()=>this.refresh(),5000); },
    \\    refresh(){
    \\      fetch('/api/dashboard/stats').then(r=>r.json()).then(j=>{this.stats=j;}).catch(()=>{});
    \\      fetch('/api/dashboard/system').then(r=>r.json()).then(j=>{this.sys=j;}).catch(()=>{});
    \\      fetch('/api/dashboard/modules').then(r=>r.json()).then(j=>{this.modules=j.modules;}).catch(()=>{});
    \\    }
    \\  };
    \\}
    \\</script>
    \\<script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.14.9/dist/cdn.min.js"></script>
    \\<style>
    \\  @keyframes pulse-glow { 0%,100% { opacity:1 } 50% { opacity:.6 } }
    \\  .pulse-dot { animation: pulse-glow 2s ease-in-out infinite }
    \\  [x-cloak]{display:none!important}
    \\  .card { @apply bg-white dark:bg-zinc-800 rounded-xl border border-zinc-200 dark:border-zinc-700 p-6 }
    \\  .stat { @apply text-3xl font-bold }
    \\  .stat-label { @apply text-sm text-zinc-500 dark:text-zinc-400 uppercase tracking-wide }
    \\  .badge-up { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200 }
    \\  .badge-warn { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200 }
    \\  .badge-err { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200 }
    \\</style>
    \\</head>
    \\<body class="bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 min-h-screen" x-data="dash()" x-init="init()">
    \\
    \\<!-- Nav -->
    \\<nav class="border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 sticky top-0 z-50">
    \\<div class="max-w-7xl mx-auto px-6 flex items-center justify-between h-16">
    \\  <div class="flex items-center gap-3">
    \\    <span class="text-2xl font-black tracking-tight">⚡ zmodu</span>
++ "    <span class=\"badge-up text-xs\">v" ++ framework_version ++ "</span>\n" ++
    \\  </div>
    \\  <div class="flex items-center gap-4">
    \\    <button @click="dark=!dark;document.documentElement.classList.toggle('dark')"
    \\      class="p-2 rounded-lg hover:bg-zinc-100 dark:hover:bg-zinc-800 transition">🌓</button>
    \\    <span class="text-xs font-semibold" :class="sys.status==='healthy'?'text-emerald-500':'text-zinc-400'"
    \\      x-text="sys.status?'● '+sys.status:'● …'"></span>
    \\  </div>
    \\</div>
    \\</nav>
    \\
    \\<!-- Tabs -->
    \\<div class="max-w-7xl mx-auto px-6 pt-6">
    \\<div class="flex gap-1 bg-zinc-100 dark:bg-zinc-800 rounded-lg p-1 w-fit">
    \\  <button @click="tab='overview'" :class="tab==='overview'?'bg-white dark:bg-zinc-700 shadow-sm':'hover:bg-zinc-200 dark:hover:bg-zinc-700'"
    \\    class="px-4 py-2 rounded-md text-sm font-medium transition">📊 Overview</button>
    \\  <button @click="tab='modules'" :class="tab==='modules'?'bg-white dark:bg-zinc-700 shadow-sm':'hover:bg-zinc-200 dark:hover:bg-zinc-700'"
    \\    class="px-4 py-2 rounded-md text-sm font-medium transition">🧩 Modules</button>
    \\  <button @click="tab='api'" :class="tab==='api'?'bg-white dark:bg-zinc-700 shadow-sm':'hover:bg-zinc-200 dark:hover:bg-zinc-700'"
    \\    class="px-4 py-2 rounded-md text-sm font-medium transition">🔌 API</button>
    \\</div>
    \\</div>
    \\
    \\<!-- Overview Tab -->
    \\<div class="max-w-7xl mx-auto px-6 pt-6" x-show="tab==='overview'" x-cloak>
    \\  <!-- Stats Row -->
    \\  <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
    \\    <div class="card"><div class="stat-label">Modules</div><div class="stat text-emerald-500" x-text="stats.modules"></div></div>
    \\    <div class="card"><div class="stat-label">Tests Passed</div><div class="stat text-emerald-500" x-text="stats.tests.passed"></div></div>
    \\    <div class="card"><div class="stat-label">Tests Failed</div><div class="stat text-red-500" x-text="stats.tests.failed"></div></div>
    \\    <div class="card"><div class="stat-label">Uptime (s)</div><div class="stat text-blue-500" x-text="stats.uptime_seconds"></div></div>
    \\    <div class="card"><div class="stat-label">Requests</div><div class="stat text-emerald-500" x-text="stats.http?stats.http.requests:'—'"></div></div>
    \\    <div class="card"><div class="stat-label">In Flight</div><div class="stat text-amber-500" x-text="stats.http?stats.http.in_flight:'—'"></div></div>
    \\    <div class="card"><div class="stat-label">Routes</div><div class="stat text-zinc-500" x-text="stats.routes"></div></div>
    \\    <div class="card"><div class="stat-label">Middleware</div><div class="stat text-zinc-500" x-text="stats.middleware"></div></div>
    \\  </div>
    \\  <!-- System Info + Health -->
    \\  <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
    \\    <div class="card">
    \\      <div class="stat-label mb-3">System</div>
    \\      <div class="space-y-2 text-sm">
    \\        <div class="flex justify-between"><span class="text-zinc-500">Version</span><span class="font-mono" x-text="sys.version"></span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">Zig</span><span class="font-mono" x-text="sys.zig"></span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">OS</span><span class="font-mono" x-text="sys.os"></span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">Status</span><span class="text-emerald-500 font-semibold" x-text="'● '+(sys.status||'…')"></span></div>
    \\      </div>
    \\    </div>
    \\    <div class="card">
    \\      <div class="stat-label mb-3">Quick Links</div>
    \\      <div class="space-y-2 text-sm">
    \\        <a href="/api/dashboard/modules" class="block text-blue-500 hover:underline">→ API: Modules JSON</a>
    \\        <a href="/api/dashboard/stats" class="block text-blue-500 hover:underline">→ API: Stats JSON</a>
    \\        <a href="/api/dashboard/system" class="block text-blue-500 hover:underline">→ API: System JSON</a>
    \\        <a href="/health/live" class="block text-blue-500 hover:underline">→ Health: Liveness</a>
    \\        <a href="/health/ready" class="block text-blue-500 hover:underline">→ Health: Readiness</a>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
    \\
    \\<!-- Modules Tab -->
    \\<div class="max-w-7xl mx-auto px-6 pt-6" x-show="tab==='modules'" x-cloak>
    \\<div class="card">
    \\  <div class="stat-label mb-3">Modules</div>
    \\  <div x-show="modules.length===0" class="text-sm text-zinc-500">No modules reported — the app has not wired <code>DataSource.modules</code>.</div>
    \\  <table class="w-full text-sm" x-show="modules.length>0">
    \\    <thead><tr class="text-left text-zinc-500 border-b border-zinc-200 dark:border-zinc-700">
    \\      <th class="py-2 pr-4 font-medium">Name</th><th class="py-2 pr-4 font-medium">Description</th>
    \\      <th class="py-2 pr-4 font-medium">Status</th><th class="py-2 font-medium">Deps</th>
    \\    </tr></thead>
    \\    <tbody>
    \\      <template x-for="m in modules" :key="m.name">
    \\        <tr class="border-b border-zinc-100 dark:border-zinc-800">
    \\          <td class="py-2 pr-4 font-mono" x-text="m.name"></td>
    \\          <td class="py-2 pr-4" x-text="m.desc"></td>
    \\          <td class="py-2 pr-4"><span class="badge-up" x-text="m.status"></span></td>
    \\          <td class="py-2" x-text="m.deps"></td>
    \\        </tr>
    \\      </template>
    \\    </tbody>
    \\  </table>
    \\</div>
    \\</div>
    \\
    \\<!-- API Tab -->
    \\<div class="max-w-7xl mx-auto px-6 pt-6" x-show="tab==='api'" x-cloak>
    \\<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    \\  <div class="card"><div class="stat-label mb-2">GET /api/dashboard/modules</div><code class="text-xs text-zinc-400">Module rows from DataSource.modules</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /api/dashboard/stats</div><code class="text-xs text-zinc-400">Counts: routes, middleware, tests, http counters</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /api/dashboard/system</div><code class="text-xs text-zinc-400">Version, Zig version, OS, status</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /health/live</div><code class="text-xs text-zinc-400">K8s liveness probe</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /health/ready</div><code class="text-xs text-zinc-400">K8s readiness probe</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /health/modules</div><code class="text-xs text-zinc-400">Per-module health status</code></div>
    \\</div>
    \\</div>
    \\
    \\<!-- Footer -->
    \\<footer class="max-w-7xl mx-auto px-6 py-8 mt-12 border-t border-zinc-200 dark:border-zinc-800">
    \\<div class="flex justify-between text-xs text-zinc-400">
++ "  <span>zmodu v" ++ framework_version ++ " · Zig " ++ zig_version ++ "</span>\n" ++
    \\  <span>Dashboard · Alpine.js + TailwindCSS</span>
    \\</div>
    \\</footer>
    \\
    \\</body>
    \\</html>
;

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "SystemInfo defaults" {
    // Defaults track build.zig.zon / the toolchain, never a hardcoded string.
    try std.testing.expectEqualStrings(framework_version, system_info.version);
    try std.testing.expectEqualStrings(zig_version, system_info.zig_version);
    try std.testing.expect(std.mem.indexOfScalar(u8, framework_version, '.') != null);
}

test "Dashboard HTML is valid" {
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "alpinejs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "tailwindcss"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "zmodu Dashboard"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/modules"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/stats"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/system"));
    // The page renders real values fetched from the JSON feeds — no leftover
    // format placeholders, no HTMX attrs swapping raw JSON into the DOM.
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "fetch('/api/dashboard/stats')"));
    try std.testing.expect(std.mem.indexOf(u8, DASHBOARD_HTML, "{d}") == null);
    try std.testing.expect(std.mem.indexOf(u8, DASHBOARD_HTML, "hx-get") == null);
    // Badge + footer render the build-time version, not a stale literal.
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 2, framework_version));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, zig_version));
}

test "SystemInfo update" {
    const prev_modules = system_info.module_count;
    const prev_passed = system_info.test_passed;
    system_info.module_count = 42;
    system_info.test_passed = 329;

    try std.testing.expectEqual(@as(usize, 42), system_info.module_count);
    try std.testing.expectEqual(@as(usize, 329), system_info.test_passed);

    system_info.module_count = prev_modules;
    system_info.test_passed = prev_passed;
}

const Testkit = @import("Testkit.zig");

const StatsDoc = struct {
    modules: usize,
    routes: usize,
    middleware: usize,
    uptime_seconds: i64,
    tests: struct { passed: usize, failed: usize, skipped: usize, total: usize },
    http: ?struct { requests: u64, in_flight: u64, r2xx: u64, r4xx: u64, r5xx: u64 } = null,
};

test "dashboard stats serve real route and middleware counts" {
    const allocator = std.testing.allocator;
    var server = Server.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    try server.addRoute(.{ .method = .GET, .path = "/hello", .handler = struct {
        fn handle(ctx: *Context) !void {
            try ctx.text(200, "hi");
        }
    }.handle });

    var source = DataSource{ .server = &server };
    var group = RouteRegistrar.init(&server, "");
    try registerRoutesWith(&group, &source);

    var resp = try Testkit.dispatch(&server, .GET, "/api/dashboard/stats", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);

    const parsed = try std.json.parseFromSlice(StatsDoc, allocator, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    // 5 dashboard routes (/, /dashboard, 3 API feeds) + the /hello route above.
    try std.testing.expectEqual(@as(usize, 6), parsed.value.routes);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.middleware);
    // The wire fields stay part of the documented shape even with no source
    // wired: uptime counts from started_at=0 (monotonic seconds) and the
    // tests block sums its three counters.
    try std.testing.expect(parsed.value.uptime_seconds >= 0);
    try std.testing.expectEqual(
        parsed.value.tests.passed + parsed.value.tests.failed + parsed.value.tests.skipped,
        parsed.value.tests.total,
    );
}

test "dashboard stats include http counters when wired" {
    const allocator = std.testing.allocator;
    var server = Server.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var collector = HttpMetricsCollector.init();
    collector.recordRequest(200, 0.010);
    collector.recordRequest(201, 0.010);
    collector.recordRequest(404, 0.005);
    collector.recordRequest(500, 0.100);

    var source = DataSource{ .server = &server, .http_metrics = &collector };
    var group = RouteRegistrar.init(&server, "");
    try registerRoutesWith(&group, &source);

    var resp = try Testkit.dispatch(&server, .GET, "/api/dashboard/stats", null);
    defer resp.deinit(allocator);

    const parsed = try std.json.parseFromSlice(StatsDoc, allocator, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const http = parsed.value.http orelse return error.NoHttpBlock;
    try std.testing.expectEqual(@as(u64, 4), http.requests);
    try std.testing.expectEqual(@as(u64, 2), http.r2xx);
    try std.testing.expectEqual(@as(u64, 1), http.r4xx);
    try std.testing.expectEqual(@as(u64, 1), http.r5xx);
    // The stats request itself never ran through the collector middleware,
    // so in-flight stays untouched.
    try std.testing.expectEqual(@as(u64, 0), http.in_flight);
}

test "dashboard without source reports honest zeros" {
    const allocator = std.testing.allocator;
    var server = Server.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var group = RouteRegistrar.init(&server, "");
    try registerRoutes(&group);

    var resp = try Testkit.dispatch(&server, .GET, "/api/dashboard/stats", null);
    defer resp.deinit(allocator);
    const parsed = try std.json.parseFromSlice(StatsDoc, allocator, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.routes);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.middleware);
    try std.testing.expect(parsed.value.http == null);

    var mresp = try Testkit.dispatch(&server, .GET, "/api/dashboard/modules", null);
    defer mresp.deinit(allocator);
    try std.testing.expect(std.mem.containsAtLeast(u8, mresp.body, 1, "\"count\":0"));
}

test "dashboard modules endpoint renders wired entries with escaping" {
    const allocator = std.testing.allocator;
    var server = Server.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const modules = [_]ModuleEntry{
        .{ .name = "order", .desc = "Order \"core\" svc", .status = "UP", .deps = 2 },
        .{ .name = "user", .desc = "Users & auth", .deps = 0 },
    };
    var source = DataSource{ .modules = &modules };
    var group = RouteRegistrar.init(&server, "");
    try registerRoutesWith(&group, &source);

    var resp = try Testkit.dispatch(&server, .GET, "/api/dashboard/modules", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    // The quote in the description must be escaped on the wire.
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\\\""));

    const ModulesDoc = struct {
        modules: []const ModuleEntry,
        count: usize,
    };
    const parsed = try std.json.parseFromSlice(ModulesDoc, allocator, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.count);
    try std.testing.expectEqualStrings("order", parsed.value.modules[0].name);
    try std.testing.expectEqualStrings("Order \"core\" svc", parsed.value.modules[0].desc);
    try std.testing.expectEqualStrings("Users & auth", parsed.value.modules[1].desc);
}
