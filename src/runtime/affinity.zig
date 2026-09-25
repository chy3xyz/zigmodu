//! CPU affinity — pinning one **thread** to one CPU, and the platform truth
//! about where that is even expressible.
//!
//! ## Platform truth (verified against the pinned toolchain and this host)
//!
//! | target | can a thread be pinned to a CPU? | evidence |
//! |--------|----------------------------------|----------|
//! | Linux | **yes** | `lib/std/os/linux.zig:3082` — `pub fn sched_setaffinity(pid: pid_t, set: *const cpu_set_t) !void`; `lib/std/os/linux.zig:7311` — `cpu_set_t = [CPU_SETSIZE / @sizeOf(usize)]usize`, with `CPU_SETSIZE = 128` at `:7310`. `std.posix` exposes only the **read** side (`lib/std/posix.zig:855` `sched_getaffinity`), so the pin goes through `std.os.linux` itself. |
//! | macOS | **no** — and the one affinity-*shaped* knob is refused too | The SDK's `sched.h` is 46 lines and declares exactly three functions: `sched_yield`, `sched_get_priority_min`, `sched_get_priority_max` (`MacOSX.sdk/usr/include/sched.h:40-42`). There is no `cpu_set_t` and no `sched_setaffinity` — `cc` on this host rejects `cpu_set_t` as an *undeclared identifier*, and `grep -c affinity` over that header returns 0. The only affinity-shaped API is Mach's `THREAD_AFFINITY_POLICY`, whose parameter is `integer_t affinity_tag` (`.../mach/thread_policy.h:208-212`) — a **grouping tag for L2 sharing, not a CPU index** — and whose own header calls it "experimental" and "a hint to the scheduler for thread placement" (`thread_policy.h:193`, `:197`). On this host (Darwin 25.6.0 / macOS 26.6.2, arm64) the kernel will not even take the hint: `thread_policy_set(mach_thread_self(), THREAD_AFFINITY_POLICY, {.affinity_tag = 42}, …)` returns **46 = `KERN_NOT_SUPPORTED`** (`mach/kern_return.h:298`), and `thread_policy_get` returns the same error with the tag untouched. So the truthful statement is stronger than "the kernel may ignore the hint": there is no pin knob, and the hint knob is refused as well. |
//! | Windows | **no binding in the pinned std** | `SetThreadAffinityMask` / `SetThreadGroupAffinity` appear **nowhere** in the pinned `lib/std` (grep). std carries the *shape* of the concept — `KAFFINITY` (`lib/std/os/windows.zig:4980`), a policy id `AffinityMask = 21` (`:1759`) — but no function. A pin would mean hand-writing an `extern "kernel32"` declaration that this repo can only cross-compile and never run (CI's `windows-cross` job). |
//!
//! **Two of this project's three targets cannot honour a pin, and the one that
//! can is the one CI runs.** That is the fact the API is shaped around, and it is
//! why what lands here is the *primitive* rather than a declaration on `spawn`.
//!
//! ## Why only the primitive, and where a declaration would go
//!
//! Affinity is a property of an **OS thread**. Exactly one thread↔worker binding
//! in this runtime is stable for a worker's whole life: `.dedicated`
//! (`runtime/runtime.zig:1719` spawns `workerMain(W, capacity)` on its own
//! thread, and that thread *is* the worker's receive loop). A `.pooled` worker is
//! by definition run by whichever pool thread claims its token — the claim moves,
//! per message — so "pin this worker" is not merely unimplementable there, it is
//! **undefined**: there would be no thread for the pin to belong to. A future
//! `.affinity` field therefore belongs on `SpawnConfig` as a `.dedicated`-only
//! declaration, refused at compile time for `.pooled` exactly as
//! `.execution_class = .blocking` is refused for `.dedicated`
//! (`runtime/runtime.zig:1543`). It would also have to be applied **from inside**
//! the new thread: `sched_setaffinity(0, …)` addresses the *calling* thread, and
//! the parent has no portable handle on a child thread (`pthread_setaffinity_np`
//! is not in this std either).
//!
//! **That declaration is deliberately not here yet, and the blocker is
//! structural rather than a matter of taste.** `spawn` returns before the worker
//! thread has run anything (`runtime/runtime.zig:1719-1723`), and the thread body
//! returns `void` with its init result "deliberately not read"
//! (`runtime/runtime.zig:2305-2308`). A declaration that *fails loudly* — the only
//! acceptable behaviour, see below — needs a parent↔child start handshake that
//! the dedicated path does not have. Adding the field before that handshake
//! exists would buy either a pin that fails silently or a `spawn` that reports
//! success for a worker that never got its core. Neither is worth shipping.
//!
//! ## Why an error, and not a warning or a no-op
//!
//! `runtime/runtime.zig:145-146` states the house rule: "a *silently ignored*
//! declaration is the one failure mode worse than an undeclared one." A no-op
//! here would be exactly the defect class this repo hunts — a knob that reads as
//! configured and does nothing. A once-per-process warning is only marginally
//! better: it is one log line in a process whose whole reason for existing is
//! that a thread must not be migrated mid-tick. So: `error.Unsupported` where the
//! platform has no API, `error.PinFailed` when the kernel refuses the call, and —
//! when the declaration does land — a `@compileError` off Linux, because the
//! target is known at compile time and a runtime error would be a worse delivery
//! of the same information.
//!
//! ```zig
//! const runtime = @import("zigmodu").runtime;
//!
//! // Linux: pins the *calling* thread. macOS/Windows: error.Unsupported.
//! try runtime.pinCurrentThread(3);
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Whether this build's target can pin a thread to a CPU at all.
///
/// `false` is not a soft "probably won't work": it means the platform has no
/// such API (see the module doc). It is comptime-known, so a caller that
/// *requires* a pin can refuse to build instead of finding out at runtime.
pub const supported: bool = switch (builtin.os.tag) {
    .linux => true,
    else => false,
};

/// Why a pin did not happen.
pub const PinError = error{
    /// This target has no way to pin a thread to a CPU: macOS (no `cpu_set_t`
    /// and no `sched_setaffinity` in its SDK, and Mach's affinity *tag* is
    /// refused with `KERN_NOT_SUPPORTED` — see the module doc) or Windows (no
    /// binding in this std).
    Unsupported,
    /// The platform has the API and the kernel refused the call. On Linux that
    /// is `EPERM` (not permitted to change this thread's affinity), `EINVAL` (no
    /// such CPU, or the CPU is outside this process's cpuset — the usual answer
    /// inside a restricted container), or `ESRCH`. `std`'s wrapper collapses all
    /// of them into `error.Unexpected` (`lib/std/os/linux.zig:3086-3089`), which
    /// is why this error cannot say which one it was.
    PinFailed,
};

/// Pin the **calling thread** to `cpu_index`.
///
/// On Linux this is `sched_setaffinity(0, …)`: afterwards the thread is eligible
/// to run on exactly that CPU until something changes the set again — a second
/// call for another index, or the thread exiting. Off Linux it returns
/// `error.Unsupported`; it never reports success for a pin it did not make, so a
/// caller cannot mistake "this platform has no such API" for "pinned".
///
/// Call it *inside* the thread you mean to pin: the parent cannot address a
/// freshly created thread through this API.
pub fn pinCurrentThread(cpu_index: usize) PinError!void {
    switch (builtin.os.tag) {
        .linux => {
            if (cpu_index >= std.os.linux.CPU_SETSIZE) return error.PinFailed;
            var set: std.os.linux.cpu_set_t = @splat(0);
            set[cpu_index / @bitSizeOf(usize)] =
                @as(usize, 1) << @intCast(cpu_index % @bitSizeOf(usize));
            std.os.linux.sched_setaffinity(0, &set) catch |err| switch (err) {
                error.Unexpected => return error.PinFailed,
            };
        },
        else => return error.Unsupported,
    }
}

test "affinity: pinCurrentThread pins where it can and refuses to pretend elsewhere" {
    // Comptime-dispatched on purpose: the untaken arm is not analysed, so the
    // Linux-only `std.posix.sched_getaffinity` never has to exist on macOS.
    switch (builtin.os.tag) {
        .linux => {
            try std.testing.expect(supported);
            const linux = std.os.linux;
            const before = try std.posix.sched_getaffinity(0);

            // Pin to a CPU the process is *already* allowed to run on, so a
            // failure here cannot mean anything but a real bug.
            var cpu: usize = 0;
            while (cpu < linux.CPU_SETSIZE) : (cpu += 1) {
                const mask = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
                if (before[cpu / @bitSizeOf(usize)] & mask != 0) break;
            }
            try std.testing.expect(cpu < linux.CPU_SETSIZE);

            // The test runner's thread keeps running after this test, so leave
            // the original set behind — a thread stuck on one core would skew
            // every later test.
            defer linux.sched_setaffinity(0, &before) catch |err| {
                std.debug.print(
                    "affinity test: could not restore the original CPU set: {s}\n",
                    .{@errorName(err)},
                );
            };

            try pinCurrentThread(cpu);
            const after = try std.posix.sched_getaffinity(0);
            // The set is exactly `{cpu}`: its word holds `cpu`'s bit and nothing
            // else, and no other word holds anything at all.
            try std.testing.expectEqual(
                @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize)),
                after[cpu / @bitSizeOf(usize)],
            );
            try std.testing.expectEqual(@as(linux.cpu_count_t, 1), linux.CPU_COUNT(after));
        },
        else => {
            // macOS: no `cpu_set_t` in the SDK and Mach's affinity tag is
            // refused with KERN_NOT_SUPPORTED. Windows: no binding in std.
            // Either way the answer is an error, at *both* ends of the legal
            // index range, and never a silent success.
            try std.testing.expect(!supported);
            try std.testing.expectError(error.Unsupported, pinCurrentThread(0));
            try std.testing.expectError(error.Unsupported, pinCurrentThread(7));
        },
    }
}
