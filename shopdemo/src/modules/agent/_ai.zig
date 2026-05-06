// ═══════════════════════════════════════════════════════════
// AI Context: agent module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_agent_apply — 13 columns
//   zmodu_agent_capital — 8 columns
//   zmodu_agent_cash — 24 columns
//   zmodu_agent_grade — 16 columns
//   zmodu_agent_grade_log — 8 columns
//   zmodu_agent_grade_task — 11 columns
//   zmodu_agent_order — 21 columns
//   zmodu_agent_poster — 10 columns
//   zmodu_agent_product — 10 columns
//   zmodu_agent_setting — 5 columns
//   zmodu_agent_user — 12 columns
//   zmodu_agent_user_product — 6 columns
//
// Public API: service.zig
//   listZmoduAgentApplys / getZmoduAgentApply / createZmoduAgentApply / updateZmoduAgentApply / deleteZmoduAgentApply
//   listZmoduAgentCapitals / getZmoduAgentCapital / createZmoduAgentCapital / updateZmoduAgentCapital / deleteZmoduAgentCapital
//   listZmoduAgentCashs / getZmoduAgentCash / createZmoduAgentCash / updateZmoduAgentCash / deleteZmoduAgentCash
//   listZmoduAgentGrades / getZmoduAgentGrade / createZmoduAgentGrade / updateZmoduAgentGrade / deleteZmoduAgentGrade
//   listZmoduAgentGradeLogs / getZmoduAgentGradeLog / createZmoduAgentGradeLog / updateZmoduAgentGradeLog / deleteZmoduAgentGradeLog
//   listZmoduAgentGradeTasks / getZmoduAgentGradeTask / createZmoduAgentGradeTask / updateZmoduAgentGradeTask / deleteZmoduAgentGradeTask
//   listZmoduAgentOrders / getZmoduAgentOrder / createZmoduAgentOrder / updateZmoduAgentOrder / deleteZmoduAgentOrder
//   listZmoduAgentPosters / getZmoduAgentPoster / createZmoduAgentPoster / updateZmoduAgentPoster / deleteZmoduAgentPoster
//   listZmoduAgentProducts / getZmoduAgentProduct / createZmoduAgentProduct / updateZmoduAgentProduct / deleteZmoduAgentProduct
//   listZmoduAgentSettings / getZmoduAgentSetting / createZmoduAgentSetting / updateZmoduAgentSetting / deleteZmoduAgentSetting
//   listZmoduAgentUsers / getZmoduAgentUser / createZmoduAgentUser / updateZmoduAgentUser / deleteZmoduAgentUser
//   listZmoduAgentUserProducts / getZmoduAgentUserProduct / createZmoduAgentUserProduct / updateZmoduAgentUserProduct / deleteZmoduAgentUserProduct
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
