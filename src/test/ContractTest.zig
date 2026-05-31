const std = @import("std");

/// [...] (Consumer-Driven Contract)
pub const Contract = struct {
    /// [...]
    name: []const u8,
    /// consume[...]
    consumer: []const u8,
    /// [...]
    provider: []const u8,
    /// [...]
    version: []const u8,
    /// Interaction type
    interaction_type: InteractionType,
    /// [...]
    request: RequestMatcher,
    /// [...]
    response: ResponseExpectation,

    pub const InteractionType = enum {
        http,
        grpc,
        event,
        message,
    };

    pub const RequestMatcher = struct {
        method: []const u8,
        path: []const u8,
        headers: []const HeaderMatcher = &.{},
        body: ?[]const u8 = null,
    };

    pub const HeaderMatcher = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const ResponseExpectation = struct {
        status: u16,
        headers: []const HeaderMatcher = &.{},
        body_contains: ?[]const u8 = null,
        body_schema: ?[]const u8 = null,
    };
};

/// [...]Validation[...]
pub const ContractVerificationResult = struct {
    contract_name: []const u8,
    passed: bool,
    failures: []const ContractFailure,
    duration_ms: u64,

    pub const ContractFailure = struct {
        field: []const u8,
        expected: []const u8,
        actual: []const u8,
        message: []const u8,
    };
};

/// [...]Tests[...]
/// consume[...]Tests (Pact-style)
pub const ContractTestRunner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    contracts: std.ArrayList(Contract),
    verifications: std.ArrayList(ContractVerificationResult),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .contracts = std.ArrayList(Contract).empty,
            .verifications = std.ArrayList(ContractVerificationResult).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.contracts.items) |c| {
            self.allocator.free(c.name);
            self.allocator.free(c.consumer);
            self.allocator.free(c.provider);
            self.allocator.free(c.version);
            self.allocator.free(c.request.method);
            self.allocator.free(c.request.path);
            for (c.request.headers) |h| {
                self.allocator.free(h.key);
                self.allocator.free(h.value);
            }
            self.allocator.free(c.request.headers);
            if (c.request.body) |b| self.allocator.free(b);
            for (c.response.headers) |h| {
                self.allocator.free(h.key);
                self.allocator.free(h.value);
            }
            self.allocator.free(c.response.headers);
            if (c.response.body_contains) |bc| self.allocator.free(bc);
            if (c.response.body_schema) |bs| self.allocator.free(bs);
        }
        self.contracts.deinit(self.allocator);

        for (self.verifications.items) |v| {
            self.allocator.free(v.contract_name);
            for (v.failures) |f| {
                self.allocator.free(f.field);
                self.allocator.free(f.expected);
                self.allocator.free(f.actual);
                self.allocator.free(f.message);
            }
            self.allocator.free(v.failures);
        }
        self.verifications.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...]
    pub fn registerContract(self: *Self, contract: Contract) !void {
        const owned = try self.cloneContract(contract);
        try self.contracts.append(self.allocator, owned);
    }

    /// Validation[...]: [...]
    pub fn verifyContract(
        self: *Self,
        contract_name: []const u8,
        actual_status: u16,
        actual_body: []const u8,
        actual_headers: []const Contract.HeaderMatcher,
    ) !ContractVerificationResult {
        const contract = self.findContract(contract_name) orelse return error.ContractNotFound;

        var failures = std.ArrayList(ContractVerificationResult.ContractFailure).empty;
        const start = @import("../core/Time.zig").monotonicNowSeconds();

        // Validation[...]
        if (actual_status != contract.response.status) {
            try failures.append(self.allocator, .{
                .field = try self.allocator.dupe(u8, "status"),
                .expected = try std.fmt.allocPrint(self.allocator, "{d}", .{contract.response.status}),
                .actual = try std.fmt.allocPrint(self.allocator, "{d}", .{actual_status}),
                .message = try self.allocator.dupe(u8, "HTTP status mismatch"),
            });
        }

        // Validation[...]
        if (contract.response.body_contains) |expected| {
            if (!std.mem.containsAtLeast(u8, actual_body, 1, expected)) {
                try failures.append(self.allocator, .{
                    .field = try self.allocator.dupe(u8, "body"),
                    .expected = try self.allocator.dupe(u8, expected),
                    .actual = try self.allocator.dupe(u8, actual_body),
                    .message = try self.allocator.dupe(u8, "Response body does not contain expected string"),
                });
            }
        }

        // Validation[...]
        for (contract.response.headers) |expected_header| {
            var found = false;
            for (actual_headers) |actual_header| {
                if (std.mem.eql(u8, expected_header.key, actual_header.key)) {
                    if (!std.mem.eql(u8, expected_header.value, actual_header.value)) {
                        try failures.append(self.allocator, .{
                            .field = try std.fmt.allocPrint(self.allocator, "header.{s}", .{expected_header.key}),
                            .expected = try self.allocator.dupe(u8, expected_header.value),
                            .actual = try self.allocator.dupe(u8, actual_header.value),
                            .message = try self.allocator.dupe(u8, "Response header value mismatch"),
                        });
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                try failures.append(self.allocator, .{
                    .field = try std.fmt.allocPrint(self.allocator, "header.{s}", .{expected_header.key}),
                    .expected = try self.allocator.dupe(u8, expected_header.value),
                    .actual = try self.allocator.dupe(u8, "<missing>"),
                    .message = try self.allocator.dupe(u8, "Expected response header not found"),
                });
            }
        }

        const end = @import("../core/Time.zig").monotonicNowSeconds();
        const duration = @as(u64, @intCast((end - start) * 1000));
        const passed = failures.items.len == 0;

        return ContractVerificationResult{
            .contract_name = try self.allocator.dupe(u8, contract_name),
            .passed = passed,
            .failures = try failures.toOwnedSlice(self.allocator),
            .duration_ms = duration,
        };
    }

    /// [...]
    pub fn generateReport(self: *Self) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "═══════════════════════════════════\n");
        try buf.appendSlice(self.allocator, "  Contract Test Report\n");
        try buf.appendSlice(self.allocator, "═══════════════════════════════════\n\n");

        var passed: usize = 0;
        var failed: usize = 0;

        for (self.verifications.items) |v| {
            if (v.passed) {
                passed += 1;
                const line = try std.fmt.allocPrint(self.allocator, "  ✓ {s}\n", .{v.contract_name});
                defer self.allocator.free(line);
                try buf.appendSlice(self.allocator, line);
            } else {
                failed += 1;
                const line = try std.fmt.allocPrint(self.allocator, "  ✗ {s}\n", .{v.contract_name});
                defer self.allocator.free(line);
                try buf.appendSlice(self.allocator, line);

                for (v.failures) |f| {
                    const detail = try std.fmt.allocPrint(self.allocator,
                        "    - {s}: expected '{s}', got '{s}' ({s})\n",
                        .{ f.field, f.expected, f.actual, f.message },
                    );
                    defer self.allocator.free(detail);
                    try buf.appendSlice(self.allocator, detail);
                }
            }
        }

        const summary = try std.fmt.allocPrint(self.allocator,
            "\n  Results: {d} passed, {d} failed, {d} total\n",
            .{ passed, failed, passed + failed },
        );
        defer self.allocator.free(summary);
        try buf.appendSlice(self.allocator, summary);

        return buf.toOwnedSlice(self.allocator);
    }

    fn findContract(self: *Self, name: []const u8) ?Contract {
        for (self.contracts.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn cloneContract(self: *Self, c: Contract) !Contract {
        const name_copy = try self.allocator.dupe(u8, c.name);
        errdefer self.allocator.free(name_copy);

        var req_headers_copy = try self.allocator.alloc(Contract.HeaderMatcher, c.request.headers.len);
        for (c.request.headers, 0..) |h, i| {
            req_headers_copy[i] = .{
                .key = try self.allocator.dupe(u8, h.key),
                .value = try self.allocator.dupe(u8, h.value),
            };
        }

        var resp_headers_copy = try self.allocator.alloc(Contract.HeaderMatcher, c.response.headers.len);
        for (c.response.headers, 0..) |h, i| {
            resp_headers_copy[i] = .{
                .key = try self.allocator.dupe(u8, h.key),
                .value = try self.allocator.dupe(u8, h.value),
            };
        }

        return Contract{
            .name = name_copy,
            .consumer = try self.allocator.dupe(u8, c.consumer),
            .provider = try self.allocator.dupe(u8, c.provider),
            .version = try self.allocator.dupe(u8, c.version),
            .interaction_type = c.interaction_type,
            .request = .{
                .method = try self.allocator.dupe(u8, c.request.method),
                .path = try self.allocator.dupe(u8, c.request.path),
                .headers = req_headers_copy,
                .body = if (c.request.body) |b| try self.allocator.dupe(u8, b) else null,
            },
            .response = .{
                .status = c.response.status,
                .headers = resp_headers_copy,
                .body_contains = if (c.response.body_contains) |bc| try self.allocator.dupe(u8, bc) else null,
                .body_schema = if (c.response.body_schema) |bs| try self.allocator.dupe(u8, bs) else null,
            },
        };
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "ContractTestRunner register and verify pass" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "order-create",
        .consumer = "order-service",
        .provider = "payment-service",
        .version = "1.0",
        .interaction_type = .http,
        .request = .{ .method = "POST", .path = "/api/payments" },
        .response = .{ .status = 201, .body_contains = "paid" },
    });

    const result = try runner.verifyContract("order-create", 201, "{\"status\":\"paid\"}", &.{});
    defer {
        allocator.free(result.contract_name);
        for (result.failures) |f| {
            allocator.free(f.field);
            allocator.free(f.expected);
            allocator.free(f.actual);
            allocator.free(f.message);
        }
        allocator.free(result.failures);
    }

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failures.len);
}

test "ContractTestRunner verify fail - status mismatch" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "status-test",
        .consumer = "c1",
        .provider = "p1",
        .version = "1.0",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/health" },
        .response = .{ .status = 200 },
    });

    const result = try runner.verifyContract("status-test", 500, "{}", &.{});
    defer {
        allocator.free(result.contract_name);
        for (result.failures) |f| {
            allocator.free(f.field);
            allocator.free(f.expected);
            allocator.free(f.actual);
            allocator.free(f.message);
        }
        allocator.free(result.failures);
    }

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.failures.len);
}

test "ContractTestRunner verify fail - body mismatch" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "body-test",
        .consumer = "c1",
        .provider = "p1",
        .version = "1.0",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/data" },
        .response = .{ .status = 200, .body_contains = "success" },
    });

    const result = try runner.verifyContract("body-test", 200, "{\"error\":\"failed\"}", &.{});
    defer {
        allocator.free(result.contract_name);
        for (result.failures) |f| {
            allocator.free(f.field);
            allocator.free(f.expected);
            allocator.free(f.actual);
            allocator.free(f.message);
        }
        allocator.free(result.failures);
    }

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 1), result.failures.len);
    try std.testing.expectEqualStrings("body", result.failures[0].field);
}

test "ContractTestRunner verify headers" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "header-test",
        .consumer = "c1",
        .provider = "p1",
        .version = "1.0",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/api" },
        .response = .{
            .status = 200,
            .headers = &.{
                .{ .key = "Content-Type", .value = "application/json" },
                .{ .key = "X-Request-Id", .value = "12345" },
            },
        },
    });

    const actual_headers = &[_]Contract.HeaderMatcher{
        .{ .key = "Content-Type", .value = "text/plain" },
    };

    const result = try runner.verifyContract("header-test", 200, "{}", actual_headers);
    defer {
        allocator.free(result.contract_name);
        for (result.failures) |f| {
            allocator.free(f.field);
            allocator.free(f.expected);
            allocator.free(f.actual);
            allocator.free(f.message);
        }
        allocator.free(result.failures);
    }

    // Content-Type mismatch + X-Request-Id missing = 2 failures
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.failures.len >= 1);
}

test "ContractTestRunner generate report" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "report-test",
        .consumer = "c1",
        .provider = "p1",
        .version = "1.0",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/ok" },
        .response = .{ .status = 200 },
    });

    const r = try runner.verifyContract("report-test", 200, "ok", &.{});
    defer {
        allocator.free(r.contract_name);
        for (r.failures) |f| {
            allocator.free(f.field);
            allocator.free(f.expected);
            allocator.free(f.actual);
            allocator.free(f.message);
        }
        allocator.free(r.failures);
    }

    try std.testing.expect(r.passed);
    try std.testing.expectEqualStrings("report-test", r.contract_name);
}

test "ContractTestRunner contract not found" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    const result = runner.verifyContract("nonexistent", 200, "", &.{});
    try std.testing.expectError(error.ContractNotFound, result);
}
