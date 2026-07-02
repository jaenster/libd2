const std = @import("std");

// Public-mirror build for the drlg package. Unlike the private source repo, this
// does NOT bake asset blobs from a raw assets/tiles/ tree at build time — the four
// blobs are pre-baked and committed under blobs/, and embedded directly by the
// src/*_data.zig files (@embedFile "../blobs/<name>_blob.bin"). So there is no
// gen-from-assets step, no wasm/web target, and no raw Blizzard art in the repo.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ds1_disk is faithful-source scaffolding (read DS1 from a disk asset tree
    // instead of the baked blob). Always false here — there is no asset tree.
    const opts = b.addOptions();
    opts.addOption(bool, "ds1_disk", false);

    // Consumable library module: the faithful DRLG generator + collision (+ the
    // native render-data API). Consumers depend on this via
    // `.@"d2-drlg" = .{ .path = "../drlg" }` and `dep.module("d2-drlg")`.
    const mod = b.addModule("d2-drlg", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "d2-drlg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the DRLG tool");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
