const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "all";
    const features = db_link.parseDb(db_opt) catch {
        @panic("invalid -Ddb= value; use all|sqlite|postgres|mysql (comma-list ok)");
    };

    const build_options = b.addOptions();
    db_link.addToOptions(build_options, features);
    // Dashboard.zig renders the framework version from build_options (batch
    // 129); this example builds its own build_options, so read the framework
    // zon's version (the single source of truth) and re-export it. The build
    // runner's cwd is this example's root.
    const io = b.graph.io;
    const zon_text = std.Io.Dir.cwd().readFileAlloc(io, "../../build.zig.zon", b.allocator, .limited(4096)) catch unreachable;
    const version_key = ".version = \"";
    const version_start = std.mem.indexOf(u8, zon_text, version_key) orelse unreachable;
    const version_rest = zon_text[version_start + version_key.len ..];
    const version_end = std.mem.indexOfScalar(u8, version_rest, '"') orelse unreachable;
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(version_rest[0..version_end]) catch unreachable);
    const build_options_mod = build_options.createModule();

    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigmodu_mod.addImport("build_options", build_options_mod);
    db_link.link(zigmodu_mod, b, target, features);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);

    const exe = b.addExecutable(.{
        .name = "tenant-mgmt",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run tenant-mgmt API server");
    run_step.dependOn(&run_cmd.step);

    // Example tests (module graph + routed catalog) live in src/tests.zig and
    // ship their own step, the same way the other examples expose one.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("zigmodu", zigmodu_mod);

    const test_step = b.step("test", "Run the tenant-mgmt example tests");
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
