const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: the faithful D2 1.14d item-generation port.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = b.addModule("d2-items", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Smoke/demo CLI: roll a drop for a seed+TC+mlvl.
    const exe = b.addExecutable(.{
        .name = "d2-items",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The CLIs use std.process.Args (native only); don't install them for wasm.
    const is_wasm = target.result.cpu.arch == .wasm32;
    if (!is_wasm) b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the item-drop roller CLI");
    run_step.dependOn(&run_cmd.step);

    // Render demo: roll a drop + composite the real item graphics into a PNG.
    const render_exe = b.addExecutable(.{
        .name = "render-items",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (!is_wasm) b.installArtifact(render_exe);

    const render_cmd = b.addRunArtifact(render_exe);
    render_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| render_cmd.addArgs(args);
    const render_step = b.step("render", "Roll a drop and render item graphics to a PNG");
    render_step.dependOn(&render_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // C-ABI shim: consumable from C/C++/C#/Node as native shared+static libs, or
    // as a freestanding wasm reactor module. This is the reference convention.
    const capi = b.option(bool, "capi", "Build the C-ABI shim (libs / wasm)") orelse true;
    if (capi) {
        if (is_wasm) {
            const wasm = b.addExecutable(.{
                .name = "d2items",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = if (b.args == null) .ReleaseSmall else optimize,
                }),
            });
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            b.installArtifact(wasm);
        } else {
            const capi_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
            const static_lib = b.addLibrary(.{
                .name = "d2items",
                .linkage = .static,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = capi_optimize,
                }),
            });
            const shared_lib = b.addLibrary(.{
                .name = "d2items",
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = capi_optimize,
                }),
            });
            b.installArtifact(static_lib);
            b.installArtifact(shared_lib);
            b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2items.h"), "d2items.h").step);
        }
    }

    _ = lib_mod;
}
