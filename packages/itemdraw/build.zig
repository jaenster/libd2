const std = @import("std");

// d2-itemdraw: an item drawn as 1.14d draws it, the inventory icon, the hover tooltip and the two
// together, into RGBA or PNG. The art comes from the caller (archives or loose files); the text from
// d2-item over the d2-data tables.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize }).module("d2-core");
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize }).module("d2-data");
    const item = b.dependency("d2_item", .{ .target = target, .optimize = optimize }).module("d2-item");
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize }).module("d2-formats");
    const util = b.dependency("d2_util", .{ .target = target, .optimize = optimize }).module("d2-util");
    const save = b.dependency("d2_save", .{ .target = target, .optimize = optimize }).module("d2-save");
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "d2-core", .module = core },
        .{ .name = "d2-data", .module = data },
        .{ .name = "d2-item", .module = item },
        .{ .name = "d2-formats", .module = formats },
        .{ .name = "d2-util", .module = util },
    };

    const mod = b.addModule("d2-itemdraw", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    // The golden tests read the retail archives from -Dd2dir (Patch_D2.mpq, d2exp.mpq, d2data.mpq) and
    // write what they drew to -Dout; without -Dd2dir they skip.
    const opts = b.addOptions();
    opts.addOption([]const u8, "d2dir", b.option([]const u8, "d2dir", "Directory holding the 1.14d MPQs, for the golden tests") orelse "");
    opts.addOption([]const u8, "out", b.option([]const u8, "out", "Directory the golden tests write their PNGs to") orelse "");
    // -Dupdate-golden rewrites testdata/itemdraw/ from what the code produces now, for review in the diff
    opts.addOption(bool, "update_golden", b.option(bool, "update-golden", "Rewrite the golden files instead of comparing") orelse false);
    // the repository's shared test data; lazy, so a package fetched as a dependency never needs it
    const td = b.lazyDependency("libd2_testdata", .{});
    opts.addOption([]const u8, "testdata", if (td) |d| d.path("itemdraw").getPath(b) else "");
    if (td) |d| tests.root_module.addImport("libd2-testdata", d.module("libd2-testdata"));
    tests.root_module.addOptions("build_options", opts);
    tests.root_module.addImport("d2-save", save);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // The binding fixtures (records and their C ABI text) the Rust, Go, .NET and npm tests read, written
    // to testdata/itemdraw/bindings/ by the one test that produces them.
    const fixtures = b.addTest(.{ .filters = &.{"the binding fixtures"}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    fixtures.root_module.addOptions("build_options", opts);
    fixtures.root_module.addImport("d2-save", save);
    if (td) |d| fixtures.root_module.addImport("libd2-testdata", d.module("libd2-testdata"));
    const run_fixtures = b.addRunArtifact(fixtures);
    run_fixtures.has_side_effects = true;
    b.step("fixtures", "Write the binding fixtures to testdata/itemdraw/bindings").dependOn(&run_fixtures.step);

    const is_wasm = target.result.cpu.arch.isWasm();
    const cli = b.option(bool, "cli", "Build the dev CLI executables") orelse true;
    if (cli and !is_wasm) {
        const exe = b.addExecutable(.{ .name = "item-draw", .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "d2-itemdraw", .module = mod }, .{ .name = "d2-save", .module = save } },
        }) });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Draw the items of a save or record file to PNGs").dependOn(&run.step);
    }

    // The C ABI, as the other packages ship it: a module the combined wasm links, and native libs.
    const capi = b.option(bool, "capi", "Build the C-ABI shim (libs / wasm)") orelse true;
    if (capi) {
        const capi_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
        _ = b.addModule("d2itemdraw-capi", .{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = capi_optimize,
            .imports = imports,
        });
        if (is_wasm) {
            const wasm = b.addExecutable(.{ .name = "d2itemdraw", .root_module = b.createModule(.{
                .root_source_file = b.path("src/capi.zig"),
                .target = target,
                .optimize = if (b.args == null) .ReleaseSmall else optimize,
                .imports = imports,
            }) });
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            b.installArtifact(wasm);
        } else {
            for ([_]std.builtin.LinkMode{ .static, .dynamic }) |linkage| {
                const lib = b.addLibrary(.{ .name = "d2itemdraw", .linkage = linkage, .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi.zig"),
                    .target = target,
                    .optimize = capi_optimize,
                    .imports = imports,
                }) });
                b.installArtifact(lib);
            }
            b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2itemdraw.h"), "d2itemdraw.h").step);
        }
    }
}
