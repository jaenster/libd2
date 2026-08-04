const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "d2-drlg", .module = drlg.module("d2-drlg") },
        .{ .name = "d2-core", .module = core.module("d2-core") },
        .{ .name = "d2-data", .module = data.module("d2-data") },
    };

    const mod = b.addModule("d2-pathfinding", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    _ = mod;

    // C-ABI shim: consumable from C/C++/C#/Node as native shared+static libs, or as part of a
    // combined wasm reactor alongside d2drlg. Off for wasm here because the useful wasm is the
    // COMBINED one (see packages/wasm): routing needs a generated act, and a module of its own
    // would have its own linear memory with no way to reach one.
    // Exposed so a bundle package can link this shim into ONE module alongside d2drlg (see
    // packages/wasm): a route has to be computed against an act in the same linear memory.
    _ = b.addModule("d2pf-capi", .{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const capi = b.option(bool, "capi", "Build the C-ABI shim") orelse true;
    if (capi and !target.result.cpu.arch.isWasm()) {
        const capi_mod = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        });
        // A static library ends up inside somebody else's binary, and on Linux those link as
        // PIE, which cannot take a non-PIC object. Same reason as d2drlg's.
        capi_mod.pic = true;
        for (imports) |imp| imp.module.pic = true;
        const static_lib = b.addLibrary(.{ .name = "d2pf", .linkage = .static, .root_module = capi_mod });
        const shared_mod = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        });
        const shared_lib = b.addLibrary(.{ .name = "d2pf", .linkage = .dynamic, .root_module = shared_mod });
        b.installArtifact(static_lib);
        b.installArtifact(shared_lib);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2pf.h"), "d2pf.h").step);
    }

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // A tiny benchmark/demo: load an act and time real routes across it. Kept as a build step
    // rather than a test so it never slows the suite down. It links libc purely for the
    // monotonic clock — the library itself stays libc-free, like the rest of libd2.
    const bench = b.addExecutable(.{
        .name = "d2-pathfinding-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &imports,
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Load an act and time routes across it");
    bench_step.dependOn(&run_bench.step);
}
