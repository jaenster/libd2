//! Skill dispatch — faithful port of the D2 1.14d server "do skill" path.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe. Modelled entry points:
//!   SKILL_ExecuteClientDoFunc         the server acting on a client skill request
//!   (Skills.txt srvdofunc dispatch)   the server "do function" switch per skill
//!
//! A skill row (Skills.txt) selects behaviour via a srvdofunc-style switch:
//!   * srvdofunc == 1 (DOFUNC_ATTACK)  -> a melee/direct attack resolved through the
//!                                        combat core (DAMAGE_* path).
//!   * srvmissile set (references a     -> a ranged cast: spawn the named missile
//!     Missiles.txt "Missile" name)       aimed at the target (see missile.zig).
//! Everything else is UNKNOWN this pass. This is the FRAMEWORK plus a vertical slice
//! (Attack + a bolt); the ~300-skill catalog, aura/passive/state srvdofuncs, mana
//! enforcement, cooldowns, LoS and multi-missile fan patterns are explicit TODOs.
//!
//! ELEMENTAL DAMAGE: `resolveElemental` / `resolveElementalVsUnit` resolve a sorceress
//! cold/fire/light spell to real Skills.txt element damage (staged per-level progression +
//! synergies + mastery, see spell.zig) and apply the target's resist (Cold Mastery as a
//! resist-pierce). The standalone supplies the monster resist through the `target_resist` seam,
//! so this lib stays independent of drlg.

const std = @import("std");
const rng = @import("rng.zig");
const unit = @import("unit.zig");
const combat = @import("combat.zig");
const missile = @import("missile.zig");
const spell = @import("spell.zig");
const calc = @import("calc.zig");
const monskill = @import("monskill.zig");
const d2data = @import("d2-data");

const Seed = rng.Seed;
const Unit = unit.Unit;

/// srvdofunc values we act on (Skills.txt). Names follow the engine's DOFUNC_* space;
/// only the slice's value is enumerated, the rest fall through to `unknown`.
pub const DoFunc = enum(i32) {
    none = 0,
    attack = 1, // DOFUNC_ATTACK — normal melee/direct attack
    teleport = 27, // DOFUNC_TELEPORT — instant reposition to a passable target cell (Teleport Id 54)
    _,
};

/// One Skills.txt row, reduced to the dispatch-relevant fields plus the elemental-damage
/// columns. Column names are the REAL 1.14d Skills.txt headers (packages/data/src/excel):
///   dispatch:  Id, srvdofunc, srvmissile, mana, manashift
///   element:   EType, EMin, EMax, EMinLev1..5, EMaxLev1..5, ELen, HitShift
pub const SkillData = struct {
    id: u16 = 0,
    srvdofunc: i32 = 0,
    /// srvmissile — the Missiles.txt "Missile" name spawned server-side ("" = none).
    srvmissile: []const u8 = "",
    mana: i32 = 0,
    manashift: i32 = 0,
    /// lvlmana — mana cost added per skill level above 1 (can be negative: Teleport gets cheaper).
    lvlmana: i32 = 0,
    /// delay — the skill's reuse cooldown in SERVER frames (25/s): Frozen Orb 25, Meteor 30,
    /// Blizzard 45; 0 = no cooldown. The host gates recasting on it.
    delay: i32 = 0,
    /// The skill's Skills.txt elemental-damage row (EType/EMin.../HitShift), for the
    /// staged per-level progression in spell.zig. `.etype == .none` when the skill has no
    /// elemental damage columns filled in.
    dmg: spell.ElementalDamage = .{},
    /// ELen — the effect duration column (cold-length etc.); carried for completeness.
    e_len: i32 = 0,
    /// Structural classification columns (Skills.txt): `aura`=1, a non-empty `passivestate`, and a
    /// non-empty `summon` mark aura / passive / summon skills respectively.
    is_aura: bool = false,
    is_passive: bool = false,
    is_summon: bool = false,
    /// mana at level 1 minus manashift/lvlmana scaling reduced to the base per-cast cost. For
    /// Teleport this is the flat `mana` column (24); D2's per-level mana scaling barely moves it.
    /// Exposed so the host can gate a cast on the caster's mana pool.
    /// (mana/manashift already carried above.)

    /// Classify a skill into a behaviour CATEGORY from its Skills.txt columns (faithful structural
    /// classification — covers every skill, even ones whose exact srvdofunc isn't individually
    /// modelled yet). Priority mirrors how the engine gates behaviour: aura > passive > summon >
    /// missile > teleport > melee-attack > direct-elemental > other.
    pub fn kind(self: SkillData) Kind {
        if (self.is_aura) return .aura;
        if (self.is_passive) return .passive;
        if (self.is_summon) return .summon;
        if (self.srvdofunc == @intFromEnum(DoFunc.teleport)) return .teleport;
        if (self.srvmissile.len != 0) return .missile;
        if (self.srvdofunc == @intFromEnum(DoFunc.attack)) return .melee;
        if (self.dmg.etype != .none) return .direct; // direct elemental (Nova / Static Field / ...)
        return .other;
    }

    /// The flat base mana column (whole). Prefer `manaCostAt` for the real per-level cost.
    pub fn manaCost(self: SkillData) i32 {
        return self.mana;
    }

    /// FAITHFUL per-level mana cost (SKILLS_CalculateManaCost @0x6c... 1.14d):
    ///   ((mana + lvlmana*(level-1)) << manashift) >> 8
    /// e.g. Fire Bolt ~2 (flat), Teleport 24 at slvl1 dropping to 15 at slvl10 (lvlmana -1),
    /// Blizzard 23 -> 32, Frozen Orb 25 -> 29. manashift is the fixed-point scale.
    pub fn manaCostAt(self: SkillData, level: i32) i32 {
        const base: i64 = self.mana + self.lvlmana * (@max(1, level) - 1);
        const shift: u6 = @intCast(self.manashift & 0x1f);
        return @intCast((base * (@as(i64, 1) << shift)) >> 8);
    }
};

/// Behaviour category a skill classifies into (see SkillData.kind). `direct` = a direct elemental
/// hit with no missile (Nova/Static Field); `other` = an unmodelled/utility do-function.
pub const Kind = enum { melee, missile, teleport, direct, aura, passive, summon, other, unknown };

/// What a summon skill spawns: the MonStats monster name (borrows the Skills table) + the max pet
/// count at the queried level. `.monster == ""` means the skill is not a summon.
pub const SummonInfo = struct {
    monster: []const u8 = "",
    count: i32 = 0,
};

/// A stat a skill grants (aura or passive): the ItemStatCost stat NAME (borrows the Skills table) +
/// its value at a given skill level. `.stat == ""` means the skill grants nothing of that kind.
pub const AuraStat = struct {
    stat: []const u8 = "",
    value: i32 = 0,
};

/// Loaded Skills.txt (the REAL 1.14d table from d2-data — ~256 columns, 357 rows),
/// indexed by numeric Id. Columns are addressed by NAME, never by index.
pub const Skills = struct {
    table: d2data.Table,

    pub fn load(gpa: std.mem.Allocator) !Skills {
        return .{ .table = try d2data.open(gpa, "Skills") };
    }
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Skills {
        return .{ .table = try d2data.tsv.parse(gpa, src) };
    }
    pub fn deinit(self: *Skills) void {
        self.table.deinit();
    }

    /// Look up a skill by numeric Id. The returned srvmissile slice borrows the
    /// table's arena (valid for the lifetime of this Skills).
    pub fn byId(self: *const Skills, id: u16) ?SkillData {
        const row = self.table.findByInt("Id", id) orelse return null;
        const t = &self.table;
        return .{
            .id = id,
            .srvdofunc = t.getInt(i32, row, "srvdofunc") orelse 0,
            .srvmissile = t.get(row, "srvmissile"),
            .mana = t.getInt(i32, row, "mana") orelse 0,
            .manashift = t.getInt(i32, row, "manashift") orelse 0,
            .lvlmana = t.getInt(i32, row, "lvlmana") orelse 0,
            .delay = t.getInt(i32, row, "delay") orelse 0,
            .dmg = .{
                .etype = spell.Element.parse(t.get(row, "EType")),
                .e_min = t.getInt(i32, row, "EMin") orelse 0,
                .e_max = t.getInt(i32, row, "EMax") orelse 0,
                .e_min_lev = .{
                    t.getInt(i32, row, "EMinLev1") orelse 0,
                    t.getInt(i32, row, "EMinLev2") orelse 0,
                    t.getInt(i32, row, "EMinLev3") orelse 0,
                    t.getInt(i32, row, "EMinLev4") orelse 0,
                    t.getInt(i32, row, "EMinLev5") orelse 0,
                },
                .e_max_lev = .{
                    t.getInt(i32, row, "EMaxLev1") orelse 0,
                    t.getInt(i32, row, "EMaxLev2") orelse 0,
                    t.getInt(i32, row, "EMaxLev3") orelse 0,
                    t.getInt(i32, row, "EMaxLev4") orelse 0,
                    t.getInt(i32, row, "EMaxLev5") orelse 0,
                },
                .hit_shift = t.getInt(i32, row, "HitShift") orelse 0,
            },
            .e_len = t.getInt(i32, row, "ELen") orelse 0,
            .is_aura = (t.getInt(i32, row, "aura") orelse 0) != 0,
            .is_passive = t.get(row, "passivestate").len != 0,
            .is_summon = t.get(row, "summon").len != 0,
        };
    }

    /// The Skills.txt row index for a numeric Id (the `skill()` name resolution + synergy lookups
    /// go through this).
    fn rowById(self: *const Skills, id: u16) ?usize {
        return self.table.findByInt("Id", id);
    }

    /// Numeric Id of the skill whose `skill` column equals `name` — the exact string a Skills.txt
    /// calc uses in `skill('Name'.blvl)` (e.g. "Frost Nova"). null if no such skill.
    pub fn idByName(self: *const Skills, name: []const u8) ?u16 {
        const t = &self.table;
        for (0..t.rowCount()) |r| {
            if (std.mem.eql(u8, t.get(r, "skill"), name)) {
                return @intCast(t.getInt(i32, r, "Id") orelse continue);
            }
        }
        return null;
    }

    /// A skill's ParamN column (1-based, matching the `parN` refs inside Skills.txt calc strings).
    pub fn param(self: *const Skills, skill_id: u16, n: u8) i32 {
        const row = self.rowById(skill_id) orelse return 0;
        var buf: [16]u8 = undefined;
        const col = std.fmt.bufPrint(&buf, "Param{d}", .{n}) catch return 0;
        return self.table.getInt(i32, row, col) orelse 0;
    }

    /// The damage-synergy skills + per-level percent for `skill_id`, parsed from its Skills.txt
    /// `EDmgSymPerCalc` column — the ONLY source (nothing about synergies is hardcoded). The calc
    /// reads e.g. `(skill('Frost Nova'.blvl)+skill('Ice Blast'.blvl)+...)*par8`; we pull every
    /// `skill('Name'.blvl)` reference (resolved to its Id) and the `parN` multiplier (-> ParamN, as
    /// a percent). `.permille` is that percent ×10 so the synergy multiplier stays integer-exact.
    pub const SynergyInfo = struct {
        ids: [spell.MAX_SYNERGIES]u16 = undefined,
        count: usize = 0,
        /// Per-level synergy bonus in permille (‰): ParamN × 10 (e.g. Param8=15 => 150 = 15%/level).
        permille: i32 = 0,
    };

    pub fn synergyInfo(self: *const Skills, skill_id: u16) SynergyInfo {
        const row = self.rowById(skill_id) orelse return .{};
        const expr = self.table.get(row, "EDmgSymPerCalc");
        if (expr.len == 0) return .{};

        var info: SynergyInfo = .{};
        // Pull each skill('Name'...) reference and resolve it to a skill Id.
        var rest = expr;
        while (std.mem.indexOf(u8, rest, "skill('")) |at| {
            const after = rest[at + "skill('".len ..];
            const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
            const name = after[0..end];
            if (self.idByName(name)) |sid| {
                if (info.count < info.ids.len) {
                    info.ids[info.count] = sid;
                    info.count += 1;
                }
            }
            rest = after[end + 1 ..];
        }
        // The `parN` multiplier (the per-level %): read ParamN off this same row.
        if (std.mem.indexOf(u8, expr, "par")) |pi| {
            const digits = expr[pi + 3 ..];
            var j: usize = 0;
            while (j < digits.len and std.ascii.isDigit(digits[j])) : (j += 1) {}
            if (j > 0) {
                const n = std.fmt.parseInt(u8, digits[0..j], 10) catch 0;
                info.permille = self.param(skill_id, n) * 10;
            }
        }
        return info;
    }

    /// A skill's passive/mastery value at `level`, evaluated FAITHFULLY through the calc VM from its
    /// Skills.txt `passivecalc1` column — e.g. Cold Mastery pierce / Fire Mastery +dmg are `ln12` =
    /// Param1 + level*Param2 (Cold Mastery 20/5 => 25 at slvl1, 45 at slvl5). No formula is hardcoded;
    /// whatever calc the row carries is what runs. `level <= 0` => 0 (skill not learned).
    pub fn masteryValue(self: *const Skills, skill_id: u16, level: i32) i32 {
        if (level <= 0) return 0;
        return self.passiveValue(skill_id, level).value; // masteries ARE passives (passivecalc1)
    }

    /// The stat an aura skill grants to units in range + its value at `level`, table-driven from
    /// Skills.txt: `aurastat1` (the ItemStatCost stat NAME) valued by `aurastatcalc1` via the calc
    /// VM. E.g. Might's damagepercent = ln34 = Param3 + lvl*Param4 => +50% at slvl1. An empty
    /// `aurastat1` (not an aura) => `.stat == ""`, value 0.
    pub fn auraValue(self: *const Skills, skill_id: u16, level: i32) AuraStat {
        const row = self.rowById(skill_id) orelse return .{};
        const stat = self.table.get(row, "aurastat1");
        if (stat.len == 0) return .{};
        return .{ .stat = stat, .value = self.evalCalc(.{}, 0, skill_id, level, "aurastatcalc1") };
    }

    /// The stat a PASSIVE skill grants + its value at `level`, table-driven from Skills.txt
    /// `passivestat1` (the ItemStatCost stat) valued by `passivecalc1` via the calc VM. Covers every
    /// passive across all classes: Warmth (manarecoverybonus = ln12), Critical Strike
    /// (passive_critical_strike = dm12 diminishing), Iron Skin, Natural Resistance, the sorc masteries
    /// (masteryValue is the value-only view of this). Empty passivestat1 => `.stat == ""`.
    pub fn passiveValue(self: *const Skills, skill_id: u16, level: i32) AuraStat {
        const row = self.rowById(skill_id) orelse return .{};
        const stat = self.table.get(row, "passivestat1");
        if (stat.len == 0) return .{};
        return .{ .stat = stat, .value = self.evalCalc(.{}, 0, skill_id, level, "passivecalc1") };
    }

    /// What a SUMMON skill spawns: the MonStats monster name (the `summon` column) + how many the
    /// caster may have at once (the `petmax` column, which is itself a calc — Raise Skeleton's is
    /// `(lvl<4)?lvl:(2+lvl/3)`, evaluated by the VM). Empty `summon` => not a summon. The host does
    /// the actual spawning (it owns unit creation).
    pub fn summonInfo(self: *const Skills, skill_id: u16, level: i32) SummonInfo {
        const row = self.rowById(skill_id) orelse return .{};
        const mon = self.table.get(row, "summon");
        if (mon.len == 0) return .{};
        return .{ .monster = mon, .count = self.evalExpr(self.table.get(row, "petmax"), skill_id, level) };
    }

    /// Evaluate a raw calc EXPRESSION string (not a column name) through the VM — for columns like
    /// `petmax` that carry the calc inline. Empty / error => 0.
    pub fn evalExpr(self: *const Skills, expr: []const u8, skill_id: u16, level: i32) i32 {
        if (expr.len == 0) return 0;
        const ev = calc.Evaluator(CalcCtx){ .ctx = .{ .skills = self, .book = .{}, .char_level = 0 } };
        return ev.eval(expr, skill_id, level) catch 0;
    }

    /// Evaluate one of a skill's calc-string columns (by header name) through the calc VM, resolving
    /// `skill('Name'.code)` synergy refs against `book` (the caster's skill levels) and `ulvl` against
    /// `char_level`. `level` is the bare `lvl` (the casting skill's effective level). Errors => 0.
    pub fn evalCalc(self: *const Skills, book: SkillBook, char_level: i32, skill_id: u16, level: i32, column: []const u8) i32 {
        const row = self.rowById(skill_id) orelse return 0;
        const expr = self.table.get(row, column);
        if (expr.len == 0) return 0;
        const ev = calc.Evaluator(CalcCtx){ .ctx = .{ .skills = self, .book = book, .char_level = char_level } };
        return ev.eval(expr, skill_id, level) catch 0;
    }
};

/// Bridges the calc VM (calc.zig) to the real Skills table + a caster's SkillBook: params come from
/// Skills.txt, skill levels from the book, name resolution from the table. Damage/aura codes
/// (edmn/edmx/...) are not wired yet -> 0 (the parser handles them, the model fills them in later).
pub const CalcCtx = struct {
    skills: *const Skills,
    book: SkillBook,
    char_level: i32 = 0,

    pub fn param(self: CalcCtx, skill_id: u16, n: u8) i32 {
        return self.skills.param(skill_id, @intCast(n));
    }
    pub fn level(self: CalcCtx, skill_id: u16) i32 {
        return self.book.get(skill_id);
    }
    pub fn baseLevel(self: CalcCtx, skill_id: u16) i32 {
        return self.book.get(skill_id);
    }
    pub fn charLevel(self: CalcCtx) i32 {
        return self.char_level;
    }
    pub fn idByName(self: CalcCtx, name: []const u8) ?u16 {
        return self.skills.idByName(name);
    }
    /// Resolve the elemental-damage SkillCalc codes (edmn/edmx/edln + 256th and +mastery variants)
    /// against `skill_id`'s staged element row at `lvl`. Returns null for codes not modelled here
    /// (aura/passive field reads etc.), which the VM treats as 0.
    pub fn keyword(self: CalcCtx, skill_id: u16, lvl: i32, code: []const u8) ?i32 {
        const sd = self.skills.byId(skill_id) orelse return null;
        const d = sd.dmg;
        // Whole-damage min/max (edmn/edmx) and their 1/256 forms (edns/edxs).
        if (std.mem.eql(u8, code, "edmn")) return d.minAt(lvl);
        if (std.mem.eql(u8, code, "edmx")) return d.maxAt(lvl);
        if (std.mem.eql(u8, code, "edns")) return @intCast(d.min256(lvl));
        if (std.mem.eql(u8, code, "edxs")) return @intCast(d.max256(lvl));
        if (std.mem.eql(u8, code, "edln")) return sd.e_len;
        // +mastery variants: fire/lightning masteries ADD +% damage; cold pierces (no +damage), so
        // the "+mastery" forms equal the base for cold. The caster's mastery level comes from `book`.
        const mpct = self.masteryDamagePercent(d.etype);
        if (std.mem.eql(u8, code, "enma")) return applyPct(d.minAt(lvl), mpct);
        if (std.mem.eql(u8, code, "exma")) return applyPct(d.maxAt(lvl), mpct);
        if (std.mem.eql(u8, code, "enms")) return applyPct(@intCast(d.min256(lvl)), mpct);
        if (std.mem.eql(u8, code, "exms")) return applyPct(@intCast(d.max256(lvl)), mpct);
        return null;
    }

    /// The caster's +% element-damage mastery for `element` (fire/lightning only; cold/poison => 0),
    /// evaluated from the matching mastery skill's passivecalc at the book level.
    fn masteryDamagePercent(self: CalcCtx, element: spell.Element) i32 {
        const m = sorcMastery(element) orelse return 0;
        if (m.kind != .damage) return 0;
        const mid = self.skills.idByName(m.name) orelse return 0;
        return self.skills.masteryValue(mid, self.book.get(mid));
    }
};

fn applyPct(base: i32, pct: i32) i32 {
    return @intCast(@divTrunc(@as(i64, base) * (100 + pct), 100));
}

/// How a caster's mastery skill affects an elemental cast: cold masteries PIERCE the target's
/// resist; fire/lightning/poison masteries ADD +% damage. (Skills.txt passive semantics.)
pub const MasteryKind = enum { none, pierce, damage };

/// Assemble a FULLY TABLE-DRIVEN elemental Cast for `skill_id` at `effective_level`:
///   * element damage row  — Skills.txt E* columns (SkillData.dmg)
///   * synergies           — Skills.txt EDmgSymPerCalc (which skills, and the ParamN %/level)
///   * mastery             — the caster's `mastery_id` skill, Param1+Param2*(lvl-1), applied as
///                           pierce (cold) or +%damage (fire/light/poison) per `mastery_kind`
/// Nothing is hardcoded — every number comes from Skills.txt. `ctx` supplies the caster's hard
/// level in a skill via `ctx.skillLevel(skills, id)`; `syn_out` is caller storage the Cast borrows.
pub fn buildElementalCast(
    skills: *const Skills,
    skill_id: u16,
    effective_level: i32,
    ctx: anytype,
    mastery_id: ?u16,
    mastery_kind: MasteryKind,
    syn_out: []spell.Synergy,
) spell.Cast {
    const sd = skills.byId(skill_id) orelse return .{ .dmg = .{}, .skill_level = effective_level };
    const info = skills.synergyInfo(skill_id);
    var n: usize = 0;
    for (info.ids[0..info.count]) |sid| {
        if (n >= syn_out.len) break;
        syn_out[n] = .{ .permille = info.permille, .skill_level = ctx.skillLevel(skills, sid) };
        n += 1;
    }
    var result: spell.Cast = .{ .dmg = sd.dmg, .skill_level = effective_level, .synergies = syn_out[0..n] };
    if (mastery_id) |mid| {
        const value = skills.masteryValue(mid, ctx.skillLevel(skills, mid));
        switch (mastery_kind) {
            .pierce => result.pierce_percent = value,
            .damage => result.mastery_percent = value,
            .none => {},
        }
    }
    return result;
}

/// Upper bound on Skills.txt Ids (1.14d has ~356 skills); the SkillBook indexes by Id.
pub const MAX_SKILLS = 512;

/// A caster's hard-point skill allocation, indexed by Skills.txt Id — the `ctx` a table-driven
/// cast reads synergy + skill levels from. This is the sim's minimal "skill sheet"; the host fills
/// it from a .d2s (or a build), by NAME so no Ids are hardcoded.
pub const SkillBook = struct {
    levels: [MAX_SKILLS]i16 = [_]i16{0} ** MAX_SKILLS,

    pub fn set(self: *SkillBook, id: u16, level: i16) void {
        if (id < MAX_SKILLS) self.levels[id] = level;
    }
    /// Set a skill's level by its Skills.txt name (no-op if the skill isn't in the table).
    pub fn setByName(self: *SkillBook, skills: *const Skills, name: []const u8, level: i16) void {
        if (skills.idByName(name)) |id| self.set(id, level);
    }
    pub fn get(self: SkillBook, id: u16) i32 {
        return if (id < MAX_SKILLS) self.levels[id] else 0;
    }
    /// ctx interface for `buildElementalCast` (the `skills` arg is unused — levels are keyed by Id).
    pub fn skillLevel(self: SkillBook, skills: *const Skills, id: u16) i32 {
        _ = skills;
        return self.get(id);
    }
};

/// The Sorceress element-mastery skill for an element (its Skills.txt name + how it applies): cold
/// masteries PIERCE resist, fire/lightning masteries ADD +% damage. Poison/magic/none => no mastery.
fn sorcMastery(element: spell.Element) ?struct { name: []const u8, kind: MasteryKind } {
    return switch (element) {
        .cold => .{ .name = "Cold Mastery", .kind = .pierce },
        .fire => .{ .name = "Fire Mastery", .kind = .damage },
        .lightning => .{ .name = "Lightning Mastery", .kind = .damage },
        else => null,
    };
}

/// FULLY TABLE-DRIVEN elemental cast for ANY sorceress elemental skill: the element row, the
/// synergies (EDmgSymPerCalc) and the caster's matching mastery are all read from Skills.txt — no
/// per-skill code. `book` supplies the caster's hard-point levels; `effective_level` is the skill's
/// level after +skills; `syn_out` is caller storage the Cast borrows.
pub fn castElemental(skills: *const Skills, book: SkillBook, skill_id: u16, effective_level: i32, syn_out: []spell.Synergy) spell.Cast {
    const sd = skills.byId(skill_id) orelse return .{ .dmg = .{}, .skill_level = effective_level };
    var mastery_id: ?u16 = null;
    var kind: MasteryKind = .none;
    if (sorcMastery(sd.dmg.etype)) |m| {
        mastery_id = skills.idByName(m.name);
        kind = m.kind;
    }
    return buildElementalCast(skills, skill_id, effective_level, book, mastery_id, kind, syn_out);
}

/// Where a cast is aimed. `unit` is the target unit for entity-targeted casts (melee
/// needs it; a missile aims at its position). `x`/`y` is the cast location (used when
/// there is no target unit, e.g. LeftSkillOnLocation).
pub const Target = struct {
    x: i32 = 0,
    y: i32 = 0,
    unit: ?*const Unit = null,
};

/// The result of a cast, for the host to apply against live game state.
pub const Outcome = union(enum) {
    /// Skill not found, no valid target, or an unmodelled srvdofunc — nothing happens.
    none,
    /// A resolved melee attack. Apply `.result.damage` to the target on `.hit`.
    melee: combat.AttackResult,
    /// A spawned missile to add to the game (assign it a guid first).
    missile: missile.Missile,
    /// A resolved direct-elemental hit (Nova/Static/Chain Lightning/...): apply `.applied` to the
    /// target's life. Carries the already-resisted result (see ElementalHit).
    elemental: ElementalHit,
};

/// SKILL_ExecuteClientDoFunc (slice): run skill `skill_id` cast by `caster` at
/// `target`, drawing from `skills`/`missiles`. Pure — it never mutates game state;
/// the host applies the returned Outcome (subtract melee damage / add the missile).
///
/// Mana is NOT enforced this pass (the runtime player has no mana pool yet) — the
/// cost is exposed on SkillData for the host to gate later; see module TODOs.
pub fn execute(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster: *const Unit,
    skill_id: u16,
    target: Target,
    seed: *Seed,
) Outcome {
    const sd = skills.byId(skill_id) orelse return .none;
    switch (sd.kind()) {
        .melee => {
            const t = target.unit orelse return .none;
            if (!t.isAlive()) return .none;
            return .{ .melee = combat.resolveAttack(caster, t, seed, .{}) };
        },
        .missile => {
            const md = missiles.byName(sd.srvmissile) orelse return .none;
            // Damage: explicit Missiles.txt damage if present, else derive the bounds
            // from the caster's physical damage (skill elemental scaling is a TODO).
            var dmin = md.min_damage;
            var dmax = md.max_damage;
            if (dmax <= dmin) {
                const pd = combat.rollPhysicalDamage(caster, seed, .{});
                dmin = pd.min256 >> 8;
                dmax = pd.max256 >> 8;
            }
            // Aim at the target unit's position when entity-targeted, else the location.
            const tx = if (target.unit) |u| u.x else target.x;
            const ty = if (target.unit) |u| u.y else target.y;
            const m = missile.Missile.create(md, caster.unit_id, caster.x, caster.y, tx, ty, dmin, dmax);
            return .{ .missile = m };
        },
        // Teleport is a pure host-side reposition (move the caster to a passable target cell) — it
        // produces no combat/missile Outcome. The host detects `.teleport` via kind() and applies
        // the jump itself (dest-passable + range + mana gate); nothing to resolve here.
        .teleport => return .none,
        // Categories the classifier recognises but whose behaviour isn't resolved here yet:
        // direct-elemental area hits (Nova/Static), auras, passives, summons, and utility do-funcs.
        // They classify correctly (kind()) so the host/AI can branch; resolution is future work.
        .direct, .aura, .passive, .summon, .other, .unknown => return .none,
    }
}

/// Cast skill `skill_id` as an ELEMENTAL missile: spawn the skill's srvmissile aimed at `target`
/// and snapshot `elem_cast` onto it (the caster's build already folded in effective skill level +
/// synergies + mastery pierce). The missile is marked `caster_derived` so stepAll routes its on-hit
/// through the elemental path (missile.applyElementalHitVs) instead of the flat physical roll — the
/// applied damage is resolved per victim at hit time from the carried cast. Pure — the host assigns
/// the returned missile a guid + appends it. Returns `.none` when the skill/srvmissile is unknown.
pub fn cast(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster: *const Unit,
    skill_id: u16,
    target: Target,
    elem_cast: spell.Cast,
) Outcome {
    const sd = skills.byId(skill_id) orelse return .none;
    const md = missiles.byName(sd.srvmissile) orelse return .none;
    const tx = if (target.unit) |u| u.x else target.x;
    const ty = if (target.unit) |u| u.y else target.y;
    var m = missile.Missile.create(md, caster.unit_id, caster.x, caster.y, tx, ty, 0, 0);
    m.caster_derived = true;
    // Seal the cast: copy its borrowed synergy slice inline so the missile can outlive the caller's
    // synergy storage without a dangling pointer (the on-hit resolution runs frames later).
    m.elem_cast = elem_cast.seal();
    return .{ .missile = m };
}

/// Apply an Outcome: the melee arm subtracts its damage from `target`'s life (pure — mutates
/// only that unit); the missile arm is RETURNED for the host to assign a guid + append (the
/// lib never sees a guid allocator or the missile collection). Returns null for `.none` and
/// the applied melee arm.
pub fn applyOutcome(out: Outcome, target: ?*Unit) ?missile.Missile {
    switch (out) {
        .none => return null,
        .melee => |res| {
            if (res.hit) if (target) |t| combat.applyToLife(t, res.damage);
            return null;
        },
        .missile => |m| return m,
        .elemental => |hit| {
            if (target) |t| applyElementalHit(hit, t);
            return null;
        },
    }
}

/// A monster acts: pick the first damaging skill from its `mc` assignments and produce the Outcome —
/// a direct-elemental hit resolved against `target` (Chain Lightning / Nova), or an elemental missile
/// aimed at it (VampireFireball). Returns `.none` when the monster has no castable damaging skill
/// (the host then falls back to a melee attack). The monster's skill levels come from `mc.book`, so
/// its damage scales table-faithfully — the same path players use.
pub fn monsterCast(skills: *const Skills, missiles: *const missile.Missiles, caster: *const Unit, mc: MonsterCaster, target: *const Unit, seed: *Seed) Outcome {
    const id = mc.pickCastable(skills) orelse return .none;
    const sd = skills.byId(id) orelse return .none;
    const level = mc.book.get(id);
    switch (sd.kind()) {
        .direct => return .{ .elemental = castDirectElemental(skills, mc.book, id, level, target, seed) },
        .missile => {
            var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
            const c = castElemental(skills, mc.book, id, level, &syn);
            return cast(skills, missiles, caster, id, .{ .unit = target }, c);
        },
        else => return .none,
    }
}

/// The result of resolving an elemental spell hit against a target.
pub const ElementalHit = struct {
    element: spell.Element,
    /// Rolled base elemental damage (after synergy + mastery, before the target's resist).
    raw: i32,
    /// Damage after the target's resist for this element: raw * (100 - resist) / 100.
    applied: i32,
    /// The resist value used (>=100 means the target was immune -> applied 0).
    resist: i32,
};

/// Resolve one elemental spell hit: roll the cast's (synergy+mastery-scaled) damage, then apply
/// the target's resist for the cast's element AFTER subtracting the cast's resist-pierce (Cold
/// Mastery / -%enemy-resist). `target_resist` is the seam the standalone fills from the monster's
/// resist (drlg-owned); this lib never depends on drlg. Consumes one RNG step (the damage roll).
/// Pure — does NOT mutate the target; call `applyElementalHit` to subtract.
///
/// This closes skill.zig's "skill elemental scaling is a TODO": a sorceress cold/fire/light cast
/// now deals its real Skills.txt element damage, synergy- and mastery-scaled, then resisted with
/// the correct Cold-Mastery-as-pierce behaviour.
pub fn resolveElemental(sp_cast: spell.Cast, target_resist: i32, seed: *Seed) ElementalHit {
    const raw = sp_cast.roll(seed);
    const effective_resist = target_resist - sp_cast.pierce_percent;
    const applied = spell.applyResist(raw, effective_resist);
    return .{ .element = sp_cast.dmg.etype, .raw = raw, .applied = applied, .resist = effective_resist };
}

/// Convenience: resolve against a Unit, reading the element-specific resist off its stat list
/// (players / modelled monsters). The standalone can instead call `resolveElemental` with a
/// resist value it pulled from the drlg monster table.
pub fn resolveElementalVsUnit(sp_cast: spell.Cast, target: *const Unit, seed: *Seed) ElementalHit {
    const resist = spell.ResistProfile.fromUnit(target, sp_cast.dmg.etype).percent;
    return resolveElemental(sp_cast, resist, seed);
}

/// Subtract an elemental hit's applied damage from the target's life (floored at 0).
pub fn applyElementalHit(hit: ElementalHit, target: *Unit) void {
    if (hit.applied > 0) combat.applyToLife(target, hit.applied);
}

/// Cast a DIRECT elemental skill (one with no missile — Frost Nova / Nova / Static Field / Poison
/// Nova, any class that classifies `.direct`) at `target`: assemble its fully table-driven Cast
/// (element + EDmgSymPerCalc synergies + matching mastery) and resolve it against the target's
/// resist in one call. `book` = the caster's skill allocation; `effective_level` = the skill's
/// level after +skills. Pure (one RNG step for the roll); subtract with `applyElementalHit`. This
/// is the direct-hit counterpart of the missile path (`cast` spawns a bolt; this resolves in place).
pub fn castDirectElemental(skills: *const Skills, book: SkillBook, skill_id: u16, effective_level: i32, target: *const Unit, seed: *Seed) ElementalHit {
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const c = castElemental(skills, book, skill_id, effective_level, &syn);
    return resolveElementalVsUnit(c, target, seed);
}

/// Resolve an ItemStatCost stat NAME (e.g. "manarecoverybonus", "passive_critical_strike") to its
/// stat id — the ItemStatCost.txt row index, which IS the id the StatList / Stat enum is keyed by.
pub fn statIdByName(isc: *const d2data.Table, name: []const u8) ?u16 {
    const row = isc.findRow("Stat", name) orelse return null;
    return @intCast(row);
}

/// Fold a caster's PASSIVE skills onto its unit stats: for every skill the `book` has points in,
/// evaluate its passive-granted stat (passiveValue) and ADD it to the unit's StatList by
/// ItemStatCost id. Active skills (empty passivestat1) contribute nothing. This is how Warmth /
/// Critical Strike / Iron Skin / the masteries actually reach the unit. `isc` is a loaded
/// ItemStatCost table (owned by the caller). Idempotency is the caller's concern (call once on load).
pub fn applyPassives(skills: *const Skills, u: *Unit, book: SkillBook, isc: *const d2data.Table) void {
    for (book.levels, 0..) |lvl, id| {
        if (lvl <= 0) continue;
        const row = skills.rowById(@intCast(id)) orelse continue;
        // Every passivestatN slot (Natural Resistance grants 4 resists across slots 1..4; a mastery
        // just uses slot 1). Each is valued by its own passivecalcN via the calc VM.
        inline for (1..6) |slot| {
            const stat_col = std.fmt.comptimePrint("passivestat{d}", .{slot});
            const calc_col = std.fmt.comptimePrint("passivecalc{d}", .{slot});
            const stat = skills.table.get(row, stat_col);
            if (stat.len != 0) {
                if (statIdByName(isc, stat)) |sid| {
                    u.stats.add(@enumFromInt(sid), skills.evalCalc(.{}, 0, @intCast(id), lvl, calc_col));
                }
            }
        }
    }
}

/// Grant an AURA's stat to a single unit (an ally the host decided is in range): evaluate the aura's
/// granted stat (auraValue) and ADD it to `u`'s StatList by ItemStatCost id. The range / who-is-in-
/// range decision is the host's (game-loop territory); this is the pure per-unit apply — a Paladin's
/// Might grants damagepercent to each party member the host passes in. Non-aura skill => no-op.
pub fn applyAuraTo(skills: *const Skills, u: *Unit, aura_id: u16, aura_level: i32, isc: *const d2data.Table) void {
    const av = skills.auraValue(aura_id, aura_level);
    if (av.stat.len == 0) return;
    const sid = statIdByName(isc, av.stat) orelse return;
    u.stats.add(@enumFromInt(sid), av.value);
}

/// Resolve a direct-elemental AREA skill (Nova / Frost Nova / Poison Nova) against every unit within
/// `radius` subtiles of (`cx`,`cy`): the caster's table-driven Cast is rolled once PER victim (so each
/// takes damage after its own resist + the caster's pierce) and applied to that unit's life. The host
/// supplies the candidate `targets` (it owns unit storage + the friend/foe policy) and the radius
/// (from the skill's area param). Returns how many units were hit. Pure combat math; mutates only the
/// units it hits.
pub fn castDirectAreaElemental(skills: *const Skills, book: SkillBook, skill_id: u16, effective_level: i32, cx: i32, cy: i32, radius: i32, targets: []const *Unit, seed: *Seed) usize {
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const c = castElemental(skills, book, skill_id, effective_level, &syn);
    const r2: i64 = @as(i64, radius) * radius;
    var hits: usize = 0;
    for (targets) |t| {
        if (!t.isAlive()) continue;
        const dx: i64 = t.x - cx;
        const dy: i64 = t.y - cy;
        if (dx * dx + dy * dy > r2) continue; // outside the ring
        const hit = resolveElementalVsUnit(c, t, seed);
        applyElementalHit(hit, t);
        hits += 1;
    }
    return hits;
}

/// A monster's castable skills, resolved from its MonStats Skill1..8 assignments to Skills.txt ids
/// + a SkillBook carrying their levels — so monster casts flow through the SAME table-driven path as
/// players (castElemental / cast / castDirectElemental). Built by `resolveMonsterCaster`.
pub const MonsterCaster = struct {
    book: SkillBook = .{},
    ids: [monskill.MAX_SKILLS]u16 = undefined,
    levels: [monskill.MAX_SKILLS]i32 = undefined,
    count: usize = 0,

    /// The first assigned skill that resolves to a DAMAGING cast (a missile or a direct-elemental
    /// hit) — a minimal AI-selection primitive. Returns its Skills id, or null when the monster has
    /// only non-damaging skills (summon/aura/heal) and should fall back to a melee attack.
    pub fn pickCastable(self: MonsterCaster, skills: *const Skills) ?u16 {
        for (self.ids[0..self.count]) |id| {
            const k = (skills.byId(id) orelse continue).kind();
            if (k == .missile or k == .direct) return id;
        }
        return null;
    }
};

/// Resolve a monster's MonStats skill assignments (from monskill.read) into a MonsterCaster: map
/// each skill NAME to its Skills.txt id and record its level in a SkillBook (skills not in Skills.txt
/// are skipped). No hardcoded ids.
pub fn resolveMonsterCaster(skills: *const Skills, mon_skills: []const monskill.MonSkill) MonsterCaster {
    var mc = MonsterCaster{};
    for (mon_skills) |ms| {
        if (mc.count >= mc.ids.len) break;
        const id = skills.idByName(ms.name) orelse continue;
        mc.ids[mc.count] = id;
        mc.levels[mc.count] = ms.level;
        mc.book.set(id, @intCast(@max(0, ms.level)));
        mc.count += 1;
    }
    return mc;
}

const testing = std.testing;

/// Test-only caster: a per-skill hard level resolved by Skills.txt NAME (the ctx interface
/// `buildElementalCast` expects). Synergies default to 0 unless set. No skill Ids are hardcoded.
const TestCaster = struct {
    ice_bolt: i32 = 20,
    frost_nova: i32 = 0,
    ice_blast: i32 = 0,
    glacial_spike: i32 = 0,
    blizzard: i32 = 0,
    frozen_orb: i32 = 0,
    cold_mastery: i32 = 0,
    fn skillLevel(self: TestCaster, skills: *const Skills, id: u16) i32 {
        const alloc = .{
            .{ "Ice Bolt", self.ice_bolt },   .{ "Frost Nova", self.frost_nova },
            .{ "Ice Blast", self.ice_blast }, .{ "Glacial Spike", self.glacial_spike },
            .{ "Blizzard", self.blizzard },   .{ "Frozen Orb", self.frozen_orb },
            .{ "Cold Mastery", self.cold_mastery },
        };
        inline for (alloc) |pair| {
            if (skills.idByName(pair[0]) == id) return pair[1];
        }
        return 0;
    }
};

/// Build a real table-driven Ice Bolt cast (synergies at 0) for the resist-wiring tests.
fn testIceBolt(skills: *const Skills, ice_bolt_lvl: i32, cold_mastery_lvl: i32, syn_out: *[spell.MAX_SYNERGIES]spell.Synergy) spell.Cast {
    const ib = skills.idByName("Ice Bolt").?;
    const cm = skills.idByName("Cold Mastery");
    const ctx = TestCaster{ .ice_bolt = ice_bolt_lvl, .cold_mastery = cold_mastery_lvl };
    return buildElementalCast(skills, ib, ice_bolt_lvl, ctx, cm, .pierce, syn_out);
}

test "resolveElemental: Ice Bolt vs a cold-resistant target applies the resist" {
    // clvl 20 Ice Bolt, no synergy/mastery: min = 6 + 4*2(9-16 span partial)... use the module's
    // verified staged value. Just assert the resist wiring: raw within [min,max], applied resisted.
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const ic = testIceBolt(&skills, 20, 0, &syn);
    const d = ic.damage();

    var mob = Unit.init(.monster);
    mob.set(.coldresist, 50); // 50% cold resist -> half damage
    mob.setLife(1000);

    var seed = Seed.fromValue(7);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(spell.Element.cold, hit.element);
    try testing.expect(hit.raw >= d.min and hit.raw <= d.max);
    try testing.expectEqual(@as(i32, 50), hit.resist);
    try testing.expectEqual(@divTrunc(hit.raw * 50, 100), hit.applied); // (100-50)/100

    applyElementalHit(hit, &mob);
    try testing.expectEqual(1000 - hit.applied, mob.life());
}

test "resolveElemental: Cold Mastery pierces the target's cold resist" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    // slvl 5 Cold Mastery => -45% enemy cold resist (ln12 = 20 + 5*5, read from Skills.txt).
    const ic = testIceBolt(&skills, 20, 5, &syn);
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 50); // 50% - 45% pierce = 5% effective resist.
    mob.setLife(1000);
    var seed = Seed.fromValue(11);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(@as(i32, 5), hit.resist); // pierced 50 -> 5
    try testing.expectEqual(@divTrunc(hit.raw * 95, 100), hit.applied);
}

test "resolveElemental: cold-immune target takes zero" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const ic = testIceBolt(&skills, 30, 0, &syn);
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 100); // immune
    mob.setLife(500);
    var seed = Seed.fromValue(3);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(@as(i32, 0), hit.applied);
    applyElementalHit(hit, &mob);
    try testing.expectEqual(@as(i32, 500), mob.life()); // untouched
}

test "applyOutcome: melee arm subtracts life, missile arm is returned for the host" {
    var mob = Unit.init(.monster);
    mob.setLife(50);
    const hit = Outcome{ .melee = .{ .hit = true, .chance = 95, .ar = 0, .def = 0, .raw_damage = 12, .damage = 12 } };
    try testing.expectEqual(@as(?missile.Missile, null), applyOutcome(hit, &mob));
    try testing.expectEqual(@as(i32, 38), mob.life());

    const miss = Outcome{ .melee = .{ .hit = false, .chance = 5, .ar = 0, .def = 0, .raw_damage = 0, .damage = 0 } };
    try testing.expectEqual(@as(?missile.Missile, null), applyOutcome(miss, &mob));
    try testing.expectEqual(@as(i32, 38), mob.life()); // unchanged on a miss

    const spawn = Outcome{ .missile = .{ .guid = 0, .id = 58 } };
    const out = applyOutcome(spawn, null);
    try testing.expect(out != null);
    try testing.expectEqual(@as(u16, 58), out.?.id);
}

test "classify: Attack is melee, Fire Bolt is a missile" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(Kind.melee, s.byId(0).?.kind()); // Attack
    try testing.expectEqual(Kind.missile, s.byId(36).?.kind()); // Fire Bolt
    try testing.expectEqualStrings("firebolt", s.byId(36).?.srvmissile);
    try testing.expectEqual(@as(?SkillData, null), s.byId(9999));
}

test "classify: every category resolves from the real Skills.txt columns" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const byName = struct {
        fn k(sk: *const Skills, name: []const u8) Kind {
            return sk.byId(sk.idByName(name).?).?.kind();
        }
    }.k;
    try testing.expectEqual(Kind.melee, byName(&s, "Attack"));
    try testing.expectEqual(Kind.missile, byName(&s, "Ice Bolt")); // srvmissile
    try testing.expectEqual(Kind.teleport, byName(&s, "Teleport")); // srvdofunc 27
    try testing.expectEqual(Kind.aura, byName(&s, "Might")); // aura=1
    try testing.expectEqual(Kind.passive, byName(&s, "Warmth")); // passivestate
    try testing.expectEqual(Kind.summon, byName(&s, "Raise Skeleton")); // summon
    try testing.expectEqual(Kind.direct, byName(&s, "Frost Nova")); // EType, no missile
    try testing.expectEqual(Kind.direct, byName(&s, "Static Field"));
    try testing.expectEqual(Kind.other, byName(&s, "Battle Orders")); // utility buff
    // Every non-divider skill must classify without crashing (no unreachable category).
    var count: usize = 0;
    for (0..s.table.rowCount()) |r| {
        const id = s.table.getInt(i32, r, "Id") orelse continue;
        if (s.byId(@intCast(id))) |sd| {
            _ = sd.kind();
            count += 1;
        }
    }
    try testing.expect(count > 300); // the whole catalog classified
}

test "calc VM resolves the elemental-damage codes (edmn/edmx/edns) from the staged element row" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const fb = s.idByName("Fire Bolt").?;
    const fbd = s.byId(fb).?;
    const ev = calc.Evaluator(CalcCtx){ .ctx = .{ .skills = &s, .book = .{}, .char_level = 1 } };
    // edmn/edmx = the skill's staged whole min/max at the given level; edns/edxs the 1/256 forms.
    try testing.expectEqual(fbd.dmg.minAt(1), try ev.eval("edmn", fb, 1));
    try testing.expectEqual(fbd.dmg.maxAt(3), try ev.eval("edmx", fb, 3));
    try testing.expectEqual(@as(i32, @intCast(fbd.dmg.min256(1))), try ev.eval("edns", fb, 1));
    // A compound calc (Energy Shield-style) evaluates end to end.
    try testing.expectEqual(@min(fbd.dmg.minAt(1), 95), try ev.eval("min(edmn,95)", fb, 1));
}

test "castDirectElemental resolves a direct (missile-less) elemental skill vs a target's resist" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const fn_id = s.idByName("Frost Nova").?;
    try testing.expectEqual(Kind.direct, s.byId(fn_id).?.kind());

    var book = SkillBook{};
    book.setByName(&s, "Frost Nova", 10);

    var mob = Unit.init(.monster);
    mob.set(.coldresist, 50); // half cold damage
    mob.setLife(10000);
    var seed = Seed.fromValue(3);
    const hit = castDirectElemental(&s, book, fn_id, 10, &mob, &seed);
    try testing.expectEqual(spell.Element.cold, hit.element);
    try testing.expect(hit.raw > 0); // real staged cold damage from the table
    try testing.expectEqual(@as(i32, 50), hit.resist);
    try testing.expectEqual(@divTrunc(hit.raw * 50, 100), hit.applied); // 50% resisted
    applyElementalHit(hit, &mob);
    try testing.expectEqual(10000 - hit.applied, mob.life());
}

test "castDirectAreaElemental hits every unit in the ring, spares those outside it" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const fn_id = s.idByName("Frost Nova").?;
    var book = SkillBook{};
    book.setByName(&s, "Frost Nova", 10);

    var near1 = Unit.init(.monster);
    near1.x = 5;
    near1.y = 0;
    near1.setLife(10000);
    var near2 = Unit.init(.monster);
    near2.x = 0;
    near2.y = 8;
    near2.setLife(10000);
    var far = Unit.init(.monster);
    far.x = 100;
    far.y = 0;
    far.setLife(10000);
    var targets = [_]*Unit{ &near1, &near2, &far };

    var seed = Seed.fromValue(9);
    // Cast from the origin with a radius of 10 subtiles: near1/near2 in, far out.
    const hits = castDirectAreaElemental(&s, book, fn_id, 10, 0, 0, 10, &targets, &seed);
    try testing.expectEqual(@as(usize, 2), hits);
    try testing.expect(near1.life() < 10000); // took cold damage
    try testing.expect(near2.life() < 10000);
    try testing.expectEqual(@as(i32, 10000), far.life()); // out of range, untouched
}

test "resolveMonsterCaster maps MonStats skills to castable selections (AI picks a damaging one)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var mt = try d2data.open(testing.allocator, "MonStats");
    defer mt.deinit();
    var buf: [monskill.MAX_SKILLS]monskill.MonSkill = undefined;

    // A Will-o-Wisp casts Chain Lightning (direct elemental) -> pickCastable selects it.
    const nw = monskill.forMonster(&mt, "willowisp1", &buf);
    const wmc = resolveMonsterCaster(&s, buf[0..nw]);
    try testing.expect(wmc.count >= 1);
    const wpick = wmc.pickCastable(&s) orelse return error.NoCastable;
    try testing.expectEqual(s.idByName("Chain Lightning").?, wpick);

    // A Vampire's VampireFireball is a missile -> also castable.
    const nv = monskill.forMonster(&mt, "vampire1", &buf);
    const vmc = resolveMonsterCaster(&s, buf[0..nv]);
    try testing.expectEqual(Kind.missile, s.byId(vmc.pickCastable(&s).?).?.kind());

    // A pure summoner (Skeleton -> SkeletonRaise) has no damaging cast -> null (melee fallback).
    const nk = monskill.forMonster(&mt, "skeleton1", &buf);
    const kmc = resolveMonsterCaster(&s, buf[0..nk]);
    try testing.expectEqual(@as(?u16, null), kmc.pickCastable(&s));
}

test "monsterCast produces a damaging outcome (direct hit + elemental missile)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var m = try missile.Missiles.load(testing.allocator);
    defer m.deinit();
    var mt = try d2data.open(testing.allocator, "MonStats");
    defer mt.deinit();
    var buf: [monskill.MAX_SKILLS]monskill.MonSkill = undefined;

    var caster = Unit.init(.monster);
    caster.unit_id = 5;
    var seed = Seed.fromValue(7);

    // Will-o-Wisp -> Chain Lightning is a DIRECT elemental hit resolved vs the target.
    const nw = monskill.forMonster(&mt, "willowisp1", &buf);
    const wmc = resolveMonsterCaster(&s, buf[0..nw]);
    var tgt = Unit.init(.player);
    tgt.setLife(5000);
    const out = monsterCast(&s, &m, &caster, wmc, &tgt, &seed);
    try testing.expect(out == .elemental);
    try testing.expectEqual(spell.Element.lightning, out.elemental.element);
    _ = applyOutcome(out, &tgt); // host applies it -> the monster hurt the player
    try testing.expect(tgt.life() <= 5000);

    // Vampire -> VampireFireball is an elemental MISSILE aimed at the target.
    const nv = monskill.forMonster(&mt, "vampire1", &buf);
    const vmc = resolveMonsterCaster(&s, buf[0..nv]);
    const vout = monsterCast(&s, &m, &caster, vmc, &tgt, &seed);
    try testing.expect(vout == .missile);
    try testing.expect(vout.missile.caster_derived); // carries the monster's elemental cast
}

test "applyPassives folds a caster's passive skills onto its unit stats (end to end)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    var u = Unit.init(.player);
    var book = SkillBook{};
    book.setByName(&s, "Warmth", 5); // passive: manarecoverybonus = ln12 = 30 + 5*12 = 90
    book.setByName(&s, "Ice Bolt", 20); // active: no passive stat -> contributes nothing

    applyPassives(&s, &u, book, &isc);

    const mrb = statIdByName(&isc, "manarecoverybonus").?;
    try testing.expectEqual(@as(i32, 90), u.stats.get(@enumFromInt(mrb)));
    // Natural Resistance grants ALL 4 resists (passivestat1..4), not just the first slot.
    var nat = Unit.init(.player);
    var nbook = SkillBook{};
    nbook.setByName(&s, "Natural Resistance", 10);
    applyPassives(&s, &nat, nbook, &isc);
    inline for (.{ "fireresist", "lightresist", "coldresist", "poisonresist" }) |rname| {
        try testing.expect(nat.stats.get(@enumFromInt(statIdByName(&isc, rname).?)) > 0);
    }
    // Cold Mastery pierce also lands when the sorc has it.
    book.setByName(&s, "Cold Mastery", 5); // passive_cold_pierce = ln12 = 20 + 5*5 = 45
    var ucm = Unit.init(.player);
    applyPassives(&s, &ucm, book, &isc);
    const pcp = statIdByName(&isc, "passive_cold_pierce").?;
    try testing.expectEqual(@as(i32, 45), ucm.stats.get(@enumFromInt(pcp)));
}

test "applyAuraTo grants a Paladin aura's stat to an ally unit" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    var ally = Unit.init(.player);
    // A level-5 Might aura on the ally grants damagepercent = ln34 = 40 + 5*10 = 90.
    applyAuraTo(&s, &ally, s.idByName("Might").?, 5, &isc);
    const dmg = statIdByName(&isc, "damagepercent").?;
    try testing.expectEqual(@as(i32, 90), ally.stats.get(@enumFromInt(dmg)));

    // A non-aura skill (Ice Bolt) grants nothing.
    var other = Unit.init(.player);
    applyAuraTo(&s, &other, s.idByName("Ice Bolt").?, 5, &isc);
    try testing.expectEqual(@as(i32, 0), other.stats.get(@enumFromInt(dmg)));
}

test "end-to-end: a Might aura flows through to a unit's physical combat damage" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    var u = Unit.init(.player);
    u.set(.mindamage, 10);
    u.set(.maxdamage, 10); // flat 10 base so the roll is deterministic
    var seed = Seed.fromValue(1);
    const before = combat.rollPhysicalDamage(&u, &seed, .{}).whole();

    // Might slvl5 grants +90% damagepercent, which rollPhysicalDamage already consumes.
    applyAuraTo(&s, &u, s.idByName("Might").?, 5, &isc);
    var seed2 = Seed.fromValue(1);
    const after = combat.rollPhysicalDamage(&u, &seed2, .{}).whole();

    try testing.expectEqual(@as(i32, 10), before);
    // The aura's value landed on the unit's damagepercent stat exactly (auraValue -> applyAuraTo).
    const dmgpct = statIdByName(&isc, "damagepercent").?;
    try testing.expectEqual(@as(i32, 90), u.stats.get(@enumFromInt(dmgpct)));
    // ...and combat consumes it: the melee damage is meaningfully higher (~+90%, plus attr rounding).
    try testing.expect(after > before);
    try testing.expect(after >= before + 8);
}

test "end-to-end: Natural Resistance reduces incoming elemental damage (resist -> resolveElemental)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    // A fire cast (arbitrary fixture) resolved against a bare unit vs a Natural-Resistance unit.
    const fire: spell.Cast = .{ .dmg = .{ .etype = .fire, .e_min = 100, .e_max = 100, .hit_shift = 8 }, .skill_level = 1 };

    var bare = Unit.init(.player);
    var seed1 = Seed.fromValue(5);
    const hit_bare = resolveElementalVsUnit(fire, &bare, &seed1);

    var resistant = Unit.init(.player);
    var rbook = SkillBook{};
    rbook.setByName(&s, "Natural Resistance", 10);
    applyPassives(&s, &resistant, rbook, &isc); // grants fireresist etc.
    var seed2 = Seed.fromValue(5);
    const hit_res = resolveElementalVsUnit(fire, &resistant, &seed2);

    try testing.expect(hit_res.resist > 0); // the passive gave real fire resist
    try testing.expect(hit_res.applied < hit_bare.applied); // so it took less fire damage
}

test "end-to-end: a Defiance aura raises a unit's defense (skill_armor_percent -> getDefense)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();
    var u = Unit.init(.player);
    u.set(.armorclass, 100);
    const before = combat.getDefense(&u);
    // Defiance grants skill_armor_percent, which getDefense now sums with item_armor_percent.
    applyAuraTo(&s, &u, s.idByName("Defiance").?, 5, &isc);
    const sap = statIdByName(&isc, "skill_armor_percent").?;
    try testing.expect(u.stats.get(@enumFromInt(sap)) > 0); // aura applied the %
    try testing.expect(combat.getDefense(&u) > before); // defense actually rose
}

test "passiveValue: passives grant their stat via the calc VM (ln + dm), all classes" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    // Warmth: manarecoverybonus = ln12 = 30 + lvl*12 (linear).
    const warmth = s.passiveValue(s.idByName("Warmth").?, 1);
    try testing.expectEqualStrings("manarecoverybonus", warmth.stat);
    try testing.expectEqual(@as(i32, 42), warmth.value); // 30 + 1*12

    // Critical Strike: passive_critical_strike = dm12 (diminishing, Param1=5 Param2=80).
    const cs = s.passiveValue(s.idByName("Critical Strike").?, 1);
    try testing.expectEqualStrings("passive_critical_strike", cs.stat);
    try testing.expectEqual(@as(i32, @intCast(calc.diminishing(1, 5, 80))), cs.value); // 16

    // Iron Skin (Barb) grants defensive armor% — a passive on a different class.
    try testing.expectEqualStrings("skill_armor_percent", s.passiveValue(s.idByName("Iron Skin").?, 1).stat);

    // masteryValue is the value-only view of the same passive path.
    const cm = s.idByName("Cold Mastery").?;
    try testing.expectEqual(s.passiveValue(cm, 5).value, s.masteryValue(cm, 5));
}

test "summonInfo: summon monster + pet count from the table (petmax is a ternary calc)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    // Raise Skeleton -> necroskeleton, petmax = (lvl<4)?lvl:(2+lvl/3).
    const rs = s.idByName("Raise Skeleton").?;
    try testing.expectEqualStrings("necroskeleton", s.summonInfo(rs, 1).monster);
    try testing.expectEqual(@as(i32, 1), s.summonInfo(rs, 1).count); // lvl<4 -> lvl
    try testing.expectEqual(@as(i32, 3), s.summonInfo(rs, 3).count);
    try testing.expectEqual(@as(i32, 3), s.summonInfo(rs, 4).count); // 2 + 4/3 = 3
    try testing.expectEqual(@as(i32, 5), s.summonInfo(rs, 10).count); // 2 + 10/3 = 5

    // Clay Golem -> a single golem (petmax constant 1).
    const cg = s.idByName("Clay Golem").?;
    try testing.expectEqualStrings("ClayGolem", s.summonInfo(cg, 20).monster);
    try testing.expectEqual(@as(i32, 1), s.summonInfo(cg, 20).count);

    // A non-summon skill => empty.
    try testing.expectEqualStrings("", s.summonInfo(s.idByName("Ice Bolt").?, 1).monster);
}

test "auraValue: aura skills grant their stat, valued by the calc VM (Might/Defiance/Blessed Aim)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    // Might: aurastat1=damagepercent, aurastatcalc1=ln34 = Param3 + lvl*Param4 = 40 + lvl*10.
    const might = s.idByName("Might").?;
    const a1 = s.auraValue(might, 1);
    try testing.expectEqualStrings("damagepercent", a1.stat);
    try testing.expectEqual(@as(i32, 50), a1.value); // 40 + 1*10
    try testing.expectEqual(@as(i32, 90), s.auraValue(might, 5).value); // 40 + 5*10

    // Defiance grants defensive armor%; Blessed Aim grants to-hit% — both ln34, same shape.
    try testing.expectEqualStrings("skill_armor_percent", s.auraValue(s.idByName("Defiance").?, 1).stat);
    try testing.expectEqualStrings("item_tohit_percent", s.auraValue(s.idByName("Blessed Aim").?, 1).stat);

    // A non-aura skill returns an empty stat.
    try testing.expectEqualStrings("", s.auraValue(s.idByName("Ice Bolt").?, 1).stat);
}

test "skill reuse cooldown (delay) loads from the table" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(i32, 25), s.byId(s.idByName("Frozen Orb").?).?.delay);
    try testing.expectEqual(@as(i32, 45), s.byId(s.idByName("Blizzard").?).?.delay);
    try testing.expectEqual(@as(i32, 30), s.byId(s.idByName("Meteor").?).?.delay);
    try testing.expectEqual(@as(i32, 0), s.byId(s.idByName("Ice Bolt").?).?.delay); // no cooldown
}

test "manaCostAt is the faithful per-level mana cost (SKILLS_CalculateManaCost)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const fb = s.byId(s.idByName("Fire Bolt").?).?;
    try testing.expectEqual(@as(i32, 2), fb.manaCostAt(1)); // (5<<7)>>8 = 2
    try testing.expectEqual(@as(i32, 2), fb.manaCostAt(10)); // lvlmana 0 -> flat

    const tp = s.byId(s.idByName("Teleport").?).?;
    try testing.expectEqual(@as(i32, 24), tp.manaCostAt(1)); // 24 at slvl1
    try testing.expectEqual(@as(i32, 15), tp.manaCostAt(10)); // lvlmana -1 -> cheaper with level

    const bl = s.byId(s.idByName("Blizzard").?).?;
    try testing.expectEqual(@as(i32, 23), bl.manaCostAt(1));
    try testing.expectEqual(@as(i32, 32), bl.manaCostAt(10)); // 23 + 1*9
}

test "castElemental is all-class: Amazon/Necromancer/Paladin/Druid elemental skills assemble" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const cases = .{
        .{ "Immolation Arrow", spell.Element.fire }, // Amazon
        .{ "Poison Nova", spell.Element.poison }, // Necromancer
        .{ "Holy Bolt", spell.Element.magic }, // Paladin
        .{ "Firestorm", spell.Element.fire }, // Druid
    };
    inline for (cases) |c| {
        const id = s.idByName(c[0]).?;
        var book = SkillBook{};
        book.setByName(&s, c[0], 10);
        const casted = castElemental(&s, book, id, 10, &syn);
        try testing.expectEqual(c[1], casted.dmg.etype); // element from Skills.txt EType
        // Real staged element damage from the table (raw 1/256 — the whole value can round to 0 for
        // a low-HitShift skill like Firestorm at low level, but the fixed-point damage is nonzero).
        try testing.expect(casted.dmg.max256(10) > 0);
    }
}

test "TABLE-DRIVEN: Teleport (Id 54) classifies as teleport with the real Skills.txt mana cost" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const tp = s.byId(54).?; // Teleport
    try testing.expectEqual(@as(i32, 27), tp.srvdofunc); // DOFUNC_TELEPORT
    try testing.expectEqual(Kind.teleport, tp.kind());
    try testing.expectEqual(@as(i32, 24), tp.mana); // Skills.txt mana column
    try testing.expectEqual(@as(i32, 24), tp.manaCost());
    try testing.expectEqualStrings("", tp.srvmissile); // reposition, not a missile
}

test "TABLE-DRIVEN: Ice Bolt (Id 39) element damage read from the REAL Skills.txt matches the parity anchor" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const ib_id = s.idByName("Ice Bolt").?; // resolves to Skills.txt Id 39 by name
    const ib = s.byId(ib_id).?;
    // The E* columns read straight from the real 1.14d Skills.txt row (no hardcoded literals):
    try testing.expectEqual(spell.Element.cold, ib.dmg.etype); // EType=cold
    try testing.expectEqual(@as(i32, 6), ib.dmg.e_min); // EMin=6
    try testing.expectEqual(@as(i32, 10), ib.dmg.e_max); // EMax=10
    try testing.expectEqual([5]i32{ 2, 4, 6, 8, 10 }, ib.dmg.e_min_lev); // EMinLev1..5
    try testing.expectEqual([5]i32{ 3, 5, 7, 9, 11 }, ib.dmg.e_max_lev); // EMaxLev1..5
    try testing.expectEqual(@as(i32, 7), ib.dmg.hit_shift); // HitShift=7
    try testing.expectEqual(@as(i32, 150), ib.e_len); // ELen=150

    // PARITY: the staged progression on the TABLE-DRIVEN row yields the known Ice Bolt numbers.
    // lvl 1 tooltip = 3-5; slvl 10 min = (6 + 2*7 + 4*2) = 28, <<7 >>8 = >>1 = 14.
    try testing.expectEqual(@as(i32, 3), ib.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 5), ib.dmg.maxAt(1));
    try testing.expectEqual(@as(i32, 14), ib.dmg.minAt(10)); // the load-bearing parity number

    // The synergy set + %/level come from EDmgSymPerCalc/Param8 (Param8=15 => 150‰), NOT a literal.
    const syn = s.synergyInfo(ib_id);
    try testing.expectEqual(@as(usize, 5), syn.count); // Frost Nova/Ice Blast/Glacial Spike/Blizzard/Frozen Orb
    try testing.expectEqual(@as(i32, 150), syn.permille);
    try testing.expectEqual(s.idByName("Frost Nova").?, syn.ids[0]);
    try testing.expectEqual(s.idByName("Frozen Orb").?, syn.ids[4]);
    // Cold Mastery pierce is Param1+Param2*(lvl-1) off its own row (Id 65, not 58=Energy Shield).
    const cm = s.idByName("Cold Mastery").?;
    try testing.expectEqual(@as(u16, 65), cm);
    try testing.expectEqual(@as(i32, 0), s.masteryValue(cm, 0)); // not learned
    try testing.expectEqual(@as(i32, 25), s.masteryValue(cm, 1)); // ln12 = 20 + 1*5
    try testing.expectEqual(@as(i32, 45), s.masteryValue(cm, 5)); // ln12 = 20 + 5*5
}

test "TABLE-DRIVEN generalizes: Glacial Spike (Id 55) + Fire Bolt (Id 36) base damage from the real table" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();

    // Glacial Spike Id 55 (Skills.txt): EType=cold EMin=32 EMax=48 EMinLev1..5=14,26,28,30,32
    // EMaxLev1..5=15,27,29,31,33 HitShift=7 — proves the loader is not Ice-Bolt-specific.
    const gs = s.byId(55).?;
    try testing.expectEqual(spell.Element.cold, gs.dmg.etype);
    try testing.expectEqual(@as(i32, 32), gs.dmg.e_min);
    try testing.expectEqual(@as(i32, 48), gs.dmg.e_max);
    try testing.expectEqual([5]i32{ 14, 26, 28, 30, 32 }, gs.dmg.e_min_lev);
    try testing.expectEqual(@as(i32, 7), gs.dmg.hit_shift);
    // slvl 1 whole-damage: EMin>>1 = 16, EMax>>1 = 24 (matches the in-game 16-24 tooltip).
    try testing.expectEqual(@as(i32, 16), gs.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 24), gs.dmg.maxAt(1));

    // Fire Bolt Id 36 (Skills.txt): EType=fire EMin=6 EMax=12 HitShift=7 => slvl1 = 3-6.
    const fb = s.byId(36).?;
    try testing.expectEqual(spell.Element.fire, fb.dmg.etype);
    try testing.expectEqual(@as(i32, 6), fb.dmg.e_min);
    try testing.expectEqual(@as(i32, 12), fb.dmg.e_max);
    try testing.expectEqual(@as(i32, 3), fb.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 6), fb.dmg.maxAt(1));
}

test "castElemental: any elemental skill assembles from tables (element + synergies + right mastery)" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();

    // A sample allocation, set BY NAME (no skill Ids anywhere).
    var book = SkillBook{};
    book.setByName(&s, "Fire Ball", 10);
    book.setByName(&s, "Meteor", 5);
    book.setByName(&s, "Fire Mastery", 8);
    book.setByName(&s, "Ice Bolt", 20);
    book.setByName(&s, "Ice Blast", 20);
    book.setByName(&s, "Frozen Orb", 20);
    book.setByName(&s, "Cold Mastery", 5);

    var syn1: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    var syn2: [spell.MAX_SYNERGIES]spell.Synergy = undefined;

    // Fire Bolt (fire): Fire Mastery ADDS +% damage (mastery_percent, no pierce); synergies are
    // Fire Ball + Meteor straight from EDmgSymPerCalc.
    const fb = s.idByName("Fire Bolt").?;
    const fc = castElemental(&s, book, fb, 10, &syn1);
    try testing.expectEqual(spell.Element.fire, fc.dmg.etype);
    try testing.expectEqual(@as(usize, 2), fc.synergies.len);
    try testing.expectEqual(s.masteryValue(s.idByName("Fire Mastery").?, 8), fc.mastery_percent); // Fire Mastery ln12 = 30 + 8*7
    try testing.expectEqual(@as(i32, 0), fc.pierce_percent);

    // Glacial Spike (cold): Cold Mastery PIERCES (pierce_percent, no +damage); 3 synergies.
    const gs = s.idByName("Glacial Spike").?;
    const gc = castElemental(&s, book, gs, 20, &syn2);
    try testing.expectEqual(spell.Element.cold, gc.dmg.etype);
    try testing.expectEqual(@as(usize, 3), gc.synergies.len);
    try testing.expectEqual(s.masteryValue(s.idByName("Cold Mastery").?, 5), gc.pierce_percent); // Cold Mastery ln12 = 20 + 5*5
    try testing.expectEqual(@as(i32, 0), gc.mastery_percent);
}

test "execute: melee skill resolves through the combat core" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 1;
    caster.set(.level, 30);
    caster.set(.dexterity, 120);
    caster.set(.tohit, 5000);
    caster.weapon = .{ .min_damage = 20, .max_damage = 60 };
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.set(.level, 1);
    mob.setLife(50);

    var seed = Seed.fromValue(0xC0FFEE);
    const out = execute(&skills, &missiles, &caster, 0, .{ .unit = &mob }, &seed);
    try testing.expect(out == .melee);
    try testing.expect(out.melee.chance >= 5 and out.melee.chance <= 95);
}

test "execute: bolt skill spawns a missile aimed at the target" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 1;
    caster.x = 0;
    caster.y = 0;
    caster.weapon = .{ .min_damage = 3, .max_damage = 5 };
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 200;
    mob.y = 0;
    mob.setLife(50);

    var seed = Seed.fromValue(1);
    const out = execute(&skills, &missiles, &caster, 36, .{ .unit = &mob }, &seed); // Fire Bolt
    try testing.expect(out == .missile);
    try testing.expectEqual(@as(u16, 58), out.missile.id); // firebolt
    try testing.expectEqual(@as(u32, 1), out.missile.owner_id);
    try testing.expect(out.missile.vx > 0); // aimed toward +X (the monster)
    try testing.expect(out.missile.dmg_max >= out.missile.dmg_min);
}

test "cast: Ice Bolt spawns a caster_derived missile carrying the elemental cast" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 7;
    caster.x = 0;
    caster.y = 0;
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 300;
    mob.y = 0;
    mob.setLife(100);

    var syn: [spell.MAX_SYNERGIES]spell.Synergy = undefined;
    const ib_id = skills.idByName("Ice Bolt").?;
    const ctx = TestCaster{ .ice_bolt = 20, .frost_nova = 1, .ice_blast = 20, .glacial_spike = 20, .blizzard = 20, .frozen_orb = 20, .cold_mastery = 20 };
    const c = buildElementalCast(&skills, ib_id, 20, ctx, skills.idByName("Cold Mastery"), .pierce, &syn);
    const out = cast(&skills, &missiles, &caster, 39, .{ .unit = &mob }, c); // Ice Bolt
    try testing.expect(out == .missile);
    const m = out.missile;
    try testing.expectEqual(missiles.byName("icebolt").?.id, m.id);
    try testing.expectEqual(@as(u32, 7), m.owner_id);
    try testing.expect(m.caster_derived);
    try testing.expect(m.elem_cast != null);
    try testing.expectEqual(spell.Element.cold, m.elem_cast.?.dmg.etype);
    try testing.expect(m.vx > 0); // aimed toward the monster (+X)
}

test "execute: unknown skill / dead target -> none" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();
    var caster = Unit.init(.player);
    var seed = Seed.fromValue(1);
    try testing.expect(execute(&skills, &missiles, &caster, 4242, .{}, &seed) == .none);
    var dead = Unit.init(.monster);
    dead.setLife(0);
    try testing.expect(execute(&skills, &missiles, &caster, 0, .{ .unit = &dead }, &seed) == .none);
}
