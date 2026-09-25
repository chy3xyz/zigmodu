//! Canonical home of `FieldRules` — the comptime struct-validation rule shape.
//!
//! Consumers write it as `http.FieldRules` (`src/http.zig` → `src/api/Extract.zig`),
//! and the `validateStruct*` entry points in `validation/Validator.zig` read its
//! fields. It sits in its own file because neither of those two can declare it:
//!
//! * `src/api/Extract.zig` re-exports it for the http domain but imports
//!   `validation/Validator.zig` for `validateStruct`, so declaring the type there
//!   would make the deprecated file import the http domain — an import cycle, and
//!   the type would once again sit behind the deprecation banner.
//! * `src/validation/Validator.zig` is the file the banner deprecates; the
//!   banner's "removed in v1.0" is only executable once `http.FieldRules` no
//!   longer resolves through it.
//!
//! This file imports nothing, so both of them point here and it points at
//! neither: deleting the deprecated file leaves `http.FieldRules` intact. The
//! direction is pinned by `src/test/ApiFreeze.zig`.

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
