# Workflow & Resumable Saga Orchestration

Applies to: zmodu v0.20+ · Zig 0.17

zmodu provides two WAL-backed workflow engines:
- `core/SagaOrchestrator.zig`: Business transaction orchestration with reverse-order compensation.
- `ai/workflow.zig`: Multi-step AI agent, skill, and approval orchestration (see [AI Orchestration](../ai/AI_ORCHESTRATION.md)).

## 1. Crash Recovery and Checkpoint Semantics

`SagaOrchestrator.restoreFromWal()` loads unfinished saga instances from the write-ahead log (`WAL`), and `resumeInstance(id)` continues execution from the last checkpoint:

| Instance State in WAL | Behavior on `resumeInstance` | Reason |
|-----------------------|------------------------------|--------|
| Step marked `completed` | Skipped | Already committed before the crash |
| `current_step` (in-flight at crash) | Re-executed | No completion record exists; **steps with external side effects must be idempotent** |
| `completed` / `compensated` / `failed` / `timed_out` | Rejected (`error.NothingToResume`) | Terminal states are never re-executed or compensated twice |
| `compensating` (interrupted mid-rollback) | Rejected (`error.NothingToResume`) | Partial compensation requires operator inspection |

```zig
var orch = zmodu.SagaOrchestrator.init(allocator);
defer orch.deinit();

orch.setWal(&wal);                      // Segmented WAL file with fsync
try orch.registerSaga("order", steps);  // Re-register step definitions at startup
try orch.restoreFromWal();              // Reconstruct active `.running` instances

for (orch.listActiveInstances()) |id| {
    try orch.resumeInstance(id);
}
```

## 2. Step Timeouts (`timeout_seconds`)

Always set `SagaStep.timeout_seconds` (defaults to `30` seconds; `0` disables the budget check).

Because an in-process orchestrator cannot preempt a running function, `timeout_seconds` is evaluated when the step's action returns:
- If the step finishes after `timeout_seconds`, the instance transitions to `.timed_out` and `execute` / `resumeInstance` returns `error.SagaStepTimeout`.
- Because the timed-out step's action completed and its side effects took place, the orchestrator compensates **both** the timed-out step and all preceding completed steps in reverse order (whereas a step that returns an error only compensates preceding steps).
- `.timed_out` is a terminal state and is not resumed on restart.

## 3. When to Use `SagaOrchestrator`

Use `SagaOrchestrator` for multi-step workflows that cross external boundaries (such as payment capture, inventory reservation across external services, or settlement pipelines) where failures require reverse-order compensation and process restarts must resume in-flight instances. For single-database multi-table writes, use a database transaction with `persistence.Tx` instead.
