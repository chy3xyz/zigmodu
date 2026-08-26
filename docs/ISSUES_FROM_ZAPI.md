# Issues from zapi — zigmodu backlog

> Sourced from the **zmcanyin / zapi** ThinkPHP-compatible commerce API on ZigModu
> (`zigmodu_ws/zmcanyin_zent/zapi`).  
> Complements [`FRAMEWORK_BACKLOG.md`](FRAMEWORK_BACKLOG.md) (landed ergonomics) with
> **auth / envelope / identity** gaps that forced app-level patches.  
> Status: **Open** unless marked. Prefer GitHub issues linked from the `#` column.

Suggested landing order: **M1 → M2 → M4 → M5 → M3 → …**.

> **v0.15.31 落地**：M1–M9、M11、M12、M14 已进框架（见 `ROUTE_TABLE.md` §7.2/§7.3）；M10 deferred、M13 declined（理由见追踪表）。

---

## P0

### M1 — Catalog is the sole auth truth

| | |
|--|--|
| **Problem** | zapi maintains `middleware/public_paths.zig` **in parallel** with `RouteSpec.meta.auth`. Drift allowed unauthenticated writes (e.g. admin `setting/Service` POST). ComptimeRouter already has `isPublic`; zapi auth middleware ignores it and uses a string path list. |
| **Evidence** | `zapi/src/middleware/{auth,public_paths}.zig`; `zapi/src/main.zig` (catalog note); `zigmodu` `ComptimeRouter.zig` `Auth` / `isPublic`; unused `jwtAuthFromCatalog` |
| **Proposal** | Generic `authFromCatalog(slot, Backend)` that skips JWT/session iff catalog says public for `(method, path)`. Deprecate / delete parallel bypass lists in consumers. |
| **Acceptance** | zapi can delete `public_paths.zig`; changing `.meta.auth` alone changes runtime. |
| **Status** | **Landed v0.15.31** |

### M2 — Build/test audit: meta ↔ runtime auth

| | |
|--|--|
| **Problem** | Comments say “keep bypass in sync” — not enforceable. |
| **Proposal** | `zig build` or test helper: every `.auth = .public` route is reachable as public; every bypass entry (if any remain) matches catalog; fail CI on drift. |
| **Acceptance** | Intentional mismatch fails CI with file:line. |
| **Status** | **Landed v0.15.31** |

### M3 — Pluggable `AuthBackend` (not JWT-only)

| | |
|--|--|
| **Problem** | zapi uses Redis/token service + path-prefix roles; framework JWT middleware doesn’t fit → full custom middleware reimplements catalog skip. |
| **Evidence** | `zapi/src/middleware/auth.zig` (`requiredRoleForPath`, token extractors) |
| **Proposal** | `AuthBackend.verify(ctx) → Identity{ sub, aud, roles }`; catalog gate wraps any backend; JWT becomes one backend. |
| **Acceptance** | zapi auth mw shrinks to Backend + catalog wrapper. |
| **Status** | **Landed v0.15.31** |

### M4 — Unauthenticated response hook / envelope dialect

| | |
|--|--|
| **Problem** | Framework `sendError(401, …)` shape ≠ ThinkPHP `{ code: -1, msg, data }` that frontends expect (`renderUnauthenticated`). |
| **Evidence** | `zapi/src/contract/response.zig`; `Server.zig` `sendError` / `sendSuccess`; RuoYi dialect in `Page.zig` |
| **Proposal** | `AuthRejectFn` or `Envelope` dialect (ThinkPHP / RuoYi / ProblemDetails) used by auth middleware and helpers. |
| **Acceptance** | Catalog JWT reject emits consumer-configured envelope without forking middleware. |
| **Status** | **Landed v0.15.31** |

### M5 — Typed identity on `Context`

| | |
|--|--|
| **Problem** | `setAttr("user_id")` as string; three copies of `requireLogin` / `currentUid` / `getUserId` across api/shop/plus. |
| **Evidence** | `zapi` `order/helpers.zig`, `plus/common_auth.zig`, `shop/common.zig` |
| **Proposal** | `ctx.setIdentity(.{ .user_id, .tenant_id, .role })`; `ctx.userId() ?i64`; `ctx.requireUserId() !i64` (maps to dialect unauth). |
| **Acceptance** | zapi deletes duplicate helpers; handlers use typed getters. |
| **Status** | **Landed v0.15.31** |

---

## P1

### M6 — First-class envelope dialect API

Lift ThinkPHP `{code:1/0/-1}` + paginated `data.list.{data,total,…}` and RuoYi into `http.Envelope` + `ctx.ok` / `ctx.fail` / `ctx.unauth` / `ctx.paginated`. Deprecate conflicting `sendSuccess` semantics (ok=0 vs ThinkPHP ok=1).

### M7 — Tenant / `app_id` middleware

Resolve `AppID` / `appid` header + `app_id` param → `setAttr` / Identity.tenant; optional `requireTenant`. Motivated by `zapi/src/contract/app_id.zig` called from every write path.

### M8 — `RouteMeta.roles` (or portal)

Replace hardcoded path-prefix → role maps (`admin` / `shop` / `cashier`). Catalog auth checks roles from Identity.

### M9 — Wire resilience into Profiles (docs + opt-in)

`CircuitBreaker` / `RateLimiter` exist and Profiles land in `FRAMEWORK_BACKLOG`, but zapi `main` never attaches them. Document + sample pairing with catalog for payment/db slots.

### M10 — `!ApiResult(T)` auto-render

Handler returns structured result → middleware/wrapper renders via envelope dialect. Shrinks fat “parse → service → renderJson” handlers (`user/order_handlers` etc.).

---

## P2

### M11 — Typed attr getters

`getAttrInt` / `getAttrEnum` on Context.

### M12 — Shared token extractors

Token / `X-Token` / Bearer / legacy form body as `TokenSource` (today copied in zapi auth).

### M13 — Mount-time State pool

Reduce per-module `var mod_state` boilerplate in large `main.zig` mounts.

### M14 — OpenAPI securitySchemes from catalog auth

Already partial; document reject dialect + public routes in generated OpenAPI.

---

## Tracking

| ID | Title | P | Status |
|----|-------|---|--------|
| M1 | Catalog = sole auth truth | P0 | **Landed v0.15.31** (`authFromCatalog` + `AuthBackend`) |
| M2 | meta ↔ runtime auth audit | P0 | **Landed v0.15.31** (`Testkit.auditAuthCoverage`) |
| M3 | Pluggable AuthBackend | P0 | **Landed v0.15.31** (`AuthBackend` / `jwtBackend`) |
| M4 | Unauth envelope hook | P0 | **Landed v0.15.31** (`AuthRejectFn` / `envelopeReject`) |
| M5 | Typed Context identity | P0 | **Landed v0.15.31** (`ctx.setIdentity` / `userId` / `requireUserId`) |
| M6 | Envelope dialect API | P1 | **Landed v0.15.31** (`EnvelopeDialect` + `ctx.ok/fail/unauth/paginated`) |
| M7 | Tenant middleware | P1 | **Landed v0.15.31** (`tenantResolver`) |
| M8 | RouteMeta.roles | P1 | **Landed v0.15.31** (gate 先于 permission 检查) |
| M9 | Resilience profile wiring | P1 | **Landed v0.15.31** (docs: ROUTE_TABLE §7.3) |
| M10 | ApiResult auto-render | P1 | Deferred — dispatch 层改动大；M6 helpers 已覆盖主要瘦身诉求 |
| M11 | Typed attr getters | P2 | **Landed v0.15.31** (`getAttrInt` / `getAttrEnum`) |
| M12 | Token extractors | P2 | **Landed v0.15.31** (`TokenSource` / `extractTokenAny`) |
| M13 | State pool at mount | P2 | Declined — 审美性样板消减，收益不抵复杂度 |
| M14 | OpenAPI securitySchemes | P2 | **Landed v0.15.31** (catalog → `bearerAuth` + per-op `security`) |

When filing GitHub issues, title prefix `[zapi]` and link this file + the consumer path cited above.

See also: sibling backlog in **zent** — `zig_ws/zent/docs/ISSUES_FROM_ZAPI.md`.
