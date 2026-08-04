const std = @import("std");

// d2-save: the .d2s character-save format — the marker-delimited sections on top of the
// fixed header d2-formats owns, read and write. Depends on core (bit readers + the item
// bit codec), data + items (the item model those resolve against) and formats (the header).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("d2_core", .{ .target = target, .optimize = optimize });
    const data = b.dependency("d2_data", .{ .target = target, .optimize = optimize });
    const items = b.dependency("d2_items", .{ .target = target, .optimize = optimize });
    const formats = b.dependency("d2_formats", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("d2-save", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("d2-core", core.module("d2-core"));
    mod.addImport("d2-data", data.module("d2-data"));
    mod.addImport("d2-items", items.module("d2-items"));
    mod.addImport("d2-formats", formats.module("d2-formats"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("d2-core", core.module("d2-core"));
    tests.root_module.addImport("d2-data", data.module("d2-data"));
    tests.root_module.addImport("d2-items", items.module("d2-items"));
    tests.root_module.addImport("d2-formats", formats.module("d2-formats"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
