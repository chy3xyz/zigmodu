# ZigModu Quick Start

Get up and running with ZigModu in 5 minutes.

## Prerequisites

```bash
# Install Zig 0.16.0
brew install zig@0.16.0    # macOS
# or
sudo apt install zig=0.16.0  # Ubuntu/Debian
# or download from https://ziglang.org/download/
```

Verify installation:
```bash
zig version
# Should show: 0.16.0
```

## Step 1: Create a Module

Create a new file `src/modules/user.zig`:

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},  // No dependencies
    };

    pub fn init() !void {
        std.log.info("User module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("User module cleaned up", .{});
    }
};
```

## Step 2: Bootstrap Application

Create `src/main.zig`:

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// Import your modules
const user = @import("modules/user.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Scan and register modules
    var modules = try zigmodu.scanModules(allocator, .{user.UserModule});
    defer modules.deinit();

    // Validate dependencies
    try zigmodu.validateModules(&modules);

    // Generate documentation (optional)
    try zigmodu.generateDocs(&modules, "modules.puml", allocator);

    // Start all modules
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("Application started successfully!", .{});
}
```

## Step 3: Configure Build

Edit `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
}
```

## Step 4: Run

```bash
# Build and run
zig build run

# Or just build
zig build

# Run tests
zig build test
```

Expected output:
```
info: Application started successfully!
```

## What's Next?

| Tutorial | Description |
|----------|-------------|
| [Examples](examples/) | More complete examples |
| [Best Practices](BEST_PRACTICES.md) | Architecture evolution |
| [API Reference](docs/API.md) | Detailed API docs |
| [Architecture](docs/ARCHITECTURE.md) | System design |

## Common Commands

```bash
# Development
zig build run          # Run application
zig build test         # Run tests
zig fmt                # Format code

# Production
zig build -Doptimize=ReleaseSafe  # Optimized build
zig build install                   # Install binary

# Documentation
zig build docs        # Generate docs
```

## Troubleshooting

**"error: module not found"**
- Ensure `build.zig.zon` has correct paths

**"error: circular dependency"**
- Check Module.info.dependencies

**"missing init/deinit"**
- Every module must implement both functions

For more help, see [CONTRIBUTING.md](CONTRIBUTING.md) or open an issue.