//! The market module: the replay feed.
//!
//! It owns no worker, so there is nothing to spawn in `initWith` — its work
//! begins when the composition root calls `drive()`, which starts the feed
//! thread and joins it. The dependency on `book` is declared by name and
//! satisfied by the book module's published inbox type.

const std = @import("std");
const zmodu = @import("zigmodu");
const api = @import("api.zig");
const service = @import("service.zig");

pub fn Module(comptime Book: type) type {
    return struct {
        pub const info = zmodu.api.Module{
            .name = "market",
            .description = "Replay feed: deterministic series into the book, then the drain marker",
            .dependencies = &.{"book"},
        };

        const Feed = service.Replay(Book.Inbox);

        /// Push the whole series, then the marker. Returns once the feed thread
        /// has finished handing both over.
        pub fn drive() !void {
            const feed = try std.Thread.spawn(.{}, Feed.run, .{ Book.inbox.?, api.marker_timeout_ms });
            feed.join();
        }

        /// Nothing to start: the module's work begins in `drive()`.
        pub fn init() !void {}
        pub fn deinit() void {}
    };
}
