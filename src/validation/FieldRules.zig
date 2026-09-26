//! Canonical home of `FieldRules` — the comptime struct-validation rule shape.
//!
//! Consumers write it as `http.FieldRules` (`src/http.zig` → `src/api/Extract.zig`),
//! and the `validateStruct*` entry points in `validation/FieldValidation.zig` read
//! its fields. It sits in its own file because it is the *declaration* half of a
//! pair and has to stay import-free:
//!
//! * `src/api/Extract.zig` re-exports it for the http domain while importing
//!   `validation/FieldValidation.zig` for `validateStruct`; if the type were
//!   declared there instead, the rule shape would travel with the engine — `std`
//!   and `sqlx/errors.zig` — and the two halves would be one file.
//! * `src/validation/Validator.zig` is the file the banner deprecates; the
//!   banner's "removed in v1.0" is only executable once `http.FieldRules` no
//!   longer resolves through it.
//!
//! This file imports nothing, so it points at nobody and the deprecated file's
//! alias points here: deleting that file leaves `http.FieldRules` intact, and the
//! engine can be read without pulling the rule shape's consumers in. Both
//! directions are pinned by `src/test/ApiFreeze.zig`.

/// Field validation rules for comptime struct validation.
/// Only fields relevant to the value type are enforced.
pub const FieldRules = struct {
    required: bool = false,
    min_len: ?usize = null,
    max_len: ?usize = null,
    min: ?i64 = null,
    max: ?i64 = null,
    email: bool = false,
    uuid: bool = false,
    phone: bool = false,
    url: bool = false,
    one_of: ?[]const u8 = null,
    /// Replaces the failure message for this field **verbatim** (no field-name
    /// prefix added). Use it to phrase the error for the end user. It covers any
    /// rule on that field, not one specific rule.
    message: ?[]const u8 = null,
};
