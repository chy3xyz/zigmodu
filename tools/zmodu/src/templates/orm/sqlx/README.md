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

`api_header.zig.tpl` emits ComptimeRouter `pub const routes` (`docs/ROUTE_TABLE.md`).
Handlers are `fn (*http.Context, *State) !void`; scaffold wires via `http.Router.scope.mountAll`.

Edit files here, then `zig build` the zigmodu repo to rebuild the `zmodu` CLI.

Zent backend templates: [`../zent/README.md`](../zent/README.md).
