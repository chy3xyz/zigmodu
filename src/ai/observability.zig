//! AI orchestration observability aggregation: merges `WorkflowMetrics`,
//! `AgentMetrics` and `TokenQuota` into one Prometheus text response so a
//! single `/metrics`-style endpoint covers the whole AI stack.

const std = @import("std");
const WorkflowMetrics = @import("workflow.zig").WorkflowMetrics;
const AgentMetrics = @import("agent.zig").AgentMetrics;
const TokenQuota = @import("quota.zig").TokenQuota;

pub const AiMetrics = struct {
    workflow: ?*WorkflowMetrics = null,
    agent: ?*AgentMetrics = null,
    quota: ?*TokenQuota = null,
    /// Labels applied to the workflow/agent series.
    workflow_name: []const u8 = "wf",
    agent_name: []const u8 = "agent",

    /// Merge all attached metrics into one Prometheus text document.
    pub fn toPrometheusFormat(self: *AiMetrics, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        if (self.workflow) |wm| {
            const part = try wm.toPrometheusFormat(allocator, self.workflow_name);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        if (self.agent) |am| {
            const part = try am.toPrometheusFormat(allocator, self.agent_name);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        if (self.quota) |q| {
            const part = try q.toPrometheusFormat(allocator);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        return buf.toOwnedSlice(allocator);
    }
};

test "AiMetrics merges workflow, agent and quota series" {
    const allocator = std.testing.allocator;
    var wf = WorkflowMetrics{ .runs = 3, .completed_steps = 7 };
    var agent = AgentMetrics{ .runs = 2, .steps = 5 };
    var quota = TokenQuota.init(allocator, std.testing.io, 100);
    defer quota.deinit();
    try quota.record(1, 30, 30);

    var ai_metrics = AiMetrics{ .workflow = &wf, .agent = &agent, .quota = &quota };
    const out = try ai_metrics.toPrometheusFormat(allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_ai_workflow_runs_total{workflow=\"wf\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_ai_agent_runs_total{agent=\"agent\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_ai_token_quota_used{tenant_id=\"1\"} 60") != null);
}
