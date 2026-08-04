const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
    const pf = b.dependency("d2_pathfinding", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "d2drlg-capi", .module = drlg.module("d2drlg-capi") },
            .{ .name = "d2pf-capi", .module = pf.module("d2pf-capi") },
        },
    });

    if (target.result.cpu.arch.isWasm()) {
        // A reactor, not a command: no entry point, and every export kept.
        const wasm = b.addExecutable(.{ .name = "libd2", .root_module = mod });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        b.installArtifact(wasm);
    } else {
        // Native too, so the same combination can be linked into a host without a wasm runtime.
        mod.pic = true;
        const lib = b.addLibrary(.{ .name = "libd2", .linkage = .static, .root_module = mod });
        b.installArtifact(lib);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(drlg.path("include/d2drlg.h"), "d2drlg.h").step);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(pf.path("include/d2pf.h"), "d2pf.h").step);
    }
}
