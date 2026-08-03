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
const OpenApi = @import("../http/OpenApi.zig");

pub const Context = Server.Context;
pub const FieldRules = Validator.FieldRules;

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

    const pk = try allocator.dupe(u8, "page");
    const pv = try allocator.dupe(u8, "3");
    try ctx.query.put(pk, pv);

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
