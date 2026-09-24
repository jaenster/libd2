const std = @import("std");

// The d2-util package: cross-cutting primitives with no domain of their own. The D2GS
// server->client Huffman codec (compress + decompress + table negotiation), the length-prefix
// packet framing that wraps it, a PNG writer, and MMPX magnification of palette-indexed pixels.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("d2-util", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C-ABI shim: MMPX index magnification. Nothing here allocates, so there is no context
    // handle and nothing to free, and the static library links into a host without libc.
    //
    // Exposed as a module as well as built as libs, so a combined artifact can link this shim
    // beside the other packages' shims.
    const capi_imports = [_]std.Build.Module.Import{.{ .name = "d2-util", .module = mod }};
    _ = b.addModule("d2util-capi", .{
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
        const static_lib = b.addLibrary(.{ .name = "d2util", .linkage = .static, .root_module = static_mod });
        // compiler-rt is deliberately not bundled: in a Release build the object needs only
        // memcpy and memset, which every C runtime provides, while a bundled compiler_rt.obj is
        // pulled in whole to satisfy them and quadruples a mingw DLL.
        const shared_mod = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &capi_imports,
        });
        const shared_lib = b.addLibrary(.{ .name = "d2util", .linkage = .dynamic, .root_module = shared_mod });
        b.installArtifact(static_lib);
        // On Windows the DLL's import library is also named d2util.lib and would overwrite the
        // static archive, whichever install step ran last. The archive is what a mingw host
        // links; a host that wants the DLL can link the .dll itself.
        b.getInstallStep().dependOn(&b.addInstallArtifact(shared_lib, .{ .implib_dir = .disabled }).step);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/d2util.h"), "d2util.h").step);
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

    // The shim reshapes lib.mmpx into C; its tests check that every export still compiles
    // against the package and returns what the Zig API returns.
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
