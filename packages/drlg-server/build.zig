const std = @import("std");

// Native, speed-focused HTTP server for the DeadlyBossMods-shaped map JSON. Holds one
// Ctx per worker thread (tables loaded once), generates an act per request via the
// d2-drlg native `renderJson`, and serves it over std.http. Defaults to ReleaseFast:
// speed is the whole point of the native path (vs the wasm shim).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseFast (speed is the whole point of the native path); still overridable
    // with -Doptimize=Debug etc.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default ReleaseFast)") orelse .ReleaseFast;

    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "drlg-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
    // Native libz for the fast collision-deflate (server binary only — the d2-drlg library
    // and its wasm build stay libc/libz-free; they use the pure-Zig std.compress.flate).
    exe.root_module.linkSystemLibrary("z", .{});
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the DRLG HTTP server");
    run_step.dependOn(&run_cmd.step);
}
