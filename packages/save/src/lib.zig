//! d2-save — the `.d2s` character-save format.
//!
//! Owns everything section-level in a played save: the marker-delimited quests ("Woo!"),
//! waypoints ("WS"), NPC intros ("w4"), attributes ("gf"), skills ("if") and items ("JM"),
//! for both reading and writing. The fixed 335-byte header stays in d2-formats — a realm
//! server lists characters from headers alone and must not link the item codec or the excel
//! tables to do it — and is re-exported here as `header` for convenience.
//!
//! Pure over byte slices: no filesystem, no allocator, no libc. The host reads and writes the
//! bytes; d2-game maps the result onto its unit/stat model.

const std = @import("std");

pub const sections = @import("sections.zig");
/// The pre-1.09 body. A different file format rather than a variant of `sections`, so it is a
/// separate reader — see the header comment there for what actually differs.
pub const old_sections = @import("old_sections.zig");
/// Whole-save conversion between the two layouts. Items are refused across the boundary — the
/// engine selects the item format by save version.
pub const convert = @import("convert.zig");
pub const attributes = @import("attributes.zig");

/// The fixed .d2s header (d2-formats `d2s`): the 335-byte struct, signature/version,
/// checksum + validation, and the fresh-character builder.
pub const header = sections.d2s;

/// The per-item bit codec (d2-core `wire`): `parseSave` / `Item` / `Quality`.
pub const wire = sections.wire;

pub const Save = sections.Save;
pub const Header = sections.d2s.Header;
pub const Quests = sections.Quests;
pub const Waypoints = sections.Waypoints;
pub const Npcs = sections.Npcs;
pub const Skills = sections.Skills;
pub const Items = sections.Items;
pub const Difficulty = sections.Difficulty;
pub const Attributes = attributes.Attributes;
pub const ParseError = sections.ParseError;

pub const parse = sections.parse;
pub const OldSave = old_sections.Save;
/// Read a pre-1.09 save. Takes the class's skill count because that is what sizes the skill
/// section and therefore where the item list begins.
pub const parseOld = old_sections.parse;
pub const parseAttributes = attributes.parseAttributes;
pub const checksum = sections.d2s.checksum;
pub const fixChecksum = sections.d2s.fixChecksum;
pub const validate = sections.d2s.validate;
pub const newSave = sections.d2s.newSave;

test {
    _ = sections;
    _ = old_sections;
    _ = convert;
    _ = attributes;
    _ = @import("tests.zig");
}
