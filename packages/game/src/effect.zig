//! The resolve→apply spine. A pure resolver (sim.object.operate, sim.skill.resolve) turns a request
//! into a small list of `Effect`s; the host's applyEffect() is the ONLY place that mutates world
//! state. Effects are intent/area-scoped — the resolver decides WHAT, the host expands it over units
//! and owns spawning/timers/broadcast. This keeps the decision logic pure + testable and the host thin.

const missile = @import("missile.zig");
const shrines = @import("shrines.zig");

/// A crowd-control kind an area effect applies.
pub const CcKind = enum { stun, fear, chill };

/// The placement/cap rule for a summoned unit.
pub const SummonKind = enum {
    pet, // pet-cap enforced, next to the caster (skeletons / valkyrie / druid pets)
    golem, // single golem, replaces the previous one
    trap, // pet-cap, stationary at the cursor (assassin sentries / Blade Sentinel)
    hydra_head, // stationary head at the cursor (Hydra spawns three)
};

/// One thing the host must do. Object resolvers emit the object arms; skill resolvers add theirs
/// during the retrofit. `guid == 0` on an area effect means "centred at the given (x,y)".
pub const Effect = union(enum) {
    /// Broadcast a new object/unit anim mode (0 Neutral, 1 Operating, 2 Opened, 3-7 special).
    set_anim_mode: struct { guid: u32, mode: u8 },
    /// Roll + spawn a lootable object's drop at (x,y).
    roll_drops: struct { x: i32, y: i32 },
    /// Grant a rolled shrine function's effect to the operator.
    grant_shrine: shrines.Effect,
    /// Re-enable a spent shrine/well `minutes` later (event type 5).
    schedule_reset: struct { guid: u32, minutes: i32 },
    /// Refill the operator's life+mana (wells; hardcoded, not Shrines.txt).
    refill_life_mana,
    /// Toggle a door open/closed.
    toggle_door: struct { guid: u32 },
    /// Activate a waypoint for the operator (reveal + enable travel).
    activate_waypoint: struct { guid: u32 },
    /// Move the operator to another level (portal / stairs / level-transition object).
    warp_level: struct { level_id: u16 },
    /// Open the operator's personal stash.
    open_stash,

    // --- skill arms (the castSkill retrofit migrates branches to these) ---
    /// Apply a curse's debuff (its aurastat) to every hostile monster within `radius` of (x,y),
    /// replacing any existing curse, for `duration` frames.
    curse_area: struct { x: i32, y: i32, radius: i32, skill_id: u16, level: i32, duration: i32 },
    /// Crowd-control hostiles within `radius` of (x,y) for `frames`; radius==0 hits `target_guid`
    /// only. `kind` selects stun / fear / chill.
    cc_area: struct { x: i32, y: i32, radius: i32, frames: u32, target_guid: u32, kind: CcKind },
    /// Make `skill_id` the caster's active aura (tickAuras applies it each frame).
    set_aura: struct { skill_id: u16 },
    /// Spawn a summon of MonStats `monster` at (x,y), owned by the caster. `kind` picks the
    /// placement/cap rules; `count` is the pet cap (pet/trap kinds).
    summon: struct { monster: []const u8, x: i32, y: i32, count: i32, kind: SummonKind },
    /// Drop a lingering AoE at (x,y) that pulses `skill_id`'s elemental damage each frame for
    /// `duration` frames (Fire Wall / Blaze / Blizzard / Volcano / Armageddon).
    ground_effect: struct { skill_id: u16, level: i32, x: i32, y: i32, duration: i32 },
    /// One-shot elemental burst on every hostile within `radius` of (x,y). `static` selects Static
    /// Field's %-of-current-life drain; otherwise the skill's staged element (Meteor / Fist of Heavens).
    elemental_area: struct { skill_id: u16, level: i32, x: i32, y: i32, radius: i32, static: bool },
    /// A weapon attack on `target_guid`: `hits` strikes at `ed_percent` enhanced damage. `reposition`
    /// first dashes onto the target (Charge / Dragon Flight); `use_melee_skill` routes through the
    /// multi-hit combat helper (Fend/Zeal) instead of a plain roll.
    weapon_strike: struct {
        target_guid: u32,
        skill_id: u16,
        ed_percent: i32,
        hits: i32,
        reposition: bool,
        use_melee_skill: bool,
    },
    /// Grant `skill_id` as a timed self-buff (Frozen Armor / Battle Orders / Enchant / …).
    buff_self: struct { skill_id: u16 },
    /// Toggle the caster's shapeshift form (Werewolf / Werebear / Delirium).
    shapeshift: struct { skill_id: u16 },
    /// A single-target poison damage-over-time (Poison Dagger).
    poison_dot: struct { target_guid: u32, skill_id: u16, level: i32 },
    /// Warp the caster to the act's town (Town Portal).
    warp_town,
    /// Consume the nearest corpse to (x,y) and do a corpse skill: `.explode` = Corpse Explosion (fire+
    /// physical AoE), `.poison_ring` = Poison Explosion (8-missile poison nova), `.revive` = Revive.
    corpse_skill: struct { x: i32, y: i32, skill_id: u16, level: i32, kind: enum { explode, poison_ring, revive } },
    /// Spawn the skill's missiles from (x,y) toward (tx,ty): `.spiral` = Blessed Hammer grid, `.spread`
    /// = a `count`-projectile fan (Multiple Shot / Charged Bolt / Guided Arrow, `homing` = seeking).
    spawn_missiles: struct { skill_id: u16, level: i32, x: i32, y: i32, tx: i32, ty: i32, count: u8, homing: bool, kind: enum { spiral, spread } },
    /// Move the caster to (x,y) (Leap / Whirlwind endpoint).
    reposition: struct { x: i32, y: i32 },
    /// Teleport the caster to (x,y) — or onto `guid` if set — through walls, mana/range-gated, and
    /// stream the jump to the casting client.
    teleport: struct { x: i32, y: i32, guid: u32 },
    /// A weapon attack on every hostile in an area. `sweep` = along the segment (from_x,from_y)->(x,y)
    /// within the melee reach (Whirlwind); otherwise within `radius` of (x,y) (Leap Attack landing).
    weapon_area: struct { x: i32, y: i32, radius: i32, ed_percent: i32, from_x: i32, from_y: i32, sweep: bool },
};
