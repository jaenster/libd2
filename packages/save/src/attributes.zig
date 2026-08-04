//! The "gf" attributes section of a `.d2s` — the bit-packed stat list D2 persists.
//!
//! Stats are written in ascending ItemStatCost-id order as [9-bit id][CSvBits-bit value]
//! pairs, terminated by id 0x1ff and zero-padded to the next byte. Life/mana/stamina (ids
//! 6-11) are stored as 8.8 fixed point.
//!
//! Two views of the same bytes: `Section` keeps the entries in stream order with their RAW
//! values, which is what a byte-exact re-emit needs; `Attributes` is the flat convenience
//! struct with the fixed-point stats already shifted down to whole values.

const std = @import("std");
const core = @import("d2-core");
const BitReader = core.bitreader.BitReader;
const BitWriter = core.bitreader.BitWriter;

pub const marker = "gf";

/// Bit widths per saved stat id (ItemStatCost CSvBits); index = the 9-bit stat id 0..15.
pub const ATTR_BITS = [16]u6{ 10, 10, 10, 10, 10, 8, 21, 21, 21, 21, 21, 21, 7, 32, 25, 25 };

pub const TERMINATOR: u32 = 0x1ff;

/// The character's saved attributes (the 16 stats D2 persists). Life/mana/stamina (ids 6-11)
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

/// One [id, raw value] pair exactly as it sits in the stream (no fixed-point shift applied).
pub const Entry = struct { id: u8, raw: u32 };

/// The section in stream order. A save only ever writes each id once and only ids 0..15 are
/// defined, so 16 slots is the hard maximum.
pub const Section = struct {
    entries: [ATTR_BITS.len]Entry = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Section) []const Entry {
        return self.entries[0..self.count];
    }

    /// Raw stream value of `id`, or 0 when the save doesn't carry that stat.
    pub fn raw(self: *const Section, id: u8) u32 {
        for (self.slice()) |e| {
            if (e.id == id) return e.raw;
        }
        return 0;
    }

    /// Set (or append) a stat's raw value, keeping the stream's ascending-id ordering.
    pub fn setRaw(self: *Section, id: u8, value: u32) void {
        if (id >= ATTR_BITS.len) return;
        for (self.entries[0..self.count]) |*e| {
            if (e.id == id) {
                e.raw = value;
                return;
            }
        }
        if (self.count >= self.entries.len) return;
        var i: usize = self.count;
        while (i > 0 and self.entries[i - 1].id > id) : (i -= 1) self.entries[i] = self.entries[i - 1];
        self.entries[i] = .{ .id = id, .raw = value };
        self.count += 1;
    }

    /// The flat view, with the 8.8 fixed-point stats (ids 6-11) shifted down to whole values.
    pub fn attributes(self: *const Section) Attributes {
        var a = Attributes{};
        for (self.slice()) |e| {
            var v = e.raw;
            if (e.id >= 6 and e.id <= 11) v >>= 8; // fixed-point life/mana/stamina
            switch (e.id) {
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
        }
        return a;
    }

    /// Byte length of the encoded section including the 2-byte "gf" marker.
    pub fn byteLen(self: *const Section) usize {
        var bits: usize = 9; // the 0x1ff terminator
        for (self.slice()) |e| bits += 9 + @as(usize, ATTR_BITS[e.id]);
        return marker.len + ((bits + 7) >> 3);
    }

    /// Encode marker + bit-stream into `out` (which must be at least `byteLen()` and is
    /// zeroed here, so the trailing bits pad with zeros the way the engine writes them).
    /// Returns the number of bytes written.
    pub fn writeInto(self: *const Section, out: []u8) usize {
        const n = self.byteLen();
        if (out.len < n) return 0;
        @memset(out[0..n], 0);
        @memcpy(out[0..marker.len], marker);
        var w = BitWriter.init(out[marker.len..n]);
        for (self.slice()) |e| {
            w.write(e.id, 9);
            w.write(e.raw, ATTR_BITS[e.id]);
        }
        w.write(TERMINATOR, 9);
        return n;
    }
};

/// Decode the section from `bytes`, which must start at the "gf" marker. Reads [9-bit
/// id][ATTR_BITS[id]-bit value] pairs until the 0x1ff terminator (or an id out of range).
/// Null when the marker isn't there.
pub fn parseSection(bytes: []const u8) ?Section {
    if (bytes.len < marker.len or !std.mem.eql(u8, bytes[0..marker.len], marker)) return null;
    var r = BitReader.init(bytes[marker.len..]);
    var s = Section{};
    while (true) {
        if (r.bitsLeft() < 9) break;
        const id = r.read(9);
        if (id == TERMINATOR or id >= ATTR_BITS.len) break;
        const nb = ATTR_BITS[@intCast(id)];
        if (r.bitsLeft() < nb) break;
        const v = r.read(nb);
        if (s.count >= s.entries.len) break;
        s.entries[s.count] = .{ .id = @intCast(id), .raw = v };
        s.count += 1;
    }
    return s;
}

/// Scan a whole `.d2s` for the attributes section and return the flat view. Finds the "gf"
/// marker whose stream begins with strength (id 0 — D2 always writes stats in ascending id
/// order, so a coincidental "gf" in the header won't validate). Returns null when no valid
/// attributes section is present (a freshly created header-only save has none).
pub fn parseAttributes(d2s: []const u8) ?Attributes {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, d2s, from, marker)) |m| {
        from = m + 1;
        var probe = BitReader.init(d2s[m + marker.len ..]);
        if (probe.bitsLeft() < 9 or probe.read(9) != 0) continue; // must lead with strength
        const s = parseSection(d2s[m..]) orelse continue;
        return s.attributes();
    }
    return null;
}

test "parseAttributes reads a .d2s gf stat bitfield" {
    var d2s: [64]u8 = [_]u8{0} ** 64;
    @memcpy(d2s[20..22], marker);
    var bw = BitWriter.init(d2s[22..]);
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
    bw.write(TERMINATOR, 9);

    const a = parseAttributes(&d2s) orelse return error.NoAttributes;
    try std.testing.expectEqual(@as(u32, 156), a.strength);
    try std.testing.expectEqual(@as(u32, 35), a.dexterity);
    try std.testing.expectEqual(@as(u32, 200), a.vitality);
    try std.testing.expectEqual(@as(u32, 100), a.maxhp); // shifted back from <<8
    try std.testing.expectEqual(@as(u32, 5000), a.gold);

    // No "gf" section (fresh header-only save) -> null.
    try std.testing.expect(parseAttributes(&[_]u8{ 0, 1, 2, 3 }) == null);
}

test "Section round-trips its own encoding" {
    var s = Section{};
    s.setRaw(0, 88);
    s.setRaw(3, 397);
    s.setRaw(7, 251392);
    s.setRaw(13, 3520485254);
    s.setRaw(1, 35); // out of order on the way in, ascending on the way out
    try std.testing.expectEqual(@as(u8, 1), s.entries[1].id);

    var buf: [64]u8 = undefined;
    const n = s.writeInto(&buf);
    try std.testing.expectEqual(s.byteLen(), n);

    const back = parseSection(buf[0..n]) orelse return error.NoSection;
    try std.testing.expectEqual(s.count, back.count);
    try std.testing.expectEqualSlices(Entry, s.slice(), back.slice());

    var buf2: [64]u8 = undefined;
    const n2 = back.writeInto(&buf2);
    try std.testing.expectEqualSlices(u8, buf[0..n], buf2[0..n2]);
}
