//! @initialized by zmodu — AI may modify freely
//!
//! Service layer for module: <<MODULE_NAME>>

const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");
const persistence = @import("persistence.zig");

pub const <<PASCAL_MODULE>>Service = struct {
    persistence: *persistence.<<PASCAL_MODULE>>Persistence,

    pub fn init(p: *persistence.<<PASCAL_MODULE>>Persistence) <<PASCAL_MODULE>>Service {
        return .{ .persistence = p };
    }
