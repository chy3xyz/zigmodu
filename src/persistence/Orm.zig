//! NOTE: ORM has been removed.
//!
//! The previous placeholder ORM (src/experimental/Orm.zig) was a no-op implementation
//! that duplicated sqlx capabilities without leveraging them.
//!
//! A future ORM for ZigModu should be built directly on top of sqlx
//! (src/sqlx/sqlx.zig) using its Client, Builder, and Row.scan() APIs.
//!
//! For now, use sqlx directly:
//!   var client = sqlx.Client.init(allocator, .{ .driver = .sqlite, ... });
//!   const users = try client.queryRows(User, "SELECT * FROM users", &.{});

