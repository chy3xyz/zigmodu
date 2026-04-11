#!/bin/bash

# Fix ArrayList.init(allocator) → .{}
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/audit.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/catalog.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/database.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/inventory.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/user.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/payment.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/order.zig
sed -i '' 's/std\.ArrayList(\([^)]*\))\.init(\([^)]*\))/std.ArrayList(\1){}/g' modules/notification.zig

# Fix .deinit() → .deinit(allocator) in specific contexts
# This is more complex, will do manually for now

echo "Fixed init patterns"
