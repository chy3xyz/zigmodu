# zmodu with zent

zent ([chy3xyz/zent](https://github.com/chy3xyz/zent)) is an ent-style, schema-as-code ORM for Zig. This page covers how to use it in zmodu modules and where it stops.

- zent **v0.97.0** (pinned by both examples), zmodu **v0.15.22+**, Zig **0.17.0**
- Reference implementation: [`examples/zent-modulith/`](../../examples/zent-modulith/); upstream examples: `zig build run-start` / `run-complex` / `run-pool`
- Related: [MODULE_LAYERS.md](../guide/MODULE_LAYERS.md) · [MODULITH.md](../guide/MODULITH.md) · [BEST_PRACTICES.md](../guide/BEST_PRACTICES.md) · [SQLX_DRIVERS.md](../guide/SQLX_DRIVERS.md)

## 1. Orthogonal stacks

The framework default is sqlx, not zent. Use zent per module; never mix drivers in one transaction.

- `data.SqlxBackend` is the default backend; `data.Repository(T)` is `orm.Orm(SqlxBackend).Repository` ([`src/data.zig`](../../src/data.zig)).
- `build.zig.zon` has `.dependencies = .{}`, so zent is not a framework dependency; applications pin it by git tag (§11). "Commerce and social projects default to zent" is a selection recommendation (§2, §4.8), not a framework default.

| Layer | zmodu | zent |
|-------|-------|------|
| HTTP, middleware, module lifecycle | `http.Server` / `Application` | no |
| Schema-as-code, relations, generated client | no (or hand-written sqlx structs) | `Schema` + `makeClient` |
| Parameterized SQL CRUD | `data.sqlx` / `Repository` | fluent query/create builders |
| Redis, metrics, JWT, outbox | yes | no |

Never put a `zent.sql_driver.Driver` inside `zmodu.data.Client`. Pools, dialects and migration tables stay separate. `examples/_shared/zent_helpers.zig` forwards to `zent.helpers` (`StoreEnv`, `TestEnv`, `PooledEnv`, `ShardedEnv`); it is example glue, not zmodu core.

## 2. When to use zent, when to use sqlx

| Requirement | Choice |
|-------------|--------|
| Commerce (catalog, orders, stock, multi-shop) | **zent**: dense graph, exact money (`field.Decimal`), idempotent upsert, row isolation |
| Social (follows, feed, likes, DMs) | **zent**: edges as first-class, eager load/filter/sort, privacy visibility |
| Plain CRUD, existing SQL, reports, complex hand-written queries | **sqlx** (`zmodu.data`) |
| Both stacks in one process | **per module** (§3) |

Orchestration and messaging belong to zmodu; the domain graph and row policies to zent; simple tables and existing SQL to sqlx.

Multi-tenancy: `TenantContext` (JWT or middleware → runtime id) is engine-neutral and used by both. Row isolation follows one engine's idiom, never both: sqlx modules use `TenantInterceptor` / `DataPermission` (`zmodu.tenant`, `zmodu.datapermission`); zent modules use a privacy filter or an explicit `tenant_id` predicate (§8, §9). Doing both gives two sources of truth.

## 3. Choosing per module

Different modules may pick different stacks. That is the recommended arrangement, not a workaround.

| Allowed | Not allowed |
|---------|-------------|
| Module A uses a zent `Client`, module B uses `data.sqlx` | Two drivers in one `Transaction` |
| Separate migrate runs and pools | A zent driver inside a sqlx client |
| Services exchange DTOs or interfaces | Expecting one DB transaction to span stacks |

Same-database strong consistency means the same stack, or writes funneled through one persistence layer. Cross-domain side effects use the event bus or outbox. The only shared inputs are `allocator`, `io` and the HTTP context. Keep drivers inside `persistence.zig`; `api` and `service` must not leak `zent.*` or `sqlx.*` types.

## 4. Capability value and scenarios

### 4.1 Edges

O2M/M2O/M2M navigation replaces hand-written joins and junction tables. Use it for order → line → product → tag, org trees, follow graphs and RBAC; skip it for single-table CRUD and warehouse queries.

### 4.2 Codegen client

Typed `client.product.Query()` / `Create()` and predicates, with migrations that track the graph. Use it with many entities and several schema editors; skip it with a large hand-written SQL surface or DBA-owned migrations.

### 4.3 Privacy and tenant source

Reads and writes carry allow/deny/filter policies; a configured policy without `withContext` returns `PrivacyDenied`. `CrudApiOpts.tenant_source`:

| Value | Meaning | When |
|-------|---------|------|
| `.attr` (recommended) | Tenant from request context, injected by JWT middleware from the `aud` claim | production only |
| `.query` | Tenant from a URL query parameter | public demos only |

`.query` lets the client declare its own tenant: changing `?tenant_id=` reads another tenant. `zmodu audit` rule b22 rejects it. Reference: `examples/zent-modulith/src/main.zig` (`.attr` + `jwtAuthFromCatalog`; the dev token route exists only with `ZENT_DEV_TOKEN=1`).

### 4.4 Hooks

Before/after validation, audit, soft delete and defaults; `before` can cancel a write. Use it for soft delete, audit rows, `updated_at` and one-step state checks; keep cross-service orchestration, sagas and heavy rules in services.

### 4.5 Scenario map

Simple CRUD, existing SQL and reports go to sqlx; dense graphs with tenant row isolation and write-side cross-cutting rules go to zent; order/payment/outbox, BFF and rate limiting stay ORM-neutral in zmodu. `tenant-shop` (orchestration and messaging) fits sqlx; "product–category–tag, staff edit only their shop, soft delete and audit" is a zent module.

### 4.6 Feature reference (v0.20–v0.74)

| Scenario | Usage | Notes |
|----------|-------|-------|
| Eager loads and joins | `q.WithEdge("posts.comments")`, `q.WithEdgeOptions("payment", .{ .join = .inner })`, `edge.To(...).OrderBy("created_at").Desc().Limit(10)` | One neighbor query per level; a third level is a compile error. Inner joins keep `Limit` after edge filtering. Per-parent `LIMIT` uses `ROW_NUMBER() OVER (PARTITION BY fk …)`; M2M/M2O limits return `UnsupportedEdgeLimit`. |
| Edge filtering | `edge.To(...).WhereRaw("\"hidden\" = ?", &.{.{ .bool = false }})` | Filters before ordering and limiting. |
| Follows, friends, likes | `edge.To/From` + `graph.neighbors` | M2M neighbor queries with has/with predicates. |
| Keyset cursor | `q.CursorKeyset("created_at", .{.int = ts}, id, desc)` + `Limit(n)` | Ties within a second do not drop rows across pages. |
| Timestamps / audit / validation | `TimeMixin`, `AuditMixin`, `NotEmpty/Length/Email/Phone/Custom` | Epoch defaults and automatic `updated_at`; `created_by`/`updated_by` come from `PrivacyContext.user_id`; Create/Update validate automatically. |
| Nested transactions | `beginTx` inside `beginTx` | Degrades to `SAVEPOINT`; an inner rollback reverts inner writes only. |
| Post-commit callbacks | `tx.afterCommit(...)` + `enqueueEvent` / `takePendingEvents` | Delivered after commit; rollback fires nothing. |
| Distributed IDs | `core.id.uuidv4()` / `uuidv7(now_ms)` + `field.UUID("id")` | Shard-safe, time-ordered for cursors. |
| Masking and projection | `zent.codegen.toMaskedJson(...)`, `q.Select(&.{"id","name"})` | `Sensitive()` renders `"***"`; projection skips large text/blob columns. |
| Restore and bulk delete | `DeleteBuilder.Restore(id)` / `BulkDelete` + `IN` | Restore clears `deleted_at`; bulk soft delete is one UPDATE. |
| Transaction from a pool | `zent.codegen.beginTxFromDriver(infos, pool.asDriver(), alloc)` | Typed `TxClient` without a root client; re-entry degrades to savepoint (§6.4). |
| Aggregate DTO columns | `sql.SelectExpr("COUNT(*)", "like_count")` + `Selector.addColumn` + `Row.columnIndex("like_count")` | Counts return with the main query; pair with `sql.OrderExprSql`. |
| Request-scoped entities | `codegen.ManagedEntity` / `managedEntity` + `dupeEntityTo(arena, …)` | Allocator-bound entities; deep copies (typed JSON, two edge levels) live in the request arena. |
| NULL-safe reads | `Row.tryGetInt/tryGetText/…` | Returns `error.NullColumn` instead of a silent zero. |
| Owned strings and LIKE escaping | `crud_helpers.freeOwnedStrings`, `ContainsEscaped` | Frees owned strings in batches; MySQL ESCAPE is `!` because `\` is MySQL's string escape and corrupts patterns. |

### 4.7 Reports and the join boundary

zent is ent-style: relations use edge preloading, not ad-hoc cross-table joins. Prefer `client.product.Query()` plus `WithEdge`, or single-table aggregates (`CountBy`, `Sum`, `GroupBy`). For complex reports use zent driver raw SQL (`client.driver.query(...)`) or a separate zmodu `data.sqlx` connection, never sharing a transaction across stacks. Give reports their own `report/` module with its own `sqlx.Client`.

Raw SQL does not carry soft-delete, privacy or interceptor predicates, so `client.driver.query()` silently skips tenant filtering. Splice the same contract in with `zent.scope`:

```zig
const scope = zent.scope.forClient(persist.infos, "product", &client.product, .{});
const frag = try scope.withClause(allocator);   // soft delete -> privacy -> interceptors
defer allocator.free(frag);
const sql = try std.fmt.allocPrint(allocator, "SELECT id, name FROM product WHERE 1=1 {s} ORDER BY id", .{frag});
```

A policy table without `privacy_ctx` returns `error.PrivacyDenied` from `withClause` instead of unfiltered SQL. `:alias` qualifies every injected predicate; `table` is comptime, so a wrong table name is a compile error.

### 4.8 Commerce and social matrix (v0.30–v0.74)

| Scenario | Usage | Notes |
|----------|-------|-------|
| Exact money | `field.Decimal("price")` | PG `NUMERIC`, MySQL `DECIMAL(38,10)`, SQLite `TEXT`; scanned as `[]const u8`, never truncated to f64. Float migration follows zent's `UPGRADING.md`. |
| Atomic stock decrement | `u.setExprArgs("stock", "stock - ?", &.{.{.int = n}})` + `Where(idEQ, stockGTE)` | `rows_affected == 0` means insufficient stock; prefer it over version-based read-modify-write at high concurrency. |
| Idempotent upsert and batch write | `SaveOrUpdateOn(&.{"order_no"})`, `SaveOrUpdateOnWith`, `SaveIgnore()`, `BulkInsertBuilder.SaveOrUpdate`, `data.bulk.insertMany` (sqlx) | `ON CONFLICT (cols) DO UPDATE` / ODKU with an explicit target; `SaveIgnore` uses `INSERT IGNORE` / `ON CONFLICT DO NOTHING`; batch writes turn N round trips into one. |
| Optimistic locking | `field.Version()` | Update/delete add `WHERE version = ?` and `version = version + 1`; conflicts return `OptimisticLockConflict`. |

## 5. Layer mapping

| zmodu file | zent usage | Responsibility |
|------------|------------|----------------|
| `model.zig` | `Schema` + `field.*` + `edge.*` + optional policies/hooks | Shape and relations; no HTTP, no SQL strings |
| `persistence.zig` | Holds `Client(infos)`; `Create`/`Query`/`beginTx` | No business `if`; returns DTOs |
| `service.zig` | Validation, commands, orchestration; may `beginTx` | No `Context`, no SQL |
| `api.zig` | Calls services only; `ctx.json` | No `zent.sql_*` imports |
| `module.zig` | zmodu `info` / `init` / `deinit` | Independent of the data stack |

For one transaction across entities use `zent.codegen.client.beginTx`, not two driver transactions. Duplicate into plain DTOs in persistence (`zent-modulith` does this) so `Managed` and `deinitEntity` never reach HTTP.

### 5.1 Write-mode differences

| | zmodu (sqlx `Repository`) | zent (create/update builders) |
|---|---|---|
| Write mode | Whole entity: `insert(entity)` writes every column | Builder: `Create.setFieldValue` / `Update.set` write only set fields |
| nullable + null | Writes `NULL`, overriding the DB default | Not written, so the default applies |
| Partial INSERT | `insertOmitNulls(allocator, entity)` | Native |
| Partial UPDATE | `updatePartial(allocator, entity)` | Native |

zent's `CreateBuilder.saveInternal` iterates only explicitly set values, so the default-override problem does not exist there. On the zmodu side `insert`/`update` keep whole-field semantics (`null` explicitly clears); opt in for defaults or partial updates:

```zig
_ = try repo.insertOmitNulls(allocator, entity); // nullable-null columns take the DB default
try repo.updatePartial(allocator, entity);       // only non-null fields change
```

## 6. Startup pipeline

Minimal path:

```zig
const graph = comptime zent.codegen.graph.buildGraph(&.{ Tenant, Product });
var drv = try zent.sql_sqlite.SQLiteDriver.open(alloc, path);
defer drv.close();
try zent.sql_schema.migrateSchema(alloc, drv.asDriver(), graph.types);
var client = zent.codegen.client.makeClient(graph.types, alloc, drv.asDriver());
```

Production: use `ConnPool` and pass `asDriver()` to `makeClient`; migrations are conservative by default (`drop_columns` and `allow_data_loss` need explicit `MigrateOptions`); `:memory:` means one connection. Order: open/pool → `migrateSchema` → `makeClient` → inject persistence → start modules → listen.

### 6.1 Testing

`TestEnv` creates one in-memory SQLite per test; `reset()` drops schema tables and re-migrates. It forwards `zent.helpers` through `examples/_shared/zent_helpers.zig`; it does not pull zent into zmodu core.

```zig
const Env = zent_helpers.TestEnv(infos);
var env = try Env.init(std.testing.allocator);
defer env.deinit();
try env.reset(); // next assertions start from a fresh schema
```

### 6.2 Production connection pool

```zig
// `openDb(a) !SQLiteDriver` wraps SQLiteDriver.open(a, "app.db").
var pool = try Pool.init(allocator, .{ .io = io, .min_connections = 2, .max_connections = 8, .connect = openDb });
defer pool.deinit();
try zent.sql_schema.migrateSchema(allocator, pool.asDriver(), infos);
var client = zent.codegen.client.makeClient(infos, allocator, pool.asDriver());
```

Do not leak individual pooled connections to modules. Ensure no borrow or query is in flight before closing the pool.

### 6.3 Observability

`sql_logger.Logger` callbacks take no context, so forward to `std.log` (or an application `StructuredLogger`).

```zig
fn onQuery(c: zent.sql_logger.LogContext) void { std.log.debug("zent query [{s}] {s} ({d}us, {d} rows)", .{ c.table_name, c.sql, c.duration_us, c.rows_affected }); }
fn onExec(c: zent.sql_logger.LogContext) void { std.log.debug("zent exec [{s}] {s} ({d}us, {d} rows)", .{ c.table_name, c.sql, c.duration_us, c.rows_affected }); }
fn onError(c: zent.sql_logger.LogContext) void { std.log.err("zent SQL error [{s}] {s}: {any}", .{ c.table_name, c.sql, c.@"error" }); }
const logger = zent.sql_logger.Logger{ .onQuery = onQuery, .onExec = onExec, .onError = onError };
zent.codegen.client.SetLogger(infos, &client, logger);
```

Log metadata only; never log passwords, tokens or sensitive values. Put the application trace id in `LogContext.trace_id`.

### 6.4 Transactions

zent v0.31+ opens a typed transaction from a shared driver or pool: `zent.codegen.beginTxFromDriver(infos, pool.asDriver(), alloc)`; re-entry degrades to a savepoint. Use it for cron jobs and event consumers.

Use one `TxClient` for cross-entity writes. For a partial rollback, run savepoints on the underlying `Tx`, then commit or roll back exactly once and `deinit` once:

```zig
var tx = try zent.codegen.client.beginTx(infos, client);
defer tx.deinit();
_ = try tx.tx.exec("SAVEPOINT order_item", &.{});
// tx.client.order.Create() / tx.client.order_item.Create() ...
_ = try tx.tx.exec("RELEASE SAVEPOINT order_item", &.{});
try tx.commit();
```

On an unrecoverable error call `tx.rollback()` and never `commit()`. Savepoints do not replace the outer commit or rollback.

## 7. Schema and edges

```zig
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Product = Schema("Product", .{
    .fields = &.{ field.Int("tenant_id"), field.String("name"), field.Int("price_cents") },
});

// With edges: register both sides in the graph and use edge.To / From / M2M.
// pub const edges = &.{ edge.To("products", Product) };
```

- Table and entity names are stable. Renaming is a migration, never a silent change.
- Every tenant-scoped model declares `tenant_id` or carries a privacy filter; at least one.
- Indexes, enums, JSON and `TimeMixin` use the zent schema API, never ad-hoc DDL in services.

## 8. Persistence contract

```zig
const graph = zent.codegen.graph.buildGraph(&.{ model.Tenant, model.Product });
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);

pub const CatalogStore = struct {
    allocator: std.mem.Allocator,
    client: Client,
    pub fn createProduct(self: *CatalogStore, tenant_id: i64, name: []const u8, price_cents: i64) !i64 {
        var b = try self.client.product.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("price_cents", price_cents);
        const row = try b.Save();
        return row.id;
    }
    pub fn listProducts(self: *CatalogStore, tenant_id: i64) ![]ProductRow {
        var q = self.client.product.Query();
        defer q.deinit();
        _ = try q.Where(.{self.client.product.predicates.tenant_idEQ(.{ .int = tenant_id })});
        var found = try q.All();
        defer self.client.product.deinitRows(&found); // page release, zent >= 0.40
        // duplicate into ProductRow DTOs ...
    }
};
```

| Prefix | Semantics |
|--------|-----------|
| `find*` | `!?T` (null when absent) |
| `get*` / `list*` | `!T` / `![]T` |
| Result release | `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)` (zent ≥ 0.40); the list must be `var` because the helper empties it |
| Tenant filter | Predicate or privacy policy, always present |
| Public return | DTOs; state who frees what |

## 9. Privacy and hooks

- Attach `policy` to the schema; inject `PrivacyContext` (roles, tenant, viewer) on the request path.
- Rules are allow / deny / filter; filters suit "only rows of my shop".
- Test with no context, a wrong tenant and cross-tenant reads; all must fail or return nothing.
- `before` returns `ValidationFailed` / `Forbidden` to cancel a write; `after` does audit and cache invalidation only.
- Never open a second driver transaction or make a blocking remote call inside a hook.

## 10. Memory and errors

| Object | Rule |
|--------|------|
| `Query().All()` | `Managed(Entity)`; prefer `client.<entity>.deinitRows(&rows)`; `deinitEntity(infos, info, &e, alloc)` + `list.deinit()` still works |
| `Create()` builder | `defer builder.deinit()` |
| `driver.Tx` / `TxClient` | Exactly one `deinit` after commit or rollback |
| `deinitEntity` | Pass a mutable pointer (`&entity`) |
| DTO strings | Duplicate in persistence; free in the caller |
| Request-scoped copies | `dupeEntityTo(req_arena, …)` deep-copies fields, typed JSON and two edge levels; `managedEntity` binds the owning allocator |

Persistence raises domain and driver errors; `api` maps them to HTTP status and text without swallowing I/O or DB errors.

## 11. Dependency wiring

zent ships a `build.zig.zon` module named `zent`. Pin a git tag in production; a path dependency replaces the URL for local work.

```zon
.zent = .{
    .url = "https://github.com/chy3xyz/zent/archive/refs/tags/v0.97.0.tar.gz",
    .hash = "<fill after zig fetch>",
},
```

```zig
const zent_dep = b.dependency("zent", .{
    .target = target,
    .optimize = optimize,
    .pg = false,    // zent >= v0.76.0: skip translate-c for drivers you do not import
    .mysql = false,
});
exe_mod.addImport("zent", zent_dep.module("zent"));
```

Disabling a driver you do import fails at first use (`no module named 'pg_c'`), never silently. `zent-modulith` disables pg and mysql; `metaverse-creative` disables mysql only. End-to-end cost on a developer machine was unchanged (763 MiB / 80 s vs 723 MiB / 82 s), because the skipped steps run in parallel with the SQLite step.

On the zmodu side, path dependencies still `addImport("zmodu")` and use `db_link.Features.sqlite_only` so zmodu's sqlx does not link libpq or mysql. Full rules: [SQLX_DRIVERS.md](../guide/SQLX_DRIVERS.md) §8.

Upgrade procedure: change the pin → delete `.zig-cache` → rebuild. Zig 0.17 incremental caches reuse the previously fetched module, so "it compiled" may still be the old version. v0.96.0 → v0.97.0 was verified this way for both examples (`zent-modulith` smoke 44/0 with no leaks; `metaverse-creative` `zig build demo` reports `demo_ok`).

## 12. Anti-patterns

| Anti-pattern | Correct approach |
|--------------|------------------|
| Building queries in `api` with `import zent` | Call a service, then persistence |
| Mixing a zent driver and a sqlx client, or one transaction across stacks | Separate pools and modules; same stack or an outbox |
| Missing `deinitEntity` on a list | Fixed `defer` template |
| Business workflow entirely in hooks | Hooks are cross-cutting; orchestration lives in services |
| No privacy policy and no `tenant_id` | Enforce one of the two |
| `allow_data_loss` by default | Explicit, auditable `MigrateOptions` |
| Multi-connection `:memory:` | One connection, or a file/server database |

## 13. Checklist

- [ ] Schema lives in `model.zig`; HTTP does not import `zent.sql_*`
- [ ] Startup: open/pool → `migrateSchema` → `makeClient`; production uses `ConnPool` and conservative migrations
- [ ] Lists: `client.<entity>.deinitRows(&rows)` with `var rows`; builders and transactions `defer deinit`
- [ ] Tenant: predicate or `PrivacyContext`
- [ ] Public return values are DTOs, not zent entity lifetimes
- [ ] No zent driver passed into a sqlx client
- [ ] Same transaction across modules means the same stack; cross-domain uses the event bus or outbox

## 14. Upgrade contracts

Run these before reading the table:

```bash
zmodu audit .                 # tenant source / bare panic / shared maps / alignCast / allocator ownership / entropy (b19-b24)
zig build check-production    # bare catch / catch unreachable
zig build test                # shape and error-set snapshots, including doc-code consistency
```

| Version | Contract | Consumer action |
|---------|----------|-----------------|
| v0.97 | Package graph is a DAG; export paths unchanged (`zent.base`, `zent.services`, `zent.migrate` are new names); comptime budgets centralized in `base/budget.zig` (`flat`, `graph(tables)`). | None; repin and rebuild. |
| v0.96 | Each migration plan statement runs in a savepoint (PG/SQLite); rejected statements roll back alone and return `error.MigrationStatementRejected`; classified errors pass through. Raw `?` SQL on PG needs `sql_dialect.translatePlaceholdersAlloc`. Cross-graph edge targets no longer guess table names or emit constraints. | Add a `switch` arm; translate raw SQL on PG. |
| v0.93–v0.95 | PG catalog reads degrade when `pg_am` / `pg_proc` / `pg_extension` are missing (`error.IndexCatalogUnavailable`, `error.ForeignKeyCatalogUnavailable`); migration double-free fixed. `zent.walltime` for wall-clock timestamps (durations stay on `sql_logger.nowUs()`); `Row.textDup/blobDup` plus the borrowed-row lifetime contract; `ownedCopy` / `client.<entity>.ownedCopy`; `migrateSchemaInTx` (caller owns the transaction); PG extension precheck (`error.MissingPostgresExtension`) with zero DDL executed. | Add `MissingPostgresExtension` to `CreateTablesError` switches. |
| v0.88–v0.92 | `QueryBuilder.joinEdge` for m2o/o2o edges with the FK in this table (o2m/m2m rejected at compile time; `JoinWithGroupBy`); `field.Vector` + distance predicates (PG-only); `field.Other` / `.SqlType`; index `.Using/.Method/.OpClass`; `add_missing_foreign_keys`; PG `field.Bytes` fixed both ways. | None beyond error-set review. |
| v0.84–v0.86 | EntQL addresses fields by name first (`UnknownField` otherwise); `ShardSet` borrows a `ShardRouter` (breaking ownership); `field.String.VarChar(n)` rejects overlong values on every dialect; `client.<entity>.AllOwned(allocator)`. | Hold and `deinit` the router; do not mutate a copied router after `init`. |
| v0.78–v0.82 | `insertMany` / `upsertMany` take `tenant_id` as a parameter and ignore the entity's tenant column (breaking signature); `cursorPage` rejects nullable integer cursor columns (`error.NullableCursorColumn`); Zig is pinned to 0.17.0 stable via `minimum_zig_version`, and consumer code migrates `std.builtin` → `std.lang` and `builtin.os.tag` → `builtin.target.os.tag`. Single-value aggregates (`Sum`, `Avg`, `Max`, `Min`, `SumOrZero`, `AggregateOne`, `AggregateText`) reject `GROUP BY` (`error.GroupByNotSupported`); `SaveOne`/`ExecOne`/`ForceExecOne` report `RowsAffectedUnknown` instead of `NotFound` when a driver has no count. | Pass the tenant; make cursor columns non-nullable; upgrade the toolchain; use `AggregateBy` / `GroupCount` for grouped aggregates. |
| v0.73–v0.76 | `CrudService.get` is now `getOwned`; free those rows with `deinitRowWith(allocator, &e)`. Empty `Sum`/`Avg` return `EmptyAggregate`; EntQL rejects unknown fields before lowering. A junction name colliding with an entity table reports `junction_name_collision` as read-breaking (`migrateSchema` only warns). OOM leaks fixed in `Builder.initCapacity`, `Builder.takeQuery`, `Selector.init`. | Rename call sites and use the matching deinit; rename one colliding side. |
| v0.67–v0.72 | SQLite enforces foreign keys (`PRAGMA foreign_keys = ON`, read back per connection); dangling references fail and cascades run. PG `23502`/`23503` no longer map to `UniqueViolation`. `Restore` applies policies and interceptors; `queryTargets*` report mid-read failures instead of a short page. Missing `last_insert_id` returns `error.MissingLastInsertId` instead of `0`, MySQL bulk insert runs one statement per row, `SaveError` gains `InconsistentRowFields` / `MissingPrimaryKey`, and eager-load targets project columns in scan order so `ALTER TABLE ... ADD COLUMN` cannot shift values. | Adjust test and cleanup order (children first); handle the error and add `switch` arms; opt out per connection with `.{ .enforce_foreign_keys = false }`. |
| v0.54–v0.66 | `CrudService.create(entity, tenant_id)` takes the tenant as a parameter; `driver.Error` gained `ParamCountMismatch` and `PoolWaitTimeout`; MySQL `String`/`Enum` become `VARCHAR(255)`; empty `dept_ids` materializes `1 = 0`; `BulkDelete` without a predicate returns `error.NoPredicate`. | Update signatures, exhaustive switches and call sites that relied on empty-list or no-predicate behavior. |
| v0.38–v0.41 | `queryTargets*` fail closed (`*Unscoped` variants opt out explicitly); `zent.scope` renders the read contract for raw SQL; lenient scanners exist for LEFT JOIN and DTO output; `deinitRows` accepts value, pointer and `*const`. | Rewrite raw SQL with `zent.scope`. |
| v0.34–v0.37 | `sql.RawArgs` (`error.RawArgCountMismatch`); aggregate helpers; outbox `claim` plus `requeueStale`; `max_wait_ms` actually waits (`PoolExhausted` after the budget); nested eager loads cost one query per level. | Add `requeueStale` sweepers; size `max_wait_ms`. |
| v0.13–v0.30 | `withTimeout(ms)` maps to `statement_timeout` (PG), `MAX_EXECUTION_TIME` (MySQL) or a deadline (SQLite). JSON from query paths is owned by the per-entity arena. `field.Time` is BIGINT epoch seconds on every dialect (existing PG tables need a column migration). `SaveOrUpdateOn` / `SaveIgnore`, `Row.tryGet*`; MySQL `ContainsEscaped` uses `!`. | Migrate PG time columns; do not free scanned JSON. |

Two traps this repository hit:

- **Allocator mismatch on `getOwned` rows.** Rows produced by a function that takes an allocator (the `get` / `getOwned` family, `queryRowOwned`, `scanRowsToOwned`, `AllIn(arena)`) are freed with `deinitRowWith(allocator, &e)` or by the arena. Only driver-scanned rows (`Query().All()`, builder `Save()`) go to `deinitRow(&e)`. Mixing them is a cross-allocator free that kills the process; `zmodu audit` b23 catches it.
- **Stale incremental cache.** After a pin change, `rm -rf .zig-cache` (and stale `zig-pkg/<old version>` directories) before building, or you validate the old module.

## 15. Practical boundaries

| Capability | Use it when | Avoid it when / traps |
|------------|-------------|-----------------------|
| `sql.RawArgs(sql_text, args)` (0.34) and typed predicates `In`/`NotIn`/`IsNull`/`NotNil`/`HasPrefix`/`HasSuffix`/`ContainsFold`/`EQFold` (0.35) | `BETWEEN`, function calls, complex `IN`, and user-input matching | Raw-arg count mismatches are runtime `error.RawArgCountMismatch`; LIKE variants escape wildcards, so `%` means the input is not user input. |
| `SumOrZero` / `AggregateOne` / `AggregateText` / `AggregateBy` (0.34) | Empty sets must be 0, single-value aggregates, exact money via `AggregateText` | No `AggregateBy` for money (f64 rounding); free `Managed(GroupMetric)` with `freeGroupMetrics`. |
| `SaveOrUpdateOnWith` (0.34) | Upsert with expressions such as `{t:receive_num} + 1` | On SQLite an expression switches from `INSERT OR REPLACE` (breaks FKs/ROWID) to `ON CONFLICT DO UPDATE`. |
| Edge writes `AddEdgeIDs` / `RemoveEdgeIDs` / `SetEdgeIDs` / `ClearEdge` (0.35) | Maintaining junctions or moving o2m/o2o foreign keys | Not atomic on their own; wrap in `beginTx`. Non-null FKs reject detach at compile time. |
| `Outbox.claim` + `requeueStale` (0.35/0.36) | Multiple dispatchers; recover rows left `processing` by a crash | `pending` becomes read-only; the stale threshold must exceed the longest publish (examples use 300 s). |
| Migration lock + checksum (0.36) | Multiple instances starting during a rollover | Without advisory-lock rights, PG degrades to a warning; never edit an applied migration (`error.MigrationChecksumMismatch`). |
| `StorageKey` (0.36) | Existing column names do not match field names | Field names drive predicates and DDL; check `codegen.graph.columnName` when debugging. |
| `crud_helpers.queryRows` (0.41) and `zent.scope.forClient` + `withClause` (0.39) | Hand-written SQL, with `zent.scope` splicing tenant and privacy filters | `queryRows` is a raw path with no soft delete, privacy or interceptors; `withClause` is not optional (a policy table without context returns `PrivacyDenied`), and `table` is comptime. |
| `queryTargets` / `queryTargetsByValue` (0.36–0.38, fail-closed) | Batch neighbor reads with the same scope as `WithEdge`, including UUID/text keys | Needing no isolation means renaming to `*Unscoped` and justifying it in review. |
| Lenient scanners (0.38/0.39) | LEFT JOIN, aggregate output, nullable DTOs | Entity reads stay strict; a NULL in a non-null column means the row violates the schema. |
| `BulkInsert` + `chunkRows(n)` (0.36) | Very large inserts (SQLite <3.32 allows 999 parameters; MySQL `max_allowed_packet`) | Chunking still means multiple statements: wrap in a transaction or accept partial success. |
| Pool wait `max_wait_ms` (0.37) | Queueing is acceptable (3–5 s budget plus metrics) | Default `0` is non-blocking. `ConnPool.deinit` requires a quiet period. |
| Nested eager load (0.37) | Two-level loads like `WithEdge("posts.comments")` that used to be N+1 | Preload targets filter soft deletes only, without tenant or row policy; add predicates explicitly. |

## Reference

| Resource | Purpose |
|----------|---------|
| [`examples/zent-modulith/`](../../examples/zent-modulith/) | zmodu HTTP + zent layering smoke test |
| [`examples/tenant-shop/`](../../examples/tenant-shop/) | sqlx + transaction/outbox flagship path |
| [MODULE_LAYERS.md](../guide/MODULE_LAYERS.md) | model / persistence / service rules |
| [chy3xyz/zent](https://github.com/chy3xyz/zent) | The ORM itself, with `run-complex` / `run-pool` |
