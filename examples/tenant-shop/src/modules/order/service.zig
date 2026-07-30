const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");
const enums = @import("../../business/enums.zig");
const order_persist = @import("persistence.zig");
const cart_persist = @import("../cart/persistence.zig");
const product_persist = @import("../product/persistence.zig");
const inventory_persist = @import("../inventory/persistence.zig");
const outbox_write = @import("../../foundation/outbox_write.zig");

pub const CheckoutCmd = struct {
    tenant_id: i64,
    user_id: i64,
};

pub const CheckoutResult = struct {
    order_id: i64,
};

/// Order service — checkout orchestrates Tx helpers in one DB transaction.
pub const OrderService = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    db: *data.Client,
    store: order_persist.OrderPersistence(*data.Client),

    pub fn init(allocator: std.mem.Allocator, db: *data.Client) Self {
        return .{
            .allocator = allocator,
            .db = db,
            .store = order_persist.OrderPersistence(*data.Client).init(db),
        };
    }

    pub fn listByTenant(self: *Self, tenant_id: i64) !data.sqlx.QueryResult(model.Order) {
        return try self.store.listByTenant(tenant_id);
    }

    pub fn checkout(self: *Self, cmd: CheckoutCmd) !CheckoutResult {
        var tx = try self.db.beginTx();
        errdefer tx.rollback() catch |err| std.log.err("[order] rollback failed: {}", .{err});

        const cart = try cart_persist.Tx.findCart(&tx, self.allocator, cmd.tenant_id, cmd.user_id);
        var items_qr = try cart_persist.Tx.listItems(&tx, self.allocator, cmd.tenant_id, cart.id);
        defer items_qr.deinit(self.allocator);
        const items = items_qr.items;
        if (items.len == 0) return error.InvalidInput;

        var total: i64 = 0;
        const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());

        var priced = try self.allocator.alloc(struct { product_id: i64, qty: i64, price_cents: i64 }, items.len);
        defer self.allocator.free(priced);

        for (items, 0..) |it, i| {
            const price = product_persist.Tx.priceCents(&tx, self.allocator, cmd.tenant_id, it.product_id) catch
                return error.NotFound;

            const inv = inventory_persist.Tx.findByProduct(&tx, self.allocator, cmd.tenant_id, it.product_id) catch
                return error.InvalidInput;
            if (inv.qty - inv.reserved < it.qty) return error.ConstraintViolation;

            try inventory_persist.Tx.reserve(&tx, cmd.tenant_id, it.product_id, it.qty, now);

            priced[i] = .{ .product_id = it.product_id, .qty = it.qty, .price_cents = price };
            total += price * it.qty;
        }

        const order_id = try order_persist.Tx.insertOrder(
            &tx,
            cmd.tenant_id,
            cmd.user_id,
            enums.OrderStatus.pending.toString(),
            total,
            now,
        );

        for (priced) |p| {
            try order_persist.Tx.insertItem(&tx, cmd.tenant_id, order_id, p.product_id, p.qty, p.price_cents);
        }

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"order_id":{d},"tenant_id":{d},"user_id":{d},"total_cents":{d}}}
        , .{ order_id, cmd.tenant_id, cmd.user_id, total });
        defer self.allocator.free(payload);
        try outbox_write.insertPending(&tx, cmd.tenant_id, "order.created", payload, now);

        try cart_persist.Tx.clearItems(&tx, cmd.tenant_id, cart.id);
        try tx.commit();
        return .{ .order_id = order_id };
    }
};
