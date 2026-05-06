// ═══════════════════════════════════════════════════════════
// AI Context: supplier module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_supplier — 36 columns
//   zmodu_supplier_access — 17 columns
//   zmodu_supplier_account — 10 columns
//   zmodu_supplier_apply — 16 columns
//   zmodu_supplier_capital — 8 columns
//   zmodu_supplier_cash — 14 columns
//   zmodu_supplier_category — 6 columns
//   zmodu_supplier_deposit_order — 15 columns
//   zmodu_supplier_deposit_refund — 8 columns
//   zmodu_supplier_login_log — 7 columns
//   zmodu_supplier_opt_log — 12 columns
//   zmodu_supplier_role — 7 columns
//   zmodu_supplier_role_access — 5 columns
//   zmodu_supplier_service — 9 columns
//   zmodu_supplier_service_apply — 8 columns
//   zmodu_supplier_service_security — 8 columns
//   zmodu_supplier_user — 11 columns
//   zmodu_supplier_user_role — 6 columns
//
// Public API: service.zig
//   listZmoduSuppliers / getZmoduSupplier / createZmoduSupplier / updateZmoduSupplier / deleteZmoduSupplier
//   listZmoduSupplierAccesss / getZmoduSupplierAccess / createZmoduSupplierAccess / updateZmoduSupplierAccess / deleteZmoduSupplierAccess
//   listZmoduSupplierAccounts / getZmoduSupplierAccount / createZmoduSupplierAccount / updateZmoduSupplierAccount / deleteZmoduSupplierAccount
//   listZmoduSupplierApplys / getZmoduSupplierApply / createZmoduSupplierApply / updateZmoduSupplierApply / deleteZmoduSupplierApply
//   listZmoduSupplierCapitals / getZmoduSupplierCapital / createZmoduSupplierCapital / updateZmoduSupplierCapital / deleteZmoduSupplierCapital
//   listZmoduSupplierCashs / getZmoduSupplierCash / createZmoduSupplierCash / updateZmoduSupplierCash / deleteZmoduSupplierCash
//   listZmoduSupplierCategorys / getZmoduSupplierCategory / createZmoduSupplierCategory / updateZmoduSupplierCategory / deleteZmoduSupplierCategory
//   listZmoduSupplierDepositOrders / getZmoduSupplierDepositOrder / createZmoduSupplierDepositOrder / updateZmoduSupplierDepositOrder / deleteZmoduSupplierDepositOrder
//   listZmoduSupplierDepositRefunds / getZmoduSupplierDepositRefund / createZmoduSupplierDepositRefund / updateZmoduSupplierDepositRefund / deleteZmoduSupplierDepositRefund
//   listZmoduSupplierLoginLogs / getZmoduSupplierLoginLog / createZmoduSupplierLoginLog / updateZmoduSupplierLoginLog / deleteZmoduSupplierLoginLog
//   listZmoduSupplierOptLogs / getZmoduSupplierOptLog / createZmoduSupplierOptLog / updateZmoduSupplierOptLog / deleteZmoduSupplierOptLog
//   listZmoduSupplierRoles / getZmoduSupplierRole / createZmoduSupplierRole / updateZmoduSupplierRole / deleteZmoduSupplierRole
//   listZmoduSupplierRoleAccesss / getZmoduSupplierRoleAccess / createZmoduSupplierRoleAccess / updateZmoduSupplierRoleAccess / deleteZmoduSupplierRoleAccess
//   listZmoduSupplierServices / getZmoduSupplierService / createZmoduSupplierService / updateZmoduSupplierService / deleteZmoduSupplierService
//   listZmoduSupplierServiceApplys / getZmoduSupplierServiceApply / createZmoduSupplierServiceApply / updateZmoduSupplierServiceApply / deleteZmoduSupplierServiceApply
//   listZmoduSupplierServiceSecuritys / getZmoduSupplierServiceSecurity / createZmoduSupplierServiceSecurity / updateZmoduSupplierServiceSecurity / deleteZmoduSupplierServiceSecurity
//   listZmoduSupplierUsers / getZmoduSupplierUser / createZmoduSupplierUser / updateZmoduSupplierUser / deleteZmoduSupplierUser
//   listZmoduSupplierUserRoles / getZmoduSupplierUserRole / createZmoduSupplierUserRole / updateZmoduSupplierUserRole / deleteZmoduSupplierUserRole
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
