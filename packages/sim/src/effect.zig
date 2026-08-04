//! The resolve→apply spine. A pure resolver (sim.object.operate, sim.skill.resolve) turns a request
//! into a small list of `Effect`s; the host's applyEffect() is the ONLY place that mutates world
//! state. Effects are intent/area-scoped — the resolver decides WHAT, the host expands it over units
//! and owns spawning/timers/broadcast. This keeps the decision logic pure + testable and the host thin.

const missile = @import("missile.zig");
const shrines = @import("shrines.zig");

/// A crowd-control kind an area effect applies.
pub const CcKind = enum { stun, fear, chill };

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
    /// Stun hostiles within `radius` of (x,y) for `frames`; radius==0 stuns `target_guid` only.
    cc_area: struct { x: i32, y: i32, radius: i32, frames: u32, target_guid: u32 },
};
