const std = @import("std");
const zigmodu = @import("zigmodu");

pub fn initWatcher(allocator: std.mem.Allocator, io: std.Io) !zigmodu.HotReloader {
    var reloader = zigmodu.HotReloader.init(allocator, io);
    try reloader.watchPath("hot_reload/targets/");
    reloader.onChange(struct {
        fn cb(path: []const u8) void {
            std.log.info("[HotReload] Marketing rules changed: {s}", .{path});
        }
    }.cb);
    return reloader;
}
