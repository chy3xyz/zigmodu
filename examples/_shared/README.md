# Shared example build helpers

| File | Role |
|------|------|
| [`db_link.zig`](db_link.zig) | Parse `-Ddb=` / `.db=`, set `build_options.enable_*`, link system DB libs |
| [`zent_helpers.zig`](zent_helpers.zig) | zent `StoreEnv` / `TestEnv` (see [`docs/reference/ZENT.md`](../../docs/reference/ZENT.md)) |

Path-dependent examples cannot `@import("../_shared/…")` — they symlink `db_link.zig` → here. Full consumer guide: [`docs/guide/SQLX_DRIVERS.md`](../../docs/guide/SQLX_DRIVERS.md).
