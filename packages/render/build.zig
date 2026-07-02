const std = @import("std");

// The d2-render package: the automap + DT1-tile-art render layer extracted out of
// drlg. It depends on d2-drlg (the byte-exact generation pipeline it consumes) and
// d2-formats (the DS1/DT1/DC6/DCC/COF parsers). No baked-from-assets step — the one
// render blob (automap sprites) is pre-baked and committed under src/blobs/.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("d2-render", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("d2-drlg", drlg.module("d2-drlg"));
    mod.addImport("d2-formats", formats.module("d2-formats"));

    const exe = b.addExecutable(.{
        .name = "d2-render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
    exe.root_module.addImport("d2-formats", formats.module("d2-formats"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the render tool");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
    tests.root_module.addImport("d2-formats", formats.module("d2-formats"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
