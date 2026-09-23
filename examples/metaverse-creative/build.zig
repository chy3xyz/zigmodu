const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const features = db_link.Features.sqlite_only;
    const build_options = b.addOptions();
    db_link.addToOptions(build_options, features);
    const build_options_mod = build_options.createModule();

    // zent v0.76.0 lets a consumer say which drivers it links, and skips the
    // `translate-c` pass for the rest. This demo imports `zent.sql_postgres`
    // (src/db.zig) and `zent.sql_sqlite`, so both stay on; only MySQL is off —
    // the example's `db_link` never links libmysqlclient.
    //
    // Measured in the sibling zent-modulith demo (macOS aarch64, cold caches):
    // the skipped translations are parallel ~23 s / 30 MiB steps, so unless they
    // dominate the host (upstream measures ~26 s / ~590 MB per driver) the
    // end-to-end wall time and peak are unchanged (763 MiB / 80 s vs 723 MiB /
    // 82 s there). Kept for the intent it states, not for a measured win here.
    const zent_dep = b.dependency("zent", .{
        .target = target,
        .optimize = optimize,
        .mysql = false,
    });
    const zent_mod = zent_dep.module("zent");
    // src/db.zig references zent.sql_postgres; zent wires its pg_c binding
    // when libpq headers are present but never links the library itself —
    // link it here so PQ symbols resolve (no-op when libpq is absent).
    db_link.linkDetected(zent_mod, b, .{ .postgres = true });

    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigmodu_mod.addImport("build_options", build_options_mod);
    db_link.link(zigmodu_mod, b, features);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);
    exe_mod.addImport("zent", zent_mod);

    const exe = b.addExecutable(.{
        .name = "metaverse-creative",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run metaverse-creative (default: cli help)");
    run_step.dependOn(&run_cmd.step);

    const demo_cmd = b.addRunArtifact(exe);
    demo_cmd.step.dependOn(b.getInstallStep());
    demo_cmd.addArgs(&.{ "cli", "demo" });
    demo_cmd.setEnvironmentVariable("ZENT_DRIVER", "sqlite");
    const demo_step = b.step("demo", "Run end-to-end zent demo on sqlite :memory:");
    demo_step.dependOn(&demo_cmd.step);

    const serve_cmd = b.addRunArtifact(exe);
    serve_cmd.step.dependOn(b.getInstallStep());
    serve_cmd.addArgs(&.{"serve"});
    const serve_step = b.step("serve", "Start HTTP API server");
    serve_step.dependOn(&serve_cmd.step);
}
