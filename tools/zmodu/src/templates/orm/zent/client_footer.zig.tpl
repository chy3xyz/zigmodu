 });

pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);

pub fn makeClient(allocator: std.mem.Allocator, drv: anytype) !Client {
    return zent.codegen.client.makeClient(infos, allocator, drv);
}
