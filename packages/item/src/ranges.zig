//! The range each of an item's stats can roll in, from the rows the item was made from.
//!
//! An item record keeps the rows it was rolled from (its magic affixes, its rare affixes, its automagic row, its
//! UniqueItems or SetItems row, the runeword its runes spell) and the values, but not which row gave which value. Every
//! property of every row is applied twice through the engine's own property functions (properties.applyProperty,
//! ITEMMOD_ApplyPropertyToUnitStatsExpansion 0x65fd70): once with its range closed on `min`, once on `max`. Neither
//! application rolls (a closed range returns its bound without touching the seed), and both leave the stats exactly
//! where a roll at that bound would have put them, with the same layers. Summed per stat and layer over the item and
//! what is socketed in it, that is the lowest and the highest value the stat could have.
//!
//! A property whose value is not a roll of its range (skill charges, a random skill, a timed stat, a charged skill, a
//! random class skill) gives no range: its stat is marked unknown, and so is any stat a per-level op computes.
//!
//! A pre-patch rare (a Classic rare of item version 0, d2up's src/game/prepatch.zig) was rolled as 1.06 rolled it:
//! every value from `min` to `max - 1`, never the top. Its ranges end one below the row's `max`.
const std = @import("std");
const wire = @import("d2-core").wire;
const tables = @import("tables.zig");
const txt = @import("txt.zig");
const properties = @import("properties.zig");
const rng = @import("rng.zig");

/// The lowest and highest value of one stat, as stored (before the value shift), and whether any of its sources
/// actually rolls (a range wider than one value).
pub const Range = struct {
    lo: i32 = 0,
    hi: i32 = 0,
    rolls: bool = false,
    /// A source of the stat could not be bounded: show nothing for it.
    unknown: bool = false,
};

pub const Ranges = struct {
    map: std.AutoHashMapUnmanaged(u32, Range) = .empty,

    fn key(stat: u16, param: u16) u32 {
        return @as(u32, stat) << 16 | param;
    }

    /// The range of a stat and layer, or null when nothing the item was made from gives it.
    pub fn get(self: *const Ranges, stat: u16, param: u16) ?Range {
        const r = self.map.get(key(stat, param)) orelse return null;
        if (r.unknown) return null;
        return r;
    }

    pub fn deinit(self: *Ranges, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    fn slot(self: *Ranges, gpa: std.mem.Allocator, stat: i32, layer: i32) !*Range {
        const k = key(@intCast(stat & 0xffff), @intCast(layer & 0xffff));
        const g = try self.map.getOrPut(gpa, k);
        if (!g.found_existing) g.value_ptr.* = .{};
        return g.value_ptr;
    }
};

/// Property functions whose value is not a roll of the row's range (properties.applyFunc): 11 skill charges (the
/// layer packs the level), 12 a random skill (the roll picks the layer), 18 a timed stat (packed durations), 19 a
/// charged skill (packed charges), 36 a random class skill.
fn bounded(func: i64) bool {
    return switch (func) {
        11, 12, 18, 19, 36 => false,
        else => true,
    };
}

pub const Builder = struct {
    gpa: std.mem.Allocator,
    t: *const tables.Tables,
    ctx: properties.PropContext,
    /// 1.06's rolls: the top of a range is never reached.
    prepatch: bool = false,
    out: Ranges = .{},

    /// One property of a row, applied at both ends of its range.
    pub fn property(b: *Builder, code: []const u8, param: i32, min: i32, max: i32) !void {
        if (code.len == 0) return;
        if (b.t.properties.findByStr("code", code) == null) return;
        const lo_in = @min(min, max);
        var hi_in = @max(min, max);
        if (b.prepatch and hi_in > lo_in) hi_in -= 1;

        var low: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        defer low.deinit(b.gpa);
        var high: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        defer high.deinit(b.gpa);
        var exact: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        defer exact.deinit(b.gpa);
        var funcs: std.ArrayListUnmanaged(i64) = .empty;
        defer funcs.deinit(b.gpa);
        var seed = rng.Seed.init(0, 0);
        try properties.applyPropertyTagged(b.gpa, &low, &funcs, &seed, b.t, code, param, lo_in, lo_in, b.ctx);
        try properties.applyProperty(b.gpa, &high, &seed, b.t, code, param, hi_in, hi_in, b.ctx);
        // 15 and 16 take `min` and `max` as the two ends of a damage range, verbatim: those stats do not roll
        try properties.applyProperty(b.gpa, &exact, &seed, b.t, code, param, min, max, b.ctx);

        var all_bounded = true;
        for (funcs.items) |f| if (!bounded(f)) {
            all_bounded = false;
        };
        if (!all_bounded or low.items.len != high.items.len or exact.items.len != low.items.len) {
            for (low.items) |r| (try b.out.slot(b.gpa, r.stat, r.layer)).unknown = true;
            for (high.items) |r| (try b.out.slot(b.gpa, r.stat, r.layer)).unknown = true;
            return;
        }
        for (low.items, high.items, exact.items, funcs.items) |l0, h0, x, f| {
            const fixed = f == 15 or f == 16;
            const l = if (fixed) x else l0;
            const h = if (fixed) x else h0;
            const s = try b.out.slot(b.gpa, l.stat, l.layer);
            if (l.stat != h.stat or l.layer != h.layer) {
                s.unknown = true;
                (try b.out.slot(b.gpa, h.stat, h.layer)).unknown = true;
                continue;
            }
            s.lo += @min(l.value, h.value);
            s.hi += @max(l.value, h.value);
            if (l.value != h.value) s.rolls = true;
        }
    }

    /// `prop{N}`/`par{N}`/`min{N}`/`max{N}` (UniqueItems, SetItems), slots 1..n.
    pub fn props(b: *Builder, tbl: *const txt.Table, row: usize, n: usize) !void {
        if (row >= tbl.rowCount()) return;
        var c: [12]u8 = undefined;
        var p: [12]u8 = undefined;
        var lo: [12]u8 = undefined;
        var hi: [12]u8 = undefined;
        for (1..n + 1) |i| {
            try b.property(
                tbl.str(row, std.fmt.bufPrint(&c, "prop{d}", .{i}) catch unreachable),
                @intCast(tbl.int(row, std.fmt.bufPrint(&p, "par{d}", .{i}) catch unreachable)),
                @intCast(tbl.int(row, std.fmt.bufPrint(&lo, "min{d}", .{i}) catch unreachable)),
                @intCast(tbl.int(row, std.fmt.bufPrint(&hi, "max{d}", .{i}) catch unreachable)),
            );
        }
    }

    /// `mod{N}code`/`mod{N}param`/`mod{N}min`/`mod{N}max` (MagicPrefix, MagicSuffix, AutoMagic), slots 1..3.
    pub fn mods(b: *Builder, tbl: *const txt.Table, row: usize) !void {
        if (row >= tbl.rowCount()) return;
        var c: [12]u8 = undefined;
        var p: [12]u8 = undefined;
        var lo: [12]u8 = undefined;
        var hi: [12]u8 = undefined;
        for (1..4) |i| {
            const code = tbl.str(row, std.fmt.bufPrint(&c, "mod{d}code", .{i}) catch unreachable);
            if (code.len == 0) break;
            try b.property(
                code,
                @intCast(tbl.int(row, std.fmt.bufPrint(&p, "mod{d}param", .{i}) catch unreachable)),
                @intCast(tbl.int(row, std.fmt.bufPrint(&lo, "mod{d}min", .{i}) catch unreachable)),
                @intCast(tbl.int(row, std.fmt.bufPrint(&hi, "mod{d}max", .{i}) catch unreachable)),
            );
        }
    }

    /// A Runes.txt row's `T1Code{N}` slots, stopping at the first empty one (RollRunewordMostlikely 0x6600a0).
    pub fn runeword(b: *Builder, row: usize) !void {
        const rt = &b.t.runes;
        if (row >= rt.rowCount()) return;
        var c: [12]u8 = undefined;
        var p: [12]u8 = undefined;
        var lo: [12]u8 = undefined;
        var hi: [12]u8 = undefined;
        for (1..8) |i| {
            const code = rt.str(row, std.fmt.bufPrint(&c, "T1Code{d}", .{i}) catch unreachable);
            if (code.len == 0) break;
            try b.property(
                code,
                @intCast(rt.int(row, std.fmt.bufPrint(&p, "T1Param{d}", .{i}) catch unreachable)),
                @intCast(rt.int(row, std.fmt.bufPrint(&lo, "T1Min{d}", .{i}) catch unreachable)),
                @intCast(rt.int(row, std.fmt.bufPrint(&hi, "T1Max{d}", .{i}) catch unreachable)),
            );
        }
    }

    /// A gem's or a rune's Gems.txt mods for what it sits in: fixed values.
    pub fn filler(b: *Builder, code: []const u8, target: properties.SocketTarget) !void {
        const gt = &b.t.gems;
        const row = gt.findByStr("code", code) orelse return;
        const prefix = switch (target) {
            .weapon => "weapon",
            .helm => "helm",
            .shield => "shield",
        };
        var c: [24]u8 = undefined;
        var p: [24]u8 = undefined;
        var lo: [24]u8 = undefined;
        var hi: [24]u8 = undefined;
        for (1..4) |i| {
            const mc = gt.str(row, std.fmt.bufPrint(&c, "{s}Mod{d}Code", .{ prefix, i }) catch unreachable);
            if (mc.len == 0) break;
            try b.property(
                mc,
                @intCast(gt.int(row, std.fmt.bufPrint(&p, "{s}Mod{d}Param", .{ prefix, i }) catch unreachable)),
                @intCast(gt.int(row, std.fmt.bufPrint(&lo, "{s}Mod{d}Min", .{ prefix, i }) catch unreachable)),
                @intCast(gt.int(row, std.fmt.bufPrint(&hi, "{s}Mod{d}Max", .{ prefix, i }) catch unreachable)),
            );
        }
    }
};

/// How a range is written after a stat's line.
pub const Style = enum {
    off,
    /// every stat a row gives: `[lo-hi]`, or `[v]` for a fixed one, in dark grey
    grey,
    /// the same in a darker blue than the stat lines' own
    dark_blue,
    /// only stats that roll, dark grey; gold when the value is at the best end
    rolled,
};

/// The text after a stat line: a space, a colour code, the bracket, and `restore` (the caller's marker for "back to
/// the line's own colour"). Empty when there is nothing to say: no range, or a value outside it (a source the item
/// does not record, such as a crafting recipe's fixed mods, a superior roll, or an ear's owner).
pub fn annotate(buf: []u8, style: Style, shown: i32, lo: i32, hi: i32, rolls: bool, lower_is_better: bool, restore: []const u8) []const u8 {
    if (style == .off) return buf[0..0];
    const a = @min(lo, hi);
    const z = @max(lo, hi);
    if (shown < a or shown > z) return buf[0..0];
    if (style == .rolled and !rolls) return buf[0..0];
    const best = if (lower_is_better) a else z;
    const colour: u8 = switch (style) {
        .dark_blue => '<', // colour 12, which the mock draws as a darker blue
        .rolled => if (rolls and shown == best) '4' else '5',
        else => '5',
    };
    const cc = "\xc3\xbfc";
    const w = if (a == z)
        std.fmt.bufPrint(buf, " {s}{c}[{d}]{s}", .{ cc, colour, a, restore })
    else if (a < 0)
        std.fmt.bufPrint(buf, " {s}{c}[{d} to {d}]{s}", .{ cc, colour, a, z, restore })
    else
        std.fmt.bufPrint(buf, " {s}{c}[{d}-{d}]{s}", .{ cc, colour, a, z, restore });
    return w catch buf[0..0];
}

/// The same for a damage line whose minimum and maximum roll apart: `[1-2 to 8-10]`, a fixed end as one number.
pub fn annotatePair(buf: []u8, style: Style, shown: [2]i32, min: Range, max: Range, restore: []const u8) []const u8 {
    if (style == .off) return buf[0..0];
    const ends = [2]Range{ min, max };
    for (ends, shown) |r, v| if (v < @min(r.lo, r.hi) or v > @max(r.lo, r.hi)) return buf[0..0];
    const rolls = min.rolls or max.rolls;
    if (style == .rolled and !rolls) return buf[0..0];
    const perfect = shown[0] == @max(min.lo, min.hi) and shown[1] == @max(max.lo, max.hi);
    const colour: u8 = switch (style) {
        .dark_blue => '<',
        .rolled => if (perfect) '4' else '5',
        else => '5',
    };
    var w: std.Io.Writer = .fixed(buf);
    w.print(" \xc3\xbfc{c}[", .{colour}) catch return buf[0..0];
    if (!rolls) {
        // a fixed damage range reads as the line does
        const a = @min(min.lo, min.hi);
        const z = @max(max.lo, max.hi);
        if (a == z) w.print("{d}]{s}", .{ a, restore }) catch return buf[0..0] else w.print("{d}-{d}]{s}", .{ a, z, restore }) catch return buf[0..0];
        return w.buffered();
    }
    for (ends, 0..) |r, i| {
        if (i == 1) w.writeAll(" to ") catch return buf[0..0];
        const a = @min(r.lo, r.hi);
        const z = @max(r.lo, r.hi);
        if (a == z) w.print("{d}", .{a}) catch return buf[0..0] else w.print("{d}-{d}", .{ a, z }) catch return buf[0..0];
    }
    w.print("]{s}", .{restore}) catch return buf[0..0];
    return w.buffered();
}

// -------------------------------------------------------------------------------------------------
// tests

test "a damage line: each end its own range" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings(" \xc3\xbfc5[1 to 8-10]", annotatePair(&b, .grey, .{ 1, 9 }, .{ .lo = 1, .hi = 1 }, .{ .lo = 8, .hi = 10, .rolls = true }, ""));
    try testing.expectEqualStrings(" \xc3\xbfc4[1-2 to 8-10]", annotatePair(&b, .rolled, .{ 2, 10 }, .{ .lo = 1, .hi = 2, .rolls = true }, .{ .lo = 8, .hi = 10, .rolls = true }, ""));
    try testing.expectEqualStrings("", annotatePair(&b, .rolled, .{ 1, 3 }, .{ .lo = 1, .hi = 1 }, .{ .lo = 3, .hi = 3 }, ""));
}

const testing = std.testing;

test "a fixed bound reads [v], a range [lo-hi], and a value outside the range says nothing" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings(" \xc3\xbfc5[1]\x01", annotate(&b, .grey, 1, 1, 1, false, false, "\x01"));
    try testing.expectEqualStrings(" \xc3\xbfc5[30-40]\x01", annotate(&b, .grey, 35, 30, 40, true, false, "\x01"));
    try testing.expectEqualStrings("", annotate(&b, .grey, 45, 30, 40, true, false, "\x01"));
    try testing.expectEqualStrings("", annotate(&b, .off, 35, 30, 40, true, false, "\x01"));
}

test "rolled: fixed stats unchanged, the best end in gold, a lower-is-better stat best at its low end" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("", annotate(&b, .rolled, 1, 1, 1, false, false, ""));
    try testing.expectEqualStrings(" \xc3\xbfc4[20-30]", annotate(&b, .rolled, 30, 20, 30, true, false, ""));
    try testing.expectEqualStrings(" \xc3\xbfc5[20-30]", annotate(&b, .rolled, 25, 20, 30, true, false, ""));
    try testing.expectEqualStrings(" \xc3\xbfc4[-30 to -20]", annotate(&b, .rolled, -30, -20, -30, true, true, ""));
}

test "the dark blue style writes colour 12" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings(" \xc3\xbfc<[3-5]", annotate(&b, .dark_blue, 4, 3, 5, true, false, ""));
}
