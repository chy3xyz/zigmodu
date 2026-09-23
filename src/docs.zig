const std = @import("std");
const zigmodu = @import("zigmodu");

const MockOrder = struct {
    pub const info = zigmodu.api.Module{
        .name = "order",
        .description = "Order management",
        .dependencies = &.{"inventory"},
    };
};

const MockPayment = struct {
    pub const info = zigmodu.api.Module{
        .name = "payment",
        .description = "Payment processing",
        .dependencies = &.{"order"},
    };
};

const MockInventory = struct {
    pub const info = zigmodu.api.Module{
        .name = "inventory",
        .description = "Inventory tracking",
        .dependencies = &.{},
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("=== Generating ZigModu Documentation ===", .{});

    var modules = try zigmodu.scanModules(allocator, .{ MockOrder, MockPayment, MockInventory });
    defer modules.deinit();

    try zigmodu.validateModules(&modules);

    try zigmodu.generateDocs(&modules, "docs/modules.puml", allocator, io);
    std.log.info("PlantUML docs generated: docs/modules.puml", .{});

    const json = try zigmodu.Documentation.generateJsonDocs(&modules, allocator);
    defer allocator.free(json);

    var json_file = try std.Io.Dir.cwd().createFile(io, "docs/modules.json", .{});
    defer json_file.close(io);
    try json_file.writeStreamingAll(io, json);
    std.log.info("JSON docs generated: docs/modules.json", .{});

    const md = try zigmodu.Documentation.generateMarkdownDocs(&modules, allocator);
    defer allocator.free(md);

    var md_file = try std.Io.Dir.cwd().createFile(io, "docs/modules.md", .{});
    defer md_file.close(io);
    try md_file.writeStreamingAll(io, md);
    std.log.info("Markdown docs generated: docs/modules.md", .{});
}
