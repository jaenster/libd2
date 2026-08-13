const std = @import("std");

// The d2-bnet package: everything a Diablo II client says to Battle.net BEFORE it is in a
// game. That is three protocols sharing one port and one session — BNCS (logon and chat),
// MCP (the realm: character list, create, join) and BNFTP (file transfer for the version
// check) — plus the hashes they carry. d2-net picks up where this leaves off.
//
// No dependencies, and no libc: the version check is compiled into a 32-bit Windows DLL,
// and everything here has to survive freestanding wasm as well.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("d2-bnet", .{
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
