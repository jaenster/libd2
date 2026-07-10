//! .d2s — the Diablo II character save file format (1.14d).
//!
//! Sibling to the other binary-format parsers here (ds1/dt1/dc6/dcc). This module decodes
//! the parts of a `.d2s` a server needs to materialize a character; it is a PURE format
//! reader — no filesystem, no runtime model. The host reads the bytes; the sim maps the
//! result onto its unit/stat model.
//!
//! A played save is: fixed header, then marker-delimited sections — quests ("Woo!"),
//! waypoints ("WS"), NPCs ("w4"), attributes ("gf"), skills ("if"), items ("JM"). This
//! pass reads the ATTRIBUTES section (the bit-packed stat list); the rest are TODO.

const std = @import("std");

/// LSB-first bit reader — the packing D2 uses for the attribute/item bitstreams (a
/// byte-aligned N*8-bit read equals a little-endian integer). Self-contained so this leaf
/// format package keeps no cross-package dependency.
const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    fn bitsLeft(self: *const BitReader) usize {
        const total = self.bytes.len * 8;
        return if (self.bit_pos >= total) 0 else total - self.bit_pos;
    }

    fn read(self: *BitReader, n: u6) u32 {
        var result: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const byte_idx = self.bit_pos >> 3;
            const bit_idx: u3 = @intCast(self.bit_pos & 7);
            const bit: u32 = if (byte_idx < self.bytes.len) (self.bytes[byte_idx] >> bit_idx) & 1 else 0;
            result |= bit << @intCast(i);
            self.bit_pos += 1;
        }
        return result;
    }
};

/// The character's saved attributes (the "gf" section: the 16 stats D2 persists, in
/// ascending ItemStatCost-id order, terminated by id 0x1ff). Life/mana/stamina (ids 6-11)
/// are stored <<8 in the file and returned here as whole values.
pub const Attributes = struct {
    strength: u32 = 0,
    energy: u32 = 0,
    dexterity: u32 = 0,
    vitality: u32 = 0,
    statpts: u32 = 0,
    newskills: u32 = 0,
    hp: u32 = 0,
    maxhp: u32 = 0,
    mana: u32 = 0,
    maxmana: u32 = 0,
    stamina: u32 = 0,
    maxstamina: u32 = 0,
    level: u32 = 0,
    experience: u32 = 0,
    gold: u32 = 0,
    goldbank: u32 = 0,
};

/// Bit widths per saved stat id (ItemStatCost CSvBits); index = the 9-bit stat id 0..15.
const ATTR_BITS = [16]u6{ 10, 10, 10, 10, 10, 8, 21, 21, 21, 21, 21, 21, 7, 32, 25, 25 };

/// Parse the attributes section of a `.d2s`. Finds the "gf" marker whose stream begins with
/// strength (id 0 — D2 always writes stats in ascending id order, so a coincidental "gf" in
/// the header won't validate), then reads each [9-bit id][ATTR_BITS[id]-bit value] pair until
/// the 0x1ff terminator. Returns null when no valid attributes section is present (a freshly
/// created header-only save has none). Fixed-point stats (ids 6-11) are shifted <<8 -> whole.
pub fn parseAttributes(d2s: []const u8) ?Attributes {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, d2s, from, "gf")) |m| {
        from = m + 1;
        var br = BitReader{ .bytes = d2s[m + 2 ..] };
        if (br.bitsLeft() < 9 or br.read(9) != 0) continue; // must lead with strength
        var a = Attributes{};
        var id: u32 = 0;
        while (true) {
            const nb = ATTR_BITS[@intCast(id)];
            if (br.bitsLeft() < nb) break;
            var v = br.read(nb);
            if (id >= 6 and id <= 11) v >>= 8; // fixed-point life/mana/stamina
            switch (id) {
                0 => a.strength = v,
                1 => a.energy = v,
                2 => a.dexterity = v,
                3 => a.vitality = v,
                4 => a.statpts = v,
                5 => a.newskills = v,
                6 => a.hp = v,
                7 => a.maxhp = v,
                8 => a.mana = v,
                9 => a.maxmana = v,
                10 => a.stamina = v,
                11 => a.maxstamina = v,
                12 => a.level = v,
                13 => a.experience = v,
                14 => a.gold = v,
                15 => a.goldbank = v,
                else => {},
            }
            if (br.bitsLeft() < 9) break;
            id = br.read(9);
            if (id == 0x1ff or id >= ATTR_BITS.len) break;
        }
        return a;
    }
    return null;
}

// --- tests ------------------------------------------------------------------

/// LSB-first bit writer — inverse of BitReader, for building test fixtures.
const BitWriter = struct {
    bytes: []u8,
    bit_pos: usize = 0,
    fn write(self: *BitWriter, value: u32, n: u6) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const byte_idx = self.bit_pos >> 3;
            const bit_idx: u3 = @intCast(self.bit_pos & 7);
            if (byte_idx < self.bytes.len) {
                const bit: u8 = @intCast((value >> @intCast(i)) & 1);
                self.bytes[byte_idx] |= bit << bit_idx;
            }
            self.bit_pos += 1;
        }
    }
};

test "parseAttributes reads a real .d2s gf stat bitfield" {
    var d2s: [64]u8 = [_]u8{0} ** 64;
    @memcpy(d2s[20..22], "gf");
    var bw = BitWriter{ .bytes = d2s[22..] };
    const put = struct {
        fn f(w: *BitWriter, id: u32, val: u32) void {
            w.write(id, 9);
            w.write(val, ATTR_BITS[@intCast(id)]);
        }
    }.f;
    put(&bw, 0, 156); // strength
    put(&bw, 2, 35); // dexterity
    put(&bw, 3, 200); // vitality
    put(&bw, 7, 100 << 8); // maxhp (fixed-point <<8)
    put(&bw, 14, 5000); // gold
    bw.write(0x1ff, 9); // terminator

    const a = parseAttributes(&d2s) orelse return error.NoAttributes;
    try std.testing.expectEqual(@as(u32, 156), a.strength);
    try std.testing.expectEqual(@as(u32, 35), a.dexterity);
    try std.testing.expectEqual(@as(u32, 200), a.vitality);
    try std.testing.expectEqual(@as(u32, 100), a.maxhp); // shifted back from <<8
    try std.testing.expectEqual(@as(u32, 5000), a.gold);

    // No "gf" section (fresh header-only save) -> null.
    try std.testing.expect(parseAttributes(&[_]u8{ 0, 1, 2, 3 }) == null);
}
