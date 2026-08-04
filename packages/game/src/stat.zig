//! Re-export of the canonical Stat model, now owned by d2-core. Kept as a thin
//! file so sim's internal `@import("stat.zig")` sites resolve unchanged.
const stat = @import("d2-core").stat;

pub const Stat = stat.Stat;
pub const NUM_STATS = stat.NUM_STATS;
pub const StatList = stat.StatList;
