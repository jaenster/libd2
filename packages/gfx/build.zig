const std = @import("std");

// The d2-gfx package: scenes drawn as the game's renderer draws them, on the CPU. No dependencies:
// it reads DT1 bytes itself and draws into RGBA buffers, so it builds for wasm32-freestanding too.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("d2-gfx", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
