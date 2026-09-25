//! Typed request extractors and unified ProblemDetails error responses.
//!
//! Usage:
//!   const q = try http.extractQuery(ctx, QueryDto); // field defaults apply when missing
//!   const p = try http.extractPath(ctx, PathDto);
//!   const body = try http.extractJsonValidated(ctx, CreateDto, rules);
//!   try http.respondErr(ctx, err); // optional http.setErrorMap(...)

const std = @import("std");
const Server = @import("Server.zig");
const ProblemDetails = @import("../http/ProblemDetails.zig").ProblemDetails;
const Validator = @import("../validation/Validator.zig");
const FieldRulesFile = @import("../validation/FieldRules.zig");
const OpenApi = @import("../http/OpenApi.zig");
const Multipart = @import("../http/Multipart.zig");
const UploadGuard = @import("../http/UploadGuard.zig");

pub const Context = Server.Context;
/// Field validation rules used by `extractJsonValidated`. Read straight from the
/// canonical home (`validation/FieldRules.zig`), not through the deprecated
/// `validation/Validator.zig` — so the `http.FieldRules` spelling survives that
/// file's deletion.
pub const FieldRules = FieldRulesFile.FieldRules;

/// Parse a `multipart/form-data` body, rendering failures as ProblemDetails.
///
/// `ctx.multipart` is the raw parser: the caller gets a `Multipart.Error` and
/// has to turn it into a status itself, which is how upload endpoints end up
/// returning a different error shape from the rest of the API. This is the
/// counterpart of `extractJson*` for uploads:
///
///   415 wrong content type · 413 too large · 400 malformed/too many parts
///
/// `OutOfMemory` is propagated without rendering — that is a 500 owned by the
/// server's error path, not a client mistake.
///
/// Size limits live in `Multipart.Config` and are gated by
/// `Server.Config.max_body_size` first — see `Multipart.Config.forBodyLimit`.
pub fn extractMultipart(ctx: *Context, config: Multipart.Config) !Multipart.Form {
    return ctx.multipart(config) catch |err| switch (err) {
        error.NotMultipart => {
            try respondProblem(ctx, 415, "Expected multipart/form-data");
            return error.UnsupportedMediaType;
        },
        error.MissingBoundary, error.MalformedPart => {
            try respondProblem(ctx, 400, "Malformed multipart body");
            return error.InvalidMultipart;
        },
        error.TooManyParts => {
            try respondProblem(ctx, 400, "Too many multipart parts");
            return error.InvalidMultipart;
        },
        error.PartTooLarge, error.PayloadTooLarge => {
            try respondProblem(ctx, 413, "Upload too large");
            return error.PayloadTooLarge;
        },
        error.OutOfMemory => |e| return e,
    };
}

/// `extractMultipartGuarded` inputs: the parser limits plus the content policy.
pub const GuardedUpload = struct {
    multipart: Multipart.Config = .{},
    policy: UploadGuard.Policy,
    /// Status rendered when the guard refuses a file. 415 by default; use 422
    /// where the media type is understood but the payload is not acceptable.
    reject_status: u16 = 415,
};

/// Parse **and** content-check in one call — `extractMultipart` followed by
/// `UploadGuard.checkForm`, with the guard's rejection rendered as
/// ProblemDetails.
///
/// Two calls is where upload endpoints go wrong: the policy exists, the
/// handler calls `extractMultipart`, and the `checkForm` line never gets
/// written. Pairing them makes the check the default rather than a step someone
/// has to remember.
///
/// Parse failures keep `extractMultipart`'s statuses (415/413/400). Guard
/// refusals answer `config.reject_status` and the guard's own error is returned
/// unchanged, so a handler may still branch on `error.ExtensionNotAllowed` vs
/// `error.ContentNotAllowed` — it just must not render a second response
/// (the server keeps the first one, see the `ctx.responded` check in
/// `Server.handleForTest`). The form is freed on the rejection path.
pub fn extractMultipartGuarded(ctx: *Context, config: GuardedUpload) !Multipart.Form {
    var form = try extractMultipart(ctx, config.multipart);
    errdefer form.deinit();

    UploadGuard.checkForm(&form, config.policy) catch |err| {
        try respondProblem(ctx, config.reject_status, uploadRejectionDetail(err));
        return err;
    };
    return form;
}

/// Client-facing wording for a policy refusal. Deliberately describes the rule,
/// not the sniffed format: echoing what the bytes were helps an attacker map
/// the guard, and the uploader already knows what they sent.
fn uploadRejectionDetail(err: UploadGuard.Error) []const u8 {
    return switch (err) {
        error.ExtensionNotAllowed => "File extension is not accepted",
        error.ContentNotAllowed => "File content is not an accepted format",
        error.ExtensionContentMismatch => "File content does not match its extension",
        error.ActiveContentNotAllowed => "Active content (SVG/HTML) is not accepted",
        error.FileTooLarge => "Uploaded file is too large",
    };
}

/// Parse query parameters into struct `T`. Field names map to query keys.
/// Supports `[]const u8`, integers, `bool`, `?T`, and Zig field defaults (`page: u32 = 0`).
pub fn extractQuery(ctx: *Context, comptime T: type) !T {
    return extractFromMap(ctx, T, .query);
}

/// Parse path parameters into struct `T`. Field names map to `{name}` segments.
pub fn extractPath(ctx: *Context, comptime T: type) !T {
    return extractFromMap(ctx, T, .path);
}

const Source = enum { query, path };

fn extractFromMap(ctx: *Context, comptime T: type, source: Source) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("extract target must be a struct");

    var out: T = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |field_name, field_type, attrs| {
        const value_str: ?[]const u8 = switch (source) {
            .query => ctx.queryParam(field_name),
            .path => ctx.param(field_name),
        };

        if (value_str) |v| {
            @field(out, field_name) = try parseField(field_type, v);
        } else if (@typeInfo(field_type) == .optional) {
            if (comptime attrs.defaultValue(field_type)) |def| {
                @field(out, field_name) = def;
            } else {
                @field(out, field_name) = null;
            }
        } else if (comptime attrs.defaultValue(field_type)) |def| {
            @field(out, field_name) = def;
        } else {
            return error.MissingParameter;
        }
    }
    return out;
}

fn parseField(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) value else @compileError("unsupported slice type"),
            else => @compileError("unsupported pointer type"),
        },
        .optional => |opt| if (value.len == 0) null else try parseField(opt.child, value),
        else => @compileError("unsupported field type in extractor"),
    };
}

/// Parse JSON body. On failure writes RFC 7807 400 and returns `error.InvalidJson`.
pub fn extractJson(ctx: *Context, comptime T: type) !T {
    if (ctx.body == null) {
        try respondProblem(ctx, 400, "Request body required");
        return error.InvalidJson;
    }
    var parsed = std.json.parseFromSlice(T, ctx.allocator, ctx.body.?, .{ .ignore_unknown_fields = true }) catch {
        try respondProblem(ctx, 400, "Invalid JSON body");
        return error.InvalidJson;
    };
    defer parsed.deinit();
    return try deepCopyValue(parsed.value, ctx.allocator);
}

/// `extractJson` then `Validator.validateStruct` with `rules`. Failures → 422 ProblemDetails.
pub fn extractJsonValidated(ctx: *Context, comptime T: type, comptime rules: anytype) !T {
    if (ctx.body == null) {
        try respondProblem(ctx, 400, "Request body required");
        return error.InvalidJson;
    }
    var parsed = std.json.parseFromSlice(T, ctx.allocator, ctx.body.?, .{ .ignore_unknown_fields = true }) catch {
        try respondProblem(ctx, 400, "Invalid JSON body");
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const err_msg = Validator.validateStruct(ctx.allocator, parsed.value, rules) catch |e| {
        try respondProblem(ctx, 500, @errorName(e));
        return e;
    };
    if (err_msg) |msg| {
        defer ctx.allocator.free(msg);
        try respondProblem(ctx, 422, msg);
        return error.ValidationFailed;
    }
    return try deepCopyValue(parsed.value, ctx.allocator);
}

/// Loose JSON extraction: field names match snake_case or camelCase
/// (`user_name` ↔ `userName`), `null` treats the field as absent (declared
/// default kept), missing fields keep their declared defaults (fields without
/// defaults are zeroed). Escape hatch for clients sending camelCase JSON or
/// `"id": null` for create requests.
pub fn extractJsonLoose(ctx: *Context, comptime T: type) !T {
    if (ctx.body == null) {
        try respondProblem(ctx, 400, "Request body required");
        return error.InvalidJson;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body.?, .{ .ignore_unknown_fields = true }) catch {
        try respondProblem(ctx, 400, "Invalid JSON body");
        return error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try respondProblem(ctx, 400, "JSON body must be an object");
        return error.InvalidJson;
    }
    var result: T = undefined;
    const sinfo = @typeInfo(T).@"struct";
    var filled: [sinfo.field_names.len]bool = undefined;
    inline for (sinfo.field_names, sinfo.field_types, 0..) |fname, F, i| {
        filled[i] = false;
        @field(result, fname) = std.mem.zeroes(F);
        if (findLooseField(parsed.value.object, fname)) |matched| {
            if (matched != .null) {
                var field_parsed = std.json.parseFromValue(F, ctx.allocator, matched, .{}) catch {
                    try respondProblem(ctx, 400, "Invalid JSON body");
                    return error.InvalidJson;
                };
                defer field_parsed.deinit();
                @field(result, fname) = try deepCopyValue(field_parsed.value, ctx.allocator);
                filled[i] = true;
            }
        }
    }
    // Unmatched fields keep declared defaults (deep-copied → uniformly owned).
    inline for (sinfo.field_names, sinfo.field_types, sinfo.field_attrs, 0..) |fname, F, attrs, i| {
        if (!filled[i]) {
            if (attrs.defaultValue(F)) |d| {
                @field(result, fname) = try deepCopyValue(d, ctx.allocator);
            }
        }
    }
    return result;
}

/// Whether two field names are equivalent ignoring underscores and case.
fn namesEquivalent(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == '_') {
            i += 1;
            continue;
        }
        if (b[j] == '_') {
            j += 1;
            continue;
        }
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < a.len and a[i] == '_') i += 1;
    while (j < b.len and b[j] == '_') j += 1;
    return i == a.len and j == b.len;
}

/// Find a JSON object entry whose key is name-equivalent to `fname`.
fn findLooseField(obj: std.json.ObjectMap, fname: []const u8) ?std.json.Value {
    var it = obj.iterator();
    while (it.next()) |e| {
        if (namesEquivalent(e.key_ptr.*, fname)) return e.value_ptr.*;
    }
    return null;
}

fn deepCopyValue(value: anytype, allocator: std.mem.Allocator) !@TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime T == []const u8 or T == []u8) {
        return allocator.dupe(u8, value);
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var copy: T = undefined;
            inline for (s.field_names) |f_name| {
                @field(copy, f_name) = try deepCopyValue(@field(value, f_name), allocator);
            }
            return copy;
        },
        .optional => {
            if (value == null) return null;
            return try deepCopyValue(value.?, allocator);
        },
        .array => |arr| {
            var copy: T = undefined;
            for (0..arr.len) |i| {
                copy[i] = try deepCopyValue(value[i], allocator);
            }
            return copy;
        },
        else => return value,
    }
}

/// Build OpenAPI `ApiParam` list from an extractor struct (query or path).
pub fn openApiParamsFromStruct(comptime T: type, comptime location: OpenApi.ParamLocation) [fieldCount(T)]OpenApi.ApiParam {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("openApiParamsFromStruct expects a struct");
    var out: [fieldCount(T)]OpenApi.ApiParam = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs, 0..) |field_name, field_type, attrs, i| {
        const is_opt = @typeInfo(field_type) == .optional;
        const has_default = attrs.default_value_ptr != null;
        const inner = if (is_opt) @typeInfo(field_type).optional.child else field_type;
        out[i] = .{
            .name = field_name,
            .location = location,
            .param_type = openApiTypeName(inner),
            .required = !is_opt and !has_default,
        };
    }
    return out;
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn openApiTypeName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "integer",
        .float => "number",
        .bool => "boolean",
        .pointer => |p| if (p.size == .slice and p.child == u8) "string" else "string",
        else => "string",
    };
}

/// Write RFC 7807 ProblemDetails JSON response.
pub fn respondProblem(ctx: *Context, status: u16, detail: []const u8) !void {
    const problem = ProblemDetails.init(status, detail, ctx.path);
    const json = try problem.toJson(ctx.allocator);
    defer ctx.allocator.free(json);
    try ctx.json(status, json);
}

/// App-level error → HTTP status overrides (checked before built-in mapping).
pub const ErrorMapping = struct {
    err: anyerror,
    status: u16,
};

/// Localized error detail: respondErr reads Accept-Language and uses `zh`
/// when the request prefers Chinese, otherwise `en` (fallback @errorName).
pub const ErrorLocalization = struct {
    err: anyerror,
    zh: []const u8,
    en: []const u8,
};

var custom_error_map: []const ErrorMapping = &.{};
var error_localizations: []const ErrorLocalization = &.{};

/// Install process-wide error map (call once at startup). Slice must outlive the server.
pub fn setErrorMap(map: []const ErrorMapping) void {
    custom_error_map = map;
}

pub fn clearErrorMap() void {
    custom_error_map = &.{};
}

/// Register per-language error details (app-level; static slices recommended).
pub fn setErrorLocalizations(msgs: []const ErrorLocalization) void {
    error_localizations = msgs;
}

fn localizedDetail(ctx: *Context, err: anyerror) []const u8 {
    if (error_localizations.len == 0) return @errorName(err);
    const lang = ctx.header("Accept-Language") orelse "";
    const zh = std.mem.indexOf(u8, lang, "zh") != null;
    for (error_localizations) |m| {
        if (m.err == err) return if (zh) m.zh else m.en;
    }
    return @errorName(err);
}

/// Map common handler errors to HTTP status + ProblemDetails.
pub fn respondErr(ctx: *Context, err: anyerror) !void {
    const status: u16 = blk: {
        for (custom_error_map) |m| {
            if (m.err == err) break :blk m.status;
        }
        break :blk switch (err) {
            error.InvalidInput, error.ValidationFailed, error.MissingParameter, error.BadRequest, error.InvalidJson => 400,
            error.Unauthorized, error.AuthenticationFailed, error.InvalidToken, error.TokenExpired => 401,
            error.Forbidden, error.AuthorizationFailed => 403,
            error.NotFound => 404,
            error.Conflict, error.AlreadyExists => 409,
            error.OutOfMemory => 500,
            else => 500,
        };
    };
    const detail = if (status >= 500) "Internal server error" else localizedDetail(ctx, err);
    try respondProblem(ctx, status, detail);
}

/// Collect a slice of entities into an owned DTO slice via a comptime
/// converter. `convert` returns DTO values (borrowed strings stay valid as
/// long as the source entities outlive the DTOs; allocate + own when needed).
/// Caller frees the returned slice.
pub fn toDtoList(
    allocator: std.mem.Allocator,
    items: anytype,
    comptime Dto: type,
    comptime convert: *const fn (@typeInfo(@TypeOf(items)).pointer.child) Dto,
) ![]Dto {
    const out = try allocator.alloc(Dto, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |e, i| out[i] = convert(e);
    return out;
}

test "toDtoList maps entities to DTOs" {
    const allocator = std.testing.allocator;
    const Src = struct { id: i64, name: []const u8 };
    const Dto = struct { id: i64 };
    const src = [_]Src{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" } };
    const slice: []const Src = &src;
    const out = try toDtoList(allocator, slice, Dto, struct {
        fn c(e: Src) Dto {
            return .{ .id = e.id };
        }
    }.c);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(i64, 2), out[1].id);
}

/// Convention-based DTO mapping: copy same-name fields from `src` into a Dto
/// struct. Dto fields must exist on the source (or carry a default value);
/// anything else is a compile error — this keeps the output contract explicit.
pub fn toDto(comptime Dto: type, src: anytype) Dto {
    const info = @typeInfo(Dto);
    if (info != .@"struct") @compileError("toDto target must be a struct");
    var out: Dto = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |field_name, field_type, attrs| {
        if (@hasField(@TypeOf(src), field_name)) {
            @field(out, field_name) = @field(src, field_name);
        } else if (comptime attrs.defaultValue(field_type)) |def| {
            @field(out, field_name) = def;
        } else {
            @compileError("Dto field '" ++ field_name ++ "' is missing on the source type");
        }
    }
    return out;
}

/// Respond with the convention-mapped DTO (e.g. hide internal columns).
pub fn respondDto(ctx: *Context, src: anytype, comptime Dto: type) !void {
    try ctx.jsonStruct(200, toDto(Dto, src));
}

test "toDto maps same-name fields and hides extras" {
    const Src = struct { id: i64, name: []const u8, secret: []const u8 };
    const Dto = struct { id: i64, name: []const u8 };
    const src = Src{ .id = 5, .name = "alice", .secret = "hidden" };
    const dto = toDto(Dto, src);
    try std.testing.expectEqual(@as(i64, 5), dto.id);
    try std.testing.expectEqualStrings("alice", dto.name);
}

// ── tests ──

test "extractPath ints and strings" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/users/42");
    defer ctx.deinit();

    const k = try allocator.dupe(u8, "id");
    const v = try allocator.dupe(u8, "42");
    try ctx.params.put(k, v);

    const Dto = struct { id: u32 };
    const dto = try extractPath(&ctx, Dto);
    try std.testing.expectEqual(@as(u32, 42), dto.id);
}

test "extractQuery applies field defaults when missing" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/search");
    defer ctx.deinit();

    const Dto = struct { page: u32 = 0, q: ?[]const u8 = null };
    const dto = try extractQuery(&ctx, Dto);
    try std.testing.expectEqual(@as(u32, 0), dto.page);
    try std.testing.expect(dto.q == null);
}

test "extractQuery with defaults via optional" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/search");
    defer ctx.deinit();

    try ctx.query.put("page", "3");

    const Dto = struct { page: u32, q: ?[]const u8 };
    const dto = try extractQuery(&ctx, Dto);
    try std.testing.expectEqual(@as(u32, 3), dto.page);
    try std.testing.expect(dto.q == null);
}

test "extractJson invalid body writes 400" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .POST, "/items");
    defer ctx.deinit();
    ctx.body = "{not json";

    const Dto = struct { name: []const u8 };
    const result = extractJson(&ctx, Dto);
    try std.testing.expectError(error.InvalidJson, result);
    try std.testing.expectEqual(@as(u16, 400), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "extractJsonValidated rejects short name" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .POST, "/items");
    defer ctx.deinit();
    ctx.body = "{\"name\":\"a\"}";

    const Dto = struct { name: []const u8 };
    const rules = .{ .name = FieldRules{ .required = true, .min_len = 2 } };
    const result = extractJsonValidated(&ctx, Dto, rules);
    try std.testing.expectError(error.ValidationFailed, result);
    try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
}

test "respondErr maps NotFound" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/missing");
    defer ctx.deinit();

    try respondErr(&ctx, error.NotFound);
    try std.testing.expectEqual(@as(u16, 404), ctx.status_code);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "Not Found") != null);
}

test "respondErr uses custom error map" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/quota");
    defer ctx.deinit();

    setErrorMap(&.{.{ .err = error.TooManyRequests, .status = 429 }});
    defer clearErrorMap();

    try respondErr(&ctx, error.TooManyRequests);
    try std.testing.expectEqual(@as(u16, 429), ctx.status_code);
}

test "respondErr localizes detail by Accept-Language" {
    const allocator = std.testing.allocator;
    const zh = [_]ErrorLocalization{
        .{ .err = error.ValidationFailed, .zh = "校验失败", .en = "Validation failed" },
    };
    setErrorLocalizations(&zh);
    defer setErrorLocalizations(&.{}); // reset

    var ctx_zh = try Context.init(allocator, .GET, "/x");
    defer ctx_zh.deinit();
    // 请求头（setHeader 写响应头；ctx.header() 读请求头）
    try ctx_zh.headers.put(try allocator.dupe(u8, "accept-language"), try allocator.dupe(u8, "zh-CN"));
    try respondErr(&ctx_zh, error.ValidationFailed);
    try std.testing.expect(std.mem.indexOf(u8, ctx_zh.response_body.items, "校验失败") != null);

    var ctx_en = try Context.init(allocator, .GET, "/x");
    defer ctx_en.deinit();
    try respondErr(&ctx_en, error.ValidationFailed);
    try std.testing.expect(std.mem.indexOf(u8, ctx_en.response_body.items, "Validation failed") != null);
}

test "openApiParamsFromStruct marks optionals and defaults" {
    const Dto = struct { page: u32 = 0, q: ?[]const u8 = null, id: u32 };
    const params = openApiParamsFromStruct(Dto, .query);
    try std.testing.expectEqual(@as(usize, 3), params.len);
    try std.testing.expect(!params[0].required); // default
    try std.testing.expect(!params[1].required); // optional
    try std.testing.expect(params[2].required);
}

test "extractMultipart renders ProblemDetails for 415 / 413 / 400" {
    const allocator = std.testing.allocator;

    // Wrong content type → 415, not a bare error the caller has to map.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        ctx.body = "{}";
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "application/json"));
        try std.testing.expectError(error.UnsupportedMediaType, extractMultipart(&ctx, .{}));
        try std.testing.expectEqual(@as(u16, 415), ctx.status_code);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"status\":415") != null);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "multipart/form-data") != null);
    }

    // multipart without a boundary → 400 (the client's body is unusable).
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        ctx.body = "x";
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data"));
        try std.testing.expectError(error.InvalidMultipart, extractMultipart(&ctx, .{}));
        try std.testing.expectEqual(@as(u16, 400), ctx.status_code);
    }

    // A well-formed body that busts the configured total → 413.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        ctx.body = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n12345\r\n--X--\r\n";
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=X"));
        try std.testing.expectError(error.PayloadTooLarge, extractMultipart(&ctx, .{ .max_total_bytes = 4 }));
        try std.testing.expectEqual(@as(u16, 413), ctx.status_code);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"status\":413") != null);
    }

    // Happy path: the form comes back owned by the caller.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        ctx.body = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nok\r\n--X--\r\n";
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=X"));
        var form = try extractMultipart(&ctx, .{});
        defer form.deinit();
        try std.testing.expectEqualStrings("ok", form.value("a").?);
        try std.testing.expect(!ctx.responded);
    }
}

/// Multipart body with one file part, as it arrives on the wire. Allocated so
/// a fixture's real bytes can be passed in — not just comptime literals.
fn uploadBody(allocator: std.mem.Allocator, filename: []const u8, declared_type: []const u8, data: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "--B\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"{s}\"\r\n" ++
            "Content-Type: {s}\r\n\r\n{s}\r\n--B--\r\n",
        .{ filename, declared_type, data },
    );
}

/// A real 1×1 PNG — the same 68 bytes the guard's own tests are built on.
fn realPng(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 68);
    return std.fmt.hexToBytes(buf, "89504e470d0a1a0a" ++
        "0000000d49484452000000010000000108060000001f15c489" ++
        "0000000b4944415478da636000020000050001e9fadcd8" ++
        "0000000049454e44ae426082");
}

test "extractMultipartGuarded renders the policy refusal as ProblemDetails" {
    const allocator = std.testing.allocator;
    const policy = UploadGuard.Policy{ .extensions = &.{ "jpg", "jpeg", "png" }, .formats = &.{ .jpeg, .png } };

    // PHP source behind an allowed name and a plausible Content-Type.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        const body = try uploadBody(allocator, "avatar.jpg", "image/jpeg", "<?php system($_GET['c']); ?>");
        defer allocator.free(body);
        ctx.body = body;
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=B"));

        try std.testing.expectError(error.ContentNotAllowed, extractMultipartGuarded(&ctx, .{ .policy = policy }));
        try std.testing.expectEqual(@as(u16, 415), ctx.status_code);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"status\":415") != null);
        // The wording describes the rule, not what the bytes were.
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "not an accepted format") != null);
    }

    // An extension off the allowlist answers the caller's chosen status.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        const body = try uploadBody(allocator, "tool.exe", "application/octet-stream", "MZ\x90\x00");
        defer allocator.free(body);
        ctx.body = body;
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=B"));

        try std.testing.expectError(error.ExtensionNotAllowed, extractMultipartGuarded(&ctx, .{
            .policy = policy,
            .reject_status = 422,
        }));
        try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
    }

    // Accepted upload: the form is returned and nothing was written.
    {
        var ctx = try Context.init(allocator, .POST, "/upload");
        defer ctx.deinit();
        const body = try uploadBody(allocator, "note.txt", "text/plain", "quarterly numbers");
        defer allocator.free(body);
        ctx.body = body;
        try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=B"));

        var form = try extractMultipartGuarded(&ctx, .{
            .policy = .{ .extensions = &.{"txt"}, .formats = &.{.plain} },
        });
        defer form.deinit();
        try std.testing.expectEqualStrings("quarterly numbers", form.file("avatar").?.data);
        try std.testing.expect(!ctx.responded);
    }
}

test "an upload endpoint refuses a renamed script with 415 (Testkit dispatch)" {
    const Testkit = @import("../http/Testkit.zig");
    const allocator = std.testing.allocator;

    const Upload = struct {
        fn post(ctx: *Context) anyerror!void {
            var form = try extractMultipartGuarded(ctx, .{
                .multipart = .{ .max_total_bytes = 1 << 20 },
                .policy = .{
                    .extensions = &.{ "jpg", "jpeg", "png" },
                    .formats = &.{ .jpeg, .png },
                },
            });
            defer form.deinit();
            try ctx.json(200, "{\"ok\":true}");
        }
    };

    var server = Server.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.post("upload", Upload.post, null);

    // The rename bypass, end to end: served as a real request, the response the
    // client sees is the guard's 415 — the handler never writes one itself.
    {
        const body = try uploadBody(allocator, "avatar.jpg", "image/jpeg", "<?php system($_GET['c']); ?>");
        defer allocator.free(body);
        var resp = try Testkit.dispatchOpts(&server, .POST, "/upload", .{
            .body = body,
            .headers = &.{.{ "content-type", "multipart/form-data; boundary=B" }},
        });
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 415), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":415") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"instance\":\"/upload\"") != null);
    }

    // A genuinely real PNG through the same route → the handler's 200.
    {
        const png = try realPng(allocator);
        defer allocator.free(png);
        const body = try uploadBody(allocator, "avatar.png", "image/png", png);
        defer allocator.free(body);
        var resp = try Testkit.dispatchOpts(&server, .POST, "/upload", .{
            .body = body,
            .headers = &.{.{ "content-type", "multipart/form-data; boundary=B" }},
        });
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
    }
}
