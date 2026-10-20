const std = @import("std");

// `gfx`: draw a scene's views with d2-gfx and compare frames block by block.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gfx = b.dependency("d2_gfx", .{ .target = target, .optimize = optimize });
    const util = b.dependency("d2_util", .{ .target = target, .optimize = optimize });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "d2-gfx", .module = gfx.module("d2-gfx") },
        .{ .name = "d2-util", .module = util.module("d2-util") },
    };
    const exe = b.addExecutable(.{
        .name = "gfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the gfx tool").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    b.step("test", "Run the tool's tests").dependOn(&b.addRunArtifact(tests).step);
}
