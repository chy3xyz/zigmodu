# ZModu Best Practices

Collected from building Heysen AI SAAS (152 tables, 13 modules, 790 endpoints, 3,200+ lines).

## Quickstart

```bash
# One-shot scaffold from SQL
zmodu scaffold --sql schema.sql --name myapp

# Add custom business endpoints (survives regeneration)
# Create modules/{name}/api_ext.zig + modules/{name}/service_ext.zig

# Build & run
zig build run
```

---

## 1. Project Architecture (The `_ext.zig` Pattern)

### The core problem

`zmodu orm --force` regenerates model/persistence/service/api files, **overwriting** any hand-written code in them. Custom business logic must live in files that zmodu doesn't touch.

### The solution: Extension layers

```
modules/{name}/
├── model.zig          ← GENERATED (never edit)
├── persistence.zig    ← GENERATED (never edit)
├── service.zig        ← GENERATED (never edit)
├── api.zig            ← GENERATED (never edit)
├── module.zig         ← GENERATED (never edit)
├── root.zig           ← GENERATED (never edit)
├── service_ext.zig    ← CUSTOM (survives regeneration)
└── api_ext.zig        ← CUSTOM (survives regeneration)
```

**Rule**: `_ext.zig` files import from generated ones. Never edit generated files directly.

### Wiring pattern

```zig
// service_ext.zig — persistence + business logic
const generated = @import("service.zig");
const business = @import("../../business/root.zig");

pub const MyServiceExt = struct {
    svc: *generated.MyService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *generated.MyService, backend: zigmodu.SqlxBackend) MyServiceExt { ... }

    // Custom business methods here
    pub fn cancelOrder(self: *MyServiceExt, order_id: i64) !?[]const u8 { ... }
};

// api_ext.zig — HTTP handlers
pub const MyApiExt = struct {
    ext: *MyServiceExt,

    pub fn registerRoutes(self: *MyApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        try group.post("/order/:id/cancel", cancel, @ptrCast(@alignCast(self)));
    }
};
```

### Registration in main.zig

```zig
var ext_svc = my_ext.MyServiceExt.init(&generated_svc, backend);
var ext_api = my_ext.MyApiExt.init(&ext_svc);
try ext_api.registerRoutes(&root);
```

---

## 2. Business Logic Layer (`src/business/`)

### Design principles

1. **Pure functions** — No side effects, no DB access, no allocations. Easy to test.
2. **Importable anywhere** — Business modules import from each other, not from generated code.
3. **PHP-aligned** — One business module per PHP domain concept.
4. **Exact enum values** — Match PHP integer constants byte-for-byte (critical for DB compatibility).

### Module organization

```
src/business/
├── enums.zig           # All DB enum constants (16 PHP enum classes)
├── commission.zig      # Commission formula (pure math, 3 calculation modes)
├── agent.zig           # Agent grades, promotion, withdrawal validation
├── referral.zig        # Referral chain, binding modes, cycle detection
├── order_flow.zig      # Order state machine (9 transitions)
├── settlement.zig      # Supplier/platform money split
├── payment_flow.zig    # Post-payment actions, trade split
├── cron_jobs.zig       # Cron action determination (what to do)
├── cron_exec.zig       # Cron action execution (how to do it)
├── events.zig          # Event bus (9 event types, pub/sub)
├── points.zig          # Points discount/gift/convert
├── coupon.zig          # Coupon validation, best-coupon selection
├── refund.zig          # Refund state machine (7 transitions)
├── grade_discount.zig  # Member grade discount per product
├── user_onboarding.zig # Registration gift, sign-in rewards
├── auth.zig            # Token generation/validation
└── root.zig            # Barrel re-exports
```

### Test-first pattern

Every business module has embedded `test { }` blocks. Tests verify pure calculations without DB or HTTP:

```zig
test "commission with grade bonus" {
    const result = calculateProductCommission(100.0, 1, .{}, cfg, grade, grade);
    try std.testing.expectEqual(@as(f64, 13.0), result.first_money);
}
```

---

## 3. SQL → Module Mapping

### Table naming convention

```
{project}_{domain}_{entity}

heysen_agent_apply      → module: agent
heysen_user_address     → module: user
heysen_order_product    → module: order
```

**Rule**: Consistent 2-level prefix. zmodu auto-strips the common prefix and groups by domain.

### Optimal module granularity

| Tables per module | Action |
|-------------------|--------|
| 1-3 | Merge with sibling domain |
| 5-15 | **Sweet spot** |
| 15-25 | Acceptable if coherent |
| 25+ | Split by sub-domain |

When auto-grouping produces too many small modules, use `--module` to force grouping.

---

## 4. PHP → Zig Porting Methodology

### Step 1: Map PHP endpoints to Zig extensions

| PHP | Zig |
|-----|-----|
| `Controller::action()` | `api_ext.zig` route handler |
| `Model::businessMethod()` | `service_ext.zig` business method |
| `event('EventName', ...)` | Direct function call to `business/*.zig` |
| `$model->transaction(fn)` | `defer` + error handling in service_ext |
| `Cache::set/get` | zigmodu cache or `std.HashMap` |

### Step 2: Copy logic, not PHP syntax

```zig
// PHP: $capital['first_money'] = $productPrice * ($setting['first_money'] * 0.01) + $add_first_money;
// Zig:
const first = product_price * ((global_cfg.first_money + first_bonus_pct) * 0.01);
```

### Step 3: Validate against PHP exactly

- All enum values must match byte-for-byte
- All calculation formulas must produce identical results (verified with tests)
- All validation rules must have the same conditions (count them: PHP has 8, Zig must have 8)

### Step 4: Wire into main.zig

```zig
// After all generated APIs are registered
try agent_api_custom.registerRoutes(&root);
try user_api_custom.registerRoutes(&root);
try order_api_custom.registerRoutes(&root);
```

---

## 5. Common Pitfalls & Solutions

### Zig 0.16 API changes

| Issue | Fix |
|-------|-----|
| `ArrayList(T).init(a)` → error | Use `.empty`, pass allocator to `append(a, item)`, `deinit(a)`, `toOwnedSlice(a)` |
| `std.time.timestamp()` → error | Use `std.time.epoch.unix` or `zigmodu.time.monotonicNowSeconds()` |
| `{d:.2f}` format → error | Use `{d:.2}` (no trailing `f`) |
| `var` not mutated → error | Use `const` |
| `_ = foo` then `foo.bar()` → error | Remove the discard line |

### Persistence integration

Business modules are pure calculations. To persist:
1. `service_ext.zig` calls business functions for computation
2. `service_ext.zig` calls generated service/persistence for DB writes
3. `service_ext.zig` wraps both in transactional error handling

### Regeneration workflow

```bash
# Regenerate modules from updated SQL:
zmodu orm --sql domain.sql --module <name> --out src/modules --force

# Extension files survive. Only update root.zig if new modules were added.
zig build && zig build test
```

---

## 6. zmodu Scaffold Evaluation

### What `zmodu scaffold` generates (correct)

- `build.zig` / `build.zig.zon` (Zig 0.16.0, zigmodu dependency)
- `src/main.zig` (all modules wired)
- `src/modules/{name}/` (6 files each: model, persistence, service, api, module, root)
- `src/tests.zig` (entry point)
- `src/business/root.zig` (skeleton)
- `.env.example`

### What's missing (manual work required after scaffold)

| Gap | Impact | Priority |
|-----|--------|----------|
| `src/business/*.zig` files are empty stubs | Must write all 17 business modules | P0 |
| No `service_ext.zig` / `api_ext.zig` pattern | Must create manually | P0 |
| No env-based config helpers (envOr, envU16Or) | Must add to main.zig | P1 |
| No health check endpoint | Must add manually | P1 |
| No extension route registration in main.zig | Must wire manually | P1 |
| build.zig.zon uses remote URL for zigmodu | Must change to local path for monorepo | P1 |
| No business module import in main.zig | Must add `const business = @import(...)` | P1 |
| `agent_ext_svc` must be `var` not `const` for api_ext | Fix manually | P2 |
| scaffold generates ALL tables into separate micro-modules | Must regroup domains manually | P2 |
| No `--prefix` flag for custom prefix stripping | Must regroup tables before generation | P2 |

### Recommended zmodu improvements

1. **`scaffold` should generate business stubs** — `commission.zig`, `agent.zig`, `referral.zig` with function signatures
2. **`scaffold` should generate `service_ext.zig` + `api_ext.zig`** — with init patterns and registerRoutes skeleton
3. **`scaffold` should include env-config helpers** — `envOr`, `envU16Or`, `envF64Or`, `envBoolOr` in main.zig
4. **`scaffold` should add health check** — `GET /api/health` endpoint
5. **`scaffold` should wire extension routes** — with commented placeholders
6. **Add `--prefix` flag** — explicit common prefix for auto-grouping
7. **Add `--group` flag** — `--group agent:heysen_agent,heysen_user_referee --group order:heysen_order,heysen_balance_*` for custom grouping

### Version matrix

| Component | Version | Notes |
|-----------|---------|-------|
| Zig | 0.16.0 | Required |
| zmodu | 0.5.5+ | SQL parser patches applied |
| zigmodu | 0.7.0+ | ORM patches for optional types + custom PKs |
| MySQL | 5.6.48 | utf8mb4 charset |
