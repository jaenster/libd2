const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Pass -Doptimize=ReleaseSmall for anything you intend to ship: a plain
    // `zig build -Dtarget=wasm32-freestanding` is a Debug build and emits 6.5 MB where the
    // released artifact is 2.9 MB. Setting a preferred_optimize_mode here would make that the
    // default, but it also makes Zig register -Drelease INSTEAD of -Doptimize, which is the flag
    // the release workflows pass — so the default stays Debug and the pipeline stays explicit.
    const optimize = b.standardOptimizeOption(.{});

    // Which subsystems this bundle carries. One artifact beats one-per-subsystem because a
    // separate module has its own linear memory and its own copy of whatever it shares — routing
    // over a generated act costs 61 KB here against roughly a megabyte as a second module. But a
    // subsystem still brings its OWN content: adding item costs 888 KB combined against 901 KB
    // standalone, because item's bulk is its excel tables and it shares almost nothing with the
    // map. So the set is chosen, not fixed, and a consumer who only generates maps does not ship
    // the item tables to say so.
    const want = b.option([]const u8, "capi", "Subsystems to bundle: comma list of drlg,pf,item,net (default all)") orelse "drlg,pf,item,net";
    const has = struct {
        fn f(list: []const u8, name: []const u8) bool {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |p| if (std.mem.eql(u8, std.mem.trim(u8, p, " "), name)) return true;
            return false;
        }
    }.f;
    const with_drlg = has(want, "drlg");
    const with_pf = has(want, "pf");
    const with_item = has(want, "item");
    const with_net = has(want, "net");

    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
    const pf = b.dependency("d2_pathfinding", .{ .target = target, .optimize = optimize });
    const item = b.dependency("d2_item", .{ .target = target, .optimize = optimize });
    const net = b.dependency("d2_net", .{ .target = target, .optimize = optimize });

    const opts = b.addOptions();
    opts.addOption(bool, "with_drlg", with_drlg);
    opts.addOption(bool, "with_pf", with_pf);
    opts.addOption(bool, "with_item", with_item);
    opts.addOption(bool, "with_net", with_net);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", opts);
    // Every shim is imported; `root.zig` decides at comptime which ones it analyses, and an
    // import nothing references is never compiled.
    mod.addImport("d2drlg-capi", drlg.module("d2drlg-capi"));
    mod.addImport("d2pf-capi", pf.module("d2pf-capi"));
    mod.addImport("d2item-capi", item.module("d2item-capi"));
    mod.addImport("d2net-capi", net.module("d2net-capi"));

    if (target.result.cpu.arch.isWasm()) {
        // A reactor, not a command: no entry point, and every export kept.
        const wasm = b.addExecutable(.{ .name = "libd2", .root_module = mod });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        b.installArtifact(wasm);
    } else {
        // Native too, so the same combination can be linked into a host without a wasm runtime.
        mod.pic = true;
        // "d2", not "libd2": zig prefixes a static library with lib, so the name that produces
        // libd2.a — the file a C consumer expects, linked as -ld2 — is d2. Naming it libd2 here
        // ships liblibd2.a. The wasm above keeps the name libd2, because that is the file name
        // the npm package's loader asks for.
        const lib = b.addLibrary(.{ .name = "d2", .linkage = .static, .root_module = mod });
        b.installArtifact(lib);
        // Headers follow the same selection as the exports: shipping a declaration for a symbol
        // the archive does not contain is how a consumer gets a link error instead of an answer.
        if (with_drlg) b.getInstallStep().dependOn(&b.addInstallHeaderFile(drlg.path("include/d2drlg.h"), "d2drlg.h").step);
        if (with_pf) b.getInstallStep().dependOn(&b.addInstallHeaderFile(pf.path("include/d2pf.h"), "d2pf.h").step);
        if (with_item) b.getInstallStep().dependOn(&b.addInstallHeaderFile(item.path("include/d2item.h"), "d2item.h").step);
        if (with_net) b.getInstallStep().dependOn(&b.addInstallHeaderFile(net.path("include/d2net.h"), "d2net.h").step);
    }
}
