# Shared example build helpers

| File | Role |
|------|------|
| [`db_link.zig`](db_link.zig) | Parse `-Ddb=` / `.db=`, set `build_options.enable_*`, link system DB libs |
| [`zent_helpers.zig`](zent_helpers.zig) | zent `StoreEnv` / `TestEnv` (see [`docs/ZENT.md`](../../docs/ZENT.md)) |

Path-dependent examples cannot `@import("../_shared/…")` — they symlink `db_link.zig` → here. Full consumer guide: [`docs/SQLX_DRIVERS.md`](../../docs/SQLX_DRIVERS.md).
