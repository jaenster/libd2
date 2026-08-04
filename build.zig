const std = @import("std");

// libd2 is a monorepo of independent, individually-consumable Zig packages under
// packages/. Each package has its own build.zig + build.zig.zon and exposes a
// module (d2-drlg / d2-item / d2-sim). A consumer depends on the one it wants:
//
//     .d2_drlg = .{ .path = "path/to/libd2/packages/drlg" },
//
// This root build.zig is a convenience aggregator: `zig build test` runs every
// package's own test suite. It intentionally does not re-wrap the packages — the
// per-package build.zig files are the source of truth for how each one builds.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Re-export each sub-package's public module under its canonical name so an
    // external dependent gets them all from one dependency:
    //     const libd2 = b.dependency("libd2", .{ .target = ..., .optimize = ... });
    //     exe.root_module.addImport("d2-sim", libd2.module("d2-sim"));
    // (.zon dep name -> exported module name.)
    const exported = [_]struct { dep: []const u8, mod: []const u8 }{
        .{ .dep = "d2_core", .mod = "d2-core" },
        .{ .dep = "d2_data", .mod = "d2-data" },
        .{ .dep = "d2_game", .mod = "d2-game" },
        .{ .dep = "d2_item", .mod = "d2-item" },
        .{ .dep = "d2_drlg", .mod = "d2-drlg" },
        .{ .dep = "d2_formats", .mod = "d2-formats" },
        .{ .dep = "d2_save", .mod = "d2-save" },
        .{ .dep = "d2_util", .mod = "d2-util" },
        .{ .dep = "d2_pathfinding", .mod = "d2-pathfinding" },
    };
    for (exported) |e| {
        const dep = b.dependency(e.dep, .{ .target = target, .optimize = optimize });
        // Alias the sub-package's already-public module into this package's module
        // table under the same name, so `libd2.module("d2-sim")` resolves for a dependent.
        b.modules.put(b.graph.arena, b.dupe(e.mod), dep.module(e.mod)) catch @panic("OOM");
    }

    const packages = [_][]const u8{ "formats", "drlg", "render", "core", "item", "game", "net", "data", "util", "pathfinding", "save" };

    const test_step = b.step("test", "Run every package's test suite");

    for (packages) |name| {
        const sub = b.addSystemCommand(&.{ "zig", "build", "test" });
        sub.setCwd(b.path(b.fmt("packages/{s}", .{name})));
        sub.setName(b.fmt("test:{s}", .{name}));

        const one = b.step(b.fmt("test-{s}", .{name}), b.fmt("Run only the {s} package tests", .{name}));
        one.dependOn(&sub.step);
        test_step.dependOn(&sub.step);
    }

    // `drlg` is the only package with golden harnesses — whole-act regenerations diffed against
    // captured engine data. They run under `test` like everything else, but are worth a step of
    // their own: they are the gate a generation change has to clear, and the slowest thing here.
    const verify_step = b.step("verify", "Run the golden verification gates (drlg)");
    const verify_sub = b.addSystemCommand(&.{ "zig", "build", "verify" });
    verify_sub.setCwd(b.path("packages/drlg"));
    verify_sub.setName("verify:drlg");
    verify_step.dependOn(&verify_sub.step);
}
