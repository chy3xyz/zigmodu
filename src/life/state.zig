//! Life — transition state machine with required-field validation.
//! Spec §4.1: validate the transition first, then the required fields;
//! a rejected validation must not mutate any data (callers re-load on error).
//! Terminal states (closed/duplicate/rejected) have no out-edges.

const std = @import("std");
const model = @import("model.zig");

pub const TransitionError = error{
    IllegalTransition,
    MissingAssignee,
    MissingInternalNote,
    MissingLinkedId,
    MissingResolution,
    MissingFixRef,
};

pub const TransitionReq = struct {
    target: model.Status,
    permission: model.Permission,
    needs_assignee: bool = false,
    needs_note: bool = false,
    needs_linked: bool = false,
    needs_resolution: bool = false,
    needs_fix_ref: bool = false,
};

/// Returns the requirement for `from → to`, or null when the transition is
/// not in the spec matrix (terminal states, skips, illegal reversals).
pub fn transitionReq(from: model.Status, to: model.Status) ?TransitionReq {
    const T = TransitionReq;
    return switch (from) {
        .new => switch (to) {
            .triaged => T{ .target = to, .permission = .life_triage, .needs_assignee = true },
            else => null,
        },
        .triaged => switch (to) {
            .confirmed => T{ .target = to, .permission = .life_triage },
            .needs_info => T{ .target = to, .permission = .life_triage, .needs_note = true },
            .duplicate => T{ .target = to, .permission = .life_triage, .needs_linked = true },
            .rejected => T{ .target = to, .permission = .life_triage, .needs_note = true },
            else => null,
        },
        .needs_info => switch (to) {
            .triaged => T{ .target = to, .permission = .life_triage },
            else => null,
        },
        .confirmed => switch (to) {
            .fixed => T{ .target = to, .permission = .life_fix, .needs_resolution = true, .needs_fix_ref = true },
            .rejected => T{ .target = to, .permission = .life_triage, .needs_note = true },
            .triaged => T{ .target = to, .permission = .life_triage, .needs_note = true },
            else => null,
        },
        .fixed => switch (to) {
            .verified => T{ .target = to, .permission = .life_verify },
            .confirmed => T{ .target = to, .permission = .life_fix, .needs_note = true },
            else => null,
        },
        .verified => switch (to) {
            .closed => T{ .target = to, .permission = .life_triage },
            .fixed => T{ .target = to, .permission = .life_verify, .needs_note = true },
            else => null,
        },
        // Terminal states have no out-edges.
        .closed, .duplicate, .rejected => null,
    };
}

fn nonEmpty(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t").len > 0;
}

/// Validate `from → to` against the spec matrix (IllegalTransition), then
/// check the target state's required fields on the prospective issue.
pub fn validate(from: model.Status, to: model.Status, prospective: *const model.Issue) TransitionError!void {
    const req = transitionReq(from, to) orelse return error.IllegalTransition;
    if (req.needs_assignee and !nonEmpty(prospective.assignee)) return error.MissingAssignee;
    if (req.needs_note and !nonEmpty(prospective.internal_note)) return error.MissingInternalNote;
    if (req.needs_linked and !nonEmpty(prospective.linked_id)) return error.MissingLinkedId;
    if (req.needs_resolution and !nonEmpty(prospective.resolution)) return error.MissingResolution;
    if (req.needs_fix_ref and !nonEmpty(prospective.fix_ref)) return error.MissingFixRef;
}

pub fn isTerminal(s: model.Status) bool {
    return switch (s) {
        .closed, .duplicate, .rejected => true,
        else => false,
    };
}

/// Dedup key for CI-sourced issues: sha256 over `source|rule|file|message`,
/// lowercase hex (64 bytes). Two identical failure signatures must map to
/// the same issue (comment appended), not a new one.
pub fn fingerprintHex(source: model.Source, rule: []const u8, file: []const u8, message: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(model.sourceToString(source));
    hasher.update("|");
    hasher.update(rule);
    hasher.update("|");
    hasher.update(file);
    hasher.update("|");
    hasher.update(message);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [64]u8 = undefined;
    const hexdig = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hexdig[b >> 4];
        out[i * 2 + 1] = hexdig[b & 0xf];
    }
    return out;
}

test "transition matrix matches spec" {
    const legal = [_][2]model.Status{
        .{ .new, .triaged },          .{ .triaged, .confirmed },   .{ .triaged, .needs_info },
        .{ .needs_info, .triaged },   .{ .triaged, .duplicate },   .{ .triaged, .rejected },
        .{ .confirmed, .rejected },   .{ .confirmed, .triaged },   .{ .confirmed, .fixed },
        .{ .fixed, .verified },       .{ .fixed, .confirmed },     .{ .verified, .closed },
        .{ .verified, .fixed },
    };
    for (legal) |pair| try std.testing.expect(transitionReq(pair[0], pair[1]) != null);
    const illegal = [_][2]model.Status{
        .{ .closed, .new },      .{ .duplicate, .triaged }, .{ .rejected, .fixed },
        .{ .new, .fixed },       .{ .triaged, .verified },  .{ .verified, .confirmed },
        .{ .closed, .closed },  .{ .new, .new },           .{ .fixed, .triaged },
        .{ .needs_info, .confirmed },
    };
    for (illegal) |pair| try std.testing.expect(transitionReq(pair[0], pair[1]) == null);
}

test "required fields enforced on prospective issue" {
    var iss = model.Issue{ .seq = 1, .title = "t" };
    try std.testing.expectError(error.MissingAssignee, validate(.new, .triaged, &iss));
    iss.assignee = "alice";
    try validate(.new, .triaged, &iss);
    iss.status = .confirmed;
    try std.testing.expectError(error.MissingResolution, validate(.confirmed, .fixed, &iss));
    iss.resolution = "root cause x";
    try std.testing.expectError(error.MissingFixRef, validate(.confirmed, .fixed, &iss));
    iss.fix_ref = "13fed68";
    try validate(.confirmed, .fixed, &iss);
    iss.status = .fixed;
    try std.testing.expectError(error.MissingInternalNote, validate(.fixed, .confirmed, &iss));
    iss.internal_note = "bad fix";
    try validate(.fixed, .confirmed, &iss);
    iss.status = .triaged;
    try std.testing.expectError(error.MissingLinkedId, validate(.triaged, .duplicate, &iss));
    iss.linked_id = "LI-0007";
    try validate(.triaged, .duplicate, &iss);
    iss.linked_id = "";
    iss.internal_note = "";
    try std.testing.expectError(error.MissingInternalNote, validate(.triaged, .needs_info, &iss));
}

test "fixer cannot verify, verifier cannot fix (permission split)" {
    const fix_req = transitionReq(.confirmed, .fixed).?;
    const verify_req = transitionReq(.fixed, .verified).?;
    try std.testing.expectEqual(model.Permission.life_fix, fix_req.permission);
    try std.testing.expectEqual(model.Permission.life_verify, verify_req.permission);
    try std.testing.expect(fix_req.permission != verify_req.permission);
}

test "fingerprint stable and distinct" {
    const a = fingerprintHex(.ci, "b26", "src/x.zig", "msg");
    const b = fingerprintHex(.ci, "b26", "src/x.zig", "msg");
    const c = fingerprintHex(.ci, "b26", "src/x.zig", "msg2");
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    try std.testing.expectEqual(@as(usize, 64), a.len);
    for (a) |ch| try std.testing.expect(std.ascii.isHex(ch) and std.ascii.toLower(ch) == ch);
}
