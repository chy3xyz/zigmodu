# Basic Example

This example demonstrates the basic usage of ZigModu with three modules: User, Order, and Payment.

## Project Structure

```
basic/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    ├── tests.zig
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

## Running the Tests

`src/tests.zig` carries the testing demo:
`ModuleTestContext`, `zigmodu.createMockModule`, application lifecycle, and
dependency validation.

```bash
cd examples/basic
zig build test
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
- Module testing: `ModuleTestContext`, `createMockModule`, dependency validation