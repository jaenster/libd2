//! Missile-PATTERN spawners: build the ring (Nova), spiral grid (Blessed Hammer) and fan (Multiple
//! Shot / Teeth) layouts a skill emits. These pair with resolve()'s `spawn_missiles` Effect — resolve
//! decides count/pattern, the host calls one of these to build the actual missiles, then assigns each a
//! guid + appends it. Faithful to the 1.14d emitters (SKILLS_CreateMissileRing / CreateMissileSpiralGrid
//! / the strafe spread), with the engine's own offset tables read straight from Game.exe.

const std = @import("std");
const skill = @import("skill.zig");
const missile = @import("missile.zig");
const spell = @import("spell.zig");

const Skills = skill.Skills;

/// Cast a RADIAL MISSILE SPRAY (srvdofunc 22 Nova/Frost Nova/Poison Nova = 64 missiles;
/// srvdofunc 63 Poison Explosion = 8 missiles from the corpse). Faithful to SKILLS_CreateMissileRing
/// (SkillSor.cpp) / MISSILES_SpawnRadialPattern (SkillNec.cpp): spawn `count` missiles of the skill's
/// `srvmissilea` evenly spaced around a FULL circle from (ox,oy), each carrying `elem_cast`
/// (caster-derived, so stepMissiles resolves the element per victim on hit exactly like a normal bolt).
/// The missiles travel OUTWARD under their own velocity — there is no radius/area sweep. Fills `out`
/// and returns how many were written (min(count, out.len)); the host gives each a guid + appends.
/// Returns 0 if the skill has no `srvmissilea`. Aim points sit on a unit circle (direction only —
/// Missile.create normalizes velocity — so the scale is arbitrary).
pub fn castRadialMissiles(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster_id: u32,
    skill_id: u16,
    ox: i32,
    oy: i32,
    count: usize,
    elem_cast: spell.Cast,
    out: []missile.Missile,
) usize {
    const row = skills.rowById(skill_id) orelse return 0;
    const md = missiles.byName(skills.table.get(row, "srvmissilea")) orelse return 0;
    const n = @min(count, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Use the ENGINE's own ring direction tables (ganMissileRingCosTable / ganMissileRingYOffsets,
        // read from 1.14d Game.exe): 64 evenly-spaced dirs on a radius-30 circle. n=64 (Nova) is exact;
        // fewer (Poison Explosion 8) sample every 64/n-th entry -> the same real angular positions.
        const idx = (i * NOVA_RING_DIRS) / n;
        const tx = ox + NOVA_RING_COS[idx];
        const ty = oy + NOVA_RING_Y[idx];
        var m = missile.Missile.create(md, caster_id, ox, oy, tx, ty, 0, 0);
        m.caster_derived = true;
        m.elem_cast = elem_cast.seal();
        out[i] = m;
    }
    return n;
}

/// A direction vector (x,y) on the engine's radius-30 ring for angle index `idx` (masked to 0..63).
/// Same table the Frozen-Orb emitter (Missiles_SrvDoFunc_015) uses via gnMissileSrvSpreadTable — the
/// host rotates `idx` by the missile's Param2 each emission to spiral the sub-bolts.
pub fn ringDir(idx: usize) [2]i32 {
    const i = idx & (NOVA_RING_DIRS - 1);
    return .{ NOVA_RING_COS[i], NOVA_RING_Y[i] };
}

/// The engine's missile-ring direction tables, verbatim from 1.14d Game.exe: ganMissileRingCosTable
/// @0x6e1288 (X) and ganMissileRingYOffsets @0x6e1388 (Y) — 64 points on a radius-30 circle (x²+y²=900),
/// the exact angular offsets SKILLS_CreateMissileRing spawns Nova's 64 missiles along.
const NOVA_RING_DIRS = 64;
const NOVA_RING_COS = [NOVA_RING_DIRS]i32{
    30, 29, 29, 28, 27, 26, 24, 23, 21, 19, 16, 14, 11, 8, 5, 2, 0, -2, -5, -8, -11, -14, -16, -19,
    -21, -23, -24, -26, -27, -28, -29, -29, -30, -29, -29, -28, -27, -26, -24, -23, -21, -19, -16,
    -14, -11, -8, -5, -2, 0, 2, 5, 8, 11, 14, 16, 19, 21, 23, 24, 26, 27, 28, 29, 29,
};
const NOVA_RING_Y = [NOVA_RING_DIRS]i32{
    0, 2, 5, 8, 11, 14, 16, 19, 21, 23, 24, 26, 27, 28, 29, 29, 30, 29, 29, 28, 27, 26, 24, 23, 21,
    19, 16, 14, 11, 8, 5, 2, 0, -2, -5, -8, -11, -14, -16, -19, -21, -23, -24, -26, -27, -28, -29,
    -29, -30, -29, -29, -28, -27, -26, -24, -23, -21, -19, -16, -14, -11, -8, -5, -2,
};

/// Blessed Hammer's spiral-grid spawn — a FAITHFUL port of SKILLS_CreateMissileSpiralGrid (1.14d Game.exe
/// @0x004c71f0, offset tables read straight from the binary at 0x6dadc0..0x6dae54). It launches up to
/// `level-1` hammers of the skill's srvmissilea at fixed grid offsets around the caster, each flying
/// outward. First hammer at (14,-14); then, per ring r (0..6) it emits, for each of 4 grid directions g
/// (while budget remains): (gridA[g]*ringB[r], gridB[g]*ringA[r]) and (gridA[g]*ringA[r], gridB[g]*ringB[r])
/// costing 2, then one outer hammer (Xouter[r], Youter[r]) costing 1. Fills `out`, returns the count.
pub fn castBlessedHammer(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster_id: u32,
    skill_id: u16,
    cx: i32,
    cy: i32,
    level: i32,
    elem_cast: spell.Cast,
    out: []missile.Missile,
) usize {
    const row = skills.rowById(skill_id) orelse return 0;
    const md = missiles.byName(skills.table.get(row, "srvmissilea")) orelse return 0;
    const gridA = [4]i32{ -1, 1, 1, -1 };
    const gridB = [4]i32{ -1, -1, 1, 1 };
    const ringA = [7]i32{ 8, 2, 11, 4, 13, 6, 9 };
    const ringB = [7]i32{ 18, 20, 17, 20, 15, 19, 18 };
    const x_outer = [7]i32{ 20, -20, 0, 0, 14, -14, -14 };
    const y_outer = [7]i32{ 0, 0, 20, -20, 14, 14, -14 };

    var n: usize = 0;
    const emit = struct {
        fn go(md_: missile.MissileData, owner: u32, ox: i32, oy: i32, sx: i32, sy: i32, ecast: spell.Cast, buf: []missile.Missile, np: *usize) void {
            if (np.* >= buf.len) return;
            // Launch from the caster through the offset point so the hammer flies outward along it.
            var m = missile.Missile.create(md_, owner, sx, sy, sx + ox * 2, sy + oy * 2, 0, 0);
            m.caster_derived = true;
            m.elem_cast = ecast.seal();
            buf[np.*] = m;
            np.* += 1;
        }
    }.go;

    emit(md, caster_id, 14, -14, cx, cy, elem_cast, out, &n);
    var remaining: i32 = level - 1;
    var r: usize = 0;
    while (r < 7 and remaining > 0) : (r += 1) {
        var g: usize = 0;
        while (g < 4 and remaining >= 1) : (g += 1) {
            emit(md, caster_id, gridA[g] * ringB[r], gridB[g] * ringA[r], cx, cy, elem_cast, out, &n);
            emit(md, caster_id, gridA[g] * ringA[r], gridB[g] * ringB[r], cx, cy, elem_cast, out, &n);
            remaining -= 2;
        }
        emit(md, caster_id, x_outer[r], y_outer[r], cx, cy, elem_cast, out, &n);
        remaining -= 1;
    }
    return n;
}

/// Cast a MISSILE FAN (srvdofunc 8: Multiple Shot / Teeth — N projectiles spread toward the target).
/// Faithful to Skills_SrvDoFunc_008_StrafeMissileSpread: `count` (= the skill's calc1) missiles of the
/// skill's `srvmissilea`, aimed at points spread PERPENDICULAR to the caster->target direction so they
/// fan out toward the target, each carrying `elem_cast`. `spacing` is the perpendicular step between
/// adjacent aim points (the exact engine value lives in SKILLS_NormalizeDirectionPerp geometry, not a
/// column — the caller passes a documented approximation). Fills `out`, returns how many were written.
pub fn castSpreadMissiles(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster_id: u32,
    skill_id: u16,
    sx: i32,
    sy: i32,
    tx: i32,
    ty: i32,
    count: usize,
    spacing: i32,
    elem_cast: spell.Cast,
    out: []missile.Missile,
) usize {
    const row = skills.rowById(skill_id) orelse return 0;
    const md = missiles.byName(skills.table.get(row, "srvmissilea")) orelse return 0;
    const n = @min(count, out.len);
    const dx: f64 = @floatFromInt(tx - sx);
    const dy: f64 = @floatFromInt(ty - sy);
    const len = @sqrt(dx * dx + dy * dy);
    // Perpendicular unit vector to the aim direction (fallback to the x-axis if source == target).
    const px: f64 = if (len > 0) -dy / len else 0;
    const py: f64 = if (len > 0) dx / len else 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const off: f64 = (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(n - 1)) / 2.0) * @as(f64, @floatFromInt(spacing));
        const ax = tx + @as(i32, @intFromFloat(@round(px * off)));
        const ay = ty + @as(i32, @intFromFloat(@round(py * off)));
        // Elemental fan (Teeth = magic): the missile is caster-derived and resolves its element per
        // victim. Physical fan (Multiple Shot arrows): a flat missile carrying the srvmissilea damage.
        var m = missile.Missile.create(md, caster_id, sx, sy, ax, ay, md.min_damage, md.max_damage);
        if (elem_cast.dmg.etype != .none) {
            m.caster_derived = true;
            m.elem_cast = elem_cast.seal();
        }
        out[i] = m;
    }
    return n;
}
