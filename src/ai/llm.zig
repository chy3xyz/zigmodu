//! LLM-backed default policies ("开箱即用"): wire `DiagnosisFlow` /
//! `ApprovalFlow` / `RiskReview` to an `AiProvider` with these built-in
//! callbacks instead of writing your own. Each policy prompts the model for
//! a small JSON object and parses it; failures fall back to a safe default
//! (escalate / escalate) so a flaky model never silently approves.

const std = @import("std");
const provider_mod = @import("provider.zig");
const SkillContext = @import("skill.zig").SkillContext;
const freeValue = @import("skill.zig").freeValue;
const diagnose_mod = @import("diagnose.zig");
const approval_mod = @import("approval.zig");
const risk_mod = @import("risk.zig");

pub const AiProvider = provider_mod.AiProvider;

/// JSON round-trip used by the policies (real provider or test fake).
pub const LlmJsonFn = *const fn (
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    system: []const u8,
    user: []const u8,
) anyerror!std.json.Value;

/// Shared capability bundle for the LLM-backed policies. `userdata` of the
/// `SkillContext` passed to the flow must point to this value.
pub const LlmPolicyCtx = struct {
    provider: ?*AiProvider = null,
    json_fn: LlmJsonFn = llmJson,
    /// Optional RAG retriever: its top-k chunks are injected into the policy
    /// prompts as business context (policies, history, playbooks...).
    retriever: ?@import("retriever.zig").Retriever = null,
    /// Query used for retrieval (e.g. "approval policy for high-value orders").
    retrieval_query: []const u8 = "",
    top_k: usize = 3,
    /// Optional extra system-prompt guidance (e.g. company policy).
    system_hint: []const u8 = "",
};

/// Default implementation: chat with the provider and parse its JSON reply.
pub fn llmJson(
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    system: []const u8,
    user: []const u8,
) anyerror!std.json.Value {
    const pc: *LlmPolicyCtx = @ptrCast(@alignCast(userdata));
    const provider = pc.provider orelse return error.LlmNotConfigured;

    const messages = [_]provider_mod.AiProvider.ChatMsg{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = user },
    };
    var resp = try provider.chat(&messages);
    defer provider.freeResponse(&resp);

    const trimmed = std.mem.trim(u8, resp.content, " \n\t");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    errdefer parsed.deinit();
    return parsed.value;
}

/// Retrieve top-k chunks and render them as a "Business context:" block.
/// Returns "" when no retriever is configured or retrieval yields nothing.
pub fn buildContext(pc: *LlmPolicyCtx, allocator: std.mem.Allocator) ![]const u8 {
    const retriever = pc.retriever orelse return "";
    const chunks = try retriever.retrieve(allocator, pc.retrieval_query, pc.top_k);
    defer retriever.free(allocator, chunks);
    if (chunks.len == 0) return "";

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "Business context:\n");
    for (chunks) |c| {
        try buf.appendSlice(allocator, "- ");
        if (c.source.len > 0) {
            try buf.appendSlice(allocator, "[");
            try buf.appendSlice(allocator, c.source);
            try buf.appendSlice(allocator, "] ");
        }
        try buf.appendSlice(allocator, c.text);
        try buf.appendSlice(allocator, "\n");
    }
    return buf.toOwnedSlice(allocator);
}

/// Diagnosis policy: asks the model for `{"summary","causes":[],"actions":[]}`
/// and fills the flow's out-arrays (strings owned by the flow).
pub fn llmDiagnose(
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    case: diagnose_mod.AnomalyCase,
    evidence: []const diagnose_mod.EvidenceBlock,
    out_causes: *std.ArrayList([]const u8),
    out_actions: *std.ArrayList([]const u8),
    out_summary: *[]const u8,
) anyerror!void {
    const pc: *LlmPolicyCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.LlmNotConfigured));

    var evidence_buf = std.ArrayList(u8).empty;
    defer evidence_buf.deinit(allocator);
    for (evidence) |e| {
        try evidence_buf.appendSlice(allocator, e.name);
        try evidence_buf.appendSlice(allocator, ":\n");
        try evidence_buf.appendSlice(allocator, e.markdown);
        try evidence_buf.appendSlice(allocator, "\n");
    }

    const rag_block = try buildContext(pc, allocator);
    defer if (rag_block.len > 0) allocator.free(rag_block);
    const user = try std.fmt.allocPrint(
        allocator,
        "Anomaly: source={s} subject={s} severity={s} description={s}\n\n{s}Evidence:\n{s}\nRespond with JSON only: {{\"summary\":\"...\",\"causes\":[\"...\"],\"actions\":[\"...\"]}}",
        .{ case.source, case.subject, @tagName(case.severity), case.description, rag_block, evidence_buf.items },
    );
    defer allocator.free(user);

    const json = try pc.json_fn(pc, allocator, "You are a senior SRE diagnosing business anomalies. Output only JSON.", user);
    defer freeValue(allocator, json);
    const obj = json.object;

    out_summary.* = try allocator.dupe(u8, (obj.get("summary") orelse return error.MalformedLlmResponse).string);
    const causes = (obj.get("causes") orelse return error.MalformedLlmResponse).array;
    for (causes.items) |c| try out_causes.append(allocator, try allocator.dupe(u8, c.string));
    const actions = (obj.get("actions") orelse return error.MalformedLlmResponse).array;
    for (actions.items) |a| try out_actions.append(allocator, try allocator.dupe(u8, a.string));
}

/// Approval policy: asks the model for `{"decision":"approve|escalate|reject",
/// "note":"..."}`. Malformed or unknown decisions fall back to `escalated`.
pub fn llmApprove(
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_index: usize,
    step_name: []const u8,
    _context_block: []const u8,
    out_note: *[]const u8,
) anyerror!approval_mod.ApprovalDecision {
    const pc: *LlmPolicyCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.LlmNotConfigured));
    _ = _context_block;
    const rag_block = try buildContext(pc, allocator);
    defer if (rag_block.len > 0) allocator.free(rag_block);
    const user = try std.fmt.allocPrint(
        allocator,
        "Approval request: subject={s} amount={d} step={d}:{s}\n{s}Respond with JSON only: {{\"decision\":\"approve|escalate|reject\",\"note\":\"...\"}}",
        .{ subject, amount, step_index, step_name, rag_block },
    );
    defer allocator.free(user);

    const json = pc.json_fn(pc, allocator, "You are an approval officer. Output only JSON.", user) catch {
        out_note.* = try allocator.dupe(u8, "LLM unavailable; escalated for human review");
        return .escalated;
    };
    defer freeValue(allocator, json);
    const obj = json.object;
    const decision = (obj.get("decision") orelse return .escalated).string;
    if (obj.get("note")) |n| out_note.* = try allocator.dupe(u8, n.string);

    if (std.mem.eql(u8, decision, "approve")) return .approved;
    if (std.mem.eql(u8, decision, "reject")) return .rejected;
    return .escalated;
}

/// Risk decision policy: asks the model whether to approve / escalate / reject
/// given the risk score and level. Malformed responses fall back to `escalate`.
pub fn llmRiskDecide(
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    score: i32,
    level: risk_mod.RiskLevel,
) anyerror!risk_mod.RiskDecision {
    const pc: *LlmPolicyCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.LlmNotConfigured));
    const context_block = try buildContext(pc, allocator);
    defer if (context_block.len > 0) allocator.free(context_block);
    const user = try std.fmt.allocPrint(
        allocator,
        "Risk review: subject={s} score={d} level={s}\n{s}Respond with JSON only: {{\"decision\":\"approve|escalate|reject\"}}",
        .{ subject, score, @tagName(level), context_block },
    );
    defer allocator.free(user);

    const json = pc.json_fn(pc, allocator, "You are a risk officer. Output only JSON.", user) catch return .escalate;
    defer freeValue(allocator, json);
    const decision = (json.object.get("decision") orelse return .escalate).string;
    if (std.mem.eql(u8, decision, "approve")) return .approve;
    if (std.mem.eql(u8, decision, "reject")) return .reject;
    return .escalate;
}

/// LLM-backed quality gate for `Workflow.reflection` (matches `VerifyFn`):
/// asks the model whether `output` satisfies `goal` and returns
/// `{"pass":true|false}`. Model failures and malformed responses return
/// `false` (conservative — the step is re-run / escalated).
pub fn llmVerify(
    ctx: *SkillContext,
    goal: []const u8,
    output: []const u8,
    allocator: std.mem.Allocator,
) anyerror!bool {
    const pc: *LlmPolicyCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.LlmNotConfigured));
    const user = try std.fmt.allocPrint(
        allocator,
        "Goal: {s}\n\nOutput:\n{s}\n\nRespond with JSON only: {{\"pass\":true,\"reason\":\"...\"}}",
        .{ goal, output },
    );
    defer allocator.free(user);

    const json = pc.json_fn(pc, allocator, "You verify whether an AI output meets a goal. Output only JSON.", user) catch return false;
    defer freeValue(allocator, json);
    const pass = (json.object.get("pass") orelse return false).bool;
    return pass;
}

fn fakeJson(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
    var obj = std.json.ObjectMap{};
    try putOwned(&obj, allocator, "decision", .{ .string = try allocator.dupe(u8, "approve") });
    try putOwned(&obj, allocator, "note", .{ .string = try allocator.dupe(u8, "ok by policy") });
    return .{ .object = obj };
}

fn diagnoseJson(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
    var obj = std.json.ObjectMap{};
    try putOwned(&obj, allocator, "summary", .{ .string = try allocator.dupe(u8, "gateway rejected") });
    var causes = std.json.Array.init(allocator);
    try causes.append(.{ .string = try allocator.dupe(u8, "bad credentials") });
    try putOwned(&obj, allocator, "causes", .{ .array = causes });
    var actions = std.json.Array.init(allocator);
    try actions.append(.{ .string = try allocator.dupe(u8, "rotate credentials") });
    try putOwned(&obj, allocator, "actions", .{ .array = actions });
    return .{ .object = obj };
}

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

test "buildContext injects retrieved policy chunks into the approval prompt" {
    const allocator = std.testing.allocator;

    var retriever = @import("retriever.zig").KeywordRetriever.init(allocator);
    defer retriever.deinit();
    try retriever.add("policy-1", "approval policy: large orders above 100000 always need CFO approval.", "approval-policy");
    const retriever_iface = retriever.asRetriever();

    const Capture = struct {
        var seen_prompt: []const u8 = "";
        fn f(_: *anyopaque, a: std.mem.Allocator, _: []const u8, user: []const u8) anyerror!std.json.Value {
            seen_prompt = try a.dupe(u8, user);
            var obj = std.json.ObjectMap{};
            try putOwned(&obj, a, "decision", .{ .string = try a.dupe(u8, "escalate") });
            return .{ .object = obj };
        }
    };

    var policy_ctx = LlmPolicyCtx{
        .json_fn = Capture.f,
        .retriever = retriever_iface,
        .retrieval_query = "approval policy",
    };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
    var note: []const u8 = "";
    const decision = try llmApprove(allocator, &ctx, "order-1", 150000, 0, "finance", "", &note);
    defer allocator.free(note);
    defer allocator.free(Capture.seen_prompt);
    try std.testing.expectEqual(approval_mod.ApprovalDecision.escalated, decision);
    try std.testing.expect(std.mem.indexOf(u8, Capture.seen_prompt, "approval policy: large orders above 100000 always need CFO approval.") != null);
    try std.testing.expect(std.mem.indexOf(u8, Capture.seen_prompt, "approval-policy") != null);
}

test "llmApprove approves with a canned model response" {
    const allocator = std.testing.allocator;
    var policy_ctx = LlmPolicyCtx{ .json_fn = fakeJson };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
    var note: []const u8 = "";
    const decision = try llmApprove(allocator, &ctx, "order-1", 9000, 0, "finance", "context", &note);
    try std.testing.expectEqual(approval_mod.ApprovalDecision.approved, decision);
    try std.testing.expectEqualStrings("ok by policy", note);
    allocator.free(note);
}

test "llmApprove falls back to escalate when the model fails" {
    const allocator = std.testing.allocator;
    const FailJson = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
            return error.ProviderUnreachable;
        }
    };
    var policy_ctx = LlmPolicyCtx{ .json_fn = FailJson.f };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
    var note: []const u8 = "";
    const decision = try llmApprove(allocator, &ctx, "order-1", 9000, 0, "finance", "", &note);
    try std.testing.expectEqual(approval_mod.ApprovalDecision.escalated, decision);
    try std.testing.expect(std.mem.indexOf(u8, note, "escalated") != null);
    allocator.free(note);
}

test "llmVerify gates on the model's judgement" {
    const allocator = std.testing.allocator;
    const Gate = struct {
        var pass: bool = false;
        fn f(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
            var obj = std.json.ObjectMap{};
            try putOwned(&obj, a, "pass", .{ .bool = @This().pass });
            return .{ .object = obj };
        }
    };
    var policy_ctx = LlmPolicyCtx{ .json_fn = Gate.f };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };

    Gate.pass = true;
    try std.testing.expect(try llmVerify(&ctx, "goal", "output", allocator));
    Gate.pass = false;
    try std.testing.expect(!try llmVerify(&ctx, "goal", "output", allocator));
}

test "llmVerify fails conservatively when the model errors" {
    const allocator = std.testing.allocator;
    const FailJson = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
            return error.ProviderUnreachable;
        }
    };
    var policy_ctx = LlmPolicyCtx{ .json_fn = FailJson.f };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
    try std.testing.expect(!try llmVerify(&ctx, "goal", "output", allocator));
}

test "llmDiagnose parses summary, causes and actions" {
    const allocator = std.testing.allocator;
    var policy_ctx = LlmPolicyCtx{ .json_fn = diagnoseJson };
    var ctx = SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
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
    const evidence = [_]diagnose_mod.EvidenceBlock{};
    try llmDiagnose(allocator, &ctx, .{ .source = "alert", .subject = "orders", .severity = .critical, .description = "spike" }, &evidence, &causes, &actions, &summary);
    try std.testing.expectEqualStrings("gateway rejected", summary);
    try std.testing.expectEqual(@as(usize, 1), causes.items.len);
    try std.testing.expectEqualStrings("bad credentials", causes.items[0]);
    try std.testing.expectEqualStrings("rotate credentials", actions.items[0]);
}
