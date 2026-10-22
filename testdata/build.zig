const std = @import("std");

// The shared test data as a module ("libd2-testdata"); its directory is the dependency's root, which
// tests that rewrite golden files reach through `dependency.path(...)`.
pub fn build(b: *std.Build) void {
    _ = b.addModule("libd2-testdata", .{ .root_source_file = b.path("testdata.zig") });
}
