// ═══════════════════════════════════════════════════════════
// AI Context: user module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_user — 34 columns
//   zmodu_user_address — 12 columns
//   zmodu_user_balance_log — 8 columns
//   zmodu_user_cart — 10 columns
//   zmodu_user_cash — 23 columns
//   zmodu_user_coupon — 21 columns
//   zmodu_user_favorite — 8 columns
//   zmodu_user_gift_log — 7 columns
//   zmodu_user_grade — 19 columns
//   zmodu_user_grade_equity — 9 columns
//   zmodu_user_grade_log — 8 columns
//   zmodu_user_points_log — 7 columns
//   zmodu_user_referee — 7 columns
//   zmodu_user_sign — 11 columns
//   zmodu_user_tag — 5 columns
//   zmodu_user_task_log — 8 columns
//   zmodu_user_visit — 9 columns
//
// Public API: service.zig
//   listZmoduUsers / getZmoduUser / createZmoduUser / updateZmoduUser / deleteZmoduUser
//   listZmoduUserAddresss / getZmoduUserAddress / createZmoduUserAddress / updateZmoduUserAddress / deleteZmoduUserAddress
//   listZmoduUserBalanceLogs / getZmoduUserBalanceLog / createZmoduUserBalanceLog / updateZmoduUserBalanceLog / deleteZmoduUserBalanceLog
//   listZmoduUserCarts / getZmoduUserCart / createZmoduUserCart / updateZmoduUserCart / deleteZmoduUserCart
//   listZmoduUserCashs / getZmoduUserCash / createZmoduUserCash / updateZmoduUserCash / deleteZmoduUserCash
//   listZmoduUserCoupons / getZmoduUserCoupon / createZmoduUserCoupon / updateZmoduUserCoupon / deleteZmoduUserCoupon
//   listZmoduUserFavorites / getZmoduUserFavorite / createZmoduUserFavorite / updateZmoduUserFavorite / deleteZmoduUserFavorite
//   listZmoduUserGiftLogs / getZmoduUserGiftLog / createZmoduUserGiftLog / updateZmoduUserGiftLog / deleteZmoduUserGiftLog
//   listZmoduUserGrades / getZmoduUserGrade / createZmoduUserGrade / updateZmoduUserGrade / deleteZmoduUserGrade
//   listZmoduUserGradeEquitys / getZmoduUserGradeEquity / createZmoduUserGradeEquity / updateZmoduUserGradeEquity / deleteZmoduUserGradeEquity
//   listZmoduUserGradeLogs / getZmoduUserGradeLog / createZmoduUserGradeLog / updateZmoduUserGradeLog / deleteZmoduUserGradeLog
//   listZmoduUserPointsLogs / getZmoduUserPointsLog / createZmoduUserPointsLog / updateZmoduUserPointsLog / deleteZmoduUserPointsLog
//   listZmoduUserReferees / getZmoduUserReferee / createZmoduUserReferee / updateZmoduUserReferee / deleteZmoduUserReferee
//   listZmoduUserSigns / getZmoduUserSign / createZmoduUserSign / updateZmoduUserSign / deleteZmoduUserSign
//   listZmoduUserTags / getZmoduUserTag / createZmoduUserTag / updateZmoduUserTag / deleteZmoduUserTag
//   listZmoduUserTaskLogs / getZmoduUserTaskLog / createZmoduUserTaskLog / updateZmoduUserTaskLog / deleteZmoduUserTaskLog
//   listZmoduUserVisits / getZmoduUserVisit / createZmoduUserVisit / updateZmoduUserVisit / deleteZmoduUserVisit
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
