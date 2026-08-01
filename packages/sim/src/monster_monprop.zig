//! Monster granted properties — faithful table-driven port of D2 1.14d MonProp.txt.
//!
//! MonProp.txt contains per-monster-id innate bonuses (granted properties): auras, resist
//! modifiers, attack rate bonuses, etc. Each row has up to 6 entries per difficulty band
//! (Normal / Nightmare / Hell). Empty prop codes are skipped.
//!
//! Usage: call `propsFor(id, diff)` to get the slice of `MonPropEntry` for that
//! (monster-id, difficulty) pair. The result is comptime-built; no allocator is needed.
//!
//! Data source: MonProp.txt — Patch_D2 override, 1.14d retail.

const std = @import("std");
const d2data = @import("d2-data");
const ctsv = @import("ctsv.zig");
const Difficulty = @import("difficulty.zig").Difficulty;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One granted property entry from MonProp.txt.
pub const MonPropEntry = struct {
    /// The property code string (e.g. "cast2", "thorns", "extra-fire", "fade").
    /// Slice into the embedded table bytes — always valid for the program lifetime.
    code: []const u8,
    /// Parameter (par column); empty string when the column was blank.
    par: []const u8,
    min: i32,
    max: i32,
    /// Chance column (0 when blank — interpreted as "always" in D2).
    chance: i32,
};

// ---------------------------------------------------------------------------
// Comptime table build
// ---------------------------------------------------------------------------

/// Maximum number of prop slots per difficulty band in the table.
const NUM_SLOTS = 6;

/// Suffix for the difficulty band columns:  "" = Normal, " (N)" = Nightmare, " (H)" = Hell.
const DIFF_SUFFIX = [3][]const u8{ "", " (N)", " (H)" };

/// A row in the comptime-built table: the monster Id and its three difficulty bands.
const MonPropRow = struct {
    id: []const u8,
    /// Indexed by @intFromEnum(Difficulty): [normal, nightmare, hell].
    props: [3][]const MonPropEntry,
};

// ---------------------------------------------------------------------------
// Comptime parse helpers
// ---------------------------------------------------------------------------

/// Read a trimmed string cell from `row` at column `col_name`. Returns empty slice on blank.
fn cellStr(comptime hdr: []const u8, comptime row: []const u8, comptime col_name: []const u8) []const u8 {
    const idx = ctsv.columnIndex(hdr, col_name) orelse @compileError("MonProp: missing column " ++ col_name);
    var fields = std.mem.splitScalar(u8, row, '\t');
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i == idx) return std.mem.trim(u8, f, " \r");
    }
    return "";
}

/// Parse all props for one difficulty band (suffix) from `row`.
/// Returns a comptime-known slice (possibly empty).
fn parseProps(
    comptime hdr: []const u8,
    comptime row: []const u8,
    comptime suffix: []const u8,
) []const MonPropEntry {
    @setEvalBranchQuota(200_000);
    var buf: [NUM_SLOTS]MonPropEntry = undefined;
    var count: usize = 0;
    inline for (1..NUM_SLOTS + 1) |slot| {
        const n = std.fmt.comptimePrint("{d}", .{slot});
        const code = cellStr(hdr, row, "prop" ++ n ++ suffix);
        if (code.len == 0) continue;
        buf[count] = .{
            .code   = code,
            .par    = cellStr(hdr, row, "par" ++ n ++ suffix),
            .min    = ctsv.cellInt(hdr, row, "min" ++ n ++ suffix),
            .max    = ctsv.cellInt(hdr, row, "max" ++ n ++ suffix),
            .chance = ctsv.cellInt(hdr, row, "chance" ++ n ++ suffix),
        };
        count += 1;
    }
    // Copy count entries into a comptime-sized array then return a const slice.
    const final = buf[0..count].*;
    const stored: [final.len]MonPropEntry = final;
    return &stored;
}

// ---------------------------------------------------------------------------
// Comptime-built table
// ---------------------------------------------------------------------------

const TABLE: []const MonPropRow = blk: {
    @setEvalBranchQuota(2_000_000);
    const txt = d2data.file("MonProp");
    const hdr = ctsv.header(txt);

    // Count non-empty rows first (skip header + blank + "Expansion" dividers).
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, txt, '\n');
    _ = lines.first(); // header
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        if (first.len == 0 or std.mem.eql(u8, first, "Expansion")) continue;
        count += 1;
    }

    var rows: [count]MonPropRow = undefined;
    var idx: usize = 0;
    var lines2 = std.mem.splitScalar(u8, txt, '\n');
    _ = lines2.first(); // skip header
    while (lines2.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        if (first.len == 0 or std.mem.eql(u8, first, "Expansion")) continue;
        rows[idx] = .{
            .id    = first,
            .props = .{
                parseProps(hdr, line, DIFF_SUFFIX[0]),
                parseProps(hdr, line, DIFF_SUFFIX[1]),
                parseProps(hdr, line, DIFF_SUFFIX[2]),
            },
        };
        idx += 1;
    }
    const frozen = rows;
    break :blk &frozen;
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return the granted properties for `monster_id` at `diff`.
/// Returns an empty slice if the monster is not in MonProp.txt or has no entries
/// for this difficulty.  The returned slice is comptime-constant — no allocation.
pub fn propsFor(monster_id: []const u8, diff: Difficulty) []const MonPropEntry {
    for (TABLE) |row| {
        if (std.mem.eql(u8, row.id, monster_id)) return row.props[@intFromEnum(diff)];
    }
    return &[_]MonPropEntry{};
}

// ---------------------------------------------------------------------------
// Tests — values verified independently with awk on MonProp.txt
// ---------------------------------------------------------------------------

test "mephisto NM: cast2 min=15 max=15, swing2 min=15 max=15" {
    const props = propsFor("mephisto", .nightmare);
    try std.testing.expectEqual(@as(usize, 2), props.len);
    try std.testing.expectEqualStrings("cast2", props[0].code);
    try std.testing.expectEqual(@as(i32, 15), props[0].min);
    try std.testing.expectEqual(@as(i32, 15), props[0].max);
    try std.testing.expectEqualStrings("swing2", props[1].code);
    try std.testing.expectEqual(@as(i32, 15), props[1].min);
    try std.testing.expectEqual(@as(i32, 15), props[1].max);
}

test "mephisto Hell: cast2 min=30 max=30, swing2 min=30 max=30" {
    const props = propsFor("mephisto", .hell);
    try std.testing.expectEqual(@as(usize, 2), props.len);
    try std.testing.expectEqualStrings("cast2", props[0].code);
    try std.testing.expectEqual(@as(i32, 30), props[0].min);
    try std.testing.expectEqual(@as(i32, 30), props[0].max);
    try std.testing.expectEqualStrings("swing2", props[1].code);
    try std.testing.expectEqual(@as(i32, 30), props[1].min);
}

test "mephisto Normal: no props" {
    const props = propsFor("mephisto", .normal);
    try std.testing.expectEqual(@as(usize, 0), props.len);
}

test "quillrat6 NM: thorns min=15 max=20" {
    const props = propsFor("quillrat6", .nightmare);
    try std.testing.expectEqual(@as(usize, 1), props.len);
    try std.testing.expectEqualStrings("thorns", props[0].code);
    try std.testing.expectEqual(@as(i32, 15), props[0].min);
    try std.testing.expectEqual(@as(i32, 20), props[0].max);
}

test "quillrat6 Hell: thorns min=30 max=40" {
    const props = propsFor("quillrat6", .hell);
    try std.testing.expectEqual(@as(usize, 1), props.len);
    try std.testing.expectEqualStrings("thorns", props[0].code);
    try std.testing.expectEqual(@as(i32, 30), props[0].min);
    try std.testing.expectEqual(@as(i32, 40), props[0].max);
}

test "unknown monster returns empty slice" {
    const props = propsFor("NONEXISTENT_MONSTER_XYZ", .hell);
    try std.testing.expectEqual(@as(usize, 0), props.len);
}
