const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });
    const net = b.dependency("d2_net", .{ .target = target, .optimize = optimize });
    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
    const item = b.dependency("d2_item", .{ .target = target, .optimize = optimize });
    const wworld = b.dependency("d2_world", .{ .target = target, .optimize = optimize });
    const pathfinding = b.dependency("d2_pathfinding", .{ .target = target, .optimize = optimize });

    // Library module: the faithful D2 1.14d runtime game-simulation port.
    // Consumers depend on this via `.d2_game = .{ .path = "../game" }`.
    const mod = b.addModule("d2-game", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("d2-core", core.module("d2-core"));
    mod.addImport("d2-data", data.module("d2-data"));
    mod.addImport("d2-net", net.module("d2-net"));
    mod.addImport("d2-drlg", drlg.module("d2-drlg"));
    mod.addImport("d2-item", item.module("d2-item"));
    mod.addImport("d2-world", wworld.module("d2-world"));
    mod.addImport("d2-pathfinding", pathfinding.module("d2-pathfinding"));

    // Smoke/demo CLI: resolve a single attack (attacker vs defender, seed).
    const exe = b.addExecutable(.{
        .name = "d2-game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("d2-core", core.module("d2-core"));
    exe.root_module.addImport("d2-data", data.module("d2-data"));
    exe.root_module.addImport("d2-net", net.module("d2-net"));
    exe.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
    exe.root_module.addImport("d2-item", item.module("d2-item"));
    exe.root_module.addImport("d2-world", wworld.module("d2-world"));
    exe.root_module.addImport("d2-pathfinding", pathfinding.module("d2-pathfinding"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the attack-resolution demo CLI");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("d2-core", core.module("d2-core"));
    tests.root_module.addImport("d2-data", data.module("d2-data"));
    tests.root_module.addImport("d2-net", net.module("d2-net"));
    tests.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
    tests.root_module.addImport("d2-item", item.module("d2-item"));
    tests.root_module.addImport("d2-world", wworld.module("d2-world"));
    tests.root_module.addImport("d2-pathfinding", pathfinding.module("d2-pathfinding"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
