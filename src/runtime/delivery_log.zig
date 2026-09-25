//! Delivery-log segments — the **storage layer** for a persisted delivery track
//! (`docs/RUNTIME.md` §13.3 Q4, tier 2).
//!
//! `src/runtime/recorder.zig` keeps the delivery stream in bounded in-memory
//! rings and says so: §13.5 lists "no cross-process replay" as out of scope for
//! v1, and `TrackRef.payload_codec` is the slot a second storage tier plugs
//! into. This file is that tier's durability half and nothing else. It knows
//! nothing about `DeliveryLog`, `Track`, `Replayer` or the runtime's wiring —
//! it appends *records* to segment files and reads them back, verifying what it
//! reads. Wiring it to the recorder is a separate change with its own contract
//! (the codec: a payload that leaves the process is bytes, not a live value).
//!
//! ## Why a new format instead of `src/core/eventbus/WAL.zig`
//!
//! `WAL.zig` is a **shipped on-disk format**, not an internal helper: it is
//! exported (`src/root.zig`: `pub const WAL` / `WALConfig`), and
//! `DistributedEventBus`, `SagaOrchestrator` and `ai/workflow` all construct it
//! with a caller-supplied `dir_path`, so its files live wherever a deployment
//! put them. Reusing it would mean changing that format in place, and every
//! requirement below is a framing change:
//!
//! | requirement | `WAL.zig` today |
//! |---|---|
//! | reject a foreign file | no magic — a 32-byte header is read out of whatever bytes are there |
//! | reject a future/older writer | no format version at all |
//! | explicit little-endian | implicit: the header is a `@bitCast` of a `packed struct`, so it is native-endian by accident |
//! | detect a damaged record | no checksum anywhere; a flipped payload byte comes back as data, and a flipped length field silently reframes every record after it |
//! | say what a record *is* | `topic`/`source` are strings, no record kind, `timestamp_ms` is milliseconds |
//! | tell a torn tail from corruption | `readSegmentEntries` `break`s on a short read — silently, with no damaged-byte count and no repair |
//! | bound the append path | `append` builds a record-sized `ArrayList` per call; the reader allocates the whole segment (`allocator.alloc(u8, seg.size_bytes)`) |
//!
//! So: **a new file, a new format, and `WAL.zig` untouched** — its bytes on disk
//! stay readable exactly as they are. This is not a fork to be merged back: it
//! stores a different record shape (delivery records: one global sequence, one
//! track id, one kind, nanosecond stamps, opaque payload bytes) for a different
//! consumer. Two formats with two names is the honest outcome; one format with a
//! magic number bolted onto files that already exist is not.
//!
//! ## The format, byte for byte
//!
//! Everything is **explicitly little-endian**, written field by field rather
//! than by `@bitCast`, so the layout below is the layout on every target.
//!
//! File header — 12 bytes, once per segment, at offset 0:
//!
//! ```text
//! [0..4)   magic          u32 = 0x314C445A  ("ZDL1")
//! [4..6)   format_version u16 = 1
//! [6..8)   header_len     u16 = 12
//! [8..12)  crc32          u32 over [0..8)
//! ```
//!
//! Record frame — 32-byte header, then the variable-length body, then nothing:
//!
//! ```text
//! [0..4)   frame_len     u32  = 32 + track_id_len + payload_len
//! [4..12)  seq           u64  (global delivery sequence)
//! [12..20) recorded_ns   i64  (nanoseconds at the record point)
//! [20..24) payload_len   u32
//! [24..26) kind          u16  (Kind, widened so a later format can add values)
//! [26..28) track_id_len  u16
//! [28..32) crc32         u32  over [0..28) ++ track_id ++ payload
//! [32..)   track_id, then payload
//! ```
//!
//! `frame_len` is not decoration: on the read path it must equal
//! `32 + track_id_len + payload_len`, and that self-consistency check is what
//! keeps the two failure modes apart.
//!
//! Segment files are `delivery-<20-digit id>.log` in the configured directory,
//! ids strictly increasing (20 digits is exactly `u64`'s width, so the name
//! cannot truncate an id). A record is written whole into one segment or not at
//! all — rotation happens *before* the write that would overflow the segment, so
//! a limit that falls inside a record moves the whole record to the next
//! segment. A record larger than the whole limit gets a segment of its own (the
//! limit is a target, not a promise; the alternative is splitting a frame, which
//! no reader could reassemble).
//!
//! ## Reading: a valid prefix, and *why* it stopped
//!
//! `scan` never hands a damaged record to the caller and never reports a hole it
//! did not describe. It returns the records that were fully verified, plus a
//! `Damage`:
//!
//! * `.torn` — the bytes after the last complete record, which is a write that
//!   did not finish (or a file header that did not finish). Tolerable, and the
//!   byte count is reported, never silently dropped. `repair` truncates it.
//! * `.corrupt` — a frame whose bytes are all there but whose CRC (or whose own
//!   length fields) do not agree, with the segment, the byte offset and the
//!   index the record would have had. **Not** tolerable: `repair` refuses, so
//!   nothing that was fully written is ever deleted by a tool.
//!
//! The two cannot be confused, because a torn write always leaves an *intact*
//! 32-byte header (it is written before the body) while a damaged header always
//! contradicts itself: a corrupt `frame_len` fails
//! `frame_len == 32 + track_id_len + payload_len` (or the `max_record_bytes`
//! bound) and is reported as corruption, and a body that is simply not there is
//! reported as a torn tail. Nothing is resynchronised past a damaged frame — a
//! length field is exactly the thing a resync would have to trust.
//!
//! `Writer.open` walks the whole log before it agrees to append, so it can never
//! write past a hole: a damaged log is `error.LogDamaged` until `repair` (for a
//! torn tail) or a human (for corruption) has dealt with it.
//!
//! ## Allocation contract
//!
//! **`Writer.append` and the whole steady-state write path allocate nothing** —
//! not "bounded", zero. The frame header is a 32-byte stack array, the CRC is
//! computed over the caller's slices, and the three `writePositionalAll` calls
//! pass caller memory straight through; `Writer` holds no allocator at all. The
//! measured assertion is *"delivery-log: append allocates nothing, not even
//! across a rotation"* below, which arms a `std.testing.FailingAllocator` for
//! the duration of the appends and asserts an exact delta of 0 — the same
//! instrument `src/runtime/alloc_contract_test.zig` and `src/benchmark.zig` use
//! for the runtime's other producer hot paths.
//!
//! The read path does allocate: `scan` materialises owned records (one dupe of
//! `track_id` and one of `payload` per record), and the segment walker grows one
//! read buffer to the largest record it decodes — bounded by
//! `Config.max_record_bytes`, because a `frame_len` above that bound is refused
//! as corruption *before* anything is sized from it.
//!
//! ## Deliberately not here
//!
//! * No recorder/`DeliveryLog` wiring and no `TrackRef.payload_codec` — that
//!   needs the codec contract §13.3 Q4 asks for.
//! * No CLI, no metrics, no compaction or deletion of *valid* records, no
//!   `max_segments` retention: there is no committed index in this layer, so
//!   "which segments are safe to delete" is a question only the caller can
//!   answer.
//! * No concurrent writers. One `Writer` per directory. A reader running beside
//!   an appending writer sees at worst the half-written frame that writer is in
//!   the middle of — reported as `.torn`, exactly as a crash's would be — and
//!   `repair` beside a live writer is the caller's own risk: nothing here locks.
//! * Not exported from `src/runtime.zig` / `src/root.zig`. Nothing consumes it
//!   yet, and an exported-but-uncalled surface is precisely what rots (see the
//!   `LogRotator` note in `AGENTS.md`). Its tests run because `src/tests.zig`
//!   imports the file — the same wiring `im/ConnectionRegistry.zig` needed, and
//!   for the same reason.

const std = @import("std");

/// `'Z','D','L','1'` as a little-endian `u32`.
const MAGIC: u32 = 0x314C_445A;
/// Bumped when the framing changes in a way a v1 reader cannot handle. A reader
/// that sees anything else reports `error.UnsupportedVersion` — never "0 records".
const FORMAT_VERSION: u16 = 1;
const FILE_HEADER_LEN: usize = 12;
const RECORD_HEADER_LEN: usize = 32;
/// Offset of the record CRC inside the record header: everything before it is
/// covered by it, together with the body.
const CRC_OFFSET: usize = RECORD_HEADER_LEN - 4;
const FILE_PREFIX = "delivery-";
const FILE_SUFFIX = ".log";
/// Width of the segment id in a file name.
const ID_DIGITS = 20;
/// `FILE_PREFIX` + `ID_DIGITS` + `FILE_SUFFIX`.
const SEGMENT_NAME_LEN = FILE_PREFIX.len + ID_DIGITS + FILE_SUFFIX.len;

comptime {
    // `segmentName` formats the id by hand into exactly `ID_DIGITS` digits, so
    // the name may not be able to drop a digit that does not fit.
    var digits: usize = 0;
    var v: u64 = std.math.maxInt(u64);
    while (v > 0) : (v /= 10) digits += 1;
    std.debug.assert(digits == ID_DIGITS);
}

/// `CRC-32/ISCSI` (Castagnoli) — the polynomial `src/core/KafkaConnector.zig`
/// already uses for its wire frames, so a damaged-frame check is a familiar
/// primitive and not a homegrown checksum. The `@hasDecl` shim covers the
/// `Crc32Iscsi` → `@"CRC-32/ISCSI"` rename (0.17-dev ~1422).
const Crc32c = if (@hasDecl(std.hash.crc, "Crc32Iscsi"))
    std.hash.crc.Crc32Iscsi
else
    std.hash.crc.@"CRC-32/ISCSI";

fn crc32Of(bytes: []const u8) u32 {
    return Crc32c.hash(bytes);
}

/// What a record is, on the wire. Two values today; stored as a `u16` so a later
/// format can add kinds without moving any other field.
pub const Kind = enum(u16) {
    /// A `Handle.send*` / `HotBus` fan-out delivery.
    message = 0,
    /// `Handle.after(...)`'s timer delivery (§13.1: it does not go through
    /// `send*`, which is why a delivery log has to have a word for it).
    timer = 1,
};

/// How often the segment file is flushed to the platform.
pub const SyncMode = enum {
    /// `fsync` after every `append`. Slowest, and the only mode where "the
    /// record is on disk" is true when `append` returns.
    fsync,
    /// `fsync` when a segment is rotated past, and on `deinit`/`sync`. A crash
    /// can lose the tail — which reads back as a torn tail, not as a hole.
    segment_sync,
    /// No explicit flush; the OS's business. Tests, and logs you can regenerate.
    none,
};

/// Everything the reader, the writer and `repair` need to agree on.
pub const Config = struct {
    /// Directory holding the segment files. The write path creates it (and only
    /// the write path — reading a directory that is not there is
    /// `error.FileNotFound`, not a log quietly conjured into existence).
    dir_path: []const u8 = "data/delivery",
    /// Byte ceiling for one segment, headers included. A record never straddles
    /// two segments.
    max_segment_bytes: u64 = 64 * 1024 * 1024,
    /// Byte ceiling for one record frame. Enforced on `append`
    /// (`error.RecordTooLarge`) and, on the read path, used as the bound that
    /// decides whether a length field can be believed at all.
    max_record_bytes: u32 = 8 * 1024 * 1024,
    /// Flush policy. Ignored by `scan`/`repair`, which never write.
    sync_mode: SyncMode = .fsync,
};

/// One delivery, as the storage layer sees it. `seq` is the caller's global
/// sequence number: this layer does not sequence anything, it checks that it is
/// told an increasing order (`error.SeqNotIncreasing`), because "read back in
/// `seq` order across segments" is only true if the file order is that order.
pub const Record = struct {
    seq: u64,
    track_id: []const u8,
    kind: Kind,
    recorded_ns: i64,
    payload: []const u8,
};

/// Why a fully present record was rejected.
pub const CorruptReason = enum {
    /// `frame_len` is larger than `Config.max_record_bytes` — a length no writer
    /// of this format can produce, so it is never trusted enough to size a read.
    frame_too_large,
    /// `frame_len` disagrees with `32 + track_id_len + payload_len`: the header
    /// contradicts itself, so the framing past this point is unknowable.
    frame_len_mismatch,
    /// The frame is all there and self-consistent, but the CRC disagrees.
    crc_mismatch,
    /// The frame verified; the `kind` field is not a value this version knows.
    unknown_kind,
};

/// Where a damaged record was, and why.
pub const Corrupt = struct {
    /// Segment file the frame is in.
    segment_id: u64,
    /// Index the record would have had in `Scan.records` — i.e. how many
    /// verified records precede it.
    index: usize,
    /// Byte offset of the frame inside its segment.
    offset: u64,
    reason: CorruptReason,
};

/// What, if anything, stopped a scan short.
pub const Damage = union(enum) {
    /// Every segment was walked to its end with nothing left over.
    none,
    /// This many bytes after the last complete record could not be decoded:
    /// a write that did not finish. Tolerable, counted, and `repair`'s business.
    torn: u64,
    /// A record that is all there but does not verify. Not tolerable: nothing
    /// after it can be trusted, and `repair` will not delete it for you.
    corrupt: Corrupt,
};

/// Why `Scan.expectClean` refused a scan.
pub const ScanError = error{
    /// `Damage.torn`: the log ends in a partial record.
    TornTail,
    /// `Damage.corrupt`: a record failed verification.
    CorruptRecord,
};

/// The result of reading a log: the verified prefix, plus what stopped it.
pub const Scan = struct {
    /// Verified records, in `seq` order, across every segment. Owned by the
    /// caller (`deinit`). Always a prefix — a record that failed verification is
    /// never in here, and neither is anything after one.
    records: []Record,
    damage: Damage,

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        freeRecords(allocator, self.records);
        allocator.free(self.records);
        self.* = undefined;
    }

    /// Nothing was left over. A scan that is not clean is still usable; this is
    /// the "I only accept a whole log" gate, so a caller that needs that cannot
    /// forget to look at `damage`.
    pub fn expectClean(self: *const Scan) ScanError!void {
        switch (self.damage) {
            .none => {},
            .torn => return error.TornTail,
            .corrupt => return error.CorruptRecord,
        }
    }

    /// Bytes after the last complete record, when the log simply stops early
    /// (`Damage.torn`). 0 when the scan is clean — and 0 on corruption too,
    /// which is not a tail but a record that is all there and does not verify
    /// (`corruption()` says where it is).
    pub fn damagedTailBytes(self: *const Scan) u64 {
        return switch (self.damage) {
            .torn => |bytes| bytes,
            else => 0,
        };
    }

    /// The damaged record, when the scan stopped on corruption rather than on a
    /// torn tail.
    pub fn corruption(self: *const Scan) ?Corrupt {
        return switch (self.damage) {
            .corrupt => |c| c,
            else => null,
        };
    }
};

/// What `repair` did, or did not have to do.
pub const RepairReport = struct {
    /// The segment that was truncated, or `null` when the log was already clean
    /// — which is also what a second `repair` call reports, since `repair` is
    /// idempotent.
    segment_id: ?u64,
    /// Bytes removed from that segment. 0 means nothing was touched.
    truncated_bytes: u64,
    /// Records the log reads back after the call.
    records_kept: usize,
};

// ─────────────────────────────────────────────────
// Write path
// ─────────────────────────────────────────────────

/// Appends records to the last segment of a log, starting a new segment when the
/// byte ceiling says so.
///
/// `open` walks the whole log first (validating every segment and learning the
/// last sequence number), and refuses a log it cannot read back whole
/// (`error.LogDamaged`, plus the segment-header errors `scan` reports). The walk
/// materialises nothing: it uses one read buffer bounded by
/// `Config.max_record_bytes`.
pub const Writer = struct {
    const Self = @This();

    io: std.Io,
    dir: std.Io.Dir,
    config: Config,
    /// The segment being appended to.
    file: std.Io.File,
    /// Its size including the file header — the write offset of the next frame.
    current_size: u64,
    /// Records in it. Rotation is skipped while this is 0, which is what gives a
    /// record larger than `max_segment_bytes` a segment to itself instead of an
    /// endless rotation.
    current_records: u64,
    /// Id the *next* segment will get. Strictly increasing, never reused.
    next_id: u64,
    last_seq: u64,
    /// False only while no record has ever been appended, so the first record
    /// may carry any `seq` (0 included) and every one after it must be larger.
    has_records: bool,
    segment_files: usize,

    /// Open (creating if needed) the log under `config.dir_path` for appending.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, config: Config) !Writer {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, config.dir_path, .default_dir);
        const dir = try std.Io.Dir.cwd().openDir(io, config.dir_path, .{ .iterate = true });
        errdefer dir.close(io);

        // Validate the whole log before agreeing to append to it. A damaged
        // segment anywhere means a record is already unreachable, and appending
        // past it would grow a log nobody can read back.
        var last_seq: u64 = 0;
        var has_records = false;
        var highest: ?u64 = null;
        var files: usize = 0;
        {
            var reader = try SegmentReader.init(allocator, io, dir, config);
            defer reader.deinit();
            files = reader.ids.len;
            if (files > 0) highest = reader.ids[files - 1];
            while (true) {
                switch (try reader.step()) {
                    .record => |r| {
                        last_seq = r.seq;
                        has_records = true;
                    },
                    .end => break,
                    .torn, .corrupt => return error.LogDamaged,
                }
            }
        }

        var self = Writer{
            .io = io,
            .dir = dir,
            .config = config,
            .file = undefined,
            .current_size = 0,
            .current_records = 0,
            .next_id = 1,
            .last_seq = last_seq,
            .has_records = has_records,
            .segment_files = files,
        };
        // No segment files at all: this is a new log, so it gets segment 0.
        const id = highest orelse 0;
        try self.openSegment(id);
        if (highest == null) self.segment_files = 1;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.config.sync_mode != .none) {
            self.file.sync(self.io) catch |err| std.log.warn(
                "[delivery-log] sync of the open segment failed on close: {s}",
                .{@errorName(err)},
            );
        }
        self.file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    /// Append one record. **Allocates nothing** (see the module doc) and calls
    /// no allocator: the frame header is a stack array, the CRC is computed over
    /// the caller's two slices, and the three positional writes pass caller
    /// memory straight through.
    ///
    /// Errors that are the caller's to fix: `error.RecordTooLarge` (a field that
    /// does not fit, or a frame above `max_record_bytes`) and
    /// `error.SeqNotIncreasing` (a `seq` that would stop the file order from
    /// being the `seq` order). Everything else is I/O.
    pub fn append(self: *Self, record: Record) !void {
        const track_len: u64 = record.track_id.len;
        const payload_len: u64 = record.payload.len;
        if (track_len > std.math.maxInt(u16) or payload_len > std.math.maxInt(u32)) return error.RecordTooLarge;
        const frame_len: u64 = RECORD_HEADER_LEN + track_len + payload_len;
        if (frame_len > @as(u64, self.config.max_record_bytes)) return error.RecordTooLarge;
        if (self.has_records and record.seq <= self.last_seq) return error.SeqNotIncreasing;

        // Rotate *before* writing, so the ceiling is never crossed in the middle
        // of a frame. `current_records > 0` keeps an oversized record from
        // rotating into an empty segment and rotating again, forever.
        if (self.current_records > 0 and self.current_size + frame_len > self.config.max_segment_bytes) {
            try self.rotate();
        }

        var head: [RECORD_HEADER_LEN]u8 = undefined;
        const prefix = encodeRecordPrefix(
            @intCast(frame_len),
            record.seq,
            record.recorded_ns,
            @intCast(payload_len),
            record.kind,
            @intCast(track_len),
        );
        @memcpy(head[0..CRC_OFFSET], &prefix);

        var crc = Crc32c.init();
        crc.update(&prefix);
        crc.update(record.track_id);
        crc.update(record.payload);
        std.mem.writeInt(u32, head[CRC_OFFSET..RECORD_HEADER_LEN], crc.final(), .little);

        // Three writes, not one: a crash between them is a torn tail, which the
        // read path reports with its byte count instead of guessing.
        const at = self.current_size;
        try self.file.writePositionalAll(self.io, &head, at);
        if (track_len > 0) try self.file.writePositionalAll(self.io, record.track_id, at + RECORD_HEADER_LEN);
        if (payload_len > 0) try self.file.writePositionalAll(self.io, record.payload, at + RECORD_HEADER_LEN + track_len);

        if (self.config.sync_mode == .fsync) try self.file.sync(self.io);

        self.current_size += frame_len;
        self.current_records += 1;
        self.last_seq = record.seq;
        self.has_records = true;
    }

    /// Flush explicitly, for a `SyncMode.segment_sync` caller that wants a
    /// durability point of its own choosing.
    pub fn sync(self: *Self) !void {
        try self.file.sync(self.io);
    }

    /// Sequence number of the last record in the log (0 when it is empty).
    pub fn lastSeq(self: *const Self) u64 {
        return self.last_seq;
    }

    /// Segment files this log has: the one being appended to, plus everybody it
    /// was rotated past.
    pub fn segmentCount(self: *const Self) usize {
        return self.segment_files;
    }

    /// Close the current segment and start the next one, syncing first when the
    /// mode asks for it.
    fn rotate(self: *Self) !void {
        if (self.config.sync_mode != .none) try self.file.sync(self.io);
        // Open the new segment before closing the old one: if that fails, the
        // writer is left exactly as it was instead of with no segment at all.
        const previous = self.file;
        try self.openSegment(self.next_id);
        previous.close(self.io);
        self.segment_files += 1;
    }

    /// Open or create segment `id`, writing its file header if the file is new
    /// (or was left empty by a crash between `createFile` and that write).
    fn openSegment(self: *Self, id: u64) !void {
        var name_buf: [SEGMENT_NAME_LEN]u8 = undefined;
        const file = try self.dir.createFile(self.io, segmentName(id, &name_buf), .{ .truncate = false, .read = true });
        errdefer file.close(self.io);

        const st = try file.stat(self.io);
        var size = st.size;
        if (size == 0) {
            try writeFileHeader(file, self.io, 0);
            size = FILE_HEADER_LEN;
        } else if (size < FILE_HEADER_LEN) {
            // Unreachable through `open` (the validating walk reports this as a
            // torn header first) and reachable through `rotate` only if the
            // segment being rotated into already exists. The file on disk is not
            // ours to trust either way.
            return error.LogDamaged;
        }

        self.file = file;
        self.current_size = size;
        self.current_records = 0;
        self.next_id = id + 1;
    }
};

// ─────────────────────────────────────────────────
// Read path
// ─────────────────────────────────────────────────

/// Read every segment in id order and return the verified prefix.
///
/// Fails outright — with no records — when a *segment* cannot be identified:
/// `error.BadMagic` (not this format), `error.UnsupportedVersion` (a different
/// format version), `error.CorruptHeader` (this version, header does not verify
/// or contradicts itself). Those are deliberately three errors and not one
/// "corrupt" umbrella: a log from another writer is a different problem from a
/// log that rotted, and the caller's response differs.
///
/// A file with no bytes at all is an empty segment (0 records, no damage): that
/// is what a crash between `createFile` and the header write leaves, and calling
/// it "damage" would ask a human to decide about nothing.
pub fn scan(allocator: std.mem.Allocator, io: std.Io, config: Config) !Scan {
    const dir = try std.Io.Dir.cwd().openDir(io, config.dir_path, .{ .iterate = true });
    defer dir.close(io);

    var reader = try SegmentReader.init(allocator, io, dir, config);
    defer reader.deinit();

    var records: std.ArrayList(Record) = .empty;
    errdefer {
        freeRecords(allocator, records.items);
        records.deinit(allocator);
    }

    while (true) {
        switch (try reader.step()) {
            .record => |r| {
                // One dupe per field: `r` points into the walker's reusable
                // buffer, which the next step overwrites.
                const track_id = try allocator.dupe(u8, r.track_id);
                errdefer allocator.free(track_id);
                const payload = try allocator.dupe(u8, r.payload);
                errdefer allocator.free(payload);
                try records.append(allocator, .{
                    .seq = r.seq,
                    .track_id = track_id,
                    .kind = r.kind,
                    .recorded_ns = r.recorded_ns,
                    .payload = payload,
                });
            },
            .end => return .{ .records = try records.toOwnedSlice(allocator), .damage = .none },
            .torn => |bytes| return .{
                .records = try records.toOwnedSlice(allocator),
                .damage = .{ .torn = bytes },
            },
            .corrupt => |c| return .{
                .records = try records.toOwnedSlice(allocator),
                .damage = .{ .corrupt = c },
            },
        }
    }
}

/// Truncate a torn tail so the log reads back clean. Nothing is removed
/// automatically — this is the explicit call, and it is idempotent.
///
/// It refuses, touching nothing, in two cases:
///
/// * `error.CorruptRecordNotRepairable` — the damage is a record that is all
///   there but does not verify. Truncating would delete bytes that were fully
///   written, which is data loss dressed up as maintenance; a human decides.
/// * `error.DamageNotInLastSegment` — a torn tail cannot be in the middle of a
///   log (rotation happens before an append, never after a partial one), so that
///   state was not produced by this writer, and truncating into the gap would
///   hide it.
pub fn repair(allocator: std.mem.Allocator, io: std.Io, config: Config) !RepairReport {
    const dir = try std.Io.Dir.cwd().openDir(io, config.dir_path, .{ .iterate = true });
    defer dir.close(io);

    var reader = try SegmentReader.init(allocator, io, dir, config);
    defer reader.deinit();

    const Found = struct { segment_id: u64, keep: u64, torn: u64, records: usize };
    var found: ?Found = null;
    while (true) {
        switch (try reader.step()) {
            .record => {},
            .end => break,
            .torn => |bytes| {
                if (!reader.atLastSegment()) return error.DamageNotInLastSegment;
                found = .{
                    .segment_id = reader.segment_id,
                    .keep = reader.offset,
                    .torn = bytes,
                    .records = reader.records,
                };
                break;
            },
            .corrupt => return error.CorruptRecordNotRepairable,
        }
    }

    const d = found orelse return .{
        .segment_id = null,
        .truncated_bytes = 0,
        .records_kept = reader.records,
    };

    var name_buf: [SEGMENT_NAME_LEN]u8 = undefined;
    const file = try dir.openFile(io, segmentName(d.segment_id, &name_buf), .{ .mode = .read_write });
    defer file.close(io);
    try file.setLength(io, d.keep);
    try file.sync(io);

    return .{ .segment_id = d.segment_id, .truncated_bytes = d.torn, .records_kept = d.records };
}

/// Walks segment files in ascending id, decoding one record at a time into a
/// reusable buffer. Slices in `Borrowed` die at the next `step()` call.
///
/// The buffer never exceeds `Config.max_record_bytes`: a `frame_len` above that
/// bound is refused as `CorruptReason.frame_too_large` before it sizes anything.
const SegmentReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    config: Config,
    /// Segment ids found on disk, ascending.
    ids: []u64,
    /// Index of the next segment to open, which is also how many were opened —
    /// so `atLastSegment` is `next_segment == ids.len`.
    next_segment: usize = 0,
    file: std.Io.File = undefined,
    segment_open: bool = false,
    segment_id: u64 = 0,
    /// Size of the open segment as it was when opened.
    segment_size: u64 = 0,
    /// Offset of the next unread byte: where the last complete record ended,
    /// which is exactly the byte `repair` truncates to.
    offset: u64 = 0,
    /// Records decoded so far, log-wide: `Corrupt.index` and the "how many did we
    /// keep" number in `RepairReport`.
    records: usize = 0,
    buf: std.ArrayList(u8) = .empty,

    const Borrowed = struct {
        seq: u64,
        track_id: []const u8,
        kind: Kind,
        recorded_ns: i64,
        payload: []const u8,
    };

    /// One step. `torn`/`corrupt` carry the same information `Damage` does,
    /// minus the `.none` a stepped walk can never produce.
    const Outcome = union(enum) {
        record: Borrowed,
        end,
        torn: u64,
        corrupt: Corrupt,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, config: Config) !SegmentReader {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .config = config,
            .ids = try segmentIds(allocator, io, dir),
        };
    }

    fn deinit(self: *SegmentReader) void {
        self.closeSegment();
        self.allocator.free(self.ids);
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// The damaged (or exhausted) segment is the highest id on disk. Rotation
    /// happens before the append that would not fit, so a torn tail can never
    /// have a segment after it.
    fn atLastSegment(self: *const SegmentReader) bool {
        return self.next_segment == self.ids.len;
    }

    fn step(self: *SegmentReader) !Outcome {
        while (true) {
            if (!self.segment_open) {
                if (self.next_segment == self.ids.len) return .end;
                try self.openSegment();
                continue;
            }

            const remaining = self.segment_size - self.offset;
            if (remaining == 0) {
                self.closeSegment();
                continue;
            }

            var head: [RECORD_HEADER_LEN]u8 = undefined;
            const head_read = try self.file.readPositionalAll(self.io, &head, self.offset);
            if (head_read != RECORD_HEADER_LEN) return .{ .torn = remaining };

            const frame_len: u64 = std.mem.readInt(u32, head[0..4], .little);
            const payload_len: usize = std.mem.readInt(u32, head[20..24], .little);
            const kind_raw = std.mem.readInt(u16, head[24..26], .little);
            const track_len: usize = std.mem.readInt(u16, head[26..28], .little);
            const stored_crc = std.mem.readInt(u32, head[CRC_OFFSET..RECORD_HEADER_LEN], .little);

            // The order of these checks is the torn-vs-corrupt distinction: a
            // length field that cannot be believed is corruption, and a body
            // that is simply not there is a torn tail.
            if (frame_len > @as(u64, self.config.max_record_bytes)) return self.corruptOutcome(.frame_too_large);
            if (frame_len != RECORD_HEADER_LEN + @as(u64, track_len) + @as(u64, payload_len)) {
                return self.corruptOutcome(.frame_len_mismatch);
            }
            if (frame_len > remaining) return .{ .torn = remaining };

            const body_len: usize = @intCast(frame_len - RECORD_HEADER_LEN);
            try self.buf.resize(self.allocator, body_len);
            const body_read = try self.file.readPositionalAll(self.io, self.buf.items, self.offset + RECORD_HEADER_LEN);
            if (body_read != body_len) return .{ .torn = remaining };

            var crc = Crc32c.init();
            crc.update(head[0..CRC_OFFSET]);
            crc.update(self.buf.items);
            if (crc.final() != stored_crc) return self.corruptOutcome(.crc_mismatch);

            // `std.enums.values` rather than a `switch` on the raw `u16`: the
            // check stays in step with the enum when a kind is added, instead of
            // silently reporting the new value as unknown.
            const kind = for (std.enums.values(Kind)) |candidate| {
                if (@backingInt(candidate) == kind_raw) break candidate;
            } else return self.corruptOutcome(.unknown_kind);

            self.offset += frame_len;
            self.records += 1;
            return .{ .record = .{
                .seq = std.mem.readInt(u64, head[4..12], .little),
                .track_id = self.buf.items[0..track_len],
                .kind = kind,
                .recorded_ns = std.mem.readInt(i64, head[12..20], .little),
                .payload = self.buf.items[track_len..],
            } };
        }
    }

    fn corruptOutcome(self: *const SegmentReader, reason: CorruptReason) Outcome {
        return .{ .corrupt = .{
            .segment_id = self.segment_id,
            .index = self.records,
            .offset = self.offset,
            .reason = reason,
        } };
    }

    fn closeSegment(self: *SegmentReader) void {
        if (!self.segment_open) return;
        self.file.close(self.io);
        self.segment_open = false;
    }

    fn openSegment(self: *SegmentReader) !void {
        const id = self.ids[self.next_segment];
        self.next_segment += 1;

        var name_buf: [SEGMENT_NAME_LEN]u8 = undefined;
        const file = try self.dir.openFile(self.io, segmentName(id, &name_buf), .{ .mode = .read_only });
        errdefer file.close(self.io);
        const st = try file.stat(self.io);

        // A crash between `createFile` and the header write. Nothing was ever
        // appended, so there is nothing to lose and nothing to report: skip it.
        if (st.size == 0) {
            file.close(self.io);
            return;
        }

        // Adopt a segment only once it has been read far enough to trust, so a
        // rejected one is closed exactly once (by the `errdefer` above) and a
        // torn one is closed by `closeSegment` in `deinit`.
        if (st.size < FILE_HEADER_LEN) {
            // A half-written file header, reported as a torn tail at offset 0 —
            // `repair` truncates the file to nothing and the next open writes a
            // fresh header. Guessing at a magic among those bytes is not this
            // format's business.
            self.adopt(file, id, st.size, 0);
            return;
        }

        var header: [FILE_HEADER_LEN]u8 = undefined;
        if (try file.readPositionalAll(self.io, &header, 0) != FILE_HEADER_LEN) {
            // The file shrank between the stat and the read: it contributes no
            // records and no damage, and a later scan re-stats it.
            file.close(self.io);
            return;
        }

        // Magic, then the header CRC, then the version — in that order on
        // purpose: a *corrupted* version byte is `CorruptHeader` (the header does
        // not verify), while a version a v1 reader genuinely cannot handle is
        // `UnsupportedVersion`.
        if (std.mem.readInt(u32, header[0..4], .little) != MAGIC) return error.BadMagic;
        if (crc32Of(header[0..8]) != std.mem.readInt(u32, header[8..12], .little)) return error.CorruptHeader;
        if (std.mem.readInt(u16, header[4..6], .little) != FORMAT_VERSION) return error.UnsupportedVersion;
        if (std.mem.readInt(u16, header[6..8], .little) != FILE_HEADER_LEN) return error.CorruptHeader;

        self.adopt(file, id, st.size, FILE_HEADER_LEN);
    }

    fn adopt(self: *SegmentReader, file: std.Io.File, id: u64, size: u64, offset: u64) void {
        self.file = file;
        self.segment_open = true;
        self.segment_id = id;
        self.segment_size = size;
        self.offset = offset;
    }
};

// ─────────────────────────────────────────────────
// Format helpers
// ─────────────────────────────────────────────────

/// The record header up to (not including) the CRC: everything the CRC covers
/// together with the body.
fn encodeRecordPrefix(
    frame_len: u32,
    seq: u64,
    recorded_ns: i64,
    payload_len: u32,
    kind: Kind,
    track_id_len: u16,
) [CRC_OFFSET]u8 {
    var buf: [CRC_OFFSET]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], frame_len, .little);
    std.mem.writeInt(u64, buf[4..12], seq, .little);
    std.mem.writeInt(i64, buf[12..20], recorded_ns, .little);
    std.mem.writeInt(u32, buf[20..24], payload_len, .little);
    std.mem.writeInt(u16, buf[24..26], @backingInt(kind), .little);
    std.mem.writeInt(u16, buf[26..28], track_id_len, .little);
    return buf;
}

fn writeFileHeader(file: std.Io.File, io: std.Io, offset: u64) !void {
    var header: [FILE_HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], MAGIC, .little);
    std.mem.writeInt(u16, header[4..6], FORMAT_VERSION, .little);
    std.mem.writeInt(u16, header[6..8], FILE_HEADER_LEN, .little);
    std.mem.writeInt(u32, header[8..12], crc32Of(header[0..8]), .little);
    try file.writePositionalAll(io, &header, offset);
}

/// `delivery-<20 digits>.log`, formatted by hand because the one `bufPrint` call
/// this would otherwise be cannot fail and `catch unreachable` is banned in
/// `src/runtime/` (scripts/check-production.sh). `ID_DIGITS` is exactly `u64`'s
/// decimal width — asserted at comptime above — so no digit is ever dropped.
fn segmentName(id: u64, buf: *[SEGMENT_NAME_LEN]u8) []const u8 {
    @memcpy(buf[0..FILE_PREFIX.len], FILE_PREFIX);
    const digits_end = SEGMENT_NAME_LEN - FILE_SUFFIX.len;
    var value = id;
    var i = digits_end;
    while (i > FILE_PREFIX.len) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }
    @memcpy(buf[digits_end..], FILE_SUFFIX);
    return buf;
}

/// `null` for a name that is not ours: a stray file in the directory
/// (a `.gitignore`, another log's segment) is skipped, not parsed.
fn parseSegmentId(name: []const u8) ?u64 {
    if (name.len != SEGMENT_NAME_LEN) return null;
    if (!std.mem.startsWith(u8, name, FILE_PREFIX)) return null;
    if (!std.mem.endsWith(u8, name, FILE_SUFFIX)) return null;
    const digits = name[FILE_PREFIX.len .. name.len - FILE_SUFFIX.len];
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

fn segmentIds(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u64 {
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = parseSegmentId(entry.name) orelse continue;
        try ids.append(allocator, id);
    }
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    return ids.toOwnedSlice(allocator);
}

fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |r| {
        allocator.free(r.track_id);
        allocator.free(r.payload);
    }
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

/// A unique log directory per test call.
///
/// `std.testing.tmpDir` names it from 12 random bytes under `.zig-cache/tmp`, so
/// the six test binaries `zig build test` runs in parallel cannot collide on it
/// — unlike a fixed relative path, which is how `core/eventbus/WAL.zig`'s tests
/// end up deleting each other's segments (that file works around it with a pid
/// suffix). `cleanup` removes the whole tree.
const TestDir = struct {
    tmp: std.testing.TmpDir,
    path_buf: [160]u8 = undefined,

    fn init() TestDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn path(self: *TestDir) ![]const u8 {
        return std.fmt.bufPrint(&self.path_buf, ".zig-cache/tmp/{s}/delivery", .{self.tmp.sub_path[0..]});
    }

    fn deinit(self: *TestDir) void {
        self.tmp.cleanup();
    }
};

fn testConfig(dir_path: []const u8, max_segment_bytes: u64, max_record_bytes: u32, sync_mode: SyncMode) Config {
    return .{
        .dir_path = dir_path,
        .max_segment_bytes = max_segment_bytes,
        .max_record_bytes = max_record_bytes,
        .sync_mode = sync_mode,
    };
}

fn readSegmentBytes(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, id: u64) ![]u8 {
    const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var name_buf: [SEGMENT_NAME_LEN]u8 = undefined;
    return dir.readFileAlloc(io, segmentName(id, &name_buf), allocator, .limited(1 << 20));
}

fn writeSegmentBytes(io: std.Io, dir_path: []const u8, id: u64, bytes: []const u8) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var name_buf: [SEGMENT_NAME_LEN]u8 = undefined;
    const file = try dir.createFile(io, segmentName(id, &name_buf), .{ .truncate = true, .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

/// The frame size of a record with this track id and payload length.
fn frameSize(track_len: usize, payload_len: usize) u64 {
    return RECORD_HEADER_LEN + track_len + payload_len;
}

/// Count the frames in a segment file by walking them, and refuse a file whose
/// frames do not land exactly on its end. An independent check of "no malformed
/// segment": it trusts only `frame_len`, so a segment holding a half-written
/// frame or a gap between frames fails here.
fn countFrames(bytes: []const u8) !usize {
    var at: usize = FILE_HEADER_LEN;
    var count: usize = 0;
    while (at < bytes.len) {
        if (at + 4 > bytes.len) return error.BadFrameWalk;
        const frame_len: usize = std.mem.readInt(u32, bytes[at..][0..4], .little);
        if (frame_len < RECORD_HEADER_LEN or at + frame_len > bytes.len) return error.BadFrameWalk;
        at += frame_len;
        count += 1;
    }
    return count;
}

/// The shared shape of the payload tests: `n` records, deterministic bytes.
fn makePayloads(comptime n: usize, lens: []const usize, out: *[n][512]u8, slices: *[n][]const u8, seed: u8) void {
    for (0..n) |i| {
        const len = lens[i % lens.len];
        for (out[i][0..len], 0..) |*b, j| b.* = @truncate(i * 31 +% j +% seed);
        slices[i] = out[i][0..len];
    }
}

test "delivery-log: a round trip preserves every field, across segment rotation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const n = 40;
    const tracks = [_][]const u8{ "book", "risk", "t0" };
    const lens = [_]usize{ 0, 1, 2, 31, 63, 100, 173, 224 };
    // 256 bytes a segment against ≥ 32-byte frames: the ceiling forces many
    // rotations, so this really is a cross-segment read.
    const config = testConfig(dir_path, 256, 512, .fsync);

    var payload_bytes: [n][512]u8 = undefined;
    var payloads: [n][]const u8 = undefined;
    makePayloads(n, &lens, &payload_bytes, &payloads, 0);
    // The last record is exactly as large as `max_record_bytes` allows (32-byte
    // header + 3-byte track id + 477 = 512), so it can share no segment and must
    // not be split.
    const biggest_payload = 477;
    for (payload_bytes[n - 1][0..biggest_payload], 0..) |*b, j| b.* = @truncate(j * 13 +% 1);
    payloads[n - 1] = payload_bytes[n - 1][0..biggest_payload];

    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    for (0..n) |i| {
        const ns: i64 = @as(i64, @intCast(i)) * 1000 - 7;
        try writer.append(.{
            .seq = i,
            .track_id = if (i == n - 1) "t0" else tracks[i % tracks.len],
            .kind = if (i % 2 == 0) .message else .timer,
            .recorded_ns = ns,
            .payload = payloads[i],
        });
    }
    try std.testing.expectEqual(@as(u64, n - 1), writer.lastSeq());
    try std.testing.expect(writer.segmentCount() > 3);

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, n), result.records.len);
    for (result.records, 0..) |r, i| {
        const ns: i64 = @as(i64, @intCast(i)) * 1000 - 7;
        try std.testing.expectEqual(@as(u64, i), r.seq);
        try std.testing.expectEqualStrings(if (i == n - 1) "t0" else tracks[i % tracks.len], r.track_id);
        try std.testing.expectEqual(if (i % 2 == 0) Kind.message else Kind.timer, r.kind);
        try std.testing.expectEqual(ns, r.recorded_ns);
        try std.testing.expectEqualSlices(u8, payloads[i], r.payload);
    }

    // No malformed segments: every file carries a header, every file is whole
    // frames from its header to its last byte, and a file over the ceiling holds
    // exactly one record — one that would not have fitted in an empty segment
    // either, never a split frame.
    const segment_count = writer.segmentCount();
    for (0..segment_count) |id| {
        const bytes = try readSegmentBytes(allocator, io, dir_path, id);
        defer allocator.free(bytes);
        try std.testing.expect(bytes.len >= FILE_HEADER_LEN);
        const frames_here = try countFrames(bytes);
        try std.testing.expect(frames_here >= 1);
        if (bytes.len > config.max_segment_bytes) {
            try std.testing.expectEqual(@as(usize, 1), frames_here);
        }
    }
}

test "delivery-log: truncating the tail at every byte offset loses nothing complete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    // One segment, three records of known size, all in it.
    const config = testConfig(dir_path, 1 << 20, 4096, .none);
    const lens = [_]usize{ 4, 5, 11 };
    const track = "book";
    var payload_bytes: [lens.len][512]u8 = undefined;
    var payloads: [lens.len][]const u8 = undefined;
    makePayloads(lens.len, &lens, &payload_bytes, &payloads, 1);

    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    for (lens, 0..) |len, i| {
        try writer.append(.{
            .seq = i,
            .track_id = track,
            .kind = .message,
            .recorded_ns = @intCast(i),
            .payload = payloads[i][0..len],
        });
    }
    try std.testing.expectEqual(@as(usize, 1), writer.segmentCount());

    const full = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(full);

    // Where each record ends, in absolute file offsets.
    var ends: [lens.len]u64 = undefined;
    var at: u64 = FILE_HEADER_LEN;
    for (lens, 0..) |len, i| {
        at += frameSize(track.len, len);
        ends[i] = at;
    }
    try std.testing.expectEqual(@as(u64, @intCast(full.len)), ends[lens.len - 1]);

    // Every byte offset a crash could have left the file at.
    for (0..full.len + 1) |cut| {
        try writeSegmentBytes(io, dir_path, 0, full[0..cut]);

        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);

        // How many records survive a file of exactly `cut` bytes: the ones whose
        // last byte is still there.
        var complete: usize = 0;
        for (ends) |end| {
            if (end <= cut) complete += 1;
        }
        try std.testing.expectEqual(complete, result.records.len);
        // Nothing is delivered partially: every record handed over is
        // byte-identical to what was written.
        for (result.records, 0..) |r, i| {
            try std.testing.expectEqual(@as(u64, i), r.seq);
            try std.testing.expectEqualStrings(track, r.track_id);
            try std.testing.expectEqualSlices(u8, payloads[i][0..lens[i]], r.payload);
        }

        // A zero-byte file, a header-only file, and an exact record boundary are
        // all "clean"; anything else is a torn tail of exactly the bytes after
        // the last complete record.
        const boundary = cut == 0 or cut == FILE_HEADER_LEN or cut == ends[0] or cut == ends[1] or cut == ends[2];
        if (boundary) {
            try std.testing.expectEqual(Damage.none, result.damage);
            try std.testing.expectEqual(@as(u64, 0), result.damagedTailBytes());
            try result.expectClean();
        } else {
            // The last complete boundary at or before `cut`: nothing (a file
            // shorter than its header), the header, or a record end.
            const after: u64 = if (cut > ends[1]) ends[1] else if (cut > ends[0]) ends[0] else if (cut > FILE_HEADER_LEN) FILE_HEADER_LEN else 0;
            try std.testing.expectEqual(cut - after, result.damagedTailBytes());
            try std.testing.expect(result.corruption() == null);
            try std.testing.expectError(error.TornTail, result.expectClean());
        }
    }
}

test "delivery-log: a flipped byte is reported with its index, and the verified prefix is untouched" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 4096, .none);
    const lens = [_]usize{ 4, 5, 11 };
    const track = "book";
    var payload_bytes: [lens.len][512]u8 = undefined;
    var payloads: [lens.len][]const u8 = undefined;
    makePayloads(lens.len, &lens, &payload_bytes, &payloads, 7);

    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    for (lens, 0..) |len, i| {
        try writer.append(.{
            .seq = i,
            .track_id = track,
            .kind = .message,
            .recorded_ns = @intCast(i),
            .payload = payloads[i][0..len],
        });
    }

    const full = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(full);

    var starts: [lens.len]u64 = undefined;
    {
        var at: u64 = FILE_HEADER_LEN;
        for (lens, 0..) |len, i| {
            starts[i] = at;
            at += frameSize(track.len, len);
        }
    }

    // Every payload byte of every record, one at a time: the record carrying the
    // flipped byte is rejected at its own index, and everything before it comes
    // back exactly as written.
    for (lens, 0..) |len, record_index| {
        const payload_at = starts[record_index] + RECORD_HEADER_LEN + track.len;
        for (0..len) |byte| {
            const damaged = try allocator.dupe(u8, full);
            defer allocator.free(damaged);
            damaged[payload_at + byte] ^= 0xff;
            try writeSegmentBytes(io, dir_path, 0, damaged);

            var result = try scan(allocator, io, config);
            defer result.deinit(allocator);

            const c = result.corruption() orelse return error.TestExpectedCorruptRecord;
            try std.testing.expectEqual(CorruptReason.crc_mismatch, c.reason);
            try std.testing.expectEqual(record_index, c.index);
            try std.testing.expectEqual(starts[record_index], c.offset);
            try std.testing.expectEqual(@as(u64, 0), result.damagedTailBytes());

            try std.testing.expectEqual(record_index, result.records.len);
            for (result.records, 0..) |r, i| {
                try std.testing.expectEqual(@as(u64, i), r.seq);
                try std.testing.expectEqualSlices(u8, payloads[i][0..lens[i]], r.payload);
            }
        }
    }

    // A flipped track-id byte is the same class of damage (the CRC covers it).
    {
        const damaged = try allocator.dupe(u8, full);
        defer allocator.free(damaged);
        damaged[starts[1] + RECORD_HEADER_LEN] ^= 0xff;
        try writeSegmentBytes(io, dir_path, 0, damaged);
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        const c = result.corruption() orelse return error.TestExpectedCorruptRecord;
        try std.testing.expectEqual(CorruptReason.crc_mismatch, c.reason);
        try std.testing.expectEqual(@as(usize, 1), c.index);
    }

    // A damaged length field is caught a step earlier, by the header's
    // consistency check — not by the CRC, and never by guessing where the next
    // record starts.
    {
        const damaged = try allocator.dupe(u8, full);
        defer allocator.free(damaged);
        damaged[starts[1] + 20] ^= 0x01; // payload_len
        try writeSegmentBytes(io, dir_path, 0, damaged);
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        const c = result.corruption() orelse return error.TestExpectedCorruptRecord;
        try std.testing.expectEqual(CorruptReason.frame_len_mismatch, c.reason);
        try std.testing.expectEqual(@as(usize, 1), c.index);
        try std.testing.expectEqual(starts[1], c.offset);
    }

    // A `kind` no version of this format knows. The frame is made to verify, so
    // the only thing wrong with it is the value.
    {
        const damaged = try allocator.dupe(u8, full);
        defer allocator.free(damaged);
        const last = lens.len - 1;
        const body_len: usize = @intCast(frameSize(track.len, lens[last]) - RECORD_HEADER_LEN);
        std.mem.writeInt(u16, damaged[starts[last] + 24 ..][0..2], 0x7fff, .little);
        var crc = Crc32c.init();
        crc.update(damaged[starts[last]..][0..CRC_OFFSET]);
        crc.update(damaged[starts[last] + RECORD_HEADER_LEN ..][0..body_len]);
        std.mem.writeInt(u32, damaged[starts[last] + CRC_OFFSET ..][0..4], crc.final(), .little);
        try writeSegmentBytes(io, dir_path, 0, damaged);
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        const c = result.corruption() orelse return error.TestExpectedCorruptRecord;
        try std.testing.expectEqual(CorruptReason.unknown_kind, c.reason);
        try std.testing.expectEqual(@as(usize, last), c.index);
    }

    // …and a scan that stopped on damage refuses to be taken for a whole log.
    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try std.testing.expectError(error.CorruptRecord, result.expectClean());
}

test "delivery-log: a foreign magic, an unsupported version and a rotten header are three errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 4096, .none);
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();
        try writer.append(.{ .seq = 0, .track_id = "book", .kind = .message, .recorded_ns = 5, .payload = "x" });
    }

    const good = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(good);
    const bad = try allocator.dupe(u8, good);
    defer allocator.free(bad);

    // Wrong magic: a file from some other writer. Not "0 records".
    bad[0] ^= 0xff;
    try writeSegmentBytes(io, dir_path, 0, bad);
    try std.testing.expectError(error.BadMagic, scan(allocator, io, config));

    // A version this reader does not know, with the header still verifying: the
    // version is genuinely foreign, not corrupt.
    @memcpy(bad, good);
    std.mem.writeInt(u16, bad[4..6], FORMAT_VERSION + 1, .little);
    std.mem.writeInt(u32, bad[8..12], crc32Of(bad[0..8]), .little);
    try writeSegmentBytes(io, dir_path, 0, bad);
    try std.testing.expectError(error.UnsupportedVersion, scan(allocator, io, config));

    // A version byte damaged in flight (the header CRC does not follow): the
    // header is rotten, which is a different answer from "a newer writer made
    // this" — so the CRC is checked *before* the version.
    @memcpy(bad, good);
    bad[4] ^= 0xff;
    try writeSegmentBytes(io, dir_path, 0, bad);
    try std.testing.expectError(error.CorruptHeader, scan(allocator, io, config));

    // A header that verifies but contradicts itself.
    @memcpy(bad, good);
    std.mem.writeInt(u16, bad[6..8], FILE_HEADER_LEN + 4, .little);
    std.mem.writeInt(u32, bad[8..12], crc32Of(bad[0..8]), .little);
    try writeSegmentBytes(io, dir_path, 0, bad);
    try std.testing.expectError(error.CorruptHeader, scan(allocator, io, config));

    // A foreign file is not ours to append to or to truncate either — and the
    // bytes neither was willing to touch are still there.
    bad[0] ^= 0xff;
    try writeSegmentBytes(io, dir_path, 0, bad);
    try std.testing.expectError(error.BadMagic, Writer.open(allocator, io, config));
    try std.testing.expectError(error.BadMagic, repair(allocator, io, config));
    const after = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, bad, after);
}

test "delivery-log: an empty segment and a header-only segment are 0 records and no damage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 4096, .none);

    // A brand-new log: `open` creates segment 0 with nothing but its header.
    {
        var writer = try Writer.open(allocator, io, config);
        writer.deinit();
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        try result.expectClean();
        try std.testing.expectEqual(@as(usize, 0), result.records.len);
        const bytes = try readSegmentBytes(allocator, io, dir_path, 0);
        defer allocator.free(bytes);
        try std.testing.expectEqual(@as(usize, FILE_HEADER_LEN), bytes.len);
    }

    // Records, then a zero-byte segment and a header-only segment after them:
    // both are skipped, and neither is reported as damage.
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();
        try writer.append(.{ .seq = 0, .track_id = "book", .kind = .message, .recorded_ns = 1, .payload = "a" });
        try writer.append(.{ .seq = 1, .track_id = "risk", .kind = .timer, .recorded_ns = 2, .payload = "bb" });
    }
    try writeSegmentBytes(io, dir_path, 1, &.{});
    const first = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(first);
    try writeSegmentBytes(io, dir_path, 2, first[0..FILE_HEADER_LEN]);

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqualStrings("a", result.records[0].payload);
    try std.testing.expectEqual(Kind.message, result.records[0].kind);
    try std.testing.expectEqualStrings("risk", result.records[1].track_id);
    try std.testing.expectEqual(Kind.timer, result.records[1].kind);
    try std.testing.expectEqual(@as(u64, 1), result.records[1].seq);
}

test "delivery-log: repair truncates a torn tail, is idempotent, and refuses a damaged record" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 4096, .none);
    const lens = [_]usize{ 4, 5, 11 };
    const track = "book";
    var payload_bytes: [lens.len][512]u8 = undefined;
    var payloads: [lens.len][]const u8 = undefined;
    makePayloads(lens.len, &lens, &payload_bytes, &payloads, 3);

    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    for (lens, 0..) |len, i| {
        try writer.append(.{
            .seq = i,
            .track_id = track,
            .kind = .message,
            .recorded_ns = @intCast(i),
            .payload = payloads[i][0..len],
        });
    }

    const full = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(full);
    const last_start = FILE_HEADER_LEN + frameSize(track.len, lens[0]) + frameSize(track.len, lens[1]);

    // Tear the third record in half.
    const cut = last_start + RECORD_HEADER_LEN + 3;
    try writeSegmentBytes(io, dir_path, 0, full[0..cut]);

    {
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), result.records.len);
        try std.testing.expectEqual(cut - last_start, result.damagedTailBytes());
        try std.testing.expectError(error.TornTail, result.expectClean());
        // A torn tail is not a hole: nothing is counted as corrupt.
        try std.testing.expect(result.corruption() == null);
    }

    // The writer will not append past it…
    try std.testing.expectError(error.LogDamaged, Writer.open(allocator, io, config));

    // …and `repair` is what clears it.
    const report = try repair(allocator, io, config);
    try std.testing.expectEqual(@as(?u64, 0), report.segment_id);
    try std.testing.expectEqual(cut - last_start, report.truncated_bytes);
    try std.testing.expectEqual(@as(usize, 2), report.records_kept);

    {
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        try result.expectClean();
        try std.testing.expectEqual(@as(usize, 2), result.records.len);
        for (result.records, 0..) |r, i| {
            try std.testing.expectEqual(@as(u64, i), r.seq);
            try std.testing.expectEqualStrings(track, r.track_id);
            try std.testing.expectEqualSlices(u8, payloads[i][0..lens[i]], r.payload);
        }
    }

    // Idempotent: a second call finds nothing and changes nothing.
    {
        const again = try repair(allocator, io, config);
        try std.testing.expectEqual(@as(?u64, null), again.segment_id);
        try std.testing.expectEqual(@as(u64, 0), again.truncated_bytes);
        try std.testing.expectEqual(@as(usize, 2), again.records_kept);
        const bytes = try readSegmentBytes(allocator, io, dir_path, 0);
        defer allocator.free(bytes);
        try std.testing.expectEqual(last_start, bytes.len);
    }

    // A fully written record that does not verify is *not* repaired: truncating
    // it would delete data that was written, which is not maintenance.
    {
        const damaged = try allocator.dupe(u8, full[0..last_start]);
        defer allocator.free(damaged);
        damaged[FILE_HEADER_LEN + RECORD_HEADER_LEN + track.len] ^= 0x80;
        try writeSegmentBytes(io, dir_path, 0, damaged);
        try std.testing.expectError(error.CorruptRecordNotRepairable, repair(allocator, io, config));
        const bytes = try readSegmentBytes(allocator, io, dir_path, 0);
        defer allocator.free(bytes);
        try std.testing.expectEqual(damaged.len, bytes.len);
    }
}

test "delivery-log: a torn segment that is not the last one is refused, not truncated into a gap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    // Small enough that each record gets a segment of its own.
    const config = testConfig(dir_path, 64, 4096, .none);
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();
        try writer.append(.{ .seq = 0, .track_id = "t", .kind = .message, .recorded_ns = 1, .payload = "aaaa" });
        try writer.append(.{ .seq = 1, .track_id = "t", .kind = .message, .recorded_ns = 2, .payload = "bbbb" });
        try std.testing.expectEqual(@as(usize, 2), writer.segmentCount());
    }

    // Wreck the *first* segment: impossible through this writer (rotation
    // happens before an append, never after a partial one), so `repair` must
    // refuse rather than truncate and pretend the gap is not there.
    const first = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(first);
    try writeSegmentBytes(io, dir_path, 0, first[0 .. FILE_HEADER_LEN + 8]);

    {
        var result = try scan(allocator, io, config);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u64, 8), result.damagedTailBytes());
        try std.testing.expectEqual(@as(usize, 0), result.records.len);
    }

    const second_before = try readSegmentBytes(allocator, io, dir_path, 1);
    defer allocator.free(second_before);
    try std.testing.expectError(error.DamageNotInLastSegment, repair(allocator, io, config));

    // Refused means untouched: both segments are exactly as they were.
    const second_after = try readSegmentBytes(allocator, io, dir_path, 1);
    defer allocator.free(second_after);
    try std.testing.expectEqualSlices(u8, second_before, second_after);
    const first_after = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(first_after);
    try std.testing.expectEqual(@as(usize, FILE_HEADER_LEN + 8), first_after.len);
}

test "delivery-log: a record never straddles a segment, and seq order survives rotation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    // Frames are 32 + 1 + 11 = 44 bytes. 110 = 12 (header) + 44 + 44 + 10: two
    // records fit, the third does not, and the ceiling falls 10 bytes into the
    // third record — the exact case that has to move the whole record.
    const max_segment_bytes: u64 = 110;
    const config = testConfig(dir_path, max_segment_bytes, 4096, .segment_sync);
    const track = "t";
    const payload = "0123456789a";
    try std.testing.expectEqual(@as(u64, 44), frameSize(track.len, payload.len));

    const plain = 6;
    var big: [200]u8 = undefined;
    for (&big, 0..) |*b, j| b.* = @truncate(j);
    const big_frame = FILE_HEADER_LEN + frameSize(track.len, big.len);

    var segment_count: usize = 0;
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();

        for (0..plain) |i| {
            try writer.append(.{ .seq = i, .track_id = track, .kind = .message, .recorded_ns = @intCast(i), .payload = payload });
        }
        // A record larger than the whole ceiling: it gets a segment of its own
        // rather than being split (and does not rotate the log to death).
        try writer.append(.{ .seq = plain, .track_id = track, .kind = .timer, .recorded_ns = 99, .payload = &big });
        try writer.sync();
        for (plain + 1..plain + 4) |i| {
            try writer.append(.{ .seq = i, .track_id = track, .kind = .message, .recorded_ns = @intCast(i), .payload = payload });
        }
        segment_count = writer.segmentCount();
    }

    // Exactly what the ceiling plus whole frames predict: six segments, and only
    // the one holding the oversized record is over the ceiling — by that record's
    // own frame, never by a partial one.
    try std.testing.expectEqual(@as(usize, 6), segment_count);
    const expected_sizes = [_]u64{ 100, 100, 100, big_frame, 100, 56 };
    const expected_frames = [_]usize{ 2, 2, 2, 1, 2, 1 };
    for (expected_sizes, expected_frames, 0..) |expected, frames, id| {
        const bytes = try readSegmentBytes(allocator, io, dir_path, id);
        defer allocator.free(bytes);
        try std.testing.expectEqual(expected, @as(u64, @intCast(bytes.len)));
        // Whole frames only, from the header to the last byte: no split record,
        // no padding, no leftover.
        try std.testing.expectEqual(frames, try countFrames(bytes));
    }

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(plain + 4, result.records.len);
    for (result.records, 0..) |r, i| {
        try std.testing.expectEqual(@as(u64, i), r.seq);
        if (i == plain) {
            try std.testing.expectEqual(Kind.timer, r.kind);
            try std.testing.expectEqualSlices(u8, &big, r.payload);
        } else {
            try std.testing.expectEqual(Kind.message, r.kind);
            try std.testing.expectEqualSlices(u8, payload, r.payload);
        }
    }

    // The order is the order the caller gave: reopen and keep going, and the
    // sequence numbers still only go up.
    var reopened = try Writer.open(allocator, io, config);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, plain + 3), reopened.lastSeq());
    try reopened.append(.{ .seq = plain + 4, .track_id = track, .kind = .message, .recorded_ns = 1, .payload = payload });
    try std.testing.expectError(
        error.SeqNotIncreasing,
        reopened.append(.{ .seq = plain + 4, .track_id = track, .kind = .message, .recorded_ns = 1, .payload = payload }),
    );
    try std.testing.expectError(
        error.SeqNotIncreasing,
        reopened.append(.{ .seq = 0, .track_id = track, .kind = .message, .recorded_ns = 1, .payload = payload }),
    );

    // The oversized record is *not* refused for being big: the byte ceiling is a
    // target, `max_record_bytes` is the bound. Reopened and appended again, it
    // gets a fresh segment to itself — and the reader is bounded by what
    // `max_record_bytes` allows, not by the ceiling.
    try reopened.append(.{ .seq = plain + 5, .track_id = track, .kind = .message, .recorded_ns = 1, .payload = &big });
    try std.testing.expectEqual(@as(usize, 7), reopened.segmentCount());
    const spill = try readSegmentBytes(allocator, io, dir_path, 6);
    defer allocator.free(spill);
    try std.testing.expectEqual(big_frame, @as(u64, @intCast(spill.len)));
    try std.testing.expectEqual(@as(usize, 1), try countFrames(spill));

    var after = try scan(allocator, io, config);
    defer after.deinit(allocator);
    try after.expectClean();
    try std.testing.expectEqual(@as(usize, plain + 6), after.records.len);
    try std.testing.expectEqualSlices(u8, &big, after.records[plain + 5].payload);
}

test "delivery-log: files whose name is not a segment id are ignored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 4096, .none);
    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    try writer.append(.{ .seq = 0, .track_id = "book", .kind = .message, .recorded_ns = 1, .payload = "keep" });

    // A stray file, a 19-digit name (one digit short) and a name with a
    // non-digit in it: none of them is a segment, and none of them breaks the
    // read.
    const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    for ([_][]const u8{ "notes.txt", "delivery-0000000000000000001.log", "delivery-00000000000000000x1.log" }) |name| {
        const file = try dir.createFile(io, name, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, "not a segment", 0);
    }

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualStrings("keep", result.records[0].payload);
}

test "delivery-log: append allocates nothing, not even across a rotation" {
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    defer probe.fail_index = std.math.maxInt(usize);
    const allocator = probe.allocator();
    const config = testConfig(dir_path, 128, 4096, .segment_sync);
    const payload = "0123456789abcdef";
    const n = 300;

    var segment_count: usize = 0;
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();

        // From here on every allocation fails, so an append that allocates at
        // all fails the test instead of merely being slow.
        probe.fail_index = probe.alloc_index;
        const before = probe.allocations;
        for (0..n) |i| {
            try writer.append(.{
                .seq = i,
                .track_id = "sink",
                .kind = .message,
                .recorded_ns = @intCast(i),
                .payload = payload,
            });
        }
        try std.testing.expectEqual(@as(usize, 0), probe.allocations - before);
        // …and it really ran, several rotations deep (128 bytes against
        // 53-byte frames): a zero count for a loop that did nothing would prove
        // nothing.
        segment_count = writer.segmentCount();
        try std.testing.expectEqual(@as(u64, n - 1), writer.lastSeq());
        probe.fail_index = std.math.maxInt(usize);
    }

    try std.testing.expect(segment_count > 10);
    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, n), result.records.len);
    for (result.records, 0..) |r, i| {
        try std.testing.expectEqual(@as(u64, i), r.seq);
        try std.testing.expectEqualStrings("sink", r.track_id);
        try std.testing.expectEqualSlices(u8, payload, r.payload);
    }
}

test "delivery-log: reopening continues the log, and refuses a damaged tail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    const config = testConfig(dir_path, 1 << 20, 64, .segment_sync);
    // A payload that cannot fit in a frame the reader would accept.
    const too_big: [64]u8 = @splat(0);
    {
        var writer = try Writer.open(allocator, io, config);
        defer writer.deinit();
        try writer.append(.{ .seq = 0, .track_id = "book", .kind = .message, .recorded_ns = 10, .payload = "one" });
        try writer.append(.{ .seq = 1, .track_id = "book", .kind = .timer, .recorded_ns = 20, .payload = "two" });
        try std.testing.expectError(
            error.RecordTooLarge,
            writer.append(.{ .seq = 2, .track_id = "book", .kind = .message, .recorded_ns = 30, .payload = &too_big }),
        );
    }

    // A crash three bytes into the second record's payload.
    const full = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(full);
    try writeSegmentBytes(io, dir_path, 0, full[0 .. full.len - 3]);
    try std.testing.expectError(error.LogDamaged, Writer.open(allocator, io, config));

    const report = try repair(allocator, io, config);
    try std.testing.expectEqual(@as(usize, 1), report.records_kept);
    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();
    try std.testing.expectEqual(@as(u64, 0), writer.lastSeq());
    try writer.append(.{ .seq = 2, .track_id = "risk", .kind = .timer, .recorded_ns = 30, .payload = "three" });

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqual(@as(u64, 0), result.records[0].seq);
    try std.testing.expectEqual(@as(u64, 2), result.records[1].seq);
    try std.testing.expectEqual(Kind.timer, result.records[1].kind);
    try std.testing.expectEqualStrings("risk", result.records[1].track_id);
    try std.testing.expectEqual(@as(i64, 30), result.records[1].recorded_ns);
    try std.testing.expectEqualStrings("three", result.records[1].payload);
}

test "delivery-log: the ceiling bounds a frame, and a refused record leaves nothing behind" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var t = TestDir.init();
    defer t.deinit();
    const dir_path = try t.path();

    // `max_record_bytes` bounds the *frame*, which is what the reader enforces:
    // a payload one byte past it is refused on the write path rather than
    // written and then rejected on the read path.
    const config = testConfig(dir_path, 1 << 20, 64, .none);
    var writer = try Writer.open(allocator, io, config);
    defer writer.deinit();

    const exactly = 64 - RECORD_HEADER_LEN - 2; // track id "tx"
    var payload: [exactly]u8 = undefined;
    for (&payload, 0..) |*b, j| b.* = @truncate(j * 7);
    try writer.append(.{ .seq = 0, .track_id = "tx", .kind = .timer, .recorded_ns = -1, .payload = &payload });

    const one_past: [exactly + 1]u8 = @splat(0);
    try std.testing.expectError(
        error.RecordTooLarge,
        writer.append(.{ .seq = 1, .track_id = "tx", .kind = .timer, .recorded_ns = -1, .payload = &one_past }),
    );
    // The refused record left nothing behind: no partial frame, no hole.
    try std.testing.expectEqual(@as(u64, 0), writer.lastSeq());

    var result = try scan(allocator, io, config);
    defer result.deinit(allocator);
    try result.expectClean();
    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualSlices(u8, &payload, result.records[0].payload);
    try std.testing.expectEqual(@as(i64, -1), result.records[0].recorded_ns);
    try std.testing.expectEqual(Kind.timer, result.records[0].kind);

    const bytes = try readSegmentBytes(allocator, io, dir_path, 0);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, FILE_HEADER_LEN + 64), bytes.len);
}
