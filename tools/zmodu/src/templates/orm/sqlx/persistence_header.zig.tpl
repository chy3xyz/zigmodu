//! @initialized by zmodu — AI may modify freely
//!
//! ORM persistence for module: <<MODULE_NAME>>

const std = @import("std");
const data = @import("zigmodu").data;
const model = @import("model.zig");

pub const <<PASCAL_MODULE>>Persistence = struct {
    backend: data.SqlxBackend,
    orm: data.orm.Orm(data.SqlxBackend),

    pub fn init(backend: data.SqlxBackend) <<PASCAL_MODULE>>Persistence {
        return .{ .backend = backend, .orm = .{ .backend = backend } };
    }
