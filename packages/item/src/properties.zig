//! Item property application — turning an affix/unique/set/runeword property (a Properties.txt `code`
//! plus the row's min/max) into rolled stat values. Faithful to the 1.14d expansion path
//! ITEMMOD_ApplyPropertyToUnitStatsExpansion @0x65fd70 + the value roll ITEMMOD_RollRandomValue @0x65e9e0.
//!
//! A Properties.txt row carries up to 7 {func, stat, val, set} slots. The engine indexes a 37-entry
//! PROPERTIESFUNCTIONS dispatch table (0x7462f8) by `func`; a func with no handler stops the slot
//! loop. Each handler returns the value it applied, and slot 0's return is fed to every later slot
//! as the "already rolled" value — which is how "res-all" (func 1 then func 3 x3) gives all four
//! resistances ONE rolled number off ONE seed advance.
//!
//! Ported handlers, by func index (engine name -> what it contributes here):
//!   1,2   AddStat_Enhanced*            roll [min,max] into the row's stat
//!   3,4   AddStat_PreserveRolledValue  reuse slot 0's value (roll only if it was 0)
//!   5,6   AddMin/MaxDamage             the 1H / 2H / throw damage stats of the base item
//!   7     AddEnhancedDamage            the two enhanced-damage stats
//!   8     AddStat_Simple               reuse slot 0's value, else roll
//!   9     AddSkillBonus                layer = the skill id in `param`
//!   10    AddClassSkillBonus           layer = param%3 + (param/3)*8
//!   12    AddStat_RandLevelAsLayer     layer = the roll, value = `param`
//!   13    AddStat_WithMaxDurabilityReset
//!   15,16 SetFixedMin/MaxDamage        value is `min` / `max` verbatim, no roll
//!   17    AddStat_FixedOrRolledMaxDamageAware  value = `param`, else roll
//!   18    AddTimedStat                 duration/count packed into one value
//!   20    SetIndestructible            the fixed indestructible stat
//!   21    AddStat_WithLayerFromParam7  layer = the Properties row's `val`
//!   22,24 AddStat_LayerFromParam4*     layer = `param`
//!   36    AddStat_LayerFromRoll_ValueFromParam7
//! Residual: 11/19 (charged skills) apply the skill+charges stat only when the level is given
//! explicitly — the derived-from-item-level case needs Skills.txt req/max levels. 14 (sockets) and
//! 23 (ethereal) set item FLAGS rather than mod stats and are handled by the drop model instead.

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");

/// One rolled stat contribution: the ItemStatCost numeric stat `id`, its `layer` (the engine's
/// per-stat sub-index — skill id, elemental type, class, …) and the rolled `value`.
pub const RolledStat = struct { stat: i32, layer: i32 = 0, value: i32 };

/// Fixed stat IDs the damage/durability handlers write directly (they ignore the row's stat column).
const Stat = struct {
    const min_damage = 0x15;
    const max_damage = 0x16;
    const secondary_min_damage = 0x17;
    const secondary_max_damage = 0x18;
    const throw_min_damage = 0x9f;
    const throw_max_damage = 0xa0;
    const enhanced_damage_max = 0x12;
    const enhanced_damage_min = 0x11;
    const indestructible = 0x98;
};

/// The base item a property is being applied to. The damage handlers pick 1H / 2H / throw stats from
/// its Weapons.txt damage columns, so they need the item, not just the property row.
pub const PropContext = struct {
    code: []const u8 = "",
    item_level: i32 = 0,
};

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

/// Apply a Properties.txt `code` with one property entry's (param, min, max), appending each rolled
/// {stat, layer, value} to `out`. Walks the 7 func slots exactly like
/// ITEMMOD_ApplyPropertyToUnitStatsExpansion 0x65fd70: a func with no handler stops the loop, and
/// slot 0's applied value is threaded into every later slot.
pub fn applyProperty(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RolledStat),
    seed: *rng.Seed,
    t: *const tables.Tables,
    code: []const u8,
    param: i32,
    min: i32,
    max: i32,
    ctx: PropContext,
) !void {
    const pt = &t.properties;
    const prow = pt.findByStr("code", code) orelse return; // unknown property code
    var fbuf: [8]u8 = undefined;
    var sbuf: [8]u8 = undefined;
    var vbuf: [8]u8 = undefined;

    var chained: i32 = 0;
    for (0..7) |slot| {
        const func = pt.int(prow, std.fmt.bufPrint(&fbuf, "func{d}", .{slot + 1}) catch unreachable);
        if (!hasHandler(func)) break;
        const stat_name = pt.str(prow, std.fmt.bufPrint(&sbuf, "stat{d}", .{slot + 1}) catch unreachable);
        const val: i32 = @intCast(pt.int(prow, std.fmt.bufPrint(&vbuf, "val{d}", .{slot + 1}) catch unreachable));
        const applied = try applyFunc(gpa, out, seed, t, .{
            .func = func,
            .stat = statId(t, stat_name),
            .val = val,
            .chained = chained,
            .param = param,
            .min = min,
            .max = max,
            .ctx = ctx,
        });
        if (slot == 0) chained = applied;
    }
}

/// PROPERTIESFUNCTIONS 0x7462f8 is 37 slots wide with holes; anything else ends the walk.
fn hasHandler(func: i64) bool {
    return (func >= 1 and func <= 24) or func == 36;
}

const FuncArgs = struct {
    func: i64,
    stat: ?i32,
    val: i32,
    chained: i32,
    param: i32,
    min: i32,
    max: i32,
    ctx: PropContext,
};

/// One PROPERTIESFUNCTIONS entry. Returns the value it applied — slot 0's return is the `chained`
/// value every later slot of the same property sees.
fn applyFunc(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RolledStat),
    seed: *rng.Seed,
    t: *const tables.Tables,
    a: FuncArgs,
) !i32 {
    switch (a.func) {
        // Always roll, layer 0.
        1, 2, 13 => {
            const v = rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, 0, v);
            return v;
        },
        // Reuse slot 0's value when it produced one, else roll.
        3, 4, 8 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, 0, v);
            return v;
        },
        5 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            try emitDamage(gpa, out, t, a.ctx, v, .min);
            return v;
        },
        6 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            try emitDamage(gpa, out, t, a.ctx, v, .max);
            return v;
        },
        7 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            try emit(gpa, out, Stat.enhanced_damage_max, 0, v);
            try emit(gpa, out, Stat.enhanced_damage_min, 0, v);
            return v;
        },
        // Skill bonus: the skill id is the layer, and a zero value applies nothing.
        9 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            if (v == 0) return 0;
            try emit(gpa, out, a.stat, a.param, v);
            return v;
        },
        // Class skill bonus: param is a (class, tab) pair packed base-3 then re-spread base-8.
        10 => {
            const v = if (a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            if (v == 0) return 0;
            try emit(gpa, out, a.stat, @mod(a.param, 3) + @divTrunc(a.param, 3) * 8, v);
            return v;
        },
        // Charged skill: layer packs skill<<6 | level, value is the charge count.
        11 => {
            const skill = a.param;
            const charges = if (a.min < 1) 5 else a.min;
            const level = a.max;
            if (level <= 0) return 0; // derived-from-item-level case: needs Skills.txt (residual)
            try emit(gpa, out, a.stat, skill * 64 + (level & 0x3f), charges);
            return charges;
        },
        // The roll picks the LAYER; the value is the property entry's param.
        12 => {
            const layer = rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, layer, a.param);
            return a.param;
        },
        14, 23 => return 0, // sockets / ethereal are item flags, not mod stats
        // Fixed damage: the range bound is the value verbatim, no roll.
        15 => {
            if (a.stat == Stat.min_damage) {
                try emitDamage(gpa, out, t, a.ctx, a.min, .min);
            } else {
                try emit(gpa, out, a.stat, 0, a.min);
            }
            return a.min;
        },
        16 => {
            if (a.stat == Stat.max_damage) {
                try emitDamage(gpa, out, t, a.ctx, a.max, .max);
            } else {
                try emit(gpa, out, a.stat, 0, a.max);
            }
            return a.max;
        },
        17 => {
            const v = if (a.param != 0) a.param else rollValue(seed, a.min, a.max);
            if (v == 0) return 0;
            if (a.stat == Stat.max_damage) {
                try emitDamage(gpa, out, t, a.ctx, v, .max);
            } else {
                try emit(gpa, out, a.stat, 0, v);
            }
            return v;
        },
        // Timed stat: the two durations are biased by 0x100, clamped to 0x3ff and packed with a
        // 0..3 count into one value.
        18 => {
            const count = std.math.clamp(a.param, 0, 3);
            const lo = std.math.clamp(a.min + 0x100, 0, 0x3ff);
            const hi = std.math.clamp(a.max + 0x100, 0, 0x3ff);
            try emit(gpa, out, a.stat, 0, count + (hi * 0x400 + lo) * 4);
            return hi;
        },
        19 => {
            const skill = a.param;
            const charges = if (a.min == 0) 5 else a.min;
            const level = a.max;
            if (level <= 0 or charges < 0) return 0; // derived level/charges: residual
            try emit(gpa, out, a.stat, skill * 64 + (level & 0x3f), charges);
            return charges;
        },
        20 => {
            try emit(gpa, out, Stat.indestructible, 0, 1);
            return 1;
        },
        21 => {
            const v = rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, a.val, v);
            return v;
        },
        22, 24 => {
            const v = if (a.func == 24 and a.chained != 0) a.chained else rollValue(seed, a.min, a.max);
            const layer = if (a.func == 22) a.param & 0xffff else a.param;
            try emit(gpa, out, a.stat, layer, v);
            return v;
        },
        36 => {
            const layer = rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, layer, a.val);
            return a.val;
        },
        else => return 0,
    }
}

fn emit(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), stat: ?i32, layer: i32, value: i32) !void {
    const sid = stat orelse return; // unresolved stat name -> nothing to add
    try out.append(gpa, .{ .stat = sid, .layer = layer, .value = value });
}

/// ITEMPROP_AddMin/MaxDamage: the same rolled number lands on whichever of the base item's damage
/// stats actually exist — one-handed, two-handed, and (for throwables) the missile pair.
fn emitDamage(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RolledStat),
    t: *const tables.Tables,
    ctx: PropContext,
    value: i32,
    which: enum { min, max },
) !void {
    const is_min = which == .min;
    const ref = t.itemRef(ctx.code) orelse {
        // No base item in context: the engine's non-item path still writes the primary stat.
        try emit(gpa, out, if (is_min) Stat.min_damage else Stat.max_damage, 0, value);
        return;
    };
    const tbl = t.itemTable(ref.table);
    const one: i32 = @intCast(tbl.int(ref.row, if (is_min) "mindam" else "maxdam"));
    const two: i32 = @intCast(tbl.int(ref.row, if (is_min) "2handmindam" else "2handmaxdam"));
    const mis: i32 = @intCast(tbl.int(ref.row, if (is_min) "minmisdam" else "maxmisdam"));
    const floor: i32 = if (is_min) 1 else 0;

    var types = try @import("itemtype.zig").typesForItem(gpa, t, ctx.code);
    defer types.deinit(gpa);
    const is_weapon = types.has("weap");

    if (!is_weapon or one != 0 or two == 0) {
        const v = if (one != 0 and one + value < floor + 1) floor - one else value;
        if (v != 0) try emit(gpa, out, if (is_min) Stat.min_damage else Stat.max_damage, 0, v);
    }
    if (!is_weapon or two != 0 or one == 0) {
        const v = if (two != 0 and two + value < floor + 1) floor - two else value;
        if (v != 0) try emit(gpa, out, if (is_min) Stat.secondary_min_damage else Stat.secondary_max_damage, 0, v);
    }
    if (!is_weapon or isThrowable(t, ctx.code)) {
        const v = if (mis != 0 and mis + value < floor + 1) floor - mis else value;
        if (v != 0) try emit(gpa, out, if (is_min) Stat.throw_min_damage else Stat.throw_max_damage, 0, v);
    }
}

fn isThrowable(t: *const tables.Tables, code: []const u8) bool {
    const ref = t.itemRef(code) orelse return false;
    const type_code = t.itemTable(ref.table).str(ref.row, "type");
    const row = t.itypeRow(type_code) orelse return false;
    return t.item_types.int(row, "Throwable") != 0;
}

/// Roll all of a unique item's rolled stats (ApplyRuneAndGemStats(3) @0x65fec0): iterate the UniqueItems
/// row's 12 prop slots (propN/minN/maxN), applying each populated property. Empty slots roll nothing (no
/// seed advance), matching the engine's failed-lookup no-op. `unique_id` is the 1-based row (from
/// affix.rollUniqueItem); `parN` feeds the skill/charge/layer property funcs.
pub fn rollUniqueStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, unique_id: u16, ctx: PropContext) !void {
    if (unique_id == 0) return;
    try rollTableProps(gpa, out, seed, t, &t.unique_items, unique_id - 1, 12, ctx);
}

/// Roll a set item's own rolled stats (ApplyRuneAndGemStats(4) @0x65fec0): the SetItems row's 9 prop
/// slots. The partial-set `aprop` bonuses (worn-piece-count gated) and the full-set Sets.txt bonuses are
/// applied on EQUIP, not here — a follow-up tied to the equipment model.
pub fn rollSetStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, set_id: u16, ctx: PropContext) !void {
    if (set_id == 0) return;
    try rollTableProps(gpa, out, seed, t, &t.set_items, set_id - 1, 9, ctx);
}

fn rollTableProps(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, tbl: *const @import("txt.zig").Table, row: usize, nslots: usize, ctx: PropContext) !void {
    if (row >= tbl.rowCount()) return;
    var pbuf: [8]u8 = undefined;
    var parbuf: [8]u8 = undefined;
    var lobuf: [8]u8 = undefined;
    var hibuf: [8]u8 = undefined;
    var n: usize = 1;
    while (n <= nslots) : (n += 1) {
        const prop = tbl.str(row, std.fmt.bufPrint(&pbuf, "prop{d}", .{n}) catch unreachable);
        if (prop.len == 0) continue; // empty slot -> no property, no roll
        const par: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&parbuf, "par{d}", .{n}) catch unreachable));
        const min: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&lobuf, "min{d}", .{n}) catch unreachable));
        const max: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&hibuf, "max{d}", .{n}) catch unreachable));
        try applyProperty(gpa, out, seed, t, prop, par, min, max, ctx);
    }
}

/// Roll the stats of one magic/rare affix (a MagicPrefix/MagicSuffix row): each affix carries up to 3
/// mods (mod1code/mod1min/mod1max…). `affix_id` is the 1-based row (from affix.roll*). Empty mod slots
/// roll nothing. `modNparam` feeds the skill/charge/layer property funcs.
pub fn rollAffixStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, tbl: *const @import("txt.zig").Table, affix_id: u16, ctx: PropContext) !void {
    if (affix_id == 0) return;
    try rollModSlots(gpa, out, seed, t, tbl, affix_id - 1, 3, ctx);
}

/// The `mod{N}code/param/min/max` shape shared by MagicPrefix/MagicSuffix and QualityItems.
/// ApplyRuneAndGemStats STOPS at the first unset property (fcode < 0) rather than skipping it.
fn rollModSlots(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, tbl: *const @import("txt.zig").Table, row: usize, nslots: usize, ctx: PropContext) !void {
    if (row >= tbl.rowCount()) return;
    var cbuf: [12]u8 = undefined;
    var pbuf: [12]u8 = undefined;
    var lobuf: [12]u8 = undefined;
    var hibuf: [12]u8 = undefined;
    var n: usize = 1;
    while (n <= nslots) : (n += 1) {
        const code = tbl.str(row, std.fmt.bufPrint(&cbuf, "mod{d}code", .{n}) catch unreachable);
        if (code.len == 0) break;
        const par: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&pbuf, "mod{d}param", .{n}) catch unreachable));
        const min: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&lobuf, "mod{d}min", .{n}) catch unreachable));
        const max: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&hibuf, "mod{d}max", .{n}) catch unreachable));
        try applyProperty(gpa, out, seed, t, code, par, min, max, ctx);
    }
}

/// Assemble ALL of a rolled drop's mod stats from its selected affixes/unique/set — the one call the
/// item bitstream + equip stat-application consume. Dispatches on the drop's quality: magic -> prefix +
/// suffix; rare -> its up-to-3 prefixes + suffixes; unique -> UniqueItems props; set -> SetItems props.
/// Normal/low/superior carry no mod stats. Caller owns `out`.
pub fn rollDropStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, d: *const @import("model.zig").Drop) !void {
    const ctx = PropContext{ .code = d.code(), .item_level = d.item_level };
    switch (d.quality) {
        .magic => {
            try rollAffixStats(gpa, out, seed, t, &t.magic_prefix, d.prefix_id, ctx);
            try rollAffixStats(gpa, out, seed, t, &t.magic_suffix, d.suffix_id, ctx);
        },
        .rare => {
            for (d.rare_prefix_ids) |id| try rollAffixStats(gpa, out, seed, t, &t.magic_prefix, id, ctx);
            for (d.rare_suffix_ids) |id| try rollAffixStats(gpa, out, seed, t, &t.magic_suffix, id, ctx);
        },
        .unique => try rollUniqueStats(gpa, out, seed, t, d.unique_id, ctx),
        .set => try rollSetStats(gpa, out, seed, t, d.set_id, ctx),
        .superior => try rollQualityItemStats(gpa, out, seed, t, d.quality_id, ctx),
        else => {},
    }
}

/// The superior bonus: ApplyRuneAndGemStats(1) walks the chosen QualityItems.txt row's TWO mod slots.
pub fn rollQualityItemStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, quality_id: u16, ctx: PropContext) !void {
    if (quality_id == 0) return;
    try rollModSlots(gpa, out, seed, t, &t.quality_items, quality_id - 1, 2, ctx);
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

test "rollAffixStats + rollDropStats: deterministic; a magic drop rolls its affix stats" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var a: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer b.deinit(testing.allocator);

    var good_prefix: u16 = 0;
    for (0..t.magic_prefix.rowCount()) |row| {
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        var s1 = rng.Seed.init(0x9, 0x29a);
        var s2 = rng.Seed.init(0x9, 0x29a);
        try rollAffixStats(testing.allocator, &a, &s1, &t, &t.magic_prefix, @intCast(row + 1), .{});
        try rollAffixStats(testing.allocator, &b, &s2, &t, &t.magic_prefix, @intCast(row + 1), .{});
        try testing.expectEqual(a.items.len, b.items.len);
        for (a.items, b.items) |x, y| {
            try testing.expectEqual(x.stat, y.stat);
            try testing.expectEqual(x.value, y.value);
        }
        if (a.items.len > 0 and good_prefix == 0) good_prefix = @intCast(row + 1);
    }
    try testing.expect(good_prefix != 0);

    // A magic drop carrying that prefix routes through rollDropStats and yields its stat(s).
    const model = @import("model.zig");
    var d = model.Drop{ .kind = .item, .quality = .magic, .item_level = 60 };
    d.prefix_id = good_prefix;
    a.clearRetainingCapacity();
    var s = rng.Seed.init(0x9, 0x29a);
    try rollDropStats(testing.allocator, &a, &s, &t, &d);
    try testing.expect(a.items.len > 0);
}

test "rollUniqueStats: deterministic, and real uniques produce rolled stats" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var a: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer b.deinit(testing.allocator);

    var any_stats = false;
    for (0..t.unique_items.rowCount()) |row| {
        if (t.unique_items.int(row, "enabled") == 0) continue;
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        var s1 = rng.Seed.init(0x42, 0x29a);
        var s2 = rng.Seed.init(0x42, 0x29a);
        try rollUniqueStats(testing.allocator, &a, &s1, &t, @intCast(row + 1), .{});
        try rollUniqueStats(testing.allocator, &b, &s2, &t, @intCast(row + 1), .{});
        try testing.expectEqual(a.items.len, b.items.len); // same seed -> same roll
        for (a.items, b.items) |x, y| {
            try testing.expectEqual(x.stat, y.stat);
            try testing.expectEqual(x.value, y.value);
        }
        if (a.items.len > 0) any_stats = true;
    }
    try testing.expect(any_stats); // the assembly resolves at least some uniques' properties
}

test "res-all: one roll, one seed advance, shared by all four resistances" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);

    var s = rng.Seed.init(0x321, 0x29a);
    const before = s.low;
    try applyProperty(testing.allocator, &out, &s, &t, "res-all", 0, 10, 20, .{});
    try testing.expectEqual(@as(usize, 4), out.items.len);
    for (out.items) |st| try testing.expectEqual(out.items[0].value, st.value);
    try testing.expect(out.items[0].value >= 10 and out.items[0].value <= 20);

    // Exactly ONE LCG advance for the whole property (func 1 rolls, funcs 3 reuse).
    var s2 = rng.Seed.init(before, 0x29a);
    _ = s2.next();
    try testing.expectEqual(s2.low, s.low);
}

test "dmg-cold: min/max come from the range bounds, length from the param" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);

    var s = rng.Seed.init(0x99, 0x29a);
    try applyProperty(testing.allocator, &out, &s, &t, "dmg-cold", 75, 3, 9, .{});
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(statId(&t, "coldmindam").?, out.items[0].stat);
    try testing.expectEqual(@as(i32, 3), out.items[0].value);
    try testing.expectEqual(statId(&t, "coldmaxdam").?, out.items[1].stat);
    try testing.expectEqual(@as(i32, 9), out.items[1].value);
    try testing.expectEqual(statId(&t, "coldlength").?, out.items[2].stat);
    try testing.expectEqual(@as(i32, 75), out.items[2].value); // func 17 takes the param
}

test "skill properties carry the skill id in the stat layer" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);

    // "skill" (func 9) — +N to a single skill; the skill id is the layer, not the value.
    var s = rng.Seed.init(0x55, 0x29a);
    try applyProperty(testing.allocator, &out, &s, &t, "skill", 54, 2, 2, .{});
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(i32, 54), out.items[0].layer);
    try testing.expectEqual(@as(i32, 2), out.items[0].value);
}

test "the full unique table produces far more stats than the single-stat funcs alone" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);

    var with_stats: u32 = 0;
    var total: u32 = 0;
    for (0..t.unique_items.rowCount()) |row| {
        if (t.unique_items.int(row, "enabled") == 0) continue;
        out.clearRetainingCapacity();
        var s = rng.Seed.init(@intCast(row + 1), 0x29a);
        try rollUniqueStats(testing.allocator, &out, &s, &t, @intCast(row + 1), .{ .code = t.unique_items.str(row, "code"), .item_level = 85 });
        total += 1;
        if (out.items.len > 0) with_stats += 1;
    }
    // Every enabled unique carries at least one property; if the dispatch table were
    // missing handlers, entire uniques would come back empty.
    try testing.expect(total > 300);
    try testing.expectEqual(total, with_stats);
}

test "applyProperty: a simple +stat property rolls one stat in range" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    // "str" is Properties func1 -> stat "strength".
    const str_id = statId(&t, "strength").?;

    var out: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer out.deinit(testing.allocator);
    var s = rng.Seed.init(0x777, 0x29a);
    try applyProperty(testing.allocator, &out, &s, &t, "str", 0, 10, 20, .{});
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(str_id, out.items[0].stat);
    try testing.expect(out.items[0].value >= 10 and out.items[0].value <= 20);

    // Fixed range -> exact value, and an unknown code contributes nothing.
    out.clearRetainingCapacity();
    try applyProperty(testing.allocator, &out, &s, &t, "str", 0, 7, 7, .{});
    try testing.expectEqual(@as(i32, 7), out.items[0].value);
    out.clearRetainingCapacity();
    try applyProperty(testing.allocator, &out, &s, &t, "zzz-nope", 0, 1, 5, .{});
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
