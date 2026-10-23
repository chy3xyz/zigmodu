# CLI & Code Generation (`zmodu`)

`zmodu` includes a built-in CLI tool (`tools/zmodu`) for scaffolding projects from SQL DDL or live databases, generating modules, auditing architecture rules, detecting dead code, and running CI checks.

## 1. Building the CLI

Build and install the CLI from the repository root:

```bash
zig build zmodu
# Binary installed at: ./zig-out/bin/zmodu
```

> Always build via `zig build zmodu` from the repository root so `./zig-out/bin/zmodu` stays in sync with the workspace. Do not run file-generating commands (`module`, `api`, `event`, `health`, `config`) inside the framework repository root without `--dry-run` or a temporary directory.

## 2. Project Scaffolding (`zmodu scaffold`)

### From a SQL Schema File

```bash
./zig-out/bin/zmodu scaffold \
  --sql ./schema.sql \
  --name my_shop_app \
  --out ./my_shop_app \
  --tenant-column tenant_id \
  --with-auth \
  --with-resilience \
  --with-events \
  --with-metrics
```

### From a Live Database

```bash
./zig-out/bin/zmodu scaffold \
  --from-db postgresql://user:pass@localhost:5432/mydb \
  --name my_app \
  --out ./my_app
```

| Input Source | Generated `.db` in `build.zig` |
|--------------|--------------------------------|
| `zmodu new` / `--sql` | `sqlite` |
| `--from-db postgres://...` | `postgres` |
| `--from-db mysql://...` | `mysql` |

### Generated Module Structure

Each generated module follows the `@initialized` model (annotated with `//! @initialized by zmodu` and meant to be edited directly in place, with no `ext/` inheritance layer):

- `model.zig`: Entity struct, `sql_table_name`, `sql_tenant_column`, and field defaults.
- `persistence.zig`: Parameterized `Repository(T)` queries and custom SQL helpers.
- `service.zig`: Validation hooks, transaction helpers (`self.transact(...)`), and `EventBus` publishing.
- `api.zig`: `ComptimeRouter` `pub const routes` or zero-boilerplate `http.CrudApi`.
- `module.zig`: Module metadata (`info`) and lifecycle (`init` / `deinit`).
- `test.zig`: Single-table modules include an in-memory SQLite round-trip test and an `http.Testkit.dispatch` route test.

## 3. Zero-Boilerplate CRUD (`zmodu saas` & `http.CrudApi`)

`zmodu saas <model.json>` writes `saas-schema.sql` and the module sources. The schema is applied by your application, so tell the generator which server it will run on:

```bash
zmodu saas model.json --dialect postgres   # sqlite (default) | postgres | mysql
```

Without `--dialect` the emitted DDL is SQLite's (`id INTEGER PRIMARY KEY AUTOINCREMENT`); `postgres` emits `BIGSERIAL PRIMARY KEY` + `BIGINT`, `mysql` emits `BIGINT AUTO_INCREMENT PRIMARY KEY`. The same flag semantics apply to embedded framework tables — see the per-store `migrate()` / `ensureTable()` calls in [API](../reference/API.md).

Modules generated with `zmodu saas` use `zmodu.http.CrudApi(Entity, Service, opts)` to register five standard endpoints in a single declaration:

```zig
const zmodu = @import("zmodu");
const model = @import("model.zig");
const service = @import("service.zig");

pub const OrdersApi = zmodu.http.CrudApi(model.Orders, service.OrdersService, .{});
```

| Method | Path | Permission | Behavior |
|--------|------|------------|----------|
| `GET` | `{nest}` | `<module>:read` | Paginated list (`PageParams`, real `COUNT(*)`) |
| `POST` | `{nest}` | `<module>:write` | Create entity (`bindJson` + `tenant_id` injection) |
| `GET` | `{nest}/{id}` | `<module>:read` | Get by ID (404 when missing or cross-tenant) |
| `PUT` | `{nest}/{id}` | `<module>:write` | Update entity |
| `DELETE` | `{nest}/{id}` | `<module>:write` | Delete entity |

`CrudOpts` options:
- `.public = true`: Marks routes `.auth = .public` and clears permission requirements.
- `.permission = "crm.order"`: Overrides the permission prefix.
- `.envelope = .plain | .ruoyi`: Selects the response JSON envelope.
- `.dto = MyDto`: Filters response fields through a whitelist DTO struct.
- `.bulk = true`: Adds `POST {nest}/bulk` for batch creation.
- `.sortable = &.{ "created_at", "price" }`: Enables whitelisted `sort` and `order` query parameters.

## 4. Incremental Module & Migration Commands

### Add or Scaffold a Module

```bash
# Generate full 5-layer module skeleton in src/modules/order/
./zig-out/bin/zmodu module order --full

# Add a table module from SQL DDL
./zig-out/bin/zmodu add --name order_item --sql ./schema.sql
```

### Generate Schema Diff Migrations

```bash
./zig-out/bin/zmodu diff old.sql new.sql --migration add-audit-log --dir src/migrations
# Outputs: src/migrations/V{YYYYMMDDHHMMSS}__add-audit-log.sql
```

## 5. Quality & Architecture Gates

### `zmodu ci` — One-Command Project Gate

Runs `zig build` → `zig fmt --check` → `verify` → `audit` → `deadcode` → `doctor`:

```bash
./zig-out/bin/zmodu ci [dir]
```

### `zmodu doctor` — Module Graph & Import Entanglement Check

Scans module declarations and source imports without compiling the project. Fails (exit 1) on circular, missing, self, or duplicate dependencies, and warns when a module imports another module's internal files directly:

```bash
./zig-out/bin/zmodu doctor [dir]
./zig-out/bin/zmodu doctor --json
./zig-out/bin/zmodu graph --out docs/modules.md
```

### `zmodu audit` — Best-Practice Linter

Checks architecture rules and business layer rules (raw SQL in handlers, non-parameterized SQL, `@ptrCast(ctx.user_data)`, banned legacy imports, removed Zig 0.17 APIs, bare `catch {}`, unscoped tenant queries):

```bash
./zig-out/bin/zmodu audit [dir]
./zig-out/bin/zmodu audit -g business -j
./zig-out/bin/zmodu audit --update   # Write baseline to .zmodu/audit-baseline.json
```

Configure per-project overrides in `.zmodu/rules.json`:

```json
{ "max_deps": 8, "disabled": ["b3", "b9"] }
```

### `zmodu deadcode` — Reachability Analyzer

Finds unused top-level functions, constants, struct fields, enum variants, and unimported modules:

```bash
./zig-out/bin/zmodu deadcode          # Library mode
./zig-out/bin/zmodu deadcode -b       # Binary mode (main as root)
./zig-out/bin/zmodu deadcode -j       # JSON output
```

### `zmodu runtime` — Static Runtime Wiring Report

Reports all `spawn` sites, mailbox capacities, worker pool settings (`max_pooled_workers`, `.mode = .pooled`), `HotBus` instances, timers, and delivery recorders with `file:line` locations:

```bash
./zig-out/bin/zmodu runtime examples/alpha-engine
./zig-out/bin/zmodu runtime --json
```

## 6. AI Skill Export & Marketplace

```bash
# Export built-in AI skills catalog and OpenAPI 3.0 specification
./zig-out/bin/zmodu ai export-skills --out skills.json
./zig-out/bin/zmodu ai openapi --in skills.json --out openapi.json

# Browse and install curated examples/plugins
./zig-out/bin/zmodu market list
./zig-out/bin/zmodu market search saas
./zig-out/bin/zmodu market install example/basic --dir ./vendor --verify
```
