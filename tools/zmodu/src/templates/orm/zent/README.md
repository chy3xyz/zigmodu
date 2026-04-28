# Zent ORM templates (`zmodu orm --backend zent`)

Embedded by `orm_tpl.zig` (`expandOrm`) via `@embedFile` (paths relative to `tools/zmodu/src/`).

## Placeholders

| Token | Example |
|-------|---------|
| `<<MODULE_NAME>>` | `user` |
| `<<PASCAL_MODULE>>` | `User` |

Table/schema bodies are still generated in `main.zig` from parsed SQL; only headers, imports, and client shell live here.

**Relations:** generated `schema.zig` does not import `zent.core.edge` by default (avoids unused-import warnings). When you add `.edges` to a schema, add `const edge = zent.core.edge;` next to the other imports in `schema.zig` (or extend `schema_imports.zig.tpl` in this repo if you want it always-on).

Edit files here, then `zig build` the zigmodu repo to rebuild the `zmodu` CLI.
