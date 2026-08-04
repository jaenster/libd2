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
    /// Classic set items carry only 2 base property slots and no partial-set bonuses.
    is_expansion: bool = true,
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
        // Skill charges: layer packs skill<<6 | level, value is the charge count.
        11 => {
            const skill = a.param;
            const charges = if (a.min < 1) 5 else a.min;
            const level = skillLevel(t, skill, a.max, a.ctx.item_level);
            try emit(gpa, out, a.stat, skill * 64 + (level & 0x3f), charges);
            return charges;
        },
        // The roll picks the LAYER; the value is the property entry's param.
        12 => {
            const layer = rollValue(seed, a.min, a.max);
            try emit(gpa, out, a.stat, layer, a.param);
            return a.param;
        },
        // ITEMPROP_SetSockets 0x65f590: the count is the property's `param` when set, else a roll,
        // clamped to the base item's own socket cap. Also raises ITEMFLAG_SOCKETED, which the drop
        // model carries as `sockets` rather than a stat.
        14 => {
            const n = if (a.param >= 1) a.param else rollValue(seed, a.min, a.max);
            const cap = socketCap(t, a.ctx.code, a.ctx.item_level);
            if (cap < 1) return 0;
            const v = std.math.clamp(n, 1, cap);
            try emit(gpa, out, a.stat, 0, v);
            return v;
        },
        // ITEMPROP_ApplyEthereal 0x65fd20 delegates to ITEMMOD_ApplyEtherealBonus: it raises
        // ITEMFLAG_ETHEREAL and scales damage/AC, writing no mod stat of its own.
        23 => return 0,
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
        // Charged skill: the value packs current | max<<8, and the current count is itself rolled.
        19 => {
            const skill = a.param;
            const level = skillLevel(t, skill, a.max, a.ctx.item_level);
            var max_charge: i32 = a.min;
            if (max_charge == 0) {
                max_charge = 5;
            } else if (max_charge < 0) {
                max_charge = -a.min + @divTrunc(-a.min * level, 8);
            }
            max_charge = std.math.clamp(max_charge, 1, 0xff);
            const step = @divTrunc(max_charge + 7, 8);
            const rolled: i32 = @bitCast(seed.pick(@bitCast(max_charge - step)));
            const value = ((rolled + 1 + step) & 0xff) + max_charge * 0x100;
            try emit(gpa, out, a.stat, skill * 64 + (level & 0x3f), value);
            return value;
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

/// The skill level a charged/skill-charges property grants (shared by funcs 11 and 19). A positive
/// stored level is used verbatim; 0 derives it from how far the item level exceeds the skill's own
/// requirement; a negative stored level spreads that same gap over a divisor. The result is clamped to
/// the skill's `maxlvl`.
fn skillLevel(t: *const tables.Tables, skill: i32, stored: i32, item_level: i32) i32 {
    if (stored > 0) return stored;
    const sk = &t.skills;
    const row: usize = if (skill >= 0 and skill < sk.rowCount()) @intCast(skill) else return @max(stored, 1);
    const req: i32 = @intCast(sk.int(row, "reqlevel"));
    var max_lvl: i32 = @intCast(sk.int(row, "maxlvl"));
    if (max_lvl < 1) max_lvl = 20;

    if (stored == 0) {
        return std.math.clamp(@divTrunc(item_level - req, 4) + 1, 1, max_lvl);
    }
    const span: i32 = if (99 - req > 1) 99 - req else 1;
    var divisor = @divTrunc(-span, stored);
    if (divisor < 1) divisor = 1;
    return @max(@divTrunc(item_level - req, divisor), 1);
}

/// The socket ceiling func 14 clamps to: the inventory footprint, the engine's hard 6, and the base
/// item's own MaxSock band for this item level.
fn socketCap(t: *const tables.Tables, code: []const u8, item_level: i32) i32 {
    const dims = t.itemDims(code) orelse return 0;
    const area: i32 = @as(i32, dims[0]) * @as(i32, dims[1]);
    const max_sock = @import("sockets.zig").maxSockForItem(t, code, item_level);
    return @min(@min(@as(i32, 6), area), max_sock);
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

/// Roll a set item's own rolled stats (ApplyRuneAndGemStats(4) @0x65fec0): the SetItems row's base
/// props — 2 slots on a classic item, 9 on an expansion one — followed, on expansion items, by the 10
/// `aprop` partial-set slots. Those partial bonuses roll HERE (they are baked into the item) even
/// though they only take effect once enough set pieces are worn; `add func` decides how many apply.
pub fn rollSetStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, set_id: u16, ctx: PropContext) !void {
    if (set_id == 0) return;
    const row = set_id - 1;
    try rollTableProps(gpa, out, seed, t, &t.set_items, row, if (ctx.is_expansion) 9 else 2, ctx);
    if (!ctx.is_expansion) return;
    try rollSetPartialProps(gpa, out, seed, t, row, ctx);
}

/// The `aprop{N}{a,b}` pairs — five worn-piece tiers, two properties each, in table order.
fn rollSetPartialProps(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, row: usize, ctx: PropContext) !void {
    const st = &t.set_items;
    if (row >= st.rowCount()) return;
    var cbuf: [12]u8 = undefined;
    var pbuf: [12]u8 = undefined;
    var lobuf: [12]u8 = undefined;
    var hibuf: [12]u8 = undefined;
    var tier: usize = 1;
    while (tier <= 5) : (tier += 1) {
        for ([2]u8{ 'a', 'b' }) |half| {
            const prop = st.str(row, std.fmt.bufPrint(&cbuf, "aprop{d}{c}", .{ tier, half }) catch unreachable);
            if (prop.len == 0) continue;
            const par: i32 = @intCast(st.int(row, std.fmt.bufPrint(&pbuf, "apar{d}{c}", .{ tier, half }) catch unreachable));
            const min: i32 = @intCast(st.int(row, std.fmt.bufPrint(&lobuf, "amin{d}{c}", .{ tier, half }) catch unreachable));
            const max: i32 = @intCast(st.int(row, std.fmt.bufPrint(&hibuf, "amax{d}{c}", .{ tier, half }) catch unreachable));
            try applyProperty(gpa, out, seed, t, prop, par, min, max, ctx);
        }
    }
}

/// RollRunewordMostlikely 0x6600a0 — apply a completed runeword's own properties. Walks the Runes.txt
/// row's seven `T1Code{N}` slots (with T1Param/T1Min/T1Max) and STOPS at the first empty one, rolling
/// every value off the item's own seed. `runeword_id` is the 1-based row from affix.detectRuneword.
/// Socket count, rune order and the item-type gate are validated upstream by the detection pass.
pub fn rollRunewordStats(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(RolledStat), seed: *rng.Seed, t: *const tables.Tables, runeword_id: u16, ctx: PropContext) !void {
    if (runeword_id == 0) return;
    const rt = &t.runes;
    const row = runeword_id - 1;
    if (row >= rt.rowCount()) return;
    var cbuf: [12]u8 = undefined;
    var pbuf: [12]u8 = undefined;
    var lobuf: [12]u8 = undefined;
    var hibuf: [12]u8 = undefined;
    var n: usize = 1;
    while (n <= 7) : (n += 1) {
        const code = rt.str(row, std.fmt.bufPrint(&cbuf, "T1Code{d}", .{n}) catch unreachable);
        if (code.len == 0) break;
        const par: i32 = @intCast(rt.int(row, std.fmt.bufPrint(&pbuf, "T1Param{d}", .{n}) catch unreachable));
        const min: i32 = @intCast(rt.int(row, std.fmt.bufPrint(&lobuf, "T1Min{d}", .{n}) catch unreachable));
        const max: i32 = @intCast(rt.int(row, std.fmt.bufPrint(&hibuf, "T1Max{d}", .{n}) catch unreachable));
        try applyProperty(gpa, out, seed, t, code, par, min, max, ctx);
    }
}

/// Gems.txt — the stats a gem or rune contributes once socketed, chosen by what it sits in. Each of the
/// three column families carries three mod slots; the walk stops at the first empty one.
pub const SocketTarget = enum { weapon, helm, shield };

pub fn rollSocketFillerStats(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RolledStat),
    seed: *rng.Seed,
    t: *const tables.Tables,
    filler_code: []const u8,
    target: SocketTarget,
    ctx: PropContext,
) !void {
    const gt = &t.gems;
    const row = gt.findByStr("code", filler_code) orelse return;
    const prefix = switch (target) {
        .weapon => "weapon",
        .helm => "helm",
        .shield => "shield",
    };
    var cbuf: [24]u8 = undefined;
    var pbuf: [24]u8 = undefined;
    var lobuf: [24]u8 = undefined;
    var hibuf: [24]u8 = undefined;
    var n: usize = 1;
    while (n <= 3) : (n += 1) {
        const code = gt.str(row, std.fmt.bufPrint(&cbuf, "{s}Mod{d}Code", .{ prefix, n }) catch unreachable);
        if (code.len == 0) break;
        const par: i32 = @intCast(gt.int(row, std.fmt.bufPrint(&pbuf, "{s}Mod{d}Param", .{ prefix, n }) catch unreachable));
        const min: i32 = @intCast(gt.int(row, std.fmt.bufPrint(&lobuf, "{s}Mod{d}Min", .{ prefix, n }) catch unreachable));
        const max: i32 = @intCast(gt.int(row, std.fmt.bufPrint(&hibuf, "{s}Mod{d}Max", .{ prefix, n }) catch unreachable));
        try applyProperty(gpa, out, seed, t, code, par, min, max, ctx);
    }
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
    // The automagic affix is independent of quality — it rides along on nearly every tier.
    try rollAffixStats(gpa, out, seed, t, &t.magic_prefix, d.auto_prefix_id, ctx);
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

test "runeword props: every complete runeword rolls stats, deterministically" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var a: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer b.deinit(testing.allocator);

    var complete: u32 = 0;
    var with_stats: u32 = 0;
    for (0..t.runes.rowCount()) |row| {
        if (t.runes.int(row, "complete") == 0) continue;
        complete += 1;
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        var s1 = rng.Seed.init(0xBEEF, 0x29a);
        var s2 = rng.Seed.init(0xBEEF, 0x29a);
        const ctx = PropContext{ .code = "7ls", .item_level = 85 };
        try rollRunewordStats(testing.allocator, &a, &s1, &t, @intCast(row + 1), ctx);
        try rollRunewordStats(testing.allocator, &b, &s2, &t, @intCast(row + 1), ctx);
        try testing.expectEqual(a.items.len, b.items.len);
        for (a.items, b.items) |x, y| {
            try testing.expectEqual(x.stat, y.stat);
            try testing.expectEqual(x.layer, y.layer);
            try testing.expectEqual(x.value, y.value);
        }
        if (a.items.len > 0) with_stats += 1;
    }
    try testing.expect(complete > 20);
    try testing.expectEqual(complete, with_stats); // no runeword comes back empty
}

test "gem socket fillers give different stats per socket target" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var w: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer w.deinit(testing.allocator);
    var h: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer h.deinit(testing.allocator);

    // A perfect ruby: weapon gets fire damage, a helm gets life.
    var s1 = rng.Seed.init(3, 0x29a);
    var s2 = rng.Seed.init(3, 0x29a);
    try rollSocketFillerStats(testing.allocator, &w, &s1, &t, "gpr", .weapon, .{ .code = "7ls" });
    try rollSocketFillerStats(testing.allocator, &h, &s2, &t, "gpr", .helm, .{ .code = "cap" });
    try testing.expect(w.items.len > 0);
    try testing.expect(h.items.len > 0);
    try testing.expect(w.items[0].stat != h.items[0].stat);
}

test "charged-skill properties derive their level from the item level" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var lo: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer lo.deinit(testing.allocator);
    var hi: std.ArrayListUnmanaged(RolledStat) = .empty;
    defer hi.deinit(testing.allocator);

    // "charged" (func 19) with no explicit level: a level-1 item and a level-85 item differ.
    var s1 = rng.Seed.init(0x11, 0x29a);
    var s2 = rng.Seed.init(0x11, 0x29a);
    try applyProperty(testing.allocator, &lo, &s1, &t, "charged", 54, -10, 0, .{ .code = "7ls", .item_level = 1 });
    try applyProperty(testing.allocator, &hi, &s2, &t, "charged", 54, -10, 0, .{ .code = "7ls", .item_level = 85 });
    try testing.expect(lo.items.len == 1 and hi.items.len == 1);
    // Skill id lives in the high bits of the layer, the derived level in the low 6.
    try testing.expectEqual(@as(i32, 54), @divTrunc(lo.items[0].layer, 64));
    try testing.expectEqual(@as(i32, 54), @divTrunc(hi.items[0].layer, 64));
    try testing.expect(@mod(hi.items[0].layer, 64) > @mod(lo.items[0].layer, 64));
    // The value packs current | max<<8, and current never exceeds max.
    try testing.expect(@mod(hi.items[0].value, 256) <= @divTrunc(hi.items[0].value, 256));
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
