# ZigModu Framework Backlog

Status tracker for framework ergonomics improvements (Zig 0.17).  
Monolith boundaries unchanged — see `docs/PRODUCTION_ROADMAP.md`.

| # | Item | Status | Entry point |
|---|------|--------|-------------|
| 1 | Typed extractors (Path / Query / Json) | **Landed** | `http.extractPath/Query/Json` + field defaults → `src/api/Extract.zig` |
| 2 | Unified error → ProblemDetails | **Landed** | `respondProblem` / `respondErr` + `setErrorMap` |
| 3 | Scope-local middleware | **Landed** | `RouteGroup.use`, `Scoped.use` |
| 4 | Router oneshot / Testkit | **Landed** | `Testkit.dispatch` / `dispatchOpts` |
| 5 | Security / Obs / Resilience profiles | **Landed** | `applyHttpDefaults` + `applyResilienceDefaults` / `ResilienceProfileState` |
| 6 | Testkit JWT / SQLite / tenant / SSE | **Landed** | `signBearerToken`, `openMemorySqlite`, `tenantMiddleware`, `SseRecorder` |
| 7 | Outbox / Idempotency | **Landed** | `zigmodu.outbox.*`, `idempotencyMiddleware` (+ sample tests) |
| 8 | Config / health / shutdown | **Landed** | `requireEnv`, `ShutdownChecklist` |
| 9 | OpenAPI ↔ extractors / SSE | **Landed** | `openApiParamsFromStruct` + `RouteMeta.openapi_params` merged in catalog |
| + | **SSE first-class** | **Landed** | `http.sse`, `SseSpec` / `sse_routes`, `SseRecorder` |
| + | Validation ↔ Extract | **Landed** | `extractJsonValidated(ctx, T, rules)` |
| + | Example migration | **Landed** | `examples/zent-modulith` + `tools/zmodu/.../api_standalone.zig.tpl` |

---

## Quick recipes

### Extractors + defaults

```zig
const QueryDto = struct { page: u32 = 0, q: ?[]const u8 = null };
const q = try http.extractQuery(ctx, QueryDto); // missing page → 0
```

### Validated JSON

```zig
const body = try http.extractJsonValidated(ctx, CreateDto, .{
    .name = http.FieldRules{ .required = true, .min_len = 2 },
});
```

### Custom error map

```zig
http.setErrorMap(&.{.{ .err = error.QuotaExceeded, .status = 429 }});
try http.respondErr(ctx, err);
```

### Profiles

```zig
var http_state = http.HttpProfileState.init(allocator);
defer http_state.deinit(allocator);
try http.applyHttpDefaults(&server, .{}, &http_state);

var res = try http.applyResilienceDefaults(allocator, &.{
    .{ .name = "db", .max_qps = 200 },
    .{ .name = "payment", .max_qps = 50 },
});
defer res.deinit();
```

### Testkit

```zig
var sec = http.Testkit.testSecurity(allocator, io);
const token = try http.Testkit.signBearerToken(&sec, allocator, "42", &.{"admin"});
defer allocator.free(token);
var db = try http.Testkit.openMemorySqlite(allocator, io);
defer db.deinit();
var rec = http.SseRecorder.init(allocator);
defer rec.deinit();
try rec.sendEvent("message", "{}");
```

### OpenAPI params on routes

```zig
const params = http.openApiParamsFromStruct(QueryDto, .query);
.{ .method = .GET, .path = "search", .handler = search, .meta = .{ .openapi_params = &params } }
```

### Idempotency + Outbox

```zig
var store = http.IdempotencyStore.init(allocator, 10_000);
defer store.deinit();
try server.addMiddleware(http.idempotencyMiddleware(&store)); // header: idempotency-key

var outbox = zmodu.outbox.OutboxPublisher.init(allocator, .{});
const insert = try outbox.buildInsert("order.created", payload_json);
// exec insert.sql with insert.params inside the same DB transaction
```

See `src/messaging/outbox_sample.zig` for unit smoke tests.

### SSE

```zig
pub const sse_routes = [_]http.SseSpec(State){ .{ .path = "events", .handler = stream } };
fn stream(ctx: *http.Context, _: *State) !void {
    var w = try http.sse(ctx);
    try w.sendEvent("tick", "{}");
    try w.done();
}
```

---

## Related docs

- [ROUTE_TABLE.md](./ROUTE_TABLE.md)
- [PRODUCTION_ROADMAP.md](./PRODUCTION_ROADMAP.md)
- [MODULITH.md](./MODULITH.md)
- [AGENTS.md](../AGENTS.md)
