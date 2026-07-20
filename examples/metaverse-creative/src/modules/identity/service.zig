const persist = @import("persistence.zig");
const model = @import("model.zig");

/// DID-centric API — mirrors legacy IdentityModule surface.
pub const IdentityService = struct {
    store: *persist.IdentityStore,

    pub fn init(store: *persist.IdentityStore) IdentityService {
        return .{ .store = store };
    }

    pub fn registerCreator(self: *IdentityService, did: []const u8, name: []const u8, wallet: []const u8) !void {
        if (did.len == 0 or did.len > 256) return error.InvalidDID;
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        if (wallet.len == 0 or wallet.len > 256) return error.InvalidWallet;
        try self.store.register(did, name, wallet);
    }

    pub fn getCreator(self: *IdentityService, did: []const u8) !?model.CreatorDto {
        return try self.store.findByDid(did);
    }

    pub fn freeCreator(self: *IdentityService, c: model.CreatorDto) void {
        self.store.freeCreator(c);
    }

    pub fn updateReputation(self: *IdentityService, did: []const u8, delta: i64) !void {
        if (did.len == 0) return error.InvalidDID;
        try self.store.updateReputation(did, delta);
    }

    pub fn verifyCreator(self: *IdentityService, did: []const u8) !void {
        if (did.len == 0) return error.InvalidDID;
        try self.store.verify(did);
    }
};
