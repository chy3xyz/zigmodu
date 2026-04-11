#!/bin/bash

# Fix .deinit() → .deinit(allocator) where appropriate
# This requires knowing the allocator variable name in each file

# For audit.zig - allocator is the variable name
sed -i '' 's/audit_logs\.deinit();/audit_logs.deinit(allocator);/g' modules/audit.zig

# For catalog.zig
sed -i '' 's/books\.deinit();/books.deinit(allocator);/g' modules/catalog.zig
sed -i '' 's/self\.tags\.deinit();/self.tags.deinit(allocator);/g' modules/catalog.zig

# For database.zig
sed -i '' 's/\.available\.deinit();/.available.deinit(alloc);/g' modules/database.zig
sed -i '' 's/\.in_use\.deinit();/.in_use.deinit(alloc);/g' modules/database.zig

# For inventory.zig
sed -i '' 's/reservations\.deinit();/reservations.deinit(allocator);/g' modules/inventory.zig

# For cart.zig - this one is tricky, it uses 'alloc' or 'allocator'
sed -i '' 's/self\.items\.deinit();/self.items.deinit(alloc);/g' modules/cart.zig

echo "Fixed deinit patterns"
