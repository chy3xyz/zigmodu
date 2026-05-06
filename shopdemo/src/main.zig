const std = @import("std");
const zigmodu = @import("zigmodu");

const ad = @import("modules/ad/root.zig");
const admin = @import("modules/admin/root.zig");
const advance = @import("modules/advance/root.zig");
const agent = @import("modules/agent/root.zig");
const app_mod = @import("modules/app/root.zig");
const article = @import("modules/article/root.zig");
const assemble = @import("modules/assemble/root.zig");
const balance = @import("modules/balance/root.zig");
const bargain = @import("modules/bargain/root.zig");
const buy = @import("modules/buy/root.zig");
const category = @import("modules/category/root.zig");
const center = @import("modules/center/root.zig");
const chat = @import("modules/chat/root.zig");
const comment = @import("modules/comment/root.zig");
const coupon = @import("modules/coupon/root.zig");
const delivery = @import("modules/delivery/root.zig");
const express = @import("modules/express/root.zig");
const image = @import("modules/image/root.zig");
const live = @import("modules/live/root.zig");
const lottery = @import("modules/lottery/root.zig");
const message = @import("modules/message/root.zig");
const order = @import("modules/order/root.zig");
const page = @import("modules/page/root.zig");
const plus = @import("modules/plus/root.zig");
const point = @import("modules/point/root.zig");
const printer = @import("modules/printer/root.zig");
const product = @import("modules/product/root.zig");
const region = @import("modules/region/root.zig");
const register = @import("modules/register/root.zig");
const return = @import("modules/return/root.zig");
const seckill = @import("modules/seckill/root.zig");
const setting = @import("modules/setting/root.zig");
const shop = @import("modules/shop/root.zig");
const sms = @import("modules/sms/root.zig");
const spec = @import("modules/spec/root.zig");
const store = @import("modules/store/root.zig");
const supplier = @import("modules/supplier/root.zig");
const table = @import("modules/table/root.zig");
const tag = @import("modules/tag/root.zig");
const upload = @import("modules/upload/root.zig");
const user = @import("modules/user/root.zig");
const version = @import("modules/version/root.zig");

const business = @import("business/root.zig");

fn envOr(map: *std.process.Environ.Map, allocator: std.mem.Allocator, key: []const u8, default: []const u8) []const u8 {
    if (map.get(key)) |val| return allocator.dupe(u8, val) catch default;
    return default;
}

fn envU16Or(map: *std.process.Environ.Map, key: []const u8, default: u16) u16 {
    const val = map.get(key) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

fn envF64Or(map: *std.process.Environ.Map, key: []const u8, default: f64) f64 {
    const val = map.get(key) orelse return default;
    return std.fmt.parseFloat(f64, val) catch default;
}

fn envBoolOr(map: *std.process.Environ.Map, key: []const u8, default: bool) bool {
    const val = map.get(key) orelse return default;
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const env = init.environ_map;

    const db_host = envOr(env, allocator, "DB_HOST", "127.0.0.1");
    const db_port = envU16Or(env, "DB_PORT", 3306);
    const db_user = envOr(env, allocator, "DB_USER", "root");
    const db_pass = envOr(env, allocator, "DB_PASS", "");
    const db_name = envOr(env, allocator, "DB_NAME", "heysen");
    const db_max_open = envU16Or(env, "DB_MAX_OPEN", 10);
    const db_max_idle = envU16Or(env, "DB_MAX_IDLE", 5);
    const http_port = envU16Or(env, "HTTP_PORT", 8080);

    const db_cfg = zigmodu.sqlx.Config{
        .driver = .mysql, .host = db_host, .port = @intCast(db_port),
        .database = db_name, .username = db_user, .password = db_pass,
        .max_open_conns = @intCast(db_max_open), .max_idle_conns = @intCast(db_max_idle),
    };

    var db_client = zigmodu.sqlx.Client.init(allocator, init.io, db_cfg);
    defer db_client.deinit();
    try db_client.connect();
    std.log.info("DB: {s}@{s}:{d}/{s} (pool={d}/{d})", .{ db_user, db_host, db_port, db_name, db_max_open, db_max_idle });

    const backend = zigmodu.SqlxBackend{ .allocator = allocator, .client = &db_client };

    // -- Persistence --
    var ad_p = ad.persistence.AdPersistence.init(backend);
    var admin_p = admin.persistence.AdminPersistence.init(backend);
    var advance_p = advance.persistence.AdvancePersistence.init(backend);
    var agent_p = agent.persistence.AgentPersistence.init(backend);
    var app_p = app_mod.persistence.AppPersistence.init(backend);
    var article_p = article.persistence.ArticlePersistence.init(backend);
    var assemble_p = assemble.persistence.AssemblePersistence.init(backend);
    var balance_p = balance.persistence.BalancePersistence.init(backend);
    var bargain_p = bargain.persistence.BargainPersistence.init(backend);
    var buy_p = buy.persistence.BuyPersistence.init(backend);
    var category_p = category.persistence.CategoryPersistence.init(backend);
    var center_p = center.persistence.CenterPersistence.init(backend);
    var chat_p = chat.persistence.ChatPersistence.init(backend);
    var comment_p = comment.persistence.CommentPersistence.init(backend);
    var coupon_p = coupon.persistence.CouponPersistence.init(backend);
    var delivery_p = delivery.persistence.DeliveryPersistence.init(backend);
    var express_p = express.persistence.ExpressPersistence.init(backend);
    var image_p = image.persistence.ImagePersistence.init(backend);
    var live_p = live.persistence.LivePersistence.init(backend);
    var lottery_p = lottery.persistence.LotteryPersistence.init(backend);
    var message_p = message.persistence.MessagePersistence.init(backend);
    var order_p = order.persistence.OrderPersistence.init(backend);
    var page_p = page.persistence.PagePersistence.init(backend);
    var plus_p = plus.persistence.PlusPersistence.init(backend);
    var point_p = point.persistence.PointPersistence.init(backend);
    var printer_p = printer.persistence.PrinterPersistence.init(backend);
    var product_p = product.persistence.ProductPersistence.init(backend);
    var region_p = region.persistence.RegionPersistence.init(backend);
    var register_p = register.persistence.RegisterPersistence.init(backend);
    var return_p = return.persistence.ReturnPersistence.init(backend);
    var seckill_p = seckill.persistence.SeckillPersistence.init(backend);
    var setting_p = setting.persistence.SettingPersistence.init(backend);
    var shop_p = shop.persistence.ShopPersistence.init(backend);
    var sms_p = sms.persistence.SmsPersistence.init(backend);
    var spec_p = spec.persistence.SpecPersistence.init(backend);
    var store_p = store.persistence.StorePersistence.init(backend);
    var supplier_p = supplier.persistence.SupplierPersistence.init(backend);
    var table_p = table.persistence.TablePersistence.init(backend);
    var tag_p = tag.persistence.TagPersistence.init(backend);
    var upload_p = upload.persistence.UploadPersistence.init(backend);
    var user_p = user.persistence.UserPersistence.init(backend);
    var version_p = version.persistence.VersionPersistence.init(backend);

    // -- Service --
    var ad_s = ad.service.AdService.init(&ad_p);
    var admin_s = admin.service.AdminService.init(&admin_p);
    var advance_s = advance.service.AdvanceService.init(&advance_p);
    var agent_s = agent.service.AgentService.init(&agent_p);
    var app_s = app_mod.service.AppService.init(&app_p);
    var article_s = article.service.ArticleService.init(&article_p);
    var assemble_s = assemble.service.AssembleService.init(&assemble_p);
    var balance_s = balance.service.BalanceService.init(&balance_p);
    var bargain_s = bargain.service.BargainService.init(&bargain_p);
    var buy_s = buy.service.BuyService.init(&buy_p);
    var category_s = category.service.CategoryService.init(&category_p);
    var center_s = center.service.CenterService.init(&center_p);
    var chat_s = chat.service.ChatService.init(&chat_p);
    var comment_s = comment.service.CommentService.init(&comment_p);
    var coupon_s = coupon.service.CouponService.init(&coupon_p);
    var delivery_s = delivery.service.DeliveryService.init(&delivery_p);
    var express_s = express.service.ExpressService.init(&express_p);
    var image_s = image.service.ImageService.init(&image_p);
    var live_s = live.service.LiveService.init(&live_p);
    var lottery_s = lottery.service.LotteryService.init(&lottery_p);
    var message_s = message.service.MessageService.init(&message_p);
    var order_s = order.service.OrderService.init(&order_p);
    var page_s = page.service.PageService.init(&page_p);
    var plus_s = plus.service.PlusService.init(&plus_p);
    var point_s = point.service.PointService.init(&point_p);
    var printer_s = printer.service.PrinterService.init(&printer_p);
    var product_s = product.service.ProductService.init(&product_p);
    var region_s = region.service.RegionService.init(&region_p);
    var register_s = register.service.RegisterService.init(&register_p);
    var return_s = return.service.ReturnService.init(&return_p);
    var seckill_s = seckill.service.SeckillService.init(&seckill_p);
    var setting_s = setting.service.SettingService.init(&setting_p);
    var shop_s = shop.service.ShopService.init(&shop_p);
    var sms_s = sms.service.SmsService.init(&sms_p);
    var spec_s = spec.service.SpecService.init(&spec_p);
    var store_s = store.service.StoreService.init(&store_p);
    var supplier_s = supplier.service.SupplierService.init(&supplier_p);
    var table_s = table.service.TableService.init(&table_p);
    var tag_s = tag.service.TagService.init(&tag_p);
    var upload_s = upload.service.UploadService.init(&upload_p);
    var user_s = user.service.UserService.init(&user_p);
    var version_s = version.service.VersionService.init(&version_p);

    // -- API --
    var ad_api = ad.api.AdApi.init(&ad_s);
    var admin_api = admin.api.AdminApi.init(&admin_s);
    var advance_api = advance.api.AdvanceApi.init(&advance_s);
    var agent_api = agent.api.AgentApi.init(&agent_s);
    var app_api = app_mod.api.AppApi.init(&app_s);
    var article_api = article.api.ArticleApi.init(&article_s);
    var assemble_api = assemble.api.AssembleApi.init(&assemble_s);
    var balance_api = balance.api.BalanceApi.init(&balance_s);
    var bargain_api = bargain.api.BargainApi.init(&bargain_s);
    var buy_api = buy.api.BuyApi.init(&buy_s);
    var category_api = category.api.CategoryApi.init(&category_s);
    var center_api = center.api.CenterApi.init(&center_s);
    var chat_api = chat.api.ChatApi.init(&chat_s);
    var comment_api = comment.api.CommentApi.init(&comment_s);
    var coupon_api = coupon.api.CouponApi.init(&coupon_s);
    var delivery_api = delivery.api.DeliveryApi.init(&delivery_s);
    var express_api = express.api.ExpressApi.init(&express_s);
    var image_api = image.api.ImageApi.init(&image_s);
    var live_api = live.api.LiveApi.init(&live_s);
    var lottery_api = lottery.api.LotteryApi.init(&lottery_s);
    var message_api = message.api.MessageApi.init(&message_s);
    var order_api = order.api.OrderApi.init(&order_s);
    var page_api = page.api.PageApi.init(&page_s);
    var plus_api = plus.api.PlusApi.init(&plus_s);
    var point_api = point.api.PointApi.init(&point_s);
    var printer_api = printer.api.PrinterApi.init(&printer_s);
    var product_api = product.api.ProductApi.init(&product_s);
    var region_api = region.api.RegionApi.init(&region_s);
    var register_api = register.api.RegisterApi.init(&register_s);
    var return_api = return.api.ReturnApi.init(&return_s);
    var seckill_api = seckill.api.SeckillApi.init(&seckill_s);
    var setting_api = setting.api.SettingApi.init(&setting_s);
    var shop_api = shop.api.ShopApi.init(&shop_s);
    var sms_api = sms.api.SmsApi.init(&sms_s);
    var spec_api = spec.api.SpecApi.init(&spec_s);
    var store_api = store.api.StoreApi.init(&store_s);
    var supplier_api = supplier.api.SupplierApi.init(&supplier_s);
    var table_api = table.api.TableApi.init(&table_s);
    var tag_api = tag.api.TagApi.init(&tag_s);
    var upload_api = upload.api.UploadApi.init(&upload_s);
    var user_api = user.api.UserApi.init(&user_s);
    var version_api = version.api.VersionApi.init(&version_s);

    // -- HTTP Server --
    var server = zigmodu.http_server.Server.init(init.io, allocator, http_port);
    defer server.deinit();
    var root = server.group("/api");

    // Health check
    try root.get("/health", healthCheck, null);

    try ad_api.registerRoutes(&root);
    try admin_api.registerRoutes(&root);
    try advance_api.registerRoutes(&root);
    try agent_api.registerRoutes(&root);
    try app_api.registerRoutes(&root);
    try article_api.registerRoutes(&root);
    try assemble_api.registerRoutes(&root);
    try balance_api.registerRoutes(&root);
    try bargain_api.registerRoutes(&root);
    try buy_api.registerRoutes(&root);
    try category_api.registerRoutes(&root);
    try center_api.registerRoutes(&root);
    try chat_api.registerRoutes(&root);
    try comment_api.registerRoutes(&root);
    try coupon_api.registerRoutes(&root);
    try delivery_api.registerRoutes(&root);
    try express_api.registerRoutes(&root);
    try image_api.registerRoutes(&root);
    try live_api.registerRoutes(&root);
    try lottery_api.registerRoutes(&root);
    try message_api.registerRoutes(&root);
    try order_api.registerRoutes(&root);
    try page_api.registerRoutes(&root);
    try plus_api.registerRoutes(&root);
    try point_api.registerRoutes(&root);
    try printer_api.registerRoutes(&root);
    try product_api.registerRoutes(&root);
    try region_api.registerRoutes(&root);
    try register_api.registerRoutes(&root);
    try return_api.registerRoutes(&root);
    try seckill_api.registerRoutes(&root);
    try setting_api.registerRoutes(&root);
    try shop_api.registerRoutes(&root);
    try sms_api.registerRoutes(&root);
    try spec_api.registerRoutes(&root);
    try store_api.registerRoutes(&root);
    try supplier_api.registerRoutes(&root);
    try table_api.registerRoutes(&root);
    try tag_api.registerRoutes(&root);
    try upload_api.registerRoutes(&root);
    try user_api.registerRoutes(&root);
    try version_api.registerRoutes(&root);

    // Custom business endpoints (add your api_ext routes here):
    // const my_ext = @import("modules/my_module/api_ext.zig");
    // var my_api = my_ext.MyApiExt.init(&my_ext_svc);
    // try my_api.registerRoutes(&root);


    // -- EventBus (Stage B) --
    const event_bus = zigmodu.TypedEventBus(struct { id: i64, name: []const u8 }).init(allocator);
    defer event_bus.deinit();

    // -- Resilience (Stage C) --
    var breaker = try zigmodu.CircuitBreaker.init(allocator, "db", .{ .failure_threshold = 5, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 3 });
    defer breaker.deinit();
    var limiter = try zigmodu.RateLimiter.init(allocator, "api", 1000, 100);
    defer limiter.deinit();

    // -- Cluster (Stage D) --
    const node_id = try std.fmt.allocPrint(allocator, "node-{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
    var dist_bus = try zigmodu.DistributedEventBus.init(allocator, init.io, node_id);
    defer dist_bus.deinit();
    try dist_bus.start(9091);

    std.log.info("42 modules + health check on :{d}", .{ http_port });

    // -- Lifecycle --
    var app = try zigmodu.Application.init(
        init.io, allocator, "shopdemo",
        .{ ad.module, admin.module, advance.module, agent.module, app_mod.module, article.module, assemble.module, balance.module, bargain.module, buy.module, category.module, center.module, chat.module, comment.module, coupon.module, delivery.module, express.module, image.module, live.module, lottery.module, message.module, order.module, page.module, plus.module, point.module, printer.module, product.module, region.module, register.module, return.module, seckill.module, setting.module, shop.module, sms.module, spec.module, store.module, supplier.module, table.module, tag.module, upload.module, user.module, version.module, },
        .{},
    );
    defer app.deinit();

    try app.start();
    try server.start();
}

fn healthCheck(ctx: *zigmodu.http_server.Context) !void {
    try ctx.json(200, "{\"status\":\"ok\"}");
}
