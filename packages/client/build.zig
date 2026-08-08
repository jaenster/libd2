const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const net = b.dependency("d2_net", .{ .target = target, .optimize = optimize });
    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "d2-net", .module = net.module("d2-net") },
        .{ .name = "d2-core", .module = core.module("d2-core") },
        .{ .name = "d2-data", .module = data.module("d2-data") },
    };

    _ = b.addModule("d2-client", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
