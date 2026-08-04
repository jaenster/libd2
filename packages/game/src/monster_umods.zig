//! Monster unique/champion modifier definitions — faithful comptime port of D2 1.14d
//! MonUMod.txt. Every numeric field comes from the real table (via ctsv) or from the
//! 1.14d reconstructed C (D2Common/Monsters.cpp) with a citation.
//!
//! Recon reference: D2Common/Monsters.cpp, 1.14d Game.exe (Ghidra session 62fbfe69).
//!
//! The table exposes:
//!   - Row: the full per-modifier record with id/enabled/version/xfer/champion/fPick/
//!           exclude1/exclude2/cpick/cpickN/cpickH/upick/upickN/upickH/constants.
//!   - rows[]: comptime array of all 43 MonUMod.txt entries, indexed by id.
//!   - byName(name): look up a row by uniquemod string, comptime or runtime.
//!   - IDX_ELEM_*_DMG_PCT: row indices the engine uses as flat constant array
//!     in MONSTER_SetElementalDamageFromLevel (D2Common/Monsters.cpp:1046-1191).

const std = @import("std");
const ctsv = @import("ctsv.zig");
const d2data = @import("d2-data");

// ---------------------------------------------------------------------------
// Row struct — one entry per MonUMod.txt row.
// fPick values: 0 = no filter, 1 = boss-type only (GetSomeMonsterStatFlag 4),
//               2 = ranged-capable (not isMelee && not nomultishot),
//               3 = can-be-on-target (GetSomeMonsterStatFlag 2).
// Cited: MONSTER_CanApplyUniqueModifier @005a03e0, D2Common/Monsters.cpp:320-394.
// ---------------------------------------------------------------------------

pub const Row = struct {
    /// `uniquemod` column — the string key used in code.
    name: []const u8,
    /// `id` column — 0-based row index used as the stored byte value in MonUModList.
    id: u8,
    /// `enabled` column — 0 disables entirely (e.g. "thief" = 0).
    enabled: bool,
    /// `version` column — >99 requires expansion (bExpansion) to be eligible.
    version: u16,
    /// `xfer` column — 1 = modifier is transferable to minions.
    xfer: bool,
    /// `champion` column — 1 = only champion rolls (not unique random rolls).
    champion: bool,
    /// `fPick` column — monster filter (see MONSTER_CanApplyUniqueModifier).
    f_pick: u8,
    /// `exclude1` / `exclude2` columns — MonType name that blocks this modifier.
    /// The engine resolves this to a MonType id at runtime (MONSTER_CheckMonTypeHasFlag).
    /// Cited: MONSTER_CanApplyUniqueModifier @005a03e0, D2Common/Monsters.cpp:328-341.
    /// Most rows have empty excludes; "lightning" (id=17) excludes "sandleaper".
    exclude1: []const u8,
    exclude2: []const u8,
    /// `cpick` / `cpick (N)` / `cpick (H)` — champion pick weight per difficulty.
    cpick: u16,
    cpick_n: u16,
    cpick_h: u16,
    /// `upick` / `upick (N)` / `upick (H)` — unique pick weight per difficulty.
    upick: u16,
    upick_n: u16,
    upick_h: u16,
    /// `constants` column — engine-indexed constant (see *constant desc comments).
    /// The engine's MONSTER_SetElementalDamageFromLevel reads
    ///   pTxtMonUmod[0x1c].constants (= stoneskin, 66)  as unique +elem-min-dmg%
    ///   pTxtMonUmod[0x1f].constants (= goboom,    100) as unique +elem-max-dmg%
    /// Cited: D2Common/Monsters.cpp:1046-1057 / 1112-1123 / 1180-1191.
    constants: i32,
};

// ---------------------------------------------------------------------------
// MonUMod.txt row names in id order (same sequence as the txt file).
// ---------------------------------------------------------------------------

const ROW_NAMES = [_][]const u8{
    "none",           "rndname",    "hpmultiply",           "light",
    "leveladd",       "strong",     "fast",                 "curse",
    "resist",         "fire",       "poisondead",           "durieldead",
    "bloodraven",     "rage",       "spcdamage",            "partydead",
    "champion",       "lightning",  "cold",                 "hireable",
    "scarab",         "killself",   "questcomplete",        "poisonhit",
    "thief",          "manahit",    "teleport",             "spectralhit",
    "stoneskin",      "multishot",  "aura",                 "goboom",
    "firespike_explode", "suicideminion_explode", "ai_after_death", "shatter_on_death",
    "ghostly",        "fanatic",    "possessed",            "berserk",
    "worms_on_death", "always_run_ai", "lightningdeath",
};

// ---------------------------------------------------------------------------
// Comptime table builder — branch quota set here to cover the per-row lookups.
// ---------------------------------------------------------------------------

fn buildRows() [ROW_NAMES.len]Row {
    // 43 rows × ~15 named-column scans, each scanning ~19 header fields with std.mem.trim.
    @setEvalBranchQuota(4_000_000);

    const txt = d2data.file("MonUMod");
    const h = ctsv.header(txt);

    var out: [ROW_NAMES.len]Row = undefined;
    for (ROW_NAMES, 0..) |name, i| {
        const row = ctsv.findRow(txt, name) orelse @compileError("MonUMod.txt: row not found: " ++ name);

        // exclude1/exclude2 are MonType name strings (not integers); extract raw cell.
        const excl1 = cellStrOf(h, row, "exclude1");
        const excl2 = cellStrOf(h, row, "exclude2");

        out[i] = .{
            .name      = name,
            .id        = @intCast(ctsv.cellInt(h, row, "id")),
            .enabled   = ctsv.cellInt(h, row, "enabled") != 0,
            .version   = @intCast(ctsv.cellInt(h, row, "version")),
            .xfer      = ctsv.cellInt(h, row, "xfer") != 0,
            .champion  = ctsv.cellInt(h, row, "champion") != 0,
            .f_pick    = @intCast(ctsv.cellInt(h, row, "fPick")),
            .exclude1  = excl1,
            .exclude2  = excl2,
            .cpick     = @intCast(ctsv.cellInt(h, row, "cpick")),
            .cpick_n   = @intCast(ctsv.cellInt(h, row, "cpick (N)")),
            .cpick_h   = @intCast(ctsv.cellInt(h, row, "cpick (H)")),
            .upick     = @intCast(ctsv.cellInt(h, row, "upick")),
            .upick_n   = @intCast(ctsv.cellInt(h, row, "upick (N)")),
            .upick_h   = @intCast(ctsv.cellInt(h, row, "upick (H)")),
            .constants = ctsv.cellInt(h, row, "constants"),
        };
    }
    return out;
}

/// Raw string value of column `col` in a tab-separated row. Empty cell => "".
fn cellStrOf(comptime h: []const u8, comptime row: []const u8, comptime col: []const u8) []const u8 {
    const idx = ctsv.columnIndex(h, col) orelse @compileError("MonUMod.txt: no column " ++ col);
    var fields = std.mem.splitScalar(u8, row, '\t');
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i == idx) return std.mem.trimEnd(u8, f, "\r");
    }
    return "";
}

// ---------------------------------------------------------------------------
// Public table — indexed by id (0-based, same as MonUMod.txt `id` column).
// ---------------------------------------------------------------------------

pub const rows: [ROW_NAMES.len]Row = buildRows();

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Look up a modifier row by uniquemod name. Returns null if not found.
pub fn byName(name: []const u8) ?*const Row {
    for (&rows) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// Return the row for a given id byte (0-based, as stored in MonUModList).
/// Returns null for out-of-range ids.
pub fn byId(id: u8) ?*const Row {
    if (id >= rows.len) return null;
    return &rows[id];
}

// ---------------------------------------------------------------------------
// Engine constant indices — cited from D2Common/Monsters.cpp.
// MONSTER_SetElementalDamageFromLevel @005a21d0 reads these rows' `constants`
// field as a flat array to derive elemental enchant damage percentages.
// ---------------------------------------------------------------------------

/// Index 0x1c (28) = stoneskin. constants=66 = unique +elem min dmg%.
/// Cited: D2Common/Monsters.cpp:1046, 1112, 1180.
pub const IDX_ELEM_MIN_DMG_PCT: usize = 0x1c;
/// Index 0x1f (31) = goboom. constants=100 = unique +elem max dmg%.
/// Cited: D2Common/Monsters.cpp:1055, 1122, 1190.
pub const IDX_ELEM_MAX_DMG_PCT: usize = 0x1f;

// ---------------------------------------------------------------------------
// Tests — all values cross-checked against MonUMod.txt via awk, never circular.
// ---------------------------------------------------------------------------

test "row count matches table" {
    try std.testing.expectEqual(@as(usize, 43), rows.len);
}

test "row ids are sequential" {
    for (rows, 0..) |r, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), r.id);
    }
}

test "none row" {
    // awk 'NR==2' MonUMod.txt: none, id=0, enabled=0, version=0, xfer=1, constants=20
    const r = byName("none").?;
    try std.testing.expectEqual(@as(u8, 0), r.id);
    try std.testing.expectEqual(false, r.enabled);
    try std.testing.expectEqual(true, r.xfer);
    try std.testing.expectEqual(@as(i32, 20), r.constants);
}

test "strong: xfer=1, upick=6 across all difficulties" {
    // awk 'NR==7' MonUMod.txt: strong, id=5, enabled=1, champion=0, xfer=1, upick=6,6,6
    const r = byName("strong").?;
    try std.testing.expectEqual(@as(u8, 5), r.id);
    try std.testing.expectEqual(true, r.enabled);
    try std.testing.expectEqual(false, r.champion);
    try std.testing.expectEqual(true, r.xfer);
    try std.testing.expectEqual(@as(u16, 6), r.upick);
    try std.testing.expectEqual(@as(u16, 6), r.upick_n);
    try std.testing.expectEqual(@as(u16, 6), r.upick_h);
}

test "fast: fPick=3 (ranged gate), cpick=0, upick=6" {
    // awk 'NR==8' MonUMod.txt: fast, id=6, fPick=3, cpick=0,0,0, upick=6,6,6
    const r = byName("fast").?;
    try std.testing.expectEqual(@as(u8, 6), r.id);
    try std.testing.expectEqual(@as(u8, 3), r.f_pick);
    try std.testing.expectEqual(@as(u16, 0), r.cpick);
    try std.testing.expectEqual(@as(u16, 6), r.upick);
}

test "champion: champion=1, cpick=1 each difficulty, upick=0" {
    // awk 'NR==18' MonUMod.txt: champion, id=16, champion=1, cpick=1,1,1, upick=0
    const r = byName("champion").?;
    try std.testing.expectEqual(@as(u8, 16), r.id);
    try std.testing.expectEqual(true, r.champion);
    try std.testing.expectEqual(@as(u16, 1), r.cpick);
    try std.testing.expectEqual(@as(u16, 1), r.cpick_n);
    try std.testing.expectEqual(@as(u16, 1), r.cpick_h);
    try std.testing.expectEqual(@as(u16, 0), r.upick);
}

test "lightning: exclude1=sandleaper" {
    // awk 'NR==19' MonUMod.txt: lightning, id=17, exclude1=sandleaper
    const r = byName("lightning").?;
    try std.testing.expectEqual(@as(u8, 17), r.id);
    try std.testing.expectEqualStrings("sandleaper", r.exclude1);
}

test "thief: disabled (enabled=0)" {
    // awk 'NR==26' MonUMod.txt: thief, id=24, enabled=0
    const r = byName("thief").?;
    try std.testing.expectEqual(@as(u8, 24), r.id);
    try std.testing.expectEqual(false, r.enabled);
}

test "stoneskin: elem min dmg constant=66" {
    // awk 'NR==30' MonUMod.txt: stoneskin, id=28, constants=66 (unique +elem min dmg%)
    try std.testing.expectEqual(@as(usize, 28), IDX_ELEM_MIN_DMG_PCT);
    try std.testing.expectEqual(@as(i32, 66), rows[IDX_ELEM_MIN_DMG_PCT].constants);
}

test "goboom: elem max dmg constant=100" {
    // awk 'NR==33' MonUMod.txt: goboom, id=31, constants=100 (unique +elem max dmg%)
    try std.testing.expectEqual(@as(usize, 31), IDX_ELEM_MAX_DMG_PCT);
    try std.testing.expectEqual(@as(i32, 100), rows[IDX_ELEM_MAX_DMG_PCT].constants);
}

test "byId round-trip" {
    const r = byId(7).?;
    try std.testing.expectEqualStrings("curse", r.name);
    try std.testing.expectEqual(@as(u8, 7), r.id);
    try std.testing.expectEqual(@as(i32, 300), r.constants);
}

test "byId out of range returns null" {
    try std.testing.expectEqual(@as(?*const Row, null), byId(255));
}
