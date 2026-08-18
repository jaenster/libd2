//! What a test measured, printed only when asked for.
//!
//! Several gates here compare a generation against a baseline and report the numbers — how many
//! subtiles matched, how many graph origins lined up. Every one of those is already guarded by an
//! assertion right below it, so the print is diagnostics: what the residual IS, not whether it is
//! acceptable.
//!
//! It has to be opt-in because anything a test writes to stderr makes the build runner report the
//! step as `failed command:` even when the whole suite passed — a green run that reads as broken,
//! which is exactly the impression `zig build test` used to give. `zig build test -Dverbose`
//! brings the numbers back.
//!
//! The golden gates under `verify` print unconditionally instead, because there the numbers are
//! the evidence rather than a comment on it — docs/VERIFICATION.md quotes them.

const std = @import("std");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@import("build_options").verbose) std.debug.print(fmt, args);
}
