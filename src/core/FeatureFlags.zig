//! Feature flags with percentage rollout, allowlists, and compile-time evaluation.

const std = @import("std");
const Time = @import("../core/Time.zig");

/// One feature flag entry
pub const FeatureFlag = struct {
    /// Unique flag name
    key: []const u8,
    /// Whether the flag is enabled
    enabled: bool,
    /// Human-readable flag description
    description: []const u8,
    /// Creation time
    created_at: i64,
    /// Last modification time
    updated_at: i64,
    /// Rollout percentage (0-100, 0=fully CLOSED, 100=fully enabled)
    rollout_percent: u8 = 100,
    /// Whitelisted user/tenant ID values that always get the flag
    whitelist: []const []const u8 = &.{},
};

/// Feature flag manager
/// Runtime toggles that support percentage rollout and allowlist
///
/// Usage:
///   var flags = FeatureFlagManager.init(allocator);
///   try flags.set("new-checkout", true, "New checkout flow", 10); // 10% rollout
///   if (flags.isEnabled("new-checkout", "user-123")) { ... }
pub const FeatureFlagManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    flags: std.StringHashMap(FeatureFlag),
    /// Callbacks invoked after every successful set()
    change_listeners: std.ArrayList(*const fn ([]const u8, FeatureFlag) void),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .flags = std.StringHashMap(FeatureFlag).init(allocator),
            .change_listeners = std.ArrayList(*const fn ([]const u8, FeatureFlag) void).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.flags.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.description);
            for (entry.value_ptr.whitelist) |w| self.allocator.free(w);
            self.allocator.free(entry.value_ptr.whitelist);
        }
        self.flags.deinit();
        self.change_listeners.deinit(self.allocator);
        self.* = undefined;
    }

    /// Creates or replaces a flag, then notifies the change listeners
    pub fn set(self: *Self, key: []const u8, enabled: bool, description: []const u8, rollout_percent: u8) !void {
        const now = Time.monotonicNowSeconds();

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const updated_at = if (self.flags.get(key)) |existing| existing.created_at else now;

        const flag = FeatureFlag{
            .key = key_copy,
            .enabled = enabled,
            .description = desc_copy,
            .created_at = updated_at,
            .updated_at = now,
            .rollout_percent = @min(rollout_percent, 100),
        };

        try self.flags.put(key_copy, flag);

        // Notify the change listeners
        for (self.change_listeners.items) |listener| {
            listener(key_copy, flag);
        }
    }

    /// Sets the whitelist used for gradual rollout publish
    pub fn setWhitelist(self: *Self, key: []const u8, whitelist: []const []const u8) !void {
        const flag = self.flags.getPtr(key) orelse return error.FlagNotFound;

        // Free the previously stored whitelist
        for (flag.whitelist) |w| self.allocator.free(w);
        self.allocator.free(flag.whitelist);

        // Copy the new whitelist into owned memory
        var new_whitelist = try self.allocator.alloc([]const u8, whitelist.len);
        for (whitelist, 0..) |entry, i| {
            new_whitelist[i] = try self.allocator.dupe(u8, entry);
        }
        flag.whitelist = new_whitelist;
    }

    /// Check if flag is enabled for specific user
    /// Considers global enabled + rollout_percent + whitelist
    pub fn isEnabled(self: *Self, key: []const u8, user_id: ?[]const u8) bool {
        const flag = self.flags.get(key) orelse return false;

        // Globally CLOSED
        if (!flag.enabled) return false;

        // Whitelist check (always wins, whatever the rollout percentage)
        if (user_id) |uid| {
            for (flag.whitelist) |w| {
                if (std.mem.eql(u8, w, uid)) return true;
            }
        }

        // 100% rollout
        if (flag.rollout_percent == 100) return true;

        // 0% rollout
        if (flag.rollout_percent == 0) return false;

        // Percentage rollout: decided by the hash of the user ID
        if (user_id) |uid| {
            const hash = hashString(uid);
            const bucket = @mod(hash, @as(u32, 100));
            return bucket < flag.rollout_percent;
        }

        return false;
    }

    /// Get flag pure enabled state (no rollout/whitelist check)
    pub fn isGloballyEnabled(self: *Self, key: []const u8) bool {
        const flag = self.flags.get(key) orelse return false;
        return flag.enabled;
    }

    /// Gets a flag by key
    pub fn get(self: *Self, key: []const u8) ?FeatureFlag {
        return self.flags.get(key);
    }

    /// Removes a flag and frees its owned memory; false if the key was absent
    pub fn remove(self: *Self, key: []const u8) bool {
        if (self.flags.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.description);
            for (removed.value.whitelist) |w| self.allocator.free(w);
            self.allocator.free(removed.value.whitelist);
            return true;
        }
        return false;
    }

    /// Lists the keys of all flags
    pub fn list(self: *Self) ![]const []const u8 {
        var keys = std.ArrayList([]const u8).empty;
        var iter = self.flags.keyIterator();
        while (iter.next()) |key| {
            try keys.append(self.allocator, key.*);
        }
        return keys.toOwnedSlice(self.allocator);
    }

    /// List all enabled flags
    pub fn listEnabled(self: *Self) ![]const []const u8 {
        var keys = std.ArrayList([]const u8).empty;
        var iter = self.flags.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.enabled) {
                try keys.append(self.allocator, entry.key_ptr.*);
            }
        }
        return keys.toOwnedSlice(self.allocator);
    }

    /// Registers a listener called on every flag change
    pub fn onChange(self: *Self, listener: *const fn ([]const u8, FeatureFlag) void) !void {
        try self.change_listeners.append(self.allocator, listener);
    }

    /// Total number of flags
    pub fn count(self: *Self) usize {
        return self.flags.count();
    }

    /// Batch loads feature flags from JSON Content
    pub fn loadFromJsonContent(self: *Self, content: []const u8) !void {
        // Format: {"flag_name": true, "flag2": false}
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '{' or content[i] == '}' or content[i] == ',')) : (i += 1) {}
            if (i >= content.len or content[i] != '"') break;

            i += 1;
            const key_start = i;
            while (i < content.len and content[i] != '"') : (i += 1) {}
            const key = content[key_start..i];
            i += 1;

            while (i < content.len and (content[i] == ':' or content[i] == ' ')) : (i += 1) {}

            var enabled = false;
            if (std.mem.startsWith(u8, content[i..], "true")) {
                enabled = true;
                i += 4;
            } else if (std.mem.startsWith(u8, content[i..], "false")) {
                i += 5;
            }

            try self.set(key, enabled, key, 100);
        }
    }
};

/// Simple string hash (for rollout bucketing)
fn hashString(s: []const u8) u32 {
    var hash: u32 = 5381;
    for (s) |c| {
        hash = ((hash << 5) +% hash) +% @as(u32, c);
    }
    return hash;
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "FeatureFlagManager basic" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    try ffs.set("new-ui", true, "New UI redesign", 100);
    try std.testing.expect(ffs.isEnabled("new-ui", "user-1"));

    try ffs.set("beta-feature", false, "Beta feature", 100);
    try std.testing.expect(!ffs.isEnabled("beta-feature", "user-1"));
}

test "FeatureFlagManager rollout percentage" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    try ffs.set("canary", true, "Canary deployment", 50);

    // Count how many of 100 users get the flag
    var enabled_count: usize = 0;
    for (0..100) |i| {
        const user_id = try std.fmt.allocPrint(allocator, "user-{d}", .{i});
        defer allocator.free(user_id);
        if (ffs.isEnabled("canary", user_id)) enabled_count += 1;
    }

    // Expect roughly 50% of users to be enabled
    try std.testing.expect(enabled_count > 20 and enabled_count < 80);
}

test "FeatureFlagManager whitelist" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    try ffs.set("premium", true, "Premium feature", 0); // 0% rollout — allowlist only

    try ffs.setWhitelist("premium", &.{ "vip-user", "admin" });

    try std.testing.expect(ffs.isEnabled("premium", "vip-user"));
    try std.testing.expect(ffs.isEnabled("premium", "admin"));
    try std.testing.expect(!ffs.isEnabled("premium", "normal-user"));
}

test "FeatureFlagManager list" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    try ffs.set("flag-a", true, "A", 100);
    try ffs.set("flag-b", false, "B", 100);
    try ffs.set("flag-c", true, "C", 50);

    const all = try ffs.list();
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const enabled = try ffs.listEnabled();
    defer allocator.free(enabled);
    try std.testing.expectEqual(@as(usize, 2), enabled.len);
}

test "FeatureFlagManager remove" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    try ffs.set("temp", true, "Temporary flag", 100);
    try std.testing.expectEqual(@as(usize, 1), ffs.count());

    try std.testing.expect(ffs.remove("temp"));
    try std.testing.expectEqual(@as(usize, 0), ffs.count());
    try std.testing.expect(!ffs.isEnabled("temp", "user-1"));
}

test "FeatureFlagManager load from JSON" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    const content = "{\"dark-mode\": true, \"beta-api\": false}";
    try ffs.loadFromJsonContent(content);

    try std.testing.expect(ffs.isEnabled("dark-mode", null));
    try std.testing.expect(!ffs.isEnabled("beta-api", null));
    try std.testing.expectEqual(@as(usize, 2), ffs.count());
}

test "FeatureFlagManager onChange" {
    const allocator = std.testing.allocator;
    var ffs = FeatureFlagManager.init(allocator);
    defer ffs.deinit();

    var change_count: usize = 0;
    const listener = struct {
        var counter: *usize = undefined;
        fn cb(key: []const u8, _: FeatureFlag) void {
            _ = key;
            counter.* += 1;
        }
    };
    listener.counter = &change_count;

    try ffs.onChange(listener.cb);
    try ffs.set("test", true, "Test", 100);
    try std.testing.expectEqual(@as(usize, 1), change_count);
}
