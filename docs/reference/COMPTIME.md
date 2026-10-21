# Compile-Time Budget (`@setEvalBranchQuota`)

zmodu performs route table expansion, `RouteMeta` indexing, module dependency graph validation, `Repository` tenant-column checks, and bounded `Mailbox(T, capacity)` validation at compile time. To prevent large projects from hitting Zig's default comptime branch limit (`1000`), framework comptime loops scale `@setEvalBranchQuota` proportionally to their input size.

## 1. Scaling Formula

`src/core/EvalQuota.zig` defines the scaling formula:

```text
quota = base + per_unit * units
base = 1_000_000, per_unit = 20_000
```

- `units` is the number of items being analyzed (modules, struct fields, graph nodes, routes).
- `@setEvalBranchQuota` is an upper bound; unused quota has zero cost.
- In Zig, the **innermost** `@setEvalBranchQuota` call wins. A caller setting `10_000_000` cannot override a library function that hardcodes `1000`, so all internal comptime loops scale via `EvalQuota.forUnits`.

If your own comptime code analyzes large types, call `EvalQuota.forUnits`:

```zig
const EvalQuota = @import("zmodu").core.EvalQuota;

comptime {
    @setEvalBranchQuota(EvalQuota.forUnits(fields.len));
}
```

## 2. Verification Gate

- `src/test/ComptimeBudget.zig` generates and mounts **256 routes** into a full catalog at compile time. Any hardcoded quota or quadratic comptime regression fails the build immediately.
- `scripts/check-comptime-budget.sh` compiles the budget test and checks wall-clock time (`COMPTIME_BUDGET_SECS`, default `300s`) and peak RSS (`COMPTIME_BUDGET_RSS_MB`, default `4096` MiB).

## 3. Keeping Build Times Fast

Because every route handler and module is instantiated at compile time, build times grow with application size. If compilation slows down:
1. Split oversized route tables across domain modules rather than registering hundreds of routes in a single struct.
2. Avoid embedding large comptime strings inside `RouteMeta`.
3. Link only the SQL drivers you need (`-Ddb=sqlite` or `-Ddb=none`) during development.
