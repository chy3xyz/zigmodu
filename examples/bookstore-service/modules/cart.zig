const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Shopping Cart Module - 购物车模块
/// 提供购物车管理、价格计算等功能
/// ============================================
pub const CartModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "cart",
        .description = "Shopping cart management with price calculation",
        .dependencies = &.{ "catalog", "inventory", "user" },
    };

    var carts: std.AutoHashMap(u64, ShoppingCart) = undefined;
    var cart_item_id_counter: u64 = 1;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        carts = std.AutoHashMap(u64, ShoppingCart).init(allocator);
        std.log.info("[cart] Cart module initialized", .{});
    }

    pub fn deinit() void {
        var iter = carts.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        carts.deinit();
        std.log.info("[cart] Cart module cleaned up", .{});
    }

    /// 购物车
    pub const ShoppingCart = struct {
        user_id: u64,
        items: std.ArrayList(CartItem),
        created_at: i64,
        updated_at: i64,

        pub fn deinit(self: *ShoppingCart, alloc: std.mem.Allocator) void {
            for (self.items.items) |*item| {
                item.deinit(alloc);
            }
            self.items.deinit(alloc);
        }

        pub fn getSubtotal(self: ShoppingCart) f64 {
            var total: f64 = 0;
            for (self.items.items) |item| {
                total += item.subtotal;
            }
            return total;
        }

        pub fn getItemCount(self: ShoppingCart) u32 {
            var count: u32 = 0;
            for (self.items.items) |item| {
                count += item.quantity;
            }
            return count;
        }
    };

    /// 购物车项
    pub const CartItem = struct {
        id: u64,
        book_id: u64,
        quantity: u32,
        unit_price: f64,
        subtotal: f64,
        added_at: i64,

        pub fn deinit(self: *CartItem, alloc: std.mem.Allocator) void {
            _ = self;
            _ = alloc;
        }
    };

    /// 创建或获取购物车
    pub fn getOrCreateCart(user_id: u64) !*ShoppingCart {
        const result = carts.getPtr(user_id);
        if (result) |cart| {
            return cart;
        }

        const now = std.time.timestamp();
        const new_cart = ShoppingCart{
            .user_id = user_id,
            .items = std.ArrayList(CartItem){},
            .created_at = now,
            .updated_at = now,
        };

        try carts.put(user_id, new_cart);
        std.log.info("[cart] Created new cart for user {d}", .{user_id});

        return carts.getPtr(user_id).?;
    }

    /// 添加商品到购物车
    pub fn addItem(user_id: u64, book_id: u64, quantity: u32, unit_price: f64) !CartItem {
        const cart = try getOrCreateCart(user_id);

        // Check if item already exists
        for (cart.items.items) |*item| {
            if (item.book_id == book_id) {
                item.quantity += quantity;
                item.subtotal = @as(f64, @floatFromInt(item.quantity)) * unit_price;
                cart.updated_at = std.time.timestamp();
                std.log.info("[cart] Updated item {d} quantity to {d} for user {d}", .{ book_id, item.quantity, user_id });
                return item.*;
            }
        }

        // Add new item
        const item = CartItem{
            .id = cart_item_id_counter,
            .book_id = book_id,
            .quantity = quantity,
            .unit_price = unit_price,
            .subtotal = unit_price * @as(f64, @floatFromInt(quantity)),
            .added_at = std.time.timestamp(),
        };

        cart_item_id_counter += 1;
        try cart.items.append(allocator, item);
        cart.updated_at = std.time.timestamp();

        std.log.info("[cart] Added item {d} (qty={d}) to cart for user {d}", .{ book_id, quantity, user_id });
        return item;
    }

    /// 更新购物车项数量
    pub fn updateItemQuantity(user_id: u64, item_id: u64, new_quantity: u32) !?CartItem {
        const cart = carts.getPtr(user_id) orelse return null;

        for (cart.items.items) |*item| {
            if (item.id == item_id) {
                if (new_quantity == 0) {
                    // Remove item if quantity is 0
                    _ = removeItem(user_id, item_id);
                    return null;
                }

                item.quantity = new_quantity;
                item.subtotal = @as(f64, @floatFromInt(new_quantity)) * item.unit_price;
                cart.updated_at = std.time.timestamp();

                std.log.info("[cart] Updated item {d} quantity to {d}", .{ item_id, new_quantity });
                return item.*;
            }
        }

        return null;
    }

    /// 移除购物车项
    pub fn removeItem(user_id: u64, item_id: u64) bool {
        const cart = carts.getPtr(user_id) orelse return false;

        for (cart.items.items, 0..) |item, index| {
            if (item.id == item_id) {
                _ = cart.items.orderedRemove(index);
                cart.updated_at = std.time.timestamp();

                std.log.info("[cart] Removed item {d} from cart for user {d}", .{ item_id, user_id });
                return true;
            }
        }

        return false;
    }

    /// 获取购物车
    pub fn getCart(user_id: u64) ?*ShoppingCart {
        return carts.getPtr(user_id);
    }

    /// 清空购物车
    pub fn clearCart(user_id: u64) !void {
        const cart = carts.getPtr(user_id) orelse return;

        for (cart.items.items) |*item| {
            item.deinit(allocator);
        }
        cart.items.clearRetainingCapacity();
        cart.updated_at = std.time.timestamp();

        std.log.info("[cart] Cleared cart for user {d}", .{user_id});
    }

    /// 结算预览
    pub const CheckoutSummary = struct {
        subtotal: f64,
        tax: f64,
        shipping: f64,
        discount: f64,
        total: f64,
        item_count: u32,
    };

    pub fn checkoutPreview(user_id: u64) !CheckoutSummary {
        const cart = carts.get(user_id) orelse return error.CartNotFound;

        const subtotal = cart.getSubtotal();
        const tax_rate = 0.08; // 8% tax rate
        const tax = subtotal * tax_rate;
        const shipping = if (subtotal > 50.0) @as(f64, 0.0) else @as(f64, 5.99);
        const discount = 0.0; // Apply discount logic here

        const total = subtotal + tax + shipping - discount;

        return CheckoutSummary{
            .subtotal = subtotal,
            .tax = tax,
            .shipping = shipping,
            .discount = discount,
            .total = total,
            .item_count = cart.getItemCount(),
        };
    }

    /// 验证库存
    pub fn validateStock(user_id: u64) ![]StockValidationResult {
        const cart = carts.get(user_id) orelse return error.CartNotFound;
        var results = std.ArrayList(StockValidationResult){};

        for (cart.items.items) |item| {
            // 这里应该查询库存模块
            // 简化实现：假设所有商品都有足够库存
            const result = StockValidationResult{
                .book_id = item.book_id,
                .requested = item.quantity,
                .available = item.quantity + 10, // 模拟可用库存
                .is_available = true,
            };
            try results.append(allocator, result);
        }

        return results.toOwnedSlice(allocator);
    }

    /// 库存验证结果
    pub const StockValidationResult = struct {
        book_id: u64,
        requested: u32,
        available: u32,
        is_available: bool,
    };

    /// 转换为订单项
    pub fn toOrderItems(user_id: u64) ![]OrderItemRequest {
        const cart = carts.get(user_id) orelse return error.CartNotFound;
        var items = std.ArrayList(OrderItemRequest){};

        for (cart.items.items) |item| {
            try items.append(allocator, .{
                .book_id = item.book_id,
                .quantity = item.quantity,
            });
        }

        return items.toOwnedSlice(allocator);
    }

    pub const OrderItemRequest = struct {
        book_id: u64,
        quantity: u32,
    };
};

test "Cart module" {
    try CartModule.init();
    defer CartModule.deinit();

    const user_id: u64 = 1;

    // Add items
    const item1 = try CartModule.addItem(user_id, 1, 2, 29.99);
    try std.testing.expectEqual(@as(u64, 1), item1.id);
    try std.testing.expectEqual(@as(u32, 2), item1.quantity);

    const item2 = try CartModule.addItem(user_id, 3, 1, 44.99);
    try std.testing.expectEqual(@as(u64, 2), item2.id);

    // Update quantity
    const updated = try CartModule.updateItemQuantity(user_id, item1.id, 3);
    try std.testing.expect(updated != null);
    try std.testing.expectEqual(@as(u32, 3), updated.?.quantity);

    // Get cart
    const cart = CartModule.getCart(user_id).?;
    try std.testing.expectEqual(@as(usize, 2), cart.items.items.len);

    // Checkout preview
    const summary = try CartModule.checkoutPreview(user_id);
    try std.testing.expect(summary.subtotal > 0);
    try std.testing.expect(summary.total > summary.subtotal);

    // Clear cart
    try CartModule.clearCart(user_id);
    const cleared = CartModule.getCart(user_id).?;
    try std.testing.expectEqual(@as(usize, 0), cleared.items.items.len);
}
