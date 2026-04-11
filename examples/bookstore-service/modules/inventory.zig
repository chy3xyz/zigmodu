const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Inventory Module - 库存管理模块
/// 提供库存跟踪、预留、预警等功能
/// ============================================
pub const InventoryModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "inventory",
        .description = "Inventory management with stock tracking and alerts",
        .dependencies = &.{ "database", "catalog" },
    };

    var inventory: std.AutoHashMap(u64, StockItem) = undefined;
    var reservations: std.ArrayList(Reservation) = undefined;
    var allocator: std.mem.Allocator = undefined;
    var reservation_id_counter: u64 = 1;

    // 低库存阈值
    const LOW_STOCK_THRESHOLD: u32 = 10;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        inventory = std.AutoHashMap(u64, StockItem).init(allocator);
        reservations = std.ArrayList(Reservation){};
        std.log.info("[inventory] Inventory module initialized", .{});
    }

    pub fn deinit() void {
        var iter = inventory.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.location);
        }
        inventory.deinit();
        reservations.deinit(allocator);
        std.log.info("[inventory] Inventory module cleaned up", .{});
    }

    /// 库存项
    pub const StockItem = struct {
        book_id: u64,
        quantity: u32,
        reserved: u32,
        location: []const u8,
        updated_at: i64,

        pub fn getAvailable(self: StockItem) u32 {
            return if (self.quantity > self.reserved)
                self.quantity - self.reserved
            else
                0;
        }

        pub fn isLowStock(self: StockItem) bool {
            return self.getAvailable() < LOW_STOCK_THRESHOLD;
        }
    };

    /// 预留记录
    pub const Reservation = struct {
        id: u64,
        book_id: u64,
        quantity: u32,
        order_id: u64,
        reserved_at: i64,
        expires_at: i64,
        status: ReservationStatus,

        pub const ReservationStatus = enum {
            active,
            fulfilled,
            cancelled,
            expired,
        };
    };

    /// 初始化图书库存
    pub fn initBookStock(book_id: u64, initial_quantity: u32, location: []const u8) !void {
        const item = StockItem{
            .book_id = book_id,
            .quantity = initial_quantity,
            .reserved = 0,
            .location = try allocator.dupe(u8, location),
            .updated_at = std.time.timestamp(),
        };

        try inventory.put(book_id, item);

        std.log.info("[inventory] Initialized stock for book {d}: qty={d}, location={s}", .{ book_id, initial_quantity, location });
    }

    /// 获取库存项
    pub fn getStock(book_id: u64) ?StockItem {
        return inventory.get(book_id);
    }

    /// 增加库存
    pub fn addStock(book_id: u64, quantity: u32, location: []const u8) !void {
        var item = inventory.getPtr(book_id) orelse {
            // If book doesn't exist, create new stock
            try initBookStock(book_id, quantity, location);
            return;
        };

        item.quantity += quantity;
        item.updated_at = std.time.timestamp();

        std.log.info("[inventory] Added {d} units to book {d}, total: {d}", .{ quantity, book_id, item.quantity });
    }

    /// 移除库存
    pub fn removeStock(book_id: u64, quantity: u32) !void {
        var item = inventory.getPtr(book_id) orelse return error.BookNotFound;

        if (item.getAvailable() < quantity) {
            return error.InsufficientStock;
        }

        item.quantity -= quantity;
        item.updated_at = std.time.timestamp();

        std.log.info("[inventory] Removed {d} units from book {d}, remaining: {d}", .{ quantity, book_id, item.quantity });
    }

    /// 预留库存
    pub fn reserveStock(book_id: u64, quantity: u32, order_id: u64) !Reservation {
        var item = inventory.getPtr(book_id) orelse return error.BookNotFound;

        if (item.getAvailable() < quantity) {
            return error.InsufficientStock;
        }

        item.reserved += quantity;
        item.updated_at = std.time.timestamp();

        const now = std.time.timestamp();
        const reservation = Reservation{
            .id = reservation_id_counter,
            .book_id = book_id,
            .quantity = quantity,
            .order_id = order_id,
            .reserved_at = now,
            .expires_at = now + 3600, // 1 hour expiry
            .status = .active,
        };

        reservation_id_counter += 1;
        try reservations.append(allocator, reservation);

        std.log.info("[inventory] Reserved {d} units of book {d} for order {d}", .{ quantity, book_id, order_id });

        return reservation;
    }

    /// 释放预留
    pub fn releaseReservation(reservation_id: u64) !void {
        for (reservations.items) |*res| {
            if (res.id == reservation_id and res.status == .active) {
                // Restore reserved stock
                if (inventory.getPtr(res.book_id)) |item| {
                    item.reserved -= res.quantity;
                    item.updated_at = std.time.timestamp();
                }

                res.status = .cancelled;

                std.log.info("[inventory] Released reservation {d}", .{reservation_id});
                return;
            }
        }

        return error.ReservationNotFound;
    }

    /// 履行预留（订单完成时调用）
    pub fn fulfillReservation(reservation_id: u64) !void {
        for (reservations.items) |*res| {
            if (res.id == reservation_id and res.status == .active) {
                if (inventory.getPtr(res.book_id)) |item| {
                    if (item.quantity < res.quantity) {
                        return error.InsufficientStock;
                    }

                    item.quantity -= res.quantity;
                    item.reserved -= res.quantity;
                    item.updated_at = std.time.timestamp();
                }

                res.status = .fulfilled;

                std.log.info("[inventory] Fulfilled reservation {d}", .{reservation_id});
                return;
            }
        }

        return error.ReservationNotFound;
    }

    /// 检查过期预留
    pub fn checkExpiredReservations() !void {
        const now = std.time.timestamp();

        for (reservations.items) |*res| {
            if (res.status == .active and now > res.expires_at) {
                // Restore reserved stock
                if (inventory.getPtr(res.book_id)) |item| {
                    item.reserved -= res.quantity;
                    item.updated_at = std.time.timestamp();
                }

                res.status = .expired;

                std.log.info("[inventory] Expired reservation {d}", .{res.id});
            }
        }
    }

    /// 获取所有库存
    pub fn getAllStock() []StockItem {
        var items = std.ArrayList(StockItem){};
        var iter = inventory.iterator();
        while (iter.next()) |entry| {
            items.append(allocator, entry.value_ptr.*) catch continue;
        }
        return items.toOwnedSlice(allocator) catch &[_]StockItem{};
    }

    /// 获取低库存项
    pub fn getLowStockItems() ![]StockItem {
        var items = std.ArrayList(StockItem){};
        var iter = inventory.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isLowStock()) {
                try items.append(allocator, entry.value_ptr.*);
            }
        }
        return items.toOwnedSlice(allocator);
    }

    /// 获取库存统计
    pub fn getInventoryStats() InventoryStats {
        var stats = InventoryStats{};

        var iter = inventory.iterator();
        while (iter.next()) |entry| {
            const item = entry.value_ptr;
            stats.total_books += 1;
            stats.total_quantity += item.quantity;
            stats.total_reserved += item.reserved;

            if (item.isLowStock()) {
                stats.low_stock_count += 1;
            }
        }

        return stats;
    }

    /// 库存统计
    pub const InventoryStats = struct {
        total_books: u32 = 0,
        total_quantity: u32 = 0,
        total_reserved: u32 = 0,
        low_stock_count: u32 = 0,

        pub fn getAvailable(self: InventoryStats) u32 {
            return if (self.total_quantity > self.total_reserved)
                self.total_quantity - self.total_reserved
            else
                0;
        }
    };

    /// 获取预留记录
    pub fn getReservationsByOrder(order_id: u64) ![]Reservation {
        var result = std.ArrayList(Reservation){};
        for (reservations.items) |res| {
            if (res.order_id == order_id) {
                try result.append(allocator, res);
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

test "Inventory module" {
    try InventoryModule.init();
    defer InventoryModule.deinit();

    // Initialize stock
    try InventoryModule.initBookStock(1, 100, "A-01-01");

    // Get stock
    const stock = InventoryModule.getStock(1).?;
    try std.testing.expectEqual(@as(u32, 100), stock.quantity);
    try std.testing.expectEqual(@as(u32, 100), stock.getAvailable());

    // Add stock
    try InventoryModule.addStock(1, 50, "A-01-01");
    const added = InventoryModule.getStock(1).?;
    try std.testing.expectEqual(@as(u32, 150), added.quantity);

    // Reserve stock
    const reservation = try InventoryModule.reserveStock(1, 10, 100);
    try std.testing.expectEqual(@as(u64, 1), reservation.id);
    try std.testing.expectEqual(InventoryModule.Reservation.ReservationStatus.active, reservation.status);

    const reserved = InventoryModule.getStock(1).?;
    try std.testing.expectEqual(@as(u32, 10), reserved.reserved);
    try std.testing.expectEqual(@as(u32, 140), reserved.getAvailable());

    // Fulfill reservation
    try InventoryModule.fulfillReservation(reservation.id);
    const fulfilled = InventoryModule.getStock(1).?;
    try std.testing.expectEqual(@as(u32, 140), fulfilled.quantity);
    try std.testing.expectEqual(@as(u32, 0), fulfilled.reserved);

    // Remove stock
    try InventoryModule.removeStock(1, 20);
    const removed = InventoryModule.getStock(1).?;
    try std.testing.expectEqual(@as(u32, 120), removed.quantity);

    // Stats
    const stats = InventoryModule.getInventoryStats();
    try std.testing.expectEqual(@as(u32, 1), stats.total_books);
    try std.testing.expectEqual(@as(u32, 120), stats.total_quantity);
}
