const std = @import("std");

// The drlg package. The four asset blobs are pre-baked and committed under blobs/, embedded
// directly by the src/*_data.zig files (@embedFile "../blobs/<name>_blob.bin") — so there is
// no bake-from-assets step in this build and no raw Blizzard art in the repo.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ds1_disk is faithful-source scaffolding (read DS1 from a disk asset tree
    // instead of the baked blob). Always false here — there is no asset tree.
    const opts = b.addOptions();
    opts.addOption(bool, "ds1_disk", false);

    // Anything a test writes to stderr makes the build runner report the step as
    // `failed command:` even when every assertion passed, so the fidelity dumps are off
    // unless asked for: `zig build test -Dverbose`.
    opts.addOption(bool, "verbose", b.option(bool, "verbose", "Print test fidelity diagnostics") orelse false);

    // Sibling packages factored out of drlg: the pure DS1/DT1 parsers, and d2-core which
    // owns the seed-RNG, the Fog::Memory pool allocator and the shared collision bit/mask
    // vocabulary (`core.collision`). drlg's sources reach them via `@import("d2-formats")`
    // / `@import("d2-core")`.
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });
    // The authoritative 1.14d excel tables. drlg reaches them via `@import("d2-data")`
    // and the DCE-friendly `d2data.file("Name")` (comptime embed), so the wasm target
    // links only the tables drlg actually names — not all 72.
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });
    const data_mod = data.module("d2-data");
    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const core_mod = core.module("d2-core");

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
    mod.addImport("d2-core", core_mod);
    mod.addImport("d2-data", data_mod);

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
    exe.root_module.addImport("d2-core", core_mod);
    exe.root_module.addImport("d2-data", data_mod);
    if (cli and !is_wasm) b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the DRLG tool");
    run_step.dependOn(&run_cmd.step);

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    tests.root_module.addImport("d2-formats", formats.module("d2-formats"));
    tests.root_module.addImport("d2-core", core_mod);
    tests.root_module.addImport("d2-data", data_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests + the golden verification gate");
    test_step.dependOn(&run_tests.step);

    const unit_step = b.step("test-unit", "Run only the unit tests (seconds — the edit/build loop)");
    unit_step.dependOn(&b.addRunArtifact(tests).step);

    // The golden harnesses regenerate whole acts per test, so they are pinned to ReleaseFast
    // whatever -Doptimize says: in Debug the same run takes minutes and can be OOM-killed. They
    // are a separate artifact because one test binary cannot hold two optimize modes.
    const verify_tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_tests.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    verify_tests.root_module.addOptions("build_options", opts);
    verify_tests.root_module.addImport("d2-formats", formats.module("d2-formats"));
    verify_tests.root_module.addImport("d2-core", core_mod);
    verify_tests.root_module.addImport("d2-data", data_mod);
    const run_verify = b.addRunArtifact(verify_tests);
    // Serialized behind the unit run: both binaries are memory-hungry and building/running them
    // concurrently is what pushes this package over the edge on a laptop.
    run_verify.step.dependOn(&run_tests.step);
    test_step.dependOn(&run_verify.step);

    const verify_step = b.step("verify", "Run only the golden verification gate (always ReleaseFast)");
    verify_step.dependOn(&b.addRunArtifact(verify_tests).step);

    // C-ABI shim: consumable from C/C++/C#/Node as native shared+static libs, or as
    // a wasm reactor module. The generator is libc-free (smp_allocator + d2-core's heap), so
    // nothing links libc and the wasm target is wasm32-freestanding-capable.
    const capi = b.option(bool, "capi", "Build the C-ABI shim (libs / wasm)") orelse true;
    if (capi) {
        const capi_optimize: std.builtin.OptimizeMode =
            if (is_wasm and b.args == null) .ReleaseSmall else (if (optimize == .Debug) .ReleaseFast else optimize);
        const CapiMod = struct {
            fn make(bb: *std.Build, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, o: *std.Build.Step.Options, fm: *std.Build.Module, cm: *std.Build.Module, dm: *std.Build.Module) *std.Build.Module {
                // Its own d2-drlg instance at the C-ABI optimize mode, so a Debug build still
                // gets a usable library rather than a generator too slow to run.
                const libmod = bb.createModule(.{
                    .root_source_file = bb.path("src/lib.zig"),
                    .target = tgt,
                    .optimize = opt,
                });
                libmod.addOptions("build_options", o);
                libmod.addImport("d2-formats", fm);
                libmod.addImport("d2-core", cm);
                libmod.addImport("d2-data", dm);

                const m = bb.createModule(.{
                    .root_source_file = bb.path("src/capi.zig"),
                    .target = tgt,
                    .optimize = opt,
                });
                m.addOptions("build_options", o);
                m.addImport("d2-drlg", libmod);
                m.addImport("d2-formats", fm);
                m.addImport("d2-core", cm);
                m.addImport("d2-data", dm);
                return m;
            }
        };
        const fmod = formats.module("d2-formats");

        // Exposed so a bundle package can link this shim into ONE module alongside other
        // subsystems (see packages/wasm). Routing needs the generated act in the same linear
        // memory, which only happens if the two shims are the same wasm.
        // The exposed one takes the PACKAGE's d2-drlg module, which is the same instance
        // pathfinding resolves, so both shims address one lib.zig in the combined module.
        const capi_pub = b.addModule("d2drlg-capi", .{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = capi_optimize,
            .imports = &.{
                .{ .name = "d2-drlg", .module = mod },
                .{ .name = "d2-formats", .module = fmod },
                .{ .name = "d2-core", .module = core_mod },
                .{ .name = "d2-data", .module = data_mod },
            },
        });
        capi_pub.addOptions("build_options", opts);

        if (is_wasm) {
            const wasm = b.addExecutable(.{ .name = "d2drlg", .root_module = CapiMod.make(b, target, capi_optimize, opts, fmod, core_mod, data_mod) });
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            b.installArtifact(wasm);
        } else {
            // A static library ends up inside somebody else's binary, and on Linux those link
            // as PIE by default, which cannot take a non-PIC object: the link fails with
            // "relocation R_X86_64_32 cannot be used against local symbol". The shared library
            // gets PIC implicitly; the static one has to ask.
            const static_mod = CapiMod.make(b, target, capi_optimize, opts, fmod, core_mod, data_mod);
            static_mod.pic = true;
            for ([_]*std.Build.Module{ fmod, core_mod, data_mod }) |dep| dep.pic = true;
            const static_lib = b.addLibrary(.{ .name = "d2drlg", .linkage = .static, .root_module = static_mod });
            const shared_lib = b.addLibrary(.{ .name = "d2drlg", .linkage = .dynamic, .root_module = CapiMod.make(b, target, capi_optimize, opts, fmod, core_mod, data_mod) });
            b.installArtifact(static_lib);
            b.installArtifact(shared_lib);
            b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2drlg.h"), "d2drlg.h").step);
        }
    }
}
