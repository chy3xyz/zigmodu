# SQLx ORM templates (`zmodu orm --backend sqlx`)

Embedded by `orm_tpl.zig` (`expandOrm`) via `@embedFile` (paths relative to `tools/zmodu/src/`).

## Placeholders

| Token | Example |
|-------|---------|
| `<<MODULE_NAME>>` | `user` |
| `<<PASCAL_MODULE>>` | `User` |

Edit files here, then `zig build` the zigmodu repo to rebuild the `zmodu` CLI.

Zent backend templates: [`../zent/README.md`](../zent/README.md).
