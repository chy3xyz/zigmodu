const std = @import("std");

/// 模块安全扫描器
/// 提供静态安全分析、依赖漏洞检查和安全最佳实践验证
/// 这是架构评估中的中优先级改进项
pub const SecurityScanner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    rules: std.array_list.Managed(SecurityRule),
    findings: std.array_list.Managed(SecurityFinding),
    config: Config,
    io: std.Io,

    /// 扫描配置
    pub const Config = struct {
        /// 最小严重级别
        min_severity: Severity = .LOW,
        /// 是否扫描依赖
        scan_dependencies: bool = true,
        /// 是否检查敏感信息泄露
        check_secrets: bool = true,
        /// 是否检查不安全的API使用
        check_unsafe_apis: bool = true,
        /// 是否检查权限问题
        check_permissions: bool = true,
    };

    /// 安全规则
    pub const SecurityRule = struct {
        id: []const u8,
        name: []const u8,
        description: []const u8,
        severity: Severity,
        category: Category,
        check_fn: *const fn ([]const u8) ?[]const u8,

        pub const Category = enum {
            SECRETS,
            INJECTION,
            PERMISSIONS,
            DEPENDENCIES,
            CONFIGURATION,
            CRYPTOGRAPHY,
        };
    };

    /// 安全发现
    pub const SecurityFinding = struct {
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        file_path: []const u8,
        line_number: ?usize,
        column: ?usize,
        suggestion: ?[]const u8,

        pub fn format(self: SecurityFinding, allocator: std.mem.Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{
                @tagName(self.severity),
                self.rule_id,
                self.message,
            });
        }
    };

    /// 严重级别
    pub const Severity = enum {
        CRITICAL,
        HIGH,
        MEDIUM,
        LOW,
        INFO,

        pub fn fromString(str: []const u8) ?Severity {
            const map = std.StaticStringMap(Severity).initComptime(.{
                .{ "CRITICAL", .CRITICAL },
                .{ "HIGH", .HIGH },
                .{ "MEDIUM", .MEDIUM },
                .{ "LOW", .LOW },
                .{ "INFO", .INFO },
            });
            return map.get(str);
        }

        pub fn isHigherOrEqual(self: Severity, other: Severity) bool {
            return @intFromEnum(self) <= @intFromEnum(other);
        }
    };

    /// 扫描结果
    pub const ScanResult = struct {
        total_files: usize,
        findings: std.ArrayList(SecurityFinding),
        critical_count: usize = 0,
        high_count: usize = 0,
        medium_count: usize = 0,
        low_count: usize = 0,
        info_count: usize = 0,

        pub fn hasCriticalOrHigh(self: *const ScanResult) bool {
            return self.critical_count > 0 or self.high_count > 0;
        }

        pub fn getTotalIssues(self: *const ScanResult) usize {
            return self.critical_count + self.high_count + self.medium_count + self.low_count + self.info_count;
        }
    };

    /// 初始化扫描器
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Self {
        var scanner = Self{
            .allocator = allocator,
            .rules = std.array_list.Managed(SecurityRule).init(allocator),
            .findings = std.array_list.Managed(SecurityFinding).init(allocator),
            .config = config,
            .io = io,
        };

        // 注册默认规则
        scanner.registerDefaultRules();

        return scanner;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.rules.deinit();

        for (self.findings.items) |*finding| {
            self.allocator.free(finding.message);
            self.allocator.free(finding.file_path);
            if (finding.suggestion) |suggestion| {
                self.allocator.free(suggestion);
            }
        }
        self.findings.deinit();
    }

    /// 注册安全规则
    pub fn registerRule(self: *Self, rule: SecurityRule) !void {
        try self.rules.append(rule);
    }

    /// 注册默认安全规则
    fn registerDefaultRules(self: *Self) void {
        // 硬编码密钥检测
        self.registerRule(.{
            .id = "SEC001",
            .name = "Hardcoded Secret",
            .description = "检测到硬编码的密钥或密码",
            .severity = .CRITICAL,
            .category = .SECRETS,
            .check_fn = checkHardcodedSecret,
        }) catch {};

        // SQL注入检测
        self.registerRule(.{
            .id = "SEC002",
            .name = "SQL Injection Risk",
            .description = "可能存在SQL注入漏洞",
            .severity = .HIGH,
            .category = .INJECTION,
            .check_fn = checkSqlInjection,
        }) catch {};

        // 不安全的HTTP配置
        self.registerRule(.{
            .id = "SEC003",
            .name = "Insecure HTTP Configuration",
            .description = "HTTP配置可能存在安全问题",
            .severity = .MEDIUM,
            .category = .CONFIGURATION,
            .check_fn = checkInsecureHttp,
        }) catch {};

        // 弱加密算法检测
        self.registerRule(.{
            .id = "SEC004",
            .name = "Weak Cryptography",
            .description = "使用了弱加密算法",
            .severity = .HIGH,
            .category = .CRYPTOGRAPHY,
            .check_fn = checkWeakCrypto,
        }) catch {};

        // 权限绕过检测
        self.registerRule(.{
            .id = "SEC005",
            .name = "Missing Authorization",
            .description = "API端点可能缺少授权检查",
            .severity = .HIGH,
            .category = .PERMISSIONS,
            .check_fn = checkMissingAuth,
        }) catch {};
    }

    /// 扫描源代码
    pub fn scanSourceCode(self: *Self, file_path: []const u8, source_code: []const u8) !void {
        for (self.rules.items) |rule| {
            if (@intFromEnum(rule.severity) > @intFromEnum(self.config.min_severity)) {
                continue;
            }

            if (rule.check_fn(source_code)) |message| {
                const finding = SecurityFinding{
                    .rule_id = rule.id,
                    .severity = rule.severity,
                    .message = try self.allocator.dupe(u8, message),
                    .file_path = try self.allocator.dupe(u8, file_path),
                    .line_number = null,
                    .column = null,
                    .suggestion = null,
                };
                try self.findings.append(finding);
            }
        }
    }

    /// 扫描模块
    pub fn scanModule(self: *Self, module_path: []const u8) !ScanResult {
        var result = ScanResult{
            .total_files = 0,
            .findings = std.ArrayList(SecurityFinding).empty,
        };
        errdefer result.findings.deinit(self.allocator);

        // 扫描目录下的所有.zig文件
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, module_path, .{ .iterate = true }) catch |err| {
            std.log.err("无法打开模块目录 {s}: {}", .{ module_path, err });
            return result;
        };
        defer dir.close(std.testing.io);

        var iter = dir.iterate();
        while (try iter.next(std.testing.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                result.total_files += 1;

                const file_path = try std.fs.path.join(self.allocator, &.{ module_path, entry.name });
                defer self.allocator.free(file_path);

                const content = dir.readFileAlloc(self.io, entry.name, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
                    std.log.warn("无法读取文件 {s}: {}", .{ entry.name, err });
                    continue;
                };
                defer self.allocator.free(content);

                try self.scanSourceCode(file_path, content);
            }
        }

        // 统计发现的问题
        for (self.findings.items) |finding| {
            try result.findings.append(self.allocator, finding);
            switch (finding.severity) {
                .CRITICAL => result.critical_count += 1,
                .HIGH => result.high_count += 1,
                .MEDIUM => result.medium_count += 1,
                .LOW => result.low_count += 1,
                .INFO => result.info_count += 1,
            }
        }

        return result;
    }

    /// 生成扫描报告
    pub fn generateReport(self: *Self, result: *const ScanResult) ![]const u8 {
        var buf = std.ArrayList(u8).empty;

        try buf.appendSlice(self.allocator, "# Security Scan Report\n\n");
        try buf.print(self.allocator, "Total Files Scanned: {d}\n", .{result.total_files});
        try buf.print(self.allocator, "Total Issues Found: {d}\n\n", .{result.getTotalIssues()});

        try buf.appendSlice(self.allocator, "## Severity Summary\n\n");
        try buf.print(self.allocator, "- Critical: {d}\n", .{result.critical_count});
        try buf.print(self.allocator, "- High: {d}\n", .{result.high_count});
        try buf.print(self.allocator, "- Medium: {d}\n", .{result.medium_count});
        try buf.print(self.allocator, "- Low: {d}\n", .{result.low_count});
        try buf.print(self.allocator, "- Info: {d}\n\n", .{result.info_count});

        if (result.findings.items.len > 0) {
            try buf.appendSlice(self.allocator, "## Detailed Findings\n\n");
            for (result.findings.items) |finding| {
                const formatted = try finding.format(self.allocator);
                defer self.allocator.free(formatted);
                try buf.print(self.allocator, "- {s} ({s})\n", .{ formatted, finding.file_path });
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// 检查是否通过安全扫描
    pub fn isSecure(self: *Self, result: *const ScanResult) bool {
        _ = self;
        return !result.hasCriticalOrHigh();
    }

    // 规则检查函数
    fn checkHardcodedSecret(source: []const u8) ?[]const u8 {
        const patterns = [_][]const u8{
            "password = \"",
            "secret = \"",
            "api_key = \"",
            "token = \"",
            "private_key",
        };

        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, source, pattern) != null) {
                return "检测到可能的硬编码密钥";
            }
        }
        return null;
    }

    fn checkSqlInjection(source: []const u8) ?[]const u8 {
        const patterns = [_][]const u8{
            "EXECUTE IMMEDIATE",
            "sqlite3_exec",
            "query(\"",
        };

        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, source, pattern) != null) {
                return "可能存在SQL注入风险";
            }
        }
        return null;
    }

    fn checkInsecureHttp(source: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, source, "http://") != null) {
            return "使用不安全的HTTP协议";
        }
        return null;
    }

    fn checkWeakCrypto(source: []const u8) ?[]const u8 {
        const patterns = [_][]const u8{
            "MD5",
            "SHA1",
            "DES",
        };

        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, source, pattern) != null) {
                return "使用了弱加密算法";
            }
        }
        return null;
    }

    fn checkMissingAuth(source: []const u8) ?[]const u8 {
        // 简化检查：查找API定义但缺少auth检查
        if (std.mem.indexOf(u8, source, "pub fn") != null and
            std.mem.indexOf(u8, source, "authorize") == null and
            std.mem.indexOf(u8, source, "authenticate") == null)
        {
            return "公共函数可能缺少授权检查";
        }
        return null;
    }
};

/// 依赖漏洞检查器
pub const DependencyScanner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vulnerability_db: std.StringHashMap(Vulnerability),

    /// 漏洞信息
    pub const Vulnerability = struct {
        id: []const u8,
        package_name: []const u8,
        affected_versions: []const u8,
        severity: SecurityScanner.Severity,
        description: []const u8,
        fix_version: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .vulnerability_db = std.StringHashMap(Vulnerability).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.vulnerability_db.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.package_name);
            self.allocator.free(entry.value_ptr.affected_versions);
            self.allocator.free(entry.value_ptr.description);
            if (entry.value_ptr.fix_version) |version| {
                self.allocator.free(version);
            }
        }
        self.vulnerability_db.deinit();
    }

    /// 添加漏洞信息到数据库
    pub fn addVulnerability(self: *Self, vuln: Vulnerability) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{
            vuln.package_name,
            vuln.affected_versions,
        });
        errdefer self.allocator.free(key);

        const owned_vuln = Vulnerability{
            .id = try self.allocator.dupe(u8, vuln.id),
            .package_name = try self.allocator.dupe(u8, vuln.package_name),
            .affected_versions = try self.allocator.dupe(u8, vuln.affected_versions),
            .severity = vuln.severity,
            .description = try self.allocator.dupe(u8, vuln.description),
            .fix_version = if (vuln.fix_version) |v| try self.allocator.dupe(u8, v) else null,
        };

        try self.vulnerability_db.put(key, owned_vuln);
    }

    /// 检查依赖是否存在已知漏洞
    pub fn checkDependency(self: *Self, package_name: []const u8, version: []const u8) ?Vulnerability {
        _ = version;
        var iter = self.vulnerability_db.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.package_name, package_name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }
};

/// 安全配置验证器
pub const SecurityConfigValidator = struct {
    const Self = @This();

    /// 安全配置检查项
    pub const SecurityCheck = struct {
        name: []const u8,
        description: []const u8,
        validate_fn: *const fn () bool,
    };

    checks: std.array_list.Managed(SecurityCheck),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .checks = std.array_list.Managed(SecurityCheck).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.checks.deinit();
    }

    /// 添加安全检查
    pub fn addCheck(self: *Self, check: SecurityCheck) !void {
        try self.checks.append(check);
    }

    /// 运行所有安全检查
    pub fn validateAll(self: *Self) ValidationResult {
        var result = ValidationResult{
            .passed = true,
            .failed_checks = std.array_list.Managed([]const u8).init(self.checks.allocator),
        };

        for (self.checks.items) |check| {
            if (!check.validate_fn()) {
                result.passed = false;
                result.failed_checks.append(check.name) catch {};
            }
        }

        return result;
    }

    pub const ValidationResult = struct {
        passed: bool,
        failed_checks: std.array_list.Managed([]const u8),

        pub fn deinit(self: *ValidationResult) void {
            self.failed_checks.deinit();
        }
    };
};

// 测试用例
test "SecurityScanner basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var scanner = SecurityScanner.init(allocator, std.testing.io, .{
        .min_severity = .LOW,
    });
    defer scanner.deinit();

    // 测试扫描有问题的代码
    const test_code =
        \\\const password = "secret123";
        \\\var api_key = "sk-1234567890";
    ;

    try scanner.scanSourceCode("test.zig", test_code);

    try testing.expect(scanner.findings.items.len > 0);
}

test "SecurityScanner Severity" {
    const testing = std.testing;

    try testing.expect(SecurityScanner.Severity.CRITICAL.isHigherOrEqual(.HIGH));
    try testing.expect(!SecurityScanner.Severity.LOW.isHigherOrEqual(.HIGH));

    const severity = SecurityScanner.Severity.fromString("HIGH");
    try testing.expectEqual(SecurityScanner.Severity.HIGH, severity.?);
}

test "DependencyScanner" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var scanner = DependencyScanner.init(allocator);
    defer scanner.deinit();

    const vuln = DependencyScanner.Vulnerability{
        .id = "CVE-2024-0001",
        .package_name = "vulnerable-pkg",
        .affected_versions = "<1.0.0",
        .severity = .HIGH,
        .description = "Test vulnerability",
        .fix_version = "1.0.1",
    };

    try scanner.addVulnerability(vuln);

    const found = scanner.checkDependency("vulnerable-pkg", "0.9.0");
    try testing.expect(found != null);
}

test "SecurityConfigValidator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = SecurityConfigValidator.init(allocator);
    defer validator.deinit();

    try validator.addCheck(.{
        .name = "HTTPS_Enabled",
        .description = "HTTPS must be enabled",
        .validate_fn = struct {
            fn check() bool {
                return true;
            }
        }.check,
    });

    var result = validator.validateAll();
    defer result.deinit();

    try testing.expect(result.passed);
}

test "SecurityScanner scanModule" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f1 = try tmp_dir.dir.createFile(std.testing.io, "main.zig", .{});
    try f1.writeStreamingAll(std.testing.io, "const password = \"secret123\";\n");
    f1.close(std.testing.io);

    const f2 = try tmp_dir.dir.createFile(std.testing.io, "http.zig", .{});
    try f2.writeStreamingAll(std.testing.io, "const url = \"http://example.com\";\n");
    f2.close(std.testing.io);

    const f3 = try tmp_dir.dir.createFile(std.testing.io, "crypto.zig", .{});
    try f3.writeStreamingAll(std.testing.io, "const hash = MD5.init();\n");
    f3.close(std.testing.io);

    const base_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base_path);

    var scanner = SecurityScanner.init(allocator, std.testing.io, .{
        .min_severity = .LOW,
    });
    defer scanner.deinit();

    var result = try scanner.scanModule(base_path);
    defer result.findings.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.total_files);
    try testing.expect(result.findings.items.len >= 3);
    try testing.expect(result.getTotalIssues() >= 3);
    try testing.expect(result.hasCriticalOrHigh());
}

test "SecurityScanner generate report" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var scanner = SecurityScanner.init(allocator, std.testing.io, .{});
    defer scanner.deinit();

    const test_code = "const password = \"secret\";\n";
    try scanner.scanSourceCode("test.zig", test_code);

    var dummy_result = SecurityScanner.ScanResult{
        .total_files = 1,
        .findings = std.ArrayList(SecurityScanner.SecurityFinding).empty,
    };
    defer dummy_result.findings.deinit(allocator);

    for (scanner.findings.items) |finding| {
        try dummy_result.findings.append(allocator, finding);
        switch (finding.severity) {
            .CRITICAL => dummy_result.critical_count += 1,
            .HIGH => dummy_result.high_count += 1,
            .MEDIUM => dummy_result.medium_count += 1,
            .LOW => dummy_result.low_count += 1,
            .INFO => dummy_result.info_count += 1,
        }
    }

    const report = try scanner.generateReport(&dummy_result);
    defer allocator.free(report);

    try testing.expect(std.mem.indexOf(u8, report, "Security Scan Report") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Total Issues Found") != null);
}

test "SecurityScanner isSecure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var scanner = SecurityScanner.init(allocator, std.testing.io, .{});
    defer scanner.deinit();

    var secure_result = SecurityScanner.ScanResult{
        .total_files = 1,
        .findings = std.ArrayList(SecurityScanner.SecurityFinding).empty,
        .low_count = 1,
    };
    defer secure_result.findings.deinit(allocator);

    var insecure_result = SecurityScanner.ScanResult{
        .total_files = 1,
        .findings = std.ArrayList(SecurityScanner.SecurityFinding).empty,
        .high_count = 1,
    };
    defer insecure_result.findings.deinit(allocator);

    try testing.expect(scanner.isSecure(&secure_result));
    try testing.expect(!scanner.isSecure(&insecure_result));
}
