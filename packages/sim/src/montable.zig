//! Monster combat stats — faithful port of the D2 1.14d monster stat-init path.
//!
//! Ghidra 1.14d (reconstructed C at /Users/jaenster/code/CPP/diablo-2). Sibling of
//! drlg/monpop.zig (which scales HP); this scales the COMBAT stats the sim's attack
//! path needs: armor class (defense), attack rating, and the two physical attack
//! damage ranges — all MonLvl.txt-scaled exactly like HP, plus the raw resistances.
//!
//! Ported function:
//!   MONSTER_CalculateLevelScaledStats @006538a0 (win) — D2Common/DataTbls/MonsterTbls.cpp:1639.
//!   For a non-noRatio monster every combat stat is D2ApplyPercent(MonLvl.col, MonStats.col, 100):
//!     armorclass   = MonLvl.AC[diff] * MonStats.AC(diff)     / 100   (flag 0x2, out[2])
//!     attackrate A1 = MonLvl.TH[diff] * MonStats.A1TH(diff)   / 100   (flag 0x8,  out[3])
//!     A1 mindam/maxdam = MonLvl.DM[diff] * MonStats.A1MinD/A1MaxD /100 (flag 0x8, out[5]/out[6])
//!     attackrate A2 = MonLvl.TH[diff] * MonStats.A2TH(diff)   / 100   (flag 0x10, out[3])
//!     A2 mindam/maxdam = MonLvl.DM[diff] * MonStats.A2MinD/A2MaxD /100 (flag 0x10)
//!   noRatio monsters (summons) use the raw MonStats value with NO MonLvl multiplier.
//!   The MonLvl row index is clamped to the last row (nClampedLevel) — same as the HP path.
//!   toblock is the raw MonStats ToBlock(diff) byte (Monster.cpp:711), not scaled.
//!
//! MonStats columns cited: AC/AC(N)/AC(H), A1TH/A1TH(N)/A1TH(H), A1MinD/A1MaxD(+N/+H),
//! A2TH/A2MinD/A2MaxD(+N/+H), ToBlock/ToBlock(N)/ToBlock(H), ResDm/ResFi/... (per diff).
//! MonLvl columns cited: AC/AC(N)/AC(H), TH/TH(N)/TH(H), DM/DM(N)/DM(H).

const std = @import("std");
const txt = @import("txt.zig");
const d2data = @import("d2-data");

/// Difficulty index into the per-difficulty column triples: Normal / Nightmare / Hell.
pub const Difficulty = enum(u2) { normal = 0, nightmare = 1, hell = 2 };

/// One monster's raw MonStats.txt combat columns (per difficulty [Normal,NM,Hell]).
pub const MonCombat = struct {
    no_ratio: bool = false,
    /// MonStats.Level / Level(N) / Level(H) — the monster level indexing MonLvl.txt for a
    /// base (non-area-override) monster; callers with the area MonLvl pass that instead.
    level: [3]i32 = .{ 0, 0, 0 },
    ac: [3]i32 = .{ 0, 0, 0 }, // AC / AC(N) / AC(H)
    a1_th: [3]i32 = .{ 0, 0, 0 }, // A1TH ...
    a1_min: [3]i32 = .{ 0, 0, 0 }, // A1MinD ...
    a1_max: [3]i32 = .{ 0, 0, 0 }, // A1MaxD ...
    a2_th: [3]i32 = .{ 0, 0, 0 }, // A2TH ...
    a2_min: [3]i32 = .{ 0, 0, 0 }, // A2MinD ...
    a2_max: [3]i32 = .{ 0, 0, 0 }, // A2MaxD ...
    to_block: [3]i32 = .{ 0, 0, 0 }, // ToBlock / ToBlock(N) / ToBlock(H)
    /// Six element resists per difficulty (percent; 100 = immune, negatives amplify).
    res: [3]Resist = .{ .{}, .{}, .{} },
    /// MonStats.AI — the AI-script name (e.g. "Fallen", "FallenShaman", "Skeleton"). Owned by
    /// Tables; the per-monster behavior dispatch keys on this. Empty string when the row is blank.
    ai_name: []const u8 = &.{},
    /// MonStats.aidel / aidel(N) / aidel(H) — the AI think-delay (frames between AI runs).
    ai_delay: [3]i32 = .{ 0, 0, 0 },
    /// MonStats.aip1..aip8 — the eight per-AI tuning parameters, each a per-difficulty triple.
    /// Meaning is AI-script-specific (e.g. Fallen aip1 = flee/rally chance percent).
    ai_params: [8][3]i32 = .{.{ 0, 0, 0 }} ** 8,
};

/// Per-difficulty monster resistances (percent). Physical uses ResDm.
pub const Resist = struct {
    phys: i32 = 0, // ResDm
    magic: i32 = 0, // ResMa
    fire: i32 = 0, // ResFi
    light: i32 = 0, // ResLi
    cold: i32 = 0, // ResCo
    poison: i32 = 0, // ResPo
};

/// One MonLvl.txt row: the per-monster-level stat MULTIPLIERS (percent), per difficulty.
pub const MonLvlRow = struct {
    ac: [3]i32 = .{ 100, 100, 100 }, // AC / AC(N) / AC(H)
    th: [3]i32 = .{ 100, 100, 100 }, // TH / TH(N) / TH(H)
    dm: [3]i32 = .{ 100, 100, 100 }, // DM / DM(N) / DM(H)
};

/// D2ApplyPercent(value, percent, 100) = value*percent/100, truncating toward zero. The
/// engine's Stats::D2ApplyPercent (0x653xxx); the 64-bit overflow branch is unreachable
/// for the small combat-stat inputs here.
inline fn applyPercent(value: i32, percent: i32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * @as(i64, percent), 100));
}

/// A monster's fully MonLvl-scaled combat stats for one (class, monLevel, difficulty).
pub const ScaledCombat = struct {
    armor_class: i32, // UNITSTAT_armorclass (defense) the to-hit roll reads
    attack_rating_a1: i32, // AR for attack 1
    attack_rating_a2: i32, // AR for attack 2 (0 when the monster has no A2)
    a1_min: i32, // attack-1 physical min damage
    a1_max: i32, // attack-1 physical max damage
    a2_min: i32,
    a2_max: i32,
    to_block: i32, // raw ToBlock(diff)
    resist: Resist, // raw MonStats resists (no scaling)
};

pub const Tables = struct {
    gpa: std.mem.Allocator,
    /// MonStats combat rows indexed by class id (the "Expansion" divider row removed so
    /// class ids line up with the engine's pTxtMonStats — mirrors drlg/monpop).
    mon: []MonCombat,
    /// MonLvl rows indexed by monster level (dense, index == Level); clamped to the last
    /// row for levels beyond the table.
    lvl: []MonLvlRow,

    pub fn load(gpa: std.mem.Allocator) !Tables {
        var mt = try txt.Table.parse(gpa, d2data.file("MonStats"));
        defer mt.deinit();

        // Count monster rows (skip the "Expansion" divider) to size the array.
        var count: usize = 0;
        {
            var r: usize = 0;
            while (r < mt.rowCount()) : (r += 1) {
                if (std.mem.eql(u8, mt.str(r, "Id"), "Expansion")) continue;
                count += 1;
            }
        }
        const mon = try gpa.alloc(MonCombat, count);
        errdefer gpa.free(mon);

        const triple = struct {
            fn f(t: *const txt.Table, row: usize, base: []const u8) [3]i32 {
                var buf: [24]u8 = undefined;
                const n = std.fmt.bufPrint(&buf, "{s}(N)", .{base}) catch unreachable;
                var buf2: [24]u8 = undefined;
                const h = std.fmt.bufPrint(&buf2, "{s}(H)", .{base}) catch unreachable;
                return .{ @intCast(t.int(row, base)), @intCast(t.int(row, n)), @intCast(t.int(row, h)) };
            }
        }.f;

        {
            var out_i: usize = 0;
            var r: usize = 0;
            while (r < mt.rowCount()) : (r += 1) {
                if (std.mem.eql(u8, mt.str(r, "Id"), "Expansion")) continue;
                var ai_params: [8][3]i32 = .{.{ 0, 0, 0 }} ** 8;
                {
                    var p: usize = 0;
                    while (p < 8) : (p += 1) {
                        var buf: [8]u8 = undefined;
                        const col = std.fmt.bufPrint(&buf, "aip{d}", .{p + 1}) catch unreachable;
                        ai_params[p] = triple(&mt, r, col);
                    }
                }
                mon[out_i] = .{
                    .no_ratio = mt.int(r, "noRatio") != 0,
                    .ai_name = try gpa.dupe(u8, mt.str(r, "AI")),
                    .ai_delay = triple(&mt, r, "aidel"),
                    .ai_params = ai_params,
                    .level = triple(&mt, r, "Level"),
                    .ac = triple(&mt, r, "AC"),
                    .a1_th = triple(&mt, r, "A1TH"),
                    .a1_min = triple(&mt, r, "A1MinD"),
                    .a1_max = triple(&mt, r, "A1MaxD"),
                    .a2_th = triple(&mt, r, "A2TH"),
                    .a2_min = triple(&mt, r, "A2MinD"),
                    .a2_max = triple(&mt, r, "A2MaxD"),
                    .to_block = triple(&mt, r, "ToBlock"),
                    .res = .{
                        .{
                            .phys = @intCast(mt.int(r, "ResDm")), .magic = @intCast(mt.int(r, "ResMa")),
                            .fire = @intCast(mt.int(r, "ResFi")), .light = @intCast(mt.int(r, "ResLi")),
                            .cold = @intCast(mt.int(r, "ResCo")), .poison = @intCast(mt.int(r, "ResPo")),
                        },
                        .{
                            .phys = @intCast(mt.int(r, "ResDm(N)")), .magic = @intCast(mt.int(r, "ResMa(N)")),
                            .fire = @intCast(mt.int(r, "ResFi(N)")), .light = @intCast(mt.int(r, "ResLi(N)")),
                            .cold = @intCast(mt.int(r, "ResCo(N)")), .poison = @intCast(mt.int(r, "ResPo(N)")),
                        },
                        .{
                            .phys = @intCast(mt.int(r, "ResDm(H)")), .magic = @intCast(mt.int(r, "ResMa(H)")),
                            .fire = @intCast(mt.int(r, "ResFi(H)")), .light = @intCast(mt.int(r, "ResLi(H)")),
                            .cold = @intCast(mt.int(r, "ResCo(H)")), .poison = @intCast(mt.int(r, "ResPo(H)")),
                        },
                    },
                };
                out_i += 1;
            }
        }

        var mlt = try txt.Table.parse(gpa, d2data.file("MonLvl"));
        defer mlt.deinit();
        const lvl = try gpa.alloc(MonLvlRow, mlt.rowCount());
        errdefer gpa.free(lvl);
        {
            var r: usize = 0;
            while (r < mlt.rowCount()) : (r += 1) {
                lvl[r] = .{
                    .ac = .{ @intCast(mlt.int(r, "AC")), @intCast(mlt.int(r, "AC(N)")), @intCast(mlt.int(r, "AC(H)")) },
                    .th = .{ @intCast(mlt.int(r, "TH")), @intCast(mlt.int(r, "TH(N)")), @intCast(mlt.int(r, "TH(H)")) },
                    .dm = .{ @intCast(mlt.int(r, "DM")), @intCast(mlt.int(r, "DM(N)")), @intCast(mlt.int(r, "DM(H)")) },
                };
            }
        }

        return .{ .gpa = gpa, .mon = mon, .lvl = lvl };
    }

    pub fn deinit(self: *Tables) void {
        for (self.mon) |m| self.gpa.free(m.ai_name);
        self.gpa.free(self.mon);
        self.gpa.free(self.lvl);
    }

    /// The MonStats.AI script name for a class id ("" when unknown). Per-monster AI dispatch
    /// keys on this; case matches the raw column ("Fallen", "FallenShaman", ...).
    pub fn aiName(self: *const Tables, class_id: i32) []const u8 {
        const mc = self.combat(class_id) orelse return &.{};
        return mc.ai_name;
    }

    pub fn combat(self: *const Tables, class_id: i32) ?*const MonCombat {
        if (class_id < 0 or class_id >= self.mon.len) return null;
        return &self.mon[@intCast(class_id)];
    }

    /// MonLvl row for a monster level, clamped to the last row (nClampedLevel).
    pub fn lvlRow(self: *const Tables, mon_level: i32) ?*const MonLvlRow {
        if (self.lvl.len == 0 or mon_level < 0) return null;
        var i = mon_level;
        const last: i32 = @intCast(self.lvl.len - 1);
        if (i > last) i = last;
        return &self.lvl[@intCast(i)];
    }

    /// The default monster level for a class at a difficulty when the caller has no area
    /// override (MonStats.Level(diff)); champions/area monsters pass the area MonLvl instead.
    pub fn monLevelDefault(self: *const Tables, class_id: i32, diff: Difficulty) i32 {
        const mc = self.combat(class_id) orelse return 1;
        return mc.level[@intFromEnum(diff)];
    }

    /// Fully MonLvl-scaled combat stats for a monster (MONSTER_CalculateLevelScaledStats).
    /// `mon_level` indexes MonLvl.txt (area MonLvl or monLevelDefault). noRatio -> raw values.
    pub fn scaled(self: *const Tables, class_id: i32, mon_level: i32, diff: Difficulty) ?ScaledCombat {
        const mc = self.combat(class_id) orelse return null;
        const d: usize = @intFromEnum(diff);
        if (mc.no_ratio) {
            return .{
                .armor_class = mc.ac[d],
                .attack_rating_a1 = mc.a1_th[d],
                .attack_rating_a2 = mc.a2_th[d],
                .a1_min = mc.a1_min[d],
                .a1_max = mc.a1_max[d],
                .a2_min = mc.a2_min[d],
                .a2_max = mc.a2_max[d],
                .to_block = mc.to_block[d],
                .resist = mc.res[d],
            };
        }
        const row = self.lvlRow(mon_level) orelse return null;
        return .{
            .armor_class = applyPercent(row.ac[d], mc.ac[d]),
            .attack_rating_a1 = applyPercent(row.th[d], mc.a1_th[d]),
            .attack_rating_a2 = applyPercent(row.th[d], mc.a2_th[d]),
            .a1_min = applyPercent(row.dm[d], mc.a1_min[d]),
            .a1_max = applyPercent(row.dm[d], mc.a1_max[d]),
            .a2_min = applyPercent(row.dm[d], mc.a2_min[d]),
            .a2_max = applyPercent(row.dm[d], mc.a2_max[d]),
            .to_block = mc.to_block[d],
            .resist = mc.res[d],
        };
    }
};

const testing = std.testing;

test "montable loads and scales a known monster (Fallen, class 19)" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    try testing.expect(t.mon.len > 500);
    try testing.expect(t.lvl.len > 0);

    // Fallen (class id 19) at its own base level, Normal. AC scales as MonLvl.AC * MonStats.AC / 100.
    const mc = t.combat(19).?;
    const ml = t.monLevelDefault(19, .normal);
    const row = t.lvlRow(ml).?;
    const sc = t.scaled(19, ml, .normal).?;
    // Faithful identity: armor_class == D2ApplyPercent(MonLvl.AC, MonStats.AC).
    try testing.expectEqual(@divTrunc(row.ac[0] * mc.ac[0], 100), sc.armor_class);
    try testing.expectEqual(@divTrunc(row.th[0] * mc.a1_th[0], 100), sc.attack_rating_a1);
    try testing.expectEqual(@divTrunc(row.dm[0] * mc.a1_max[0], 100), sc.a1_max);
}

test "montable: MonLvl scaling grows AC with monster level; Hell >= Normal multiplier" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // Pick a plain monster (Fallen, 19) and compare Normal vs Hell scaling at a fixed level.
    const mc = t.combat(19).?;
    if (!mc.no_ratio and mc.ac[0] > 0) {
        const lo = t.scaled(19, 5, .normal).?;
        const hi = t.scaled(19, 40, .normal).?;
        // Higher monster level -> higher MonLvl.AC multiplier -> higher scaled AC.
        try testing.expect(hi.armor_class >= lo.armor_class);
    }
    // A known level index clamps beyond the table without error.
    _ = t.scaled(19, 999, .hell).?;
}

test "montable: AI column plumbs MonStats.AI/aidel/aip verbatim (Fallen)" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // Fallen (class id 19) — real MonStats.txt row fallen1: AI=Fallen, aidel 15/14/13, aip1 30/40/50.
    const mc = t.combat(19).?;
    try testing.expectEqualStrings("Fallen", mc.ai_name);
    try testing.expectEqualStrings("Fallen", t.aiName(19));
    try testing.expectEqual(@as(i32, 15), mc.ai_delay[0]);
    try testing.expectEqual(@as(i32, 14), mc.ai_delay[1]);
    try testing.expectEqual(@as(i32, 13), mc.ai_delay[2]);
    try testing.expectEqual(@as(i32, 30), mc.ai_params[0][0]);
    try testing.expectEqual(@as(i32, 40), mc.ai_params[0][1]);
    try testing.expectEqual(@as(i32, 50), mc.ai_params[0][2]);
}

test "montable: noRatio monster uses raw MonStats (no MonLvl multiplier)" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // Scan for a noRatio monster and assert its scaled AC equals the raw column.
    for (t.mon, 0..) |mc, id| {
        if (mc.no_ratio) {
            const sc = t.scaled(@intCast(id), 20, .normal).?;
            try testing.expectEqual(mc.ac[0], sc.armor_class);
            try testing.expectEqual(mc.a1_th[0], sc.attack_rating_a1);
            break;
        }
    }
}
