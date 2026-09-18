# SQLx ORM templates (`zmodu orm --backend sqlx`)

Embedded by `orm_tpl.zig` (`expandOrm`) via `@embedFile` (paths relative to `tools/zmodu/src/`).

## Placeholders

| Token | Example |
|-------|---------|
| `<<MODULE_NAME>>` | `user` or `shop/order` |
| `<<PASCAL_MODULE>>` | `User` / `ShopOrder` |
| `<<GATE_NAME>>` | `user` / `shop_order` (slashes → `_`) |
| `<<NEST>>` | `.{ "user" }` / `.{ "shop", "order" }` |
| `<<SHARED_IMPORT>>` | `../../shared/` |
| `<<DEPS>>` | `&.{}` |
| `<<STD_IMPORT>>` | `const std = @import("std");\n`, or empty — see below |

`api_header.zig.tpl` emits ComptimeRouter `pub const routes` (`docs/ROUTE_TABLE.md`).
Handlers are `fn (*http.Context, *State) !void`; scaffold wires via `http.Router.scope.mountAll`.

`<<STD_IMPORT>>` appears in `service_header*.zig.tpl` and in `api_header.zig.tpl`.
The generated service body calls into `std` just for the email shape check, so
`generateModuleService` keeps the import when a column triggers it and drops it
otherwise (an unused `const std` fails `zmodu ci` deadcode in the generated
project). `api_header` needs it only for the `requireTenant` helper it gains
when a table is tenant-scoped, and `generateModuleApi` drops it for every other
module; `persistence_header` emits no `std.*` at all and carries no import.

Edit files here, then `zig build` the zigmodu repo to rebuild the `zmodu` CLI.

## `test.zig.tpl`

Real, runnable module tests — not a stub. Two cases, both against
`http.Testkit`:

1. repository insert / findById / delete round-trip over `openMemorySqlite`;
2. a `dispatch` against the generated POST route, asserting the envelope and
   that the row reached the database.

It needs `<<MODULE_NAME>>`, `<<PASCAL_MODULE>>` and `<<MODEL_NAME>>` (the emitter
calls `expandOrmTest`, because the module's types are named after the module
while the model is named after the table), plus `<<POST_DISPATCH>>` — the tail of
the one `dispatch` call, which the emitter fills with
`(&server, .POST, create_path, body)` and which `test_tenant.zig.tpl` widens to
`Opts(…, .attrs = …)` for a tenant table. Route paths come from `Api.nest` /
`Api.routes`, so it does not hardcode a URL.

**Status: wired (2026-09-18).** `orm_tpl.sqlx_test` embeds this file and
`writeModuleFiles` writes it out as `modules/<name>/test.zig` next to `api.zig`,
**only for single-table modules**; `generateScaffoldTestsZig` emits the matching
`test { _ = @import("modules/<name>/test.zig"); }` so `zig build test` picks it
up. Verified end-to-end: `zmodu scaffold` on a one-table schema produces a
project whose `zig build test` runs both cases below (7/7 pass).

Multi-table modules get no `test.zig`: this file reaches the model through
`model.<<PASCAL_MODULE>>`, which assumes the scaffold's default shape — one table
per module whose table name matches the module name. A module that aggregates
several tables (or a `--strip-prefix` rename) would make that the wrong type
name, so the emitter skips it rather than emitting a file that cannot compile.

`zmodu test <module>` still builds its own inline text and does not use this
template.

## `test_tenant.zig.tpl`

Appended to `test.zig` for a single-table module whose table carries the
configured tenant column (`--tenant-column`, default `tenant_id`). It drives the
generated **routes**, not the service methods, so it covers the whole chain —
handler tenant lookup, service call, SQL predicate.

Four things have to hold, and the test asserts each:

1. a tenant-1 POST whose body claims tenant 2 lands in tenant 1 (`createByTenant`
   stamps the column from the identity);
2. tenant 1's `list` returns exactly its own row;
3. `get` on tenant 2's row id, with tenant 1's identity, answers the not-found
   envelope instead of the row;
4. a request with **no** tenant attr is rejected (401), not answered unscoped.

Placeholders: `<<TENANT_COLUMN>>` (the SQL/field name) on top of the three
`expandOrmTest` names. Because the module's handlers now require a tenant, the
base template's POST test would fail for such a table; `<<POST_DISPATCH>>` in
`test.zig.tpl` is what lets both share one file while a module without the tenant
column still renders the original bytes.

Zent backend templates: [`../zent/README.md`](../zent/README.md).
