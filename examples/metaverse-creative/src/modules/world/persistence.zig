const std = @import("std");
const zent = @import("zent");
const schema = @import("../../schema.zig");
const model = @import("model.zig");

pub const WorldStore = struct {
    db: *schema.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, client: *schema.Client) WorldStore {
        return .{ .db = client, .allocator = allocator };
    }

    pub fn create(self: *WorldStore, owner_did: []const u8, name: []const u8, symbol: []const u8, entry_fee: i64) !i64 {
        var b = try self.db.world.Create();
        defer b.deinit();
        _ = try b.setFieldValue("owner_did", owner_did);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("token_symbol", symbol);
        _ = try b.setFieldValue("entry_fee_cents", entry_fee);
        _ = try b.setFieldValue("visitor_count", @as(i64, 0));
        _ = try b.setFieldValue("revenue_cents", @as(i64, 0));
        _ = try b.setFieldValue("featured_creative_id", @as(i64, 0));
        var row = try b.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.WorldInfo, &row, self.allocator);
        return row.id;
    }

    pub fn featureCreative(self: *WorldStore, world_id: i64, creative_id: i64) !void {
        const preds = self.db.world.predicates;
        var u = self.db.world.Update();
        defer u.deinit();
        _ = try u.setFieldValue("featured_creative_id", creative_id);
        _ = try u.Where(.{preds.idEQ(.{ .int = world_id })});
        _ = try u.Save();
    }

    pub fn get(self: *WorldStore, id: i64) !?model.WorldDto {
        var q = self.db.world.Query();
        defer q.deinit();
        const preds = self.db.world.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        var found = try q.All();
        defer {
            for (found.items) |*w| {
                zent.codegen.deinitEntity(schema.infos, schema.WorldInfo, w, self.allocator);
            }
            found.deinit();
        }
        if (found.items.len == 0) return null;
        const w = found.items[0];
        return .{
            .id = w.id,
            .owner_did = try self.allocator.dupe(u8, w.owner_did),
            .name = try self.allocator.dupe(u8, w.name),
            .token_symbol = try self.allocator.dupe(u8, w.token_symbol),
            .entry_fee_cents = w.entry_fee_cents,
            .visitor_count = w.visitor_count,
            .revenue_cents = w.revenue_cents,
            .featured_creative_id = w.featured_creative_id,
        };
    }

    pub fn free(self: *WorldStore, w: model.WorldDto) void {
        self.allocator.free(w.owner_did);
        self.allocator.free(w.name);
        self.allocator.free(w.token_symbol);
    }

    /// Legacy fee rule: discount = min(reputation/1000, 50) percent off.
    pub fn visit(self: *WorldStore, world_id: i64, visitor_reputation: i64) !i64 {
        const w = (try self.get(world_id)) orelse return error.WorldNotFound;
        defer self.free(w);
        const discount: i64 = @min(@divTrunc(visitor_reputation, 1000), 50);
        const fee = @divTrunc(w.entry_fee_cents * (100 - discount), 100);

        const preds = self.db.world.predicates;
        var u = self.db.world.Update();
        defer u.deinit();
        _ = try u.setFieldValue("visitor_count", w.visitor_count + 1);
        _ = try u.setFieldValue("revenue_cents", w.revenue_cents + fee);
        _ = try u.Where(.{preds.idEQ(.{ .int = world_id })});
        _ = try u.Save();
        return fee;
    }
};
