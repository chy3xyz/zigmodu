const std = @import("std");

/// OpenAPI [...]
pub const OpenApiVersion = enum {
    v3_0,
    v3_1,
};

/// HTTP [...]
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

/// [...]
pub const ParamLocation = enum {
    query,
    path,
    header,
    cookie,
};

/// API endpoint[...]
pub const ApiParam = struct {
    name: []const u8,
    location: ParamLocation,
    param_type: []const u8 = "string",
    required: bool = false,
    description: []const u8 = "",
};

/// API endpoint[...]
pub const ApiEndpoint = struct {
    method: HttpMethod,
    path: []const u8,
    summary: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    params: []const ApiParam = &.{},
    request_body: ?RequestBody = null,
    responses: []const ApiResponse = &.{},
    deprecated: bool = false,
    /// When true (and generator `bearer_auth` is on), the operation gets
    /// `"security": [{"bearerAuth": []}]`. Set from catalog `auth != .public`.
    requires_auth: bool = false,
};

/// Request body[...]
pub const RequestBody = struct {
    content_type: []const u8 = "application/json",
    description: []const u8 = "",
    required: bool = true,
    schema_ref: ?[]const u8 = null,
};

/// API response[...]
pub const ApiResponse = struct {
    status_code: u16,
    description: []const u8,
    schema_ref: ?[]const u8 = null,
};

/// [...]/ Schema [...]
pub const ApiSchema = struct {
    name: []const u8,
    schema_type: []const u8 = "object",
    properties: []const SchemaProperty = &.{},
    required_fields: []const []const u8 = &.{},
    description: []const u8 = "",
};

/// Schema [...]
pub const SchemaProperty = struct {
    name: []const u8,
    prop_type: []const u8,
    format: ?[]const u8 = null,
    description: []const u8 = "",
    example: ?[]const u8 = null,
    nullable: bool = false,
    enum_values: ?[]const []const u8 = null,
};

/// OpenAPI [...]
/// [...] OpenAPI 3.0/3.1 JSON
pub const OpenApiGenerator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    title: []const u8,
    version: []const u8,
    description: []const u8,
    base_path: []const u8,
    api_version: OpenApiVersion,
    /// When true, emits `components.securitySchemes.bearerAuth` (http/bearer,
    /// JWT) and per-operation `security` for endpoints with `requires_auth`.
    bearer_auth: bool = false,

    endpoints: std.ArrayList(ApiEndpoint),
    schemas: std.ArrayList(ApiSchema),
    tags: std.ArrayList([]const u8),

    pub fn init(
        allocator: std.mem.Allocator,
        title: []const u8,
        version: []const u8,
        description: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .title = title,
            .version = version,
            .description = description,
            .base_path = "/",
            .api_version = .v3_0,
            .endpoints = std.ArrayList(ApiEndpoint).empty,
            .schemas = std.ArrayList(ApiSchema).empty,
            .tags = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.endpoints.items) |ep| {
            self.allocator.free(ep.path);
            self.allocator.free(ep.summary);
            self.allocator.free(ep.description);
            for (ep.tags) |t| self.allocator.free(t);
            self.allocator.free(ep.tags);
            for (ep.params) |p| {
                self.allocator.free(p.name);
                self.allocator.free(p.param_type);
                self.allocator.free(p.description);
            }
            self.allocator.free(ep.params);
            for (ep.responses) |r| {
                self.allocator.free(r.description);
            }
            self.allocator.free(ep.responses);
        }
        self.endpoints.deinit(self.allocator);

        for (self.schemas.items) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.schema_type);
            self.allocator.free(s.description);
            for (s.properties) |p| {
                self.allocator.free(p.name);
                self.allocator.free(p.prop_type);
                self.allocator.free(p.description);
            }
            self.allocator.free(s.properties);
            for (s.required_fields) |rf| self.allocator.free(rf);
            self.allocator.free(s.required_fields);
        }
        self.schemas.deinit(self.allocator);

        for (self.tags.items) |t| self.allocator.free(t);
        self.tags.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...] API endpoint
    pub fn addEndpoint(self: *Self, endpoint: ApiEndpoint) !void {
        const owned = try self.cloneEndpoint(endpoint);
        try self.endpoints.append(self.allocator, owned);

        // [...] tags
        for (owned.tags) |tag| {
            var found = false;
            for (self.tags.items) |existing| {
                if (std.mem.eql(u8, existing, tag)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.tags.append(self.allocator, try self.allocator.dupe(u8, tag));
            }
        }
    }

    /// [...] Schema
    pub fn addSchema(self: *Self, schema: ApiSchema) !void {
        const owned = try self.cloneSchema(schema);
        try self.schemas.append(self.allocator, owned);
    }

    /// [...] OpenAPI JSON [...]
    pub fn generate(self: *Self) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        // Helper: allocPrint → append → free; emitEscaped for JSON string contents
        const S = struct {
            fn emit(target: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(s);
                try target.appendSlice(alloc, s);
            }
            fn emitJsonStr(target: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
                try target.append(alloc, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try target.appendSlice(alloc, "\\\""),
                        '\\' => try target.appendSlice(alloc, "\\\\"),
                        '\n' => try target.appendSlice(alloc, "\\n"),
                        '\r' => try target.appendSlice(alloc, "\\r"),
                        '\t' => try target.appendSlice(alloc, "\\t"),
                        else => {
                            if (c < 0x20) {
                                try emit(target, alloc, "\\u{x:0>4}", .{c});
                            } else {
                                try target.append(alloc, c);
                            }
                        },
                    }
                }
                try target.append(alloc, '"');
            }
        };

        try S.emit(&buf, self.allocator, "{{\n", .{});

        // openapi field
        const openapi_ver = switch (self.api_version) {
            .v3_0 => "3.0.3",
            .v3_1 => "3.1.0",
        };
        try S.emit(&buf, self.allocator, "  \"openapi\": \"{s}\",\n", .{openapi_ver});

        // info
        try buf.appendSlice(self.allocator, "  \"info\": {\n");
        try buf.appendSlice(self.allocator, "    \"title\": ");
        try S.emitJsonStr(&buf, self.allocator, self.title);
        try buf.appendSlice(self.allocator, ",\n");
        try buf.appendSlice(self.allocator, "    \"version\": ");
        try S.emitJsonStr(&buf, self.allocator, self.version);
        try buf.appendSlice(self.allocator, ",\n");
        try buf.appendSlice(self.allocator, "    \"description\": ");
        try S.emitJsonStr(&buf, self.allocator, self.description);
        try buf.appendSlice(self.allocator, "\n");
        try buf.appendSlice(self.allocator, "  },\n");

        // servers
        try buf.appendSlice(self.allocator, "  \"servers\": [\n");
        try buf.appendSlice(self.allocator, "    { \"url\": \"/\" }\n");
        try buf.appendSlice(self.allocator, "  ],\n");

        // tags
        if (self.tags.items.len > 0) {
            try buf.appendSlice(self.allocator, "  \"tags\": [\n");
            for (self.tags.items, 0..) |tag, i| {
                const comma = if (i < self.tags.items.len - 1) "," else "";
                try S.emit(&buf, self.allocator, "    {{ \"name\": \"{s}\" }}{s}\n", .{ tag, comma });
            }
            try buf.appendSlice(self.allocator, "  ],\n");
        }

        // paths
        try buf.appendSlice(self.allocator, "  \"paths\": {\n");
        var path_map = std.StringHashMap(std.ArrayList(*ApiEndpoint)).init(self.allocator);
        defer {
            var it = path_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            path_map.deinit();
        }

        for (self.endpoints.items) |*ep| {
            const gop = try path_map.getOrPut(ep.path);
            if (!gop.found_existing) {
                gop.key_ptr.* = ep.path;
                gop.value_ptr.* = std.ArrayList(*ApiEndpoint).empty;
            }
            try gop.value_ptr.append(self.allocator, ep);
        }

        var path_iter = path_map.iterator();
        var path_idx: usize = 0;
        while (path_iter.next()) |path_entry| : (path_idx += 1) {
            const path = path_entry.key_ptr.*;
            const eps = path_entry.value_ptr;

            try S.emit(&buf, self.allocator, "    \"{s}\": {{\n", .{path});

            for (eps.items, 0..) |ep, ep_idx| {
                const method = methodToString(ep.method);
                try S.emit(&buf, self.allocator, "      \"{s}\": {{\n", .{method});

                // summary
                try buf.appendSlice(self.allocator, "        \"summary\": ");
                try S.emitJsonStr(&buf, self.allocator, ep.summary);
                try buf.appendSlice(self.allocator, ",\n");

                // description
                if (ep.description.len > 0) {
                    try buf.appendSlice(self.allocator, "        \"description\": ");
                    try S.emitJsonStr(&buf, self.allocator, ep.description);
                    try buf.appendSlice(self.allocator, ",\n");
                }

                // tags
                if (ep.tags.len > 0) {
                    try buf.appendSlice(self.allocator, "        \"tags\": [");
                    for (ep.tags, 0..) |tag, ti| {
                        const comma = if (ti < ep.tags.len - 1) ", " else "";
                        try S.emit(&buf, self.allocator, "\"{s}\"{s}", .{ tag, comma });
                    }
                    try buf.appendSlice(self.allocator, "],\n");
                }

                // parameters
                if (ep.params.len > 0) {
                    try buf.appendSlice(self.allocator, "        \"parameters\": [\n");
                    for (ep.params, 0..) |param, pi| {
                        const comma = if (pi < ep.params.len - 1) "," else "";
                        const req = if (param.required) "true" else "false";
                        try S.emit(
                            &buf,
                            self.allocator,
                            "          {{ \"name\": \"{s}\", \"in\": \"{s}\", \"required\": {s}, \"schema\": {{ \"type\": \"{s}\" }} }}{s}\n",
                            .{ param.name, @tagName(param.location), req, param.param_type, comma },
                        );
                    }
                    try buf.appendSlice(self.allocator, "        ],\n");
                }

                // security (M14): non-public endpoints require bearerAuth
                if (self.bearer_auth and ep.requires_auth) {
                    try buf.appendSlice(self.allocator, "        \"security\": [ { \"bearerAuth\": [] } ],\n");
                }

                // responses
                try buf.appendSlice(self.allocator, "        \"responses\": {\n");
                for (ep.responses, 0..) |resp, ri| {
                    const comma = if (ri < ep.responses.len - 1) "," else "";
                    try S.emit(
                        &buf,
                        self.allocator,
                        "          \"{d}\": {{ \"description\": \"{s}\" }}{s}\n",
                        .{ resp.status_code, resp.description, comma },
                    );
                }
                try buf.appendSlice(self.allocator, "        }\n");

                const close_method = if (ep_idx < eps.items.len - 1) "      },\n" else "      }\n";
                try buf.appendSlice(self.allocator, close_method);
            }

            const close_path = if (path_idx < path_map.count() - 1) "    },\n" else "    }\n";
            try buf.appendSlice(self.allocator, close_path);
        }

        // components.securitySchemes (M14): only when bearer auth is enabled
        // and at least one endpoint actually requires it.
        var any_auth = false;
        if (self.bearer_auth) {
            for (self.endpoints.items) |ep| {
                if (ep.requires_auth) {
                    any_auth = true;
                    break;
                }
            }
        }
        if (any_auth) {
            try buf.appendSlice(self.allocator, "  },\n");
            try buf.appendSlice(self.allocator, "  \"components\": {\n");
            try buf.appendSlice(self.allocator, "    \"securitySchemes\": {\n");
            try buf.appendSlice(self.allocator, "      \"bearerAuth\": { \"type\": \"http\", \"scheme\": \"bearer\", \"bearerFormat\": \"JWT\" }\n");
            try buf.appendSlice(self.allocator, "    }\n");
            try buf.appendSlice(self.allocator, "  }\n");
        } else {
            try buf.appendSlice(self.allocator, "  }\n");
        }

        try buf.appendSlice(self.allocator, "}\n");

        return buf.toOwnedSlice(self.allocator);
    }

    fn cloneEndpoint(self: *Self, ep: ApiEndpoint) !ApiEndpoint {
        const path_copy = try self.allocator.dupe(u8, ep.path);
        errdefer self.allocator.free(path_copy);
        const summary_copy = try self.allocator.dupe(u8, ep.summary);
        errdefer self.allocator.free(summary_copy);
        const desc_copy = try self.allocator.dupe(u8, ep.description);
        errdefer self.allocator.free(desc_copy);

        var tags_copy = try self.allocator.alloc([]const u8, ep.tags.len);
        for (ep.tags, 0..) |t, i| {
            tags_copy[i] = try self.allocator.dupe(u8, t);
        }

        var params_copy = try self.allocator.alloc(ApiParam, ep.params.len);
        for (ep.params, 0..) |p, i| {
            params_copy[i] = .{
                .name = try self.allocator.dupe(u8, p.name),
                .location = p.location,
                .param_type = try self.allocator.dupe(u8, p.param_type),
                .required = p.required,
                .description = try self.allocator.dupe(u8, p.description),
            };
        }

        var resp_copy = try self.allocator.alloc(ApiResponse, ep.responses.len);
        for (ep.responses, 0..) |r, i| {
            resp_copy[i] = .{
                .status_code = r.status_code,
                .description = try self.allocator.dupe(u8, r.description),
                .schema_ref = if (r.schema_ref) |sr| try self.allocator.dupe(u8, sr) else null,
            };
        }

        return .{
            .method = ep.method,
            .path = path_copy,
            .summary = summary_copy,
            .description = desc_copy,
            .tags = tags_copy,
            .params = params_copy,
            .responses = resp_copy,
            .deprecated = ep.deprecated,
            .requires_auth = ep.requires_auth,
        };
    }

    fn cloneSchema(self: *Self, schema: ApiSchema) !ApiSchema {
        const name_copy = try self.allocator.dupe(u8, schema.name);
        const type_copy = try self.allocator.dupe(u8, schema.schema_type);
        const desc_copy = try self.allocator.dupe(u8, schema.description);

        var props_copy = try self.allocator.alloc(SchemaProperty, schema.properties.len);
        for (schema.properties, 0..) |p, i| {
            props_copy[i] = .{
                .name = try self.allocator.dupe(u8, p.name),
                .prop_type = try self.allocator.dupe(u8, p.prop_type),
                .description = try self.allocator.dupe(u8, p.description),
                .format = if (p.format) |f| try self.allocator.dupe(u8, f) else null,
                .nullable = p.nullable,
            };
        }

        var req_copy = try self.allocator.alloc([]const u8, schema.required_fields.len);
        for (schema.required_fields, 0..) |rf, i| {
            req_copy[i] = try self.allocator.dupe(u8, rf);
        }

        return .{
            .name = name_copy,
            .schema_type = type_copy,
            .description = desc_copy,
            .properties = props_copy,
            .required_fields = req_copy,
        };
    }
};

fn methodToString(method: HttpMethod) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .DELETE => "delete",
        .PATCH => "patch",
        .HEAD => "head",
        .OPTIONS => "options",
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "OpenApiGenerator basic" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "Test API", "1.0.0", "A test API");
    defer gen.deinit();

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/health",
        .summary = "Health check",
        .tags = &.{"system"},
        .responses = &.{
            .{ .status_code = 200, .description = "OK" },
            .{ .status_code = 500, .description = "Internal Server Error" },
        },
    });

    const json = try gen.generate();
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"openapi\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"paths\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "/health"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "Health check"));
}

test "OpenApiGenerator with params" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "API", "1.0.0", "desc");
    defer gen.deinit();

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/users/{id}",
        .summary = "Get user",
        .params = &.{
            .{ .name = "id", .location = .path, .param_type = "integer", .required = true, .description = "User ID" },
            .{ .name = "fields", .location = .query, .param_type = "string", .required = false, .description = "Fields to return" },
        },
        .responses = &.{
            .{ .status_code = 200, .description = "User object" },
        },
    });

    const json = try gen.generate();
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"name\": \"id\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "path"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "query"));
}

test "OpenApiGenerator tags" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "API", "1.0.0", "desc");
    defer gen.deinit();

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/users",
        .summary = "List users",
        .tags = &.{ "users", "public" },
        .responses = &.{.{ .status_code = 200, .description = "OK" }},
    });

    try gen.addEndpoint(.{
        .method = .POST,
        .path = "/orders",
        .summary = "Create order",
        .tags = &.{"orders"},
        .responses = &.{.{ .status_code = 201, .description = "Created" }},
    });

    const json = try gen.generate();
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"tags\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "users"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "orders"));
}

test "OpenApiGenerator OpenAPI 3.1" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "API", "1.0.0", "desc");
    gen.api_version = .v3_1;
    defer gen.deinit();

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/ping",
        .summary = "Ping",
        .responses = &.{.{ .status_code = 200, .description = "pong" }},
    });

    const json = try gen.generate();
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "3.1.0"));
}

test "OpenApiGenerator bearer_auth emits securitySchemes and per-op security" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "API", "1.0.0", "desc");
    defer gen.deinit();
    gen.bearer_auth = true;

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/api/me",
        .summary = "me",
        .requires_auth = true,
        .responses = &.{.{ .status_code = 200, .description = "OK" }},
    });
    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/health",
        .summary = "health",
        .responses = &.{.{ .status_code = 200, .description = "OK" }},
    });

    const json = try gen.generate();
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"securitySchemes\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"bearerAuth\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"bearerFormat\": \"JWT\""));
    // exactly one operation carries the security requirement
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"security\": [ { \"bearerAuth\": [] } ]"));
}

test "OpenApiGenerator without bearer_auth omits components" {
    const allocator = std.testing.allocator;
    var gen = OpenApiGenerator.init(allocator, "API", "1.0.0", "desc");
    defer gen.deinit();

    try gen.addEndpoint(.{
        .method = .GET,
        .path = "/api/me",
        .summary = "me",
        .requires_auth = true,
        .responses = &.{.{ .status_code = 200, .description = "OK" }},
    });

    const json = try gen.generate();
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "securitySchemes") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"security\"") == null);
}
