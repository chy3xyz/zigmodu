//! CSPRNG × Io-backend coverage — the surface the v0.32.0 migration (CHANGELOG
//! 「CSPRNG 换成 `std.Io.randomSecure`」) explicitly left unverified: the
//! `Uring` / `Dispatch` vtable slots were only read in std source, never run.
//!
//! What the framework owns vs what std owns:
//!
//! * Every framework call site is one vtable dispatch —
//!   `std.Io.randomSecure(io, buf)` — and `src/` contains no backend-specific
//!   branch anywhere (no reference to `Io.Dispatch` / `Io.Uring` at all). So
//!   per-backend behaviour lives entirely in std's vtable implementations:
//!   `Io.Threaded` (macOS: libc `arc4random_buf`; Linux: `getrandom(2)`),
//!   `Io.Dispatch` (Darwin: `arc4random_buf`, instance unused), `Io.Uring`
//!   (Linux: an io_uring read of `/dev/urandom`).
//! * The whole pre-existing suite exercises only the `Threaded` slot, because
//!   every test passes `std.testing.io` — the first test below pins that
//!   identity, so a std change re-pointing the default test backend turns red
//!   here instead of silently moving the suite's entropy coverage.
//!
//! What this file adds:
//!
//! * The battery (API keys, password salts, uuids, lock owner ids) always runs
//!   against a second, locally-constructed `Io.Threaded` instance — the same
//!   vtable `std.testing.io` serves, through a handle that is not the
//!   suite-global one.
//! * `Io.Uring` (Linux) and `Io.Dispatch` (macOS) batteries exist but are
//!   comptime-gated off: std 0.17.0 stable cannot compile *either* backend —
//!   both vtable literals assign a `VTable.processReplacePath` field that does
//!   not exist (`lib/std/Io/Uring.zig:759`, `lib/std/Io/Dispatch.zig:439`;
//!   see `std_uring_backend_compiles` / `std_dispatch_backend_compiles` for
//!   the probe evidence). So on the pinned toolchain there is no ring and no
//!   GCD queue to run against, on any OS — consumers cannot hand the
//!   framework such an `io` either; their program would not compile.
//! * Windows has exactly one std backend (`Threaded`), which the default
//!   suite already covers — there is no extra slot to run.

const std = @import("std");
const builtin = @import("builtin");

const kit_random = @import("../kit/random.zig");
const ApiKeyGenerator = @import("../security/ApiKeyAuth.zig").ApiKeyGenerator;
const PasswordEncoder = @import("../security/PasswordEncoder.zig").PasswordEncoder;
const SecurityModule = @import("../security/SecurityModule.zig").SecurityModule;
const DistributedLock = @import("../core/DistributedLock.zig");
const sqlx = @import("../sqlx/sqlx.zig");

test "csprng: the suite default std.testing.io is the Threaded backend" {
    // `init_single_threaded` is a side-effect-free constant; the vtable a
    // Threaded instance serves does not depend on init options, so comparing
    // against it pins what `std.testing.io` is without installing the signal
    // handlers a live `Threaded.init` would.
    var probe = std.Io.Threaded.init_single_threaded;
    try std.testing.expect(std.testing.io.vtable == probe.io().vtable);
}

test "csprng: migrated primitives run on an explicit Threaded backend" {
    // A second, locally-constructed Threaded instance — the same vtable
    // `std.testing.io` serves (pinned above), exercised through a handle that
    // is *not* the suite-global one. This is what keeps
    // `exerciseMigratedPrimitives` itself honest: the Dispatch/Uring gates
    // below can be skipped by the environment, this one always runs.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try exerciseMigratedPrimitives(std.testing.allocator, threaded.io());
}

/// The v0.32.0 migration battery, run against whichever `io` the caller hands
/// in. Counts stay small: the Threaded suite already proves collision
/// resistance at 256×; here a modest batch suffices because the failure mode
/// a broken backend would show is `error.EntropyUnavailable` or identical
/// outputs, not a statistical near-miss.
fn exerciseMigratedPrimitives(allocator: std.mem.Allocator, io: std.Io) !void {
    // kit.random.uuid: shape (36 bytes, v4 nibble) + batch uniqueness.
    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_ids.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_ids.deinit();
    }
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const id = try kit_random.uuid(allocator, io);
        try std.testing.expectEqual(@as(usize, 36), id.len);
        try std.testing.expectEqual(@as(u8, '-'), id[8]);
        try std.testing.expectEqual(@as(u8, '4'), id[14]);
        const res = try seen_ids.getOrPut(id);
        if (res.found_existing) allocator.free(id);
    }
    try std.testing.expectEqual(@as(usize, 32), seen_ids.count());

    // kit.random.bytes: two draws never match.
    const b1 = try kit_random.bytes(io, 32);
    const b2 = try kit_random.bytes(io, 32);
    try std.testing.expect(!std.mem.eql(u8, &b1, &b2));

    // ApiKeyGenerator: format + batch uniqueness.
    var seen_keys = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_keys.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_keys.deinit();
    }
    i = 0;
    while (i < 32) : (i += 1) {
        const key = try ApiKeyGenerator.generate(allocator, io);
        try std.testing.expect(ApiKeyGenerator.validateFormat(key));
        const res = try seen_keys.getOrPut(key);
        if (res.found_existing) allocator.free(key);
    }
    try std.testing.expectEqual(@as(usize, 32), seen_keys.count());

    // PasswordEncoder: a fresh salt per call (two encodes of one password
    // must differ) and the produced hash still verifies. Low iterations keep
    // the battery fast; the entropy path under test is iteration-independent.
    var enc = PasswordEncoder.initWithIterations(allocator, io, 1000);
    const h1 = try enc.encode("correct horse battery staple");
    defer allocator.free(h1);
    const h2 = try enc.encode("correct horse battery staple");
    defer allocator.free(h2);
    try std.testing.expect(!std.mem.eql(u8, h1, h2));
    try std.testing.expect(try enc.matches("correct horse battery staple", h1));
    try std.testing.expect(!try enc.matches("wrong horse", h1));

    // SecurityModule: the `hashPassword` salt path (fixed 100k PBKDF2).
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, io);
    const hash = try sec.hashPassword("my_password");
    defer allocator.free(hash);
    try std.testing.expect(try sec.verifyPassword("my_password", hash));
    try std.testing.expect(!try sec.verifyPassword("wrong_password", hash));

    // DistributedLock: the owner id *is* the ownership credential — two
    // replicas deriving the same owner would both enter the critical section
    // (the defect the migration fixed). Distinct owners plus a working
    // claim/hand-over also exercise `Time.wallClockMilliseconds(io)` on this
    // backend. Driver-independent: skipped only if sqlite was compiled out.
    if (sqlx.DriverFeatures.sqlite) {
        var db = sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 2, .max_idle_conns = 1 });
        defer db.deinit();
        const Lock = DistributedLock.SqlLock(@TypeOf(db));
        var a = try Lock.init(allocator, io, &db, "zmodu_lock_iotest", .sqlite);
        defer a.deinit();
        var b = try Lock.init(allocator, io, &db, "zmodu_lock_iotest", .sqlite);
        defer b.deinit();
        try std.testing.expect(!std.mem.eql(u8, &a.owner, &b.owner));
        try std.testing.expect(try a.lock().tryAcquire("job", 60_000));
        try std.testing.expect(!try b.lock().tryAcquire("job", 60_000));
        a.lock().release("job");
        try std.testing.expect(try b.lock().tryAcquire("job", 60_000));
    }
}

/// std 0.17.0 stable cannot compile `Io.Dispatch` at all: its vtable literal
/// (`lib/std/Io/Dispatch.zig:439`) assigns `processReplacePath`, a field
/// `Io.VTable` does not declare (verified with a standalone probe — a 10-line
/// `Dispatch.init` + `randomSecure` program fails to compile the same way).
/// The backend being unbuildable is a std boundary, not a framework gap: every
/// framework call site takes a vtable-erased `std.Io`. Flip this to `true`
/// when the pinned toolchain's Dispatch compiles, and the battery below runs
/// for real.
const std_dispatch_backend_compiles = false;

/// Same std defect, other backend: `lib/std/Io/Uring.zig:759` assigns the same
/// nonexistent `VTable.processReplacePath` — verified by cross-compiling a
/// standalone `Uring.io()` + `randomSecure` probe for `x86_64-linux`
/// (`zig build-obj -target x86_64-linux` → that exact error). Until the pinned
/// toolchain's Uring compiles there is no ring to init, on any kernel.
const std_uring_backend_compiles = false;

test "csprng: migrated primitives run on the Io.Dispatch backend" {
    if (comptime (builtin.target.os.tag == .macos and std_dispatch_backend_compiles)) {
        var dispatch: std.Io.Dispatch = undefined;
        try std.Io.Dispatch.init(&dispatch, std.testing.allocator, .{});
        defer dispatch.deinit();
        try exerciseMigratedPrimitives(std.testing.allocator, dispatch.io());
    } else return error.SkipZigTest;
}

test "csprng: migrated primitives run on the Io.Uring backend" {
    if (comptime (builtin.target.os.tag == .linux and std_uring_backend_compiles)) {
        var ring: std.Io.Uring = undefined;
        std.Io.Uring.init(&ring, std.testing.allocator, .{}) catch |err| {
            // Old kernel or a seccomp profile without io_uring: this host
            // cannot prove the path, so skip with the reason visible rather
            // than fail an environment we do not control.
            std.debug.print("csprng uring: io_uring unavailable ({s}), skipping\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer ring.deinit();
        try exerciseMigratedPrimitives(std.testing.allocator, ring.io());
    } else return error.SkipZigTest;
}
