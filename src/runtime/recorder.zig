//! Recorder — a bounded, zero-allocation log of the runtime's **delivery**
//! stream, plus replay in seq order against a `Clock.Manual`.
//!
//! The runtime is deliberately lossy (`HotBus` drops on a full mailbox and
//! counts it) and its ordering is only defined per mailbox, so "what did this
//! run actually deliver, in what order, at what time?" cannot be answered from
//! the runtime after the fact. Two logs in this file answer it, from the two
//! sides of the same hand-off (`docs/RUNTIME.md` §11 and §13):
//!
//! * `Recorder(E, capacity)` — the `HotBus` **publish** stream, i.e. what a
//!   producer published, recorded inside `publish` before the fan-out. What a
//!   subscriber did with it is not its business.
//! * `Track(E, capacity)` + `DeliveryLog` — the **delivery** stream, i.e. what
//!   each worker's mailbox actually accepted (`Handle.send*`, a `HotBus`
//!   fan-out landing on a handle, and `after(...)`'s timer delivery). One track
//!   per worker, each single-typed, all ordered by one shared sequence.
//!
//! ```zig
//! // §11: the publish stream
//! var rec = runtime.Recorder(Trade, 4096).init(clock); // the runtime's clock…
//! try bus.attachRecorder(&rec);   // before bus.freeze()
//! rec.replay(&manual_clock, &harness, Harness.sink);  // no sleeping
//!
//! // §13: the delivery stream, declared at the spawn point
//! const book = try rt.spawn(Book, .{}, .{ .capacity = 256, .record = .{ .id = "book", .capacity = 1024 } });
//! const log = rt.deliveryLog().?;
//! var rp = log.replayer(&manual_clock);
//! try rp.bind("book", fresh_book);                    // the caller supplies the map
//! try rp.onlyTracks(&.{"book"});                      // …and which tracks are in it
//! rp.open(from_seq, to_seq);                          // …and which seq range: [from, to)
//! while (try rp.step()) |step| { … }                  // merged by global seq, never sleeps
//! ```
//!
//! Four properties, each a deliberate choice, and they hold for both logs:
//!
//! 1. **Overflow is an error, not a drop.** `record` returns `error.Full` once
//!    the log has no room. That is the opposite of `HotBus`, on purpose: a log
//!    with a hole in it *looks* complete, so a replay built on it would be
//!    silently wrong. Nothing is ever overwritten, so `entries()` stays a
//!    prefix in `seq` order.
//! 2. **Zero allocation, lock-free.** Capacity is comptime, storage is a fixed
//!    array, and one atomic increment claims a slot. `Recorder`'s sequence
//!    number *is* its slot index; a `Track` claims slots locally and stamps its
//!    entries with the log's sequence number, because its entries must merge
//!    with other tracks. No allocator is threaded through `Mailbox` /
//!    `RingBuffer` / `send` for either.
//! 3. **Off costs one null check.** A bus with no recorder attached, and a
//!    handle spawned without `.record`, behave exactly as they did before this
//!    file existed.
//! 4. **A narrowed replay is a counted one.** `Replayer.open`/`seekTo` take a
//!    seq range and `Replayer.onlyTracks` takes a track filter; whatever either
//!    of them screens out is skipped *and counted* (`skippedBefore`,
//!    `skippedUnselected`), never dropped in silence. Looking at a slice of a
//!    log is the whole point of the feature, so "what did this replay not
//!    cover" has to be readable rather than implied.
//!
//! ## Division of labour with `core/EventStore.zig`
//!
//! `EventStore` is **domain event sourcing**: application code appends *business*
//! events to a named `stream_id` with a version, may snapshot, and expects them
//! to survive a restart. It is the record of what the business decided.
//!
//! The logs here record the **runtime stream**: what the hot path actually
//! handed over, in the order the runtime ordered it, stamped with the injected
//! clock — in memory, bounded, and opt-in. They are debugging/replay tools, not
//! a system of record. Use neither in place of the other: appending ticks to an
//! `EventStore` misuses streams/versions, and using either log for durability
//! loses everything on exit.
//!
//! ## What v1 is not (`docs/RUNTIME.md` §11.4, §13.5/§13.7)
//!
//! - **Single event type per log.** A `Recorder(E, capacity)` logs one `E`, and
//!   so does a `Track`. `MpscRing` cross-producer interleavings within one
//!   mailbox are not reproduced either: what a log holds is *one* legal
//!   interleaving at its record points (§11.3 Q2), not the interleaving a run
//!   happened to observe.
//! - **No codec on the record path.** Two heterogeneous workers are logged as
//!   two single-typed tracks merged by their sequence numbers, and `record` still
//!   stores the value itself: turning a value into bytes is a caller-supplied
//!   `Codec(E)` that runs in `drainTo`, where allocating is allowed (§13.9
//!   D1/D2). What is still missing is the other direction — replaying *from*
//!   those bytes is the next slice (§13.9 D5).
//! - **Not a `HotBus` subscriber.** A sink consumes a comptime subscriber slot,
//!   and a log too small for the traffic would come back as `deliver ==
//!   false` → counted as a *drop* while the event kept flowing. Both record
//!   points are inside the runtime instead (see `HotBus.attachRecorder` and
//!   `Handle.enqueue`).
//! - **No process-level determinism.** `spawn`/`init` side effects, sockets, the
//!   wall clock and drop-on-full delivery are not replayed. Replay reproduces
//!   what the log holds, not the interleaving a given run happened to observe.
//! - **Only clock-reading code replays.** Time is injected (`Clock`); code that
//!   calls `core/Time.zig` directly reads real time and is outside the replay.

const std = @import("std");
const mbox = @import("mailbox.zig");
const dlog = @import("delivery_log.zig");
const Sequencer = @import("sequencer.zig").Sequencer;
const Clock = @import("clock.zig").Clock;

/// "This log has no hole" in `DeliveryLog.first_hole_seq`. Not 0: seq 0 is a
/// perfectly good delivery, and a hole can be at it.
const NO_HOLE: u64 = std.math.maxInt(u64);

/// Errors `record` reports.
pub const RecordError = error{
    /// The log is full. Deliberately loud (see the file doc comment): the caller
    /// must decide to stop, resize or discard the log — continuing would produce
    /// a plausible-looking replay with a hole in it.
    Full,
};

/// The storage half of a bounded log: `capacity` slots of `Record`, a per-slot
/// publish flag, and a contiguous published prefix.
///
/// Both logs in this file are this ring — `Recorder` (the `HotBus` publish
/// stream, §11) and `Track` (one worker's delivery stream, §13) — and what they
/// do *not* share is where the slot index comes from. `Recorder` uses its
/// sequence number as the slot index (so `seq` is dense and slot == seq); a
/// `Track` claims slots locally and stamps entries with the *log's* sequence
/// number, because its entries have to be mergeable with other tracks. Keeping
/// that difference outside the storage is what makes the ring one mechanism
/// instead of two copies.
fn Slots(comptime Record: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Written before the slot is published; read only below `published`.
        buf: [capacity]Record = undefined,
        /// Per-slot publish flag. A producer sets its own slot with release; a
        /// reader that observed `published` with acquire only looks at slots
        /// whose flag it saw set. This keeps `entries()` a contiguous, complete
        /// prefix without a lock and without waiting.
        ready: [capacity]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
        /// Length of the complete prefix of `buf`, in slot order. A producer
        /// whose predecessor is still missing does not block: it publishes its
        /// slot and lets the predecessor's producer extend the prefix when it
        /// lands.
        published: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Write one record into a claimed slot and publish it.
        fn publish(self: *Self, slot: usize, record: Record) void {
            self.buf[slot] = record;
            self.ready[slot].store(true, .release);
            self.advancePublished();
        }

        /// Extend `published` over every slot at the front that is now written.
        /// Cheap in the common case; a producer that runs ahead of a straggler
        /// simply stops here and returns.
        fn advancePublished(self: *Self) void {
            var next = self.published.load(.monotonic);
            while (next < capacity and self.ready[next].load(.acquire)) {
                if (self.published.cmpxchgWeak(next, next + 1, .release, .monotonic)) |actual| {
                    next = actual;
                    continue;
                }
                next += 1;
            }
        }

        fn entries(self: *const Self) []const Record {
            return self.buf[0..self.published.load(.acquire)];
        }

        fn len(self: *const Self) usize {
            return self.published.load(.acquire);
        }
    };
}

/// A bounded, in-memory, zero-allocation log of `capacity` events of type `E`.
pub fn Recorder(comptime E: type, comptime capacity: usize) type {
    if (capacity < 1) @compileError("Recorder needs capacity >= 1");
    if (@sizeOf(E) == 0) @compileError("Recorder stores events by value; " ++ @typeName(E) ++ " has no size");
    return struct {
        const Self = @This();

        /// The event type this log holds — `HotBus.attachRecorder` checks it
        /// against the bus's own event type.
        pub const Event = E;

        /// One recorded delivery: the runtime sequence number, the injected
        /// clock reading at the record point, and the event itself.
        pub const Entry = struct {
            seq: u64,
            clock_ms: i64,
            event: E,
        };

        /// Comptime storage budget.
        pub const max_entries = capacity;

        /// Where `clock_ms` comes from at the record point. Use the same clock
        /// the runtime was built with (`Clock.monotonic` in production) so the
        /// timestamps line up with what timers saw; replay is then driven by a
        /// `Clock.Manual` set to those same values.
        clock: Clock,

        /// A record's sequence number *is* its slot index: `next()` hands out
        /// 0, 1, 2, …, so a value `>= capacity` is exactly "the log is full".
        /// One atomic increment therefore claims order and space together, and
        /// concurrent producers cannot collide on a slot.
        sequencer: Sequencer = Sequencer.init(0),

        /// Written before the slot is published; read only below `published`.
        /// The ring itself: `Recorder` claims slot == seq, so `entries()` is in
        /// `seq` order by construction.
        slots: Slots(Entry, capacity) = .{},
        overflowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(clock: Clock) Self {
            return .{ .clock = clock };
        }

        /// Append one event. Allocation-free and lock-free. `error.Full` when
        /// the log has no room left — the event is *not* silently discarded.
        pub fn record(self: *Self, event: E) RecordError!void {
            const n = self.sequencer.next();
            if (n >= capacity) {
                self.overflowed.store(true, .release);
                return RecordError.Full;
            }
            self.slots.publish(@intCast(n), .{
                .seq = n,
                .clock_ms = self.clock.nowMs(),
                .event = event,
            });
        }

        /// The recorded events, in ascending `seq` — the replay order.
        pub fn entries(self: *const Self) []const Entry {
            return self.slots.entries();
        }

        /// How many events the log holds.
        pub fn len(self: *const Self) usize {
            return self.slots.len();
        }

        /// No further `record` will be accepted.
        pub fn full(self: *const Self) bool {
            return self.sequencer.peek() >= capacity;
        }

        /// The sequence number the next accepted record will carry (also the
        /// count of numbers handed out, so it keeps growing after an overflow).
        pub fn seq(self: *const Self) u64 {
            return self.sequencer.peek();
        }

        /// True once a `record` was refused. The log is incomplete from then on:
        /// discard it, or treat the replay as covering only `entries().len`
        /// events. There is no repair — the refused event is gone.
        pub fn hasOverflowed(self: *const Self) bool {
            return self.overflowed.load(.acquire);
        }

        /// Hand every entry to `sink` in seq order, moving `clock` to each
        /// entry's `clock_ms` first. Nothing sleeps and no wall-clock time is
        /// consulted: time comes from the log, so a three-hour recorded run
        /// replays at CPU speed and timers fire in the recorded relative order.
        ///
        /// `sink` is called as `sink(ctx, entry)` — pass `Harness.sink` for a
        /// `fn sink(self: *Harness, entry: Recorder(E, N).Entry) void`, or any
        /// plain `fn (ctx, entry)` with that shape.
        pub fn replay(self: *Self, clock: *Clock.Manual, ctx: anytype, sink: anytype) void {
            for (self.entries()) |entry| {
                clock.set(entry.clock_ms);
                sink(ctx, entry);
            }
        }
    };
}

// ─────────────────────────────────────────────────
// §13 — delivery tracks: what each worker received, in one global order
// ─────────────────────────────────────────────────

/// The spawn-time declaration of a worker's delivery track (docs/RUNTIME.md
/// §13.2): `.record = .{ .id = "book:0", .capacity = 1024 }`.
///
/// Both fields are the caller's, deliberately. `capacity` is the memory bound —
/// it is a *declaration*, never a default (§13.6 · 1: no "record everything"),
/// and it is per worker because the storage is `Message`-sized. `id` is the
/// worker's stable identity (§13.6 · 2): the replay driver maps it back to a
/// handle, so deriving it from anything the runtime could renumber (a module
/// name, a spawn ordinal) would make replays that only work when the graph is
/// rebuilt in exactly the same order.
pub const TrackSpec = struct {
    /// Stable identity of this worker inside its log. Must be unique — two tracks
    /// under one id would split a worker's deliveries and replay them as one.
    id: []const u8,
    /// Track capacity in messages. Memory is `capacity × (sizeof(Message) + the
    /// entry's overhead)` — `seq`, `clock_ms` and the delivery `kind` ride along
    /// per slot, and the struct's alignment rounds the total up (real numbers for
    /// the message sizes in use: `docs/RUNTIME.md` §13.11) — held for the life of
    /// the runtime.
    capacity: usize,
};

/// One entry as the *erased* side sees it: the ordering stamps, the kind of
/// delivery it was, plus a pointer to the payload inside the track's ring (valid
/// until the track is destroyed).
///
/// The payload is a pointer to the recorded value rather than encoded bytes on
/// purpose: replaying *in memory* hands the value over (§13.9 D5 reads bytes back
/// instead, and is not this file's), so the typed half is re-attached by the
/// target handle's own thunk in `Replayer.bind`.
pub const TrackEntry = struct {
    seq: u64,
    clock_ms: i64,
    /// What the delivery *was* — `dlog.Kind.message` for a `Handle.send*`, or
    /// `dlog.Kind.timer` for one a timer's `post` handed over. Carried through
    /// the ring rather than re-derived here: the two land in one ring and are
    /// indistinguishable from the payload alone, so guessing is what used to make
    /// every drained frame claim `.message` (§13.9, and §13.11 for the fix).
    kind: dlog.Kind,
    payload: *const anyopaque,
};

/// One track's ring in **claim space**, which is where the drain tells "an entry
/// I can write" from "a delivery the ring could not keep" (`docs/RUNTIME.md`
/// §13.9 D3). Claims are what the ring's own counter hands out, in order, and
/// today's `Track` refuses a claim it has no room for rather than overwriting
/// the slot the drain has not read yet.
pub const TrackClaims = struct {
    /// Claims the ring has made. Claim `i` is slot `i` while `i < slots`.
    claimed: u64,
    /// The claim index where the ring runs out of room — its comptime capacity.
    /// A delivery claimed at or above it is one the ring did not keep, and it is
    /// counted as a hole whether the ring refused it (`Track`) or overwrote it
    /// (a ring that wrapped would lose exactly the same deliveries).
    slots: u64,
};

/// The type-erased view of one worker's track: what a `Handle` holds on the send
/// path, and what `DeliveryLog`/`Replayer` iterate. `Track(E, capacity)` contains
/// one of these, so a pointer to it is stable for as long as the track is.
pub const TrackRef = struct {
    /// The caller's `TrackSpec.id`.
    id: []const u8,
    /// `@typeName(E)` — `Replayer.bind` refuses to hand this track's payloads to a
    /// handle whose `Message` is a different type.
    message_type: []const u8,
    /// Reserved for §13.3 Q4's second storage tier: a track persisted across
    /// processes needs a payload codec, and an entry then has to say which one
    /// wrote it. Attached by `DeliveryLog.setCodec` (§13.9 D2) — the caller's
    /// `Codec(E).name` — and `null` for a track that only ever held live values,
    /// which is what makes `drainTo` refuse it *by name* instead of skipping it.
    payload_codec: ?[]const u8 = null,

    /// Append one delivery of `kind`. `event` points at the sender's value, which
    /// the track copies into its ring — no allocation, and the sender's copy is
    /// not kept.
    record: *const fn (track: *TrackRef, event: *const anyopaque, kind: dlog.Kind) RecordError!void,
    /// Entry `i`, which must be below `len`.
    entry: *const fn (track: *const TrackRef, i: usize) TrackEntry,
    len: *const fn (track: *const TrackRef) usize,
    has_overflowed: *const fn (track: *const TrackRef) bool,
    destroy: *const fn (track: *TrackRef, allocator: std.mem.Allocator) void,
    /// This track's ring in claim space — what `drainTo` reads (§13.9 D3).
    claims: *const fn (track: *const TrackRef) TrackClaims,

    /// §13.9 D2: how this track turns one of its entries into bytes — the
    /// codec's `encode`, monomorphised for this track's own `E`. Installed by
    /// `setCodec`; `null` when the track declared no codec, which is the whole
    /// reason `drainTo` can refuse it rather than guess.
    encode: ?*const fn (allocator: std.mem.Allocator, payload: *const anyopaque) anyerror![]u8 = null,
    /// The same codec's `decode`, for the codec that will read these bytes back.
    /// `out` must point at an aligned `E` — the erased side cannot name it, and
    /// the typed side is the only one that can (reading a segment back is the
    /// next slice, §13.9 D5).
    decode: ?*const fn (allocator: std.mem.Allocator, bytes: []const u8, out: *anyopaque) anyerror!void = null,

    /// Replay state, owned by this descriptor (see `DeliveryLog.replayer`): the
    /// next entry to hand out, and — once bound — where its payloads go back to.
    cursor: usize = 0,
    target: ?*anyopaque = null,
    post: ?*const fn (target: *anyopaque, payload: *const anyopaque) mbox.SendError!void = null,

    /// **The drain's** cursor: entries already appended to a segment file
    /// (§13.9 D4). `cursor` above belongs to the replay and `replayer()` rewinds
    /// it; this one only ever moves forward, so an entry reaches the file at
    /// most once and a second drain writes only what the first did not.
    drained_slots: usize = 0,
    /// The last global seq `drainTo` wrote from this track, or `null` while it
    /// has written none (§13.9 D4). Read back with `DeliveryLog.drainedUpto`.
    drained_upto: ?u64 = null,
};

/// One worker's delivery track: a bounded ring of that worker's own `Message`
/// type whose entries carry sequence numbers from the log's shared `Sequencer`.
///
/// That is the whole trick of §13.2 — each track stays single-typed, so it is
/// still zero-allocation and value-semantic on the record path, while the shared
/// sequence makes the tracks mergeable into one replay order. A codec is only
/// ever needed to *drain* it (§13.9), never to record into it.
pub fn Track(comptime E: type, comptime capacity: usize) type {
    if (capacity < 1) @compileError("Track needs capacity >= 1");
    if (@sizeOf(E) == 0) @compileError("Track stores messages by value; " ++ @typeName(E) ++ " has no size");
    return struct {
        const Self = @This();

        /// The message type this track holds.
        pub const Event = E;
        /// Comptime storage budget.
        pub const max_entries = capacity;
        /// Statically no codec: whether this track can be drained to bytes is a
        /// per-track declaration the caller makes later
        /// (`DeliveryLog.setCodec` sets `TrackRef.payload_codec`), which a
        /// `const` on the type cannot say.
        pub const codec: ?[]const u8 = null;

        /// One recorded delivery, in this track's ring: the *global* sequence
        /// number, the injected clock reading at the record point, the kind of
        /// delivery it was, and the message itself.
        pub const Entry = struct {
            seq: u64,
            clock_ms: i64,
            /// `dlog.Kind.message` for `Handle.send*`, `dlog.Kind.timer` for one
            /// `Handle.after(...)` handed over (§13.9). Stored per entry because
            /// the ring is where the difference is lost otherwise: both arrive at
            /// the same funnel with the same payload type.
            kind: dlog.Kind,
            event: E,
        };

        /// The log this track belongs to: source of its `seq` values and of the
        /// clock its entries are stamped with.
        log: *DeliveryLog,
        /// The ring — `Recorder`'s storage, claimed by this track's own counter
        /// (see `Slots`).
        slots: Slots(Entry, capacity) = .{},
        /// Slot claim. A second counter next to the log's sequencer is the point:
        /// the entry's `seq` is global, while its *storage* stays local and
        /// bounded, so a track that runs out of room refuses rather than growing
        /// or overwriting.
        writes: Sequencer = Sequencer.init(0),
        overflowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// The erased view. It lives *inside* the track, which is what makes
        /// `&track.ref` stable for the track's whole life — a handle holds it, so
        /// it must not move. (`DeliveryLog.addTrack` sets `id`/`payload_codec`
        /// after allocation, for the same reason.)
        ref: TrackRef = .{
            .id = "",
            .message_type = @typeName(E),
            .record = recordErased,
            .entry = entryErased,
            .len = lenErased,
            .has_overflowed = overflowedErased,
            .destroy = destroyErased,
            .claims = claimsErased,
        },

        /// Append one delivery, read as a `Handle.send*` delivery (`.message`).
        /// The signature the send path has always used; a delivery whose kind is
        /// known to be something else goes through `recordKind`.
        ///
        /// Zero allocation, lock-free. `error.Full` when the track has no room
        /// left: the delivery *happened* (the message is in the mailbox), the log
        /// just cannot keep it — which is why the runtime counts the refusal
        /// instead of failing the send (see `DeliveryLog.refused`).
        pub fn record(self: *Self, event: E) RecordError!void {
            return self.recordKind(event, .message);
        }

        /// `record`, with the kind the delivery really was (§13.9): `Handle.send*`
        /// passes `.message`, a timer's delivery passes `.timer`. Same contract as
        /// `record` — zero allocation, by value, `error.Full` when the ring is
        /// full — and the same entry point, because what a drain writes is exactly
        /// the kind it is handed here.
        pub fn recordKind(self: *Self, event: E, kind: dlog.Kind) RecordError!void {
            const seq = self.log.sequencer.next();
            const n = self.writes.next();
            if (n >= capacity) {
                self.overflowed.store(true, .release);
                _ = self.log.refused.fetchAdd(1, .monotonic);
                // The refused delivery's seq is the one thing nobody can
                // reconstruct later: it was handed out and never stored, so the
                // drain's read-out would have to say "there is a hole, somewhere"
                // (§13.9 D3). It costs this branch — the error path, not the hot
                // one — one atomic min.
                self.log.noteHoleSeq(seq);
                return RecordError.Full;
            }
            self.slots.publish(@intCast(n), .{
                .seq = seq,
                .clock_ms = self.log.clock.nowMs(),
                .kind = kind,
                .event = event,
            });
        }

        /// This track's entries, in ascending `seq`.
        pub fn entries(self: *const Self) []const Entry {
            return self.slots.entries();
        }

        /// How many deliveries this track holds.
        pub fn len(self: *const Self) usize {
            return self.slots.len();
        }

        /// No further `record` will be accepted.
        pub fn full(self: *const Self) bool {
            return self.writes.peek() >= capacity;
        }

        /// True once a `record` was refused — this track's part of the log is
        /// incomplete from then on.
        pub fn hasOverflowed(self: *const Self) bool {
            return self.overflowed.load(.acquire);
        }

        /// This track's ring in claim space (§13.9 D3): what `drainTo` reads from
        /// a track it only knows erased, to tell an entry it can write from a
        /// delivery the ring could not keep.
        pub fn claimState(self: *const Self) TrackClaims {
            return .{ .claimed = self.writes.peek(), .slots = capacity };
        }

        /// Entry `i` in erased form (see `TrackEntry`).
        pub fn entryAt(self: *const Self, i: usize) TrackEntry {
            return .{
                .seq = self.slots.buf[i].seq,
                .clock_ms = self.slots.buf[i].clock_ms,
                .kind = self.slots.buf[i].kind,
                .payload = @ptrCast(&self.slots.buf[i].event),
            };
        }

        /// The typed track behind an erased view.
        fn fromRef(ref: *TrackRef) *Self {
            return @fieldParentPtr("ref", ref);
        }

        /// `fromRef` for the read-only half of the erased interface.
        fn fromConstRef(ref: *const TrackRef) *const Self {
            return @fieldParentPtr("ref", ref);
        }

        fn recordErased(ref: *TrackRef, event: *const anyopaque, kind: dlog.Kind) RecordError!void {
            const value: *const E = @ptrCast(@alignCast(event));
            return fromRef(ref).recordKind(value.*, kind);
        }

        fn entryErased(ref: *const TrackRef, i: usize) TrackEntry {
            return fromConstRef(ref).entryAt(i);
        }

        fn lenErased(ref: *const TrackRef) usize {
            return fromConstRef(ref).len();
        }

        fn overflowedErased(ref: *const TrackRef) bool {
            return fromConstRef(ref).hasOverflowed();
        }

        fn claimsErased(ref: *const TrackRef) TrackClaims {
            return fromConstRef(ref).claimState();
        }

        fn destroyErased(ref: *TrackRef, allocator: std.mem.Allocator) void {
            allocator.destroy(fromRef(ref));
        }
    };
}

/// §13.9 D2: what a track has to declare before `drainTo` can put its payloads
/// in a file, expressed as a **shape rather than a format**. The framework reads
/// none of the payload: these four declarations are the whole contract, and
/// `DeliveryLog.setCodec` checks a caller's codec against them at compile time.
///
/// `E` is the track's own `Message`, so the codec of one track cannot be attached
/// to a track whose ring holds something else: the mismatch fails where the codec
/// is called, with the ordinary type error, instead of reinterpreting memory.
///
/// The declarations below are deliberately not usable — a codec is the caller's
/// (`encode`/`decode` here would have to know the payload). They are what the
/// names and types *are*, and the calls that read them are in `drainTo` and the
/// codec's own reader.
pub fn Codec(comptime E: type) type {
    return struct {
        /// Stable identity of the payload format: written verbatim into
        /// `TrackRef.payload_codec`, and the key whoever reads the file picks the
        /// codec back up with. Empty here — filling it in is the implementation's.
        pub const name: []const u8 = "";
        /// The caller's own payload version, for the codec's compatibility
        /// checks. Nothing to do with the segment file's `format_version`, which
        /// belongs to `delivery_log.zig`.
        pub const version: u16 = 1;
        /// The value as bytes. Owned by the caller, who frees them (`drainTo`
        /// writes them and gives them straight back — §13.9 D6).
        pub fn encode(allocator: std.mem.Allocator, value: E) anyerror![]u8 {
            _ = allocator;
            _ = value;
            return error.CodecNotImplemented;
        }
        /// The bytes back into a value, with the same allocator that read them.
        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) anyerror!E {
            _ = allocator;
            _ = bytes;
            return error.CodecNotImplemented;
        }
    };
}

/// Is `C` a `Codec(E)`? A comptime check, so a codec that is missing a piece
/// never reaches a build, and the message names the piece.
///
/// The checklist is read out of `Codec(E)` itself rather than written down twice
/// — a second copy of a shape is how the two drift apart. `encode`/`decode` are
/// only checked for existence here: whether they take *this* track's `E` is
/// decided by the call `setCodec` makes, which is a better error than any
/// signature comparison could give.
fn checkCodec(comptime E: type, comptime C: type) void {
    const Contract = Codec(E);
    const required = [_][]const u8{ "name", "version", "encode", "decode" };
    inline for (required) |decl| {
        if (!@hasDecl(C, decl)) @compileError(
            "the codec for " ++ @typeName(E) ++ " declares no `" ++ decl ++
                "` — docs/RUNTIME.md §13.9 D2's contract is `Codec(" ++ @typeName(E) ++ ")`",
        );
    }
    const name: []const u8 = C.name;
    const version: u16 = C.version;
    _ = name;
    _ = version;
    const contract_name: []const u8 = Contract.name;
    const contract_version: u16 = Contract.version;
    const contract_encode = &Contract.encode;
    const contract_decode = &Contract.decode;
    _ = contract_name;
    _ = contract_version;
    _ = contract_encode;
    _ = contract_decode;
}

/// The erasure half of the codec contract (§13.9 D2): the two thunks a track needs
/// to become bytes and back, monomorphised for one `(C, E)` pair. Both
/// `setCodec` (typed track) and `setCodecRef` (erased track) end here, so there is
/// one place that knows what `TrackRef.encode`/`decode` are.
fn installCodec(track: *TrackRef, comptime C: type, comptime E: type) void {
    track.payload_codec = C.name;
    track.encode = struct {
        fn encode(allocator: std.mem.Allocator, payload: *const anyopaque) anyerror![]u8 {
            const value: *const E = @ptrCast(@alignCast(payload));
            return C.encode(allocator, value.*);
        }
    }.encode;
    track.decode = struct {
        fn decode(allocator: std.mem.Allocator, bytes: []const u8, out: *anyopaque) anyerror!void {
            const value: *E = @ptrCast(@alignCast(out));
            value.* = try C.decode(allocator, bytes);
        }
    }.decode;
}

/// What one `drainTo` call wrote, and what the file it wrote is missing
/// (docs/RUNTIME.md §13.9 D3).
pub const DrainReport = struct {
    /// Records this call appended.
    records: usize,
    /// Deliveries that are not in the file and never will be: a full ring refused
    /// them, or the drain met an entry whose seq the file had already gone past.
    /// Cumulative and sticky, like `DeliveryLog.refusedCount` — it describes the
    /// file, so it never goes down and a later call reports the same holes.
    holes: u64,
    /// The lowest global seq among them, or `null` while the file has none.
    /// Sticky for the same reason. It is the one thing a reader cannot work out
    /// for itself: a gap in the records shows that something is missing, and this
    /// says where the missing starts.
    first_hole_seq: ?u64,
};

/// A track's stamp in milliseconds to a segment frame's nanosecond clock
/// (`delivery_log.Record.recorded_ns`). Exact for every stamp a clock hands out
/// in this process's lifetime; one that would not fit saturates, because a stamp
/// orders records rather than being arithmetic.
fn stampsToNs(clock_ms: i64) i64 {
    return std.math.mul(i64, clock_ms, std.time.ns_per_ms) catch
        if (clock_ms < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// The delivery log: one `Track` per worker that declared `.record = …`, plus the
/// single `Sequencer` that orders all of their entries.
///
/// Owned by the `Runtime` that created the workers (it holds the allocator and
/// outlives their handles — a replay normally happens *after* the run), and
/// created lazily: a runtime whose workers never declare a track allocates
/// nothing and its sends cost one null check (§13.6 · 1).
pub const DeliveryLog = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// What every track stamps `clock_ms` from — the runtime's own clock, so the
    /// log's stamps line up with what timers saw.
    clock: Clock,
    /// The one sequence every track draws from: the merge key, and the definition
    /// of the log's order across tracks (§13.3 Q2). Nothing else orders deliveries.
    sequencer: Sequencer = Sequencer.init(0),
    /// One per declared worker, in declaration order.
    tracks: std.ArrayList(*TrackRef) = .empty,
    /// Deliveries some full track refused. Non-zero means the log has a hole in
    /// it, which `Replayer.step` refuses to replay (see `hasOverflowed`).
    refused: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Entries a drain met and could not write, because the file had already
    /// moved past their `seq` (see `drainTo`). The half of `holesKnown` that is
    /// not the rings' business, and like `refused` it only ever grows.
    skipped_entries: u64 = 0,
    /// The lowest global seq that never reached a file, or `NO_HOLE`. Written
    /// from the refusal half of `Track.record` (any producer thread) and from a
    /// drain stepping over an entry, so it is an atomic min (`noteHoleSeq`)
    /// rather than an assignment.
    first_hole_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(NO_HOLE),
    /// The track the last `drainTo` refused *by name*, or `null` when it refused
    /// none (`drainRefusal`).
    drain_refusal: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, clock: Clock) Self {
        return .{ .allocator = allocator, .clock = clock };
    }

    pub fn deinit(self: *Self) void {
        for (self.tracks.items) |track| track.destroy(track, self.allocator);
        self.tracks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Declare a track for `spec.id`, holding `E` values — the spawn site's
    /// `W.Message`, which is what keeps every track single-typed. Duplicate ids
    /// are refused rather than merged.
    pub fn addTrack(self: *Self, spec: TrackSpec, comptime E: type, comptime capacity: usize) !*Track(E, capacity) {
        if (self.find(spec.id) != null) return error.DuplicateTrackId;
        const track = try self.allocator.create(Track(E, capacity));
        errdefer self.allocator.destroy(track);
        track.* = .{ .log = self };
        track.ref.id = spec.id;
        try self.tracks.append(self.allocator, &track.ref);
        return track;
    }

    /// Give back a track whose worker failed to spawn: a later failure must not
    /// leave its id taken (or its ring allocated).
    pub fn removeTrack(self: *Self, track: *TrackRef) void {
        for (self.tracks.items, 0..) |t, i| {
            if (t == track) {
                _ = self.tracks.swapRemove(i);
                track.destroy(track, self.allocator);
                return;
            }
        }
    }

    /// The track declared under `id`, or null.
    pub fn find(self: *const Self, id: []const u8) ?*TrackRef {
        for (self.tracks.items) |track| {
            if (std.mem.eql(u8, track.id, id)) return track;
        }
        return null;
    }

    /// How many tracks were declared.
    pub fn trackCount(self: *const Self) usize {
        return self.tracks.items.len;
    }

    /// Deliveries the tracks refused. Every one of them is a hole in the log.
    pub fn refusedCount(self: *const Self) u64 {
        return self.refused.load(.monotonic);
    }

    /// True once any track refused a delivery. The log is incomplete from then
    /// on: there is no repair, and `Replayer` will not replay it.
    pub fn hasOverflowed(self: *const Self) bool {
        return self.refusedCount() != 0;
    }

    /// How many deliveries the log holds, across every track.
    pub fn len(self: *const Self) usize {
        var total: usize = 0;
        for (self.tracks.items) |track| total += track.len(track);
        return total;
    }

    /// Attach a payload codec to a declared track (docs/RUNTIME.md §13.9 D2):
    /// from here on `drainTo` can turn its entries into bytes, and
    /// `TrackRef.payload_codec` records which codec's bytes they are.
    ///
    /// A separate call rather than a `TrackSpec` field or a type parameter on
    /// `Track(E, capacity)`: the codec is a *type*, and pushing it into the
    /// declaration would make every runtime worker's signature carry a
    /// serialization question it may have no answer to. `C` is checked against
    /// `Codec(E)` at compile time, where `E` is this track's own `Message` —
    /// so the codec of one track cannot be attached to another's.
    ///
    /// `track` must be this log's own (`error.UnknownTrack` otherwise): a codec
    /// attached to a track of a different log would be a wiring mistake that
    /// only shows up as a drain writing another log's entries.
    pub fn setCodec(self: *Self, track: anytype, comptime C: type) error{UnknownTrack}!void {
        const T = @TypeOf(track.*);
        if (!@hasField(T, "ref") or !@hasDecl(T, "Event"))
            @compileError("DeliveryLog.setCodec expects a track (*Track(E, capacity)) — pass " ++
                "what `addTrack` returned (docs/RUNTIME.md §13.9 D2)");
        if (!self.owns(&track.ref)) return error.UnknownTrack;
        const E = T.Event;
        comptime checkCodec(E, C);
        installCodec(&track.ref, C, E);
    }

    /// `setCodec` for a track the caller only holds **erased** — a runtime worker's,
    /// which is the only shape a spawn site has (`*Handle(W, capacity)` keeps
    /// `track: ?*TrackRef`; the typed pointer `addTrack` returned is gone by then).
    /// Without this the drain path would be unreachable for every worker declared
    /// with `.record = …`, which is exactly who §13.9 was written for.
    ///
    /// `E` is named rather than read off the track, for the same reason
    /// `ReplayFromLog.setCodec` names it: erasure is what an erased pointer lacks.
    /// That makes one check possible that the typed form does not need — the name is
    /// compared against the track's own `message_type`, so a codec for the wrong
    /// kind of `Message` is refused here (`error.MessageTypeMismatch`) instead of
    /// reinterpreted on the next drain.
    pub fn setCodecRef(self: *Self, track: *TrackRef, comptime C: type, comptime E: type) error{ UnknownTrack, MessageTypeMismatch }!void {
        if (!self.owns(track)) return error.UnknownTrack;
        if (!std.mem.eql(u8, track.message_type, @typeName(E))) return error.MessageTypeMismatch;
        comptime checkCodec(E, C);
        installCodec(track, C, E);
    }

    /// Is `track` this log's own? A codec attached to a track of a different log
    /// would be a wiring mistake that only shows up as a drain writing another
    /// log's entries.
    fn owns(self: *const Self, track: *const TrackRef) bool {
        for (self.tracks.items) |t| {
            if (t == track) return true;
        }
        return false;
    }

    /// Append every track's not-yet-drained entries to a segment file, oldest
    /// global `seq` first (docs/RUNTIME.md §13.9). Returns what this call wrote
    /// and what the file is missing.
    ///
    /// * **The hot path is untouched.** Values become bytes here and nowhere
    ///   else: `Track.record` — what `Handle.send*` calls — still copies the value
    ///   into its ring with no allocator and no codec (§13.9 D1). Allocating is
    ///   this call's privilege, and every buffer a codec hands back is freed
    ///   before the next entry (§13.9 D6).
    /// * **A track with entries and no codec is refused by name** —
    ///   `error.CodecRequired`, plus `drainRefusal()` for the id — and nothing is
    ///   written by that call (§13.9 D2). A track quietly left out of a file would
    ///   read as a worker that delivered nothing, which is the lie this whole log
    ///   exists to avoid. A track with nothing to write needs no codec: there is
    ///   nothing to encode.
    /// * **The cursor is per track and only moves forward** (`TrackRef.drained_slots`),
    ///   so an entry reaches the file at most once and a second call writes only
    ///   what the first did not (§13.9 D4).
    /// * **What cannot go in is counted, not written out of order** (§13.9 D3):
    ///   a delivery the ring refused, and one whose seq the file has already
    ///   moved past. Both are in the report's `holes` / `first_hole_seq`, so a
    ///   file that is not whole says so instead of looking whole.
    ///
    /// Errors: `error.CodecRequired` (named above), whatever the codec's `encode`
    /// returns, and whatever the writer's `append` returns — including
    /// `error.SeqNotIncreasing`, which can only come from a track whose entries
    /// are not in `seq` order by slot (concurrent producers; the same boundary
    /// `Replayer.step`'s merge has, §13.8) *and* the ring never refused.
    /// A failed call leaves the cursors exactly where the writer got to, so it
    /// can be retried.
    ///
    /// **One drain at a time per log**: the cursors are plain fields and the
    /// `Writer` is one-per-directory (see `delivery_log.zig`), so this is a
    /// maintenance loop's call, not a producer's.
    pub fn drainTo(self: *Self, writer: *dlog.Writer) !DrainReport {
        self.drain_refusal = null;
        // Nothing at all is written until everything can be: a half-drained log
        // would have some cursors past entries that the next call tries to append
        // again, and the writer refuses a seq that does not increase — a log that
        // could never be drained again.
        for (self.tracks.items) |track| {
            if (track.drained_slots >= track.len(track)) continue;
            if (track.encode == null) {
                self.drain_refusal = track.id;
                return error.CodecRequired;
            }
        }

        var written: usize = 0;
        while (self.nextToDrain()) |track| {
            const slot = track.drained_slots;
            const entry = track.entry(track, slot);
            const bytes = try track.encode.?(self.allocator, entry.payload);
            defer self.allocator.free(bytes);

            writer.append(.{
                .seq = entry.seq,
                .track_id = track.id,
                // The kind the ring recorded, not a guess: `Handle.send*` records
                // `.message` and a timer's delivery records `.timer`
                // (`Handle.noteDelivery`). A frame that said `.message` for a
                // timer delivery — which is what this line did before §13.11 —
                // made the file disagree with the run it describes.
                .kind = entry.kind,
                .recorded_ns = stampsToNs(entry.clock_ms),
                .payload = bytes,
            }) catch |err| switch (err) {
                // The file is already past this seq (an earlier drain wrote a
                // later one, e.g. a producer that published out of order). The
                // format's order *is* the file's order, so this delivery can
                // never be in it: step over it and count it, rather than fail the
                // whole drain — or worse, write it out of order.
                error.SeqNotIncreasing => {
                    track.drained_slots += 1;
                    self.skipped_entries += 1;
                    self.noteHoleSeq(entry.seq);
                    continue;
                },
                else => return err,
            };

            track.drained_slots = slot + 1;
            track.drained_upto = entry.seq;
            written += 1;
        }

        return .{
            .records = written,
            .holes = self.holesKnown(),
            .first_hole_seq = self.firstHoleSeq(),
        };
    }

    /// The track the last `drainTo` refused by name — `error.CodecRequired` says
    /// a track has entries to write and no codec; this says *which* (§13.9 D2).
    /// Cleared at the start of every drain, so it is never stale.
    pub fn drainRefusal(self: *const Self) ?[]const u8 {
        return self.drain_refusal;
    }

    /// The lowest global seq that never reached a file, or `null` while there is
    /// none. Sticky: what is missing does not stop being missing.
    pub fn firstHoleSeq(self: *const Self) ?u64 {
        const seq = self.first_hole_seq.load(.acquire);
        return if (seq == NO_HOLE) null else seq;
    }

    /// The last global seq `drainTo` wrote from the track declared under `id`, or
    /// null while it has written none — unknown ids included (§13.9 D4; the
    /// "how much" half is `TrackRef.drained_slots`).
    pub fn drainedUpto(self: *const Self, id: []const u8) ?u64 {
        const track = self.find(id) orelse return null;
        return track.drained_upto;
    }

    /// Fold one missing seq into `first_hole_seq`. Two paths write it: the
    /// refusal half of `Track.record`, which any producer thread runs, and a
    /// drain stepping over an entry — so it is a lock-free min.
    fn noteHoleSeq(self: *Self, seq: u64) void {
        var current = self.first_hole_seq.load(.monotonic);
        while (seq < current) {
            if (self.first_hole_seq.cmpxchgWeak(current, seq, .release, .monotonic)) |actual| {
                current = actual;
                continue;
            }
            current = seq;
        }
    }

    /// Deliveries that are not in the file, across every track: claims the rings
    /// made that no slot could hold, plus what a drain stepped over because the
    /// file was already past it.
    ///
    /// Counted from the rings' own claim counters rather than from
    /// `hasOverflowed`: a boolean cannot say *how many* were lost, and the
    /// counter is what tells a refused claim apart from one the track simply has
    /// not published yet. Those counters are also where §13.9 D3's second source
    /// of holes lives — a cursor that fell behind the ring loses claims in
    /// exactly this arithmetic, whether the ring refused them or overwrote them.
    fn holesKnown(self: *const Self) u64 {
        var holes: u64 = self.skipped_entries;
        for (self.tracks.items) |track| {
            const claims = track.claims(track);
            if (claims.claimed > claims.slots) holes += claims.claimed - claims.slots;
        }
        return holes;
    }

    /// The track whose next undrained entry has the smallest global seq, or null
    /// when every track is drained. The same merge `Replayer.step` does, for the
    /// same reason: the file's order has to be the log's `seq` order, which is
    /// what lets it be read back in that order.
    fn nextToDrain(self: *Self) ?*TrackRef {
        var next: ?*TrackRef = null;
        var next_seq: u64 = std.math.maxInt(u64);
        for (self.tracks.items) |track| {
            const slot = track.drained_slots;
            if (slot >= track.len(track)) continue;
            const seq = track.entry(track, slot).seq;
            if (seq < next_seq) {
                next_seq = seq;
                next = track;
            }
        }
        return next;
    }

    /// A driver over this log's entries in global `seq` order, moving `manual`.
    ///
    /// Rewinds the tracks' own cursors on the way (the cursors and bindings live
    /// on the `TrackRef`), so a log has **one replay at a time** — the same
    /// discipline `Recorder.replay` has by taking a sink.
    ///
    /// The driver starts wide open: every track, the whole `seq` range. Narrow it
    /// with `Replayer.open`/`seekTo` (a range) and `Replayer.onlyTracks` (a set of
    /// tracks); both are counted, never silent.
    pub fn replayer(self: *Self, manual: *Clock.Manual) Replayer {
        for (self.tracks.items) |track| {
            track.cursor = 0;
            track.target = null;
            track.post = null;
        }
        return .{ .log = self, .manual = manual };
    }
};

/// One step of a replay, as the caller sees it: enough to log or assert the run,
/// and nothing that borrows the track (a step stays valid after the next one).
pub const Step = struct {
    seq: u64,
    clock_ms: i64,
    id: []const u8,
};

/// Why a step failed.
pub const StepError = mbox.SendError || error{
    /// A track overflowed: the log has a hole, and a replay of it would look
    /// complete without being one. Nothing was replayed (§11.6's rule, kept).
    LogIncomplete,
    /// Nothing is bound to the track this entry came from, and the entry is due
    /// to be delivered (it is inside the window and on a selected track).
    /// Skipping it would be the same lie in smaller letters — the entry would
    /// simply never arrive.
    UnboundTrack,
};

/// Why binding failed.
pub const BindError = error{
    /// No track was declared under that id — a typo, or workers built from a
    /// different declaration.
    UnknownTrack,
    /// The handle's `Message` is not the type this track recorded: handing the
    /// payload over would reinterpret memory.
    MessageTypeMismatch,
    /// The handle is one of the workers whose deliveries are in this very log.
    /// Replaying into it would *record* every replayed delivery, and since the
    /// new entries land behind the cursors, `step` would find them again and
    /// deliver them again — a replay that feeds itself and never ends. Bind a
    /// worker of the same type that is not recorded here (a fresh graph), which
    /// is also the only thing a replay means: the same workers, a new run.
    TargetIsInSourceLog,
    /// The track was written through a codec (`TrackRef.payload_codec`), so its
    /// payload is not a live value this process can point at. v1 never sets one.
    CodecRequired,
};

/// The `seq` range a replay covers: **`[from, to)` — `from` inclusive, `to`
/// exclusive**. The whole log is `{ .from = 0, .to = null }`, which is what a
/// driver starts with.
pub const Window = struct {
    /// The first `seq` replayed. Everything before it is skipped *and counted*
    /// (`Replayer.skippedBefore`): a range is a decision the caller made, so the
    /// size of what it left out is a number, not a shrug.
    from: u64 = 0,
    /// One past the last `seq` replayed; `null` means "to the end of the log".
    /// Entries at or after it are **not walked at all** — the replay stops
    /// there — so they are counted nowhere. Distinct from `from` on purpose:
    /// before `from` is discarded, from `to` on is simply not part of this
    /// replay (and still in the log, untouched).
    to: ?u64 = null,
};

/// Why a track filter was refused.
pub const FilterError = error{
    /// The filter named a track this log does not have. Validated eagerly so a
    /// typo fails here rather than screening out every delivery and looking
    /// like a deliberate filter.
    UnknownTrack,
};

/// Replays a `DeliveryLog` (§13.4): merge the tracks by global `seq`, move a
/// `Clock.Manual` to each entry's recorded stamp, and post each payload back to
/// the handle the caller bound for that id.
///
/// The mapping is the caller's (§13.3 Q3). The runtime never guesses it: a
/// "rebuild the graph and hope the spawn order matches" replay works exactly
/// until the graph changes, and then misdelivers in silence.
///
/// A replay can also be **narrowed** to a `seq` range (`open`/`seekTo`) and to a
/// set of tracks (`onlyTracks`) — looking at one worker, or at the window around
/// an incident, instead of replaying a whole run. Narrowing never removes a
/// binding check silently: whatever is screened out is skipped and counted
/// (`skippedBefore`, `skippedUnselected`), and an entry the driver *is* supposed
/// to deliver still needs a target (`error.UnboundTrack`).
pub const Replayer = struct {
    log: *DeliveryLog,
    manual: *Clock.Manual,

    /// What this driver replays: the seq range, and the tracks it delivers from.
    /// Set through `open`/`seekTo`/`onlyTracks`, which is what brings the cursors
    /// and the skip counters in line — assigning these fields directly would
    /// leave them disagreeing with `remaining()`.
    ///
    /// The defaults — every track, the whole seq range — are exactly what this
    /// driver did before the window and the filter existed.
    window: Window = .{},
    /// The tracks to deliver from, by `TrackSpec.id`, or `null` for all of them.
    /// The slice is the caller's (see `onlyTracks`).
    only: ?[]const []const u8 = null,

    /// Entries before `window.from`, passed over when the cursors were
    /// positioned. **Recomputed** by `seekTo`/`open` rather than accumulated, so
    /// it describes the current position and repeated seeks cannot double count.
    skipped_before: usize = 0,
    /// Entries walked past because their track is not in `only` — the cursor
    /// advances over them, they are never delivered, and they are counted here.
    /// Grows as the replay runs; reset by positioning.
    skipped_unselected: usize = 0,

    /// Bind the track `id` to the handle its deliveries go to on replay. The
    /// handle may be freshly spawned on another runtime — the driver only needs
    /// its `send`. A target that is recorded *into this log* is refused:
    /// `error.TargetIsInSourceLog` (see `BindError`).
    ///
    /// Last bind wins, deliberately: a second replay binds its own handles.
    pub fn bind(self: *Replayer, id: []const u8, handle: anytype) BindError!void {
        const H = @TypeOf(handle.*);
        if (!@hasField(H, "mailbox") or !@hasField(H, "track") or !@hasDecl(H, "Message"))
            @compileError("Replayer.bind expects a runtime worker handle (*Handle(W, capacity))");
        const track = self.log.find(id) orelse return error.UnknownTrack;
        if (track.payload_codec != null) return error.CodecRequired;
        if (!std.mem.eql(u8, track.message_type, @typeName(H.Message))) return error.MessageTypeMismatch;
        if (handle.track) |target_track| {
            for (self.log.tracks.items) |t| {
                if (t == target_track) return error.TargetIsInSourceLog;
            }
        }
        track.target = @ptrCast(handle);
        track.post = struct {
            fn post(target: *anyopaque, payload: *const anyopaque) mbox.SendError!void {
                const h: *H = @ptrCast(@alignCast(target));
                const msg: *const H.Message = @ptrCast(@alignCast(payload));
                return h.send(msg.*);
            }
        }.post;
    }

    /// Whether every track this driver would deliver from has a target. False
    /// means `step` would return `error.UnboundTrack` as soon as it reached an
    /// unbound **selected** track.
    ///
    /// Tracks the filter excludes are not part of this replay, so their missing
    /// bindings are not counted here — filters are as wide as they are only
    /// because a filtered-out track is skipped *and counted*. With no filter this
    /// is every track, i.e. the same answer it gave before the filter existed.
    pub fn isFullyBound(self: *const Replayer) bool {
        for (self.log.tracks.items) |track| {
            if (!self.selects(track)) continue;
            if (track.target == null) return false;
        }
        return true;
    }

    /// Deliveries this driver will still hand over: entries on the selected
    /// tracks, with `seq` in `[from, to)`, whose cursor has not passed them.
    ///
    /// Entries the filter screens out and entries before `from` are not counted
    /// — they are `skipped*` — and neither are entries at or after `to`, since
    /// the replay stops there. With no window and no filter this is
    /// `Σ(len − cursor)`, the number it has always been; with either set it can
    /// no longer be answered by subtraction, so it reads the entries (no
    /// allocation, no state change).
    pub fn remaining(self: *const Replayer) usize {
        var total: usize = 0;
        for (self.log.tracks.items) |track| {
            if (!self.selects(track)) continue;
            const n = track.len(track);
            var i = track.cursor;
            while (i < n) : (i += 1) {
                const seq = track.entry(track, i).seq;
                if (seq < self.window.from) continue;
                if (self.window.to) |to| {
                    if (seq >= to) continue;
                }
                total += 1;
            }
        }
        return total;
    }

    /// Replay from `from` on: put every track's cursor at its first entry whose
    /// `seq` is >= `from`, and count what that passed over (`skippedBefore`).
    /// `window.to` is left as it is — `open` sets both ends.
    ///
    /// Lets a caller start in the middle of a log (the entry before the one it
    /// cares about, the delivery that followed a bad state). Zero allocation, and
    /// idempotent: the cursors and both skip counters are recomputed from `from`,
    /// so seeking twice — or backwards, to re-replay a range — is just a scan.
    pub fn seekTo(self: *Replayer, from: u64) void {
        self.window.from = from;
        self.position();
    }

    /// `seekTo(from)` plus the exclusive end: replay exactly **`[from, to)`**,
    /// with `null` for "to the end of the log". `from >= to` is an empty window —
    /// the driver hands over nothing and `remaining()` is 0, which is an answer,
    /// not an error.
    pub fn open(self: *Replayer, from: u64, to: ?u64) void {
        self.window = .{ .from = from, .to = to };
        self.position();
    }

    /// Deliver only from these tracks (`TrackSpec.id`). A track that is not
    /// named here is **skipped, its cursor advanced, and counted**
    /// (`skippedUnselected`) — the driver never passes an entry over without a
    /// number to point at. An unselected track therefore does not need a
    /// binding: the filter is the caller saying "this worker is not part of this
    /// replay". A *selected* track that has no target still fails with
    /// `error.UnboundTrack` at the first of its entries — the filter narrows the
    /// check, it does not remove it.
    ///
    /// The ids are validated against the log here: a typo is
    /// `error.UnknownTrack`, not a replay that screens everything out and looks
    /// deliberate. An empty slice selects nothing (the whole log is skipped);
    /// `clearTrackFilter` goes back to all tracks.
    ///
    /// The slice is the caller's and must outlive the driver. Zero allocation.
    pub fn onlyTracks(self: *Replayer, ids: []const []const u8) FilterError!void {
        for (ids) |id| {
            if (self.log.find(id) == null) return error.UnknownTrack;
        }
        self.only = ids;
    }

    /// Deliver from every track again. The cursors do not move: anything the
    /// filter skipped is already behind the driver, and `skippedUnselected` keeps
    /// saying so.
    pub fn clearTrackFilter(self: *Replayer) void {
        self.only = null;
    }

    /// Entries this driver passed over without delivering since it was last
    /// positioned: `skippedBefore + skippedUnselected`.
    pub fn skipped(self: *const Replayer) usize {
        return self.skipped_before + self.skipped_unselected;
    }

    /// Entries before `window.from` — what `seekTo`/`open` passed over.
    pub fn skippedBefore(self: *const Replayer) usize {
        return self.skipped_before;
    }

    /// Entries walked past because their track is not in the filter.
    pub fn skippedUnselected(self: *const Replayer) usize {
        return self.skipped_unselected;
    }

    /// Is `track` part of this replay? `true` for every track when no filter is
    /// set.
    fn selects(self: *const Replayer, track: *const TrackRef) bool {
        const only = self.only orelse return true;
        for (only) |id| {
            if (std.mem.eql(u8, id, track.id)) return true;
        }
        return false;
    }

    /// Bring the cursors and both skip counters in line with `window`: every
    /// track starts at its first entry whose `seq` is >= `window.from`, and every
    /// entry before that is counted. The single place the counters are reset —
    /// and the reason a narrowed `remaining()` can be answered from the cursors.
    /// Allocates nothing; runs on the caller's thread.
    fn position(self: *Replayer) void {
        self.skipped_before = 0;
        self.skipped_unselected = 0;
        for (self.log.tracks.items) |track| {
            const n = track.len(track);
            var i: usize = 0;
            while (i < n and track.entry(track, i).seq < self.window.from) : (i += 1) {}
            self.skipped_before += i;
            track.cursor = i;
        }
    }

    /// Advance one delivery: take the smallest un-consumed `seq` across the
    /// tracks, move the manual clock to that entry's recorded stamp, and post its
    /// payload to the bound handle. Null when the log is exhausted — or when
    /// nothing inside `[from, to)` is left, which is the same thing as far as the
    /// caller is concerned.
    ///
    /// Entries outside the window or on an unselected track are **not** delivered:
    /// the driver advances their track's cursor, counts them (`skippedBefore` /
    /// `skippedUnselected`), and moves on, so `step` never hands the caller an
    /// entry it was not asked for, and never hides the ones it passed.
    ///
    /// **It never waits for anyone** — no sleep, no spin, no join: the driver
    /// orders *deliveries*, and where the handler then runs is the target
    /// worker's business. A caller that needs the handler to have finished before
    /// the next step (that is what makes §13.4's handler sequence assertable)
    /// owns that synchronization, on the target side.
    ///
    /// A failed post leaves the entry unconsumed, so the clock stays at the stamp
    /// that entry's delivery was recorded with and the caller may retry it.
    pub fn step(self: *Replayer) StepError!?Step {
        if (self.log.hasOverflowed()) return error.LogIncomplete;
        while (true) {
            var next: ?*TrackRef = null;
            var next_seq: u64 = std.math.maxInt(u64);
            for (self.log.tracks.items) |track| {
                if (track.cursor >= track.len(track)) continue;
                const seq = track.entry(track, track.cursor).seq;
                if (seq < next_seq) {
                    next_seq = seq;
                    next = track;
                }
            }
            const track = next orelse return null;
            // The smallest seq left is past the window: nothing in `[from, to)`
            // remains, and entries from `to` on are deliberately not walked.
            if (self.window.to) |to| {
                if (next_seq >= to) return null;
            }
            if (next_seq < self.window.from) {
                track.cursor += 1;
                self.skipped_before += 1;
                continue;
            }
            if (!self.selects(track)) {
                track.cursor += 1;
                self.skipped_unselected += 1;
                continue;
            }
            const post = track.post orelse return error.UnboundTrack;
            const entry = track.entry(track, track.cursor);
            self.manual.set(entry.clock_ms);
            try post(track.target.?, entry.payload);
            track.cursor += 1;
            return .{ .seq = entry.seq, .clock_ms = entry.clock_ms, .id = track.id };
        }
    }

    /// `step` until the log is exhausted; returns the number of deliveries handed
    /// over — entries the window or the filter screened out are not counted, and
    /// are visible in `skipped()` instead. The "just replay it" call, for a
    /// caller that does not need to inspect each delivery (§13.6 · 3: `step` is
    /// the primary driver, this rides along).
    pub fn replayAll(self: *Replayer) StepError!usize {
        var delivered: usize = 0;
        while (try self.step()) |_| delivered += 1;
        return delivered;
    }
};

// ─────────────────────────────────────────────────
// §13.10 — replay *from a segment file*: the reader half of `drainTo`
// ─────────────────────────────────────────────────

/// One delivery as a replay *from a file* hands it over: the same read-out
/// `Step` gives — the global seq, the recorded stamp, the track it belongs to —
/// plus the frame's own `kind`. The kind is the one the track recorded when it
/// was drained (§13.11), so this is the reader's *checked* view of it rather than
/// the only one: an in-memory `TrackEntry` carries the same value. It is reported
/// rather than acted on, since a message and a timer delivery go to the same
/// mailbox either way.
pub const LogStep = struct {
    seq: u64,
    clock_ms: i64,
    id: []const u8,
    kind: dlog.Kind,
};

/// The two type names behind a `MessageTypeMismatch`: what the declared codec's
/// message type is, and what the handle that was bound for it carries. Both are
/// `@typeName` readings — the same comparison `Replayer.bind` makes against
/// `TrackRef.message_type`, and the check that makes the payload hand-off below
/// a checked cast rather than a reinterpretation.
pub const TypeMismatch = struct {
    expected: []const u8,
    got: []const u8,
};

/// Why a replay *from a file* refused. Every one of them names the track it is
/// about (`ReplayFromLog.refusal`) and, when it is about a delivery, the seq
/// (`refusalSeq`) — so the errors themselves can stay payload-free, which is the
/// discipline `DeliveryLog.drainRefusal` already uses.
///
/// None of these can be answered by the file: it holds `track_id` and payload
/// bytes, and nothing about which codec wrote them (§13.10 D2 — the
/// reconciliation key is the id, and the caller owns the codec). So the reader
/// checks the things it *can* know, and refuses rather than guesses.
pub const LoadError = error{
    /// The id appears in no record of this file — a typo, or a file from another
    /// run. Validated eagerly, like `Replayer.onlyTracks`, so a typo fails here
    /// instead of reading as "this track delivered nothing".
    UnknownTrack,
    /// A delivery is due from a track the caller bound a handle for but declared
    /// **no codec** for. The bytes cannot become a value without one, and
    /// skipping them would hand the caller a replay that quietly lost a worker's
    /// part of the run — the strongest form of the "no silent skip" rule.
    CodecRequired,
    /// A delivery is due from a track with no binding at all. Distinct from
    /// `CodecRequired` on purpose: one says "nothing is bound", the other says
    /// "a target is bound and its payloads still cannot be read".
    UnboundTrack,
    /// The seq chain has a gap — this file does not hold a delivery that the
    /// global sequence says happened (§13.10 D3). The default is to refuse; a
    /// caller that knows why may `allowHoles` and have every crossed seq counted.
    LogHasHoles,
    /// Two codecs were declared for one id, and their names disagree. The bytes
    /// of every entry read afterwards would be reinterpreted, so last-declaration-
    /// wins (the rule `bind` has for targets) is not a thing here.
    CodecNameMismatch,
    /// The handle bound for an id carries a different `Message` type than the
    /// codec declared for it (`mismatch` has both names).
    MessageTypeMismatch,
    /// The reader's own bookkeeping had no room — the `seq` order it sorts at
    /// `init`, or the per-track list. The only allocation failure this type
    /// reports; everything else a step allocates is the caller's codec's.
    OutOfMemory,
};

/// One track of the file, as this reader knows it: what the caller *declared*
/// (`setCodec`) and where the decoded values go (`bindDecoded`). The two halves
/// are separate calls because they are separate facts — the codec a file's bytes
/// were written by, and the handle this run delivers them to — exactly as the
/// writer side declares a track and then attaches a codec to it.
///
/// Either half may come first: a handle bound before its codec is not an error at
/// bind time (nothing is unknown yet), and the delivery it can never decode is
/// refused *by name* when it comes due. That is why the two type-name fields are
/// kept apart instead of collapsed into one.
const LoadedTrack = struct {
    /// The caller's id slice (the `setCodec`/`bindDecoded` argument), borrowed for
    /// the reader's life and the key every lookup compares against.
    id: []const u8,
    /// `Codec(E).name` of the codec declared for this id, or `""` while none is.
    codec_name: []const u8 = "",
    /// `@typeName(E)` of that codec's message type, or `""` while none is
    /// declared. Checked against `target_type`.
    message_type: []const u8 = "",
    /// `@typeName(H.Message)` of the bound handle, or `""` while none is bound.
    target_type: []const u8 = "",
    /// Decode one payload and post it — monomorphised for this track's codec at
    /// `setCodec`, so `C.decode`'s result *is* the declared `E` (a codec whose
    /// `decode` returns something else fails to compile right there, which is
    /// §13.10's answer to "the codec does not match the track").
    deliver: ?*const fn (state: *LoadedTrack, allocator: std.mem.Allocator, bytes: []const u8) anyerror!void = null,
    /// Where a decoded payload goes: the bound handle, erased (see `post`).
    target: ?*anyopaque = null,
    /// §13.10 D5's by-value hand-off, the same thunk shape `Replayer.bind`
    /// builds: dereference the pointer and call `send` with the **value**, so the
    /// value in `deliver`'s frame is copied into the mailbox and the frame may die
    /// on return. `deliver` is the only caller, and it is the frame that owns the
    /// decoded value's lifetime.
    post: ?*const fn (target: *anyopaque, payload: *const anyopaque) mbox.SendError!void = null,
};

/// Replays a delivery log **from its segment file** (`docs/RUNTIME.md` §13.10):
/// the reader half of §13.9's `drainTo`, for a track whose payloads left the
/// process as bytes and have to come back through a codec.
///
/// A new type rather than a second mode of `Replayer` (`§13.10 D1`): the data
/// source is different (segment records plus a decode, not pointers into live
/// rings), so the window/filter/cursor arithmetic and the
/// `log.len() == delivered + skipped + …` identity `Replayer` is pinned on do
/// not carry over. What *is* shared is the contract, and it is deliberately the
/// same three pieces: an id → handle binding the caller owns, a `post` thunk that
/// hands the message over **by value**, and a hole that has to be visible.
///
/// **Load then replay, not tailing** (§13.10 D4): the records are read once
/// (`dlog.scan`) and live in memory, ordered by global `seq` here. This cannot
/// follow a log another process is still writing — a scan is a snapshot.
///
/// **It holds an allocator, and that is a deliberate difference from `Replayer`**
/// (§13.10 D6) rather than a regression. `Replayer` hands over a pointer into a
/// live ring, which is why it can be pinned by a test that forbids it to
/// allocate at all. Here the payload is bytes in a file and `Codec.decode` — the
/// caller's, whose shape §13.9 D2 fixed — takes an allocator and returns a value.
/// The allocator is used for exactly two things: the `seq` order built once at
/// `init`, and whatever a codec asks for while a step decodes. Nothing is held
/// between steps, and `deinit` gives the reader's own two buffers back.
pub const ReplayFromLog = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// The clock every replayed handler reads time off. Moved to a record's stamp
    /// before its delivery, the same contract `Replayer.step` has — a recorded
    /// hour replays at CPU speed, with the stamps in their recorded order.
    manual: *Clock.Manual,
    /// The file's verified records, **borrowed**: the caller keeps the `Scan` (and
    /// its payload bytes) alive for as long as it steps this reader.
    records: []const dlog.Record,
    /// `records`' indices, ordered by global `seq` (§13.10 D4). The file's own
    /// order is append order, which is only *usually* `seq` order, and the file is
    /// the caller's — so the indices are sorted rather than the records.
    order: []usize,
    /// Position in `order`.
    cursor: usize = 0,
    /// Per-id declarations and bindings, in first-mention order. Indices rather
    /// than pointers are handed out by the helpers below: the list grows, and a
    /// pointer into an `ArrayList` would not survive the next `setCodec`.
    tracks: std.ArrayList(LoadedTrack) = .empty,
    /// The last `seq` this reader delivered, or null before the first one. Holes
    /// are gaps in this chain.
    last_seq: ?u64 = null,
    /// Missing seqs behind the cursor, counted when the delivery that follows them
    /// is handed over.
    crossed_holes: u64 = 0,
    /// Missing seqs between the cursor's predecessor and the entry at the cursor.
    /// Recomputed by every `step` rather than accumulated, because a refused hole
    /// leaves the cursor exactly where it is: the caller may allow holes and step
    /// again, and the same gap must not be counted twice.
    pending_holes: u64 = 0,
    /// Records whose `seq` was already delivered. Unreachable through `drainTo`
    /// (`Writer.append` refuses a seq that does not increase), but a hand-built
    /// record slice can hold one, and re-delivering it would make the file look
    /// like twice the traffic. Counted instead, never silently replayed.
    duplicates: u64 = 0,
    /// The lowest missing seq, or null while the file has none. Sticky: what is
    /// missing does not stop being missing.
    first_hole_seq: ?u64 = null,
    /// Whether stepping over a gap is allowed. `false` — refuse — is the default
    /// (§13.10 D3): a replay that jumps a hole silently is a replay that looks
    /// complete without being one.
    allow_holes: bool = false,
    /// The track id the last refusal was about, or null when there was none. Set
    /// by every refusing call and cleared where it is set, so it is never stale
    /// (the discipline `DeliveryLog.drainRefusal` has). Read back with
    /// `refusal()` — a field and a method cannot share a name.
    refusal_id: ?[]const u8 = null,
    /// The seq the last refusal was about, when it was about a delivery: the
    /// missing seq for `LogHasHoles`, the entry's own seq otherwise.
    refusal_seq: ?u64 = null,
    /// The two type names behind a `MessageTypeMismatch`, or null.
    mismatch: ?TypeMismatch = null,

    /// A reader over `records`, delivering into handles the caller binds. Allocates
    /// the `seq` order (one index per record, §13.10 D4) and nothing else; a
    /// record slice with no records is a valid, empty replay.
    pub fn init(allocator: std.mem.Allocator, manual: *Clock.Manual, records: []const dlog.Record) error{OutOfMemory}!Self {
        const order = try allocator.alloc(usize, records.len);
        errdefer allocator.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        // Stable, so two records that claim one seq keep the file's own order —
        // which is what lets `step` tell "the same delivery twice" from "the next
        // one" with a single comparison.
        std.mem.sort(usize, order, records, seqAscending);
        return .{ .allocator = allocator, .manual = manual, .records = records, .order = order };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.order);
        self.tracks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Declare the codec this track's payloads were written with — the reader-side
    /// counterpart of `DeliveryLog.setCodec`, and the only place a payload format
    /// enters a replay from a file, since the file holds no codec name
    /// (§13.10 D2).
    ///
    /// `E` is named by the caller because the reader has no track object to read
    /// it off (`addTrack(spec, E, capacity)` did that on the writer side): it goes
    /// into `message_type` and is what `bindDecoded` checks a handle against. The
    /// compiler checks it the other way round at the same time — `C.decode`'s
    /// result is assigned to an `E` here, so a codec for some *other* type does
    /// not build.
    pub fn setCodec(self: *Self, id: []const u8, comptime C: type, comptime E: type) LoadError!void {
        self.reset();
        comptime checkCodec(E, C);
        if (!self.inFile(id)) return self.refuse(id, error.UnknownTrack);
        const slot = try self.slotFor(id);
        const state = &self.tracks.items[slot];
        if (state.codec_name.len != 0 and !std.mem.eql(u8, state.codec_name, C.name))
            return self.refuse(id, error.CodecNameMismatch);
        if (state.target_type.len != 0 and !std.mem.eql(u8, state.target_type, @typeName(E))) {
            self.mismatch = .{ .expected = state.target_type, .got = @typeName(E) };
            return self.refuse(id, error.MessageTypeMismatch);
        }
        state.codec_name = C.name;
        state.message_type = @typeName(E);
        state.deliver = struct {
            /// Decode this track's payload and hand it over. §13.10 D5: the decoded
            /// value is a temporary **in this frame** — the pointer that reaches
            /// `post` is live for the length of the call, `post` dereferences it,
            /// and `Handle.send(message: Message)` takes the message by value. The
            /// frame may therefore be reused the moment this returns.
            fn deliver(state_: *LoadedTrack, allocator: std.mem.Allocator, bytes: []const u8) anyerror!void {
                var value: E = try C.decode(allocator, bytes);
                const post = state_.post orelse return error.UnboundTrack;
                return post(state_.target.?, @ptrCast(&value));
            }
        }.deliver;
    }

    /// Bind the handle this track's decoded deliveries go to. The handle may be
    /// freshly spawned on another runtime — this reader only needs its `send`.
    ///
    /// A target bound without a codec is accepted and then refused per delivery
    /// (`error.CodecRequired`): binding order is the caller's business, and a
    /// refusal that names what is missing is better than a bind that has to guess
    /// whether a codec is coming.
    ///
    /// The `Message` type is checked against the codec's declared `E`
    /// (`error.MessageTypeMismatch`, both names in `mismatch`): the erased `post`
    /// thunk dereferences the payload as this handle's `Message`, so this check is
    /// what makes that cast a checked one.
    pub fn bindDecoded(self: *Self, id: []const u8, handle: anytype) LoadError!void {
        const H = @TypeOf(handle.*);
        if (!@hasField(H, "mailbox") or !@hasField(H, "track") or !@hasDecl(H, "Message"))
            @compileError("ReplayFromLog.bindDecoded expects a runtime worker handle (*Handle(W, capacity))");
        self.reset();
        if (!self.inFile(id)) return self.refuse(id, error.UnknownTrack);
        const slot = try self.slotFor(id);
        const state = &self.tracks.items[slot];
        const handle_type = @typeName(H.Message);
        if (state.message_type.len != 0 and !std.mem.eql(u8, state.message_type, handle_type)) {
            self.mismatch = .{ .expected = state.message_type, .got = handle_type };
            return self.refuse(id, error.MessageTypeMismatch);
        }
        state.target_type = handle_type;
        state.target = @ptrCast(handle);
        state.post = struct {
            fn post(target: *anyopaque, payload: *const anyopaque) mbox.SendError!void {
                const h: *H = @ptrCast(@alignCast(target));
                const msg: *const H.Message = @ptrCast(@alignCast(payload));
                // A replay is a `send`, whatever the frame's `kind` said: the file
                // records that a timer *fired in the recorded run*, and this line
                // makes a fresh, ordinary delivery in the target runtime. Copying
                // the frame's kind would be the target claiming a timer it never
                // armed — and the reader that wants the recorded kind has it, in
                // `LogStep.kind` (§13.11). The target is normally a graph spawned
                // without `.record` (nothing to record into); the delivery kind of
                // a target that did declare one is this runtime's own, recorded by
                // `Handle.enqueue` like every other send.
                return h.send(msg.*);
            }
        }.post;
    }

    /// Deliver the next record in global `seq` order: move the manual clock to
    /// the stamp it was recorded with and post the decoded payload to the bound
    /// handle. Null when the file is exhausted.
    ///
    /// A refusal consumes nothing, so the same entry is offered again after the
    /// caller fixes what was missing (binds the handle, declares the codec,
    /// `allowHoles`) — the same retry shape `Replayer.step` has, and the reason
    /// the cursor only ever advances on a delivered entry.
    ///
    /// The error set is the union of this file's refusals and **whatever the
    /// callers' codecs raise**: a decode is the caller's code, so `anyerror` is
    /// the honest bound. Nothing sleeps and no wall clock is read.
    pub fn step(self: *Self) anyerror!?LogStep {
        self.reset();
        self.pending_holes = 0;
        while (self.cursor < self.order.len) {
            const record = self.records[self.order[self.cursor]];
            if (self.last_seq) |last| {
                if (record.seq <= last) {
                    // A seq the reader has already delivered. The file's writer
                    // cannot produce one; a hand-built slice can. Counted, not
                    // replayed (§13.10 D3's rule, applied to the other direction).
                    self.duplicates += 1;
                    self.cursor += 1;
                    continue;
                }
                if (record.seq > last + 1) {
                    self.pending_holes = record.seq - last - 1;
                    if (self.first_hole_seq == null) self.first_hole_seq = last + 1;
                    if (!self.allow_holes) {
                        // The refusal names the *following* delivery's track: it is
                        // the one the caller will be asked to deliver next.
                        self.refusal_seq = last + 1;
                        return self.refuse(record.track_id, error.LogHasHoles);
                    }
                }
            }
            const slot = self.slotIndex(record.track_id) orelse {
                self.refusal_seq = record.seq;
                return self.refuse(record.track_id, error.UnboundTrack);
            };
            const state = &self.tracks.items[slot];
            if (state.target == null) {
                self.refusal_seq = record.seq;
                return self.refuse(record.track_id, error.UnboundTrack);
            }
            const deliver = state.deliver orelse {
                self.refusal_seq = record.seq;
                return self.refuse(record.track_id, error.CodecRequired);
            };
            // A frame's stamp is in nanoseconds (`dlog.Record.recorded_ns`); a
            // track's and a `Clock`'s are in milliseconds. `drainTo` is the only
            // place the two meet, and this is the way back.
            const clock_ms = @divTrunc(record.recorded_ns, std.time.ns_per_ms);
            self.manual.set(clock_ms);
            try deliver(state, self.allocator, record.payload);

            self.cursor += 1;
            self.last_seq = record.seq;
            self.crossed_holes += self.pending_holes;
            self.pending_holes = 0;
            return .{ .seq = record.seq, .clock_ms = clock_ms, .id = record.track_id, .kind = record.kind };
        }
        return null;
    }

    /// `step` until the file is exhausted; returns how many deliveries were handed
    /// over. The "just replay it" call, for a caller that does not need to inspect
    /// each one (§13.6 · 3: `step` is the primary driver, this rides along).
    pub fn replayAll(self: *Self) anyerror!usize {
        var delivered: usize = 0;
        while (try self.step()) |_| delivered += 1;
        return delivered;
    }

    /// Let the reader step over a gap instead of refusing (`error.LogHasHoles`).
    /// The gap is still counted (`holesSeen`) and its first seq is still named
    /// (`refusalSeq`), so a caller that declares "I know this file has holes" pays
    /// for the declaration with a number — §13.10 D3's whole point.
    pub fn allowHoles(self: *Self) void {
        self.allow_holes = true;
    }

    /// Back to refusing. A reader narrowed by hand is the same reader: nothing is
    /// silently skipped by default.
    pub fn refuseHoles(self: *Self) void {
        self.allow_holes = false;
    }

    /// Deliveries the file does not hold, seen so far: the gaps the reader has
    /// walked over, plus the gap (if any) in front of the entry the cursor is at —
    /// so a refusal reports how much is missing too. A gap *after* the last record
    /// is invisible here: nothing in the file says the run continued
    /// (`drainTo`'s report is where that end-of-file hole is named).
    pub fn holesSeen(self: *const Self) u64 {
        return self.crossed_holes + self.pending_holes;
    }

    /// The share of `holesSeen` behind the cursor — what the reader really stepped
    /// over, as opposed to what it has merely found.
    pub fn crossedHoles(self: *const Self) u64 {
        return self.crossed_holes;
    }

    /// The lowest seq this file does not have, or null while it has none.
    pub fn firstHoleSeq(self: *const Self) ?u64 {
        return self.first_hole_seq;
    }

    /// Records whose seq was already delivered, and which were therefore counted
    /// instead of replayed.
    pub fn duplicateSeqs(self: *const Self) u64 {
        return self.duplicates;
    }

    /// Deliveries still to hand over.
    pub fn remaining(self: *const Self) usize {
        return self.order.len - self.cursor;
    }

    /// Whether every track that appears in this file has both a codec and a
    /// target. False means a step will refuse as soon as it reaches a delivery
    /// from a track that does not — `CodecRequired` for a bound-but-undecodable
    /// one, `UnboundTrack` for one with nothing bound at all.
    pub fn isFullyBound(self: *const Self) bool {
        for (self.records) |record| {
            const slot = self.slotIndex(record.track_id) orelse return false;
            const state = &self.tracks.items[slot];
            if (state.deliver == null or state.target == null) return false;
        }
        return true;
    }

    /// The track id the last refusal was about, or null.
    pub fn refusal(self: *const Self) ?[]const u8 {
        return self.refusal_id;
    }

    /// The seq the last refusal was about, or null when it was not about a
    /// delivery. For `LogHasHoles` it is the **first missing** seq.
    pub fn refusalSeq(self: *const Self) ?u64 {
        return self.refusal_seq;
    }

    /// The two type names behind a `MessageTypeMismatch`, or null.
    pub fn typeMismatch(self: *const Self) ?TypeMismatch {
        return self.mismatch;
    }

    /// `seq` ascending, with the file's order as the tie-break (`std.mem.sort` is
    /// stable and the order starts out as `0, 1, 2, …`).
    fn seqAscending(records: []const dlog.Record, a: usize, b: usize) bool {
        return records[a].seq < records[b].seq;
    }

    /// Whether this file holds a delivery from `id` — the check behind
    /// `error.UnknownTrack`. A reader is a reader *of a file*, so an id the file
    /// does not mention is a typo or a file from another run, not a track that
    /// happened to be quiet.
    fn inFile(self: *const Self, id: []const u8) bool {
        for (self.records) |record| {
            if (std.mem.eql(u8, record.track_id, id)) return true;
        }
        return false;
    }

    /// The declared/bound track for `id`, or null.
    fn slotIndex(self: *const Self, id: []const u8) ?usize {
        for (self.tracks.items, 0..) |state, i| {
            if (std.mem.eql(u8, state.id, id)) return i;
        }
        return null;
    }

    /// The index of `id`'s track, appended if this is the first mention. An index
    /// rather than a pointer: the list grows, and nothing may hold a pointer into
    /// it across a call that can append.
    fn slotFor(self: *Self, id: []const u8) error{OutOfMemory}!usize {
        if (self.slotIndex(id)) |i| return i;
        try self.tracks.append(self.allocator, .{ .id = id });
        return self.tracks.items.len - 1;
    }

    /// Clear the last refusal and name `id` as this one's subject. The errors
    /// themselves carry no payload — there is no room in an error set — so this is
    /// the "which track?" half, exactly as `DeliveryLog.drainRefusal` is for
    /// `error.CodecRequired`.
    fn refuse(self: *Self, id: []const u8, err: LoadError) LoadError {
        self.refusal_id = id;
        return err;
    }

    /// Start a call with a clean refusal. Same rule as the drain's: a refusal is
    /// about *this* call, never the last one.
    fn reset(self: *Self) void {
        self.refusal_id = null;
        self.refusal_seq = null;
        self.mismatch = null;
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const Time = @import("../core/Time.zig");
const hot_bus_mod = @import("hot_bus.zig");

/// Sink harness with fixed storage, so a test asserts after the replay without
/// an allocator on either side.
const Taken = struct {
    events: [16]u32 = @splat(0),
    times: [16]i64 = @splat(0),
    seen: usize = 0,

    fn sink(self: *@This(), entry: Recorder(u32, 16).Entry) void {
        self.events[self.seen] = entry.event;
        self.times[self.seen] = entry.clock_ms;
        self.seen += 1;
    }
};

test "record/replay round-trips every payload in seq order" {
    const payloads = [_]u32{ 7, 11, 13, 42 };
    var src = Clock.Manual{ .now_ms = 0 };
    var rec = Recorder(u32, 16).init(src.clock());

    for (payloads, 0..) |p, i| {
        src.set(100 + @as(i64, @intCast(i)) * 5);
        try rec.record(p);
    }
    try std.testing.expectEqual(payloads.len, rec.len());

    for (rec.entries(), 0..) |entry, i| {
        try std.testing.expectEqual(@as(u64, @intCast(i)), entry.seq);
        try std.testing.expectEqual(payloads[i], entry.event);
        try std.testing.expectEqual(@as(i64, 100 + @as(i64, @intCast(i)) * 5), entry.clock_ms);
    }

    var dst = Clock.Manual{ .now_ms = -1 };
    var taken = Taken{};
    rec.replay(&dst, &taken, Taken.sink);

    try std.testing.expectEqual(payloads.len, taken.seen);
    try std.testing.expectEqualSlices(u32, &payloads, taken.events[0..taken.seen]);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 100, 105, 110, 115 }, taken.times[0..taken.seen]);
}

test "a full recorder reports error.Full instead of dropping silently" {
    var rec = Recorder(u32, 4).init(.monotonic);
    for (0..4) |i| try rec.record(@intCast(i));

    try std.testing.expect(rec.full());
    try std.testing.expectError(error.Full, rec.record(99));
    try std.testing.expectError(error.Full, rec.record(100));
    try std.testing.expect(rec.hasOverflowed());

    // The refused events are gone, but nothing was overwritten to make room.
    try std.testing.expectEqual(@as(usize, 4), rec.len());
    try std.testing.expectEqual(@as(usize, 4), rec.entries().len);
    var expected: u32 = 0;
    for (rec.entries()) |entry| {
        try std.testing.expectEqual(expected, entry.event);
        expected += 1;
    }
}

test "seq is strictly monotonic across records and refusals" {
    var rec = Recorder(u32, 3).init(.monotonic);
    try rec.record(1);
    try rec.record(2);
    try rec.record(3);
    try std.testing.expectEqual(@as(u64, 3), rec.seq());

    try std.testing.expectError(error.Full, rec.record(4));
    // The refused record still consumed a sequence number: seq never repeats.
    try std.testing.expectEqual(@as(u64, 4), rec.seq());

    var previous: u64 = 0;
    for (rec.entries(), 0..) |entry, i| {
        if (i > 0) try std.testing.expect(entry.seq > previous);
        previous = entry.seq;
    }
    try std.testing.expectEqual(@as(u64, 2), previous);
}

test "replay drives Clock.Manual to the recorded times — it never sleeps" {
    // A timer scenario: an event at t=0 schedules a 500 ms timer, the fire
    // arrives at t=500, and one more event follows at t=501. Recorded across a
    // half-second of *recorded* time; replay must not spend that time waiting.
    const R = Recorder(u32, 8);
    var src = Clock.Manual{ .now_ms = 0 };
    var rec = R.init(src.clock());
    try rec.record(0); // scheduled
    src.advance(500);
    try rec.record(500); // fired
    src.advance(1);
    try rec.record(501);

    const Harness = struct {
        clock: *Clock.Manual,
        due_ms: i64 = 500,
        fired: usize = 0,
        seen_clock: [8]i64 = @splat(0),
        seen: usize = 0,

        fn sink(self: *@This(), entry: R.Entry) void {
            self.seen_clock[self.seen] = self.clock.now_ms;
            self.seen += 1;
            if (entry.event >= self.due_ms) self.fired += 1;
        }
    };

    var dst = Clock.Manual{ .now_ms = -1 };
    var h = Harness{ .clock = &dst };
    const started = Time.monotonicNowMilliseconds();
    rec.replay(&dst, &h, Harness.sink);
    const elapsed = Time.monotonicNowMilliseconds() - started;

    try std.testing.expectEqual(@as(usize, 3), h.seen);
    // The clock the sink observed is the recorded one, per entry.
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 500, 501 }, h.seen_clock[0..h.seen]);
    try std.testing.expectEqual(@as(usize, 2), h.fired);
    try std.testing.expectEqual(@as(i64, 501), dst.now_ms);
    // 501 ms of recorded time replayed in well under half a second of wall time:
    // the clock was moved by the log, not waited on.
    try std.testing.expect(elapsed < 500);
}

/// Collects whatever a `HotBus(u32, 2)` publishes.
const Gather = struct {
    buf: *[8]u32,
    n: usize = 0,

    fn sink(self: *@This()) hot_bus_mod.HotBus(u32, 2).Sink {
        return .{ .ctx = @ptrCast(self), .deliver = deliver };
    }

    fn deliver(ctx: *anyopaque, event: u32) bool {
        const self: *Gather = @ptrCast(@alignCast(ctx));
        self.buf[self.n] = event;
        self.n += 1;
        return true;
    }
};

test "HotBus publish behaves the same with and without a recorder attached" {
    const Bus = hot_bus_mod.HotBus(u32, 2);

    // One identical run of the bus — subscribe, (optionally) attach, freeze,
    // publish 1..3 — with the same assertions in both cases. An attached
    // recorder must not change what `publish` reports to its callers.
    const Case = struct {
        fn run(with_recorder: bool, rec: *Recorder(u32, 8)) !struct {
            returns: [3]bool,
            recorder: bool,
        } {
            var collected: [8]u32 = @splat(0);
            var gather = Gather{ .buf = &collected };
            var bus = Bus.init();
            try bus.subscribeSink(gather.sink());
            if (with_recorder) try bus.attachRecorder(rec);
            bus.freeze();

            var returns: [3]bool = undefined;
            for (0..3) |i| {
                returns[i] = try bus.publish(@intCast(i + 1));
                try std.testing.expect(returns[i]);
            }
            try std.testing.expectEqual(with_recorder, bus.hasRecorder());
            try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3 }, collected[0..gather.n]);
            try std.testing.expectEqual(@as(u64, 3), bus.stats().published);
            try std.testing.expectEqual(@as(u64, 0), bus.stats().record_dropped);
            return .{ .returns = returns, .recorder = bus.hasRecorder() };
        }
    };

    var rec = Recorder(u32, 8).init(.monotonic);
    const plain = try Case.run(false, &rec);
    try std.testing.expectEqual(@as(usize, 0), rec.len());

    const logged = try Case.run(true, &rec);
    try std.testing.expectEqualSlices(bool, &plain.returns, &logged.returns);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, true, true }, &logged.returns);
    try std.testing.expect(!plain.recorder);
    try std.testing.expect(logged.recorder);

    try std.testing.expectEqual(@as(usize, 3), rec.len());
    for (rec.entries(), 0..) |entry, i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), entry.event);
}

test "a recorder is wired before freeze — attachRecorder is error.Frozen after it" {
    const Bus = hot_bus_mod.HotBus(u32, 1);
    var rec = Recorder(u32, 4).init(.monotonic);

    var bus = Bus.init();
    bus.freeze();
    try std.testing.expectError(hot_bus_mod.Error.Frozen, bus.attachRecorder(&rec));
    try std.testing.expect(!bus.hasRecorder());

    var fresh = Bus.init();
    try fresh.attachRecorder(&rec);
    try std.testing.expect(fresh.hasRecorder());
}

test "a refused record is visible on the bus, not swallowed" {
    const Bus = hot_bus_mod.HotBus(u32, 1);
    var bus = Bus.init();
    var rec = Recorder(u32, 2).init(.monotonic);
    try bus.attachRecorder(&rec);
    bus.freeze();

    try std.testing.expect(try bus.publish(1));
    try std.testing.expect(try bus.publish(2));
    // Third publish: the log is full. The bus must say so — in the return value
    // and in the counter — rather than keep publishing an unlogged stream.
    try std.testing.expect(!try bus.publish(3));

    const s = bus.stats();
    try std.testing.expectEqual(@as(u64, 3), s.published);
    try std.testing.expectEqual(@as(u64, 1), s.record_dropped);
    try std.testing.expect(rec.hasOverflowed());
    try std.testing.expectEqual(@as(usize, 2), rec.len());
}

test "concurrent producers get distinct sequence numbers and lose nothing" {
    const producers = 4;
    const per_producer = 500;
    const total = producers * per_producer;
    const R = Recorder(u32, total);

    var rec = R.init(.monotonic);
    const Worker = struct {
        fn run(r: *R, tag: u32) void {
            var i: u32 = 0;
            while (i < per_producer) : (i += 1) r.record(tag) catch return;
        }
    };

    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &rec, @as(u32, @intCast(i)) });
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, total), rec.len());
    try std.testing.expect(!rec.hasOverflowed());
    var seen: [total]bool = @splat(false);
    for (rec.entries(), 0..) |entry, i| {
        // Slot == seq, so the log has no holes and is already in replay order.
        try std.testing.expectEqual(@as(u64, @intCast(i)), entry.seq);
        const slot: usize = @intCast(entry.seq);
        try std.testing.expect(!seen[slot]);
        seen[slot] = true;
    }
}

// ─────────────────────────────────────────────────
// §13 — delivery tracks
// ─────────────────────────────────────────────────

test "Track: entries carry the log's global sequence, not their slot index" {
    var log = DeliveryLog.init(std.testing.allocator, .monotonic);
    defer log.deinit();

    const A = try log.addTrack(.{ .id = "a", .capacity = 4 }, u32, 4);
    const B = try log.addTrack(.{ .id = "b", .capacity = 4 }, i64, 4);
    try std.testing.expectEqual(@as(usize, 2), log.trackCount());
    try std.testing.expectEqual(u32, Track(u32, 4).Event);
    try std.testing.expectEqual(@as(usize, 4), Track(u32, 4).max_entries);
    try std.testing.expect(Track(u32, 4).codec == null);
    try std.testing.expect(log.find("a") == &A.ref);
    try std.testing.expect(log.find("nope") == null);

    // Interleaved across two tracks: a track's *slots* are 0..n-1, while the
    // sequence on its entries is the log's global one — which is what makes two
    // tracks mergeable without either of them knowing about the other.
    try A.record(10);
    try B.record(20);
    try A.record(11);

    try std.testing.expectEqual(@as(usize, 2), A.len());
    try std.testing.expectEqualSlices(u64, &.{ 0, 2 }, &.{ A.entries()[0].seq, A.entries()[1].seq });
    try std.testing.expectEqual(@as(u32, 10), A.entries()[0].event);
    try std.testing.expectEqual(@as(u32, 11), A.entries()[1].event);
    try std.testing.expectEqual(@as(u64, 1), B.entries()[0].seq);
    try std.testing.expectEqual(@as(i64, 20), B.entries()[0].event);
    try std.testing.expectEqual(@as(usize, 3), log.len());

    // The erased view is what a handle holds: same values, plus the payload as a
    // pointer into the track's ring.
    const erased = log.find("a").?;
    try std.testing.expectEqual(@as(usize, 2), erased.len(erased));
    try std.testing.expect(!erased.has_overflowed(erased));
    const entry = erased.entry(erased, 1);
    try std.testing.expectEqual(@as(u64, 2), entry.seq);
    // A `record` with no kind is a `send`-shaped delivery, and the erased view
    // says so — the kind is one of the stamps it hands out (§13.11).
    try std.testing.expectEqual(dlog.Kind.message, entry.kind);
    const payload: *const u32 = @ptrCast(@alignCast(entry.payload));
    try std.testing.expectEqual(@as(u32, 11), payload.*);

    // ...and the erased `record` thunk is the whole send-path cost of a track. It
    // carries the kind as its third argument: `.timer` here, so the assertion
    // below cannot pass by the thunk dropping it and defaulting to `.message`.
    var value: u32 = 12;
    try erased.record(erased, @ptrCast(&value), .timer);
    try std.testing.expectEqual(@as(u32, 12), A.entries()[2].event);
    try std.testing.expectEqual(dlog.Kind.timer, A.entries()[2].kind);
    try std.testing.expectEqual(dlog.Kind.message, A.entries()[0].kind);
}

test "Track.recordKind: the ring carries the kind, and record() means .message" {
    var log = DeliveryLog.init(std.testing.allocator, .monotonic);
    defer log.deinit();
    const track = try log.addTrack(.{ .id = "a", .capacity = 4 }, u32, 4);

    // The one-argument `record` is the `send*` shape, and it says so (§13.11);
    // the kind is a per-slot field, so the two can differ within one ring.
    try track.record(1);
    try track.recordKind(2, .timer);
    try track.record(3);

    try std.testing.expectEqualSlices(dlog.Kind, &.{ .message, .timer, .message }, &.{
        track.entries()[0].kind,
        track.entries()[1].kind,
        track.entries()[2].kind,
    });
    // The erased view hands the same value out — it is what `drainTo` reads.
    try std.testing.expectEqual(dlog.Kind.timer, track.ref.entry(&track.ref, 1).kind);

    // What the field costs, measured rather than promised: the entry is
    // `{ seq: u64, clock_ms: i64, kind: Kind, event: E }`, so the kind lands in
    // the padding a small `E` already had (0 extra bytes for a `u32` message) and
    // pushes an 8-byte-aligned `E` onto the next 8-byte boundary (+8 for a `u64`).
    // An `E` of any alignment in between behaves like one of these two. The
    // absolute sizes are asserted too, so the numbers `docs/RUNTIME.md` §13.11
    // publishes are the ones this test measures rather than a reading of them.
    const WithoutKind = struct { seq: u64, clock_ms: i64, event: u32 };
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Track(u32, 4).Entry));
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(Track(u32, 4).Entry) - @sizeOf(WithoutKind),
    );
    const WithoutKind64 = struct { seq: u64, clock_ms: i64, event: u64 };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Track(u64, 4).Entry));
    try std.testing.expectEqual(
        @as(usize, 8),
        @sizeOf(Track(u64, 4).Entry) - @sizeOf(WithoutKind64),
    );
}

test "DeliveryLog: a refusal is counted, and a full track stops instead of overwriting" {
    var log = DeliveryLog.init(std.testing.allocator, .monotonic);
    defer log.deinit();

    const spec: TrackSpec = .{ .id = "a", .capacity = 2 };
    const track = try log.addTrack(spec, u32, 2);
    // Two workers under one id would split a worker's deliveries and replay them
    // as one, so the declaration is refused rather than merged.
    try std.testing.expectError(error.DuplicateTrackId, log.addTrack(spec, u32, 2));
    try std.testing.expectEqual(@as(usize, 1), log.trackCount());

    try track.record(1);
    try track.record(2);
    try std.testing.expect(track.full());
    try std.testing.expectError(error.Full, track.record(3));
    try std.testing.expect(track.hasOverflowed());
    try std.testing.expectEqual(@as(u64, 1), log.refusedCount());
    try std.testing.expect(log.hasOverflowed());

    // Nothing was overwritten to make room, and the refused delivery is gone.
    try std.testing.expectEqual(@as(usize, 2), log.len());
    try std.testing.expectEqual(@as(u32, 1), track.entries()[0].event);
    try std.testing.expectEqual(@as(u32, 2), track.entries()[1].event);
    // The refused record still consumed a sequence number: seq never repeats.
    try std.testing.expectEqual(@as(u64, 3), log.sequencer.peek());

    // Handing a track back releases it and its id — the spawn-failure path.
    log.removeTrack(&track.ref);
    try std.testing.expectEqual(@as(usize, 0), log.trackCount());
    try std.testing.expect(log.find("a") == null);
}

test "Track: concurrent producers get distinct global sequences across tracks" {
    const producers = 2;
    const per_producer = 500;
    var log = DeliveryLog.init(std.testing.allocator, .monotonic);
    defer log.deinit();
    const A = try log.addTrack(.{ .id = "a", .capacity = per_producer }, u32, per_producer);
    const B = try log.addTrack(.{ .id = "b", .capacity = per_producer }, u32, per_producer);

    const Worker = struct {
        fn run(track: *Track(u32, per_producer), tag: u32) void {
            var i: u32 = 0;
            while (i < per_producer) : (i += 1) track.record(tag) catch return;
        }
    };

    var threads: [producers]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Worker.run, .{ A, 1 });
    threads[1] = try std.Thread.spawn(.{}, Worker.run, .{ B, 2 });
    for (threads) |t| t.join();

    // One shared sequence, two independent rings: everything was recorded, and
    // the sequence numbers are one permutation of 0..2N-1 — no duplicates, none
    // missing, whatever order the two producers interleaved in.
    try std.testing.expectEqual(@as(usize, 2 * per_producer), log.len());
    try std.testing.expect(!log.hasOverflowed());
    var seen: [2 * per_producer]bool = @splat(false);
    for ([_]*Track(u32, per_producer){ A, B }) |track| {
        for (track.entries()) |entry| {
            const seq: usize = @intCast(entry.seq);
            try std.testing.expect(seq < seen.len);
            try std.testing.expect(!seen[seq]);
            seen[seq] = true;
        }
    }
    try std.testing.expectEqual(@as(u64, 2 * per_producer), log.sequencer.peek());
}

// ─────────────────────────────────────────────────
// §13 — positioning and filtering a replay
// ─────────────────────────────────────────────────

/// A stand-in for `*Handle(W, capacity)`. `bind` needs three things from a
/// target — a `mailbox` field, a `track` field, and a `Message` decl with a
/// `send` — so a narrowed replay can be asserted here with no runtime, no
/// threads and nothing to synchronize.
///
/// A real handle's `track` is non-null precisely when that worker is recorded,
/// which is what makes it a `TargetIsInSourceLog`; a fake leaves it null, i.e.
/// "a fresh graph", the only thing a replay may deliver into.
fn FakeTarget(comptime M: type) type {
    return struct {
        const Self = @This();

        pub const Message = M;
        mailbox: u8 = 0,
        track: ?*TrackRef = null,
        sent: [16]M = @splat(0),
        n: usize = 0,

        pub fn send(self: *Self, message: M) mbox.SendError!void {
            self.sent[self.n] = message;
            self.n += 1;
        }

        fn taken(self: *const Self) []const M {
            return self.sent[0..self.n];
        }
    };
}

test "Replayer.open: only [from, to) is replayed, and what that passed over is counted" {
    // The log stamps entries from the clock it was built with, so a manual one
    // makes the `clock_ms` assertions below values instead of "whatever the wall
    // clock said while the test ran".
    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(std.testing.allocator, clk.clock());
    defer log.deinit();
    const track = try log.addTrack(.{ .id = "a", .capacity = 8 }, u32, 8);

    for (0..8) |i| {
        clk.set(@intCast(i * 10));
        try track.record(@intCast(i));
    }
    // One track, so its slots are the log's seq values: entry i carries seq i.

    var manual = Clock.Manual{ .now_ms = 0 };
    var target = FakeTarget(u32){};
    var rp = log.replayer(&manual);
    try rp.bind("a", &target);

    // Nothing narrowed: the whole log, i.e. the number `remaining()` has always
    // returned (Σ len − cursor).
    try std.testing.expectEqual(@as(usize, 8), rp.remaining());
    try std.testing.expectEqual(@as(usize, 0), rp.skipped());

    // [2, 6): seq 0 and 1 are skipped and counted, 2..5 are delivered, and 6/7
    // are never walked — `to` is a stop, not a filter.
    rp.open(2, 6);
    try std.testing.expectEqual(@as(usize, 4), rp.remaining());
    try std.testing.expectEqual(@as(usize, 2), rp.skippedBefore());
    try std.testing.expectEqual(@as(usize, 0), rp.skippedUnselected());

    try std.testing.expectEqual(@as(usize, 4), try rp.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5 }, target.taken());
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());
    try std.testing.expectEqual(@as(?Step, null), try rp.step());
    try std.testing.expectEqual(@as(usize, 2), rp.skipped());
    // The entries from `to` on are untouched, not consumed: the log is the same
    // length it was, and a second driver can still replay all of it.
    try std.testing.expectEqual(@as(usize, 8), log.len());
    // The clock stopped at the last entry actually delivered (seq 5, t = 50).
    try std.testing.expectEqual(@as(i64, 50), manual.now_ms);

    // `from` inclusive, `to` exclusive — one entry at a time.
    rp.open(7, 8);
    try std.testing.expectEqual(@as(usize, 1), rp.remaining());
    try std.testing.expectEqual(@as(usize, 7), rp.skippedBefore());
    try std.testing.expectEqual(@as(usize, 1), try rp.replayAll());
    try std.testing.expectEqual(@as(u32, 7), target.taken()[target.n - 1]);

    // `from` past the last entry, to the end: an empty window is an answer, not
    // an error — nothing to hand over, and the count says so.
    rp.open(8, null);
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());
    try std.testing.expectEqual(@as(usize, 0), try rp.replayAll());
    try std.testing.expectEqual(@as(usize, 8), rp.skippedBefore());

    // …and an inverted range is empty too, rather than replaying backwards.
    rp.open(6, 2);
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());
    try std.testing.expectEqual(@as(usize, 0), try rp.replayAll());
    try std.testing.expectEqual(@as(usize, 6), rp.skippedBefore());

    // Positioning repositions rather than accumulates: after all of that, a
    // driver told to start at 2 says "two entries are before the position", not
    // "many were skipped at some point".
    const before = target.n;
    rp.open(2, null);
    try std.testing.expectEqual(@as(usize, 2), rp.skippedBefore());
    try std.testing.expectEqual(@as(usize, 6), rp.remaining());
    try std.testing.expectEqual(@as(usize, 6), try rp.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7 }, target.taken()[before..]);
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());

    // `seekTo` is the same positioning with `to` left alone — here it has none,
    // so the range is open to the end again.
    rp.seekTo(0);
    try std.testing.expectEqual(@as(usize, 0), rp.skippedBefore());
    try std.testing.expectEqual(@as(usize, 8), rp.remaining());
}

test "Replayer.onlyTracks: one track is delivered, the others are skipped and counted" {
    // Manual clock on the log itself: the recorded stamps are then the values
    // below, which is what lets the driver's final clock reading be asserted.
    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(std.testing.allocator, clk.clock());
    defer log.deinit();
    const book = try log.addTrack(.{ .id = "book", .capacity = 8 }, u32, 8);
    const risk = try log.addTrack(.{ .id = "risk", .capacity = 8 }, u64, 8);

    // Interleaved, one shared sequence: "risk" holds seq 0 and 2, "book" 1, 3, 4.
    clk.set(100);
    try risk.record(20);
    clk.set(200);
    try book.record(1);
    clk.set(300);
    try risk.record(40);
    clk.set(400);
    try book.record(2);
    clk.set(500);
    try book.record(3);

    var manual = Clock.Manual{ .now_ms = 0 };
    var book_target = FakeTarget(u32){};
    var risk_target = FakeTarget(u64){};
    var rp = log.replayer(&manual);
    try rp.bind("book", &book_target);
    try rp.bind("risk", &risk_target);

    // "Replay the book track": the other track's deliveries are skipped, its
    // cursor advances over them, and the count says how many.
    try rp.onlyTracks(&.{"book"});
    try std.testing.expectEqual(@as(usize, 3), rp.remaining());
    try std.testing.expectEqual(@as(usize, 3), try rp.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, book_target.taken());
    try std.testing.expectEqual(@as(usize, 0), risk_target.n);
    try std.testing.expectEqual(@as(usize, 2), rp.skippedUnselected());
    try std.testing.expectEqual(@as(usize, 2), rp.skipped());
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());
    try std.testing.expectEqual(@as(i64, 500), manual.now_ms);

    // A filter that names a track the log does not have fails here instead of
    // screening every delivery out, and it leaves the filter in force alone.
    try std.testing.expectError(error.UnknownTrack, rp.onlyTracks(&.{"bookk"}));

    // An empty filter selects nothing — deliberately, visibly, and with the
    // whole log counted as skipped rather than silently replayed.
    var null_manual = Clock.Manual{ .now_ms = 0 };
    var skipping = log.replayer(&null_manual);
    try skipping.onlyTracks(&.{});
    try std.testing.expectEqual(@as(usize, 0), skipping.remaining());
    try std.testing.expectEqual(@as(usize, 0), try skipping.replayAll());
    try std.testing.expectEqual(@as(usize, 5), skipping.skippedUnselected());

    // `isFullyBound` follows the filter: a filtered-out track is not part of this
    // replay, so its missing target is not a missing binding …
    var manual2 = Clock.Manual{ .now_ms = 0 };
    var only_book = FakeTarget(u32){};
    var rp2 = log.replayer(&manual2);
    try std.testing.expect(!rp2.isFullyBound());
    try rp2.bind("book", &only_book);
    try std.testing.expect(!rp2.isFullyBound()); // `risk` is still owed a target
    try rp2.onlyTracks(&.{"book"});
    try std.testing.expect(rp2.isFullyBound());
    try std.testing.expectEqual(@as(usize, 3), try rp2.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, only_book.taken());

    // … but a *selected* track with no target still stops the replay: the filter
    // narrows the binding check, it does not remove it.
    var manual3 = Clock.Manual{ .now_ms = 0 };
    var rp3 = log.replayer(&manual3);
    try rp3.onlyTracks(&.{"book"});
    try std.testing.expectError(error.UnboundTrack, rp3.step());
    // The entry it walked past on the way to that failure is counted (seq 0 is
    // "risk"): an error is not a licence to lose track of what was skipped.
    try std.testing.expectEqual(@as(usize, 1), rp3.skippedUnselected());

    // Clearing the filter goes back to every track — the ones already walked past
    // are behind the driver, and the counter still accounts for them.
    var manual4 = Clock.Manual{ .now_ms = 0 };
    var both_book = FakeTarget(u32){};
    var both_risk = FakeTarget(u64){};
    var rp4 = log.replayer(&manual4);
    try rp4.bind("book", &both_book);
    try rp4.bind("risk", &both_risk);
    try rp4.onlyTracks(&.{"book"});
    try std.testing.expectEqual(@as(u64, 1), (try rp4.step()).?.seq);
    rp4.clearTrackFilter();
    try std.testing.expectEqual(@as(usize, 3), try rp4.replayAll());
    try std.testing.expectEqualSlices(u64, &.{40}, both_risk.taken());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, both_book.taken());
    try std.testing.expectEqual(@as(usize, 1), rp4.skippedUnselected()); // seq 0, skipped while filtered
}

test "Replayer: a window inside a filtered log leaves no entry unaccounted for" {
    var log = DeliveryLog.init(std.testing.allocator, .monotonic);
    defer log.deinit();
    const a = try log.addTrack(.{ .id = "a", .capacity = 8 }, u32, 8);
    const b = try log.addTrack(.{ .id = "b", .capacity = 8 }, u32, 8);

    var clk = Clock.Manual{ .now_ms = 0 };
    for (0..7) |i| {
        clk.set(@intCast(100 + @as(i64, @intCast(i)) * 10));
        if (i % 2 == 0) try a.record(@intCast(i)) else try b.record(@intCast(i));
    }
    // seq 0, 2, 4, 6 on "a" and seq 1, 3, 5 on "b" — interleaved, so a window or
    // a filter leaves holes in what actually gets delivered.
    try std.testing.expectEqual(@as(usize, 4), a.len());
    try std.testing.expectEqual(@as(usize, 3), b.len());

    var manual = Clock.Manual{ .now_ms = 0 };
    var target = FakeTarget(u32){};
    var rp = log.replayer(&manual);
    try rp.bind("a", &target);

    // [1, 6) on "a": seq 2 and 4 are deliverable, seq 0 is before the window,
    // seq 1/3/5 are on the unselected track, seq 6 sits at `to`.
    rp.open(1, 6);
    try rp.onlyTracks(&.{"a"});
    try std.testing.expectEqual(@as(usize, 2), rp.remaining());
    try std.testing.expectEqual(@as(usize, 2), try rp.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, target.taken());
    try std.testing.expectEqual(@as(usize, 1), rp.skippedBefore()); // seq 0
    try std.testing.expectEqual(@as(usize, 3), rp.skippedUnselected()); // seq 1, 3, 5
    try std.testing.expectEqual(@as(usize, 4), rp.skipped());
    try std.testing.expectEqual(@as(usize, 0), rp.remaining());
    try std.testing.expectEqual(@as(?Step, null), try rp.step());

    // Every entry is in exactly one bucket: delivered, skipped, or untouched at
    // and after `to`. The holes are visible, which is the point — a narrowed
    // replay that looked complete would be worse than no replay.
    try std.testing.expectEqual(@as(usize, 1), log.len() - target.n - rp.skipped());
    try std.testing.expectEqual(@as(usize, 7), log.len());

    // A second driver on the same log, wide open, still sees all seven: the
    // narrowing never wrote anything back into it.
    var manual2 = Clock.Manual{ .now_ms = 0 };
    var all_a = FakeTarget(u32){};
    var all_b = FakeTarget(u32){};
    var rp2 = log.replayer(&manual2);
    try rp2.bind("a", &all_a);
    try rp2.bind("b", &all_b);
    try std.testing.expectEqual(@as(usize, 7), rp2.remaining());
    try std.testing.expectEqual(@as(usize, 7), try rp2.replayAll());
    try std.testing.expectEqual(@as(usize, 0), rp2.skipped());
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6 }, all_a.taken());
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, all_b.taken());
}

test "Replayer: narrowing and stepping take no allocator, so they cannot allocate" {
    // The driver holds no allocator at all — the reason `seekTo`/`onlyTracks`/
    // `step`/`remaining` cannot quietly become an allocation path. Pinning it by
    // construction: the log's allocator refuses everything from here on, and the
    // whole narrowed replay still runs.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var log = DeliveryLog.init(probe.allocator(), .monotonic);
    defer log.deinit();
    defer probe.fail_index = std.math.maxInt(usize);

    const a = try log.addTrack(.{ .id = "a", .capacity = 16 }, u32, 16);
    const b = try log.addTrack(.{ .id = "b", .capacity = 16 }, u32, 16);
    for (0..8) |i| {
        if (i % 2 == 0) try a.record(@intCast(i)) else try b.record(@intCast(i));
    }

    var manual = Clock.Manual{ .now_ms = 0 };
    var target = FakeTarget(u32){};
    var rp = log.replayer(&manual);

    probe.fail_index = probe.alloc_index;
    try rp.bind("a", &target);
    try rp.onlyTracks(&.{"a"});
    rp.open(1, 6);
    _ = rp.remaining();
    _ = rp.skipped();
    const delivered = try rp.replayAll();
    rp.clearTrackFilter();
    rp.seekTo(0);
    _ = rp.remaining();

    // …and the walk really ran: a green result cannot mean "nothing happened".
    try std.testing.expectEqual(@as(usize, 2), delivered);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, target.taken());
}

// ─────────────────────────────────────────────────
// §13.9 — the codec contract, and draining a track to a segment file
// ─────────────────────────────────────────────────

/// A throwaway segment directory, unique per test call. `std.testing.tmpDir`
/// names it from random bytes under `.zig-cache/tmp`, so the test binaries
/// `zig build test` runs in parallel cannot collide on it; `cleanup` removes the
/// tree, including the subdirectory `Writer.open` creates under it.
const DrainDir = struct {
    tmp: std.testing.TmpDir,
    path_buf: [160]u8 = undefined,

    fn init() DrainDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn path(self: *DrainDir) ![]const u8 {
        return std.fmt.bufPrint(&self.path_buf, ".zig-cache/tmp/{s}/drain", .{self.tmp.sub_path[0..]});
    }

    fn deinit(self: *DrainDir) void {
        self.tmp.cleanup();
    }
};

/// §13.9 D2 in practice: a `u32` message as four little-endian bytes. The shape
/// — `name`, `version`, `encode`, `decode` — is the whole contract, and nothing
/// in the runtime reads the payload.
const U32Codec = struct {
    pub const name: []const u8 = "test:u32";
    pub const version: u16 = 1;

    pub fn encode(allocator: std.mem.Allocator, value: u32) ![]u8 {
        const bytes = try allocator.alloc(u8, @sizeOf(u32));
        std.mem.writeInt(u32, bytes[0..4], value, .little);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
        _ = allocator;
        if (bytes.len != @sizeOf(u32)) return error.BadPayloadLength;
        return std.mem.readInt(u32, bytes[0..4], .little);
    }
};

/// A second codec for a second `Message`: one track's bytes are not another's,
/// and `payload_codec` is the only thing that says which is which.
const I64Codec = struct {
    pub const name: []const u8 = "test:i64";
    pub const version: u16 = 1;

    pub fn encode(allocator: std.mem.Allocator, value: i64) ![]u8 {
        const bytes = try allocator.alloc(u8, @sizeOf(i64));
        std.mem.writeInt(i64, bytes[0..8], value, .little);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !i64 {
        _ = allocator;
        if (bytes.len != @sizeOf(i64)) return error.BadPayloadLength;
        return std.mem.readInt(i64, bytes[0..8], .little);
    }
};

test "drainTo: two tracks reach a segment file, encoded, in one global seq order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        // 40-byte frames against a 512-byte ceiling: the ceiling really rotates,
        // so reading the records back below is a cross-segment read.
        .max_segment_bytes = 512,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();

    const book = try log.addTrack(.{ .id = "book", .capacity = 4 }, u32, 4);
    const risk = try log.addTrack(.{ .id = "risk", .capacity = 16 }, i64, 16);
    try log.setCodec(book, U32Codec);
    try log.setCodec(risk, I64Codec);

    // §13.9 D2's identity lands on the erased view — which is all a drain holds.
    try std.testing.expectEqualStrings(U32Codec.name, log.find("book").?.payload_codec.?);
    try std.testing.expectEqualStrings(I64Codec.name, log.find("risk").?.payload_codec.?);

    // 24 deliveries, one per `i`: every third goes to the short track, so it
    // overflows while the long one keeps all sixteen of its own. Each delivery's
    // seq *is* its `i` — the log hands out one number per record attempt — which
    // is what makes the file assertable record by record below.
    for (0..24) |i| {
        clk.set(@intCast(i));
        if (i % 3 == 0) {
            book.record(@intCast(i)) catch |err| try std.testing.expectEqual(error.Full, err);
        } else {
            try risk.record(@intCast(i));
        }
    }
    try std.testing.expect(book.hasOverflowed());
    try std.testing.expectEqual(@as(usize, 4), book.len());
    try std.testing.expectEqual(@as(usize, 16), risk.len());
    try std.testing.expectEqual(@as(u64, 4), log.refusedCount());

    var writer = try dlog.Writer.open(allocator, io, config);
    const report = try log.drainTo(&writer);
    const segments = writer.segmentCount();
    writer.deinit();

    // Everything the rings kept, and nothing else: twenty records, four holes.
    try std.testing.expectEqual(@as(usize, 20), report.records);
    try std.testing.expectEqual(@as(u64, 4), report.holes);
    // The same number by the rings' own arithmetic: the counter `Track.record`
    // bumps and the claim arithmetic `drainTo` reads are two views of one fact.
    try std.testing.expectEqual(log.refusedCount(), report.holes);
    // The short track's 5th..8th attempts are i = 12, 15, 18, 21, so the file's
    // completeness ends at 12.
    try std.testing.expectEqual(@as(?u64, 12), report.first_hole_seq);
    // §13.9 D4: the cursor is per track, and it knows how far it got.
    try std.testing.expectEqual(@as(?u64, 9), log.drainedUpto("book")); // its last kept seq
    try std.testing.expectEqual(@as(?u64, 23), log.drainedUpto("risk"));
    try std.testing.expectEqual(@as(?u64, null), log.drainedUpto("nope"));
    try std.testing.expect(segments > 1); // the ceiling rotated

    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    // The storage layer's own verdict: no torn tail, no corrupt frame.
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 20), scanned.records.len);

    const refused_seqs = [_]u64{ 12, 15, 18, 21 };
    var seen: [24]bool = @splat(false);
    var previous: ?u64 = null;
    for (scanned.records) |record| {
        try std.testing.expect(record.seq < 24);
        try std.testing.expect(!seen[record.seq]); // once each, not twice
        seen[record.seq] = true;
        if (previous) |p| try std.testing.expect(record.seq > p); // file order is seq order
        previous = record.seq;

        // The stamps: the clock was moved to `i` before each delivery, and a frame
        // carries nanoseconds while a track carries milliseconds.
        try std.testing.expectEqual(@as(i64, @intCast(record.seq)) * std.time.ns_per_ms, record.recorded_ns);

        // The bytes decode back through the track's *own* erased codec thunk, and
        // the delivery was the value `seq`, so a round trip is exact.
        if (std.mem.eql(u8, record.track_id, "book")) {
            var value: u32 = 0;
            try log.find("book").?.decode.?(allocator, record.payload, @ptrCast(&value));
            try std.testing.expectEqual(@as(u32, @intCast(record.seq)), value);
        } else {
            try std.testing.expectEqualStrings("risk", record.track_id);
            var value: i64 = 0;
            try log.find("risk").?.decode.?(allocator, record.payload, @ptrCast(&value));
            try std.testing.expectEqual(@as(i64, @intCast(record.seq)), value);
        }
    }
    for (0..24) |i| {
        const refused = std.mem.indexOfScalar(u64, &refused_seqs, @intCast(i)) != null;
        try std.testing.expectEqual(!refused, seen[i]);
    }
    // Both ends of the hole: the read-out named seq 12, and the records really do
    // not have it — while its neighbours are there, so this is not "the file is
    // empty" in disguise either.
    try std.testing.expect(!seen[report.first_hole_seq.?]);
    try std.testing.expect(seen[report.first_hole_seq.? - 1]);
    try std.testing.expect(seen[report.first_hole_seq.? + 1]);
}

test "drainTo: the second call writes only what the first one left" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();
    const tape = try log.addTrack(.{ .id = "tape", .capacity = 16 }, u32, 16);
    try log.setCodec(tape, U32Codec);

    var writer = try dlog.Writer.open(allocator, io, config);

    for (0..3) |i| {
        clk.set(@intCast(i * 10));
        try tape.record(@intCast(100 + i));
    }
    const first = try log.drainTo(&writer);
    try std.testing.expectEqual(@as(usize, 3), first.records); // exact, not "at least"
    try std.testing.expectEqual(@as(u64, 2), writer.lastSeq());
    try std.testing.expectEqual(@as(?u64, 2), log.drainedUpto("tape"));
    try std.testing.expectEqual(@as(u64, 0), first.holes);
    try std.testing.expectEqual(@as(?u64, null), first.first_hole_seq);

    for (0..4) |i| {
        clk.set(@intCast(100 + i * 10));
        try tape.record(@intCast(200 + i));
    }
    const second = try log.drainTo(&writer);
    // Four — not seven: the three entries the first call wrote are behind the
    // cursor. Rewriting them is not merely wasteful; the writer would refuse the
    // seq, because it does not increase.
    try std.testing.expectEqual(@as(usize, 4), second.records);
    try std.testing.expectEqual(@as(u64, 6), writer.lastSeq());
    try std.testing.expectEqual(@as(u64, 6), log.drainedUpto("tape").?);

    // A third call with nothing new is a no-op, not a rewrite.
    const third = try log.drainTo(&writer);
    try std.testing.expectEqual(@as(usize, 0), third.records);
    try std.testing.expectEqual(@as(u64, 6), writer.lastSeq());
    writer.deinit();

    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 7), scanned.records.len);
    for (scanned.records, 0..) |record, i| {
        try std.testing.expectEqual(@as(u64, @intCast(i)), record.seq);
        var value: u32 = 0;
        try log.find("tape").?.decode.?(allocator, record.payload, @ptrCast(&value));
        const expected: u32 = if (i < 3) @intCast(100 + i) else @intCast(200 + (i - 3));
        try std.testing.expectEqual(expected, value);
    }
}

test "drainTo: a track with no codec is refused by name, and the other track is untouched" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();
    const raw = try log.addTrack(.{ .id = "raw", .capacity = 8 }, u32, 8);
    const book = try log.addTrack(.{ .id = "book", .capacity = 8 }, u32, 8);
    try log.setCodec(book, U32Codec);
    try std.testing.expectEqual(@as(?[]const u8, null), log.find("raw").?.payload_codec);

    // A codec is attached to a track of *this* log, and refused for another's: a
    // codec on a foreign track would only show up as a drain writing another
    // log's entries.
    var other = DeliveryLog.init(allocator, .monotonic);
    defer other.deinit();
    try std.testing.expectError(error.UnknownTrack, other.setCodec(raw, U32Codec));

    try raw.record(1);
    try book.record(2);

    var writer = try dlog.Writer.open(allocator, io, config);
    // Refused, and named: `raw` has something to write and no way to write it.
    try std.testing.expectError(error.CodecRequired, log.drainTo(&writer));
    try std.testing.expectEqualStrings("raw", log.drainRefusal().?);

    // Nothing went out — not even from `book`, which *can* be drained. A
    // half-drained log would be one whose cursor sits past entries the writer
    // would then refuse to take a second time.
    try std.testing.expectEqual(@as(u64, 0), writer.lastSeq());
    try std.testing.expectEqual(@as(?u64, null), log.drainedUpto("book"));
    try std.testing.expectEqual(@as(usize, 0), book.ref.drained_slots);

    // The declaration can still be fixed, and then both tracks go out together:
    // the refusal cost the log a call, not an entry.
    try log.setCodec(raw, U32Codec);
    const report = try log.drainTo(&writer);
    try std.testing.expectEqual(@as(usize, 2), report.records);
    try std.testing.expectEqual(@as(?[]const u8, null), log.drainRefusal());
    try std.testing.expectEqual(@as(u64, 1), writer.lastSeq());
    writer.deinit();

    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 2), scanned.records.len);
    try std.testing.expectEqualStrings("raw", scanned.records[0].track_id);
    try std.testing.expectEqualStrings("book", scanned.records[1].track_id);
    var value: u32 = 0;
    try log.find("book").?.decode.?(allocator, scanned.records[1].payload, @ptrCast(&value));
    try std.testing.expectEqual(@as(u32, 2), value);
}

test "drainTo: an overflow is a hole, with a seq the file really does not have" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();
    const tape = try log.addTrack(.{ .id = "tape", .capacity = 4 }, u32, 4);
    try log.setCodec(tape, U32Codec);

    // Six deliveries into a ring of four: seq 0..3 are kept, 4 and 5 are refused.
    for (0..6) |i| {
        clk.set(@intCast(i));
        tape.record(@intCast(i)) catch |err| try std.testing.expectEqual(error.Full, err);
    }
    try std.testing.expectEqual(@as(usize, 4), tape.len());
    try std.testing.expect(tape.hasOverflowed());

    var writer = try dlog.Writer.open(allocator, io, config);
    const report = try log.drainTo(&writer);
    writer.deinit();

    // What the read-out says…
    try std.testing.expectEqual(@as(usize, 4), report.records);
    try std.testing.expect(report.holes > 0);
    try std.testing.expectEqual(@as(u64, 2), report.holes);
    try std.testing.expectEqual(@as(?u64, 4), report.first_hole_seq);
    try std.testing.expectEqual(log.refusedCount(), report.holes);

    // …and what the file has. The two ends have to agree, or a hole count is a
    // number nobody can act on: the refused seqs are exactly the missing ones,
    // and the one the read-out named is among them.
    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 4), scanned.records.len);
    var seen: [6]bool = @splat(false);
    for (scanned.records) |record| {
        try std.testing.expect(record.seq < 6);
        try std.testing.expect(!seen[record.seq]);
        seen[record.seq] = true;
    }
    for (0..4) |i| try std.testing.expect(seen[i]);
    try std.testing.expect(!seen[report.first_hole_seq.?]);
    try std.testing.expect(!seen[5]);
}

test "drainTo: an entry the file has already moved past is counted, not written back" {
    // A directory that already holds a later seq — a log an earlier run drained
    // into, or (the shape that matters in production) a track whose entry became
    // readable only after a higher seq had gone out. The format's order *is* the
    // file's order: `Writer.append` refuses a seq that does not increase, because
    // otherwise the file could no longer be read back in `seq` order. So these
    // deliveries can never be in the file — the drain steps over them and counts
    // them, instead of failing, and instead of writing them out of order.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();

    var writer = try dlog.Writer.open(allocator, io, config);
    try writer.append(.{ .seq = 500, .track_id = "tape", .kind = .message, .recorded_ns = 0, .payload = "" });

    const tape = try log.addTrack(.{ .id = "tape", .capacity = 4 }, u32, 4);
    try log.setCodec(tape, U32Codec);
    try tape.record(0);
    try tape.record(1);

    const report = try log.drainTo(&writer);
    try std.testing.expectEqual(@as(usize, 0), report.records);
    try std.testing.expectEqual(@as(u64, 2), report.holes);
    // Seq 0 *is* a hole here, and the read-out says 0 rather than "none" — which
    // is why "no hole" is not spelled `0` on the field.
    try std.testing.expectEqual(@as(?u64, 0), report.first_hole_seq);
    // The cursor moved past both, so a retry does not chase them again.
    try std.testing.expectEqual(@as(usize, 2), tape.ref.drained_slots);
    try std.testing.expectEqual(@as(?u64, null), log.drainedUpto("tape"));
    try std.testing.expectEqual(@as(u64, 500), writer.lastSeq());
    writer.deinit();

    // The file still holds exactly what it did, in its own order.
    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 1), scanned.records.len);
    try std.testing.expectEqual(@as(u64, 500), scanned.records[0].seq);
}

test "drainTo: the codec's buffers all come back, and record never takes one" {
    // §13.9 D6, measured rather than promised: `drainTo` hands the log's
    // allocator to the codec's `encode` and frees what comes back, while the
    // record path — `Handle.send*`, the hot path — never sees it at all (§13.9
    // D1). The instrument is the counting allocator `alloc_contract_test.zig`
    // uses for the runtime's other producer paths.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(probe.allocator(), clk.clock());
    const tape = try log.addTrack(.{ .id = "tape", .capacity = 8 }, u32, 8);
    try log.setCodec(tape, U32Codec);

    const live_before = probe.allocations - probe.deallocations;
    var value: u32 = 0;
    while (value < 6) : (value += 1) {
        clk.set(@intCast(value));
        try tape.record(value);
    }
    try std.testing.expectEqual(live_before, probe.allocations - probe.deallocations);

    // The writer is not this test's subject, so it gets the real allocator.
    var writer = try dlog.Writer.open(std.testing.allocator, std.testing.io, config);
    const allocs_before = probe.allocations;
    const frees_before = probe.deallocations;
    const live = allocs_before - frees_before;

    const report = try log.drainTo(&writer);
    try std.testing.expectEqual(@as(usize, 6), report.records);

    // Six entries, one buffer each: the encodes ran …
    try std.testing.expectEqual(@as(usize, 6), probe.allocations - allocs_before);
    // … and every buffer was given back before the next entry.
    try std.testing.expectEqual(@as(usize, 6), probe.deallocations - frees_before);
    try std.testing.expectEqual(live, probe.allocations - probe.deallocations);
    writer.deinit();

    // The whole log balances too, once the log's own storage is given back: no
    // leak, and nothing the drain left behind.
    log.deinit();
    try std.testing.expectEqual(probe.allocations, probe.deallocations);
}

// ─────────────────────────────────────────────────
// §13.10 — replay from a segment file
// ─────────────────────────────────────────────────

/// A wide message, for the test that scribbles over the stack its payload was
/// decoded in: one word would be too small to be sure the scribble landed on it,
/// and sixteen bytes make a stale read a value that is wrong in every field rather
/// than a plausible one.
const WideCodec = struct {
    pub const name: []const u8 = "test:wide";
    pub const version: u16 = 1;

    pub fn encode(allocator: std.mem.Allocator, value: u128) ![]u8 {
        const bytes = try allocator.alloc(u8, @sizeOf(u128));
        std.mem.writeInt(u128, bytes[0..16], value, .little);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !u128 {
        _ = allocator;
        if (bytes.len != @sizeOf(u128)) return error.BadPayloadLength;
        return std.mem.readInt(u128, bytes[0..16], .little);
    }
};

/// A codec whose `decode` genuinely uses the allocator it is handed: one scratch
/// buffer per call, given back before the value returns. That is what turns the
/// counting allocator in the test below into a reading about the reader's wiring
/// (does the reader hand its own allocator down?) instead of about this codec.
const ScratchCodec = struct {
    pub const name: []const u8 = "test:scratch";
    pub const version: u16 = 1;

    pub fn encode(allocator: std.mem.Allocator, value: u32) ![]u8 {
        const bytes = try allocator.alloc(u8, @sizeOf(u32));
        std.mem.writeInt(u32, bytes[0..4], value, .little);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
        if (bytes.len != @sizeOf(u32)) return error.BadPayloadLength;
        const scratch = try allocator.alloc(u8, 64);
        defer allocator.free(scratch);
        @memcpy(scratch[0..4], bytes[0..4]);
        return std.mem.readInt(u32, scratch[0..4], .little);
    }
};

/// Overwrite the stack a just-returned call used. Two nested calls, because the
/// frame that is of interest was a *callee* of the reader's step: the leaf's frame
/// then lands at the depth the decoder's did, and the buffer is far larger than
/// the temporary it has to bury.
fn scribbleStack() void {
    scribbleLeaf();
}

fn scribbleLeaf() void {
    var buf: [1024]u8 = @splat(0xA5);
    std.mem.doNotOptimizeAway(&buf);
}

test "ReplayFromLog: a drained file replays in global seq order, and a hole is refused before it is crossed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = DrainDir.init();
    defer dir.deinit();
    const config: dlog.Config = .{
        .dir_path = try dir.path(),
        .max_segment_bytes = 512,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var log = DeliveryLog.init(allocator, clk.clock());
    defer log.deinit();
    // The same shape the drain tests use: a short track that overflows *between*
    // the long track's entries, so the file has interior gaps rather than only a
    // missing tail — a tail gap is invisible to a reader (nothing in the file says
    // the run continued), and the hole contract is about what the file can prove.
    const book = try log.addTrack(.{ .id = "book", .capacity = 4 }, u32, 4);
    const risk = try log.addTrack(.{ .id = "risk", .capacity = 16 }, i64, 16);
    try log.setCodec(book, U32Codec);
    try log.setCodec(risk, I64Codec);

    for (0..24) |i| {
        clk.set(@intCast(i));
        if (i % 3 == 0) {
            book.record(@intCast(i)) catch |err| try std.testing.expectEqual(error.Full, err);
        } else {
            try risk.record(@intCast(i));
        }
    }
    // "book" kept seq 0, 3, 6, 9 and refused 12, 15, 18, 21; each delivery's value
    // is its own seq, which is what lets the targets' readings below be the seqs.
    try std.testing.expectEqual(@as(u64, 4), log.refusedCount());

    var writer = try dlog.Writer.open(allocator, io, config);
    const report = try log.drainTo(&writer);
    writer.deinit();
    try std.testing.expectEqual(@as(usize, 20), report.records);
    try std.testing.expectEqual(@as(u64, 4), report.holes);
    try std.testing.expectEqual(@as(?u64, 12), report.first_hole_seq);

    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    // §13.10's requirement on the file itself: the previous slice's reader still
    // calls it clean.
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 20), scanned.records.len);

    var manual = Clock.Manual{ .now_ms = 0 };
    var book_target = FakeTarget(u32){};
    var risk_target = FakeTarget(i64){};
    var loader = try ReplayFromLog.init(allocator, &manual, scanned.records);
    defer loader.deinit();
    try loader.setCodec("book", U32Codec, u32);
    try loader.setCodec("risk", I64Codec, i64);
    try loader.bindDecoded("book", &book_target);
    try loader.bindDecoded("risk", &risk_target);
    try std.testing.expect(loader.isFullyBound());
    try std.testing.expectEqual(@as(usize, 20), loader.remaining());

    // ── the hole, refused by default ────────────────────────────────────────
    // The file's first twelve records are seq 0..11, then seq 12 is not in it (the
    // short track refused that delivery). Getting to the next record means stepping
    // over a missing delivery, which the reader will not do on its own — and it
    // leaves the entry where it is.
    for (0..12) |_| _ = (try loader.step()).?;
    try std.testing.expectError(error.LogHasHoles, loader.step());
    try std.testing.expectEqualStrings("risk", loader.refusal().?); // seq 13's track
    try std.testing.expectEqual(@as(?u64, 12), loader.refusalSeq()); // the missing seq
    try std.testing.expectEqual(@as(u64, 1), loader.holesSeen()); // found …
    try std.testing.expectEqual(@as(u64, 0), loader.crossedHoles()); // … not crossed
    try std.testing.expectEqual(@as(?u64, 12), loader.firstHoleSeq());
    // Nothing was consumed by the refusal: the same twelve are behind the cursor and
    // the entry is still ahead of it.
    try std.testing.expectEqual(@as(usize, 8), loader.remaining());
    try std.testing.expectEqual(@as(usize, 12), book_target.n + risk_target.n);

    // … and refusing again changes nothing — a caller that refuses holes after a
    // retry gets the same answer, and the count is not doubled.
    loader.refuseHoles();
    try std.testing.expectError(error.LogHasHoles, loader.step());
    try std.testing.expectEqual(@as(u64, 1), loader.holesSeen());
    try std.testing.expectEqual(@as(u64, 0), loader.crossedHoles());

    // ── the hole, crossed on purpose and counted ────────────────────────────
    loader.allowHoles();
    const delivered = try loader.replayAll();
    try std.testing.expectEqual(@as(usize, 8), delivered); // the twenty less the twelve already handed over
    try std.testing.expectEqual(@as(?LogStep, null), try loader.step());
    try std.testing.expectEqual(@as(usize, 0), loader.remaining());
    // Exactly four: the gaps are seq 12, 15, 18 and 21, one each.
    try std.testing.expectEqual(@as(u64, 4), loader.crossedHoles());
    try std.testing.expectEqual(@as(u64, 4), loader.holesSeen());
    try std.testing.expectEqual(@as(u64, 0), loader.duplicateSeqs());
    // The two ends agree: the drain's read-out and the reader's own walk name the
    // same four seqs, and they are the ones `drainTo` says were never written.
    try std.testing.expectEqual(report.first_hole_seq, loader.firstHoleSeq());

    // Order and payloads, per track: the values are the seqs they were sent as.
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 6, 9 }, book_target.taken());
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 4, 5, 7, 8, 10, 11, 13, 14, 16, 17, 19, 20, 22, 23 }, risk_target.taken());
    // The clock rode the stamps to the end (there were no timers here: a track
    // stamps a delivery when it is recorded, and the clock was at `i` for seq `i`).
    try std.testing.expectEqual(@as(i64, 23), manual.now_ms);
}

test "ReplayFromLog: an unknown id, a missing codec and a missing handle are three different refusals" {
    const allocator = std.testing.allocator;
    // The reader is handed the records, so this test needs no segment at all: a
    // file's `scan` is *one* producer of this slice, and the refusals below are
    // about what the reader was told, not where the bytes came from.
    const payload_a = [_]u8{ 0xE8, 0x03, 0x00, 0x00 }; // 1000
    const records = [_]dlog.Record{
        .{ .seq = 0, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload_a },
        .{ .seq = 1, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload_a },
    };

    var manual = Clock.Manual{ .now_ms = 0 };
    var loader = try ReplayFromLog.init(allocator, &manual, &records);
    defer loader.deinit();

    // 1. An id the file does not hold — a typo, and it is refused at the
    //    declaration rather than reading as "this track delivered nothing".
    try std.testing.expectError(error.UnknownTrack, loader.setCodec("nope", U32Codec, u32));
    try std.testing.expectEqualStrings("nope", loader.refusal().?);
    var target = FakeTarget(u32){};
    try std.testing.expectError(error.UnknownTrack, loader.bindDecoded("nope", &target));
    try std.testing.expectEqualStrings("nope", loader.refusal().?);

    // 2. A handle bound with no codec declared. That is a legal order to bind in
    //    (the codec may come later), so it is the *delivery* that refuses — by
    //    name, and with the seq in hand.
    try loader.bindDecoded("a", &target);
    try std.testing.expect(!loader.isFullyBound());
    try std.testing.expectError(error.CodecRequired, loader.step());
    try std.testing.expectEqualStrings("a", loader.refusal().?);
    try std.testing.expectEqual(@as(?u64, 0), loader.refusalSeq());
    try std.testing.expectEqual(@as(usize, 0), target.n); // nothing was delivered

    // 3. An id with a codec and no handle at all — a different mistake, and a
    //    different error: there is nothing to hand the decoded value to.
    var unbound_manual = Clock.Manual{ .now_ms = 0 };
    var unbound = try ReplayFromLog.init(allocator, &unbound_manual, &records);
    defer unbound.deinit();
    try unbound.setCodec("a", U32Codec, u32);
    try std.testing.expect(!unbound.isFullyBound());
    try std.testing.expectError(error.UnboundTrack, unbound.step());
    try std.testing.expectEqualStrings("a", unbound.refusal().?);
    try std.testing.expectEqual(@as(?u64, 0), unbound.refusalSeq());

    // The codec can still arrive after the binding, and then the whole file
    // replays: the refusal cost the caller a call, not a delivery.
    try loader.setCodec("a", U32Codec, u32);
    try std.testing.expect(loader.isFullyBound());
    try std.testing.expectEqual(@as(usize, 2), try loader.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 1000, 1000 }, target.taken());
}

test "ReplayFromLog: codec name and message type are checked against the id they were declared for" {
    const allocator = std.testing.allocator;
    const payload_a = [_]u8{ 0xE8, 0x03, 0x00, 0x00 }; // 1000
    const payload_b = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // i64 0
    const records = [_]dlog.Record{
        .{ .seq = 0, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload_a },
        .{ .seq = 1, .track_id = "b", .kind = .message, .recorded_ns = 0, .payload = &payload_b },
    };

    var manual = Clock.Manual{ .now_ms = 0 };
    var loader = try ReplayFromLog.init(allocator, &manual, &records);
    defer loader.deinit();

    // The file holds only ids and bytes: which codec wrote them is the caller's
    // declaration, so a handle of the wrong `Message` type can only be caught
    // against what was declared (docs/RUNTIME.md §13.10 D2).
    var wide = FakeTarget(u64){};
    try loader.setCodec("a", U32Codec, u32);
    try std.testing.expectError(error.MessageTypeMismatch, loader.bindDecoded("a", &wide));
    try std.testing.expectEqualStrings("a", loader.refusal().?);
    const refused = loader.typeMismatch().?;
    try std.testing.expectEqualStrings("u32", refused.expected);
    try std.testing.expectEqualStrings("u64", refused.got);

    // …and the other way round, by binding first: the handle is a fact the reader
    // keeps, so a codec declared afterwards is checked against it too.
    var late = FakeTarget(u64){};
    var binding_first = try ReplayFromLog.init(allocator, &manual, &records);
    defer binding_first.deinit();
    try binding_first.bindDecoded("a", &late);
    try std.testing.expectError(error.MessageTypeMismatch, binding_first.setCodec("a", U32Codec, u32));
    try std.testing.expectEqualStrings("a", binding_first.refusal().?);
    try std.testing.expectEqualStrings("u64", binding_first.typeMismatch().?.expected);
    try std.testing.expectEqualStrings("u32", binding_first.typeMismatch().?.got);

    // Two codecs for one id: the bytes of everything read afterwards would be
    // reinterpreted, so the second declaration is refused rather than taking over.
    try loader.setCodec("b", I64Codec, i64);
    try std.testing.expectError(error.CodecNameMismatch, loader.setCodec("b", U32Codec, u32));
    try std.testing.expectEqualStrings("b", loader.refusal().?);
    // The declaration that was already there is untouched: `b` still decodes as i64.
    var narrow = FakeTarget(i64){};
    const records_b = [_]dlog.Record{
        .{ .seq = 0, .track_id = "b", .kind = .message, .recorded_ns = 0, .payload = &payload_b },
    };
    var bound = try ReplayFromLog.init(allocator, &manual, &records_b);
    defer bound.deinit();
    try bound.setCodec("b", I64Codec, i64);
    try bound.bindDecoded("b", &narrow);
    try std.testing.expectEqual(@as(usize, 1), try bound.replayAll());
    try std.testing.expectEqualSlices(i64, &.{0}, narrow.taken());
}

test "ReplayFromLog: a seq the file holds twice is counted, not replayed" {
    // Unreachable through `drainTo` (`Writer.append` refuses a seq that does not
    // increase), but a reader is handed a slice of records, and a hand-built one
    // can hold the same seq twice. Re-delivering it would make the file look like
    // twice the traffic it recorded, so it is skipped *and counted*.
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    const records = [_]dlog.Record{
        .{ .seq = 0, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload },
        .{ .seq = 0, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload },
        .{ .seq = 1, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload },
    };

    var manual = Clock.Manual{ .now_ms = 0 };
    var loader = try ReplayFromLog.init(allocator, &manual, &records);
    defer loader.deinit();
    try loader.setCodec("a", U32Codec, u32);
    var target = FakeTarget(u32){};
    try loader.bindDecoded("a", &target);

    try std.testing.expectEqual(@as(usize, 2), try loader.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 1, 1 }, target.taken());
    try std.testing.expectEqual(@as(u64, 1), loader.duplicateSeqs());
    // A duplicate is not a hole: the chain is still whole, and nothing is missing.
    try std.testing.expectEqual(@as(u64, 0), loader.holesSeen());
    try std.testing.expectEqual(@as(?u64, null), loader.firstHoleSeq());
}

test "ReplayFromLog: the decoded value is posted by value, so the frame it was decoded in can be reused" {
    // §13.10 D5, pinned rather than argued: `deliver` decodes into a temporary in
    // its own frame and hands `post` a pointer to it; `post` dereferences and
    // `send` takes the message **by value**. So the temporary dies when the call
    // returns, and the receiver must already have its own copy — which is what a
    // scribbled-over stack checks.
    const allocator = std.testing.allocator;
    const first: u128 = 0xDEADBEEF0000000701020304A1B2C3D4;
    const second: u128 = 0x88888888777777776666666655555555;

    var payload: [2][16]u8 = undefined;
    for ([_]u128{ first, second }, 0..) |value, i| {
        const encoded = try WideCodec.encode(allocator, value);
        @memcpy(payload[i][0..], encoded);
        allocator.free(encoded);
    }
    const records = [_]dlog.Record{
        .{ .seq = 0, .track_id = "wide", .kind = .message, .recorded_ns = 0, .payload = &payload[0] },
        .{ .seq = 1, .track_id = "wide", .kind = .message, .recorded_ns = 1, .payload = &payload[1] },
    };

    var manual = Clock.Manual{ .now_ms = 0 };
    var loader = try ReplayFromLog.init(allocator, &manual, &records);
    defer loader.deinit();
    try loader.setCodec("wide", WideCodec, u128);
    var target = FakeTarget(u128){};
    try loader.bindDecoded("wide", &target);

    const step0 = (try loader.step()).?;
    try std.testing.expectEqual(@as(u64, 0), step0.seq);
    try std.testing.expectEqual(@as(usize, 1), target.n);
    // The frame that held the decoded value is gone. Bury it.
    scribbleStack();
    try std.testing.expectEqual(first, target.taken()[0]);

    // And again across the *next* step, which reuses the same stack slot: a reader
    // that kept a pointer to the earlier temporary (or posted one later) would
    // have the first delivery overwritten by the second one here.
    const step1 = (try loader.step()).?;
    try std.testing.expectEqual(@as(u64, 1), step1.seq);
    scribbleStack();
    try std.testing.expectEqual(first, target.taken()[0]);
    try std.testing.expectEqual(second, target.taken()[1]);
}

test "ReplayFromLog: the reader's allocator is real, and nothing a step takes survives it" {
    // §13.10 D6, measured rather than promised: the reader holds an allocator
    // (deliberately, unlike `Replayer`) because `Codec.decode` is the caller's and
    // takes one. The counting allocator sees exactly what the reader does with it.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = probe.allocator();
    const payload = [_]u8{ 0x2A, 0x00, 0x00, 0x00 }; // 42
    const records = [_]dlog.Record{
        .{ .seq = 0, .track_id = "a", .kind = .message, .recorded_ns = 0, .payload = &payload },
        .{ .seq = 1, .track_id = "a", .kind = .message, .recorded_ns = 1, .payload = &payload },
        .{ .seq = 2, .track_id = "a", .kind = .message, .recorded_ns = 2, .payload = &payload },
    };

    var manual = Clock.Manual{ .now_ms = 0 };
    var loader = try ReplayFromLog.init(allocator, &manual, &records);
    try loader.setCodec("a", ScratchCodec, u32);
    var target = FakeTarget(u32){};
    try loader.bindDecoded("a", &target);

    // The reader really did allocate for itself: the `seq` order it sorts at
    // `init` is its own buffer, and this is where that shows.
    const built = probe.allocations - probe.deallocations;
    try std.testing.expect(built > 0);
    const allocations_before = probe.allocations;

    try std.testing.expectEqual(@as(usize, 3), try loader.replayAll());
    try std.testing.expectEqualSlices(u32, &.{ 42, 42, 42 }, target.taken());

    // The codec was handed *this* allocator and used it — three decodes, at least
    // one scratch each …
    try std.testing.expect(probe.allocations > allocations_before);
    // … and the live count is exactly where the reader left it: every buffer a
    // step took came back before the step returned, so nothing accumulates across
    // a replay of any length.
    try std.testing.expectEqual(built, probe.allocations - probe.deallocations);

    // And the reader gives back what it took: its two buffers and the codecs'
    // scratches all balance once it is done.
    loader.deinit();
    try std.testing.expectEqual(probe.allocations, probe.deallocations);
}
