# API freeze and preview surface

Entry points on the frozen surface only grow before 1.0; `zmodu.runtime.*` is preview and may break during 0.x. The gate lives in `src/test/ApiFreeze.zig` and runs in the full suite because `src/tests.zig` imports it.

Every statement here is backed by a source, and every checkable claim maps to one assertion in the gate.

## Where the policy comes from

| Policy | Source |
|---|---|
| Deprecated aliases are removed no earlier than 1.0 | the deprecation table at the top of `UPGRADING.md` |
| `Application` / `Module` / DI / `EventBus` / HTTP public contracts only grow | `RUNTIME.md` §2 items 1–4 and 9 |
| `runtime.*` may break during 0.x | `RUNTIME.md` §2 item 10 |
| Every runtime breaking change is recorded in the §9 roadmap and the matching `UPGRADING.md` section | `RUNTIME.md` §2 |
| The current state of §12 / §13 / §14 | `RUNTIME.md` (worker pools, replay v1, supervision) |

The first decision this document records is an extension of the "only grow" rule: it applies to every category in the table below, not only the five named in `RUNTIME.md`. To shrink the frozen surface, delete a row; the sync test watches both sides. Extending it works the same way.

## Frozen entry point categories

What freezes is the category and its anchor symbol, not an enumerated export list. The full list stays in `root.zig` and `API.md`. The second column is asserted one by one in `src/test/ApiFreeze.zig` with `@hasDecl`.

| Category | Gate anchors | Basis |
|---|---|---|
| `zmodu` top level · lifecycle and module contract | `Application`, `ApplicationBuilder`, `builder`, `api`, `ModuleContext`, `ZmoduError`, `Result`, `Time`, `scanModules`, `ModuleInfo` | referenced |
| `zmodu` domain aliases (opt-in domains) | `http`, `data`, `security`, `observability`, `runtime`, `ai`, `im`, `web4`, `outbox`, `cron`, `migration`, `datapermission` | decided; renaming an alias breaks every consumer |
| `http` · routing and requests | `http.Server`, `http.Context`, `http.RouteSpec`, `http.RouteMeta`, `http.Router`, `http.CatalogSlot` | referenced |
| `http` · extractors and error rendering | `http.extractPath`, `http.extractQuery`, `http.extractJson`, `http.extractJsonValidated`, `http.extractMultipart`, `http.respondErr`, `http.setErrorMap`, `http.problemReject`, `http.useRfc7807Errors`, `http.productionProfile`, `http.sse`, `http.Testkit` | referenced |
| `http` / `security` · auth (Path A) | `http.jwtAuthFromCatalogWithPermissions`, `http.catalogLoaderFromTable`, `http.AuthBackend`, `http.jwtBackend`, `http.envelopeReject`, `http.permissionGateWith`, `http.tenantResolver`, `security.AppSecurity`, `security.PasswordEncoder`, `security.CatalogPermDb`, `security.JwksKeyRing` | decided; Path A is the default wiring in `AGENTS.md`. The gate checks names only, signatures are reviewed by hand |
| `data` · data layer | `data.Client`, `data.Repository`, `data.SqlxBackend`, `data.CrudService`, `data.CacheManager`, `data.MigrationRunner`, `data.sqlx`, `data.redis`, `data.orm`, `data.pool` | decided |
| `observability` | `observability.PrometheusMetrics`, `observability.DistributedTracer`, `observability.StructuredLogger`, `observability.ModuleLogger`, `observability.OtlpExporter`, `observability.LogScope` | decided |
| `zmodu` top level · resilience / scheduling / distribution | `CircuitBreaker`, `RateLimiter`, `Bulkhead`, `retry`, `cron`, `DistributedLock`, `Preflight`, `SagaOrchestrator`, `ClusterView`, `MembershipView` | decided |
| `zmodu` top level · DI / events / config / utilities | `Container`, `ScopedContainer`, `EventBus`, `ThreadSafeEventBus`, `FrozenMap`, `Params`, `ConfigManager`, `TomlLoader`, `Validator`, `panicHook` | referenced for the first four; the rest fall in the same category |
| `zmodu` top level · test helpers and extensions | `IntegrationTest`, `Benchmark`, `ContractTestRunner`, `ModuleTestContext`, `WebSocketServer`, `PluginManager` | decided |

## Preview surface (0.x may break)

This follows `RUNTIME.md` §2 item 10. The rows name the symbols §11–§14 document; what is "not done" or "deliberately not done" stays prose in `RUNTIME.md` and is reviewed by hand.

The checkable part is the second test in `src/test/ApiFreeze.zig`: these symbols are exposed through `zmodu.runtime.*` only and must not appear on the frozen top level. Adding `pub const Supervision = ...` to `root.zig` would hit the frozen surface with a change the preview rule allows.

| Preview source | Gate anchors |
|---|---|
| `runtime` · §3 worker / `Runtime` | `runtime.Runtime` |
| `runtime` · §12 worker pool / scheduler | `runtime.SpawnMode`, `runtime.SpawnConfig`, `runtime.SchedulerConfig`, `runtime.ExecutionClass`, `runtime.StopPolicy`, `runtime.PrecisionTimer` |
| `runtime.recorder` · §11 / §13 event recorder and replay | `runtime.Sequencer`, `runtime.recorder.Recorder`, `runtime.recorder.DeliveryLog`, `runtime.recorder.Replayer`, `runtime.recorder.TrackRef`, `runtime.recorder.LogStep` |
| `runtime` · §14 supervision tree | `runtime.Supervision`, `runtime.Group`, `runtime.GroupPolicy`, `runtime.Intensity` |

## How the gate works

`src/test/ApiFreeze.zig` reads both documents at test time and compares them with its own tables.

- Anchor tokens are `Domain.Name`, `Schema.Name` or a bare top-level name. Resolution uses the longest namespace prefix, so `runtime.recorder.*` entries must come first in the table.
- A table row is parsed only when its first column holds a backticked token; keep one there.
- Anchor resolution asserts that every symbol named in the frozen table resolves through `root.zig`.
- The sync test parses both tables here and compares the anchor sets in both directions.
- The deprecation test parses the table in `UPGRADING.md`, checks each row's replacement and removal plan, and reads the declaration markers.
- The removed and banner tests check that removed names stay off the top level and that every banner file is named in this document.

Failures print the document, the category and the symbol, for example `[api-freeze] docs/reference/API_FREEZE.md names ... as frozen, but nothing in src/test/ApiFreeze.zig checks it`.

## Deprecated aliases and removal dates

The table is not duplicated here; it sits at the top of `UPGRADING.md`. This document records how the gate governs it:

- Every row is asserted line by line: the deprecated name still resolves, and the current name it points at still exists (`replacementResolves` checks the third column).
- The declaration keeps its `DEPRECATED` marker and names the replacement.
- The table and the gate stay in sync both ways: a row without a gate fails, and a gate entry without a row fails.

### Removed records

The table promises only names that still work. A removed name would read as "still available" if it sat in it, so removals go into the record section of `UPGRADING.md`, and the gate asserts the opposite direction: the name must not reappear at the top level.

Each record carries four fields, and the gate checks all of them against the document:

| Field | `zmodu.App` / `zmodu.ModuleImpl` | `zmodu.extensions` |
|---|---|---|
| Evidence | commit `557190a` | `CHANGELOG.md` section `[0.15.0]` (no commit records it) |
| Implementation file | `src/api/Simplified.zig` | `src/extensions.zig` |
| Compiled import in `src/tests.zig` | `"api/Simplified.zig"` | `"extensions.zig"` |
| Replacement | `Application` | domain files (`zmodu.http.*`, `zmodu.data.*`) |

- `Simplified` (`App`, `ModuleImpl`, `Module`) was removed from `src/root.zig` as a block. The file-level guarantee is that the file is still compiled; the block is not promised to be supported.
- `zmodu.extensions.HttpServer` and the rest of the namespace are gone from the top level. The shim names still resolve to the same types as the domain files (asserted with `==`).

### File-level deprecation banners

`UPGRADING.md` explains why these two files are neither table rows nor removal records. The gate (`BANNERS`) pins:

- The banner stays within the first 1500 bytes of the file and names the replacement path.
- `src/extensions.zig` is still imported by the compile gate in `src/tests.zig`. `src/validation/Validator.zig` is not on that direct import list (the list imports `validation/ObjectValidator.zig`, `validation/FieldRules.zig` and `validation/FieldValidation.zig`), so the gate imports it itself and calls `notEmpty`, `validateStruct`, `email` and `validateStructCollect`, which keeps those signatures from rotting silently.
- Dependency direction for `src/validation/Validator.zig` and `http.FieldRules`: `http.FieldRules`, `http.validateRequest` and `http.extractJsonValidated` still resolve. The canonical `FieldRules` declaration lives in `src/validation/FieldRules.zig`, and the re-export in `http.FieldRules`, the one in `src/api/Extract.zig` and the `Validator.FieldRules` alias are the same type. The canonical implementation must not live in the deprecated file, the new home must not import it, and the deprecated file must still point at the new home. Together that proves deleting `Validator.zig` no longer breaks `http.FieldRules`. (`@import` matching uses the quoted spelling, so a file name in prose does not count as a dependency.)
- The `zmodu.Validator` alias resolves to a different type in `validation/ObjectValidator.zig`; the `!=` assertion is part of the check, since a self-reference would mean no migration happened.
- Dependency direction for the `validateStruct*` chain (`FIELD_VALIDATION_HOME`): the canonical declarations (16 `pub fn` / `pub const ... = struct`) live in `src/validation/FieldValidation.zig`, and each is asserted present there and absent from the deprecated file. The deprecated file has no `pub fn` at all: it is a layer of `pub const <name> =` aliases, with 17 spellings asserted. The new home must not import the deprecated file, the deprecated file must point at `FieldValidation.zig`, and the two `http.*` callers (`src/api/Extract.zig`, `src/api/middleware/Validation.zig`) must import the new home directly and not the deprecated file. Aliases and canonical types are compared with `==`, and both entry points are called once.
- The banner set is asserted as text, not as a support promise. The gate is what keeps the "kept alive" rationale from coming back.

## What the gate does not cover

1. Removed blocks are pinned as "cannot come back to the top level", not as "cannot be used". The gate does not assert the signatures inside `src/api/Simplified.zig`, nor that a cross-package `@import("zmodu/src/api/Simplified.zig")` keeps working (cross-package paths are unsupported). It does run `App.init` → `register(ModuleImpl(T).interface(...))` → `start` / `stop` through such an import, so the before-sample in `docs/API-MIGRATION.md` compiles only with the cross-package path, not with `zmodu.App`.
2. Signature accuracy ("does this function still take the same arguments") is out of scope, matching the existing rule in `src/test/DocsConsistency.zig`. Human review.
3. The 1.0 deletion itself is a human commitment. The gate only checks that the removal column says "no earlier than 1.0" and is not empty.
4. Per-symbol existence in `docs/reference/API.md` is covered by `src/test/DocsConsistency.zig`, which imports the same way a consumer does. This document does not repeat it.
5. The complete export list per category is not here. The sync test compares the anchor set named here with the gate's set, not the full `root.zig` exports.
6. Whether a `runtime.*` breaking change actually reached §9 and `UPGRADING.md` has no mechanical check. Human review.
7. Deprecation markers outside the table cannot be found exhaustively. The gate checks rows that exist; the reverse ("marked `DEPRECATED` but no row") has no general check, because markers sit both before declarations and in file-level banners, and scanning for them produces too many false positives. The approach is to close known cases one at a time: classify, then add a row, a record or a banner, then pin it.
   - In the table: `startAll` / `stopAll` (`src/root.zig`) and `http_server` (`src/http.zig`).
   - In the table: `RateLimiter.acquire` → `tryAcquire`, and the family `sendSuccess` / `sendFail` / `sendPageResult` / `sendJsonItems` → `ctx.json` (`src/api/Server.zig`). The four `send*` names are one family; the envelope-leak scan in `scripts/check-production.sh` treats them as one shape.
   - File-level banners, outside the table: `src/validation/Validator.zig` and `src/extensions.zig`. The first is now a thin compatibility layer whose two chains are decoupled, with no consumer blocker left; only the gate imports it. The second is a namespace removal, recorded under removed names and pinned as `@hasDecl(zmodu, "extensions") == false`.
   - No other markers are pending.
8. The marker check for `zmodu.stopAll` is not independent. The gate reads the 1500 bytes before a declaration (`marker_window`), and the two markers in `src/root.zig` are one line apart, so deleting only the `stopAll` comment does not fail. The same window applies to the four adjacent `send*` markers in `Server.zig` and to file-level banners (`banner_window` measured from the top of the file). The acceptance rule is "the marker is still there", not "the marker belongs to exactly this declaration".

## Adding or removing a row

1. To add a deprecated alias: add the row to the table in `UPGRADING.md` (never leave the removal column empty), add an entry to `ALIASES` in `src/test/ApiFreeze.zig` with a callable check, and let `replacementResolves` check the new name. Mismatched tables fail the sync test.
2. To change the frozen or preview surface: edit the table here and the matching table in the gate (`FREEZE_CATEGORIES` / `PREVIEW`). One side alone fails. Before adding a symbol to preview, ask whether it should stay under `runtime.*`; item 10 protects only that namespace.
3. To remove a row, change three places: delete it from the table, delete it from `ALIASES`, and add a record to the removed section of `UPGRADING.md` with name, evidence, replacement and where to find it today, plus an entry in `REMOVED`. The gate pins that the name does not return to the top level and checks the record's name, evidence and file path.
4. For a file-level `DEPRECATED` banner (neither a table row nor a removal): document it in `UPGRADING.md` and in the banner section here, and add an entry to `BANNERS` with the banner location, the replacement path and the dependency-direction assertions. Every file in `BANNERS` must be named in this document.

## Verify a doc change

```bash
bash scripts/test-fast.sh --db all --filter ApiFreeze
bash scripts/test-fast.sh --db all --filter DocsConsistency   # when API.md changed
```

Both tables and the gate change together; a passing run on one side only means the other table moved without its assertion.
