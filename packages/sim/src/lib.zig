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
pub const spell = @import("spell.zig");
pub const montable = @import("montable.zig");
pub const monskill = @import("monskill.zig");
pub const missile = @import("missile.zig");
pub const select = @import("select.zig");
pub const ai = @import("ai.zig");
pub const character = @import("character.zig");
pub const derive = @import("derive.zig");
pub const difficulty = @import("difficulty.zig");
pub const calc = @import("calc.zig");
pub const buff = @import("buff.zig");
pub const net = @import("net/net.zig");
pub const skills_barbarian = @import("skills_barbarian.zig");
pub const skills_amazon = @import("skills_amazon.zig");
pub const skills_druid = @import("skills_druid.zig");
pub const skills_paladin = @import("skills_paladin.zig");
pub const skills_assassin = @import("skills_assassin.zig");
pub const skills_necromancer = @import("skills_necromancer.zig");
pub const monster_monprop = @import("monster_monprop.zig");
pub const monster_umods = @import("monster_umods.zig");

pub const Seed = rng.Seed;
pub const Stat = stat.Stat;
pub const StatList = stat.StatList;
pub const Unit = unit.Unit;
pub const UnitType = unit.UnitType;
pub const Weapon = unit.Weapon;
pub const applyItemStats = unit.applyItemStats;
pub const AttackResult = combat.AttackResult;
pub const resolveAttack = combat.resolveAttack;
pub const chanceToHit = combat.chanceToHit;
pub const blockChance = combat.blockChance;
pub const resolveMonsterAttack = combat.resolveMonsterAttack;
pub const MonsterAttack = combat.MonsterAttack;
pub const initMonsterStats = combat.initMonsterStats;
pub const monsterAttackFrom = combat.monsterAttackFrom;
pub const MonCombatTables = montable.Tables;
pub const ScaledCombat = montable.ScaledCombat;
pub const Difficulty = montable.Difficulty;
pub const Skills = skill.Skills;
pub const Missiles = missile.Missiles;
pub const Missile = missile.Missile;
pub const AiConfig = ai.AiConfig;
pub const MonsterAI = ai.MonsterAI;
pub const AiAction = ai.AiAction;
pub const CharSave = character.CharSave;
pub const QuestState = character.QuestState;
pub const SorcColdBuild = character.SorcColdBuild;
pub const Element = spell.Element;
pub const ElementalDamage = spell.ElementalDamage;
pub const Cast = spell.Cast;
pub const ResistProfile = spell.ResistProfile;
pub const applyResist = spell.applyResist;
pub const deriveLifeMana = derive.derive;
pub const CharStats = derive.CharStats;
pub const resistPenalty = difficulty.resistPenalty;

test {
    _ = rng;
    _ = stat;
    _ = unit;
    _ = combat;
    _ = txt;
    _ = skill;
    _ = spell;
    _ = montable;
    _ = monskill;
    _ = missile;
    _ = select;
    _ = ai;
    _ = character;
    _ = derive;
    _ = difficulty;
    _ = calc;
    _ = buff;
    _ = net;
    _ = skills_barbarian;
    _ = skills_amazon;
    _ = skills_druid;
    _ = skills_assassin;
    _ = skills_paladin;
    _ = skills_necromancer;
    _ = monster_monprop;
    _ = monster_umods;
}
