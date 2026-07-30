const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");
const enums = @import("../../business/enums.zig");
const payment_persist = @import("persistence.zig");
const order_persist = @import("../order/persistence.zig");
const inventory_persist = @import("../inventory/persistence.zig");
const outbox_write = @import("../../foundation/outbox_write.zig");

pub const ChargeCmd = struct {
    tenant_id: i64,
    order_id: i64,
    idempotency_key: []const u8,
    success: bool,
};

/// Payment service — charge is idempotent; orchestrates Tx helpers.
pub const PaymentService = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    db: *data.Client,
    store: payment_persist.PaymentPersistence(*data.Client),

    pub fn init(allocator: std.mem.Allocator, db: *data.Client) Self {
        return .{
            .allocator = allocator,
            .db = db,
            .store = payment_persist.PaymentPersistence(*data.Client).init(db),
        };
    }

    pub fn listByOrder(self: *Self, tenant_id: i64, order_id: i64) !data.sqlx.QueryResult(model.Payment) {
        return try self.store.listByOrder(tenant_id, order_id);
    }

    pub fn charge(self: *Self, cmd: ChargeCmd) !model.Payment {
        if (cmd.idempotency_key.len == 0) return error.InvalidInput;

        if (try self.store.findByKey(cmd.idempotency_key)) |existing| {
            return existing;
        }

        var tx = try self.db.beginTx();
        errdefer tx.rollback() catch |err| std.log.err("[payment] rollback failed: {}", .{err});

        if (try payment_persist.Tx.findByKey(&tx, self.allocator, cmd.idempotency_key)) |existing| {
            try tx.rollback();
            return existing;
        }

        const order = order_persist.Tx.get(&tx, self.allocator, cmd.tenant_id, cmd.order_id) catch
            return error.NotFound;
        defer self.allocator.free(order.status);

        if (!std.mem.eql(u8, order.status, enums.OrderStatus.pending.toString())) {
            return error.InvalidInput;
        }

        var items_qr = try order_persist.Tx.listItems(&tx, self.allocator, cmd.tenant_id, cmd.order_id);
        defer items_qr.deinit(self.allocator);
        const items = items_qr.items;

        const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
        const pay_status = if (cmd.success)
            enums.PaymentStatus.succeeded.toString()
        else
            enums.PaymentStatus.failed.toString();
        const order_status = if (cmd.success)
            enums.OrderStatus.paid.toString()
        else
            enums.OrderStatus.cancelled.toString();
        const topic = if (cmd.success) "payment.succeeded" else "payment.failed";

        const payment_id = payment_persist.Tx.insert(
            &tx,
            cmd.tenant_id,
            cmd.order_id,
            cmd.idempotency_key,
            pay_status,
            order.total_cents,
            now,
        ) catch |err| switch (err) {
            error.ConstraintViolation => {
                try tx.rollback();
                return (try self.store.findByKey(cmd.idempotency_key)) orelse return error.ConstraintViolation;
            },
            else => return err,
        };

        try order_persist.Tx.updateStatusIf(
            &tx,
            cmd.tenant_id,
            cmd.order_id,
            enums.OrderStatus.pending.toString(),
            order_status,
            now,
        );

        for (items) |it| {
            if (cmd.success) {
                try inventory_persist.Tx.commitSale(&tx, cmd.tenant_id, it.product_id, it.qty, now);
            } else {
                try inventory_persist.Tx.release(&tx, cmd.tenant_id, it.product_id, it.qty, now);
            }
        }

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"payment_id":{d},"order_id":{d},"tenant_id":{d},"amount_cents":{d},"status":"{s}"}}
        , .{ payment_id, cmd.order_id, cmd.tenant_id, order.total_cents, pay_status });
        defer self.allocator.free(payload);
        try outbox_write.insertPending(&tx, cmd.tenant_id, topic, payload, now);

        try tx.commit();

        const key_owned = try self.allocator.dupe(u8, cmd.idempotency_key);
        errdefer self.allocator.free(key_owned);
        const status_owned = try self.allocator.dupe(u8, pay_status);
        return .{
            .id = payment_id,
            .tenant_id = cmd.tenant_id,
            .order_id = cmd.order_id,
            .idempotency_key = key_owned,
            .status = status_owned,
            .amount_cents = order.total_cents,
            .created_at = now,
        };
    }
};
