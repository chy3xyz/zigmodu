//! @initialized by zmodu — AI may modify freely
//!
//! Service layer for module: <<MODULE_NAME>>

const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");
const persistence = @import("persistence.zig");

// ── Event types ──────────────────────────────────────────────
pub const <<PASCAL_MODULE>>Event = union(enum) {
    // populated by zmodu orm from table discovery
};

pub const <<PASCAL_MODULE>>Service = struct {
    persistence: *persistence.<<PASCAL_MODULE>>Persistence,
    event_bus: ?*zigmodu.TypedEventBus(<<PASCAL_MODULE>>Event) = null,

    pub fn init(p: *persistence.<<PASCAL_MODULE>>Persistence) <<PASCAL_MODULE>>Service {
        return .{ .persistence = p };
    }

    pub fn withEvents(self: *<<PASCAL_MODULE>>Service, bus: *zigmodu.TypedEventBus(<<PASCAL_MODULE>>Event)) void {
        self.event_bus = bus;
    }

    pub fn publish(self: *<<PASCAL_MODULE>>Service, event: <<PASCAL_MODULE>>Event) void {
        if (self.event_bus) |bus| bus.publish(event);
    }
