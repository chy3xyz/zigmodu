//! The replay driver: not a worker, and deliberately so.
//!
//! It owns no state and has nothing to be scheduled for — a plain thread pushing
//! a file-shaped series into the book's mailbox, then the drain marker. The
//! interesting part is what it does when the book says no: nothing. The queue is
//! comptime-bounded, so `error.Full` is its only exit and shedding is a decision
//! rather than an accident.

const std = @import("std");
const model = @import("model.zig");

/// `BookInbox` is the book's market-data mailbox, supplied by `module.zig`.
pub fn Replay(comptime BookInbox: type) type {
    return struct {
        pub fn run(book: *BookInbox, marker_timeout_ms: u32) void {
            for (0..model.points) |i| {
                book.send(model.pointAt(i)) catch |err| switch (err) {
                    // The book is behind: shed this point rather than grow a
                    // queue that was never allowed to grow.
                    error.Full, error.Timeout => {},
                    error.Closed => return,
                };
            }
            // `sendBlocking`: the run's barrier is this marker, and losing it to
            // a full mailbox would hang `main` instead of ending the replay.
            // Give up loudly rather than silently, then let the deadline in
            // `main` truncate the report.
            book.sendBlocking(.{ .kind = .shutdown }, marker_timeout_ms) catch |err|
                std.log.err("[market] drain marker not delivered: {s}", .{@errorName(err)});
        }
    };
}
