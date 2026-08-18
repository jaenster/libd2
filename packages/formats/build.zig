const std = @import("std");

// d2-formats: pure DS1/DT1 parsers, no dependencies. Consumed by the drlg package
// (and usable standalone by any tool that reads D2 map data).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("d2-formats", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Anything a test writes to stderr makes the build runner report the step as
    // `failed command:` even when every assertion passed, so the fixture dumps are off
    // unless asked for: `zig build test -Dverbose`.
    const opts = b.addOptions();
    opts.addOption(bool, "verbose", b.option(bool, "verbose", "Print test fixture diagnostics") orelse false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", opts);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
