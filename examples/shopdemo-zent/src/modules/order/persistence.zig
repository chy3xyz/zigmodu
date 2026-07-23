//! Persistence over zent Client — all SQL stays inside zent builders.
//!
//! Two schemas (`Order`, `OrderItem`) registered in a single graph. The
//! store exposes CRUD methods on `Order` and an `addItem` helper on
//! `OrderItem`; results are duped into `OrderRow` DTOs so the zent
//! entity lifecycle never leaks past the persistence boundary.
const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.Order, model.OrderItem });
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);
pub const OrderInfo = infos[0];
pub const OrderItemInfo = infos[1];

pub const OrderStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, driver: zent.sql_driver.Driver) OrderStore {
        return .{
            .allocator = allocator,
            .client = zent.codegen.client.makeClient(infos, allocator, driver),
        };
    }

    pub fn createOrder(
        self: *OrderStore,
        order_no: []const u8,
        status: []const u8,
        amount_cents: i64,
        user_id: i64,
    ) !i64 {
        var b = try self.client.order.Create();
        defer b.deinit();
        _ = try b.setFieldValue("order_no", order_no);
        _ = try b.setFieldValue("status", status);
        _ = try b.setFieldValue("amount_cents", amount_cents);
        _ = try b.setFieldValue("user_id", user_id);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, OrderInfo, &row, self.allocator);
        return row.id;
    }

    pub const OrderRow = struct {
        id: i64,
        order_no: []const u8,
        status: []const u8,
        amount_cents: i64,
        user_id: i64,

        /// Free the owned strings. Callers must call this once per row.
        pub fn free(self: OrderRow, allocator: std.mem.Allocator) void {
            allocator.free(self.order_no);
            allocator.free(self.status);
        }
    };

    /// Caller owns the returned slice and each row's strings. Free with
    /// `freeOrders`.
    pub fn listOrders(self: *OrderStore) ![]OrderRow {
        var q = self.client.order.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*o| {
                zent.codegen.deinitEntity(infos, OrderInfo, o, self.allocator);
            }
            found.deinit();
        }

        var out = try self.allocator.alloc(OrderRow, found.items.len);
        errdefer self.allocator.free(out);
        for (found.items, 0..) |o, i| {
            out[i] = .{
                .id = o.id,
                .order_no = try self.allocator.dupe(u8, o.order_no),
                .status = try self.allocator.dupe(u8, o.status),
                .amount_cents = o.amount_cents,
                .user_id = o.user_id,
            };
        }
        return out;
    }

    pub fn freeOrders(self: *OrderStore, rows: []OrderRow) void {
        for (rows) |r| r.free(self.allocator);
        self.allocator.free(rows);
    }

    /// Look up a single order by its `order_no` (business key). Returns
    /// `null` if not found.
    pub fn getOrder(self: *OrderStore, order_no: []const u8) !?OrderRow {
        var q = self.client.order.Query();
        defer q.deinit();
        const preds = self.client.order.predicates;
        _ = try q.Where(.{preds.order_noEQ(.{ .string = order_no })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        errdefer zent.codegen.deinitEntity(infos, OrderInfo, &entity, self.allocator);

        const order_no_dup = try self.allocator.dupe(u8, entity.order_no);
        errdefer self.allocator.free(order_no_dup);
        const status_dup = try self.allocator.dupe(u8, entity.status);

        zent.codegen.deinitEntity(infos, OrderInfo, &entity, self.allocator);
        return OrderRow{
            .id = entity.id,
            .order_no = order_no_dup,
            .status = status_dup,
            .amount_cents = entity.amount_cents,
            .user_id = entity.user_id,
        };
    }

    /// Append a line item to an order. Returns the new item id.
    pub fn addItem(
        self: *OrderStore,
        order_no: []const u8,
        sku: []const u8,
        qty: i64,
        unit_price_cents: i64,
    ) !i64 {
        var b = try self.client.order_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("order_no", order_no);
        _ = try b.setFieldValue("sku", sku);
        _ = try b.setFieldValue("qty", qty);
        _ = try b.setFieldValue("unit_price_cents", unit_price_cents);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, OrderItemInfo, &row, self.allocator);
        return row.id;
    }
};
