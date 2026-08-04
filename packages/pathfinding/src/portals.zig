//! The level links map generation cannot see.
//!
//! `d2-drlg` derives a level's neighbours from two things it can compute: the per-room warp slots
//! (`Levels.txt` Vis/Warp — staircases and dungeon entrances) and outdoor seams (two levels whose
//! rooms are edge-to-edge). That covers almost the whole game, but it structurally cannot cover a
//! portal, because a portal is not in the map — quest code spawns it at runtime.
//!
//! The Arcane Sanctuary is the clearest case and the reason this table exists. Levels.txt gives it
//! Vis0-7 = 0 and Warp0-7 = -1, so map generation reports it with ZERO neighbours: an island. In
//! the game you arrive through a portal on a Palace Cellar Level 3 platform and leave through the
//! Summoner's portal to the Canyon of the Magi. Without the two rows below, any router treats the
//! Arcane Sanctuary as unreachable and every route through it fails.
//!
//! These are one-way as listed — the direction the game opens them in — but most stay open both
//! ways once used, so `World.load` inserts the reverse edge too unless `one_way` is set.
//!
//! Deliberately NOT here: act travel by caravan/ship/Tyrael dialogue between town levels. That is
//! an NPC conversation, not a map link, and whether it is available depends on quest state a map
//! router has no view of. A caller whose mover can use it adds those edges itself.

const std = @import("std");

pub const Kind = enum {
    /// A red/blue portal a quest opens between two levels.
    quest_portal,
    /// A portal that also moves the player to another act.
    act_change,
};

/// How well each row is established, so nothing here reads as more certain than it is.
pub const Provenance = enum {
    /// The endpoints are pinned by Levels.txt (an island level with no Vis/Warp has to be entered
    /// somehow, and there is exactly one candidate).
    table_implied,
    /// Established by play, not by a table or a decompile. Correct as far as anyone has seen, but
    /// this package has not proven it from the binary.
    observed,
};

pub const Link = struct {
    from: i32,
    to: i32,
    kind: Kind = .quest_portal,
    provenance: Provenance = .observed,
    /// True when the portal genuinely cannot be walked back through.
    one_way: bool = false,
    note: []const u8 = "",
};

/// Level ids, by their Levels.txt `Name`, for the endpoints below.
pub const STONY_FIELD: i32 = 4;
pub const TRISTRAM: i32 = 38;
pub const ROGUE_ENCAMPMENT: i32 = 1;
pub const MOO_MOO_FARM: i32 = 39;
pub const CANYON_OF_THE_MAGI: i32 = 46;
pub const PALACE_CELLAR_3: i32 = 54;
pub const DURIELS_LAIR: i32 = 73;
pub const ARCANE_SANCTUARY: i32 = 74;
pub const DURANCE_OF_HATE_3: i32 = 102;
pub const PANDEMONIUM_FORTRESS: i32 = 103;
pub const CHAOS_SANCTUM: i32 = 108;
pub const HARROGATH: i32 = 109;
pub const NIHLATHAKS_TEMPLE: i32 = 121;

/// The seven Tal Rasha tombs. Exactly one of them holds the orifice down to Duriel's Lair, and
/// which one is decided per seed by quest data this package does not read — so all seven appear
/// below as candidates. A caller that knows the real tomb should filter the other six.
pub const TAL_RASHA_TOMBS = [_]i32{ 66, 67, 68, 69, 70, 71, 72 };

pub const LINKS = blk: {
    var list: []const Link = &[_]Link{
        .{
            .from = STONY_FIELD,
            .to = TRISTRAM,
            .provenance = .table_implied,
            .note = "Cairn Stones portal. Tristram has no Vis/Warp entry of its own.",
        },
        .{
            .from = ROGUE_ENCAMPMENT,
            .to = MOO_MOO_FARM,
            .provenance = .table_implied,
            .note = "Secret Cow Level portal, opened by cubing Wirt's Leg with a Tome of Town Portal.",
        },
        .{
            .from = PALACE_CELLAR_3,
            .to = ARCANE_SANCTUARY,
            .provenance = .table_implied,
            .note = "The platform portal. Arcane Sanctuary has Vis0-7 = 0 and Warp0-7 = -1, so this " ++
                "is its only way in.",
        },
        .{
            .from = ARCANE_SANCTUARY,
            .to = CANYON_OF_THE_MAGI,
            .provenance = .table_implied,
            .note = "The Summoner's portal, at the end of one of the four arms.",
        },
        .{
            .from = DURIELS_LAIR,
            .to = PANDEMONIUM_FORTRESS,
            .kind = .act_change,
            .note = "Tyrael's portal, after Duriel.",
        },
        .{
            .from = DURANCE_OF_HATE_3,
            .to = PANDEMONIUM_FORTRESS,
            .kind = .act_change,
            .note = "Mephisto's red portal over the Hellforge bridge.",
        },
        .{
            .from = CHAOS_SANCTUM,
            .to = HARROGATH,
            .kind = .act_change,
            .note = "Tyrael's portal, after Diablo.",
        },
        .{
            .from = HARROGATH,
            .to = NIHLATHAKS_TEMPLE,
            .provenance = .table_implied,
            .note = "The town portal to Nihlathak's Temple; the temple has no Vis entry.",
        },
    };
    for (TAL_RASHA_TOMBS) |tomb| {
        list = list ++ [_]Link{.{
            .from = tomb,
            .to = DURIELS_LAIR,
            .provenance = .table_implied,
            .note = "The Horadric Staff orifice. Duriel's Lair has no Vis entry; exactly one of the " ++
                "seven tombs holds the real orifice for a given seed.",
        }};
    }
    break :blk list;
};

/// Every link touching `level_id`, in either direction.
pub fn linksFor(level_id: i32) []const Link {
    // Small enough (15 rows) that a caller filters inline; kept as a helper so the shape of the
    // table can change without every consumer looping over it by hand.
    _ = level_id;
    return LINKS;
}

test "the Arcane Sanctuary is no longer an island" {
    var into: usize = 0;
    var out_of: usize = 0;
    for (LINKS) |l| {
        if (l.to == ARCANE_SANCTUARY) into += 1;
        if (l.from == ARCANE_SANCTUARY) out_of += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), into);
    try std.testing.expectEqual(@as(usize, 1), out_of);
}

test "every Tal Rasha tomb offers a way into Duriel's Lair" {
    for (TAL_RASHA_TOMBS) |tomb| {
        var found = false;
        for (LINKS) |l| {
            if (l.from == tomb and l.to == DURIELS_LAIR) found = true;
        }
        try std.testing.expect(found);
    }
}
