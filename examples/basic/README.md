# Basic Example

This example demonstrates the basic usage of ZigModu with three modules: User, Order, and Payment.

## Project Structure

```
basic/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    └── modules/
        ├── user.zig
        ├── order.zig
        └── payment.zig
```

## Running the Example

```bash
cd examples/basic
zig build run
```

## Module Dependencies

```
Payment → Order → User
```

## Key Concepts Demonstrated

- Module definition with metadata
- Module dependencies
- Lifecycle hooks (init/deinit)
- Application bootstrap