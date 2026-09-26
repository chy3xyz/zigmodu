//! ⚠️ DEPRECATED — use `zigmodu.Validator` (validation/ObjectValidator.zig) instead.
//! This GoZero-style validator will be removed in v1.0.
//!
//! As of the "move the chain to a non-deprecated home" batch, this file is a
//! **thin compatibility layer only**: every name below is an alias, and the
//! canonical implementations live in
//! `validation/FieldValidation.zig` (`validateStruct` / `validateStructCollect`
//! / `Violation(s)` / `MessageHook` / the scalar checkers / the multi-check
//! `Validator` struct) and `validation/FieldRules.zig` (`FieldRules`).
//!
//! That is what makes the banner's "removed in v1.0" executable: nothing in the
//! tree reaches this file except the freeze gate that pins these spellings
//! (`src/test/ApiFreeze.zig`), and the dependency runs one way only
//! (deprecated file → new homes, never the reverse). `http.validateRequest`
//! (`api/middleware/Validation.zig`) and `http.extractJsonValidated`
//! (`api/Extract.zig`) read `FieldValidation.zig` directly, so deleting this
//! file breaks no `http.*` chain. The gate asserts all three facts, plus that
//! no `pub fn` body lives here any more.

const FieldValidation = @import("FieldValidation.zig");

/// Validation result — see `FieldValidation.Result`.
pub const Result = FieldValidation.Result;

/// Validate that string is not empty — see `FieldValidation.notEmpty`.
pub const notEmpty = FieldValidation.notEmpty;

/// Validate minimum length — see `FieldValidation.minLength`.
pub const minLength = FieldValidation.minLength;

/// Validate maximum length — see `FieldValidation.maxLength`.
pub const maxLength = FieldValidation.maxLength;

/// Validate email format — see `FieldValidation.email`.
pub const email = FieldValidation.email;

/// Validate phone number — see `FieldValidation.phone`.
pub const phone = FieldValidation.phone;

/// Validate range for integers — see `FieldValidation.range`.
pub const range = FieldValidation.range;

/// Validate that value is in allowed set — see `FieldValidation.oneOf`.
pub const oneOf = FieldValidation.oneOf;

/// Validate UUID format — see `FieldValidation.uuid`.
pub const uuid = FieldValidation.uuid;

/// Validate URL format — see `FieldValidation.url`.
pub const url = FieldValidation.url;

/// One violated rule on one field — see `FieldValidation.Violation`.
pub const Violation = FieldValidation.Violation;

/// Every violation from one collection call — see `FieldValidation.Violations`.
pub const Violations = FieldValidation.Violations;

/// Localization hook for default rule messages — see
/// `FieldValidation.MessageHook`.
pub const MessageHook = FieldValidation.MessageHook;

/// First-failure-only struct validation — see `FieldValidation.validateStruct`.
pub const validateStruct = FieldValidation.validateStruct;

/// Collecting struct validation — see
/// `FieldValidation.validateStructCollect`.
pub const validateStructCollect = FieldValidation.validateStructCollect;

/// Validator that combines multiple checks — see
/// `FieldValidation.Validator`.
pub const Validator = FieldValidation.Validator;

/// Field validation rules for comptime struct validation. The canonical
/// declaration lives in `validation/FieldRules.zig`, because `http.FieldRules`
/// resolves there now and the http domain must not be reached from this
/// deprecated file. This is the compatibility alias for consumers who wrote
/// `Validator.FieldRules`.
pub const FieldRules = @import("FieldRules.zig").FieldRules;
