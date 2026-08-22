const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const core_mod = core.module("d2-core");
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });
    const data_mod = data.module("d2-data");
    const util = b.dependency("d2_util", .{ .target = target, .optimize = optimize });
    const util_mod = util.module("d2-util");

    // Library module: the faithful D2 1.14d item-generation port.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const items_mod = b.addModule("d2-item", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    items_mod.addImport("d2-core", core_mod);
    items_mod.addImport("d2-data", data_mod);
    items_mod.addImport("d2-util", util_mod);

    // Smoke/demo CLI: roll a drop for a seed+TC+mlvl.
    const exe = b.addExecutable(.{
        .name = "d2-item",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("d2-core", core_mod);
    exe.root_module.addImport("d2-data", data_mod);
    exe.root_module.addImport("d2-util", util_mod);
    // The CLIs use std.process.Args (native only, and not cross-compilable to
    // Windows); -Dcli=false skips them so release cross-compiles build only the
    // shippable C-ABI libs + wasm. Local dev keeps them (default true).
    const is_wasm = target.result.cpu.arch == .wasm32;
    const cli = b.option(bool, "cli", "Build the dev CLI executables") orelse true;
    if (cli and !is_wasm) b.installArtifact(exe);

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
    render_exe.root_module.addImport("d2-core", core_mod);
    render_exe.root_module.addImport("d2-data", data_mod);
    render_exe.root_module.addImport("d2-util", util_mod);
    if (cli and !is_wasm) b.installArtifact(render_exe);

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
    tests.root_module.addImport("d2-core", core_mod);
    tests.root_module.addImport("d2-data", data_mod);
    tests.root_module.addImport("d2-util", util_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // C-ABI shim: consumable from C/C++/C#/Node as native shared+static libs, or
    // as a freestanding wasm reactor module. This is the reference convention.
    const capi = b.option(bool, "capi", "Build the C-ABI shim (libs / wasm)") orelse true;
    if (capi) {
        // Exposed so the bundle package can link this shim into ONE module alongside the other
        // subsystems (see packages/wasm). A separate wasm per subsystem carries its own copy of
        // the shared base — the excel tables above all — so N modules pay for it N times, while
        // one combined module pays once and lets the shims address the same linear memory.
        _ = b.addModule("d2item-capi", .{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
            .imports = &.{
                .{ .name = "d2-core", .module = core_mod },
                .{ .name = "d2-data", .module = data_mod },
                .{ .name = "d2-util", .module = util_mod },
            },
        });
        if (is_wasm) {
            const wasm = b.addExecutable(.{
                .name = "d2item",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = if (b.args == null) .ReleaseSmall else optimize,
                }),
            });
            wasm.root_module.addImport("d2-core", core_mod);
            wasm.root_module.addImport("d2-data", data_mod);
            wasm.root_module.addImport("d2-util", util_mod);
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            b.installArtifact(wasm);
        } else {
            const capi_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
            const static_lib = b.addLibrary(.{
                .name = "d2item",
                .linkage = .static,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = capi_optimize,
                }),
            });
            const shared_lib = b.addLibrary(.{
                .name = "d2item",
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = capi_optimize,
                }),
            });
            static_lib.root_module.addImport("d2-core", core_mod);
            static_lib.root_module.addImport("d2-data", data_mod);
            static_lib.root_module.addImport("d2-util", util_mod);
            shared_lib.root_module.addImport("d2-core", core_mod);
            shared_lib.root_module.addImport("d2-data", data_mod);
            shared_lib.root_module.addImport("d2-util", util_mod);
            b.installArtifact(static_lib);
            b.installArtifact(shared_lib);
            b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2item.h"), "d2item.h").step);
        }
    }

    lib_mod.addImport("d2-core", core_mod);

    lib_mod.addImport("d2-data", data_mod);
    lib_mod.addImport("d2-util", util_mod);
}
