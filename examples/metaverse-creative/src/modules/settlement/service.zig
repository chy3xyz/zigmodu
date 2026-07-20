const model = @import("model.zig");
const persist = @import("persistence.zig");
const creative_persist = @import("../creative/persistence.zig");

pub const SettlementService = struct {
    store: *persist.SettlementStore,
    creatives: *creative_persist.CreativeStore,

    pub fn init(store: *persist.SettlementStore, creatives: *creative_persist.CreativeStore) SettlementService {
        return .{ .store = store, .creatives = creatives };
    }

    pub fn purchase(self: *SettlementService, cmd: model.PurchaseCmd) !model.PurchaseResult {
        if (cmd.idempotency_key.len == 0 or cmd.idempotency_key.len > 128) return error.InvalidIdempotencyKey;
        if (cmd.creative_id <= 0 or cmd.buyer_did.len == 0) return error.InvalidInput;
        return try self.store.purchase(self.creatives, cmd);
    }

    pub fn reconcile(self: *SettlementService) !model.ReconcileReport {
        return try self.store.reconcile();
    }

    pub fn drainOutbox(self: *SettlementService) !usize {
        return try self.store.drainOutbox();
    }
};
