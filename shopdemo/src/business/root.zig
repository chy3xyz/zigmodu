//! Business logic layer — pure functions, no DB/HTTP dependencies.
//! Importable by any module. Testable without infrastructure.

pub const enums = @import("enums.zig");
pub const commission = @import("commission.zig");
pub const order_flow = @import("order_flow.zig");

// Extension points — add domain modules as you build them:
// pub const coupon_validation = @import("coupon_validation.zig");
// pub const points_calculation = @import("points_calculation.zig");
