const std = @import("std");

/// 密钥来源优先级
pub const SecretsSourcePriority = enum(u8) {
    /// 环境变量 (最高优先级)
    env = 0,
    /// 文件 (如 Docker secrets / K8s secrets)
    file = 1,
    /// Vault 等远端密钥管理服务
    vault = 2,
    /// 默认值 (最低优先级)
    default = 3,
};

/// 密钥管理器
/// 支持多来源密钥加载，按优先级解析
/// 类似 HashiCorp Vault / Spring Cloud Config 的密钥管理
pub const SecretsManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    secrets: std.StringHashMap(SecretEntry),
    vault_config: ?VaultConfig,

    pub const VaultConfig = struct {
        address: []const u8,
        token: []const u8,
        mount_path: []const u8 = "secret",
        timeout_ms: u64 = 5000,
    };

    pub const SecretEntry = struct {
        key: []const u8,
        value: []const u8,
        source: SecretsSourcePriority,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .secrets = std.StringHashMap(SecretEntry).init(allocator),
            .vault_config = null,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.secrets.deinit();

        if (self.vault_config) |vc| {
            self.allocator.free(vc.address);
            self.allocator.free(vc.token);
            if (!std.mem.eql(u8, vc.mount_path, "secret")) {
                self.allocator.free(vc.mount_path);
            }
        }
    }

    /// 从环境变量加载密钥
    /// 前缀过滤: 只加载指定前缀的变量
    pub fn loadFromEnv(self: *Self, prefix: []const u8) !void {
        const env_map = std.process.getEnvMap(self.allocator) catch {
            return error.EnvLoadError;
        };
        defer env_map.deinit();

        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            if (prefix.len == 0 or std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                const secret_key = if (prefix.len > 0)
                    entry.key_ptr.*[prefix.len..]
                else
                    entry.key_ptr.*;

                const key_copy = try self.allocator.dupe(u8, secret_key);
                errdefer self.allocator.free(key_copy);

                const val_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
                errdefer self.allocator.free(val_copy);

                try self.setWithPriority(key_copy, val_copy, .env);
            }
        }
    }

    /// 从 key=value 格式的内容加载密钥 (用于 Docker secrets / K8s secrets)
    /// 配合 ConfigManager 或文件读取器使用
    pub fn loadFromEnvContent(self: *Self, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
                const key = trimmed[0..eq_idx];
                const value = trimmed[eq_idx + 1 ..];

                const key_copy = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(key_copy);

                const val_copy = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(val_copy);

                try self.setWithPriority(key_copy, val_copy, .file);
            }
        }
    }

    /// 从 JSON 内容加载密钥
    /// 配合 ConfigManager 或文件读取器使用
    pub fn loadFromJsonContent(self: *Self, content: []const u8) !void {
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t' or content[i] == '{' or content[i] == '}' or content[i] == ',')) : (i += 1) {}

            if (i >= content.len or content[i] != '"') break;

            i += 1;
            const key_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const key = content[key_start..i];
            i += 1;

            while (i < content.len and (content[i] == ':' or content[i] == ' ' or content[i] == '\t')) : (i += 1) {}

            if (i >= content.len or content[i] != '"') break;

            i += 1;
            const val_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const value = content[val_start..i];
            i += 1;

            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);

            const val_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(val_copy);

            try self.setWithPriority(key_copy, val_copy, .file);
        }
    }

    /// 配置 Vault 连接
    pub fn configureVault(self: *Self, address: []const u8, token: []const u8) !void {
        if (self.vault_config) |vc| {
            self.allocator.free(vc.address);
            self.allocator.free(vc.token);
        }

        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);

        const token_copy = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(token_copy);

        self.vault_config = .{
            .address = addr_copy,
            .token = token_copy,
        };
    }

    /// 从 Vault 加载密钥 (placeholder — 需要 HTTP 客户端集成)
    pub fn loadFromVault(self: *Self, path: []const u8) !void {
        if (self.vault_config == null) {
            return error.VaultNotConfigured;
        }

        std.log.info("[SecretsManager] Vault integration: would load secrets from {s}/v1/{s}/data/{s}", .{
            self.vault_config.?.address,
            self.vault_config.?.mount_path,
            path,
        });
    }

    /// 设置默认值 (最低优先级)
    pub fn setDefault(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);

        try self.setWithPriority(key_copy, val_copy, .default);
    }

    fn setWithPriority(self: *Self, key: []const u8, value: []const u8, source: SecretsSourcePriority) !void {
        const existing = self.secrets.get(key);
        if (existing) |entry| {
            if (@intFromEnum(source) >= @intFromEnum(entry.source)) {
                self.allocator.free(key);
                self.allocator.free(value);
                return;
            }
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }

        try self.secrets.put(key, .{
            .key = key,
            .value = value,
            .source = source,
        });
    }

    /// 获取密钥值
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const entry = self.secrets.get(key) orelse return null;
        return entry.value;
    }

    /// 获取密钥 (带默认值)
    pub fn getOrDefault(self: *Self, key: []const u8, default_val: []const u8) []const u8 {
        return self.get(key) orelse default_val;
    }

    /// 获取整数密钥
    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch null;
    }

    /// 获取布尔密钥
    pub fn getBool(self: *Self, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
        return null;
    }

    /// 检查密钥是否存在
    pub fn has(self: *Self, key: []const u8) bool {
        return self.secrets.contains(key);
    }

    /// 获取密钥来源
    pub fn getSource(self: *Self, key: []const u8) ?SecretsSourcePriority {
        const entry = self.secrets.get(key) orelse return null;
        return entry.source;
    }

    /// 获取所有密钥的键名列表
    pub fn listKeys(self: *Self) ![]const []const u8 {
        var keys = std.ArrayList([]const u8).empty;
        var iter = self.secrets.keyIterator();
        while (iter.next()) |key| {
            try keys.append(self.allocator, key.*);
        }
        return keys.toOwnedSlice(self.allocator);
    }

    /// 导出为环境变量格式字符串
    pub fn exportAsEnv(self: *Self) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            const line = try std.fmt.allocPrint(self.allocator, "{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.value });
            defer self.allocator.free(line);
            try buf.appendSlice(self.allocator, line);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// 密钥数量
    pub fn count(self: *Self) usize {
        return self.secrets.count();
    }

    /// 清除所有密钥
    pub fn clear(self: *Self) void {
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.secrets.clearRetainingCapacity();
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "SecretsManager init and get" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("DB_HOST", "localhost");
    try sm.setDefault("DB_PORT", "5432");

    try std.testing.expectEqualStrings("localhost", sm.get("DB_HOST").?);
    try std.testing.expectEqualStrings("5432", sm.get("DB_PORT").?);
    try std.testing.expect(sm.get("NONEXISTENT") == null);
}

test "SecretsManager priority" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("TOKEN", "default_token");
    try sm.setDefault("TOKEN", "another_default");
    try std.testing.expectEqualStrings("default_token", sm.get("TOKEN").?);

    try sm.setWithPriority(try allocator.dupe(u8, "TOKEN"),
        try allocator.dupe(u8, "file_token"), .file);
    try std.testing.expectEqualStrings("file_token", sm.get("TOKEN").?);

    try sm.setWithPriority(try allocator.dupe(u8, "TOKEN"),
        try allocator.dupe(u8, "env_token"), .env);
    try std.testing.expectEqualStrings("env_token", sm.get("TOKEN").?);
}

test "SecretsManager getInt and getBool" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("MAX_CONNS", "100");
    try sm.setDefault("DEBUG", "true");
    try sm.setDefault("ENABLED", "1");

    try std.testing.expectEqual(@as(i64, 100), sm.getInt("MAX_CONNS").?);
    try std.testing.expectEqual(true, sm.getBool("DEBUG").?);
    try std.testing.expectEqual(true, sm.getBool("ENABLED").?);
}

test "SecretsManager getOrDefault" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try std.testing.expectEqualStrings("fallback", sm.getOrDefault("MISSING", "fallback"));
    try sm.setDefault("EXISTS", "real_value");
    try std.testing.expectEqualStrings("real_value", sm.getOrDefault("EXISTS", "fallback"));
}

test "SecretsManager load from env content" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    const content =
        \\DB_HOST=prod-db.example.com
        \\DB_PORT=5432
        \\# This is a comment
        \\DB_PASS=s3cret
        \\
    ;

    try sm.loadFromEnvContent(content);

    try std.testing.expectEqualStrings("prod-db.example.com", sm.get("DB_HOST").?);
    try std.testing.expectEqualStrings("5432", sm.get("DB_PORT").?);
    try std.testing.expectEqualStrings("s3cret", sm.get("DB_PASS").?);
    try std.testing.expect(sm.get("# This is a comment") == null);
}

test "SecretsManager load from json content" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    const content = "{\"API_KEY\":\"sk-abc123\",\"API_URL\":\"https://api.example.com\"}";

    try sm.loadFromJsonContent(content);

    try std.testing.expectEqualStrings("sk-abc123", sm.get("API_KEY").?);
    try std.testing.expectEqualStrings("https://api.example.com", sm.get("API_URL").?);
}

test "SecretsManager Vault config" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.configureVault("https://vault.example.com:8200", "hvs.token123");
    try std.testing.expect(sm.vault_config != null);

    _ = sm.loadFromVault("database/creds") catch {};
}

test "SecretsManager export as env" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("KEY1", "val1");
    try sm.setDefault("KEY2", "val2");

    const env_output = try sm.exportAsEnv();
    defer allocator.free(env_output);

    try std.testing.expect(std.mem.containsAtLeast(u8, env_output, 1, "KEY1=val1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, env_output, 1, "KEY2=val2"));
}

test "SecretsManager listKeys" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("A", "1");
    try sm.setDefault("B", "2");

    const keys = try sm.listKeys();
    defer allocator.free(keys);

    try std.testing.expectEqual(@as(usize, 2), keys.len);
}

test "SecretsManager count and clear" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setDefault("A", "1");
    try sm.setDefault("B", "2");
    try std.testing.expectEqual(@as(usize, 2), sm.count());

    sm.clear();
    try std.testing.expectEqual(@as(usize, 0), sm.count());
    try std.testing.expect(sm.get("A") == null);
}
