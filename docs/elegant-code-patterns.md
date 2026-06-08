# Writing Elegant ZigModu Code — Patterns & Conventions

> Companion to `best-practices-heysen-lessons.md`. Concrete code patterns, not just bug reports.

## 1. Module Structure — One Pattern to Rule Them All

Every module follows the same 5-file layout. No exceptions. No `ext/` directories.

```
modules/<domain>/<entity>/
  model.zig        — Data struct, column mapping, JSON names
  persistence.zig  — DB access only (SQL, params, exec)
  service.zig      — Business logic (validation, orchestration)
  api.zig          — HTTP handlers + route registration
  module.zig       — Lifecycle (init/deinit), dependency declaration
```

### model.zig — Keep It Thin

```zig
pub const Agent = struct {
    pub const sql_table_name: []const u8 = "insurance_agents";

    id: ?i64 = null,
    tenant_id: i64 = 1,
    agent_name: []const u8,
    level_code: ?[]const u8 = null,
    status: ?i16 = null,
    // ...

    /// Maps DB column → JSON field. DB is snake_case, JSON is camelCase.
    pub const json_names = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id",             .json = "id" },
        .{ .db = "tenant_id",      .json = "tenantId" },
        .{ .db = "agent_name",     .json = "agentName" },
        .{ .db = "level_code",     .json = "levelCode" },
        .{ .db = "status",         .json = "status" },
    };
};
```

**Rules**:
- `id` is always `?i64 = null` (auto-generated)
- `tenant_id` is `i64 = 1` (default tenant)
- String fields are `[]const u8` (required) or `?[]const u8 = null` (optional)
- `json_names` maps EVERY field — never rely on default serialization
- No business logic in model — pure data

### persistence.zig — SQL Only, No Logic

```zig
pub const AgentPersistence = struct {
    backend: data.SqlxBackend,

    pub fn init(backend: data.SqlxBackend) AgentPersistence {
        return .{ .backend = backend };
    }

    // ── Queries ──

    pub fn listByTenant(self: *AgentPersistence, tid: i64, page: usize, size: usize) ![]Agent {
        const offset = (page - 1) * size;
        return self.backend.queryRows(Agent,
            \\ SELECT id, tenant_id, agent_name, level_code, status
            \\ FROM insurance_agents
            \\ WHERE tenant_id = $1 AND deleted = 0
            \\ ORDER BY id DESC LIMIT $2 OFFSET $3
        , &.{.{ .int = tid }, .{ .int = @intCast(size) }, .{ .int = @intCast(offset) }});
    }

    // ── Mutations ──

    pub fn insert(self: *AgentPersistence, a: Agent) !i64 {
        const new_id = try self.nextId("insurance_agents");
        _ = self.backend.client.exec(
            \\ INSERT INTO insurance_agents (id, tenant_id, agent_name, level_code, status)
            \\ VALUES ($1, $2, $3, $4, $5)
        , &.{.{ .int = new_id }, .{ .int = a.tenant_id }, .{ .string = a.agent_name },
            .{ .string = a.level_code orelse "" }, .{ .int = a.status orelse 1 }}) catch |err| {
            std.log.err("Agent insert failed: {s}", .{@errorName(err)});
            return error.DatabaseError;
        };
        return new_id;
    }

    pub fn update(self: *AgentPersistence, a: Agent) !void {
        _ = self.backend.client.exec(
            \\ UPDATE insurance_agents SET agent_name=$1, level_code=$2, status=$3
            \\ WHERE id=$4 AND tenant_id=$5 AND deleted=0
        , &.{.{ .string = a.agent_name }, .{ .string = a.level_code orelse "" },
            .{ .int = a.status orelse 1 }, .{ .int = a.id orelse 0 }, .{ .int = a.tenant_id }}) catch |err| {
            std.log.err("Agent update failed: {s}", .{@errorName(err)});
            return error.DatabaseError;
        };
    }

    pub fn delete(self: *AgentPersistence, id: i64) !void {
        _ = self.backend.client.exec(
            "UPDATE insurance_agents SET deleted=1 WHERE id=$1", &.{.{ .int = id }}) catch |err| {
            std.log.err("Agent delete failed: {s}", .{@errorName(err)});
            return error.DatabaseError;
        };
    }
};
```

**Rules**:
- ≤9 params per `exec()` call (PG driver limit)
- Split large inserts/updates into multiple calls if needed
- Always use `AND deleted=0` in WHERE clauses
- Log errors before propagating — `catch |err| { log; return err; }`
- `catch {}` is banned — always propagate or log

### service.zig — Business Logic Hub

```zig
pub const AgentService = struct {
    persistence: *AgentPersistence,

    pub fn init(p: *AgentPersistence) AgentService {
        return .{ .persistence = p };
    }

    pub fn createAgent(self: *AgentService, a: Agent) !i64 {
        if (a.agent_name.len == 0) return error.ValidationFailed;
        return try self.persistence.insert(a);
    }

    pub fn updateAgent(self: *AgentService, a: Agent) !void {
        if (a.agent_name.len == 0) return error.ValidationFailed;
        try self.persistence.update(a);
    }

    pub fn deleteAgent(self: *AgentService, id: i64) !void {
        try self.persistence.delete(id);
    }
};
```

**Rules**:
- All business validation lives here
- Service orchestrates multiple persistence calls
- Never import `http` or `Context` — service is transport-agnostic

### api.zig — Thin HTTP Layer

```zig
pub const AgentApi = struct {
    service: *AgentService,

    pub fn registerRoutes(self: *AgentApi, group: *RouteGroup) !void {
        const p = "/insurance/agents";
        try group.get(p ++ "/page",     self.hPage);
        try group.get(p ++ "/get",      self.hGet);
        try group.post(p ++ "/create",   self.hCreate);
        try group.put(p ++ "/update",    self.hUpdate);
        try group.delete(p ++ "/delete", self.hDelete);
    }

    fn hCreate(ctx: *Context) !void {
        const self = resolveApi(ctx);
        const input = parseBody(AgentInput, ctx) catch return;
        const agent = Agent{ .tenant_id = getTid(ctx), .agent_name = input.agent_name,
            .level_code = input.level_code, .status = 1 };
        const id = self.service.createAgent(agent) catch |err| {
            try wrapErr(ctx, 500, "Create failed");
            return;
        };
        try wrapOk(ctx, .{ .id = id });
    }
};
```

**Rules**:
- Handlers are ≤20 lines
- One handler per route
- All JSON parsing uses arena (see §4)
- Use `wrapOk`/`wrapErr`/`wrapList` consistently

---

## 2. The Handler Pattern — PARSE → VALIDATE → EXECUTE → RESPOND

Every handler follows this exact flow. No exceptions.

```zig
fn hCreate(ctx: *Context) !void {
    // 1. RESOLVE — get service reference
    const self = resolveApi(ctx);

    // 2. PARSE — arena-backed JSON parsing (never GPA)
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const input = parseBody(CreateAgentInput, arena.allocator(), ctx) catch {
        try wrapErr(ctx, 400, "Invalid request body");
        return;
    };

    // 3. VALIDATE — business rules
    if (input.agent_name.len == 0) {
        try wrapErr(ctx, 400, "Agent name is required");
        return;
    }

    // 4. EXECUTE — call service
    const agent = Agent{
        .tenant_id = getTid(ctx),
        .agent_name = input.agent_name,
        .level_code = input.level_code,
        .status = 1,
    };
    const id = self.service.createAgent(agent) catch |err| {
        std.log.err("Create agent failed: {s}", .{@errorName(err)});
        try wrapErr(ctx, 500, "Create failed");
        return;
    };

    // 5. RESPOND — always {code, msg, data}
    try wrapOk(ctx, .{ .id = id });
}
```

**Why arena?** `parseFromSlice` with GPA deinits individual string fields on `parsed.deinit()`. Arena keeps everything alive until `arena.deinit()` at function end. See `best-practices-heysen-lessons.md` §4.

---

## 3. Input Structs — Parse Only What You Accept

Never parse directly into the ORM model. Create a separate input struct:

```zig
/// Only the fields the API accepts from the client.
const CreateAgentInput = struct {
    agent_name: []const u8,          // required
    level_code: ?[]const u8 = null,  // optional
    company_code: []const u8 = "HSIC",
    license_no: ?[]const u8 = null,
    license_states: ?[]const u8 = null,
    email: ?[]const u8 = null,
};
```

**Benefits**:
- Client can't inject `id`, `creator`, `create_time`, `deleted`
- Missing optional fields get defaults, not parse errors
- Self-documenting — you can see every accepted field

Helper to reduce boilerplate:
```zig
fn parseBody(comptime T: type, allocator: std.mem.Allocator, ctx: *Context) !T {
    const body = ctx.body orelse return error.BadRequest;
    const parsed = std.json.parseFromSlice(T, allocator, body, .{}) catch return error.BadRequest;
    return parsed.value;
}
```

---

## 4. Response Helpers — Consistent Envelope

Every API response must use the `{code, msg, data}` envelope:

```zig
/// Success with data
fn wrapOk(ctx: *Context, data: anytype) !void {
    try ctx.json(200, .{ .code = 0, .msg = "", .data = data });
}

/// Success, no data
fn wrapSuccess(ctx: *Context) !void {
    try ctx.json(200, .{ .code = 0, .msg = "", .data = null });
}

/// Error
fn wrapErr(ctx: *Context, code: i32, msg: []const u8) !void {
    try ctx.json(200, .{ .code = code, .msg = msg, .data = null });
}

/// Paginated list — always returns {list, total}
fn wrapList(ctx: *Context, result: anytype) !void {
    try ctx.json(200, .{ .code = 0, .msg = "", .data = .{ .list = result.items, .total = result.total } });
}
```

---

## 5. Multi-Tenant by Default

Every query that touches tenant data includes `tenant_id`:

```zig
fn getTid(ctx: *Context) i64 {
    return ctx.queryInt(i64, "tenantId", 1);
}

// In persistence:
fn listByTenant(self: *Persistence, tid: i64) ![]T {
    return self.backend.queryRows(T,
        \\ SELECT ... FROM table
        \\ WHERE tenant_id = $1 AND deleted = 0
    , &.{.{ .int = tid }});
}
```

System-level tables (system_menu, system_role, system_user) omit tenant_id.

---

## 6. Error Handling — Three Levels

### Level 1: Persistence — Log + Propagate
```zig
_ = self.backend.client.exec(sql, args) catch |err| {
    std.log.err("SQL failed: {s} — {s}", .{ sql, @errorName(err) });
    return error.DatabaseError;
};
```

### Level 2: Service — Validate + Propagate
```zig
pub fn create(self: *Service, entity: T) !i64 {
    if (entity.name.len == 0) return error.ValidationFailed;
    return try self.persistence.insert(entity);
}
```

### Level 3: API — Translate to User-Friendly Message
```zig
const id = self.service.create(entity) catch |err| {
    const msg = switch (err) {
        error.ValidationFailed => "Name is required",
        error.DatabaseError => "Database error — please retry",
        else => "Unexpected error",
    };
    try wrapErr(ctx, 500, msg);
    return;
};
```

---

## 7. Testing — Three Layers

### Layer 1: Smoke (68 endpoints, 15s)
```bash
# tests/smoke.sh — verify all GET endpoints return 200
TOKEN=$(login)
for ep in $(all_endpoints); do
    check_200 "$ep" "$TOKEN"
done
```

### Layer 2: E2E Flow (14 business flows, 30s)
```bash
# tests/e2e-flow.sh — create → read → update → delete
create_agent; verify_in_list; create_client; create_policy; verify_commission
```

### Layer 3: Regression (100+ checks, 45s)
```bash
# tests/regression.sh — auth, CRUD lifecycle, data integrity, perf
test_auth_required; test_invalid_token; test_public_paths
test_agent_crud; test_policy_lifecycle; test_commission_chargeback
test_cross_table_integrity; test_response_time
```

---

## 8. The "Never" List

| Never | Because | Instead |
|-------|---------|---------|
| `catch {}` | Silently hides errors | `catch \|err\| { log; return err; }` |
| `parseFromSlice(ORM_Model, gpa, ...)` | Dangling string ptrs after deinit | Use arena + Input struct |
| `ctx.allocator` for parsed data | GPA — freed on deinit | Arena wrapping `ctx.allocator` |
| `client.query()` for INSERT/UPDATE | Returns Rows type — confusion | `client.exec()` |
| >9 params in `exec()` | PG driver crash | Split into multiple calls |
| Snake_case in handler names | Inconsistent with Zig convention | camelCase handlers, snake_case DB |
| Hard-coded string literals in SQL | SQL injection, escape issues | Parameterized queries (`$1, $2`) |
| Direct model parse for create | Client can inject protected fields | Input struct with only accepted fields |

---

## 9. Quick Reference — File Templates

### New CRUD Module Checklist
```
[ ] model.zig — struct + sql_table_name + json_names
[ ] persistence.zig — listByTenant, getById, insert, update, delete
[ ] service.zig — create, update, delete with validation
[ ] api.zig — registerRoutes with page/get/create/update/delete
[ ] module.zig — init/deinit lifecycle
[ ] Wire in main.zig — persistence → service → api → routes
[ ] Add to seed SQL if needed
[ ] Add smoke test endpoint
```

### Typical Wire-Up (main.zig)
```zig
var agent_p = AgentPersistence.init(backend);
var agent_svc = AgentService.init(&agent_p);
var agent_api = AgentApi.init(&agent_svc);
try agent_api.registerRoutes(&root);
```

---

## 10. Refactoring Checklist

When you inherit generated code, fix these:

1. [ ] Rename handler functions (remove doubled module names)
2. [ ] Replace `parseFromSlice(Model, ctx.allocator, ...)` with arena-backed Input struct
3. [ ] Split >9-param `exec()` calls into batches
4. [ ] Replace `catch {}` with logged error propagation
5. [ ] Add `deleted=0` filter to all queries
6. [ ] Add `tenant_id` filter to tenant-scoped queries
7. [ ] Standardize response format (wrapOk/wrapErr/wrapList)
8. [ ] Add kebab-case route alias if admin frontend needs it
