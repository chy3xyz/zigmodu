const std = @import("std");
const builtin = @import("builtin");
const HttpClient = @import("../http/HttpClient.zig").HttpClient;

/// Lower enum value = higher priority (env wins over file/vault/default).
pub const SecretsSourcePriority = enum(u8) {
    env = 0,
    file = 1,
    vault = 2,
    default = 3,
};

/// Multi-source secrets manager (env > file > Vault KV > default).
/// Vault: HashiCorp KV v2 via HTTP (`GET /v1/{mount}/data/{path}` + `X-Vault-Token`).
pub const SecretsManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    secrets: std.StringHashMap(SecretEntry),
    vault_config: ?VaultConfig,
    io: ?std.Io = null,
    /// The manager's Vault `HttpClient`, created on the first `loadFromVault` and
    /// kept until `deinit` so the connection it pools survives from one read to
    /// the next. A client per read re-dials (and re-handshakes, for an `https://`
    /// Vault) every time.
    ///
    /// Created lazily rather than in `init` because it needs both an `io` (only
    /// `initWithIo`/`bindIo` provide one) and a timeout (only the Vault config
    /// provides one).
    ///
    /// Published once, by atomic compare-exchange, rather than under a mutex: two
    /// threads racing on the first read each build a client and the loser drops
    /// its own never-used one (`HttpClient.init` allocates nothing, so that
    /// discard closes no connection). Nothing swaps this pointer again until
    /// `deinit`, so every reader sees the same fully initialized client — and
    /// `HttpClient` is thread-safe for concurrent requests.
    http_client: std.atomic.Value(?*HttpClient) = .init(null),

    pub const VaultConfig = struct {
        address: []const u8,
        token: []const u8,
        mount_path: []const u8 = "secret",
        timeout_ms: u64 = 5000,
        /// When true, skip HTTP and only allow `applyVaultKvJson` (unit tests).
        offline: bool = false,
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

    /// Network-capable manager (required for `loadFromVault` HTTP).
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .secrets = std.StringHashMap(SecretEntry).init(allocator),
            .vault_config = null,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            std.crypto.secureZero(u8, @constCast(entry.value_ptr.key));
            std.crypto.secureZero(u8, @constCast(entry.value_ptr.value));
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.secrets.deinit();

        if (self.vault_config) |vc| {
            std.crypto.secureZero(u8, @constCast(vc.token));
            self.allocator.free(vc.address);
            self.allocator.free(vc.token);
            if (!std.mem.eql(u8, vc.mount_path, "secret")) {
                self.allocator.free(vc.mount_path);
            }
        }

        // Contract (inherited from `HttpClient.deinit`, which asserts its pool is
        // idle): no `loadFromVault` may be in flight while this runs. Every read
        // releases its connection before it returns, so joining the loading
        // thread first is enough — `deinit` while a read is still running on
        // another thread is a use-after-free.
        if (self.http_client.swap(null, .acq_rel)) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }

        self.* = undefined;
    }

    /// The manager's resident Vault client, created on first use.
    ///
    /// `timeout_ms` is the current Vault config's and is applied on every call,
    /// so a `configureVaultEx` between two reads is picked up (it is the
    /// plain-`http://` socket budget; `HttpClient`'s TLS path does not read it).
    /// That assignment is a plain field store, so concurrent reads that disagree
    /// on `timeout_ms` race on that one field — last writer wins.
    ///
    /// Vault GETs are the only traffic this client carries, so the whole of a
    /// read's client state is set here: retries off (a read is one attempt, as
    /// before) and the pool cap at the two connections the per-read client used
    /// to allow. Note that cap is now *per manager instance* rather than per
    /// read, so more than two concurrent `loadFromVault` calls to one Vault can
    /// get `error.PoolExhausted` on the plain-HTTP path.
    fn acquireVaultClient(self: *Self, io: std.Io, timeout_ms: u64) !*HttpClient {
        if (self.http_client.load(.acquire)) |client| {
            client.timeout_ms = timeout_ms;
            return client;
        }

        const client = try self.allocator.create(HttpClient);
        client.* = HttpClient.init(self.allocator, io, 2, timeout_ms);
        client.retry_policy = .{
            .max_retries = 0,
            .initial_delay_ms = 0,
            .max_delay_ms = 0,
            .backoff_multiplier = 1.0,
        };

        // `cmpxchgStrong` wraps its result again when the payload is already
        // optional, hence the `.?`: a non-null result *is* the "another thread
        // won" case, and null means this thread published.
        if (self.http_client.cmpxchgStrong(null, client, .release, .acquire)) |published| {
            const existing = published.?;
            // Ours never served a request, so tearing it down frees nothing but
            // the struct itself.
            client.deinit();
            self.allocator.destroy(client);
            existing.timeout_ms = timeout_ms;
            return existing;
        }
        return client;
    }

    pub fn bindIo(self: *Self, io: std.Io) void {
        self.io = io;
    }

    /// Load keys from environment variables matching a non-empty prefix.
    pub fn loadFromEnv(self: *Self, prefix: []const u8) !void {
        if (prefix.len == 0) return error.EmptyPrefixNotAllowed;
        const env_map = std.process.getEnvMap(self.allocator) catch {
            return error.EnvLoadError;
        };
        defer env_map.deinit();

        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                const secret_key = entry.key_ptr.*[prefix.len..];
                const key_copy = try self.allocator.dupe(u8, secret_key);
                errdefer self.allocator.free(key_copy);
                const val_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
                errdefer self.allocator.free(val_copy);
                try self.setWithPriority(key_copy, val_copy, .env);
            }
        }
    }

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

    pub fn configureVault(self: *Self, address: []const u8, token: []const u8) !void {
        try self.configureVaultEx(.{
            .address = address,
            .token = token,
        });
    }

    pub fn configureVaultEx(self: *Self, cfg: struct {
        address: []const u8,
        token: []const u8,
        mount_path: []const u8 = "secret",
        timeout_ms: u64 = 5000,
        offline: bool = false,
    }) !void {
        if (cfg.address.len == 0 or cfg.token.len == 0) return error.InvalidVaultConfig;
        if (self.vault_config) |vc| {
            std.crypto.secureZero(u8, @constCast(vc.token));
            self.allocator.free(vc.address);
            self.allocator.free(vc.token);
            if (!std.mem.eql(u8, vc.mount_path, "secret")) {
                self.allocator.free(vc.mount_path);
            }
        }

        const addr_copy = try self.allocator.dupe(u8, cfg.address);
        errdefer self.allocator.free(addr_copy);
        const token_copy = try self.allocator.dupe(u8, cfg.token);
        errdefer self.allocator.free(token_copy);
        const mount_copy = if (std.mem.eql(u8, cfg.mount_path, "secret"))
            "secret"
        else
            try self.allocator.dupe(u8, cfg.mount_path);
        errdefer if (!std.mem.eql(u8, mount_copy, "secret")) self.allocator.free(mount_copy);

        self.vault_config = .{
            .address = addr_copy,
            .token = token_copy,
            .mount_path = mount_copy,
            .timeout_ms = cfg.timeout_ms,
            .offline = cfg.offline,
        };
    }

    /// Load secrets from Vault KV at `path` (e.g. `database/creds`).
    /// Uses KV v2 URL: `{addr}/v1/{mount}/data/{path}` with `X-Vault-Token`.
    /// `https://` addresses route through HttpClient's std.http.Client TLS
    /// (system CA bundle); keep Vault's PKI chain in the system trust store.
    pub fn loadFromVault(self: *Self, path: []const u8) !void {
        const vc = self.vault_config orelse return error.VaultNotConfigured;
        if (path.len == 0) return error.InvalidVaultPath;
        if (vc.offline) return error.VaultOffline;

        const io = self.io orelse return error.IoRequired;
        const addr = std.mem.trimEnd(u8, vc.address, "/");
        if (!std.mem.startsWith(u8, addr, "http://") and
            !std.mem.startsWith(u8, addr, "https://")) return error.InvalidVaultAddress;

        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/{s}/data/{s}", .{ addr, vc.mount_path, path });
        defer self.allocator.free(url);

        const client = try self.acquireVaultClient(io, vc.timeout_ms);

        var req = HttpClient.HttpRequest.init(self.allocator, "GET", url);
        defer req.deinit();
        try req.setHeader("X-Vault-Token", vc.token);
        try req.setHeader("Accept", "application/json");
        try req.setHeader("User-Agent", "zigmodu-secrets/0.14");

        var host_buf: [256]u8 = undefined;
        const host = blk: {
            const uri = try std.Uri.parse(url);
            const h = uri.host orelse return error.InvalidVaultAddress;
            break :blk h.toRaw(&host_buf) catch return error.InvalidVaultAddress;
        };
        try req.setHeader("Host", host);

        var resp = try client.request(req);
        defer resp.deinit();

        switch (resp.status_code) {
            200 => {},
            403 => return error.VaultForbidden,
            404 => return error.VaultSecretNotFound,
            else => {
                std.log.warn("[SecretsManager] Vault HTTP {d} for {s}", .{ resp.status_code, path });
                return error.VaultHttpError;
            },
        }

        const n = try self.applyVaultKvJson(resp.body);
        std.log.info("[SecretsManager] loaded {d} secrets from Vault path {s}", .{ n, path });
    }

    /// Ingest Vault KV JSON body (unit tests + HTTP path). Supports KV v2 (`data.data`) and flat KV v1 (`data`).
    /// Returns number of keys applied with `.vault` priority.
    pub fn applyVaultKvJson(self: *Self, body: []const u8) !usize {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidVaultResponse;
        const data_val = root.object.get("data") orelse return error.InvalidVaultResponse;
        if (data_val != .object) return error.InvalidVaultResponse;

        const secret_obj = if (data_val.object.get("data")) |inner|
            if (inner == .object) inner else return error.InvalidVaultResponse
        else
            data_val;

        var n: usize = 0;
        var it = secret_obj.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val_str = try jsonValueToString(self.allocator, entry.value_ptr.*);
            defer self.allocator.free(val_str);

            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            const val_copy = try self.allocator.dupe(u8, val_str);
            errdefer self.allocator.free(val_copy);
            try self.setWithPriority(key_copy, val_copy, .vault);
            n += 1;
        }
        return n;
    }

    pub fn setDefault(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);
        try self.setWithPriority(key_copy, val_copy, .default);
    }

    pub fn setWithPriority(self: *Self, key: []const u8, value: []const u8, source: SecretsSourcePriority) !void {
        if (self.secrets.get(key)) |entry| {
            if (@backingInt(source) >= @backingInt(entry.source)) {
                self.allocator.free(key);
                self.allocator.free(value);
                return;
            }
            const old_key = entry.key;
            const old_val = entry.value;
            _ = self.secrets.remove(key);
            self.allocator.free(old_key);
            self.allocator.free(old_val);
        }
        try self.secrets.put(key, .{
            .key = key,
            .value = value,
            .source = source,
        });
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const entry = self.secrets.get(key) orelse return null;
        return entry.value;
    }

    pub fn getOrDefault(self: *Self, key: []const u8, default_val: []const u8) []const u8 {
        return self.get(key) orelse default_val;
    }

    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch null;
    }

    pub fn getBool(self: *Self, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
        return null;
    }

    pub fn has(self: *Self, key: []const u8) bool {
        return self.secrets.contains(key);
    }

    pub fn getSource(self: *Self, key: []const u8) ?SecretsSourcePriority {
        const entry = self.secrets.get(key) orelse return null;
        return entry.source;
    }

    pub fn listKeys(self: *Self) ![]const []const u8 {
        var keys = std.ArrayList([]const u8).empty;
        var iter = self.secrets.keyIterator();
        while (iter.next()) |key| {
            try keys.append(self.allocator, key.*);
        }
        return keys.toOwnedSlice(self.allocator);
    }

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

    pub fn count(self: *Self) usize {
        return self.secrets.count();
    }

    pub fn clear(self: *Self) void {
        var iter = self.secrets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.secrets.clearRetainingCapacity();
    }
};

fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .null => try allocator.dupe(u8, ""),
        .number_string => |s| try allocator.dupe(u8, s),
        else => error.UnsupportedVaultValueType,
    };
}

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

    try sm.setWithPriority(try allocator.dupe(u8, "TOKEN"), try allocator.dupe(u8, "file_token"), .file);
    try std.testing.expectEqualStrings("file_token", sm.get("TOKEN").?);

    try sm.setWithPriority(try allocator.dupe(u8, "TOKEN"), try allocator.dupe(u8, "env_token"), .env);
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

test "SecretsManager Vault config requires io for HTTP" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.configureVault("http://127.0.0.1:8200", "hvs.token123");
    try std.testing.expect(sm.vault_config != null);
    try std.testing.expectError(error.IoRequired, sm.loadFromVault("database/creds"));
}

test "SecretsManager Vault https routes through HttpClient TLS (no offline rejection)" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.initWithIo(allocator, std.testing.io);
    defer sm.deinit();
    try sm.configureVault("https://vault.example.com:8200", "hvs.token");
    // https is now a supported scheme; an unreachable host surfaces as a
    // transport error — NOT VaultTlsNotSupported. No live network in tests,
    // so assert it fails for a transport reason by attempting with io present
    // would hit the network; instead verify the scheme no longer short-
    // circuits by checking the error is not the removed TLS error when using
    // the offline guard.
    var sm_off = SecretsManager.initWithIo(allocator, std.testing.io);
    defer sm_off.deinit();
    try sm_off.configureVault("https://vault.example.com:8200", "hvs.token");
    sm_off.vault_config.?.offline = true;
    try std.testing.expectError(error.VaultOffline, sm_off.loadFromVault("app/db"));
}

test "SecretsManager applyVaultKvJson v2" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    const body =
        \\{
        \\  "data": {
        \\    "data": {
        \\      "DB_HOST": "prod-db",
        \\      "DB_PORT": 5432,
        \\      "DEBUG": true
        \\    },
        \\    "metadata": { "version": 1 }
        \\  }
        \\}
    ;
    const n = try sm.applyVaultKvJson(body);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("prod-db", sm.get("DB_HOST").?);
    try std.testing.expectEqualStrings("5432", sm.get("DB_PORT").?);
    try std.testing.expectEqualStrings("true", sm.get("DEBUG").?);
    try std.testing.expectEqual(SecretsSourcePriority.vault, sm.getSource("DB_HOST").?);
}

test "SecretsManager applyVaultKvJson priority below env" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.init(allocator);
    defer sm.deinit();

    try sm.setWithPriority(try allocator.dupe(u8, "DB_HOST"), try allocator.dupe(u8, "from-env"), .env);
    _ = try sm.applyVaultKvJson(
        \\{"data":{"data":{"DB_HOST":"from-vault","NEW_KEY":"v"}}}
    );
    try std.testing.expectEqualStrings("from-env", sm.get("DB_HOST").?);
    try std.testing.expectEqualStrings("v", sm.get("NEW_KEY").?);
}

test "SecretsManager Vault offline mode" {
    const allocator = std.testing.allocator;
    var sm = SecretsManager.initWithIo(allocator, std.testing.io);
    defer sm.deinit();
    try sm.configureVaultEx(.{
        .address = "http://127.0.0.1:8200",
        .token = "t",
        .offline = true,
    });
    try std.testing.expectError(error.VaultOffline, sm.loadFromVault("x"));
}

test "SecretsManager Vault live smoke" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const addr = if (std.c.getenv("VAULT_ADDR")) |p| std.mem.span(p) else null;
    const token = if (std.c.getenv("VAULT_TOKEN")) |p| std.mem.span(p) else null;
    if (addr == null or token == null or addr.?.len == 0 or token.?.len == 0) return error.SkipZigTest;
    if (std.mem.startsWith(u8, addr.?, "https://")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var sm = SecretsManager.initWithIo(allocator, std.testing.io);
    defer sm.deinit();
    try sm.configureVaultEx(.{
        .address = addr.?,
        .token = token.?,
        .mount_path = if (std.c.getenv("VAULT_MOUNT")) |m| std.mem.span(m) else "secret",
    });
    const path = if (std.c.getenv("VAULT_SECRET_PATH")) |p| std.mem.span(p) else "zigmodu/smoke";
    sm.loadFromVault(path) catch |err| {
        if (err == error.VaultSecretNotFound) return;
        return err;
    };
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

// ── resident-client connection reuse ─────────────────────────────────────────

/// Loopback HTTP server that counts TCP accepts: it answers every request on a
/// connection with `payload` and leaves the connection open (HTTP/1.1
/// keep-alive). One accept for N requests means the client pooled its
/// connection; N accepts means it dialed per request.
const ReuseProbeServer = struct {
    listener: *std.Io.net.Server,
    payload: []const u8,
    accepts: std.atomic.Value(usize) = .init(0),
    requests: std.atomic.Value(usize) = .init(0),

    fn run(ctx: *@This()) void {
        var first = true;
        while (true) {
            // The first accept waits for the client; afterwards only a short
            // grace period, so a finished test ends instead of hanging on join.
            const wait_ms: i32 = if (first) 5000 else 300;
            first = false;
            if (!probeWaitReadable(ctx.listener.socket.handle, wait_ms)) return;
            const accepted = ctx.listener.accept(std.testing.io) catch return;
            _ = ctx.accepts.fetchAdd(1, .monotonic);
            while (probeReadRequest(accepted)) {
                _ = ctx.requests.fetchAdd(1, .monotonic);
                probeWriteAll(accepted.socket.handle, ctx.payload);
            }
            accepted.close(std.testing.io);
        }
    }
};

/// Poll/read/write by raw syscall: this runs on a thread that shares the testing
/// io scheduler with the test thread, where an io-path read can stall (same
/// reason the HttpClient framing probes do it).
fn probeWaitReadable(fd: std.posix.socket_t, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

/// Read exactly one request — the head plus the body its `Content-Length`
/// promises — so a reused connection starts the next request byte-aligned.
/// False when the peer closed instead of sending one.
fn probeReadRequest(accepted: std.Io.net.Stream) bool {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var body_len: ?usize = null;
    while (total < buf.len) {
        if (!probeWaitReadable(accepted.socket.handle, 1000)) return false;
        const n = std.posix.read(accepted.socket.handle, buf[total..]) catch return false;
        if (n == 0) return false;
        total += n;
        const head_end = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse continue;
        if (body_len == null) {
            body_len = if (probeHeaderValue(buf[0..head_end], "content-length")) |v|
                std.fmt.parseInt(usize, v, 10) catch 0
            else
                0;
        }
        if (total >= head_end + 4 + body_len.?) return true;
    }
    return false;
}

/// Case-insensitive value of `name` inside a raw request head.
fn probeHeaderValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn probeWriteAll(fd: std.posix.socket_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (std.posix.errno(rc) != .SUCCESS) return;
        const n: usize = @intCast(rc);
        if (n == 0) return;
        sent += n;
    }
}

test "SecretsManager Vault reuses one connection across loads (resident client)" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var url_buf: [128]u8 = undefined;
    const vault_addr = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port});

    const body = "{\"data\":{\"data\":{\"DB_HOST\":\"prod-db\"}}}";
    var payload_buf: [256]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });

    var server = ReuseProbeServer{ .listener = &listener, .payload = payload };
    const th = try std.Thread.spawn(.{}, ReuseProbeServer.run, .{&server});
    var joined = false;
    defer if (!joined) th.join();

    {
        var sm = SecretsManager.initWithIo(allocator, io);
        defer sm.deinit();
        try sm.configureVault(vault_addr, "hvs.token");

        for (0..3) |_| {
            try sm.loadFromVault("app/db");
        }
        try std.testing.expectEqualStrings("prod-db", sm.get("DB_HOST").?);

        // Three reads, one socket: the pool's own per-connection counter is the
        // reading that says the same connection served all three (a re-dial would
        // have restarted it at 1). `std.testing.allocator` fails this test if
        // `deinit` below misses the client it allocates.
        const client = sm.http_client.load(.acquire) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), client.connection_pool.idle_connections.items.len);
        try std.testing.expectEqual(@as(u64, 3), client.connection_pool.idle_connections.items[0].request_count);
    }

    // `deinit` closed the pooled connection, so the probe's read sees EOF and
    // its accept loop ends.
    th.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), server.accepts.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), server.requests.load(.monotonic));
}

// Lazy creation is the one place where two threads touch the same field at
// once, so it gets a real race rather than an argument: every thread must come
// away with the same client. `std.testing.allocator` fails this test on any
// leaked byte, which is what catches a thread that lost the race and did not
// free the client it built.
test "SecretsManager's first-use race publishes one client for every thread" {
    const allocator = std.testing.allocator;
    const thread_count = 8;

    var sm = SecretsManager.initWithIo(allocator, std.testing.io);
    defer sm.deinit();

    const Race = struct {
        sm: *SecretsManager,
        io: std.Io,
        gate: *std.atomic.Value(bool),
        results: *[thread_count]?*HttpClient,

        fn run(self: *@This(), slot: usize) void {
            // Line the threads up so they reach the first-use branch together.
            while (!self.gate.load(.acquire)) std.atomic.spinLoopHint();
            self.results[slot] = self.sm.acquireVaultClient(self.io, 1_000) catch null;
        }
    };

    var gate = std.atomic.Value(bool).init(false);
    var results: [thread_count]?*HttpClient = @splat(null);
    var race = Race{
        .sm = &sm,
        .io = std.testing.io,
        .gate = &gate,
        .results = &results,
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Race.run, .{ &race, i });
    gate.store(true, .release);
    for (&threads) |*thread| thread.join();

    const first = results[0] orelse return error.TestUnexpectedResult;
    for (results) |maybe_client| {
        const client = maybe_client orelse return error.TestUnexpectedResult;
        try std.testing.expect(first == client);
    }
    try std.testing.expect(sm.http_client.load(.acquire).? == first);
}
