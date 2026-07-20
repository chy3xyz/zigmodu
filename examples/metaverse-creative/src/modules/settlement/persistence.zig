const std = @import("std");
const zent = @import("zent");
const schema = @import("../../schema.zig");
const model = @import("model.zig");
const creative_persist = @import("../creative/persistence.zig");

pub const SettlementStore = struct {
    db: *schema.Client,
    allocator: std.mem.Allocator,
    by_key: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, client: *schema.Client) SettlementStore {
        return .{
            .db = client,
            .allocator = allocator,
            .by_key = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *SettlementStore) void {
        var it = self.by_key.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.by_key.deinit();
    }

    pub fn findPaymentId(self: *SettlementStore, key: []const u8) ?i64 {
        return self.by_key.get(key);
    }

    pub fn loadPayment(self: *SettlementStore, id: i64) !?model.PaymentDto {
        var q = self.db.payment_intent.Query();
        defer q.deinit();
        const preds = self.db.payment_intent.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        var found = try q.All();
        defer {
            for (found.items) |*p| {
                zent.codegen.deinitEntity(schema.infos, schema.PaymentIntentInfo, p, self.allocator);
            }
            found.deinit();
        }
        if (found.items.len == 0) return null;
        const p = found.items[0];
        return .{
            .id = p.id,
            .idempotency_key = try self.allocator.dupe(u8, p.idempotency_key),
            .status = try self.allocator.dupe(u8, p.status),
            .amount_cents = p.amount_cents,
            .creative_id = p.creative_id,
            .buyer_did = try self.allocator.dupe(u8, p.buyer_did),
        };
    }

    pub fn freePayment(self: *SettlementStore, p: model.PaymentDto) void {
        self.allocator.free(p.idempotency_key);
        self.allocator.free(p.status);
        self.allocator.free(p.buyer_did);
    }

    pub fn findTransferByPayment(self: *SettlementStore, payment_id: i64) !?i64 {
        var q = self.db.ownership_transfer.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*t| {
                zent.codegen.deinitEntity(schema.infos, schema.OwnershipTransferInfo, t, self.allocator);
            }
            found.deinit();
        }
        for (found.items) |t| {
            if (t.payment_id == payment_id) return t.id;
        }
        return null;
    }

    pub fn findSaleByPayment(self: *SettlementStore, payment_id: i64) !?i64 {
        var q = self.db.sale.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*s| {
                zent.codegen.deinitEntity(schema.infos, schema.SaleInfo, s, self.allocator);
            }
            found.deinit();
        }
        for (found.items) |s| {
            if (s.payment_id == payment_id) return s.id;
        }
        return null;
    }

    pub fn purchase(
        self: *SettlementStore,
        creatives: *creative_persist.CreativeStore,
        cmd: model.PurchaseCmd,
    ) !model.PurchaseResult {
        if (self.findPaymentId(cmd.idempotency_key)) |pid| {
            const pay = (try self.loadPayment(pid)) orelse return error.PaymentCorrupt;
            defer self.freePayment(pay);
            if (std.mem.eql(u8, pay.status, "succeeded")) {
                return .{
                    .payment_id = pid,
                    .transfer_id = (try self.findTransferByPayment(pid)) orelse 0,
                    .sale_id = (try self.findSaleByPayment(pid)) orelse 0,
                    .amount_cents = pay.amount_cents,
                    .platform_fee_cents = 0,
                    .seller_net_cents = 0,
                    .idempotent_replay = true,
                };
            }
            return error.PaymentInFlight;
        }

        const item = (try creatives.get(cmd.creative_id)) orelse return error.NotFound;
        defer creatives.freeDto(item);
        if (!std.mem.eql(u8, item.status, "published")) return error.NotForSale;
        if (std.mem.eql(u8, item.owner_did, cmd.buyer_did)) return error.CannotBuyOwn;
        if (item.price_cents < 0) return error.InvalidPrice;

        const amount = item.price_cents;
        const platform_fee = @divTrunc(amount * schema.platform_fee_bps, 10000);
        const seller_net = amount - platform_fee;

        var txc = try zent.codegen.client.beginTx(schema.infos, self.db.*);
        errdefer txc.rollback() catch {};
        defer txc.deinit();
        const tx = &txc.client;

        var pb = try tx.payment_intent.Create();
        defer pb.deinit();
        _ = try pb.setFieldValue("idempotency_key", cmd.idempotency_key);
        _ = try pb.setFieldValue("creative_id", cmd.creative_id);
        _ = try pb.setFieldValue("buyer_did", cmd.buyer_did);
        _ = try pb.setFieldValue("amount_cents", amount);
        _ = try pb.setFieldValue("platform_fee_cents", platform_fee);
        _ = try pb.setFieldValue("seller_net_cents", seller_net);
        _ = try pb.setFieldValue("status", "succeeded");
        _ = try pb.setFieldValue("currency", "USD");
        var payment = try pb.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.PaymentIntentInfo, &payment, self.allocator);
        const payment_id = payment.id;

        var buyer_acct: [160]u8 = undefined;
        const buyer_a = try std.fmt.bufPrint(&buyer_acct, "buyer:{s}", .{cmd.buyer_did});
        var seller_acct: [160]u8 = undefined;
        const seller_a = try std.fmt.bufPrint(&seller_acct, "seller:{s}", .{item.owner_did});
        try addEntry(tx, self.allocator, payment_id, buyer_a, -amount, "purchase debit");
        try addEntry(tx, self.allocator, payment_id, seller_a, seller_net, "seller net");
        try addEntry(tx, self.allocator, payment_id, "platform:fee", platform_fee, "platform fee");

        var tb = try tx.ownership_transfer.Create();
        defer tb.deinit();
        _ = try tb.setFieldValue("creative_id", cmd.creative_id);
        _ = try tb.setFieldValue("from_did", item.owner_did);
        _ = try tb.setFieldValue("to_did", cmd.buyer_did);
        _ = try tb.setFieldValue("payment_id", payment_id);
        _ = try tb.setFieldValue("license", cmd.license);
        var transfer = try tb.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.OwnershipTransferInfo, &transfer, self.allocator);
        const transfer_id = transfer.id;

        const preds = tx.creative.predicates;
        var u = tx.creative.Update();
        defer u.deinit();
        _ = try u.set("owner_did", .{ .string = cmd.buyer_did });
        _ = try u.set("status", .{ .string = "sold" });
        _ = try u.Where(.{preds.idEQ(.{ .int = cmd.creative_id })});
        _ = try u.Save();

        var sb = try tx.sale.Create();
        defer sb.deinit();
        _ = try sb.setFieldValue("creative_id", cmd.creative_id);
        _ = try sb.setFieldValue("seller_did", item.owner_did);
        _ = try sb.setFieldValue("buyer_did", cmd.buyer_did);
        _ = try sb.setFieldValue("price_cents", amount);
        _ = try sb.setFieldValue("royalty_cents", @as(i64, 0));
        _ = try sb.setFieldValue("payment_id", payment_id);
        var sale = try sb.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.SaleInfo, &sale, self.allocator);
        const sale_id = sale.id;

        var payload_buf: [128]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "{{\"payment_id\":{d},\"creative_id\":{d}}}", .{ payment_id, cmd.creative_id });
        var ob = try tx.outbox_event.Create();
        defer ob.deinit();
        _ = try ob.setFieldValue("topic", "payment.succeeded");
        _ = try ob.setFieldValue("payload", payload);
        _ = try ob.setFieldValue("status", "pending");
        _ = try ob.setFieldValue("retry_count", @as(i64, 0));
        var oev = try ob.Save();
        defer zent.codegen.deinitEntity(schema.infos, schema.OutboxEventInfo, &oev, self.allocator);

        try txc.commit();

        const key = try self.allocator.dupe(u8, cmd.idempotency_key);
        errdefer self.allocator.free(key);
        try self.by_key.put(key, payment_id);

        return .{
            .payment_id = payment_id,
            .transfer_id = transfer_id,
            .sale_id = sale_id,
            .amount_cents = amount,
            .platform_fee_cents = platform_fee,
            .seller_net_cents = seller_net,
            .idempotent_replay = false,
        };
    }

    pub fn reconcile(self: *SettlementStore) !model.ReconcileReport {
        var sum: i64 = 0;
        var ledger_q = self.db.ledger_entry.Query();
        defer ledger_q.deinit();
        var ledgers = try ledger_q.All();
        defer {
            for (ledgers.items) |*e| {
                zent.codegen.deinitEntity(schema.infos, schema.LedgerEntryInfo, e, self.allocator);
            }
            ledgers.deinit();
        }
        for (ledgers.items) |e| sum += e.amount_cents;

        var pay_ok: usize = 0;
        var pay_q = self.db.payment_intent.Query();
        defer pay_q.deinit();
        var pays = try pay_q.All();
        defer {
            for (pays.items) |*p| {
                zent.codegen.deinitEntity(schema.infos, schema.PaymentIntentInfo, p, self.allocator);
            }
            pays.deinit();
        }
        for (pays.items) |p| {
            if (std.mem.eql(u8, p.status, "succeeded")) pay_ok += 1;
        }

        var xfer_q = self.db.ownership_transfer.Query();
        defer xfer_q.deinit();
        var xfers = try xfer_q.All();
        defer {
            for (xfers.items) |*t| {
                zent.codegen.deinitEntity(schema.infos, schema.OwnershipTransferInfo, t, self.allocator);
            }
            xfers.deinit();
        }

        var pending: usize = 0;
        var ob_q = self.db.outbox_event.Query();
        defer ob_q.deinit();
        var obs = try ob_q.All();
        defer {
            for (obs.items) |*o| {
                zent.codegen.deinitEntity(schema.infos, schema.OutboxEventInfo, o, self.allocator);
            }
            obs.deinit();
        }
        for (obs.items) |o| {
            if (std.mem.eql(u8, o.status, "pending")) pending += 1;
        }

        return .{
            .ledger_sum_cents = sum,
            .succeeded_payments = pay_ok,
            .transfers = xfers.items.len,
            .pending_outbox = pending,
            .balanced = sum == 0,
        };
    }

    pub fn drainOutbox(self: *SettlementStore) !usize {
        var q = self.db.outbox_event.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*o| {
                zent.codegen.deinitEntity(schema.infos, schema.OutboxEventInfo, o, self.allocator);
            }
            found.deinit();
        }
        var n: usize = 0;
        const preds = self.db.outbox_event.predicates;
        for (found.items) |o| {
            if (!std.mem.eql(u8, o.status, "pending")) continue;
            var u = self.db.outbox_event.Update();
            defer u.deinit();
            _ = try u.set("status", .{ .string = "published" });
            _ = try u.Where(.{preds.idEQ(.{ .int = o.id })});
            _ = try u.Save();
            n += 1;
            std.log.info("[outbox] published id={d} topic={s}", .{ o.id, o.topic });
        }
        return n;
    }
};

fn addEntry(
    tx: *schema.Client,
    allocator: std.mem.Allocator,
    journal_id: i64,
    account: []const u8,
    amount: i64,
    memo: []const u8,
) !void {
    var b = try tx.ledger_entry.Create();
    defer b.deinit();
    _ = try b.setFieldValue("journal_id", journal_id);
    _ = try b.setFieldValue("account", account);
    _ = try b.setFieldValue("amount_cents", amount);
    _ = try b.setFieldValue("memo", memo);
    var row = try b.Save();
    defer zent.codegen.deinitEntity(schema.infos, schema.LedgerEntryInfo, &row, allocator);
}
