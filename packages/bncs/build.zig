const std = @import("std");

// The d2-bncs package: the Battle.net protocol a Diablo II client speaks before it is in a
// game — the logon hashes (password, version check, CD key) and the chat/realm message
// vocabulary. No dependencies, and no libc: the version check is compiled into a 32-bit
// Windows DLL, and everything here has to survive freestanding wasm as well.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("d2-bncs", .{
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
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
