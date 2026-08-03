#!/usr/bin/env python3
"""Re-apply zmsaas custom business-logic edits after `zmodu saas` regeneration.

`zmodu saas` overwrites model/persistence/service/api/module/root in the
orders module. This script re-applies the demo customizations (DTO whitelist,
CrudOpts dto/bulk/sortable, cancel/fulfill actions, event export) so the
workflow is: regenerate -> reapply-custom.py -> build/test.

Usage: python3 examples/zmsaas/scripts/reapply-custom.py
"""

from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "backend/src/modules/orders"

# --- model.zig: append OrdersDto after the generated Orders struct ----------
MODEL_DTO = '''
/// Response DTO whitelist (CrudOpts.dto): list/get 只暴露业务字段，
/// `org_id`/`created_at`/`updated_at` 等内部列不上 wire。
pub const OrdersDto = struct {
    id: i64 = 0,
    customer: []const u8 = "",
    amount: i64 = 0,
    status: []const u8 = "",
    notes: []const u8 = "",
};
'''

# --- service.zig: validate extensions + cancel + fulfill (insert before the
# generated transact passthrough) -------------------------------------------
SERVICE_CUSTOM = '''
        if (e.amount <= 0) return error.ValidationFailed; // 金额必须为正
        if (e.status.len == 0) return error.ValidationFailed;
    }

    /// Custom business logic — state machine: only `pending` orders can be
    /// cancelled. Reuses the base path (crud.get + crud.update) so the write
    /// still runs `validate` and publishes CrudEvent.updated, with zero new
    /// SQL. Called from OrdersActionsApi `POST {id}/cancel`.
    pub fn cancel(self: *@This(), allocator: std.mem.Allocator, org_id: i64, id: i64) !void {
        const e = (try self.crud.get(allocator, org_id, id)) orelse return error.NotFound;
        if (!std.mem.eql(u8, e.status, "pending")) return error.Conflict;
        var updated = e;
        updated.status = "cancelled";
        try self.crud.update(updated, org_id);
    }

    /// 真实的多写事务演示：CAS 状态更新（pending→paid）+ 审计插入，同一事务
    /// 内完成，任一失败整体回滚。回调携带运行时上下文（transactWith）。
    /// 状态不符（非 pending）→ Conflict(409)，不写审计行。
    pub const FulfillCtx = struct { allocator: std.mem.Allocator, org_id: i64, id: i64, now: i64, payload: []const u8 };

    pub fn fulfill(self: *@This(), allocator: std.mem.Allocator, org_id: i64, id: i64) !void {
        const now = zigmodu.Time.monotonicNowSeconds();
        const payload = try std.fmt.allocPrint(allocator, "{{\\"order_id\\":{d},\\"action\\":\\"fulfilled\\"}}", .{id});
        defer allocator.free(payload);
        const ok = try self.transactWith(bool, FulfillCtx, FulfillCtx{ .allocator = allocator, .org_id = org_id, .id = id, .now = now, .payload = payload }, struct {
            fn f(tx: *zigmodu.data.sqlx.Transaction, c: FulfillCtx) zigmodu.ZigModuError!bool {
                const res = try tx.exec("UPDATE orders SET status = ?, updated_at = ? WHERE id = ? AND org_id = ? AND status = ?", &.{
                    .{ .string = "paid" },
                    .{ .int = c.now },
                    .{ .int = c.id },
                    .{ .int = c.org_id },
                    .{ .string = "pending" },
                });
                if (res.rows_affected != 1) return false;
                _ = try tx.exec("INSERT INTO order_events (order_id, action, created_at) VALUES (?, ?, ?)", &.{
                    .{ .int = c.id },
                    .{ .string = "fulfilled" },
                    .{ .int = c.now },
                });
                // 事务性 outbox：与业务写同一事务提交，投递至少一次。
                var publisher = zigmodu.outbox.OutboxPublisher.init(c.allocator, .{});
                const insert = try publisher.buildInsert("order.fulfilled", c.payload);
                _ = try tx.exec(insert.sql, &.{
                    .{ .string = insert.params.topic },
                    .{ .string = insert.params.payload },
                    .{ .int = @intCast(insert.params.max_retries) },
                    .{ .int = insert.params.created_at },
                    .{ .int = insert.params.updated_at },
                });
                return true;
            }
        }.f);
        if (!ok) return error.Conflict;
    }

'''

# --- api.zig: CrudOpts + OrdersActionsApi -----------------------------------
API_OPTS = '''pub const OrdersApi = zigmodu.http.CrudApi(model.Orders, service.OrdersService, .{
    .dto = model.OrdersDto,
    .bulk = true,
    .sortable = &.{ "id", "amount", "status" },
});
'''

API_ACTIONS = '''

// Custom endpoints coexist with autoCrud: same nest, disjoint paths. Mounted
// alongside OrdersApi in main.zig (assertNoDupes only rejects duplicate
// method+path pairs).
pub const OrdersActionsApi = struct {
    pub const module_name = "orders";
    pub const nest = .{"orders"};
    pub const State = @This();

    service: *service.OrdersService,

    pub fn init(s: *service.OrdersService) @This() {
        return .{ .service = s };
    }

    pub const routes = [_]zigmodu.http.RouteSpec(State){
        .{ .method = .POST, .path = "{id}/cancel", .handler = cancel, .meta = .{ .auth = .jwt, .permission = "orders:write" } },
        .{ .method = .POST, .path = "{id}/fulfill", .handler = fulfill, .meta = .{ .auth = .jwt, .permission = "orders:write" } },
    };

    fn cancel(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_str = ctx.getAttr("tenant_id") orelse return error.Unauthorized;
        const org_id = std.fmt.parseInt(i64, org_str, 10) catch return error.Unauthorized;
        const id = try ctx.paramInt(i64, "id");
        self.service.cancel(ctx.allocator, org_id, id) catch |err| return zigmodu.http.respondErr(ctx, err);
        try ctx.jsonStruct(200, .{ .code = 0, .status = "cancelled" });
    }

    fn fulfill(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_str = ctx.getAttr("tenant_id") orelse return error.Unauthorized;
        const org_id = std.fmt.parseInt(i64, org_str, 10) catch return error.Unauthorized;
        const id = try ctx.paramInt(i64, "id");
        self.service.fulfill(ctx.allocator, org_id, id) catch |err| return zigmodu.http.respondErr(ctx, err);
        try ctx.jsonStruct(200, .{ .code = 0, .status = "paid" });
    }
};
'''


def apply_model(p: Path) -> bool:
    text = p.read_text()
    if "OrdersDto" in text:
        return False
    p.write_text(text + MODEL_DTO)
    return True


def apply_service(p: Path) -> bool:
    text = p.read_text()
    if "pub fn fulfill" in text:
        return False
    anchor = "    /// Multi-statement atomic writes: runs `f` inside a transaction"
    idx = text.index(anchor)
    # validate 扩展插在生成的 validate 尾括号前（anchored on the generated check）
    val = text.index("if (e.customer.len == 0) return error.ValidationFailed;")
    val_end = text.index("}", val) + 1
    head = text[:val_end]
    # 去掉生成的 validate 闭括号，换自定义闭括号（多两条规则）
    head = head[: head.rindex("    }")] + "    " + SERVICE_CUSTOM.lstrip()
    p.write_text(head + text[val_end:].replace(anchor, anchor, 1))
    return True


def apply_api(p: Path) -> bool:
    text = p.read_text()
    changed = False
    if "OrdersActionsApi" not in text:
        text = text.replace(
            "const zigmodu = @import(\"zigmodu\");",
            "const std = @import(\"std\");\nconst zigmodu = @import(\"zigmodu\");",
            1,
        )
        text = text.replace(
            "pub const OrdersApi = zigmodu.http.CrudApi(model.Orders, service.OrdersService, .{});",
            API_OPTS,
            1,
        )
        text += API_ACTIONS
        changed = True
    p.write_text(text)
    return changed


def apply_root(p: Path) -> bool:
    text = p.read_text()
    if "pub const events" in text:
        return False
    p.write_text(text.replace("pub const api = @import(\"api.zig\");", "pub const api = @import(\"api.zig\");\npub const events = @import(\"events.zig\");", 1))
    return True


def main() -> None:
    changed = 0
    changed += apply_model(MOD / "model.zig")
    changed += apply_service(MOD / "service.zig")
    changed += apply_api(MOD / "api.zig")
    changed += apply_root(MOD / "root.zig")
    print(f"reapply-custom: applied {changed} file(s) (0 = already customized)")


if __name__ == "__main__":
    main()
