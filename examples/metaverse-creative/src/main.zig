const std = @import("std");
const zigmodu = @import("zigmodu");

const db_mod = @import("db.zig");
const cli = @import("cli.zig");

const identity_mod = @import("modules/identity/module.zig");
const creative_mod = @import("modules/creative/module.zig");
const world_mod = @import("modules/world/module.zig");
const settlement_mod = @import("modules/settlement/module.zig");

const identity = @import("modules/identity/root.zig");
const creative = @import("modules/creative/root.zig");
const world = @import("modules/world/root.zig");
const settlement = @import("modules/settlement/root.zig");

/// Metaverse Creative — ZigModu + zent best-practice demo (P0 settlement).
///
///   ZENT_DRIVER=sqlite zig build run -- cli demo
///   ZENT_DRIVER=postgres zig build run -- cli demo
///   ZENT_DRIVER=sqlite zig build run -- serve
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var db = try db_mod.Db.open(allocator, init.environ_map);
    defer db.deinit();
    try db.migrateAndBind();

    var id_store = identity.persistence.IdentityStore.init(allocator, &db.client);
    defer id_store.deinit();
    var cr_store = creative.persistence.CreativeStore.init(allocator, &db.client);
    var wo_store = world.persistence.WorldStore.init(allocator, &db.client);
    var st_store = settlement.persistence.SettlementStore.init(allocator, &db.client);
    defer st_store.deinit();

    var id_svc = identity.service.IdentityService.init(&id_store);
    var cr_svc = creative.service.CreativeService.init(&cr_store);
    var wo_svc = world.service.WorldService.init(&wo_store);
    wo_svc.withIdentity(&id_svc);
    var st_svc = settlement.service.SettlementService.init(&st_store, &cr_store);

    var modules = try zigmodu.scanModules(allocator, .{ identity_mod, creative_mod, world_mod, settlement_mod });
    defer modules.deinit();
    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    const app = cli.App{
        .identity = &id_svc,
        .creative = &cr_svc,
        .world = &wo_svc,
        .settlement = &st_svc,
    };

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.skip(); // argv0

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    while (arg_it.next()) |a| {
        try args.append(allocator, a);
    }

    if (args.items.len == 0) {
        try cli.run(io, allocator, app, &.{"help"});
        return;
    }

    if (std.mem.eql(u8, args.items[0], "serve")) {
        try serveHttp(io, allocator, &id_svc, &cr_svc, &wo_svc, &st_svc, init.environ_map);
        return;
    }

    if (std.mem.eql(u8, args.items[0], "cli")) {
        try cli.run(io, allocator, app, args.items[1..]);
        return;
    }

    try cli.run(io, allocator, app, args.items);
}

fn serveHttp(
    io: std.Io,
    allocator: std.mem.Allocator,
    id_svc: *identity.service.IdentityService,
    cr_svc: *creative.service.CreativeService,
    wo_svc: *world.service.WorldService,
    st_svc: *settlement.service.SettlementService,
    env: *const std.process.Environ.Map,
) !void {
    const port: u16 = blk: {
        if (env.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 18200;
        }
        break :blk 18200;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();

    var id_api = identity.api.IdentityApi(@TypeOf(id_svc.*)).init(id_svc);
    var cr_api = creative.api.CreativeApi(@TypeOf(cr_svc.*)).init(cr_svc);
    var wo_api = world.api.WorldApi(@TypeOf(wo_svc.*)).init(wo_svc);
    var st_api = settlement.api.SettlementApi(@TypeOf(st_svc.*)).init(st_svc);

    var v1 = server.group("/api/v1");
    try id_api.registerRoutes(&v1);
    try cr_api.registerRoutes(&v1);
    try wo_api.registerRoutes(&v1);
    try st_api.registerRoutes(&v1);

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\",\"app\":\"metaverse-creative\"}");
            }
        }.handle,
    });

    std.log.info("[main] listening http://127.0.0.1:{d}", .{port});
    std.log.info("[main] CLI preferred for agents: zig build run -- cli help", .{});
    try server.start();
}
