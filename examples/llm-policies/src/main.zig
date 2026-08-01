//! llm-policies: LLM-Powered Policies wiring demo.
//!
//! Shows how to connect the real `AiProvider` to the built-in LLM policies
//! (`llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify`), exactly as
//! described in docs/LLM_POLICIES.md.
//!
//! With `LLM_ENDPOINT` + `LLM_API_KEY` + `LLM_MODEL` set it calls the real
//! model; otherwise it falls back to an injected fake `json_fn` so the demo
//! and its tests stay green without network access.
//!
//! Run:  LLM_ENDPOINT=... LLM_API_KEY='Bearer sk-...' LLM_MODEL=... zig build run
//! Test: zig build test   (fake json_fn, no network)

const std = @import("std");
const zigmodu = @import("zigmodu");

const ai = zigmodu.ai;

// ── Fake model (no network): scripted JSON replies per policy ─────────────
const FakeKind = enum { approve, escalate, diagnose, pass };
var fake_kind: FakeKind = .approve;

fn fakeJson(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
    var obj = std.json.ObjectMap{};
    switch (fake_kind) {
        .approve => {
            try obj.put(a, try a.dupe(u8, "decision"), .{ .string = try a.dupe(u8, "approve") });
            try obj.put(a, try a.dupe(u8, "note"), .{ .string = try a.dupe(u8, "policy ok (fake)") });
        },
        .escalate => {
            try obj.put(a, try a.dupe(u8, "decision"), .{ .string = try a.dupe(u8, "escalate") });
        },
        .pass => {
            try obj.put(a, try a.dupe(u8, "pass"), .{ .bool = true });
        },
        .diagnose => {
            try obj.put(a, try a.dupe(u8, "summary"), .{ .string = try a.dupe(u8, "payment gateway rejected") });
            var causes_arr = std.json.Array.init(a);
            try causes_arr.append(.{ .string = try a.dupe(u8, "bad credentials") });
            try obj.put(a, try a.dupe(u8, "causes"), .{ .array = causes_arr });
            var actions_arr = std.json.Array.init(a);
            try actions_arr.append(.{ .string = try a.dupe(u8, "rotate credentials") });
            try obj.put(a, try a.dupe(u8, "actions"), .{ .array = actions_arr });
        },
    }
    return .{ .object = obj };
}

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const endpoint = init.environ_map.get("LLM_ENDPOINT") orelse "";
    const api_key = init.environ_map.get("LLM_API_KEY") orelse "";
    const model = init.environ_map.get("LLM_MODEL") orelse "gpt-4o-mini";

    var http = zigmodu.http.HttpClient.init(allocator, io, 4, 30000);
    defer http.deinit();
    var provider = ai.AiProvider.init(allocator, &http, endpoint, api_key, model);
    var policy_ctx = if (api_key.len == 0) blk: {
        std.debug.print("== demo mode: no LLM_API_KEY, using fake json_fn ==\n\n", .{});
        break :blk ai.llm.LlmPolicyCtx{ .json_fn = fakeJson };
    } else blk: {
        std.debug.print("== real mode: {s} ({s}) ==\n\n", .{ model, endpoint });
        break :blk ai.llm.LlmPolicyCtx{ .provider = &provider };
    };
    var ctx = ai.SkillContext{ .allocator = allocator, .userdata = &policy_ctx };

    // 1. Approval decision.
    fake_kind = .approve;
    var note: []const u8 = "";
    const decision = try ai.llm.llmApprove(allocator, &ctx, "order-42", 150000, 0, "finance", "tenant=1 orders=12", &note);
    std.debug.print("1. llmApprove   : {s} (note: {s})\n", .{ @tagName(decision), note });
    defer if (note.len > 0) allocator.free(note);

    // 2. Risk decision.
    fake_kind = .escalate;
    const risk = try ai.llm.llmRiskDecide(allocator, &ctx, "order-42", 95, .high);
    std.debug.print("2. llmRiskDecide: {s}\n", .{@tagName(risk)});

    // 3. Diagnosis (evidence blocks → summary/causes/actions).
    fake_kind = .diagnose;
    const evidence = [_]ai.diagnose.EvidenceBlock{
        .{ .name = "failed orders", .markdown = "| id | status |\n|---|---|\n| 1 | failed |" },
    };
    var causes = std.ArrayList([]const u8).empty;
    defer {
        for (causes.items) |c| allocator.free(c);
        causes.deinit(allocator);
    }
    var actions = std.ArrayList([]const u8).empty;
    defer {
        for (actions.items) |a| allocator.free(a);
        actions.deinit(allocator);
    }
    var summary: []const u8 = "";
    defer if (summary.len > 0) allocator.free(summary);
    try ai.llm.llmDiagnose(allocator, &ctx, .{ .source = "alert", .subject = "orders", .severity = .critical, .description = "failed spike" }, &evidence, &causes, &actions, &summary);
    std.debug.print("3. llmDiagnose  : {s} → causes={d} actions={d}\n", .{ summary, causes.items.len, actions.items.len });

    // 4. Workflow quality gate.
    fake_kind = .pass;
    const ok = try ai.llm.llmVerify(&ctx, "produce a report", "report with amounts", allocator);
    std.debug.print("4. llmVerify    : {s}\n", .{if (ok) "pass" else "fail"});

    std.debug.print("\ndone — wiring as documented in docs/LLM_POLICIES.md\n", .{});
}

test "llm-policies wiring works with a fake model" {
    const allocator = std.testing.allocator;
    var policy_ctx = ai.llm.LlmPolicyCtx{ .json_fn = fakeJson };
    var ctx = ai.SkillContext{ .allocator = allocator, .userdata = &policy_ctx };

    fake_kind = .approve;
    var note: []const u8 = "";
    const decision = try ai.llm.llmApprove(allocator, &ctx, "order-1", 100, 0, "ops", "", &note);
    defer if (note.len > 0) allocator.free(note);
    try std.testing.expectEqual(ai.approval.ApprovalDecision.approved, decision);

    fake_kind = .escalate;
    const risk = try ai.llm.llmRiskDecide(allocator, &ctx, "order-1", 80, .medium);
    try std.testing.expectEqual(ai.risk.RiskDecision.escalate, risk);

    fake_kind = .pass;
    try std.testing.expect(try ai.llm.llmVerify(&ctx, "goal", "output", allocator));
}
