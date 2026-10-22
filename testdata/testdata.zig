//! The test data every libd2 package and binding shares, in one place: character saves, kit specs and
//! the item-drawing fixtures. Zig packages import this module (a lazy path dependency, so a consumer
//! fetching a package never needs it); the Go, .NET, Rust and npm tests read the same files by their
//! path from the repository root.

/// The seed characters of the realm's test accounts, played in the 1.14d engine: a level 99 Sorceress
/// and a level 91 Amazon.
pub const epic_sorc = @embedFile("saves/EpicSorc.d2s");
pub const epic_ama = @embedFile("saves/EpicAma.d2s");

/// charkit specs: a played paladin's build, and the item-drawing golden character.
pub const paladin_kit = @embedFile("kits/paladin.kit");
pub const golden_kit = @embedFile("kits/golden.kit");
