//! Re-export of the canonical seed-RNG, now owned by d2-core. Kept as a thin file
//! so drlg's internal `@import("rng.zig")` sites resolve unchanged.
const rng = @import("d2-core").rng;

pub const Seed = rng.Seed;
pub const actStartSeed = rng.actStartSeed;
pub const levelSeed = rng.levelSeed;
pub const generateRandomSeed = rng.generateRandomSeed;
