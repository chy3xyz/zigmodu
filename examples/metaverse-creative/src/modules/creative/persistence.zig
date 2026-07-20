const std = @import("std");
const zent = @import("zent");
const schema = @import("../../schema.zig");
const model = @import("model.zig");

pub const CreativeStore = struct {
    db: *schema.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, client: *schema.Client) CreativeStore {
        return .{ .db = client, .allocator = allocator };
    }

    pub fn createDraft(self: *CreativeStore, d: model.CreativeDraft) !i64 {
        var b = try self.db.creative.Create();
        defer b.deinit();
        _ = try b.setFieldValue("owner_did", d.owner_did);
        _ = try b.setFieldValue("title", d.title);
        _ = try b.setFieldValue("slug", d.slug);
        _ = try b.setFieldValue("problem", d.problem);
        _ = try b.setFieldValue("solution", d.solution);
        _ = try b.setFieldValue("world", d.world);
        _ = try b.setFieldValue("status", "draft");
        _ = try b.setFieldValue("price_cents", d.price_cents);
        _ = try b.setFieldValue("royalty_bps", @as(i64, 1000));
        var row = try b.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.CreativeInfo, &row, self.allocator);
        return row.id;
    }

    pub fn publish(self: *CreativeStore, id: i64, price_cents: i64) !void {
        const preds = self.db.creative.predicates;
        var u = self.db.creative.Update();
        defer u.deinit();
        _ = try u.set("status", .{ .string = "published" });
        _ = try u.setFieldValue("price_cents", price_cents);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    pub fn get(self: *CreativeStore, id: i64) !?model.CreativeDto {
        var q = self.db.creative.Query();
        defer q.deinit();
        const preds = self.db.creative.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        var found = try q.All();
        defer {
            for (found.items) |*c| {
                zent.codegen.deinitEntity(schema.infos, schema.CreativeInfo, c, self.allocator);
            }
            found.deinit();
        }
        if (found.items.len == 0) return null;
        return try dupeDto(self.allocator, found.items[0]);
    }

    pub fn listPublished(self: *CreativeStore) ![]model.CreativeDto {
        var q = self.db.creative.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*c| {
                zent.codegen.deinitEntity(schema.infos, schema.CreativeInfo, c, self.allocator);
            }
            found.deinit();
        }
        var list = std.ArrayList(model.CreativeDto).empty;
        errdefer {
            for (list.items) |d| freeDtoFields(self.allocator, d);
            list.deinit(self.allocator);
        }
        for (found.items) |c| {
            if (!std.mem.eql(u8, c.status, "published")) continue;
            try list.append(self.allocator, try dupeDto(self.allocator, c));
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn freeDto(self: *CreativeStore, d: model.CreativeDto) void {
        freeDtoFields(self.allocator, d);
    }

    pub fn freeList(self: *CreativeStore, rows: []model.CreativeDto) void {
        for (rows) |d| freeDtoFields(self.allocator, d);
        self.allocator.free(rows);
    }
};

fn dupeDto(allocator: std.mem.Allocator, c: anytype) !model.CreativeDto {
    return .{
        .id = c.id,
        .owner_did = try allocator.dupe(u8, c.owner_did),
        .title = try allocator.dupe(u8, c.title),
        .slug = try allocator.dupe(u8, c.slug),
        .status = try allocator.dupe(u8, c.status),
        .price_cents = c.price_cents,
        .problem = try allocator.dupe(u8, c.problem),
        .solution = try allocator.dupe(u8, c.solution),
        .world = try allocator.dupe(u8, c.world),
    };
}

fn freeDtoFields(allocator: std.mem.Allocator, d: model.CreativeDto) void {
    allocator.free(d.owner_did);
    allocator.free(d.title);
    allocator.free(d.slug);
    allocator.free(d.status);
    allocator.free(d.problem);
    allocator.free(d.solution);
    allocator.free(d.world);
}
