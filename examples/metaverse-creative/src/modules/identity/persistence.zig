const std = @import("std");
const zent = @import("zent");
const schema = @import("../../schema.zig");
const model = @import("model.zig");

/// DID remains the business key (legacy IdentityModule). zent row id is internal.
pub const IdentityStore = struct {
    db: *schema.Client,
    allocator: std.mem.Allocator,
    /// did -> zent id (avoids string-predicate / empty-table Query bugs)
    by_did: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, client: *schema.Client) IdentityStore {
        return .{
            .db = client,
            .allocator = allocator,
            .by_did = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *IdentityStore) void {
        var it = self.by_did.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.by_did.deinit();
    }

    pub fn register(self: *IdentityStore, did: []const u8, name: []const u8, wallet: []const u8) !void {
        if (self.by_did.contains(did)) return error.DuplicateDID;

        var b = try self.db.creator.Create();
        defer b.deinit();
        _ = try b.setFieldValue("did", did);
        _ = try b.setFieldValue("display_name", name);
        _ = try b.setFieldValue("wallet", wallet);
        _ = try b.setFieldValue("reputation", @as(i64, 0));
        _ = try b.setFieldValue("verified", false);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.CreatorInfo, &row, self.allocator);

        const key = try self.allocator.dupe(u8, did);
        errdefer self.allocator.free(key);
        try self.by_did.put(key, row.id);
    }

    pub fn findByDid(self: *IdentityStore, did: []const u8) !?model.CreatorDto {
        const id = self.by_did.get(did) orelse return null;
        return try self.loadById(id);
    }

    pub fn freeCreator(self: *IdentityStore, c: model.CreatorDto) void {
        self.allocator.free(c.did);
        self.allocator.free(c.display_name);
        self.allocator.free(c.wallet);
    }

    pub fn updateReputation(self: *IdentityStore, did: []const u8, delta: i64) !void {
        const cur = (try self.findByDid(did)) orelse return error.IdentityNotFound;
        defer self.freeCreator(cur);
        var score = cur.reputation + delta;
        if (score < 0) score = 0;
        if (score > 10000) score = 10000;

        const preds = self.db.creator.predicates;
        var u = self.db.creator.Update();
        defer u.deinit();
        _ = try u.setFieldValue("reputation", score);
        _ = try u.Where(.{preds.idEQ(.{ .int = cur.id })});
        _ = try u.Save();
    }

    pub fn verify(self: *IdentityStore, did: []const u8) !void {
        const cur = (try self.findByDid(did)) orelse return error.IdentityNotFound;
        defer self.freeCreator(cur);
        const preds = self.db.creator.predicates;
        var u = self.db.creator.Update();
        defer u.deinit();
        _ = try u.setFieldValue("verified", true);
        _ = try u.Where(.{preds.idEQ(.{ .int = cur.id })});
        _ = try u.Save();
    }

    fn loadById(self: *IdentityStore, id: i64) !?model.CreatorDto {
        var q = self.db.creator.Query();
        defer q.deinit();
        const preds = self.db.creator.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        var found = try q.All();
        defer {
            for (found.items) |*c| {
                zent.codegen.deinitEntity(schema.infos, schema.CreatorInfo, c, self.allocator);
            }
            found.deinit();
        }
        if (found.items.len == 0) return null;
        const c = found.items[0];
        return .{
            .id = c.id,
            .did = try self.allocator.dupe(u8, c.did),
            .display_name = try self.allocator.dupe(u8, c.display_name),
            .wallet = try self.allocator.dupe(u8, c.wallet),
            .reputation = c.reputation,
            .verified = c.verified,
        };
    }
};
