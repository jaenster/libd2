//! Resolving a monster's MonStats skill assignments into something castable. A `MonsterCaster` carries
//! the monster's Skill1..8 as Skills.txt ids + their levels (in a SkillBook), so a monster's casts flow
//! through the SAME table-driven damage path players use (castElemental / cast / castDirectElemental in
//! skill.zig). This file is the resolution half (names/classes -> ids); the execution half (a monster
//! acting -> Outcome) is `skill.monsterCast`, which lives next to the other Outcome producers.

const std = @import("std");
const skill = @import("skill.zig");
const monskill = @import("monskill.zig");
const d2data = @import("d2-data");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;

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

    /// Like pickCastable, but begins scanning from `offset` (wrapping), so a caller that advances
    /// `offset` after each cast cycles through ALL of the monster's damaging skills in turn — the
    /// multi-skill rotation the act bosses (and any multi-cast monster) use instead of spamming one
    /// spell. Returns the chosen Skills id, or null when it has no damaging skill.
    pub fn pickCastableRotating(self: MonsterCaster, skills: *const Skills, offset: usize) ?u16 {
        if (self.count == 0) return null;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const id = self.ids[(offset + i) % self.count];
            const k = (skills.byId(id) orelse continue).kind();
            if (k == .missile or k == .direct) return id;
        }
        return null;
    }
};

/// Resolve a monster's MonStats `Id` NAME (as a summon skill's `summon` column gives it, e.g.
/// "necroskeleton", "ClayGolem", "valkyrie") to its class id — the MonStats row index. This is what a
/// summon skill needs to actually spawn its pet unit (summonInfo gives the name + count; this maps the
/// name to the class the host instantiates). Loads MonStats each call; null if the name isn't found.
pub fn monClassByName(gpa: std.mem.Allocator, name: []const u8) ?u16 {
    if (name.len == 0) return null;
    var mt = d2data.open(gpa, "MonStats") catch return null;
    defer mt.deinit();
    // Return the ENGINE class id (the "Expansion" divider row removed, matching monpop/montable and
    // pTxtMonStats) so the resolved id lines up with buildMonsterUnit — not the raw file row. Post-
    // divider summons (valkyrie/shadow/druid pets, all expansion monsters) were otherwise off by one.
    // Case-insensitive: the summon column casing (ClayGolem) can differ from the Id (claygolem).
    var class_id: u16 = 0;
    for (0..mt.rowCount()) |r| {
        const id = mt.get(r, "Id");
        if (std.ascii.eqlIgnoreCase(id, "Expansion")) continue;
        if (std.ascii.eqlIgnoreCase(id, name)) return class_id;
        class_id += 1;
    }
    return null;
}

/// Translate an engine class id (MonStats "Expansion" divider REMOVED — the convention monpop, montable
/// and the engine's pTxtMonStats use) into the raw MonStats.txt row (the file still holds the divider).
/// Without this, skills for class ids at/past the divider (410 = the Act5/expansion monsters, incl the
/// act bosses) were read one row high. Returns null when class_id is past the last monster.
fn rawRowForClassId(mt: anytype, class_id: u16) ?usize {
    var removed: u16 = 0;
    var r: usize = 0;
    while (r < mt.rowCount()) : (r += 1) {
        if (std.ascii.eqlIgnoreCase(mt.get(r, "Id"), "Expansion")) continue;
        if (removed == class_id) return r;
        removed += 1;
    }
    return null;
}

/// Build a MonsterCaster for a monster CLASS — its MonStats row index IS the class id (`class_id`),
/// so this loads the monster's Skill1..8 straight off that row and resolves them to Skills ids. Loads
/// the MonStats table each call, so the HOST should cache the returned MonsterCaster per class id
/// (there are only ~40 monster classes in a game). Empty caster on any failure.
pub fn casterForClass(gpa: std.mem.Allocator, skills: *const Skills, class_id: u16) MonsterCaster {
    var mt = d2data.open(gpa, "MonStats") catch return .{};
    defer mt.deinit();
    // class_id is an engine (Expansion-removed) id; map it to the raw MonStats row before reading skills.
    const raw = rawRowForClassId(&mt, class_id) orelse return .{};
    var buf: [monskill.MAX_SKILLS]monskill.MonSkill = undefined;
    const n = monskill.read(&mt, raw, &buf);
    return resolveMonsterCaster(skills, buf[0..n]);
}

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
