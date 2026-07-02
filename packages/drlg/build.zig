const std = @import("std");

// Public-mirror build for the drlg package. Unlike the private source repo, this
// does NOT bake asset blobs from a raw assets/tiles/ tree at build time — the four
// blobs are pre-baked and committed under blobs/, and embedded directly by the
// src/*_data.zig files (@embedFile "../blobs/<name>_blob.bin"). So there is no
// gen-from-assets step, no wasm/web target, and no raw Blizzard art in the repo.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ds1_disk is faithful-source scaffolding (read DS1 from a disk asset tree
    // instead of the baked blob). Always false here — there is no asset tree.
    const opts = b.addOptions();
    opts.addOption(bool, "ds1_disk", false);

    // Sibling packages factored out of drlg: the pure DS1/DT1 parsers and the
    // Fog::Memory pool allocator. drlg's sources reach them via
    // `@import("d2-formats")` / `@import("d2-fog")`.
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });
    const fog = b.dependency("d2_fog", .{ .target = target, .optimize = optimize });

    // Consumable library module: the faithful DRLG generator + collision (+ the
    // native render-data API). Consumers depend on this via
    // `.@"d2-drlg" = .{ .path = "../drlg" }` and `dep.module("d2-drlg")`.
    const mod = b.addModule("d2-drlg", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", opts);
    mod.addImport("d2-formats", formats.module("d2-formats"));
    mod.addImport("d2-fog", fog.module("d2-fog"));

    // The CLI/tests use std.process.Args + file loaders (native only); guard them
    // out for wasm, where only the C-ABI reactor module is built. The CLI exe also
    // can't cross-compile to windows-gnu (std.process.Args needs initAllocator on
    // Windows), so -Dcli=false lets the C-ABI libs cross-compile to every target.
    const is_wasm = target.result.cpu.arch == .wasm32;
    const cli = b.option(bool, "cli", "Build the dev CLI exe") orelse true;

    const exe = b.addExecutable(.{
        .name = "d2-drlg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);
    exe.root_module.addImport("d2-formats", formats.module("d2-formats"));
    exe.root_module.addImport("d2-fog", fog.module("d2-fog"));
    if (cli and !is_wasm) b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the DRLG tool");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    tests.root_module.addImport("d2-formats", formats.module("d2-formats"));
    tests.root_module.addImport("d2-fog", fog.module("d2-fog"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // C-ABI shim: consumable from C/C++/C#/Node as native shared+static libs, or as
    // a wasm reactor module. The generator is libc-free (smp_allocator + page_allocator),
    // so nothing links libc and the wasm target is wasm32-freestanding-capable.
    const capi = b.option(bool, "capi", "Build the C-ABI shim (libs / wasm)") orelse true;
    if (capi) {
        const capi_optimize: std.builtin.OptimizeMode =
            if (is_wasm and b.args == null) .ReleaseSmall else (if (optimize == .Debug) .ReleaseFast else optimize);
        const CapiMod = struct {
            fn make(bb: *std.Build, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, o: *std.Build.Step.Options, fm: *std.Build.Module, fg: *std.Build.Module) *std.Build.Module {
                const m = bb.createModule(.{
                    .root_source_file = bb.path("src/capi.zig"),
                    .target = tgt,
                    .optimize = opt,
                });
                m.addOptions("build_options", o);
                m.addImport("d2-formats", fm);
                m.addImport("d2-fog", fg);
                return m;
            }
        };
        const fmod = formats.module("d2-formats");
        const gmod = fog.module("d2-fog");

        if (is_wasm) {
            const wasm = b.addExecutable(.{ .name = "d2drlg", .root_module = CapiMod.make(b, target, capi_optimize, opts, fmod, gmod) });
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            b.installArtifact(wasm);
        } else {
            const static_lib = b.addLibrary(.{ .name = "d2drlg", .linkage = .static, .root_module = CapiMod.make(b, target, capi_optimize, opts, fmod, gmod) });
            const shared_lib = b.addLibrary(.{ .name = "d2drlg", .linkage = .dynamic, .root_module = CapiMod.make(b, target, capi_optimize, opts, fmod, gmod) });
            b.installArtifact(static_lib);
            b.installArtifact(shared_lib);
            b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2drlg.h"), "d2drlg.h").step);
        }
    }
}
