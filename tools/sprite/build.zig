const std = @import("std");

// `sprite` — a headless, scriptable CLI over d2-formats and d2-util for DC6, DCC and COF art:
// list, extract, render to PNG, compose a unit, batch over an archive, upscale in index space
// and write the result back into the game's own formats.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });
    const util = b.dependency("d2_util", .{ .target = target, .optimize = optimize });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "d2-formats", .module = formats.module("d2-formats") },
        .{ .name = "d2-util", .module = util.module("d2-util") },
    };

    const exe = b.addExecutable(.{
        .name = "sprite",
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
    b.step("run", "Run the sprite tool").dependOn(&run_cmd.step);

    // Round trips over the real archives. Skipped, not failed, when the game files are absent:
    // set D2_DIR to a Diablo II install.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    b.step("test", "Run the tool's tests, including real-archive round trips").dependOn(&b.addRunArtifact(tests).step);
}
