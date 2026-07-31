//! d2-data — the single authoritative home for the real 1.14d Blizzard excel game
//! tables, plus a generic TSV reader over them. The tables under excel/ are the
//! Patch_D2-overridden 1.14d bytes, extracted straight from the retail MPQs in
//! override order (Patch_D2 > d2exp > d2data) by tools/extract_excel.zig.
//!
//! This package OWNS the tables. It is meant to become the one source of truth the
//! drlg/sim/items packages consume (migration is a separate follow-up; today those
//! packages still carry their own src/excel copies).
//!
//! Every table is `@embedFile`d, so the loader is freestanding: it needs no
//! filesystem and cross-compiles to wasm. Open a table by name -> a parsed Table
//! with typed, header-named column access (see tsv.zig).

const std = @import("std");
pub const tsv = @import("tsv.zig");
pub const Table = tsv.Table;

const Embedded = struct { name: []const u8, bytes: []const u8 };

/// Every extracted 1.14d excel table, keyed by its logical name (the file stem).
/// Names are matched case-insensitively by `raw`/`load`.
pub const tables = [_]Embedded{
    .{ .name = "Armor", .bytes = @embedFile("excel/Armor.txt") },
    .{ .name = "AutoMap", .bytes = @embedFile("excel/AutoMap.txt") },
    .{ .name = "Belts", .bytes = @embedFile("excel/Belts.txt") },
    .{ .name = "BodyLocs", .bytes = @embedFile("excel/BodyLocs.txt") },
    .{ .name = "Books", .bytes = @embedFile("excel/Books.txt") },
    .{ .name = "CharStats", .bytes = @embedFile("excel/CharStats.txt") },
    .{ .name = "Colors", .bytes = @embedFile("excel/Colors.txt") },
    .{ .name = "CompCode", .bytes = @embedFile("excel/CompCode.txt") },
    .{ .name = "Composit", .bytes = @embedFile("excel/Composit.txt") },
    .{ .name = "CubeMain", .bytes = @embedFile("excel/CubeMain.txt") },
    .{ .name = "DifficultyLevels", .bytes = @embedFile("excel/DifficultyLevels.txt") },
    .{ .name = "ElemTypes", .bytes = @embedFile("excel/ElemTypes.txt") },
    .{ .name = "Events", .bytes = @embedFile("excel/Events.txt") },
    .{ .name = "Experience", .bytes = @embedFile("excel/Experience.txt") },
    .{ .name = "Gamble", .bytes = @embedFile("excel/Gamble.txt") },
    .{ .name = "Gems", .bytes = @embedFile("excel/Gems.txt") },
    .{ .name = "Hireling", .bytes = @embedFile("excel/Hireling.txt") },
    .{ .name = "Inventory", .bytes = @embedFile("excel/Inventory.txt") },
    .{ .name = "ItemRatio", .bytes = @embedFile("excel/ItemRatio.txt") },
    .{ .name = "ItemStatCost", .bytes = @embedFile("excel/ItemStatCost.txt") },
    .{ .name = "ItemTypes", .bytes = @embedFile("excel/ItemTypes.txt") },
    .{ .name = "Levels", .bytes = @embedFile("excel/Levels.txt") },
    .{ .name = "LowQualityItems", .bytes = @embedFile("excel/LowQualityItems.txt") },
    .{ .name = "LvlMaze", .bytes = @embedFile("excel/LvlMaze.txt") },
    .{ .name = "LvlPrest", .bytes = @embedFile("excel/LvlPrest.txt") },
    .{ .name = "LvlSub", .bytes = @embedFile("excel/LvlSub.txt") },
    .{ .name = "LvlTypes", .bytes = @embedFile("excel/LvlTypes.txt") },
    .{ .name = "LvlWarp", .bytes = @embedFile("excel/LvlWarp.txt") },
    .{ .name = "MagicPrefix", .bytes = @embedFile("excel/MagicPrefix.txt") },
    .{ .name = "MagicSuffix", .bytes = @embedFile("excel/MagicSuffix.txt") },
    .{ .name = "Misc", .bytes = @embedFile("excel/Misc.txt") },
    .{ .name = "MissCalc", .bytes = @embedFile("excel/MissCalc.txt") },
    .{ .name = "Missiles", .bytes = @embedFile("excel/Missiles.txt") },
    .{ .name = "MonAI", .bytes = @embedFile("excel/MonAI.txt") },
    .{ .name = "MonEquip", .bytes = @embedFile("excel/MonEquip.txt") },
    .{ .name = "MonLvl", .bytes = @embedFile("excel/MonLvl.txt") },
    .{ .name = "MonMode", .bytes = @embedFile("excel/MonMode.txt") },
    .{ .name = "MonPlace", .bytes = @embedFile("excel/MonPlace.txt") },
    .{ .name = "MonPreset", .bytes = @embedFile("excel/MonPreset.txt") },
    .{ .name = "MonProp", .bytes = @embedFile("excel/MonProp.txt") },
    .{ .name = "MonSeq", .bytes = @embedFile("excel/MonSeq.txt") },
    .{ .name = "MonSounds", .bytes = @embedFile("excel/MonSounds.txt") },
    .{ .name = "MonStats", .bytes = @embedFile("excel/MonStats.txt") },
    .{ .name = "MonStats2", .bytes = @embedFile("excel/MonStats2.txt") },
    .{ .name = "MonType", .bytes = @embedFile("excel/MonType.txt") },
    .{ .name = "MonUMod", .bytes = @embedFile("excel/MonUMod.txt") },
    .{ .name = "NPC", .bytes = @embedFile("excel/NPC.txt") },
    .{ .name = "ObjMode", .bytes = @embedFile("excel/ObjMode.txt") },
    .{ .name = "Objects", .bytes = @embedFile("excel/Objects.txt") },
    .{ .name = "Overlay", .bytes = @embedFile("excel/Overlay.txt") },
    .{ .name = "PetType", .bytes = @embedFile("excel/PetType.txt") },
    .{ .name = "Properties", .bytes = @embedFile("excel/Properties.txt") },
    .{ .name = "QualityItems", .bytes = @embedFile("excel/QualityItems.txt") },
    .{ .name = "RarePrefix", .bytes = @embedFile("excel/RarePrefix.txt") },
    .{ .name = "RareSuffix", .bytes = @embedFile("excel/RareSuffix.txt") },
    .{ .name = "Runes", .bytes = @embedFile("excel/Runes.txt") },
    .{ .name = "SetItems", .bytes = @embedFile("excel/SetItems.txt") },
    .{ .name = "Sets", .bytes = @embedFile("excel/Sets.txt") },
    .{ .name = "Shrines", .bytes = @embedFile("excel/Shrines.txt") },
    .{ .name = "SkillCalc", .bytes = @embedFile("excel/SkillCalc.txt") },
    .{ .name = "SkillDesc", .bytes = @embedFile("excel/SkillDesc.txt") },
    .{ .name = "Skills", .bytes = @embedFile("excel/Skills.txt") },
    .{ .name = "Sounds", .bytes = @embedFile("excel/Sounds.txt") },
    .{ .name = "States", .bytes = @embedFile("excel/States.txt") },
    .{ .name = "SuperUniques", .bytes = @embedFile("excel/SuperUniques.txt") },
    .{ .name = "TreasureClassEx", .bytes = @embedFile("excel/TreasureClassEx.txt") },
    .{ .name = "UniqueAppellation", .bytes = @embedFile("excel/UniqueAppellation.txt") },
    .{ .name = "UniqueItems", .bytes = @embedFile("excel/UniqueItems.txt") },
    .{ .name = "UniquePrefix", .bytes = @embedFile("excel/UniquePrefix.txt") },
    .{ .name = "UniqueSuffix", .bytes = @embedFile("excel/UniqueSuffix.txt") },
    .{ .name = "Weapons", .bytes = @embedFile("excel/Weapons.txt") },
    .{ .name = "objgroup", .bytes = @embedFile("excel/objgroup.txt") },
};

/// Comptime table bytes by exact file stem — resolves to a single `@embedFile` at the
/// call site, so it never references the `tables` array. This keeps lazy-decl DCE able
/// to drop the tables a consumer doesn't touch (critical for the wasm-targeted packages:
/// drlg/items link only the handful they name, not all 72 embeds). Prefer this over
/// `raw()` in a package that ships a wasm; `raw()`/`load()` (dynamic name) force-link
/// every table and are for native callers only.
pub inline fn file(comptime name: []const u8) []const u8 {
    return @embedFile("excel/" ++ name ++ ".txt");
}

/// Parse a comptime-named table into an owned Table (the DCE-friendly sibling of `load`).
pub fn open(gpa: std.mem.Allocator, comptime name: []const u8) !Table {
    return tsv.parse(gpa, file(name));
}

/// Raw file bytes for a table by name (case-insensitive), or null if absent.
/// The bytes are static (embedded); no allocation, no freeing.
pub fn raw(name: []const u8) ?[]const u8 {
    for (tables) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t.bytes;
    }
    return null;
}

pub fn has(name: []const u8) bool {
    return raw(name) != null;
}

/// Load + parse a table by name into an owned Table. Caller must `deinit()` it.
/// Returns error.UnknownTable if the name isn't one of the extracted tables.
pub fn load(gpa: std.mem.Allocator, name: []const u8) !Table {
    const bytes = raw(name) orelse return error.UnknownTable;
    return tsv.parse(gpa, bytes);
}
