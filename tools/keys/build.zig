const std = @import("std");

// `keys` — point it at a Diablo II directory and it says what key material is in there.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bnet = b.dependency("d2_bnet", .{ .target = target, .optimize = optimize });
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "keys",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("d2-bnet", bnet.module("d2-bnet"));
    exe.root_module.addImport("d2-formats", formats.module("d2-formats"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the key tool").dependOn(&run_cmd.step);
}
