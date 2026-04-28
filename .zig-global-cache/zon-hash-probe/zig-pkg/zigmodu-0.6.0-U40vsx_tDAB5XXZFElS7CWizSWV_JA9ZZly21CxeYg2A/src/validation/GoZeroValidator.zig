//! DEPRECATED: GoZeroValidator has been moved to src/experimental/GoZeroValidator.zig.
//! This wrapper is kept for backward compatibility only.
pub const Result = @import("../experimental/GoZeroValidator.zig").Result;
pub const FieldRules = @import("../experimental/GoZeroValidator.zig").FieldRules;
pub const notEmpty = @import("../experimental/GoZeroValidator.zig").notEmpty;
pub const minLength = @import("../experimental/GoZeroValidator.zig").minLength;
pub const maxLength = @import("../experimental/GoZeroValidator.zig").maxLength;
pub const email = @import("../experimental/GoZeroValidator.zig").email;
pub const phone = @import("../experimental/GoZeroValidator.zig").phone;
pub const range = @import("../experimental/GoZeroValidator.zig").range;
pub const oneOf = @import("../experimental/GoZeroValidator.zig").oneOf;
pub const uuid = @import("../experimental/GoZeroValidator.zig").uuid;
pub const url = @import("../experimental/GoZeroValidator.zig").url;
pub const validateStruct = @import("../experimental/GoZeroValidator.zig").validateStruct;
pub const Validator = @import("../experimental/GoZeroValidator.zig").Validator;
