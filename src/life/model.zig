//! Life — core data model for the issue/release governance system.
//! Spec: docs/superpowers/specs/2026-10-16-life-issue-release-design.md
//! Pure data + enum text codecs; no IO, zero dependencies beyond std.

const std = @import("std");

pub const Status = enum {
    new,
    triaged,
    confirmed,
    fixed,
    verified,
    closed,
    needs_info,
    duplicate,
    rejected,
};

pub const Category = enum {
    bug,
    feat,
    perf,
    ux,
    docs,
    other,
};

pub const Source = enum {
    user,
    agent,
    ci,
    bench,
    stress,
};

pub const Priority = enum {
    p0,
    p1,
    p2,
    p3,
};

pub const Permission = enum {
    life_triage,
    life_fix,
    life_verify,
    life_manage,
};

pub const Audience = enum {
    public_,
    internal,
};

pub const ReleaseStatus = enum {
    draft,
    published,
    archived,
};

pub const Comment = struct {
    at: i64,
    author: []const u8,
    text: []const u8,
};

pub const Issue = struct {
    seq: u32,
    title: []const u8,
    body: []const u8 = "",
    category: Category = .bug,
    source: Source = .user,
    status: Status = .new,
    priority: Priority = .p2,
    reporter: []const u8 = "",
    assignee: []const u8 = "",
    created_at: i64 = 0,
    updated_at: i64 = 0,
    resolution: []const u8 = "",
    fix_ref: []const u8 = "",
    linked_id: []const u8 = "",
    internal_note: []const u8 = "",
    fingerprint: []const u8 = "",
    repro_lines: []const u8 = "",
    comments: []const Comment = &.{},
};

pub const Release = struct {
    version: []const u8,
    title: []const u8,
    summary: []const u8 = "",
    items_json: []const u8 = "[]",
    status: ReleaseStatus = .draft,
    audience: Audience = .public_,
    source: []const u8 = "auto",
    since_at: i64 = 0,
    published_at: i64 = 0,
    git_sha: []const u8 = "",
};

// ---- enum <-> string codecs (frontmatter wire format) ----
// Zig 0.17: Type.Enum exposes field_names/field_values (not `fields`).

fn enumFromString(comptime T: type, s: []const u8) ?T {
    const info = @typeInfo(T).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (std.mem.eql(u8, s, name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn lowerEnumFromString(comptime T: type, s0: []const u8) ?T {
    var buf: [16]u8 = undefined;
    if (s0.len > buf.len) return null;
    const s = std.ascii.lowerString(&buf, s0);
    return enumFromString(T, s);
}

pub fn statusFromString(s: []const u8) ?Status {
    return enumFromString(Status, s);
}

pub fn statusToString(v: Status) []const u8 {
    return @tagName(v);
}

pub fn categoryFromString(s: []const u8) ?Category {
    return enumFromString(Category, s);
}

pub fn categoryToString(v: Category) []const u8 {
    return @tagName(v);
}

pub fn sourceFromString(s: []const u8) ?Source {
    return enumFromString(Source, s);
}

pub fn sourceToString(v: Source) []const u8 {
    return @tagName(v);
}

pub fn priorityFromString(s: []const u8) ?Priority {
    return lowerEnumFromString(Priority, s);
}

pub fn priorityToString(v: Priority) []const u8 {
    return switch (v) {
        .p0 => "P0",
        .p1 => "P1",
        .p2 => "P2",
        .p3 => "P3",
    };
}

pub fn permissionFromString(s: []const u8) ?Permission {
    return enumFromString(Permission, s);
}

pub fn permissionToString(v: Permission) []const u8 {
    return @tagName(v);
}

pub fn audienceFromString(s: []const u8) ?Audience {
    if (std.mem.eql(u8, s, "public")) return .public_;
    if (std.mem.eql(u8, s, "internal")) return .internal;
    return null;
}

pub fn audienceToString(v: Audience) []const u8 {
    return switch (v) {
        .public_ => "public",
        .internal => "internal",
    };
}

pub fn releaseStatusFromString(s: []const u8) ?ReleaseStatus {
    return enumFromString(ReleaseStatus, s);
}

pub fn releaseStatusToString(v: ReleaseStatus) []const u8 {
    return @tagName(v);
}

test "enum string round trip" {
    try std.testing.expectEqual(Status.confirmed, statusFromString("confirmed").?);
    try std.testing.expect(statusFromString("nope") == null);
    try std.testing.expectEqualStrings("needs_info", statusToString(.needs_info));
    try std.testing.expectEqual(Priority.p1, priorityFromString("P1").?);
    try std.testing.expectEqual(Audience.public_, audienceFromString("public").?);
    try std.testing.expectEqualStrings("public", audienceToString(.public_));
}
