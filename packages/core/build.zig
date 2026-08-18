const std = @import("std");

// The d2-core package: the canonical Stat/Item model foundation shared by d2-game
// (runtime simulation) and d2-item (drop generation). It owns the seed-RNG, the
// Stat enum + StatList, ItemStatCost metadata, and the wire item bit-decoder, so
// those types have a single source of truth instead of being vendored twice.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("d2-core", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("d2-data", data.module("d2-data"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("d2-data", data.module("d2-data"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
