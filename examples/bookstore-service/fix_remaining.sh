#!/bin/bash

# Fix remaining deinit() calls
sed -i '' 's/performance_metrics\.deinit();/performance_metrics.deinit(allocator);/g' modules/audit.zig
sed -i '' 's/error_logs\.deinit();/error_logs.deinit(allocator);/g' modules/audit.zig
sed -i '' 's/notifications\.deinit();/notifications.deinit(allocator);/g' modules/notification.zig
sed -i '' 's/templates\.deinit();/templates.deinit(allocator);/g' modules/notification.zig
sed -i '' 's/orders\.deinit();/orders.deinit(allocator);/g' modules/order.zig
sed -i '' 's/payment_methods\.deinit();/payment_methods.deinit(allocator);/g' modules/payment.zig
sed -i '' 's/transactions\.deinit();/transactions.deinit(allocator);/g' modules/payment.zig
sed -i '' 's/users\.deinit();/users.deinit(allocator);/g' modules/user.zig
sed -i '' 's/sessions\.deinit();/sessions.deinit(allocator);/g' modules/user.zig

# Fix database.zig deinit with 'gpa' not 'alloc'
sed -i '' 's/\.deinit(alloc);/.deinit(gpa);/g' modules/database.zig

# Fix cart.zig - uses 'alloc' not 'allocator'
sed -i '' 's/\.deinit(allocator);/.deinit(alloc);/g' modules/cart.zig

# Fix append calls to include allocator
sed -i '' 's/\.available\.append(conn)/.available.append(alloc, conn)/g' modules/database.zig
sed -i '' 's/\.in_use\.append(conn)/.in_use.append(alloc, conn)/g' modules/database.zig

echo "Fixed remaining patterns"
