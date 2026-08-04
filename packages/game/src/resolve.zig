//! The skill-cast -> Effect spine. `resolve()` turns a cast (skill id + caster/target coords) into the
//! `Effect`s the host applies (see effect.zig); it is PURE — it decides, it never mutates world state.
//! Kept separate from the skill data model (skill.zig) because this is the newest, most-churned layer:
//! every migrated srvdofunc branch lands here, one at a time, without touching how a skill is loaded.

const std = @import("std");
const skill = @import("skill.zig");
const effect_mod = @import("effect.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;

/// Resolve a skill cast to Effects the host applies (the castSkill retrofit — see effect.zig). Handles
/// the migrated branches; returns [] for skills still resolved by the host's legacy inline path, so it
/// can grow branch-by-branch without a big-bang rewrite. Effects are written into `buf`.
pub fn resolve(
    skills: *const Skills,
    book: SkillBook,
    skill_id: u16,
    caster_x: i32,
    caster_y: i32,
    target_x: i32,
    target_y: i32,
    target_guid: u32,
    buf: []effect_mod.Effect,
) []effect_mod.Effect {
    const sd = skills.byId(skill_id) orelse return buf[0..0];
    // Aura (Might / Concentration / ...): casting one makes it the caster's active aura.
    if (sd.is_aura) {
        buf[0] = .{ .set_aura = .{ .skill_id = skill_id } };
        return buf[0..1];
    }
    // Summon (skeletons / golems / valkyrie / traps / hydra / druid pets): the monster + placement.
    if (sd.is_summon) {
        const lvl = book.get(skill_id);
        const info = skills.summonInfo(skill_id, lvl);
        if (info.monster.len == 0) return buf[0..0];
        if (sd.doFunc() == .hydra) { // three stationary heads at the cursor
            const off = [_]i32{ -1, 0, 1 };
            for (off, 0..) |ox, i| buf[i] = .{ .summon = .{ .monster = info.monster, .x = target_x + ox, .y = target_y, .count = info.count, .kind = .hydra_head } };
            return buf[0..3];
        }
        const is_golem = std.mem.indexOf(u8, info.monster, "Golem") != null;
        const is_trap = sd.doFunc() == .blade_sentinel or sd.doFunc() == .summon_trap_sentry;
        const kind: effect_mod.SummonKind = if (is_golem) .golem else if (is_trap) .trap else .pet;
        const sx = if (is_trap) target_x else caster_x + 2;
        const sy = if (is_trap) target_y else caster_y;
        buf[0] = .{ .summon = .{ .monster = info.monster, .x = sx, .y = sy, .count = info.count, .kind = kind } };
        return buf[0..1];
    }
    // Persistent ground effects (24 Fire Wall, 23 Blaze, 28 Blizzard-no-radius, 123 Volcano, 124
    // Armageddon): a lingering AoE pulsing the skill's element. 23-without-EType is Energy Shield and
    // 28-with-radius is Meteor — both fall through (return [] here).
    {
        const no_radius = if (skills.rowById(skill_id)) |row| skills.table.get(row, "aurarangecalc").len == 0 else true;
        const is_armageddon = sd.doFunc() == .armageddon;
        const is_ground = sd.doFunc() == .fire_wall or
            (sd.doFunc() == .blaze_energy_shield and sd.dmg.etype != .none) or
            (sd.doFunc() == .meteor_blizzard and no_radius and sd.dmg.etype != .none) or
            (sd.doFunc() == .volcano and sd.dmg.etype != .none) or
            is_armageddon;
        if (is_ground) {
            const lvl = book.get(skill_id);
            const dur: i32 = if (is_armageddon) @max(1, skills.evalCalc(book, 0, skill_id, lvl, "auralencalc")) else if (sd.doFunc() == .meteor_blizzard) 100 else 90;
            buf[0] = .{ .ground_effect = .{
                .skill_id = skill_id,
                .level = lvl,
                .x = if (is_armageddon) caster_x else target_x,
                .y = if (is_armageddon) caster_y else target_y,
                .duration = dur,
            } };
            return buf[0..1];
        }
    }
    // Whirlwind (sweep from caster to cursor, then end there), Leap (pure jump), Leap Attack (jump
    // then a weapon burst at the landing).
    if (sd.doFunc() == .whirlwind) {
        const lvl = book.get(skill_id);
        buf[0] = .{ .weapon_area = .{ .x = target_x, .y = target_y, .radius = 0, .ed_percent = skills.evalCalc(book, 0, skill_id, lvl, "calc1"), .from_x = caster_x, .from_y = caster_y, .sweep = true } };
        buf[1] = .{ .reposition = .{ .x = target_x, .y = target_y } };
        return buf[0..2];
    }
    if (sd.doFunc() == .leap) {
        buf[0] = .{ .reposition = .{ .x = target_x, .y = target_y } };
        return buf[0..1];
    }
    if (sd.doFunc() == .leap_attack) {
        const lvl = book.get(skill_id);
        buf[0] = .{ .reposition = .{ .x = target_x, .y = target_y } };
        buf[1] = .{ .weapon_area = .{ .x = target_x, .y = target_y, .radius = skills.evalCalc(book, 0, skill_id, lvl, "calc1"), .ed_percent = 0, .from_x = 0, .from_y = 0, .sweep = false } };
        return buf[0..2];
    }
    // Melee weapon strikes. Precedence mirrors the host: the ed%/reposition/multi-hit specials first,
    // then the generic strike group (meleeHitCount plain rolls). The 34/35 charge-ups are resolved
    // separately (they stack charges) and are not handled here.
    {
        const lvl = book.get(skill_id);
        const calc1 = skills.evalCalc(book, 0, skill_id, lvl, "calc1");
        const ws: ?effect_mod.Effect = switch (sd.doFunc()) {
            .multi_hit_attack => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = 0, .hits = 1, .reposition = false, .use_melee_skill = true } },
            .sacrifice, .smite, .generic_melee_hit => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = calc1, .hits = 1, .reposition = false, .use_melee_skill = false } },
            .charge => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = calc1, .hits = 1, .reposition = true, .use_melee_skill = false } },
            .frenzy_melee_hit, .double_swing => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = calc1, .hits = 2, .reposition = false, .use_melee_skill = false } },
            .dragon_flight => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = 0, .hits = 1, .reposition = true, .use_melee_skill = false } },
            .throw_weapon_left_hand, .throw_weapon_right_hand, .jab, .charged_strike, .lightning_strike, .dragon_talon, .dragon_claw, .dragon_tail_fire_explosion, .double_throw, .melee_attack_with_missile_wrapper, .feral_rage, .rabies, .hunger => .{ .weapon_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .ed_percent = 0, .hits = meleeHitCount(skills, book, skill_id, lvl), .reposition = false, .use_melee_skill = false } },
            else => null,
        };
        if (ws) |e| {
            buf[0] = e;
            return buf[0..1];
        }
    }
    // Area elemental burst: Meteor (28 WITH a radius) + Fist of the Heavens (80) hit hostiles at the
    // cursor; Static Field (20) drains %-current-life from monsters around the caster.
    if (sd.doFunc() == .fist_of_the_heavens or
        (sd.doFunc() == .meteor_blizzard and (if (skills.rowById(skill_id)) |row| skills.table.get(row, "aurarangecalc").len != 0 else false)))
    {
        const lvl = book.get(skill_id);
        buf[0] = .{ .elemental_area = .{ .skill_id = skill_id, .level = lvl, .x = target_x, .y = target_y, .radius = skills.evalCalc(book, 0, skill_id, lvl, "aurarangecalc"), .static = false } };
        return buf[0..1];
    }
    if (sd.doFunc() == .static) {
        const lvl = book.get(skill_id);
        buf[0] = .{ .elemental_area = .{ .skill_id = skill_id, .level = lvl, .x = caster_x, .y = caster_y, .radius = skills.evalCalc(book, 0, skill_id, lvl, "aurarangecalc"), .static = true } };
        return buf[0..1];
    }
    // Martial-arts charge-ups (Tiger/Cobra/Phoenix Strike; Fists of Fire / Claws of Thunder / Blades
    // of Ice): a weapon strike + the prgdam charge effect (host tracks the charge stack).
    if (sd.doFunc() == .charge_up_stack_melee or sd.doFunc() == .elemental_charge_release) {
        buf[0] = .{ .charge_up_strike = .{ .target_guid = target_guid, .skill_id = skill_id, .level = book.get(skill_id) } };
        return buf[0..1];
    }
    // Teleport: a through-walls reposition (host applies the mana/range gate + client stream).
    if (sd.doFunc() == .teleport) {
        buf[0] = .{ .teleport = .{ .x = target_x, .y = target_y, .guid = target_guid } };
        return buf[0..1];
    }
    // Missile spawns: Blessed Hammer's spiral grid + the bow/bolt fans (Multiple Shot/Charged Bolt/
    // Guided Arrow). resolve() picks count/homing/pattern; applyEffect builds + spawns via the missiles.
    if (sd.doFunc() == .blessed_hammer) {
        const lvl = book.get(skill_id);
        buf[0] = .{ .spawn_missiles = .{ .skill_id = skill_id, .level = lvl, .x = caster_x, .y = caster_y, .tx = target_x, .ty = target_y, .count = 0, .homing = false, .kind = .spiral } };
        return buf[0..1];
    }
    if (sd.doFunc() == .multi_shot or sd.doFunc() == .charged_bolt or sd.doFunc() == .guided_arrow_launch) {
        const lvl = book.get(skill_id);
        const homing = sd.doFunc() == .guided_arrow_launch;
        const cnt: u8 = if (homing) 1 else @intCast(@min(24, @max(1, skills.evalCalc(book, 0, skill_id, lvl, "calc1"))));
        buf[0] = .{ .spawn_missiles = .{ .skill_id = skill_id, .level = lvl, .x = caster_x, .y = caster_y, .tx = target_x, .ty = target_y, .count = cnt, .homing = homing, .kind = .spread } };
        return buf[0..1];
    }
    // Corpse skills: consume the nearest corpse at the cast point (host finds it) and do the mechanic.
    {
        const kind: ?@FieldType(@FieldType(effect_mod.Effect, "corpse_skill"), "kind") = switch (sd.doFunc()) {
            .corpse_explosion => .explode,
            .poison_explosion => .poison_ring,
            .revive_corpse_check => .revive,
            else => null,
        };
        if (kind) |k| {
            buf[0] = .{ .corpse_skill = .{ .x = target_x, .y = target_y, .skill_id = skill_id, .level = book.get(skill_id), .kind = k } };
            return buf[0..1];
        }
    }
    // Curses (Necro curses; Inner Sight / Slow Missiles): a debuff over hostiles in radius.
    if (sd.doFunc() == .cast_curse_aoe or sd.doFunc() == .inner_sight) {
        const lvl = book.get(skill_id);
        buf[0] = .{ .curse_area = .{
            .x = target_x,
            .y = target_y,
            .radius = skills.evalCalc(book, 0, skill_id, lvl, "aurarangecalc"),
            .skill_id = skill_id,
            .level = lvl,
            .duration = skills.evalCalc(book, 0, skill_id, lvl, "auralencalc"),
        } };
        return buf[0..1];
    }
    // Fear (Grim Ward, Howl = Nova-do-func with no element): hostiles near the CASTER flee for a while.
    if (sd.doFunc() == .grim_ward or (sd.doFunc() == .nova_frost_nova and sd.dmg.etype == .none)) {
        const lvl = book.get(skill_id);
        var radius = skills.evalCalc(book, 0, skill_id, lvl, "aurarangecalc");
        if (radius <= 0) radius = 12; // Howl has no aurarangecalc column
        var durc = skills.evalCalc(book, 0, skill_id, lvl, "auralencalc");
        if (durc <= 0) durc = 25;
        buf[0] = .{ .cc_area = .{ .x = caster_x, .y = caster_y, .radius = radius, .frames = @intCast(@max(1, durc)), .target_guid = 0, .kind = .fear } };
        return buf[0..1];
    }
    // Crowd control: a brief stun — Cloak / Mind Blast hit an area, the rest the single target.
    switch (sd.doFunc()) {
        .cloak_of_shadows, .mind_blast, .attract, .confuse, .taunt, .conversion => {
            const area = sd.doFunc() == .cloak_of_shadows or sd.doFunc() == .mind_blast;
            buf[0] = .{ .cc_area = .{ .x = target_x, .y = target_y, .radius = if (area) 12 else 0, .frames = 25, .target_guid = target_guid, .kind = .stun } };
            return buf[0..1];
        },
        else => {},
    }
    return buf[0..0];
}

/// Multi-hit count for a melee skill (Zeal/Strafe/Fend): srvdofunc 12/13 read calc1, else a single hit.
fn meleeHitCount(skills: *const Skills, book: SkillBook, skill_id: u16, level: i32) i32 {
    return skill.meleeHitCount(skills, book, skill_id, level);
}

const testing = std.testing;

test "resolve emits the right Effect for each migrated skill branch" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    var buf: [4]effect_mod.Effect = undefined;
    const R = struct {
        fn tag(sk: *const Skills, b: []effect_mod.Effect, name: []const u8) ?std.meta.Tag(effect_mod.Effect) {
            const id = sk.idByName(name) orelse return null;
            var book = SkillBook{};
            book.setByName(sk, name, 5);
            const e = resolve(sk, book, id, 100, 100, 120, 120, 9001, b);
            if (e.len == 0) return null;
            return e[0];
        }
    };
    try testing.expectEqual(effect_mod.Effect.curse_area, R.tag(&s, &buf, "Amplify Damage").?);
    try testing.expectEqual(effect_mod.Effect.cc_area, R.tag(&s, &buf, "Cloak of Shadows").?); // stun
    try testing.expectEqual(effect_mod.Effect.cc_area, R.tag(&s, &buf, "Grim Ward").?); // fear
    try testing.expectEqual(effect_mod.Effect.set_aura, R.tag(&s, &buf, "Might").?);
    try testing.expectEqual(effect_mod.Effect.summon, R.tag(&s, &buf, "Raise Skeleton").?);
    try testing.expectEqual(effect_mod.Effect.ground_effect, R.tag(&s, &buf, "Fire Wall").?);
    try testing.expectEqual(effect_mod.Effect.elemental_area, R.tag(&s, &buf, "Fist of the Heavens").?);
    try testing.expectEqual(effect_mod.Effect.elemental_area, R.tag(&s, &buf, "Static Field").?);
    try testing.expectEqual(effect_mod.Effect.weapon_strike, R.tag(&s, &buf, "Bash").?);
    try testing.expectEqual(effect_mod.Effect.weapon_strike, R.tag(&s, &buf, "Zeal").?); // multi-hit
    try testing.expectEqual(effect_mod.Effect.weapon_area, R.tag(&s, &buf, "Whirlwind").?);
    try testing.expectEqual(effect_mod.Effect.reposition, R.tag(&s, &buf, "Leap").?);
    // Fear centres on the caster; stun CC uses the given radius/target.
    const gw = resolve(&s, blk: {
        var b = SkillBook{};
        b.setByName(&s, "Grim Ward", 5);
        break :blk b;
    }, s.idByName("Grim Ward").?, 100, 100, 120, 120, 0, &buf);
    try testing.expect(gw[0].cc_area.kind == .fear and gw[0].cc_area.x == 100);
}
