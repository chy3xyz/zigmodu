const std = @import("std");
const zigmodu = @import("zigmodu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZigModu Benchmarks ===", .{});

    var suite = try zigmodu.BenchmarkSuite.init(allocator, "Framework Benchmarks");
    defer suite.deinit();

    const bench = try suite.addBenchmark("Module Operations", .{
        .min_iterations = 100,
        .max_iterations = 1000,
        .verbose = true,
    });
    _ = bench;

    try suite.runAll();

    const report = try suite.generateSummaryReport();
    defer allocator.free(report);

    std.log.info("\n{s}", .{report});
}
