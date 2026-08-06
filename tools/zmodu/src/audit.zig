//! `zmodu audit` — best-practice checker for business code.
//!
//! Two rule groups:
//!   - architecture: module boundaries / naming / dependency hygiene,
//!     mirroring `zigmodu.core.ArchitectureTester` (static source scan);
//!   - business: anti-pattern lint over `src/modules/**` (handler SQL,
//!     non-parameterized SQL, legacy/banned APIs, cross-module file imports).
//!
//! Baseline: `<dir>/.zmodu/audit-baseline.json` (same semantics as the
//! deadcode baseline: new findings fail, removals are allowed, `--update`
//! shrinks). Exit: 0 pass / 1 new findings / 2 usage error.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const usage =
    \\Usage: zmodu audit [options] [dir]
    \\
    \\Checks business code against ZigModu best practices:
    \\  architecture  module self/circular deps, missing description, naming,
    \\                dependency limit, unknown/base-module dependencies
    \\  business      handler/model SQL, non-parameterized SQL, @ptrCast
    \\                user_data, sendSuccess/sendFail, banned/removed APIs,
    \\                cross-module file imports, manual Bearer, swallowed
    \\                errors, unused catch capture, service CRUD passthrough
    \\                (use data.CrudService), bare raw-entity responses
    \\                (use DTO whitelists), missing module tests, hand-written
    \\                column-index scan (use typed row.scan), multi-write
    \\                service methods without a transaction
    \\
    \\Options:
    \\  -j, --json              machine-readable JSON output
    \\  -g, --group <group>     architecture | business | all (default all)
    \\      --max-deps <n>      architecture dependency limit (default 5)
    \\      --base-modules <csv> base modules (must not depend on business)
    \\  -u, --update            update the baseline file
    \\  -h, --help              show this help
    \\
    \\Rule config: <dir>/.zmodu/rules.json — {"max_deps":8,"disabled":["b3"]}
    \\
;

const Group = enum { architecture, business, all };

const Cli = struct {
    json: bool = false,
    group: Group = .all,
    max_deps: usize = 5,
    max_deps_set: bool = false,
    base_modules: []const []const u8 = &.{},
    update: bool = false,
    help: bool = false,
    dir: []const u8 = ".",
};

pub const Violation = struct {
    rule: []const u8, // static literal
    file: []const u8, // owned relative path
    line: usize,
    message: []const u8, // owned

    pub fn deinit(self: *Violation, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.message);
    }
};

pub const ModuleRec = struct {
    name: []const u8, // owned
    description: []const u8, // owned
    deps: []const []const u8, // owned slice; each entry owned
    file: []const u8, // owned relative path
    info_line: usize,

    pub fn deinit(self: *ModuleRec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.deps) |d| allocator.free(d);
        allocator.free(self.deps);
        allocator.free(self.file);
        self.* = undefined;
    }
};

/// Project-level rule overrides from `<dir>/.zmodu/rules.json`:
/// `{"max_deps":8,"disabled":["b3","b9"]}`.
pub const RuleConfig = struct {
    max_deps: usize = 5,
    disabled: std.StringHashMap(void) = undefined,
    /// Model type symbol table: `pub const NAME = struct { … }` → whether the
    /// struct body mentions a `[]const u8` field. Populated by the audit
    /// runner from `src/modules/*/model.zig`; used by b17 to skip named types
    /// that own no strings (scalar rows cannot leak). `null` = conservative
    /// (report everything).
    model_symbols: ?*const std.StringHashMap(bool) = null,

    pub fn deinit(self: *RuleConfig, allocator: std.mem.Allocator) void {
        var it = self.disabled.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.disabled.deinit();
        self.* = undefined;
    }
};

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var cli = parseArgs(allocator, args) catch |err| {
        std.log.err("audit: {s}", .{@errorName(err)});
        std.log.err("{s}", .{usage});
        return 2;
    };
    defer {
        allocator.free(cli.dir);
        allocator.free(cli.base_modules);
    }
    if (cli.help) {
        std.log.info("{s}", .{usage});
        return 0;
    }

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    var rule_config = loadRuleConfig(io, allocator, cli.dir) catch blk: {
        var rc = RuleConfig{};
        rc.disabled = std.StringHashMap(void).init(allocator);
        break :blk rc;
    };
    defer rule_config.deinit(allocator);
    if (!cli.max_deps_set) {
        // config file wins over the built-in default; CLI --max-deps wins over both.
        if (rule_config.max_deps != 5 or cli.max_deps == 5) {
            cli.max_deps = rule_config.max_deps;
        }
    }

    if (cli.group == .all or cli.group == .architecture) {
        collectArchitecture(io, allocator, cli.dir, cli.max_deps, cli.base_modules, &rule_config, &violations) catch |err| {
            std.log.err("audit: architecture scan failed: {s}", .{@errorName(err)});
            return 2;
        };
    }
    if (cli.group == .all or cli.group == .business) {
        collectBusiness(io, allocator, cli.dir, &rule_config, &violations) catch |err| {
            std.log.err("audit: business scan failed: {s}", .{@errorName(err)});
            return 2;
        };
    }

    var arch_count: usize = 0;
    var biz_count: usize = 0;
    for (violations.items) |v| {
        if (v.rule[0] == 'a') arch_count += 1 else biz_count += 1;
    }

    const baseline_path = std.fs.path.join(allocator, &.{ cli.dir, ".zmodu", "audit-baseline.json" }) catch return 2;
    defer allocator.free(baseline_path);

    var baseline = BaselineResult{ .added = 0, .suppressed = 0, .removed = 0 };
    if (cli.update) {
        writeBaseline(io, allocator, baseline_path, violations.items) catch |err| {
            std.log.err("audit: cannot write baseline: {s}", .{@errorName(err)});
            return 2;
        };
        baseline.added = 0;
    } else {
        baseline = compareBaseline(io, allocator, baseline_path, violations.items) catch |err| {
            std.log.err("audit: baseline compare failed: {s}", .{@errorName(err)});
            return 2;
        };
    }

    const pass = baseline.added == 0;
    if (cli.json) {
        printJson(io, allocator, cli.dir, arch_count, biz_count, violations.items, baseline) catch return 2;
    } else {
        printHuman(io, cli.dir, arch_count, biz_count, violations.items, baseline, pass) catch return 2;
    }
    return if (pass) 0 else 1;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    var cli = Cli{};
    var base = std.ArrayList([]const u8).empty;
    errdefer base.deinit(allocator);
    var dir_owned = try allocator.dupe(u8, ".");
    errdefer allocator.free(dir_owned);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            cli.json = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            cli.update = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.help = true;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--group")) {
            if (i + 1 >= args.len) return error.CliUsage;
            i += 1;
            if (std.mem.eql(u8, args[i], "architecture")) {
                cli.group = .architecture;
            } else if (std.mem.eql(u8, args[i], "business")) {
                cli.group = .business;
            } else if (std.mem.eql(u8, args[i], "all")) {
                cli.group = .all;
            } else return error.CliUsage;
        } else if (std.mem.eql(u8, arg, "--max-deps")) {
            if (i + 1 >= args.len) return error.CliUsage;
            i += 1;
            cli.max_deps = std.fmt.parseInt(usize, args[i], 10) catch return error.CliUsage;
            cli.max_deps_set = true;
        } else if (std.mem.eql(u8, arg, "--base-modules")) {
            if (i + 1 >= args.len) return error.CliUsage;
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |part| {
                const t = std.mem.trim(u8, part, " \t");
                if (t.len == 0) continue;
                try base.append(allocator, try allocator.dupe(u8, t));
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.CliUsage;
        } else {
            allocator.free(dir_owned);
            dir_owned = try allocator.dupe(u8, arg);
        }
    }
    cli.dir = dir_owned;
    cli.base_modules = try base.toOwnedSlice(allocator);
    return cli;
}

/// Load `<dir>/.zmodu/rules.json` (optional). `disabled` is always initialized.
fn loadRuleConfig(io: Io, allocator: std.mem.Allocator, project_dir: []const u8) !RuleConfig {
    var rc = RuleConfig{};
    rc.disabled = std.StringHashMap(void).init(allocator);
    errdefer rc.deinit(allocator);

    const path = std.fs.path.join(allocator, &.{ project_dir, ".zmodu", "rules.json" }) catch return rc;
    defer allocator.free(path);
    const content = Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return rc;
        return err;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return rc;
    defer parsed.deinit();
    if (parsed.value != .object) return rc;
    if (parsed.value.object.get("max_deps")) |md| {
        if (md == .integer) rc.max_deps = @intCast(md.integer);
    }
    if (parsed.value.object.get("disabled")) |dis| {
        if (dis == .array) {
            for (dis.array.items) |item| {
                if (item == .string) rc.disabled.put(try allocator.dupe(u8, item.string), {}) catch {};
            }
        }
    }
    return rc;
}

// ── architecture ──────────────────────────────────────────────────────────

fn collectArchitecture(
    io: Io,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    max_deps: usize,
    base_modules: []const []const u8,
    config: *const RuleConfig,
    violations: *std.ArrayList(Violation),
) !void {
    var modules = std.ArrayList(ModuleRec).empty;
    defer {
        for (modules.items) |*m| m.deinit(allocator);
        modules.deinit(allocator);
    }
    try collectModules(io, allocator, project_dir, &modules);

    // a1 self dependency, a3 missing description, a4 naming, a5 dep limit.
    for (modules.items) |*m| {
        if (m.info_line == 0 and !config.disabled.contains("a0")) {
            try pushViolation(violations, allocator, "a0", m.file, 1, "module.zig does not declare a Module info (pub const info)", .{});
        }
        if (std.mem.trim(u8, m.description, " \t").len == 0 and !config.disabled.contains("a3")) {
            try pushViolation(violations, allocator, "a3", m.file, m.info_line, "module has no description in Module info", .{});
        }
        if (!isValidModuleName(m.name) and !config.disabled.contains("a4")) {
            try pushViolation(violations, allocator, "a4", m.file, m.info_line, "module name '{s}' violates naming convention (lowercase letters/digits/-/_)", .{m.name});
        }
        for (m.deps) |d| {
            if (std.mem.eql(u8, d, m.name) and !config.disabled.contains("a1")) {
                try pushViolation(violations, allocator, "a1", m.file, m.info_line, "module depends on itself", .{});
            }
        }
        if (m.deps.len > max_deps and !config.disabled.contains("a5")) {
            try pushViolation(violations, allocator, "a5", m.file, m.info_line, "module has {d} dependencies, exceeding limit {d}", .{ m.deps.len, max_deps });
        }
    }

    // a6 unknown dependency (typo detection).
    if (!config.disabled.contains("a6")) {
        for (modules.items) |*m| {
            for (m.deps) |d| {
                var known = false;
                for (modules.items) |*other| {
                    if (std.mem.eql(u8, other.name, d)) {
                        known = true;
                        break;
                    }
                }
                if (!known) {
                    try pushViolation(violations, allocator, "a6", m.file, m.info_line, "dependency '{s}' does not match any module in src/modules", .{d});
                }
            }
        }
    }

    // a2 circular dependencies (three-color DFS over the module graph).
    if (!config.disabled.contains("a2")) {
        try detectCycles(allocator, modules.items, violations);
    }

    // a7 base modules must not depend on business modules.
    if (base_modules.len > 0) {
        for (modules.items) |*m| {
            const is_base = blk: {
                for (base_modules) |b| {
                    if (std.mem.eql(u8, b, m.name)) break :blk true;
                }
                break :blk false;
            };
            if (!is_base) continue;
            for (m.deps) |d| {
                var dep_is_base = false;
                for (base_modules) |b| {
                    if (std.mem.eql(u8, b, d)) {
                        dep_is_base = true;
                        break;
                    }
                }
                if (!dep_is_base and !config.disabled.contains("a7")) {
                    try pushViolation(violations, allocator, "a7", m.file, m.info_line, "base module depends on business module '{s}'", .{d});
                }
            }
        }
    }
}

/// Walk `src/modules/*/module.zig` and statically extract `Module` info.
/// Caller owns the appended records (free each via `ModuleRec.deinit`).
pub fn collectModules(io: Io, allocator: std.mem.Allocator, project_dir: []const u8, out: *std.ArrayList(ModuleRec)) !void {
    const modules_path = std.fs.path.join(allocator, &.{ project_dir, "src", "modules" }) catch return error.PathTooLong;
    defer allocator.free(modules_path);

    const dir = Dir.cwd().openDir(io, modules_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const rel = std.fs.path.join(allocator, &.{ modules_path, entry.name, "module.zig" }) catch continue;
        defer allocator.free(rel);
        const content = Dir.cwd().readFileAlloc(io, rel, allocator, Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(content);

        const rel_display = std.fs.path.join(allocator, &.{ "src", "modules", entry.name, "module.zig" }) catch continue;
        defer allocator.free(rel_display);
        var rec_maybe = extractModuleInfo(allocator, entry.name, content, rel_display);
        if (rec_maybe) |*rec| {
            out.append(allocator, rec.*) catch |err| {
                rec.deinit(allocator);
                return err;
            };
        } else |err| {
            if (err == error.OutOfMemory) return err;
            // Not parseable: report missing info via empty record.
            var rec = ModuleRec{
                .name = try allocator.dupe(u8, entry.name),
                .description = "",
                .deps = &.{},
                .file = try allocator.dupe(u8, rel_display),
                .info_line = 0,
            };
            out.append(allocator, rec) catch |err2| {
                rec.deinit(allocator);
                return err2;
            };
        }
    }
}

fn extractModuleInfo(
    allocator: std.mem.Allocator,
    dir_name: []const u8,
    content: []const u8,
    file: []const u8,
) !ModuleRec {
    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var info_line: usize = 0;
    var deps = std.ArrayList([]const u8).empty;
    errdefer {
        for (deps.items) |d| allocator.free(d);
        deps.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 1;
    while (lines.next()) |line| : (idx += 1) {
        if (name == null) {
            if (std.mem.indexOf(u8, line, ".name = \"")) |pos| {
                name = readQuoted(line, pos + ".name = \"".len) orelse continue;
                info_line = idx;
            }
        }
        if (std.mem.indexOf(u8, line, ".description = \"")) |pos| {
            description = readQuoted(line, pos + ".description = \"".len) orelse "";
        }
        if (std.mem.indexOf(u8, line, ".dependencies = &.{")) |dep_pos| {
            // Collect quoted names on this line and following lines until '}'.
            var cur = line[dep_pos + ".dependencies = &.{".len ..];
            var done = false;
            while (!done) {
                var rest = cur;
                while (std.mem.indexOf(u8, rest, "\"")) |qpos| {
                    const value = readQuoted(rest, qpos + 1) orelse break;
                    try deps.append(allocator, try allocator.dupe(u8, value));
                    // Skip opening quote + value + closing quote.
                    rest = rest[qpos + value.len + 2 ..];
                }
                if (std.mem.indexOf(u8, cur, "}")) |_| {
                    done = true;
                } else {
                    if (lines.next()) |next_line| {
                        cur = next_line;
                    } else done = true;
                }
            }
        }
    }

    const mod_name = name orelse try allocator.dupe(u8, dir_name);
    return ModuleRec{
        .name = if (name) |n| try allocator.dupe(u8, n) else mod_name,
        .description = try allocator.dupe(u8, description),
        .deps = try deps.toOwnedSlice(allocator),
        .file = try allocator.dupe(u8, file),
        .info_line = info_line,
    };
}

/// Read a `"..."` literal starting at `start` (after the opening quote).
/// Returns the slice without the closing quote, or null if unterminated.
fn readQuoted(line: []const u8, start: usize) ?[]const u8 {
    if (start >= line.len) return null;
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == '"') return line[start..i];
    }
    return null;
}

fn isValidModuleName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn detectCycles(allocator: std.mem.Allocator, modules: []ModuleRec, violations: *std.ArrayList(Violation)) !void {
    // state: 0 = unvisited, 1 = in progress, 2 = done
    const n = modules.len;
    const state = try allocator.alloc(u8, n);
    defer allocator.free(state);
    @memset(state, 0);

    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(allocator);

    var ctx = CycleCtx{
        .allocator = allocator,
        .modules = modules,
        .state = state,
        .stack = &stack,
        .violations = violations,
    };
    for (0..n) |i| try cycleVisit(&ctx, i);
}

const CycleCtx = struct {
    allocator: std.mem.Allocator,
    modules: []ModuleRec,
    state: []u8,
    stack: *std.ArrayList(usize),
    violations: *std.ArrayList(Violation),
};

fn cycleVisit(ctx: *CycleCtx, i: usize) !void {
    if (ctx.state[i] == 2) return;
    if (ctx.state[i] == 1) {
        // Back edge: report modules on the stack from this index.
        var start_found = false;
        for (ctx.stack.items) |idx| {
            if (idx == i) start_found = true;
            if (start_found) {
                try pushViolation(ctx.violations, ctx.allocator, "a2", ctx.modules[idx].file, ctx.modules[idx].info_line, "module participates in a dependency cycle", .{});
            }
        }
        return;
    }
    ctx.state[i] = 1;
    try ctx.stack.append(ctx.allocator, i);
    for (ctx.modules[i].deps) |d| {
        for (ctx.modules, 0..) |*other, j| {
            if (std.mem.eql(u8, other.name, d)) {
                try cycleVisit(ctx, j);
                break;
            }
        }
    }
    _ = ctx.stack.pop();
    ctx.state[i] = 2;
}

// ── business lint ─────────────────────────────────────────────────────────

fn collectBusiness(
    io: Io,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    config: *const RuleConfig,
    violations: *std.ArrayList(Violation),
) !void {
    const modules_path = std.fs.path.join(allocator, &.{ project_dir, "src", "modules" }) catch return error.PathTooLong;
    defer allocator.free(modules_path);

    const dir = Dir.cwd().openDir(io, modules_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    // Build the struct symbol table first: top-level `const X = struct { … }`
    // in every module source file (model.zig, persistence.zig, service.zig,
    // …) → whether the body has a `[]const u8` string field. b17 uses it to
    // skip named types that own no strings (scalar rows).
    var model_symbols = std.StringHashMap(bool).init(allocator);
    defer {
        var kit = model_symbols.iterator();
        while (kit.next()) |e| allocator.free(e.key_ptr.*);
        model_symbols.deinit();
    }
    var scan_it = dir.iterate();
    while (try scan_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const scan_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer scan_dir.close(io);
        var sf_it = scan_dir.iterate();
        while (try sf_it.next(io)) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".zig")) continue;
            const rel = std.fs.path.join(allocator, &.{ modules_path, entry.name, f.name }) catch continue;
            defer allocator.free(rel);
            const content = Dir.cwd().readFileAlloc(io, rel, allocator, Io.Limit.limited(4 * 1024 * 1024)) catch continue;
            defer allocator.free(content);
            try collectModelStructs(allocator, content, &model_symbols);
        }
    }
    var effective_cfg = config.*;
    effective_cfg.model_symbols = &model_symbols;
    const lint_cfg = &effective_cfg;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const mod_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer mod_dir.close(io);

        // b14 — autoCrud modules must ship tests (generated `tests.zig` or
        // hand-written `test "…"` blocks). Scoped to modules using
        // http.CrudApi / data.CrudService so hand-written legacy modules
        // (tenant-mgmt/tenant-shop style) aren't gated before migration.
        var module_has_test = false;
        var module_uses_autocrud = false;
        var f_it = mod_dir.iterate();
        while (try f_it.next(io)) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".zig")) continue;
            const rel = std.fs.path.join(allocator, &.{ modules_path, entry.name, f.name }) catch continue;
            defer allocator.free(rel);
            const content = Dir.cwd().readFileAlloc(io, rel, allocator, Io.Limit.limited(4 * 1024 * 1024)) catch continue;
            defer allocator.free(content);

            const rel_display = std.fs.path.join(allocator, &.{ "src", "modules", entry.name, f.name }) catch continue;
            defer allocator.free(rel_display);
            if (std.mem.indexOf(u8, content, "test \"") != null or std.mem.indexOf(u8, content, "test {") != null) {
                module_has_test = true;
            }
            if (std.mem.indexOf(u8, content, "CrudApi(") != null or std.mem.indexOf(u8, content, "CrudService(") != null) {
                module_uses_autocrud = true;
            }
            try lintFile(allocator, f.name, content, rel_display, lint_cfg, violations);
        }
        if (module_uses_autocrud and !module_has_test and !config.disabled.contains("b14")) {
            const mod_rel = try std.fs.path.join(allocator, &.{ "src", "modules", entry.name });
            defer allocator.free(mod_rel);
            try pushViolation(violations, allocator, "b14", mod_rel, 1, "autoCrud module has no tests — add a smoke test (generated projects ship tests.zig; run via zig build test)", .{});
        }
    }
}

fn lintFile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    content: []const u8,
    rel_path: []const u8,
    config: *const RuleConfig,
    violations: *std.ArrayList(Violation),
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 1;
    // Row count before this call — line-level exemption filtering below only
    // touches violations this invocation produced.
    const prior_count = violations.items.len;
    // Track an unused `catch |X|` capture to report `_ = X;` a few lines later.
    var pending_catch: ?[]const u8 = null;
    var pending_line: usize = 0;
    // Track a CRUD-named service fn to catch a pure passthrough body (b12).
    var pending_fn: ?[]const u8 = null;
    var pending_fn_line: usize = 0;
    // b16 — multi-write methods must run inside a transaction.
    var fn_write_count: usize = 0;
    var fn_tx_seen = false;
    var fn_open = false;
    var fn_open_line: usize = 0;
    var fn_open_name: ?[]const u8 = null;
    // b17 — owned-string queryRow* results must be freed (freeScanned) or the
    // caller leaks; scope-local code should prefer queryRowBorrowed instead.
    var qr_count: usize = 0;
    var qr_fs_count: usize = 0;
    var qr_return_count: usize = 0;
    var qr_first_line: usize = 0;
    // b18 — pseudo-transaction guard: beginTx() followed by a pool-connection
    // exec in the same fn (auto-commit, rollback no-op).
    var b18_begin_seen = false;
    // `const x = queryRow(...)` whose value is delegated via the next-line
    // `return x;` — ownership transfers, no leak at this call site.
    var pending_qr_var: ?[]const u8 = null;
    // Inside a `return .{ … };` assembly that may borrow the pending var whole.
    var in_return_assembly = false;
    // A queryRow* call whose first argument starts on the NEXT line (e.g.
    // `queryRow(\n struct {cnt: i64}, …)`); resolved there (cross-line inline
    // struct → scalar check; otherwise count normally).
    var pending_qr_open_line: usize = 0;
    while (lines.next()) |line| : (idx += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;

        // b18 — pseudo-transaction: beginTx() then a pool-connection exec.
        // Writing via client/backend after beginTx auto-commits on the pool
        // connection; tx.rollback() becomes a no-op. Everything inside the
        // transaction must go through the tx handle (tx.exec / execTx).
        if ((std.mem.eql(u8, file_name, "service.zig") or std.mem.eql(u8, file_name, "persistence.zig")) and !config.disabled.contains("b18")) {
            if (pubFnName(trimmed)) |_| {
                b18_begin_seen = false;
            } else {
                if (std.mem.indexOf(u8, line, "beginTx") != null) b18_begin_seen = true;
                if (b18_begin_seen and isPoolExec(line)) {
                    try pushViolation(violations, allocator, "b18", rel_path, idx, "beginTx() 后仍用池连接 exec — 事务内读写必须走 tx 句柄 (tx.exec / backend.execTx)，否则自动提交且 rollback 无效（伪事务）", .{});
                    b18_begin_seen = false;
                }
            }
        }

        // b16 — track the current service method: count write calls, look for
        // a transaction, and flag 2+ writes without one when the method ends.
        if (std.mem.eql(u8, file_name, "service.zig") and !config.disabled.contains("b16")) {
            if (pubFnName(trimmed)) |fn_name| {
                try flushMultiWrite(fn_open, fn_open_name, fn_open_line, fn_write_count, fn_tx_seen, rel_path, allocator, violations);
                fn_open = true;
                fn_open_name = fn_name;
                fn_open_line = idx;
                fn_write_count = 0;
                fn_tx_seen = false;
            } else if (fn_open) {
                if (containsAny(line, &.{ "transact", "beginTx", ".begin(" }) or
                    std.mem.indexOf(u8, line, "tx.") != null)
                {
                    fn_tx_seen = true;
                }
                if (isWriteCall(line)) fn_write_count += 1;
                if (std.mem.eql(u8, trimmed, "}")) {
                    try flushMultiWrite(fn_open, fn_open_name, fn_open_line, fn_write_count, fn_tx_seen, rel_path, allocator, violations);
                    fn_open = false;
                    fn_open_name = null;
                }
            }
        }

        // b17 — owned-string queryRow* results never freed: `queryRow` /
        // `queryRowPartial` return string fields dupe'd into the client's
        // allocator, so each call site must `freeScanned` them (or delegate
        // ownership via `return`). Scope-local code should prefer the RAII
        // `queryRowBorrowed` (arena owned by the wrapper, nothing to free).
        // Heuristic is per-fn and heuristic: flag when a service/persistence
        // fn has owned queryRow* calls, no freeScanned anywhere in it, and
        // doesn't `return` all of them.
        if ((std.mem.eql(u8, file_name, "service.zig") or std.mem.eql(u8, file_name, "persistence.zig")) and !config.disabled.contains("b17")) {
            if (pubFnName(trimmed)) |_| {
                try flushOwnedRow(qr_count, qr_fs_count, qr_return_count, qr_first_line, rel_path, allocator, violations);
                qr_count = 0;
                qr_fs_count = 0;
                qr_return_count = 0;
                qr_first_line = 0;
            } else {
                // Delegate pattern: `const x = queryRow(...); return x;` —
                // the following line(s) decide whether ownership transfers
                // (direct `return x;`, a `return .{ … x … };` assembly, or an
                // intermediate `const y = .{ … x … }; return y;` chain).
                if (pending_qr_var) |v| {
                    if (in_return_assembly) {
                        if (isWholeVarAssign(line, v)) qr_return_count += 1;
                        if (std.mem.endsWith(u8, trimmed, "};")) {
                            in_return_assembly = false;
                            pending_qr_var = null;
                        }
                    } else if (isReturnVar(trimmed, v)) {
                        qr_return_count += 1;
                        pending_qr_var = null;
                    } else if (std.mem.indexOf(u8, line, "return .{") != null) {
                        in_return_assembly = true;
                        if (isWholeVarAssign(line, v)) qr_return_count += 1;
                        if (std.mem.endsWith(u8, trimmed, "};")) {
                            in_return_assembly = false;
                            pending_qr_var = null;
                        }
                    } else if (constAssignedVar(line)) |alias| {
                        // Intermediate assembly/alias: ownership follows the
                        // alias until it is returned (or used elsewhere).
                        pending_qr_var = if (isWholeVarAssign(line, v)) alias else null;
                    } else {
                        pending_qr_var = null;
                    }
                }
                if (std.mem.indexOf(u8, line, "freeScanned") != null) qr_fs_count += 1;
                // Cross-line queryRow* call: first argument starts next line.
                if (pending_qr_open_line > 0) {
                    if (std.mem.startsWith(u8, trimmed, "struct {")) {
                        if (!isScalarInlineStruct(line)) {
                            if (qr_count == 0) qr_first_line = pending_qr_open_line;
                            qr_count += 1;
                            if (isReturnOfOwnedQueryRow(trimmed)) qr_return_count += 1;
                        }
                    } else if (!namedTypeHasNoString(line, config.model_symbols)) {
                        if (qr_count == 0) qr_first_line = pending_qr_open_line;
                        qr_count += 1;
                        if (isReturnOfOwnedQueryRow(trimmed)) qr_return_count += 1;
                    }
                    pending_qr_open_line = 0;
                }
                if (isOwnedQueryRowCall(line)) {
                    if (queryRowFirstArgOpen(line)) {
                        // First argument on the next line — resolve there.
                        // `return try …queryRow(` transfers ownership outright,
                        // regardless of where the type lands; don't cancel the
                        // delegation by deferring to the next line.
                        pending_qr_open_line = if (isReturnOfOwnedQueryRow(trimmed)) 0 else idx;
                    } else if (isScalarInlineStruct(line) or namedTypeHasNoString(line, config.model_symbols)) {
                        // Inline `struct { … }` without `[]const u8` fields
                        // (e.g. `struct { count: i64 }`, `[]i64` slices), or a
                        // named type the symbol table knows to be string-free:
                        // row owns no strings — nothing to free.
                    } else {
                        if (qr_count == 0) qr_first_line = idx;
                        qr_count += 1;
                        if (isReturnOfOwnedQueryRow(trimmed)) {
                            qr_return_count += 1;
                        } else if (constAssignedVar(line)) |name| {
                            pending_qr_var = name;
                        }
                    }
                }
                if (std.mem.eql(u8, trimmed, "}")) {
                    try flushOwnedRow(qr_count, qr_fs_count, qr_return_count, qr_first_line, rel_path, allocator, violations);
                    qr_count = 0;
                    qr_fs_count = 0;
                    qr_return_count = 0;
                    qr_first_line = 0;
                    in_return_assembly = false;
                    pending_qr_open_line = 0;
                }
            }
        }

        // b11 — unused catch capture (`catch |err| { _ = err;` → `catch {`).
        if (!config.disabled.contains("b11")) {
            if (pending_catch) |name| {
                if (idx - pending_line <= 15 and std.mem.indexOf(u8, line, "_ = ") != null and
                    std.mem.indexOf(u8, line, name) != null and
                    std.mem.indexOf(u8, line, ";") != null)
                {
                    try pushViolation(violations, allocator, "b11", rel_path, pending_line, "unused catch capture — write `catch {{` (Zig 0.17 discards the error set)", .{});
                    pending_catch = null;
                }
                if (idx - pending_line > 15) pending_catch = null;
            }
            if (std.mem.indexOf(u8, line, "catch |_|")) |_| {
                try pushViolation(violations, allocator, "b11", rel_path, idx, "unused catch capture — write `catch {{` (Zig 0.17 discards the error set)", .{});
            } else if (std.mem.indexOf(u8, line, "catch |")) |cpos| {
                const rest = line[cpos + "catch |".len ..];
                const name_end = std.mem.indexOfScalar(u8, rest, '|') orelse continue;
                const name = rest[0..name_end];
                if (name.len > 0 and name[0] != '_') {
                    pending_catch = name;
                    pending_line = idx;
                }
            }
        }

        // b1 / b2 — SQL in handler/model files.
        if (std.mem.eql(u8, file_name, "api.zig")) {
            if (containsAny(line, &.{ ".exec(", "queryCursor", "queryRows", "queryRow(" }) and !config.disabled.contains("b1")) {
                try pushViolation(violations, allocator, "b1", rel_path, idx, "api.zig handler contains SQL execution (SQL belongs in persistence/service)", .{});
            }
        } else if (std.mem.eql(u8, file_name, "model.zig")) {
            if (containsAny(line, &.{ ".exec(", "queryCursor", "queryRows", "queryRow(" }) and !config.disabled.contains("b2")) {
                try pushViolation(violations, allocator, "b2", rel_path, idx, "model.zig contains SQL (models must not touch the database)", .{});
            }
        }

        // b3 — non-parameterized SQL in persistence/service.
        if (std.mem.eql(u8, file_name, "persistence.zig") or std.mem.eql(u8, file_name, "service.zig")) {
            if (looksLikeSql(line) and hasNonEmptyStringLiteral(line) and !config.disabled.contains("b3")) {
                try pushViolation(violations, allocator, "b3", rel_path, idx, "SQL statement contains string literals — use ? placeholders with bound args", .{});
            }
        }

        // b4 — @ptrCast on user_data.
        if (std.mem.indexOf(u8, line, "@ptrCast") != null and std.mem.indexOf(u8, line, "user_data") != null and !config.disabled.contains("b4")) {
            try pushViolation(violations, allocator, "b4", rel_path, idx, "@ptrCast on ctx.user_data — read auth via middleware attrs (user_id/tenant_id/permissions)", .{});
        }

        // b5 — legacy response helpers.
        if (containsAny(line, &.{ "sendSuccess", "sendFail" }) and !config.disabled.contains("b5")) {
            try pushViolation(violations, allocator, "b5", rel_path, idx, "legacy sendSuccess/sendFail response helper — use ctx.json / http.respondErr", .{});
        }

        // b6 — banned imports.
        if (containsAny(line, &.{ "zigmodu.http_server", "zigmodu.orm.Orm", "zigmodu.PasswordEncoder" }) and !config.disabled.contains("b6")) {
            try pushViolation(violations, allocator, "b6", rel_path, idx, "banned import path — use canonical domain modules (http.zig/data.zig/security.zig)", .{});
        }

        // b7 — removed Zig 0.17 APIs.
        if (containsAny(line, &.{
            "std.Thread.Mutex",
            "std.Thread.sleep",
            "std.Thread.WaitGroup",
            "std.time.milliTimestamp",
            "std.time.microTimestamp",
            "std.fs.cwd",
            "std.hash.crc.Crc32Iscsi",
        }) and !config.disabled.contains("b7")) {
            try pushViolation(violations, allocator, "b7", rel_path, idx, "removed Zig 0.17 API — see AGENTS.md replacement table", .{});
        }

        // b8 — cross-module direct file imports.
        if (std.mem.indexOf(u8, line, "@import(") != null and
            std.mem.indexOf(u8, line, "/modules/") != null and
            std.mem.indexOf(u8, line, ".zig\"") != null and
            !config.disabled.contains("b8"))
        {
            try pushViolation(violations, allocator, "b8", rel_path, idx, "cross-module direct file import — import the module barrel (root.zig) instead", .{});
        }

        // b9 — handler-level manual auth (Bearer parsing in api.zig).
        if (std.mem.eql(u8, file_name, "api.zig") and
            (containsAny(line, &.{ "Authorization", "parseBearer", "bearer_" }) or
                (std.mem.indexOf(u8, line, "bearer") != null and std.mem.indexOf(u8, line, "token") != null)) and
            !config.disabled.contains("b9"))
        {
            try pushViolation(violations, allocator, "b9", rel_path, idx, "handler parses Authorization/Bearer manually — use jwtAuthFromCatalogWithPermissions middleware + attrs", .{});
        }

        // b10 — swallowed errors. Empty catches on `errdefer` cleanup,
        // transaction `rollback`, and `sendError` (best-effort response
        // write, e.g. SSE disconnect) are best-effort by nature — the
        // original error is what matters, the cleanup failure is secondary —
        // so they are idiomatic rather than swallowed errors and exempted.
        if (isEmptyCatch(line) and
            !containsAny(line, &.{ "errdefer", "rollback", "sendError" }) and
            !config.disabled.contains("b10"))
        {
            try pushViolation(violations, allocator, "b10", rel_path, idx, "empty catch block swallows errors — log and propagate (ZigModuError)", .{});
        }

        // b12 — pure CRUD passthrough in service.zig: a list/get/create/
        // update/delete method whose whole body forwards to
        // `self.persistence.<sameName>(...)`. Prefer
        // `data.CrudService(Entity, Persistence)` (writes auto-publish
        // CrudEvent) or keep the service only when it adds real logic.
        if (std.mem.eql(u8, file_name, "service.zig") and !config.disabled.contains("b12")) {
            if (pubFnName(trimmed)) |fn_name| {
                pending_fn = null;
                const crudish = isCrudName(fn_name);
                if (crudish) {
                    if (isSameLinePassthrough(trimmed, fn_name)) {
                        try pushViolation(violations, allocator, "b12", rel_path, idx, "pure passthrough service method '{s}' — consider data.CrudService(Entity, Persistence) (writes auto-publish CrudEvent)", .{fn_name});
                    } else {
                        pending_fn = fn_name;
                        pending_fn_line = idx;
                    }
                }
            } else if (pending_fn) |fn_name| {
                if (idx - pending_fn_line <= 1 and isPurePassthrough(trimmed, fn_name)) {
                    try pushViolation(violations, allocator, "b12", rel_path, pending_fn_line, "pure passthrough service method '{s}' — consider data.CrudService(Entity, Persistence) (writes auto-publish CrudEvent)", .{fn_name});
                }
                pending_fn = null;
            }
        }

        // b13 — bare entity response in api.zig: handler serializes a raw
        // model value straight through jsonStruct instead of a DTO
        // whitelist. Route responses through Extract.toDto/respondDto to
        // hide internal columns (secret/org_id/…).
        if (std.mem.eql(u8, file_name, "api.zig") and !config.disabled.contains("b13")) {
            if (bareJsonStructArg(trimmed)) |payload| {
                try pushViolation(violations, allocator, "b13", rel_path, idx, "handler serializes raw value '{s}' — respond through a DTO (Extract.toDto/respondDto hides internal columns)", .{payload});
            }
        }

        // b15 — hand-written column-index scan: `row.values[N]` / `fn scan(`.
        // Prefer typed `row.scan(allocator, Model)` (column-name mapping).
        if (std.mem.eql(u8, file_name, "persistence.zig") and !config.disabled.contains("b15")) {
            if (std.mem.indexOf(u8, line, "row.values[") != null or
                (std.mem.indexOf(u8, line, "fn scan(") != null and std.mem.indexOf(u8, line, "row.scan") == null))
            {
                try pushViolation(violations, allocator, "b15", rel_path, idx, "hand-written column-index scan — use typed row.scan(allocator, Model) (column-name mapping, immune to column reorder)", .{});
            }
        }
    }
    try flushMultiWrite(fn_open, fn_open_name, fn_open_line, fn_write_count, fn_tx_seen, rel_path, allocator, violations);
    try flushOwnedRow(qr_count, qr_fs_count, qr_return_count, qr_first_line, rel_path, allocator, violations);

    // Line-level exemptions: a source line ending with `// audit: ignore`
    // (all rules) or `// audit: ignore b13,b17` (specific rules) drops the
    // violations reported for that exact line — the precise alternative to
    // rule-level `--disable` (too broad) and baseline absorption (noisy).
    // Only violations added by THIS call are considered (violations is shared
    // across lintFile calls; a later content must not re-judge earlier rows).
    var vi: usize = prior_count;
    while (vi < violations.items.len) {
        const v = &violations.items[vi];
        if (lineHasIgnore(content, v.line, v.rule)) {
            v.deinit(allocator);
            _ = violations.orderedRemove(vi);
        } else {
            vi += 1;
        }
    }
}

/// True when the source `line_no` (1-based, in `content`) carries an
/// `// audit: ignore` marker covering `rule` — bare marker ignores all rules.
fn lineHasIgnore(content: []const u8, line_no: usize, rule: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 1;
    while (it.next()) |l| : (idx += 1) {
        if (idx != line_no) continue;
        const cpos = std.mem.indexOf(u8, l, "// audit: ignore") orelse return false;
        const rest = std.mem.trim(u8, l[cpos + "// audit: ignore".len ..], " \t");
        if (rest.len == 0) return true;
        var rit = std.mem.tokenizeAny(u8, rest, ", \t");
        while (rit.next()) |r| {
            if (std.mem.eql(u8, r, rule)) return true;
        }
        return false;
    }
    return false;
}

fn flushMultiWrite(
    fn_open: bool,
    fn_name: ?[]const u8,
    fn_line: usize,
    write_count: usize,
    tx_seen: bool,
    rel_path: []const u8,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
) !void {
    if (fn_open and write_count >= 2 and !tx_seen) {
        try pushViolation(violations, allocator, "b16", rel_path, fn_line, "service method '{s}' performs {d} writes without a transaction — wrap in self.transact(...) / beginTx", .{ fn_name.?, write_count });
    }
}

/// b17 — flush the per-fn owned-string bookkeeping: report when the fn used
/// owned `queryRow*` calls but neither freed them (`freeScanned`) nor
/// delegated every result via `return`.
fn flushOwnedRow(
    qr_count: usize,
    qr_fs_count: usize,
    qr_return_count: usize,
    qr_first_line: usize,
    rel_path: []const u8,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
) !void {
    if (qr_count > 0 and qr_fs_count == 0 and qr_return_count < qr_count) {
        try pushViolation(violations, allocator, "b17", rel_path, qr_first_line, "queryRow/queryRowPartial returns owned strings never freed here — call freeScanned(allocator, T, row) or use queryRowBorrowed (RAII arena, nothing to free)", .{});
    }
}

/// Owned-string single-row query calls (the caller owns the returned string
/// fields). Excludes `queryRows*` (QueryResult arena contract) and
/// `queryRowBorrowed` (RAII, nothing to free).
fn isOwnedQueryRowCall(line: []const u8) bool {
    const needles = [_][]const u8{ ".queryRowOwned(", ".queryRowPartialOwned(", ".queryRowPartial(", ".queryRow(" };
    for (needles) |n| {
        if (std.mem.indexOf(u8, line, n) != null) return true;
    }
    return false;
}

/// True when the whole trimmed line delegates the owned result via `return`,
/// e.g. `return self.db.queryRow(...)` — ownership transfers to the caller.
fn isReturnOfOwnedQueryRow(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "return ")) return false;
    return isOwnedQueryRowCall(trimmed);
}

/// True for `return x;` (whole value delegated, no trailing expression).
fn isReturnVar(trimmed: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "return ")) return false;
    const rest = std.mem.trim(u8, trimmed["return ".len..], " \t");
    if (!std.mem.startsWith(u8, rest, name)) return false;
    const after = rest[name.len..];
    return after.len == 0 or (after.len == 1 and after[0] == ';');
}

/// Extract the variable name from `const x = …` (or `var x = …`). Returns
/// null when the line is not a simple const/var assignment.
fn constAssignedVar(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const prefix_len: usize = if (std.mem.startsWith(u8, trimmed, "const "))
        "const ".len
    else if (std.mem.startsWith(u8, trimmed, "var "))
        "var ".len
    else
        return null;
    const rest = std.mem.trim(u8, trimmed[prefix_len..], " \t");
    const eq = std.mem.indexOf(u8, rest, " =") orelse return null;
    const name = std.mem.trim(u8, rest[0..eq], " \t");
    if (!isIdent(name)) return null;
    return name;
}

/// True when the line passes an inline anonymous struct to a query call that
/// has no slice/string fields — e.g. `queryRow(struct { count: i64 }, …)`.
/// Heuristic: slice/string types always contain `[`; scalar types never do.
/// Multi-line struct literals are not recognized (conservatively reported).
/// True when the inline anonymous struct passed to a query call has NO
/// `[]const u8` string fields — the only fields `freeScanned` ever frees.
/// `[]i64`, `[]u8`, scalars, etc. own nothing, so such rows cannot leak.
/// Heuristic: `[]const u8` (incl. `?[]const u8` / `[]const []const u8`) is the
/// exact string-slice spelling; anything else is not a freed string field.
/// Multi-line struct literals are not recognized (conservatively reported).
fn isScalarInlineStruct(line: []const u8) bool {
    const start = std.mem.indexOf(u8, line, "struct {") orelse return false;
    const brace = start + "struct {".len - 1; // position of '{'
    const close = std.mem.indexOfScalarPos(u8, line, brace + 1, '}') orelse return false;
    const body = line[brace + 1 .. close];
    return std.mem.indexOf(u8, body, "[]const u8") == null;
}

/// True when `name` is assigned whole inside a return assembly, e.g.
/// `.product = p,` / `= p }` — but not `.id = p.id` (field borrow) or
/// `= p[i]` (slice element).
fn isWholeVarAssign(line: []const u8, name: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_from, name)) |pos| {
        // preceding non-space char must be '='
        var i = pos;
        while (i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t')) i -= 1;
        if (i > 0 and line[i - 1] == '=') {
            const after = if (pos + name.len < line.len) line[pos + name.len] else ' ';
            switch (after) {
                ',', '}', ';', ' ', '\t' => return true,
                else => {},
            }
        }
        search_from = pos + name.len;
    }
    return false;
}

/// Extract the first-argument type name of a queryRow* call: `model.Product`
/// → `Product`. Returns null for inline `struct { … }` args (handled by
/// `isScalarInlineStruct`) and non-identifier args.
fn queryRowTypeName(line: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ ".queryRowOwned(", ".queryRowPartialOwned(", ".queryRowPartial(", ".queryRow(" };
    var arg_start: ?usize = null;
    for (needles) |n| {
        if (std.mem.indexOf(u8, line, n)) |pos| {
            arg_start = pos + n.len;
            break;
        }
    }
    const s = arg_start orelse return null;
    const after = line[s..];
    if (std.mem.startsWith(u8, after, "struct")) return null;
    const comma = std.mem.indexOfScalar(u8, after, ',') orelse return null;
    const arg = std.mem.trim(u8, after[0..comma], " \t");
    const dot = std.mem.lastIndexOfScalar(u8, arg, '.') orelse {
        if (!isIdent(arg)) return null;
        return arg;
    };
    const name = arg[dot + 1 ..];
    if (!isIdent(name)) return null;
    return name;
}

/// True when the queryRow* call's FIRST argument does not start/end on this
/// line (nothing after `queryRow(` before end-of-line, e.g. a trailing `(`),
/// so the type lands on the next line.
fn queryRowFirstArgOpen(line: []const u8) bool {
    const needles = [_][]const u8{ ".queryRowOwned(", ".queryRowPartialOwned(", ".queryRowPartial(", ".queryRow(" };
    for (needles) |n| {
        if (std.mem.indexOf(u8, line, n)) |pos| {
            const after = line[pos + n.len ..];
            return std.mem.indexOfScalar(u8, after, ',') == null;
        }
    }
    return false;
}

/// When the model symbol table knows the named type and it has no `[]const u8`
/// field, the row owns no strings and cannot leak. Unknown types are reported
/// (conservative).
fn namedTypeHasNoString(line: []const u8, symbols: ?*const std.StringHashMap(bool)) bool {
    const symbols_ptr = symbols orelse return false;
    const type_name = queryRowTypeName(line) orelse return false;
    if (symbols_ptr.get(type_name)) |has_string| {
        return !has_string;
    }
    return false;
}

/// Scan a module source file for `const NAME = struct { … }` declarations
/// (top-level, optionally `pub`) and record whether the struct body mentions
/// a `[]const u8` string field (the only field kind `freeScanned` frees).
/// Heuristic: body lines between the declaration line and the closing `};`.
/// Indented (`fn`-local) structs are ignored. Keys are duplicated into `out`
/// (caller frees on deinit); re-declarations overwrite without leaking.
fn collectModelStructs(allocator: std.mem.Allocator, content: []const u8, out: *std.StringHashMap(bool)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var pending_name: ?[]const u8 = null;
    var has_string = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (pending_name) |name| {
            if (std.mem.indexOf(u8, trimmed, "[]const u8") != null) has_string = true;
            if (std.mem.startsWith(u8, trimmed, "};")) {
                const new_key = try allocator.dupe(u8, name);
                const gop = try out.getOrPut(new_key);
                if (gop.found_existing) allocator.free(new_key);
                gop.value_ptr.* = has_string;
                pending_name = null;
            }
        } else if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and
            std.mem.indexOf(u8, line, "const ") != null and
            std.mem.indexOf(u8, line, "= struct") != null)
        {
            const p = std.mem.indexOf(u8, line, "const ") orelse continue;
            const rest = std.mem.trim(u8, line[p + "const ".len ..], " \t");
            const eq = std.mem.indexOf(u8, rest, " = ") orelse continue;
            const name = rest[0..eq];
            if (!isIdent(name)) continue;
            pending_name = name;
            has_string = std.mem.indexOf(u8, line, "[]const u8") != null;
        }
    }
}

/// True when the line executes SQL on the pool connection (not the tx
/// handle): client.exec / backend.exec / self.db.exec / self.client.exec,
/// excluding `tx.exec` / `execTx` variants.
fn isPoolExec(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, ".exec(") == null) return false;
    if (std.mem.indexOf(u8, line, "tx.exec") != null) return false;
    return containsAny(line, &.{ "client.exec", "backend.exec", "self.db.exec", ".client.exec" });
}

/// A write-shaped call inside a service method: a persistence write helper or
/// a CrudService write (create/update/delete). Reads (list/get/query) don't
/// count — they don't need a transaction.
fn isWriteCall(line: []const u8) bool {
    const prefixes = [_][]const u8{ "self.crud.", "self.persistence." };
    const write_names = [_][]const u8{ "create", "insert", "update", "delete", "upsert", "save", "exec" };
    for (prefixes) |prefix| {
        const pos = std.mem.indexOf(u8, line, prefix) orelse continue;
        const after = line[pos + prefix.len ..];
        for (write_names) |name| {
            if (std.mem.startsWith(u8, after, name) and after.len >= name.len and after[name.len] == '(') return true;
        }
    }
    return false;
}

fn isCrudName(name: []const u8) bool {
    return std.mem.eql(u8, name, "list") or
        std.mem.eql(u8, name, "get") or
        std.mem.eql(u8, name, "create") or
        std.mem.eql(u8, name, "update") or
        std.mem.eql(u8, name, "delete");
}

/// Extract the declared function name from `pub fn NAME(`.
fn pubFnName(line: []const u8) ?[]const u8 {
    const p = std.mem.indexOf(u8, line, "pub fn ") orelse return null;
    const rest = std.mem.trim(u8, line[p + "pub fn ".len ..], " \t");
    const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const name = rest[0..paren];
    if (!isIdent(name)) return null;
    return name;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// True when `line` is a single statement forwarding to
/// `self.persistence.<fn_name>(` (with `return` or `try` in the prefix).
fn isPurePassthrough(line: []const u8, fn_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) return false;
    const needle = "self.persistence.";
    const pos = std.mem.indexOf(u8, trimmed, needle) orelse return false;
    if (!std.mem.endsWith(u8, trimmed, ";")) return false;
    const after = trimmed[pos + needle.len ..];
    if (!std.mem.startsWith(u8, after, fn_name)) return false;
    if (after.len < fn_name.len or after[fn_name.len] != '(') return false;
    const before = trimmed[0..pos];
    return std.mem.indexOf(u8, before, "return") != null or std.mem.indexOf(u8, before, "try") != null;
}

/// Same-line variant: `pub fn list(...) !T { return self.persistence.list(...); }`.
fn isSameLinePassthrough(line: []const u8, fn_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) return false;
    if (!std.mem.endsWith(u8, trimmed, "}")) return false;
    const body = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
    return isPurePassthrough(body, fn_name);
}

/// When a `ctx.jsonStruct(` call's payload is a bare identifier (not a struct
/// literal / field access / call), return that identifier for rule b13.
fn bareJsonStructArg(line: []const u8) ?[]const u8 {
    const p = std.mem.indexOf(u8, line, "ctx.jsonStruct(") orelse return null;
    const rest = line[p + "ctx.jsonStruct(".len ..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    var payload = std.mem.trim(u8, rest[comma + 1 ..], " \t");
    // Strip the statement terminator / closing paren: `ctx.jsonStruct(200, e);`
    while (payload.len > 0 and (payload[payload.len - 1] == ')' or payload[payload.len - 1] == ';')) {
        payload = payload[0 .. payload.len - 1];
    }
    if (payload.len == 0) return null;
    if (payload[0] == '{' or payload[0] == '.' or payload[0] == '&' or
        payload[0] == '"' or payload[0] == '[' or payload[0] == '@') return null;
    for (payload) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return payload;
}

fn isEmptyCatch(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOf(u8, trimmed, "catch {}")) |_| return true;
    const c = std.mem.indexOf(u8, trimmed, "catch") orelse return false;
    const after = std.mem.trim(u8, trimmed[c + 5 ..], " \t");
    // catch |err| {} / catch |_| {} / catch |e| { } (empty body)
    if (after.len >= 2 and after[0] == '|') {
        const close = std.mem.indexOfScalarPos(u8, after, 1, '|') orelse return false;
        var body = std.mem.trim(u8, after[close + 1 ..], " \t");
        if (std.mem.endsWith(u8, body, ";")) body = body[0 .. body.len - 1];
        body = std.mem.trimEnd(u8, body, " \t");
        return body.len == 2 and body[0] == '{' and body[1] == '}';
    }
    return false;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

fn looksLikeSql(line: []const u8) bool {
    const needle = "SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER";
    var it = std.mem.splitScalar(u8, needle, '|');
    while (it.next()) |kw| {
        if (containsIgnoreCase(line, kw)) return true;
    }
    return false;
}

/// True when the line contains a **non-empty** string literal (`'…'` with
/// content). Empty `''` — used for aliases/defaults like `'' as spec_sku_id`
/// — is not an injection vector, so it doesn't trigger b3.
fn hasNonEmptyStringLiteral(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\'') continue;
        // `''` = empty literal (or an escaped quote inside one); either way
        // the first quote has no content after it.
        if (i + 1 < line.len and line[i + 1] == '\'') {
            i += 1;
            continue;
        }
        return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn pushViolation(
    violations: *std.ArrayList(Violation),
    allocator: std.mem.Allocator,
    rule: []const u8,
    file: []const u8,
    line: usize,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(allocator, .{
        .rule = rule,
        .file = try allocator.dupe(u8, file),
        .line = line,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    });
}

// ── baseline ──────────────────────────────────────────────────────────────

const BaselineResult = struct {
    added: usize,
    suppressed: usize,
    removed: usize,
};

fn baselineKey(rule: []const u8, file: []const u8, line: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}:{d}", .{ rule, file, line }) catch "";
}

fn compareBaseline(
    io: Io,
    allocator: std.mem.Allocator,
    baseline_path: []const u8,
    violations: []const Violation,
) !BaselineResult {
    const content = Dir.cwd().readFileAlloc(io, baseline_path, allocator, Io.Limit.limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            return .{ .added = violations.len, .suppressed = 0, .removed = 0 };
        }
        return err;
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    var baseline = std.StringHashMap(void).init(allocator);
    defer {
        var it = baseline.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        baseline.deinit();
    }
    if (parsed.value == .object) {
        if (parsed.value.object.get("items")) |items| {
            if (items == .array) {
                for (items.array.items) |item| {
                    if (item != .object) continue;
                    const rule = item.object.get("rule") orelse continue;
                    const file = item.object.get("file") orelse continue;
                    const line = item.object.get("line") orelse continue;
                    if (rule != .string or file != .string or line != .integer) continue;
                    var key_buf: [1024]u8 = undefined;
                    const key = baselineKey(rule.string, file.string, @intCast(line.integer), &key_buf);
                    if (key.len > 0) try baseline.put(try allocator.dupe(u8, key), {});
                }
            }
        }
    }

    var added: usize = 0;
    var suppressed: usize = 0;
    for (violations) |v| {
        var key_buf: [1024]u8 = undefined;
        const key = baselineKey(v.rule, v.file, v.line, &key_buf);
        if (key.len > 0 and baseline.contains(key)) {
            suppressed += 1;
        } else {
            added += 1;
        }
    }

    // Removed = baseline entries that no longer appear in the current run.
    var current = std.StringHashMap(void).init(allocator);
    defer {
        var it = current.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        current.deinit();
    }
    for (violations) |v| {
        var key_buf: [1024]u8 = undefined;
        const key = baselineKey(v.rule, v.file, v.line, &key_buf);
        if (key.len > 0) try current.put(try allocator.dupe(u8, key), {});
    }
    var removed: usize = 0;
    var it = baseline.iterator();
    while (it.next()) |entry| {
        if (!current.contains(entry.key_ptr.*)) removed += 1;
    }
    return .{ .added = added, .suppressed = suppressed, .removed = removed };
}

fn writeBaseline(
    io: Io,
    allocator: std.mem.Allocator,
    baseline_path: []const u8,
    violations: []const Violation,
) !void {
    // Ensure parent dir exists.
    const parent = std.fs.path.dirname(baseline_path) orelse ".";
    Dir.cwd().createDirPath(io, parent) catch {};

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"items\":[");
    for (violations, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"rule\":\"");
        try buf.appendSlice(allocator, v.rule);
        try buf.appendSlice(allocator, "\",\"file\":\"");
        try buf.appendSlice(allocator, v.file);
        try buf.appendSlice(allocator, "\",\"line\":");
        var line_buf: [32]u8 = undefined;
        const n = std.fmt.bufPrint(&line_buf, "{d}", .{v.line}) catch continue;
        try buf.appendSlice(allocator, n);
        try buf.appendSlice(allocator, "}");
    }
    try buf.appendSlice(allocator, "]}\n");

    const file = try Dir.cwd().createFile(io, baseline_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
    std.log.info("audit: baseline updated: {d} violations -> {s}", .{ violations.len, baseline_path });
}

// ── output ────────────────────────────────────────────────────────────────

fn printHuman(
    io: Io,
    dir: []const u8,
    arch_count: usize,
    biz_count: usize,
    violations: []const Violation,
    baseline: BaselineResult,
    pass: bool,
) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;

    try stdout.print("== zmodu audit (dir: {s}) ==\n", .{dir});
    try stdout.print("architecture: {d} violation(s), business: {d} violation(s)\n", .{ arch_count, biz_count });
    for (violations) |v| {
        try stdout.print("  [{s}] {s}:{d}  {s}\n", .{ v.rule, v.file, v.line, v.message });
    }
    try stdout.print("baseline: {d} new, {d} suppressed, {d} removed\n", .{ baseline.added, baseline.suppressed, baseline.removed });
    if (pass) {
        try stdout.print("summary: PASS\n", .{});
    } else {
        try stdout.print("summary: FAIL — {d} new violation(s); fix or run `zmodu audit --update`\n", .{baseline.added});
    }
    try stdout.flush();
}

fn printJson(
    io: Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    arch_count: usize,
    biz_count: usize,
    violations: []const Violation,
    baseline: BaselineResult,
) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;

    const json = try buildJsonString(allocator, dir, arch_count, biz_count, violations, baseline);
    defer allocator.free(json);
    try stdout.writeAll(json);
    try stdout.flush();
}

/// Build the audit JSON report as an owned string (baseline zeros when not
/// computed). Shared by the CLI, `zmodu ci` and the MCP server.
pub fn buildJsonString(
    allocator: std.mem.Allocator,
    dir: []const u8,
    arch_count: usize,
    biz_count: usize,
    violations: []const Violation,
    baseline: BaselineResult,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const pass = baseline.added == 0;
    try buf.appendSlice(allocator, "{\"pass\":");
    try buf.appendSlice(allocator, if (pass) "true" else "false");
    try appendPrint(&buf, allocator, ",\"dir\":\"{s}\",\"architecture\":{d},\"business\":{d},\"violations\":[", .{ dir, arch_count, biz_count });
    for (violations, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try appendPrint(&buf, allocator, "{{\"rule\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"message\":\"{s}\"}}", .{ v.rule, v.file, v.line, v.message });
    }
    try appendPrint(&buf, allocator, "],\"baseline\":{{\"added\":{d},\"suppressed\":{d},\"removed\":{d}}}}}\n", .{ baseline.added, baseline.suppressed, baseline.removed });
    return buf.toOwnedSlice(allocator);
}

fn appendPrint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Run both groups without baseline and return the JSON report (MCP/ci entry).
pub fn auditJsonFor(io: Io, allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    var cfg = loadRuleConfig(io, allocator, project_dir) catch blk: {
        var rc = RuleConfig{};
        rc.disabled = std.StringHashMap(void).init(allocator);
        break :blk rc;
    };
    defer cfg.deinit(allocator);

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }
    try collectArchitecture(io, allocator, project_dir, cfg.max_deps, &.{}, &cfg, &violations);
    try collectBusiness(io, allocator, project_dir, &cfg, &violations);

    var arch_count: usize = 0;
    var biz_count: usize = 0;
    for (violations.items) |v| {
        if (v.rule[0] == 'a') arch_count += 1 else biz_count += 1;
    }
    return buildJsonString(allocator, project_dir, arch_count, biz_count, violations.items, .{ .added = violations.items.len, .suppressed = 0, .removed = 0 });
}

/// Render the module dependency graph as Mermaid (nodes + edges between known
/// modules). Owned by caller.
pub fn renderMermaid(io: Io, allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    var modules = std.ArrayList(ModuleRec).empty;
    defer {
        for (modules.items) |*m| m.deinit(allocator);
        modules.deinit(allocator);
    }
    try collectModules(io, allocator, project_dir, &modules);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "graph TD\n");
    for (modules.items) |*m| {
        try appendPrint(&buf, allocator, "  {s}[\"{s}\"]\n", .{ m.name, m.name });
    }
    for (modules.items) |*m| {
        for (m.deps) |d| {
            var known = false;
            for (modules.items) |*other| {
                if (std.mem.eql(u8, other.name, d)) {
                    known = true;
                    break;
                }
            }
            if (!known) continue;
            try appendPrint(&buf, allocator, "  {s} --> {s}\n", .{ m.name, d });
        }
    }
    return buf.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────

test "audit extracts Module info from module.zig" {
    const allocator = std.testing.allocator;
    const content =
        \\const zigmodu = @import("zigmodu");
        \\pub const info = zigmodu.api.Module{
        \\    .name = "order",
        \\    .description = "Order management",
        \\    .dependencies = &.{"user", "inventory"},
        \\    .is_internal = false,
        \\};
    ;
    var rec = try extractModuleInfo(allocator, "order", content, "src/modules/order/module.zig");
    defer rec.deinit(allocator);
    try std.testing.expectEqualStrings("order", rec.name);
    try std.testing.expectEqualStrings("Order management", rec.description);
    try std.testing.expectEqual(@as(usize, 2), rec.deps.len);
    try std.testing.expectEqualStrings("user", rec.deps[0]);
    try std.testing.expectEqualStrings("inventory", rec.deps[1]);
}

test "audit name validation" {
    try std.testing.expect(isValidModuleName("order"));
    try std.testing.expect(isValidModuleName("tenant-mgmt"));
    try std.testing.expect(isValidModuleName("user_profile"));
    try std.testing.expect(!isValidModuleName("Order"));
    try std.testing.expect(!isValidModuleName("order manager"));
    try std.testing.expect(!isValidModuleName(""));
}

test "audit architecture rules flag self/unknown/missing-description" {
    const allocator = std.testing.allocator;
    var modules = [_]ModuleRec{
        .{
            .name = try allocator.dupe(u8, "alpha"),
            .description = try allocator.dupe(u8, ""),
            .deps = blk: {
                const d = try allocator.alloc([]const u8, 2);
                d[0] = try allocator.dupe(u8, "alpha");
                d[1] = try allocator.dupe(u8, "ghost");
                break :blk d;
            },
            .file = try allocator.dupe(u8, "src/modules/alpha/module.zig"),
            .info_line = 3,
        },
        .{
            .name = try allocator.dupe(u8, "beta"),
            .description = try allocator.dupe(u8, "Beta module"),
            .deps = try allocator.alloc([]const u8, 0),
            .file = try allocator.dupe(u8, "src/modules/beta/module.zig"),
            .info_line = 3,
        },
    };
    defer for (&modules) |*m| m.deinit(allocator);

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    // Reuse rule logic by driving collectArchitecture needs real dirs; test
    // the pure pieces instead: self dep, missing description, unknown dep.
    try pushViolation(&violations, allocator, "a1", modules[0].file, 3, "module depends on itself", .{});
    try pushViolation(&violations, allocator, "a3", modules[0].file, 3, "no description", .{});
    try pushViolation(&violations, allocator, "a6", modules[0].file, 3, "dependency 'ghost' unknown", .{});
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
    try std.testing.expectEqualStrings("a1", violations.items[0].rule);
    try std.testing.expectEqual(@as(usize, 3), violations.items[0].line);
}

test "audit business lint flags anti-patterns" {
    const allocator = std.testing.allocator;
    var cfg = RuleConfig{};
    cfg.disabled = std.StringHashMap(void).init(allocator);
    defer cfg.deinit(allocator);

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    try lintFile(allocator, "api.zig", "const r = try client.queryRows(T, sql, args);\n", "src/modules/x/api.zig", &cfg, &violations);
    try lintFile(allocator, "model.zig", "const r = try client.queryRows(T, sql, args);\n", "src/modules/x/model.zig", &cfg, &violations);
    try lintFile(allocator, "persistence.zig", "SELECT * FROM users WHERE name = 'alice'\n", "src/modules/x/persistence.zig", &cfg, &violations);
    // b3 negative — empty string literal (alias/default) is not an injection vector.
    try lintFile(allocator, "persistence.zig", "SELECT '' AS spec_sku_id FROM skus WHERE id = ?\n", "src/modules/x/persistence.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "const auth = @ptrCast(@alignCast(ctx.user_data));\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "api.zig", "try sendFail(ctx, 500, \"x\");\n", "src/modules/x/api.zig", &cfg, &violations);
    try lintFile(allocator, "root.zig", "const z = @import(\"zigmodu.http_server\");\n", "src/modules/x/root.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "var mu: std.Thread.Mutex = .init;\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "const p = @import(\"../../modules/order/persistence.zig\");\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "api.zig", "const auth = ctx.getHeader(\"Authorization\");\n", "src/modules/x/api.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "client.exec(sql, &.{}) catch {};\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "client.exec(sql, &.{}) catch |err| {};\n", "src/modules/x/service.zig", &cfg, &violations);
    // b10 negative — errdefer rollback is best-effort cleanup, not a swallowed error.
    try lintFile(allocator, "service.zig", "errdefer tx.rollback() catch {};\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "errdefer conn.close(io) catch {};\n", "src/modules/x/service.zig", &cfg, &violations);
    // b10 negative — sendError is best-effort (SSE disconnect / client gone).
    try lintFile(allocator, "service.zig", "sse.sendError(500, \"boom\") catch {};\n", "src/modules/x/service.zig", &cfg, &violations);
    // b18 — pseudo-transaction: beginTx then pool exec.
    try lintFile(allocator, "service.zig", "pub fn pay(self: *@This(), id: i64) !void {\n    _ = try self.client.beginTx();\n    _ = self.db.exec(\"UPDATE orders SET paid = 1 WHERE id = ?\", &.{});\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b18 negative — tx handle exec inside the transaction is fine.
    try lintFile(allocator, "service.zig", "pub fn pay(self: *@This(), id: i64) !void {\n    var tx = try self.client.beginTx();\n    _ = tx.exec(\"UPDATE orders SET paid = 1 WHERE id = ?\", &.{});\n    try tx.commit();\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b18 negative — pool exec without beginTx is not a pseudo-transaction.
    try lintFile(allocator, "service.zig", "pub fn touch(self: *@This(), id: i64) !void {\n    _ = self.db.exec(\"UPDATE orders SET touched = 1 WHERE id = ?\", &.{});\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "x() catch |err| {\n  _ = err;\n  return;\n};\n", "src/modules/x/service.zig", &cfg, &violations);
    // b12 — pure CRUD passthrough service method (next-line body).
    try lintFile(allocator, "service.zig", "pub fn list(self: *@This(), allocator: std.mem.Allocator, org_id: i64, page: usize, size: usize) !std.ArrayList(T) {\n    return self.persistence.list(allocator, org_id, page, size);\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b12 — same-line body passthrough.
    try lintFile(allocator, "service.zig", "pub fn get(self: *@This(), a: std.mem.Allocator, o: i64, id: i64) !?T { return self.persistence.get(a, o, id); }\n", "src/modules/x/service.zig", &cfg, &violations);
    // b12 negative — validate adds logic, so this is not a pure passthrough.
    try lintFile(allocator, "service.zig", "pub fn create(self: *@This(), e: T) !i64 {\n    try self.validate(e);\n    return self.persistence.create(e);\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b13 — bare entity response in api.zig.
    try lintFile(allocator, "api.zig", "try ctx.jsonStruct(200, e);\n", "src/modules/x/api.zig", &cfg, &violations);
    // b13 negative — struct literal envelopes are fine.
    try lintFile(allocator, "api.zig", "try ctx.jsonStruct(200, .{ .code = 0, .data = e });\n", "src/modules/x/api.zig", &cfg, &violations);
    // b15 — hand-written column-index scan in persistence.zig.
    try lintFile(allocator, "persistence.zig", "    const raw = row.values[2].?.int;\n", "src/modules/x/persistence.zig", &cfg, &violations);
    // b15 negative — typed scan by column name is fine.
    try lintFile(allocator, "persistence.zig", "        while (cursor.next()) |row| try out.append(allocator, try row.scan(allocator, model.X));\n", "src/modules/x/persistence.zig", &cfg, &violations);
    // b16 — two writes in one service method without a transaction.
    try lintFile(allocator, "service.zig", "pub fn ship(self: *@This(), org_id: i64, id: i64) !void {\n    try self.crud.update(.{ .id = id }, org_id);\n    try self.persistence.exec(\"UPDATE x SET y = ?\", &.{.{ .int = 1 }});\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b16 negative — transact() marks the method transactional.
    try lintFile(allocator, "service.zig", "pub fn atomic(self: *@This(), id: i64) !void {\n    return self.transact(void, struct {\n        fn f(tx: *zigmodu.data.sqlx.Transaction) zigmodu.ZigModuError!void {\n            _ = tx;\n            return {};\n        }\n    }.f);\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 — owned queryRow result never freed: only a field is returned,
    // the owned strings leak.
    try lintFile(allocator, "service.zig", "pub fn getProductId(self: *@This(), id: i64) !i64 {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return p.id;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 — inline struct row with a string field, never freed.
    try lintFile(allocator, "service.zig", "pub fn getName(self: *@This(), id: i64) ![]const u8 {\n    const r = try self.db.queryRow(struct { name: []const u8 }, \"SELECT name FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return r.name;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — `const p = queryRow(...); return p;` delegates ownership.
    try lintFile(allocator, "service.zig", "pub fn getProduct(self: *@This(), id: i64) !model.Product {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return p;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — scalar inline struct row owns no strings.
    try lintFile(allocator, "service.zig", "pub fn getCount(self: *@This(), id: i64) !i64 {\n    const r = try self.db.queryRow(struct { count: i64 }, \"SELECT COUNT(*) AS count FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return r.count;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — slice fields that are NOT `[]const u8` (e.g. `[]i64`,
    // `[]u8`) are never freed by freeScanned, so they cannot leak.
    try lintFile(allocator, "service.zig", "pub fn getIds(self: *@This(), id: i64) ![]i64 {\n    const r = try self.db.queryRow(struct { ids: []i64 }, \"SELECT ids FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return r.ids;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    try lintFile(allocator, "service.zig", "pub fn getRaw(self: *@This(), id: i64) ![]u8 {\n    const r = try self.db.queryRow(struct { raw: []u8 }, \"SELECT raw FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return r.raw;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — freeScanned present in the same fn.
    try lintFile(allocator, "service.zig", "pub fn getProduct(self: *@This(), id: i64) !model.Product {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    defer freeScanned(self.allocator, model.Product, p);\n    return p;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — ownership delegated via `return self.db.queryRow(...)`.
    try lintFile(allocator, "service.zig", "pub fn getProduct(self: *@This(), id: i64) !model.Product {\n    return self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — RAII borrowed variant needs no freeing.
    try lintFile(allocator, "service.zig", "pub fn getProduct(self: *@This(), id: i64) !model.Product {\n    var row = try self.db.queryRowBorrowed(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    defer row.deinit();\n    return row.get();\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — assembly return borrows the whole value (single line).
    try lintFile(allocator, "service.zig", "pub fn getDetail(self: *@This(), id: i64) !Detail {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return .{ .product = p, .ts = 1 };\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — assembly return borrows the whole value (multi line).
    try lintFile(allocator, "service.zig", "pub fn getDetail(self: *@This(), id: i64) !Detail {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return .{\n        .product = p,\n        .ts = 1,\n    };\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 — assembly return only borrows a field → strings leak.
    try lintFile(allocator, "service.zig", "pub fn getMeta(self: *@This(), id: i64) !Meta {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    return .{ .id = p.id };\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — cross-line inline struct (type on the next line), scalar.
    try lintFile(allocator, "service.zig", "pub fn getCnt(self: *@This(), id: i64) !i64 {\n    const r = try self.db.queryRow(\n        struct { cnt: i64 },\n        \"SELECT COUNT(*) AS cnt FROM products WHERE id = ?\",\n        &.{.{ .int = id }},\n    );\n    return r.cnt;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — intermediate assembly: `var detail = .{ … p … }; return detail;`.
    try lintFile(allocator, "service.zig", "pub fn getDetail(self: *@This(), id: i64) !Detail {\n    const p = try self.db.queryRow(model.Product, \"SELECT * FROM products WHERE id = ?\", &.{.{ .int = id }});\n    var detail = .{ .product = p, .ts = 1 };\n    return detail;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // b17 negative — cross-line type + single-line `return try queryRow(`:
    // ownership transfers regardless of where the type lands (regression:
    // this must stay exempt even though the type is on the next line).
    try lintFile(allocator, "service.zig", "pub fn getGrade(self: *@This(), id: i64) !model.UserGradeRow {\n    return try self.db.queryRowPartial(\n        model.UserGradeRow,\n        \"SELECT grade_id FROM grades WHERE id = ?\",\n        &.{.{ .int = id }},\n    );\n}\n", "src/modules/x/service.zig", &cfg, &violations);

    var rules = std.StringHashMap(usize).init(allocator);
    defer rules.deinit();
    for (violations.items) |v| {
        const gop = try rules.getOrPut(v.rule);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rules.get("b1").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b2").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b3").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b4").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b5").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b6").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b7").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b8").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b9").?);
    try std.testing.expectEqual(@as(usize, 2), rules.get("b10").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b11").?);
    try std.testing.expectEqual(@as(usize, 2), rules.get("b12").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b13").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b15").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b16").?);
    try std.testing.expectEqual(@as(usize, 3), rules.get("b17").?);
    try std.testing.expectEqual(@as(usize, 1), rules.get("b18").?);
}

test "audit b17 honors named model symbol table" {
    const allocator = std.testing.allocator;

    var symbols = std.StringHashMap(bool).init(allocator);
    defer {
        var kit = symbols.iterator();
        while (kit.next()) |e| allocator.free(e.key_ptr.*);
        symbols.deinit();
    }
    try symbols.put(try allocator.dupe(u8, "ScalarOnly"), false);
    try symbols.put(try allocator.dupe(u8, "User"), true);

    var cfg = RuleConfig{};
    cfg.disabled = std.StringHashMap(void).init(allocator);
    defer cfg.deinit(allocator);
    cfg.model_symbols = &symbols;

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    // Named type known to have no `[]const u8` fields → no leak possible,
    // even though only a field is returned.
    try lintFile(allocator, "service.zig", "pub fn getScalar(self: *@This(), id: i64) !i64 {\n    const s = try self.db.queryRow(model.ScalarOnly, \"SELECT * FROM scalars WHERE id = ?\", &.{.{ .int = id }});\n    return s.id;\n}\n", "src/modules/x/service.zig", &cfg, &violations);
    // Named type with a string field, never freed → still flagged.
    try lintFile(allocator, "service.zig", "pub fn getUser(self: *@This(), id: i64) !i64 {\n    const u = try self.db.queryRow(model.User, \"SELECT * FROM users WHERE id = ?\", &.{.{ .int = id }});\n    return u.id;\n}\n", "src/modules/x/service.zig", &cfg, &violations);

    var rules = std.StringHashMap(usize).init(allocator);
    defer rules.deinit();
    for (violations.items) |v| {
        const gop = try rules.getOrPut(v.rule);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rules.get("b17").?);
}

test "audit collectModelStructs builds symbol table" {
    const allocator = std.testing.allocator;
    const content =
        \\pub const User = struct {
        \\    id: i64,
        \\    name: []const u8,
        \\};
        \\
        \\const CartRow = struct {
        \\    id: i64,
        \\};
        \\
        \\pub fn helper() void {
        \\    const Local = struct { name: []const u8 };
        \\    _ = Local;
        \\}
        \\
        \\const Unclosed = struct {
        \\
    ;

    var symbols = std.StringHashMap(bool).init(allocator);
    defer {
        var kit = symbols.iterator();
        while (kit.next()) |e| allocator.free(e.key_ptr.*);
        symbols.deinit();
    }
    try collectModelStructs(allocator, content, &symbols);

    try std.testing.expect(symbols.get("User").?); // has []const u8
    try std.testing.expect(!symbols.get("CartRow").?); // scalar
    // fn-local (indented) structs are not collected.
    try std.testing.expect(symbols.get("Local") == null);
    // Unclosed struct must not crash or leak the pending name.
    try std.testing.expect(symbols.get("Unclosed") == null);
}

test "audit rules config disables rules" {
    const allocator = std.testing.allocator;
    var cfg = RuleConfig{};
    cfg.disabled = std.StringHashMap(void).init(allocator);
    defer cfg.deinit(allocator);
    try cfg.disabled.put(try allocator.dupe(u8, "b4"), {});
    try cfg.disabled.put(try allocator.dupe(u8, "b9"), {});

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }
    try lintFile(allocator, "api.zig", "const auth = @ptrCast(@alignCast(ctx.user_data));\n", "src/modules/x/api.zig", &cfg, &violations);
    try lintFile(allocator, "api.zig", "const auth = ctx.getHeader(\"Authorization\");\n", "src/modules/x/api.zig", &cfg, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit line-level ignore comment suppresses that line's violations" {
    const allocator = std.testing.allocator;
    var cfg = RuleConfig{};
    cfg.disabled = std.StringHashMap(void).init(allocator);
    defer cfg.deinit(allocator);

    var violations = std.ArrayList(Violation).empty;
    defer {
        for (violations.items) |*v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    // Line with `// audit: ignore b10` — the swallowed-error catch is exempt.
    try lintFile(allocator, "service.zig", "client.exec(sql, &.{}) catch {}; // audit: ignore b10\n", "src/modules/x/service.zig", &cfg, &violations);
    // Same pattern without the marker still reports.
    try lintFile(allocator, "service.zig", "client.exec(sql, &.{}) catch {};\n", "src/modules/x/service.zig", &cfg, &violations);
    // Bare `// audit: ignore` ignores every rule on that line.
    try lintFile(allocator, "service.zig", "client.exec(sql, &.{}) catch {}; // audit: ignore\n", "src/modules/x/service.zig", &cfg, &violations);

    var rules = std.StringHashMap(usize).init(allocator);
    defer rules.deinit();
    for (violations.items) |v| {
        const gop = try rules.getOrPut(v.rule);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rules.get("b10").?);
}
