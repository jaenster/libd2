//! Item property application — turning an affix/unique/set/runeword property (a Properties.txt `code`
//! plus the row's min/max) into rolled stat values. Faithful to the 1.14d expansion path
//! ITEMMOD_ApplyPropertyToUnitStatsExpansion @0x65fd70 + the value roll ITEMMOD_RollRandomValue @0x65e9e0.
//!
//! A Properties.txt row carries up to 7 {func, stat, val, set} slots. The engine indexes a 37-entry
//! PROPERTIESFUNCTIONS dispatch table by `func`; a null (func 0) stops the slot loop. This module ports
//! the COMMON single-stat funcs (1/2/3/4/8 — roll [min,max] into the named ItemStatCost stat), which
//! cover the bulk of affix/unique properties (+str/+life/+resist/+mana/…). The damage (5/6/7),
//! skill/charge (9/10/11/19) and special layer funcs are not valued yet — documented follow-ups.

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");

/// One rolled stat contribution: the ItemStatCost numeric stat `id` and the rolled `value`.
pub const RolledStat = struct { stat: i32, value: i32 };

/// ITEMMOD_RollRandomValue @0x65e9e0: `min == max` returns `min` WITHOUT advancing the seed; otherwise
/// the range is normalized (low/high) and the value is `low + RandomNumberSelector(seed, high-low+1)` —
/// an INCLUSIVE roll (the expansion path's +1), which advances the seed once.
pub fn rollValue(seed: *rng.Seed, min: i32, max: i32) i32 {
    if (min == max) return min;
    const lo = @min(min, max);
    const hi = @max(min, max);
    return lo + @as(i32, @intCast(seed.pick(@intCast(hi - lo + 1))));
}

/// Resolve an ItemStatCost stat NAME (the Properties.txt `statN` column) to its numeric stat ID (the
/// ItemStatCost `ID` column). The engine resolves this at table-load time via pTxtItemStatCostLink.
pub fn statId(t: *const tables.Tables, name: []const u8) ?i32 {
    if (name.len == 0) return null;
    const isc = &t.item_stat_cost;
    const row = isc.findByStr("Stat", name) orelse return null;
    return @intCast(isc.int(row, "ID"));
}

/// True when `func` is one of the ported single-stat property functions (roll [min,max] into one stat).
fn isSingleStatFunc(func: i64) bool {
    return switch (func) {
        1, 2, 3, 4, 8 => true,
        else => false,
    };
}

/// Apply a Properties.txt `code` with the property row's (min, max) range, appending each rolled
/// {stat, value} to `out`. Walks the 7 func slots; a null func stops the loop (faithful). Only the
/// common single-stat funcs are valued; other funcs are skipped (their stats are a follow-up).
pub fn applyProperty(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RolledStat),
    seed: *rng.Seed,
    t: *const tables.Tables,
    code: []const u8,
    min: i32,
    max: i32,
) !void {
    const pt = &t.properties;
    const prow = pt.findByStr("code", code) orelse return; // unknown property code
    var fbuf: [8]u8 = undefined;
    var sbuf: [8]u8 = undefined;
    for (0..7) |slot| {
        const fcol = std.fmt.bufPrint(&fbuf, "func{d}", .{slot + 1}) catch unreachable;
        const func = pt.int(prow, fcol);
        if (func == 0) break; // null handler -> stop (ITEMMOD_ApplyPropertyToUnitStatsExpansion)
        if (!isSingleStatFunc(func)) continue; // unported func: stat not valued yet
        const scol = std.fmt.bufPrint(&sbuf, "stat{d}", .{slot + 1}) catch unreachable;
        const sid = statId(t, pt.str(prow, scol)) orelse continue;
        try out.append(gpa, .{ .stat = sid, .value = rollValue(seed, min, max) });
    }
}

const testing = std.testing;

test "rollValue: min==max returns min without advancing the seed" {
    var s = rng.Seed.init(0x1234, 0x29a);
    const before = s.low;
    try testing.expectEqual(@as(i32, 10), rollValue(&s, 10, 10));
    try testing.expectEqual(before, s.low); // untouched
    // A real range advances the seed and lands within [min,max].
    const v = rollValue(&s, 5, 15);
    try testing.expect(v >= 5 and v <= 15);
    try testing.expect(s.low != before);
}

test "rollValue: deterministic + covers the whole inclusive range over many seeds" {
    var saw_min = false;
    var saw_max = false;
    var n: u32 = 0;
    while (n < 500) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        const v = rollValue(&s, 3, 7);
        try testing.expect(v >= 3 and v <= 7);
        if (v == 3) saw_min = true;
        if (v == 7) saw_max = true;
    }
    try testing.expect(saw_min and saw_max); // inclusive on both ends
}

test "statId resolves known ItemStatCost stats" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    try testing.expect(statId(&t, "strength") != null);
    try testing.expect(statId(&t, "maxhp") != null);
    try testing.expect(statId(&t, "not-a-stat") == null);
}

test "applyProperty: a simple +stat property rolls one stat in range" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    // "str" is Properties func1 -> stat "strength".
    const str_id = statId(&t, "strength").?;

    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);
    var s = rng.Seed.init(0x777, 0x29a);
    try applyProperty(testing.allocator, &out, &s, &t, "str", 10, 20);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(str_id, out.items[0].stat);
    try testing.expect(out.items[0].value >= 10 and out.items[0].value <= 20);

    // Fixed range -> exact value, and an unknown code contributes nothing.
    out.clearRetainingCapacity();
    try applyProperty(testing.allocator, &out, &s, &t, "str", 7, 7);
    try testing.expectEqual(@as(i32, 7), out.items[0].value);
    out.clearRetainingCapacity();
    try applyProperty(testing.allocator, &out, &s, &t, "zzz-nope", 1, 5);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
