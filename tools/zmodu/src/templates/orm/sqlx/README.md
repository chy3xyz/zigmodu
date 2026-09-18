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

`<<STD_IMPORT>>` appears only in `service_header*.zig.tpl`: the generated service
body calls into `std` just for the email shape check, so `generateModuleService`
keeps the import when a column triggers it and drops it otherwise (an unused
`const std` fails `zmodu ci` deadcode in the generated project). `persistence_header`
and `api_header` emit no `std.*` at all and carry no import.

Edit files here, then `zig build` the zigmodu repo to rebuild the `zmodu` CLI.

Zent backend templates: [`../zent/README.md`](../zent/README.md).
