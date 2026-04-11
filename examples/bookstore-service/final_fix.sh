#!/bin/bash

# Fix database.zig - gpa is the GPA struct, need to use gpa.allocator()
# Actually, the issue is that gpa is GeneralPurposeAllocator, not Allocator
# Need to use: var allocator = gpa.allocator();

# For now, let's fix by using the correct variable names:

# Fix database.zig to use allocator instead of gpa for ArrayList operations
sed -i '' 's/\.deinit(gpa)/.deinit(allocator)/g' modules/database.zig
sed -i '' 's/\.append(gpa,/.append(allocator,/g' modules/database.zig
sed -i '' 's/\.append(alloc,/.append(allocator,/g' modules/database.zig

# Fix cart.zig - change alloc to allocator
sed -i '' 's/\.deinit(alloc)/.deinit(allocator)/g' modules/cart.zig

# Fix notification.zig - templates is a HashMap, not ArrayList
sed -i '' 's/templates\.deinit(allocator);/templates.deinit();/g' modules/notification.zig

# Fix order.zig self.items.deinit() - Order doesn't have 'items' field with deinit
# Actually, Order.items is OrderItem list which doesn't need deinit
# Let me check what needs fixing
echo "Applied final fixes"
