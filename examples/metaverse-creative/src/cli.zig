//! Agent-facing CLI — DID-centric; creative uses 三域; purchase via P0 settlement.
const std = @import("std");
const identity = @import("modules/identity/root.zig");
const creative = @import("modules/creative/root.zig");
const world = @import("modules/world/root.zig");
const settlement = @import("modules/settlement/root.zig");

pub const App = struct {
    identity: *identity.service.IdentityService,
    creative: *creative.service.CreativeService,
    world: *world.service.WorldService,
    settlement: *settlement.service.SettlementService,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, app: App, args: []const []const u8) !void {
    _ = allocator;
    if (args.len == 0) {
        try printHelp(io);
        return;
    }
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp(io);
        return;
    }
    if (std.mem.eql(u8, cmd, "demo")) {
        try runDemo(io, app);
        return;
    }
    if (std.mem.eql(u8, cmd, "creator")) {
        try cmdCreator(io, app, args[1..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "creative")) {
        try cmdCreative(io, app, args[1..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "world")) {
        try cmdWorld(io, app, args[1..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "settlement") or std.mem.eql(u8, cmd, "purchase")) {
        try cmdSettlement(io, app, if (std.mem.eql(u8, cmd, "purchase")) args else args[1..]);
        return;
    }
    std.log.err("unknown command: {s}", .{cmd});
    try printHelp(io);
}

fn printHelp(io: std.Io) !void {
    const out =
        \\metaverse-creative CLI (DID + 三域 + P0 settlement)
        \\
        \\  zig build demo
        \\  zig-out/bin/metaverse-creative cli creator register --did=DID --name=N --wallet=W
        \\  zig-out/bin/metaverse-creative cli creator get --did=DID
        \\  zig-out/bin/metaverse-creative cli creative draft --owner_did=DID --title=T --slug=S \
        \\       --problem='insight|thesis|vision' --solution='...' --world='...'
        \\  zig-out/bin/metaverse-creative cli creative publish --id=N --price_cents=N
        \\  zig-out/bin/metaverse-creative cli creative list
        \\  zig-out/bin/metaverse-creative cli settlement purchase --id=N --buyer_did=DID --key=K
        \\  zig-out/bin/metaverse-creative cli settlement reconcile
        \\  zig-out/bin/metaverse-creative cli settlement outbox drain
        \\  zig-out/bin/metaverse-creative cli world create --owner_did=DID --name=N --symbol=S
        \\  zig-out/bin/metaverse-creative cli world feature --world_id=N --creative_id=N
        \\  zig-out/bin/metaverse-creative cli world visit --world_id=N --visitor_did=DID
        \\  zig-out/bin/metaverse-creative cli world get --id=N
        \\
        \\Env: ZENT_DRIVER=postgres|sqlite  METHOD.md=三域模板
        \\
    ;
    try writeln(io, out);
}

fn writeln(io: std.Io, msg: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

fn printLine(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    try writeln(io, try std.fmt.bufPrint(&buf, fmt ++ "\n", args));
}

fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    var prefix_buf: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "--{s}=", .{name}) catch return null;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, prefix)) return a[prefix.len..];
    }
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "--{s}", .{name}) catch return null;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], key)) return args[i + 1];
    }
    return null;
}

fn requireFlag(args: []const []const u8, name: []const u8) ![]const u8 {
    return flag(args, name) orelse {
        std.log.err("missing --{s}", .{name});
        return error.MissingFlag;
    };
}

fn cmdCreator(io: std.Io, app: App, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "register")) {
        const did = try requireFlag(args, "did");
        try app.identity.registerCreator(did, try requireFlag(args, "name"), try requireFlag(args, "wallet"));
        try printLine(io, "ok did={s}", .{did});
        return;
    }
    if (std.mem.eql(u8, args[0], "get")) {
        const did = try requireFlag(args, "did");
        const c = (try app.identity.getCreator(did)) orelse {
            try writeln(io, "not_found\n");
            return;
        };
        defer app.identity.freeCreator(c);
        try printLine(io, "ok did={s} name={s} rep={d} verified={}", .{ c.did, c.display_name, c.reputation, c.verified });
        return;
    }
    return error.UnknownSubcommand;
}

fn cmdCreative(io: std.Io, app: App, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "draft")) {
        const id = try app.creative.draft(.{
            .owner_did = try requireFlag(args, "owner_did"),
            .title = try requireFlag(args, "title"),
            .slug = try requireFlag(args, "slug"),
            .problem = try requireFlag(args, "problem"),
            .solution = try requireFlag(args, "solution"),
            .world = try requireFlag(args, "world"),
            .price_cents = std.fmt.parseInt(i64, flag(args, "price_cents") orelse "0", 10) catch 0,
        });
        try printLine(io, "ok id={d} status=draft", .{id});
        return;
    }
    if (std.mem.eql(u8, args[0], "publish")) {
        const id = try std.fmt.parseInt(i64, try requireFlag(args, "id"), 10);
        const price = try std.fmt.parseInt(i64, try requireFlag(args, "price_cents"), 10);
        try app.creative.publish(id, price);
        try printLine(io, "ok id={d} status=published price_cents={d}", .{ id, price });
        return;
    }
    if (std.mem.eql(u8, args[0], "list")) {
        const rows = try app.creative.listPublished();
        defer app.creative.freeList(rows);
        try printLine(io, "ok count={d}", .{rows.len});
        for (rows) |r| {
            try printLine(io, "  id={d} title={s} owner_did={s} price_cents={d}", .{ r.id, r.title, r.owner_did, r.price_cents });
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "buy")) {
        // Compat alias → settlement.purchase (requires --key)
        try cmdSettlementPurchase(io, app, args);
        return;
    }
    return error.UnknownSubcommand;
}

fn cmdSettlement(io: std.Io, app: App, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "purchase")) {
        try cmdSettlementPurchase(io, app, args);
        return;
    }
    if (std.mem.eql(u8, args[0], "reconcile")) {
        const r = try app.settlement.reconcile();
        try printLine(io, "ok ledger_sum={d} payments={d} transfers={d} pending_outbox={d} balanced={}", .{
            r.ledger_sum_cents,
            r.succeeded_payments,
            r.transfers,
            r.pending_outbox,
            r.balanced,
        });
        return;
    }
    if (std.mem.eql(u8, args[0], "outbox")) {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "drain")) return error.UnknownSubcommand;
        const n = try app.settlement.drainOutbox();
        try printLine(io, "ok published={d}", .{n});
        return;
    }
    return error.UnknownSubcommand;
}

fn cmdSettlementPurchase(io: std.Io, app: App, args: []const []const u8) !void {
    const id = try std.fmt.parseInt(i64, try requireFlag(args, "id"), 10);
    const buyer = try requireFlag(args, "buyer_did");
    const key = try requireFlag(args, "key");
    const license = flag(args, "license") orelse "personal";
    const r = try app.settlement.purchase(.{
        .idempotency_key = key,
        .creative_id = id,
        .buyer_did = buyer,
        .license = license,
    });
    try printLine(io, "ok payment_id={d} sale_id={d} transfer_id={d} amount={d} fee={d} net={d} replay={}", .{
        r.payment_id,
        r.sale_id,
        r.transfer_id,
        r.amount_cents,
        r.platform_fee_cents,
        r.seller_net_cents,
        r.idempotent_replay,
    });
}

fn cmdWorld(io: std.Io, app: App, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, args[0], "create")) {
        const id = try app.world.create(
            try requireFlag(args, "owner_did"),
            try requireFlag(args, "name"),
            try requireFlag(args, "symbol"),
            std.fmt.parseInt(i64, flag(args, "entry_fee_cents") orelse "100", 10) catch 100,
        );
        try printLine(io, "ok id={d}", .{id});
        return;
    }
    if (std.mem.eql(u8, args[0], "feature")) {
        try app.world.feature(
            try std.fmt.parseInt(i64, try requireFlag(args, "world_id"), 10),
            try std.fmt.parseInt(i64, try requireFlag(args, "creative_id"), 10),
        );
        try writeln(io, "ok\n");
        return;
    }
    if (std.mem.eql(u8, args[0], "visit")) {
        const fee = try app.world.visitWorld(
            try std.fmt.parseInt(i64, try requireFlag(args, "world_id"), 10),
            try requireFlag(args, "visitor_did"),
        );
        try printLine(io, "ok fee_cents={d}", .{fee});
        return;
    }
    if (std.mem.eql(u8, args[0], "get")) {
        const id = try std.fmt.parseInt(i64, try requireFlag(args, "id"), 10);
        const w = (try app.world.get(id)) orelse {
            try writeln(io, "not_found\n");
            return;
        };
        defer app.world.free(w);
        try printLine(io, "ok id={d} name={s} owner_did={s} visitors={d} revenue_cents={d} featured={d}", .{ w.id, w.name, w.owner_did, w.visitor_count, w.revenue_cents, w.featured_creative_id });
        return;
    }
    return error.UnknownSubcommand;
}

fn runDemo(io: std.Io, app: App) !void {
    std.log.info("demo: creators (DID)", .{});
    try app.identity.registerCreator("did:mv:alice", "Alice - 3D Architect", "0xAlice");
    try app.identity.updateReputation("did:mv:alice", 3500);
    try app.identity.verifyCreator("did:mv:alice");
    try app.identity.registerCreator("did:mv:bob", "Bob - Texture Artist", "0xBob");
    try app.identity.updateReputation("did:mv:bob", 1800);

    std.log.info("demo: publish creative (三域)", .{});
    const cid = try app.creative.draft(.{
        .owner_did = "did:mv:alice",
        .title = "Neo Tokyo Street Pack",
        .slug = "neo-tokyo-street",
        .problem = "Creators cannot package sellable world slices|Asset equals structured idea|Any idea ships priced and world-attachable",
        .solution = "Three-domain template + marketplace|Publish then buy with royalty|Reputation discounts world entry",
        .world = "metaverse Neo-Tokyo 2077|scene pack + featured id|Neon rain high-rep cheaper entry",
    });
    try app.creative.publish(cid, 2500);

    std.log.info("demo: world visit + P0 purchase", .{});
    const wid = try app.world.create("did:mv:alice", "Neo-Tokyo 2077", "NEOTOK", 100);
    try app.world.feature(wid, cid);
    const fee = try app.world.visitWorld(wid, "did:mv:alice");

    const key = "demo-purchase-bob-v1";
    const sale = try app.settlement.purchase(.{
        .idempotency_key = key,
        .creative_id = cid,
        .buyer_did = "did:mv:bob",
        .license = "personal",
    });
    const replay = try app.settlement.purchase(.{
        .idempotency_key = key,
        .creative_id = cid,
        .buyer_did = "did:mv:bob",
        .license = "personal",
    });
    if (!replay.idempotent_replay) return error.IdempotencyFailed;
    if (replay.payment_id != sale.payment_id) return error.IdempotencyMismatch;

    const report = try app.settlement.reconcile();
    if (!report.balanced) return error.LedgerUnbalanced;
    const drained = try app.settlement.drainOutbox();

    const w = (try app.world.get(wid)).?;
    defer app.world.free(w);
    try printLine(io, "demo_ok creative={d} world={d} visit_fee={d} sale={d} payment={d} fee={d} net={d} balanced={} outbox={d} revenue={d}", .{
        cid,
        wid,
        fee,
        sale.sale_id,
        sale.payment_id,
        sale.platform_fee_cents,
        sale.seller_net_cents,
        report.balanced,
        drained,
        w.revenue_cents,
    });
}
