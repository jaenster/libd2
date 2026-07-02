//! Shared item-generation model types (clean-room, Zig-native — NOT the 32-bit
//! Game.exe ABI). These mirror the roles of D2ItemGenContextStrc and the drop
//! output, but with idiomatic Zig fields.

const std = @import("std");

/// D2 item quality tier (eD2ItemQuality). Values are the engine's — the quality
/// cascade and switch dispatch depend on these exact numbers.
pub const Quality = enum(u8) {
    invalid = 0,
    low = 1, // "crude/inferior"
    normal = 2,
    superior = 3, // "hiquality"
    magic = 4,
    set = 5,
    rare = 6,
    unique = 7,
    crafted = 8,
    tempered = 9,
    _,
};

/// What a single TreasureClass roll produced.
pub const DropKind = enum { none, gold, item, quiver, bodypart };

/// A rolled drop. `item_code` is the base item (weapon/armor/misc `code`) when
/// kind == .item. prefix/suffix ids are 1-based indices into MagicPrefix.txt /
/// MagicSuffix.txt (0 = none), faithful to the engine's `affixId+1` return.
pub const Drop = struct {
    kind: DropKind = .none,
    item_code: [4]u8 = .{ 0, 0, 0, 0 },
    quality: Quality = .invalid,
    prefix_id: u16 = 0, // magic/first-affix prefix
    suffix_id: u16 = 0, // magic/first-affix suffix
    rare_prefix_ids: [3]u16 = .{ 0, 0, 0 },
    rare_suffix_ids: [3]u16 = .{ 0, 0, 0 },
    sockets: u8 = 0,
    quantity: i32 = 0, // gold amount / quiver count
    item_level: i32 = 0,

    pub fn code(self: *const Drop) []const u8 {
        var n: usize = 0;
        while (n < 4 and self.item_code[n] != 0) : (n += 1) {}
        return self.item_code[0..n];
    }
};

/// Quality-modifier bonuses propagated down the TC recursion (TreasureClassEx
/// Magic/Rare/Set/Unique columns). These feed GAME_GetItemQuality as additive
/// bonuses on the corresponding tier chance.
pub const QualityMods = struct {
    magic: i32 = 0,
    rare: i32 = 0,
    set: i32 = 0,
    unique: i32 = 0,
};
