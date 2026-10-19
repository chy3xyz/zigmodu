//! Orchestration ports — the value types and behaviour interfaces that let the
//! core (`workflow`, `proposal`, `llm`) drive approval / risk without importing
//! the concrete engines.
//!
//! The engines stay where they are (`approval.zig`, `risk.zig`, `diagnose.zig`)
//! and expose `toPort()` adapters; the core depends on this file only. The data
//! types live here too, because a callback signature like
//! `fn (…, level: RiskLevel)` would otherwise pull `risk.zig` into every
//! consumer.

const std = @import("std");
const SkillContext = @import("skill.zig").SkillContext;

// ── approval ────────────────────────────────────────────────────────────

pub const ApprovalDecision = enum { approved, escalated, rejected };
pub const ApprovalStatus = enum { approved, pending_human, rejected };

/// One step in a human chain. `name` is caller-owned.
pub const ApprovalStep = struct {
    name: []const u8,
};

/// Behaviour the workflow/proposal layers need from an approval chain:
/// submit and answer a status. The concrete `ApprovalFlow` keeps its richer
/// result (entries, run id); the port is the narrow view core needs.
pub const ApprovalPort = struct {
    ptr: *anyopaque,
    submitFn: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
        amount: i64,
        steps: []const ApprovalStep,
    ) anyerror!ApprovalStatus,

    pub fn submit(
        self: ApprovalPort,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
        amount: i64,
        steps: []const ApprovalStep,
    ) !ApprovalStatus {
        return self.submitFn(self.ptr, allocator, ctx, subject, amount, steps);
    }
};

// ── risk ────────────────────────────────────────────────────────────────

pub const RiskLevel = enum { low, medium, high };
pub const RiskDecision = enum { approve, reject, escalate };

pub const RiskResult = struct {
    subject: []const u8,
    score: i32,
    level: RiskLevel,
    decision: RiskDecision,
};

/// Behaviour the proposal layer needs from a risk engine.
pub const RiskPort = struct {
    ptr: *anyopaque,
    reviewFn: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
    ) anyerror!RiskResult,

    pub fn review(
        self: RiskPort,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
    ) !RiskResult {
        return self.reviewFn(self.ptr, allocator, ctx, subject);
    }
};

// ── diagnosis ───────────────────────────────────────────────────────────

pub const AnomalyCase = struct {
    /// Source: "alert" | "recon" | "sla" | "app".
    source: []const u8,
    subject: []const u8,
    severity: enum { info, warning, critical },
    description: []const u8,
};

pub const EvidenceBlock = struct {
    name: []const u8,
    markdown: []const u8,
};
