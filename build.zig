const std = @import("std");

// libd2 is a monorepo of independent, individually-consumable Zig packages under
// packages/. Each package has its own build.zig + build.zig.zon and exposes a
// module (d2-drlg / d2-items / d2-sim). A consumer depends on the one it wants:
//
//     .d2_drlg = .{ .path = "path/to/libd2/packages/drlg" },
//
// This root build.zig is a convenience aggregator: `zig build test` runs every
// package's own test suite. It intentionally does not re-wrap the packages — the
// per-package build.zig files are the source of truth for how each one builds.
pub fn build(b: *std.Build) void {
    const packages = [_][]const u8{ "formats", "fog", "drlg", "render", "items", "sim" };

    const test_step = b.step("test", "Run every package's test suite");

    for (packages) |name| {
        const sub = b.addSystemCommand(&.{ "zig", "build", "test" });
        sub.setCwd(b.path(b.fmt("packages/{s}", .{name})));
        sub.setName(b.fmt("test:{s}", .{name}));

        const one = b.step(b.fmt("test-{s}", .{name}), b.fmt("Run only the {s} package tests", .{name}));
        one.dependOn(&sub.step);
        test_step.dependOn(&sub.step);
    }
}
