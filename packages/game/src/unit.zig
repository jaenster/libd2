//! Re-export of the canonical Unit model, now owned by d2-core. Kept as a thin
//! file so sim's internal `@import("unit.zig")` sites (combat/skill/ai/missile/…) resolve
//! unchanged.
const unit = @import("d2-core").unit;

pub const Unit = unit.Unit;
pub const Collision = unit.Collision;
pub const MonsterOpts = unit.MonsterOpts;
pub const UnitType = unit.UnitType;
pub const Weapon = unit.Weapon;
pub const applyItemStats = unit.applyItemStats;
pub const NO_OWNER = unit.NO_OWNER;
