const std = @import("std");

// `bindgen` — the raw Rust, Go, .NET and TypeScript bindings of every libd2 C ABI, generated from the
// headers and checked against each package's capi.zig. The root build runs it as `zig build bindings`
// (write) and `zig build check-bindings` (fail when a generated file is out of date).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "bindgen", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run bindgen").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Run the parser tests").dependOn(&b.addRunArtifact(tests).step);
}
