# ZigModu Best Practices — Lessons from Heysen SaaS

> Derived from building a 68-module insurance brokerage platform (Zig 0.17.0 + zigmodu).

## 1. SQLx — PostgreSQL Driver

### 1.1 NULL-TERMINATE ALL PARAM STRINGS

**Problem**: Zig `[]const u8` is not null-terminated. `PQexecParams` and `PQexecPrepared` may call `strlen()` on parameter values despite the length array being provided. This causes segfaults at `0xfffffffffffffff0`.

**Wrong**:
```zig
.string => |v| @ptrCast(v.ptr),  // Zig slice — no \0 terminator
```

**Right**:
```zig
.string => |v| blk: {
    const s = allocZ(self.allocator, v) catch return null;
    break :blk @ptrCast(s.ptr);
},
```

**Fix applied**: `allocZ` and `allocPrintZ` helpers in `sqlx.zig`. All PG parameter strings now null-terminated in both `execParamsDirect` and `execParamsPrepared`.

### 1.2 DON'T FREE PARAM BUFFERS BETWEEN EXEC CALLS

**Problem**: `defer` freed param buffers immediately after `PQexecParams` returned. libpq internally caches pointers to param data for the connection lifetime. Second `exec()` on same connection → use-after-free → UTF8 corruption → crash.

**Wrong**:
```zig
defer {
    for (paramAllocs) |a| if (a) |buf| self.allocator.free(buf);
    self.allocator.free(paramAllocs);
}
```

**Right**:
```zig
errdefer {  // only free on error path
    for (paramAllocs) |a| if (a) |buf| self.allocator.free(buf);
    self.allocator.free(paramAllocs);
}
```

**Rule**: Param buffers must outlive the connection, not just the query call. Use `errdefer` for cleanup. Let normal success path leak into the connection's allocator (freed on connection close).

### 1.3 DOCUMENT PARAM COUNT LIMITS

**Problem**: 17 params crashed. 13 worked. Exact threshold unknown. Caused confusing debugging.

**Proposed**: Add assert or compile-time check: if `args.len > MAX_PARAMS` (e.g., 15), use `PQexec` with formatted SQL (like MySQL's `formatQuery`) instead of `PQexecParams`.

### 1.4 PROVIDE `query()` FOR INSERT/UPDATE SAFETY

**Problem**: `Client.query()` returns `!Rows` but is called for INSERT/UPDATE (which return no rows). This creates confusion — some drivers handle it, others don't.

**Proposed**: Deprecate `.query()` for DML. Add explicit `.exec()` for INSERT/UPDATE/DELETE, and `.select()` for queries that return rows.

---

## 2. ORM Layer

### 2.1 PAGE OFFSET STANDARDIZATION

**Problem**: `findPage` used `offset = page * size` (0-based) but callers passed 1-based page numbers. Fixed to `(page-1)*size`.

**Rule**: Document the contract. Either:
- Use 0-based pages everywhere with `page` parameter renamed to `page_index`
- Or use 1-based pages everywhere with `(page-1)*size` consistently

### 2.2 SOFT-DELETE IN `findPage`

**Problem**: `findPage` does not filter `WHERE deleted=0`. Callers must write custom queries or use workarounds.

**Proposed**: If the model has a `deleted` field, `findPage` should automatically add `WHERE deleted=0`.

```zig
pub fn findPage(self: @This(), page: usize, size: usize) !PageResult(T) {
    const where_clause = if (@hasField(T, "deleted")) " WHERE deleted=0" else "";
    // ...
}
```

### 2.3 AUTO-DETECT TABLE COLUMNS FROM DB

**Problem**: Generated models had wrong column names (`menu_type` vs `type` in DB, `ip` vs `user_ip`). Model and DB schema drifted.

**Proposed**: Add a `zigmodu validate-schema` command that compares model `json_names` against actual DB columns at startup. Or generate models from `\d` output.

---

## 3. HTTP API — Route Conventions

### 3.1 KEBAB-CASE URL NORMALIZATION

**Problem**: Admin frontend (Vben, Java convention) uses kebab-case (`/crm/business-status/page`). Zig backend uses snake_case (`/crm/business_status/page`). Every module needed manual aliases.

**Proposed**: Add a `normalizePath` middleware in zigmodu's Server that converts `-` → `_` in URL paths before route matching. One line of code saves dozens of alias routes.

```zig
pub fn setPathNormalizer(self: *Server, normalize: PathNormalizerFn) void {
    // PathNormalizerFn = *const fn (path: []const u8, allocator: Allocator) []const u8
    // Example: replace '-' with '_' for all admin-api routes
}
```

### 3.2 STANDARD CRUD ROUTE SUFFIXES

**Problem**: Admin uses `simple-list`, backend uses `list-all-simple`. Inconsistent.

**Proposed**: Generate BOTH aliases automatically in the code generator:
```zig
pub fn registerRoutes(self: *Api, group: *RouteGroup) !void {
    const p = "/crm/business_status";
    try group.get(p ++ "/page", hPage, ...);
    try group.get(p ++ "/list-all-simple", hSimple, ...);
    try group.get(p ++ "/simple-list", hSimple, ...);  // auto-generated alias
}
```

### 3.3 RESPONSE ENVELOPE CONSISTENCY

**Problem**: Some endpoints return `{list, total}`, others return `[...]` directly, others return `{data: [...]}`. Admin frontend has to handle all variants.

**Proposed**: Standardize on `PageResult(T)` wrapper for all list endpoints:
```zig
pub fn PageResult(comptime T: type) type {
    return struct { list: []T, total: usize, page: usize, size: usize };
}
```

---

## 4. JSON Parsing — Memory Safety

### 4.1 ALWAYS USE ARENA FOR parseFromSlice

**Problem**: `std.json.parseFromSlice(ContentArticle, ctx.allocator, body, .{})` uses GPA. `parsed.deinit()` frees all string fields. Any code that uses `parsed.value` after deinit gets dangling pointers. With GPA, `defer` runs early. With arena, memory stays valid.

**Right**:
```zig
var arena = std.heap.ArenaAllocator.init(ctx.allocator);
defer arena.deinit();
const parsed = std.json.parseFromSlice(T, arena.allocator(), body, .{}) catch ...;
// parsed.value is valid until arena.deinit()
// No parsed.deinit() needed — arena handles cleanup
```

**Rule**: Never use GPA-backed `parseFromSlice` for structs with `[]const u8` fields. Always use arena.

### 4.2 SIMPLE PARSE STRUCT FOR HANDLERS

**Problem**: Parsing directly into the full ORM model (`ContentArticle`) pulls in 25+ fields, many unknown to the JSON body. Unknown fields cause parse errors or unexpected defaults.

**Right**: Parse into a minimal struct with only the fields the API accepts:
```zig
const Input = struct {
    title: []const u8,
    category_id: i64,
    difficulty: []const u8 = "beginner",
    // ... only the 5-10 fields the form sends
};
const parsed = std.json.parseFromSlice(Input, arena.allocator(), body, .{}) catch ...;
```

---

## 5. Module Generation — Code Quality

### 5.1 AVOID DOUBLED MODULE NAMES

**Problem**: Generator produced function names like `listSystemOperateLogOperateLog` (module name doubled). Service calls like `getSystemMailAccountMailAccount`. This makes code unreadable and breaks compilation.

**Root cause**: Generator appends module name to standardized prefix without checking for redundancy.

**Fix**: Strip the module prefix before appending:
```zig
fn handlerName(module: []const u8, operation: []const u8) []const u8 {
    // "operate_log" → "listOperateLogs" NOT "listOperateLogOperateLogs"
    const base = stripCommonPrefix(module, operation);
    return operation ++ titleCase(base);
}
```

### 5.2 GENERATE WORKING STUBS FOR OPTIONAL MODULES

**Problem**: Dead modules (mail_account, notify_template, etc.) had broken generated code that wouldn't compile. Fixed manually, then broke again on re-generation.

**Proposed**: Generator should produce compilable stubs with `return error.NotImplemented`:
```zig
pub fn registerRoutes(_: *Api, _: *RouteGroup) !void {
    return error.NotImplemented;
}
```

### 5.3 VALIDATE MODELS AGAINST DATABASE AT BUILD TIME

**Problem**: Column name mismatches discovered at runtime (500 errors), not compile time.

**Proposed**: Add `zigmodu check` command that:
1. Connects to database
2. Reads `\d` output for each model's `sql_table_name`
3. Compares model fields against actual columns
4. Reports mismatches

---

## 6. Error Handling

### 6.1 REPLACE CATCH {} WITH PROPER LOGGING

**Problem**: `catch {}` hides errors silently. Causes "empty list" bugs that look like query issues but are actually silent parse/DB failures.

**Right**:
```zig
_ = self.backend.client.exec(sql, args) catch |err| {
    std.log.err("DB exec failed: {s} — {s}", .{ sql, @errorName(err) });
};
```

### 6.2 ADD REQUEST TRACING

**Problem**: Debugging a crash requires correlating log lines across modules. No request ID.

**Proposed**: Add `x-request-id` header propagation through the middleware chain:
```zig
const trace_id = ctx.headers.get("x-request-id") orelse generateTraceId();
std.log.info("[{s}] {s} {s}", .{ trace_id, ctx.method, ctx.path });
```

---

## 7. Testing

### 7.1 CONNECTION POOL HEALTH CHECK

**Problem**: Pool returns broken connections silently. Second exec crashes with no clear error.

**Proposed**: Add `conn.ping()` before returning from `acquire()`:
```zig
pub fn acquire(self: *ConnPool) !Conn {
    const conn = self.getIdleOrCreate() catch return error.ConnectionFailed;
    conn.ping() catch {
        conn.close();
        return self.acquire(); // retry with fresh connection
    };
    return conn;
}
```

### 7.2 PARAM VALIDATION AT BIND TIME

**Problem**: Invalid UTF8 bytes sent to libpq cause cryptic errors. No validation before the C call.

**Proposed**: Validate string params before binding:
```zig
.string => |v| blk: {
    if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidUtf8;
    // ... allocate and bind
},
```

---

## 8. Summary — Priority Actions

| Priority | Action | Impact |
|----------|--------|--------|
| P0 | Add `normalizePath` middleware (kebab→snake) | Eliminate 100+ route alias lines |
| P0 | `findPage` auto-filter `WHERE deleted=0` | Eliminate 20+ custom query workarounds |
| P1 | Arena-backed JSON parsing in generated handlers | Prevent production crashes |
| P1 | Connection pool `ping()` before `acquire()` | Prevent stale connection crashes |
| P2 | Generate `simple-list` alias alongside `list-all-simple` | Eliminate manual alias additions |
| P2 | `zigmodu check` — validate models against DB schema | Catch drift at build time |
| P3 | Request tracing with `x-request-id` | Debugging speed |
| P3 | Deprecate `.query()` for DML, add `.select()` | API clarity |
