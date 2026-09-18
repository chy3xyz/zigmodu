//! Test root for the shopdemo example (`zig build test`).
//!
//! The generated test files (`test.zig`, `_arch_test.zig`) are never imported
//! by `src/main.zig`, so without this root Zig compiles no test in the example.
//!
//! Both copies are pulled in: the running app's module (`src/modules/order/`)
//! and the `generated-sample/` codegen reference, which is otherwise never
//! compiled by anything and silently rots against the framework API. Keeping it
//! in this graph is what surfaced the two API-compat lines it was missing
//! (`data` alias + `OrderEvent` in `generated-sample/service.zig`).

test {
    _ = @import("src/modules/order/test.zig");
    _ = @import("src/modules/order/_arch_test.zig");
    _ = @import("generated-sample/test.zig");
    _ = @import("generated-sample/_arch_test.zig");
}
