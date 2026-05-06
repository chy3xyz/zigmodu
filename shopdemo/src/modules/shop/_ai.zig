// ═══════════════════════════════════════════════════════════
// AI Context: shop module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_shop_access — 17 columns
//   zmodu_shop_fullreduce — 12 columns
//   zmodu_shop_login_log — 6 columns
//   zmodu_shop_opt_log — 11 columns
//   zmodu_shop_role — 6 columns
//   zmodu_shop_role_access — 5 columns
//   zmodu_shop_user — 9 columns
//   zmodu_shop_user_role — 6 columns
//
// Public API: service.zig
//   listZmoduShopAccesss / getZmoduShopAccess / createZmoduShopAccess / updateZmoduShopAccess / deleteZmoduShopAccess
//   listZmoduShopFullreduces / getZmoduShopFullreduce / createZmoduShopFullreduce / updateZmoduShopFullreduce / deleteZmoduShopFullreduce
//   listZmoduShopLoginLogs / getZmoduShopLoginLog / createZmoduShopLoginLog / updateZmoduShopLoginLog / deleteZmoduShopLoginLog
//   listZmoduShopOptLogs / getZmoduShopOptLog / createZmoduShopOptLog / updateZmoduShopOptLog / deleteZmoduShopOptLog
//   listZmoduShopRoles / getZmoduShopRole / createZmoduShopRole / updateZmoduShopRole / deleteZmoduShopRole
//   listZmoduShopRoleAccesss / getZmoduShopRoleAccess / createZmoduShopRoleAccess / updateZmoduShopRoleAccess / deleteZmoduShopRoleAccess
//   listZmoduShopUsers / getZmoduShopUser / createZmoduShopUser / updateZmoduShopUser / deleteZmoduShopUser
//   listZmoduShopUserRoles / getZmoduShopUserRole / createZmoduShopUserRole / updateZmoduShopUserRole / deleteZmoduShopUserRole
//
// Extension points:
//   service_ext.zig — custom business logic (survives regeneration)
//   api_ext.zig — custom HTTP endpoints (survives regeneration)
//
// File map:
//   module.zig — declaration layer (module contract)
//   model.zig — data structures + jsonStringify
//   persistence.zig — ORM repositories
//   service.zig — CRUD delegation + event hooks
//   api.zig — HTTP routes + JSON handlers
//   root.zig — barrel exports
//   test.zig — smoke tests
// ═══════════════════════════════════════════════════════════
