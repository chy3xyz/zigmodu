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
//! - **No codec, anywhere.** Two heterogeneous workers are logged as two
//!   single-typed tracks merged by their sequence numbers, not as encoded
//!   bytes — which is why a delivery log is in-process only (`TrackRef`
//!   reserves the codec slot for the tier that changes that, §13.3 Q4).
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
const Sequencer = @import("sequencer.zig").Sequencer;
const Clock = @import("clock.zig").Clock;

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
    /// Track capacity in messages. Memory is `capacity × sizeof(Message)`, held
    /// for the life of the runtime.
    capacity: usize,
};

/// One entry as the *erased* side sees it: the ordering stamps, plus a pointer to
/// the payload inside the track's ring (valid until the track is destroyed).
///
/// The payload is a pointer to the recorded value rather than encoded bytes on
/// purpose: v1 has no codec (§13.5), and the value is already in memory — the
/// typed half is re-attached by the target handle's own thunk in `Replayer.bind`.
pub const TrackEntry = struct {
    seq: u64,
    clock_ms: i64,
    payload: *const anyopaque,
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
    /// wrote it. v1 records values in memory and leaves this `null`; `bind`
    /// refuses a track that declares one, so the interface does not have to
    /// change when that tier lands — the payload pointer stops being the answer
    /// at exactly that point.
    payload_codec: ?[]const u8 = null,

    /// Append one delivery. `event` points at the sender's value, which the track
    /// copies into its ring — no allocation, and the sender's copy is not kept.
    record: *const fn (track: *TrackRef, event: *const anyopaque) RecordError!void,
    /// Entry `i`, which must be below `len`.
    entry: *const fn (track: *const TrackRef, i: usize) TrackEntry,
    len: *const fn (track: *const TrackRef) usize,
    has_overflowed: *const fn (track: *const TrackRef) bool,
    destroy: *const fn (track: *TrackRef, allocator: std.mem.Allocator) void,

    /// Replay state, owned by this descriptor (see `DeliveryLog.replayer`): the
    /// next entry to hand out, and — once bound — where its payloads go back to.
    cursor: usize = 0,
    target: ?*anyopaque = null,
    post: ?*const fn (target: *anyopaque, payload: *const anyopaque) mbox.SendError!void = null,
};

/// One worker's delivery track: a bounded ring of that worker's own `Message`
/// type whose entries carry sequence numbers from the log's shared `Sequencer`.
///
/// That is the whole trick of §13.2 — each track stays single-typed, so it is
/// still zero-allocation and value-semantic and needs no codec, while the shared
/// sequence makes the tracks mergeable into one replay order.
pub fn Track(comptime E: type, comptime capacity: usize) type {
    if (capacity < 1) @compileError("Track needs capacity >= 1");
    if (@sizeOf(E) == 0) @compileError("Track stores messages by value; " ++ @typeName(E) ++ " has no size");
    return struct {
        const Self = @This();

        /// The message type this track holds.
        pub const Event = E;
        /// Comptime storage budget.
        pub const max_entries = capacity;
        /// See `TrackRef.payload_codec`: v1 records values, so there is none.
        pub const codec: ?[]const u8 = null;

        /// One recorded delivery, in this track's ring: the *global* sequence
        /// number, the injected clock reading at the record point, and the
        /// message itself.
        pub const Entry = struct {
            seq: u64,
            clock_ms: i64,
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
        },

        /// Append one delivery. Zero allocation, lock-free. `error.Full` when the
        /// track has no room left: the delivery *happened* (the message is in the
        /// mailbox), the log just cannot keep it — which is why the runtime counts
        /// the refusal instead of failing the send (see `DeliveryLog.refused`).
        pub fn record(self: *Self, event: E) RecordError!void {
            const seq = self.log.sequencer.next();
            const n = self.writes.next();
            if (n >= capacity) {
                self.overflowed.store(true, .release);
                _ = self.log.refused.fetchAdd(1, .monotonic);
                return RecordError.Full;
            }
            self.slots.publish(@intCast(n), .{
                .seq = seq,
                .clock_ms = self.log.clock.nowMs(),
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

        /// Entry `i` in erased form (see `TrackEntry`).
        pub fn entryAt(self: *const Self, i: usize) TrackEntry {
            return .{
                .seq = self.slots.buf[i].seq,
                .clock_ms = self.slots.buf[i].clock_ms,
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

        fn recordErased(ref: *TrackRef, event: *const anyopaque) RecordError!void {
            const value: *const E = @ptrCast(@alignCast(event));
            return fromRef(ref).record(value.*);
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

        fn destroyErased(ref: *TrackRef, allocator: std.mem.Allocator) void {
            allocator.destroy(fromRef(ref));
        }
    };
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
    const payload: *const u32 = @ptrCast(@alignCast(entry.payload));
    try std.testing.expectEqual(@as(u32, 11), payload.*);

    // ...and the erased `record` thunk is the whole send-path cost of a track.
    var value: u32 = 12;
    try erased.record(erased, @ptrCast(&value));
    try std.testing.expectEqual(@as(u32, 12), A.entries()[2].event);
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
