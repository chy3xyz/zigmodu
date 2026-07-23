//! Service layer for the order module — validates inputs, delegates to
//! the zent-backed `OrderStore`. No HTTP / SQL strings leak in here.
const std = @import("std");
const persist = @import("persistence.zig");

pub const OrderService = struct {
    store: *persist.OrderStore,

    pub fn init(store: *persist.OrderStore) OrderService {
        return .{ .store = store };
    }

    pub fn createOrder(
        self: *OrderService,
        order_no: []const u8,
        status: []const u8,
        amount_cents: i64,
        user_id: i64,
    ) !i64 {
        if (order_no.len == 0) return error.InvalidInput;
        if (status.len == 0) return error.InvalidInput;
        if (user_id <= 0) return error.InvalidInput;
        return try self.store.createOrder(order_no, status, amount_cents, user_id);
    }

    pub fn listOrders(self: *OrderService) ![]persist.OrderStore.OrderRow {
        return try self.store.listOrders();
    }

    pub fn freeOrders(self: *OrderService, rows: []persist.OrderStore.OrderRow) void {
        self.store.freeOrders(rows);
    }

    pub fn getOrder(self: *OrderService, order_no: []const u8) !?persist.OrderStore.OrderRow {
        if (order_no.len == 0) return error.InvalidInput;
        return try self.store.getOrder(order_no);
    }

    pub fn addItem(
        self: *OrderService,
        order_no: []const u8,
        sku: []const u8,
        qty: i64,
        unit_price_cents: i64,
    ) !i64 {
        if (order_no.len == 0 or sku.len == 0) return error.InvalidInput;
        if (qty <= 0) return error.InvalidInput;
        if (unit_price_cents < 0) return error.InvalidInput;
        return try self.store.addItem(order_no, sku, qty, unit_price_cents);
    }
};
