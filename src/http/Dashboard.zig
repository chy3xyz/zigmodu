const std = @import("std");
const Time = @import("../core/Time.zig");
const Server = @import("../api/Server.zig");
const Context = Server.Context;
const HandlerFn = Server.HandlerFn;

/// System information ([...])
pub var system_info = SystemInfo{
    .version = "0.8.0",
    .zig_version = "0.16.0",
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

/// [...] Dashboard [...] HTTP Server
pub fn registerRoutes(server_or_group: anytype) !void {
    // HTML [...]
    try server_or_group.get("/", handleIndex, null);
    try server_or_group.get("/dashboard", handleIndex, null);

    // API endpoint
    try server_or_group.get("/api/dashboard/modules", handleModules, null);
    try server_or_group.get("/api/dashboard/stats", handleStats, null);
    try server_or_group.get("/api/dashboard/system", handleSystem, null);
}

/// Dashboard HTML [...]
fn handleIndex(ctx: *Context) !void {
    try ctx.text(200, DASHBOARD_HTML);
}

/// API: Module list
fn handleModules(ctx: *Context) !void {
    if (system_info.module_count == 0) {
        try ctx.json(200, "{\"modules\":[],\"count\":0}");
        return;
    }

    const json = try std.fmt.allocPrint(ctx.allocator,
        \\{{"modules":[
        \\  {{"name":"core","desc":"Core framework","status":"UP","deps":0}},
        \\  {{"name":"http","desc":"HTTP server & API","status":"UP","deps":2}},
        \\  {{"name":"resilience","desc":"Circuit breaker, rate limiter","status":"UP","deps":1}},
        \\  {{"name":"metrics","desc":"Prometheus metrics","status":"UP","deps":2}},
        \\  {{"name":"tracing","desc":"Distributed tracing","status":"UP","deps":1}},
        \\  {{"name":"security","desc":"JWT, RBAC, scanner","status":"UP","deps":2}},
        \\  {{"name":"migration","desc":"DB migrations","status":"UP","deps":0}},
        \\  {{"name":"secrets","desc":"Secrets management","status":"UP","deps":0}},
        \\  {{"name":"grpc","desc":"gRPC transport","status":"UP","deps":1}},
        \\  {{"name":"kafka","desc":"Kafka connector","status":"UP","deps":1}},
        \\  {{"name":"saga","desc":"Saga orchestrator","status":"UP","deps":1}},
        \\  {{"name":"cache","desc":"Cache aside + LRU","status":"UP","deps":0}},
        \\  {{"name":"sqlx","desc":"PG/MySQL/SQLite","status":"UP","deps":0}}
        \\],"count":13}}
    );
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// API: [...]
fn handleStats(ctx: *Context) !void {
    const now = Time.monotonicNowSeconds();
    const uptime = now - system_info.started_at;

    const json = try std.fmt.allocPrint(ctx.allocator,
        \\{{"modules":{d},"routes":15,"middleware":8,"events":0,"uptime_seconds":{d},"tests":
        \\{{"passed":{d},"failed":{d},"skipped":{d},"total":{d}}}}}
    , .{
        system_info.module_count,
        uptime,
        system_info.test_passed,
        system_info.test_failed,
        system_info.test_skipped,
        system_info.test_passed + system_info.test_failed + system_info.test_skipped,
    });
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// API: System information
fn handleSystem(ctx: *Context) !void {
    const now = Time.monotonicNowSeconds();
    const uptime = now - system_info.started_at;

    const json = try std.fmt.allocPrint(ctx.allocator,
        \\{{"version":"{s}","zig":"{s}","started_at":{d},"uptime_seconds":{d},"status":"healthy",
        \\"allocator":"gpa","os":"{s}"}}
    , .{
        system_info.version,
        system_info.zig_version,
        system_info.started_at,
        uptime,
        @tagName(@import("builtin").os.tag),
    });
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

/// [...] Dashboard HTML (HTMX + Alpine.js + TailwindCSS CDN)
const DASHBOARD_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en" class="dark">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1.0">
    \\<title>ZigModu Dashboard</title>
    \\<script src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.4/dist/htmx.min.js"></script>
    \\<script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.14.9/dist/cdn.min.js"></script>
    \\<script src="https://cdn.tailwindcss.com"></script>
    \\<script>tailwind.config={darkMode:'class'}</script>
    \\<style>
    \\  @keyframes pulse-glow { 0%,100% { opacity:1 } 50% { opacity:.6 } }
    \\  .pulse-dot { animation: pulse-glow 2s ease-in-out infinite }
    \\  .card { @apply bg-white dark:bg-zinc-800 rounded-xl border border-zinc-200 dark:border-zinc-700 p-6 }
    \\  .stat { @apply text-3xl font-bold }
    \\  .stat-label { @apply text-sm text-zinc-500 dark:text-zinc-400 uppercase tracking-wide }
    \\  .badge-up { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200 }
    \\  .badge-warn { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200 }
    \\  .badge-err { @apply inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200 }
    \\</style>
    \\</head>
    \\<body class="bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 min-h-screen" x-data="{dark:true,tab:'overview'}">
    \\
    \\<!-- Nav -->
    \\<nav class="border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 sticky top-0 z-50">
    \\<div class="max-w-7xl mx-auto px-6 flex items-center justify-between h-16">
    \\  <div class="flex items-center gap-3">
    \\    <span class="text-2xl font-black tracking-tight">⚡ ZigModu</span>
    \\    <span class="badge-up text-xs">v0.8.0</span>
    \\  </div>
    \\  <div class="flex items-center gap-4">
    \\    <button @click="dark=!dark;document.documentElement.classList.toggle('dark')"
    \\      class="p-2 rounded-lg hover:bg-zinc-100 dark:hover:bg-zinc-800 transition">🌓</button>
    \\    <span class="text-xs text-zinc-400" hx-get="/api/dashboard/system" hx-trigger="every 10s" hx-swap="innerHTML">
    \\      Loading...
    \\    </span>
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
    \\  <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6" hx-get="/api/dashboard/stats" hx-trigger="every 5s" hx-swap="innerHTML">
    \\    <div class="card"><div class="stat-label">Modules</div><div class="stat text-emerald-500">{d}</div></div>
    \\    <div class="card"><div class="stat-label">Tests Passed</div><div class="stat text-emerald-500">{d}</div></div>
    \\    <div class="card"><div class="stat-label">Tests Failed</div><div class="stat text-red-500">{d}</div></div>
    \\    <div class="card"><div class="stat-label">Uptime (s)</div><div class="stat text-blue-500">{d}</div></div>
    \\  </div>
    \\  <!-- System Info + Health -->
    \\  <div class="grid grid-cols-1 md:grid-cols-2 gap-6" hx-get="/api/dashboard/system" hx-trigger="every 10s" hx-swap="innerHTML">
    \\    <div class="card">
    \\      <div class="stat-label mb-3">System</div>
    \\      <div class="space-y-2 text-sm">
    \\        <div class="flex justify-between"><span class="text-zinc-500">Version</span><span class="font-mono">{s}</span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">Zig</span><span class="font-mono">{s}</span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">OS</span><span class="font-mono">{s}</span></div>
    \\        <div class="flex justify-between"><span class="text-zinc-500">Status</span><span class="text-emerald-500 font-semibold">● {s}</span></div>
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
    \\<div hx-get="/api/dashboard/modules" hx-trigger="every 10s" hx-swap="innerHTML">
    \\  <div class="card"><div class="stat-label">Loading modules...</div></div>
    \\</div>
    \\</div>
    \\
    \\<!-- API Tab -->
    \\<div class="max-w-7xl mx-auto px-6 pt-6" x-show="tab==='api'" x-cloak>
    \\<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    \\  <div class="card"><div class="stat-label mb-2">GET /api/dashboard/modules</div><code class="text-xs text-zinc-400">List all modules with status</code></div>
    \\  <div class="card"><div class="stat-label mb-2">GET /api/dashboard/stats</div><code class="text-xs text-zinc-400">Test stats, uptime, counts</code></div>
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
    \\  <span>ZigModu v0.8.0 · Zig 0.16.0</span>
    \\  <span>Dashboard · HTMX + Alpine.js + TailwindCSS</span>
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
    try std.testing.expectEqualStrings("0.8.0", system_info.version);
    try std.testing.expectEqualStrings("0.16.0", system_info.zig_version);
}

test "Dashboard HTML is valid" {
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "htmx"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "alpinejs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "tailwindcss"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "ZigModu Dashboard"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/modules"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/stats"));
    try std.testing.expect(std.mem.containsAtLeast(u8, DASHBOARD_HTML, 1, "/api/dashboard/system"));
}

test "SystemInfo update" {
    const prev = system_info.module_count;
    system_info.module_count = 42;
    system_info.test_passed = 329;

    try std.testing.expectEqual(@as(usize, 42), system_info.module_count);
    try std.testing.expectEqual(@as(usize, 329), system_info.test_passed);

    system_info.module_count = prev;
}
