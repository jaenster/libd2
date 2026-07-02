//! d2-sim public library API — the faithful D2 1.14d runtime game SIMULATION.
//!
//! Sibling to the standalone content libs d2-drlg (map generation) and d2-items
//! (item generation); d2-sim is the STATEFUL runtime that composes them. Same
//! philosophy: faithful-to-Ghidra, pure Zig (no C, no @cImport), seeded +
//! verifiable. Ported from the reconstructed 1.14d Game.exe (Ghidra 62fbfe69);
//! every ported function cites its 1.14d address.
//!
//! This first pass ships the COMBAT CORE (physical attack resolution) on top of a
//! minimal unit-stat foundation. Skills, missiles, AI, elemental/DOT damage,
//! blocking and PvP are explicit follow-ups (see the module TODOs).

const std = @import("std");

pub const rng = @import("rng.zig");
pub const stat = @import("stat.zig");
pub const unit = @import("unit.zig");
pub const combat = @import("combat.zig");
pub const txt = @import("txt.zig");
pub const skill = @import("skill.zig");
pub const missile = @import("missile.zig");
pub const net = @import("net/net.zig");

pub const Seed = rng.Seed;
pub const Stat = stat.Stat;
pub const StatList = stat.StatList;
pub const Unit = unit.Unit;
pub const UnitType = unit.UnitType;
pub const Weapon = unit.Weapon;
pub const AttackResult = combat.AttackResult;
pub const resolveAttack = combat.resolveAttack;
pub const Skills = skill.Skills;
pub const Missiles = missile.Missiles;
pub const Missile = missile.Missile;

test {
    _ = rng;
    _ = stat;
    _ = unit;
    _ = combat;
    _ = txt;
    _ = skill;
    _ = missile;
    _ = net;
}
