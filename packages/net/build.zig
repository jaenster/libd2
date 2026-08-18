const std = @import("std");

// The d2-net package: the D2 1.14d server<->client wire protocol (sc / cs opcode spaces +
// the bit-packed reader/writer). Pure serialization over std only — no game-rules dependency —
// so it can be consumed independently of the simulation.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("d2-net", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C-ABI shim: frame demux, per-opcode wire sizing and the server->client decoders, for
    // C/C++/C#/Go/Node. Nothing here allocates, so there is no context handle and nothing to
    // free — every export is a pure function over the caller's own memory.
    //
    // Exposed as a module as well as built as libs, so the combined wasm can link this shim
    // beside the others (see packages/wasm). A bot decodes packets and routes over the map the
    // same stream describes; two wasm modules would put those in two linear memories.
    const capi_imports = [_]std.Build.Module.Import{.{ .name = "d2-net", .module = mod }};
    _ = b.addModule("d2net-capi", .{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &capi_imports,
    });

    const capi = b.option(bool, "capi", "Build the C-ABI shim") orelse true;
    if (capi and !target.result.cpu.arch.isWasm()) {
        // A static library ends up inside somebody else's binary, and on Linux those link as
        // PIE, which cannot take a non-PIC object.
        mod.pic = true;
        const static_mod = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &capi_imports,
        });
        static_mod.pic = true;
        const static_lib = b.addLibrary(.{ .name = "d2net", .linkage = .static, .root_module = static_mod });
        const shared_mod = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &capi_imports,
        });
        const shared_lib = b.addLibrary(.{ .name = "d2net", .linkage = .dynamic, .root_module = shared_mod });
        b.installArtifact(static_lib);
        b.installArtifact(shared_lib);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2net.h"), "d2net.h").step);
    }

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

    // The shim is a translation layer with no logic of its own, so what its tests can catch is
    // exactly what unit tests of lib.zig cannot: that every export still compiles against the
    // package it reshapes, and that the sizes it reports match the table lib.zig owns.
    const capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &capi_imports,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(capi_tests).step);
}
