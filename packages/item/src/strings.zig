//! The game's string tables looked up by key, the way the .txt loaders do it: every excel name
//! column (a unique's `index`, a prefix's `Name`, an ItemStatCost `descstrpos`) is a key into
//! string.tbl / expansionstring.tbl / patchstring.tbl, and the patch table wins over the
//! expansion table, which wins over the base. A key with no entry shows as itself.
//!
//! Layout (see d2-formats strtbl.zig for the by-id side): header 0x15 bytes, u16 index[count],
//! then `hash_size` entries of 17 bytes: used u8, id u16, hash u32, key offset u32, string
//! offset u32, length u16.

const std = @import("std");
const d2data = @import("d2-data");

pub const Strings = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.heap.ArenaAllocator,

    pub fn load(gpa: std.mem.Allocator) !Strings {
        var s = Strings{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer s.arena.deinit();
        // Lowest priority first, so later tables overwrite earlier ones.
        try s.add(d2data.strings.base);
        try s.add(d2data.strings.expansion);
        try s.add(d2data.strings.patch);
        return s;
    }

    pub fn deinit(self: *Strings) void {
        self.arena.deinit();
    }

    fn add(self: *Strings, bytes: []const u8) !void {
        const a = self.arena.allocator();
        if (bytes.len < 0x15) return error.BadStringTable;
        const count = std.mem.readInt(u16, bytes[2..4], .little);
        const hash_size = std.mem.readInt(u32, bytes[4..8], .little);
        const first = 0x15 + @as(usize, count) * 2;
        var i: usize = 0;
        while (i < hash_size) : (i += 1) {
            const at = first + i * 17;
            if (at + 17 > bytes.len) return error.BadStringTable;
            if (bytes[at] != 1) continue;
            const key_off = std.mem.readInt(u32, bytes[at + 7 ..][0..4], .little);
            const str_off = std.mem.readInt(u32, bytes[at + 11 ..][0..4], .little);
            if (key_off >= bytes.len or str_off >= bytes.len) continue;
            const key_end = std.mem.indexOfScalarPos(u8, bytes, key_off, 0) orelse continue;
            const str_end = std.mem.indexOfScalarPos(u8, bytes, str_off, 0) orelse continue;
            try self.map.put(a, bytes[key_off..key_end], bytes[str_off..str_end]);
        }
    }

    /// The text for `key`, or null when no table has it.
    pub fn find(self: *const Strings, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// The text for `key`, or the key itself when no table has it (what the game shows).
    pub fn get(self: *const Strings, key: []const u8) []const u8 {
        return self.map.get(key) orelse key;
    }
};

test "keys resolve through the layered tables" {
    var s = try Strings.load(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqualStrings("Annihilus", s.get("Annihilus"));
    try std.testing.expectEqualStrings("Enigma", s.get("Runeword33"));
    try std.testing.expect(s.find("ModStr1a") != null);
}

const patch_bias: u16 = 0xd8f0;
const expansion_bias: u16 = 0xb1e0;

fn byIndex(bytes: []const u8, id: u16) ?[]const u8 {
    if (bytes.len < 0x15) return null;
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    const hash_size = std.mem.readInt(u32, bytes[4..8], .little);
    if (id >= count) return null;
    const slot = std.mem.readInt(u16, bytes[0x15 + @as(usize, id) * 2 ..][0..2], .little);
    if (slot >= hash_size) return null;
    const at = 0x15 + @as(usize, count) * 2 + @as(usize, slot) * 17;
    if (at + 17 > bytes.len or bytes[at] != 1) return null;
    const str_off = std.mem.readInt(u32, bytes[at + 11 ..][0..4], .little);
    if (str_off >= bytes.len) return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, str_off, 0) orelse return null;
    return bytes[str_off..end];
}

/// The text for a numeric string id, routed as GetLocaleString does: ids from 20000 are looked
/// for in the expansion table, ids from 10000 in the patch table, and anything else (or a miss)
/// in the base table. The biases wrap in 16 bits on purpose.
pub fn byId(id: u16) ?[]const u8 {
    if (id >= 20000) if (byIndex(d2data.strings.expansion, id +% expansion_bias)) |s| return s;
    if (id >= 10000) if (byIndex(d2data.strings.patch, id +% patch_bias)) |s| return s;
    return byIndex(d2data.strings.base, id);
}

test "ids route to the right table" {
    try std.testing.expect(byId(0x6b2) != null);
    try std.testing.expectEqualStrings("Enigma", byId(20539).?);
}
