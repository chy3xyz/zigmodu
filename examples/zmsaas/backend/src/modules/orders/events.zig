//! Custom business logic — decoupled side effects on CRUD events. Wired in
//! main.zig: svc.crud.setEventBus(&bus) + bus.subscribe(onOrderEvent).
const std = @import("std");
const zigmodu = @import("zigmodu");
const model = @import("model.zig");

pub fn onOrderEvent(e: zigmodu.data.CrudEvent(model.Orders)) void {
    switch (e) {
        .created => |id| std.log.info("[orders:event] created id={d}", .{id}),
        .updated => |id| std.log.info("[orders:event] updated id={d}", .{id}),
        .deleted => |id| std.log.info("[orders:event] deleted id={d}", .{id}),
    }
}
