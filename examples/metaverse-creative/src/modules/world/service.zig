const persist = @import("persistence.zig");
const model = @import("model.zig");
const identity = @import("../identity/service.zig");

pub const WorldService = struct {
    store: *persist.WorldStore,
    identity: ?*identity.IdentityService = null,

    pub fn init(store: *persist.WorldStore) WorldService {
        return .{ .store = store };
    }

    pub fn withIdentity(self: *WorldService, id_svc: *identity.IdentityService) void {
        self.identity = id_svc;
    }

    pub fn create(self: *WorldService, owner_did: []const u8, name: []const u8, symbol: []const u8, entry_fee: i64) !i64 {
        if (owner_did.len == 0) return error.InvalidOwner;
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        if (symbol.len == 0 or symbol.len > 10) return error.InvalidSymbol;
        if (entry_fee < 0) return error.InvalidFee;
        if (self.identity) |ids| {
            if (try ids.getCreator(owner_did)) |c| {
                ids.freeCreator(c);
            } else {
                return error.OwnerNotFound;
            }
        }
        return try self.store.create(owner_did, name, symbol, entry_fee);
    }

    pub fn feature(self: *WorldService, world_id: i64, creative_id: i64) !void {
        if (world_id <= 0 or creative_id <= 0) return error.InvalidInput;
        try self.store.featureCreative(world_id, creative_id);
    }

    pub fn get(self: *WorldService, id: i64) !?model.WorldDto {
        return try self.store.get(id);
    }

    pub fn free(self: *WorldService, w: model.WorldDto) void {
        self.store.free(w);
    }

    /// Visit by visitor DID — looks up reputation like legacy WorldModule.visitWorld.
    pub fn visitWorld(self: *WorldService, world_id: i64, visitor_did: []const u8) !i64 {
        var reputation: i64 = 0;
        if (self.identity) |ids| {
            const visitor = (try ids.getCreator(visitor_did)) orelse return error.VisitorNotFound;
            defer ids.freeCreator(visitor);
            reputation = visitor.reputation;
        }
        return try self.store.visit(world_id, reputation);
    }
};
