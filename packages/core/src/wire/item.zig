//! Faithful 1.14d item bit-stream decoder (network/wire form, isSave=0, version 0x60).
//!
//! Ports ITEM_DeserializeFromBitBuffer @0x62cbe0 (via ITEM_LoadFromSaveData). Field order and
//! widths per the Ghidra decompile — see docs/re/sc-packets.md. On the wire there is no "JM"
//! magic and no seed/timestamp block (both save-only). Unidentified items end before the stat
//! list. At version 0x60 every stat uses the generic decode path except the grouped min/max
//! damage stats; the packed skill special-cases are all version-gated off.

const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;
const isc = @import("itemstatcost.zig");
const types = @import("itemtypes.zig");

pub const flag = struct {
    pub const IDENTIFIED: u32 = 0x10;
    pub const SOCKETED: u32 = 0x800;
    pub const NEW: u32 = 0x2000;
    pub const BODYPART: u32 = 0x10000; // ear
    pub const COMPACT: u32 = 0x200000; // "simple item" (gold/potion/scroll/quest)
    pub const ETHEREAL: u32 = 0x400000;
    pub const PLAYERNAME: u32 = 0x1000000; // personalized
    pub const CRUDE: u32 = 0x2000000; // no ilvl/quality/stats past the code
    pub const RUNEWORD: u32 = 0x4000000;
};

pub const Quality = enum(u8) {
    invalid = 0,
    low = 1,
    normal = 2,
    superior = 3,
    magic = 4,
    set = 5,
    rare = 6,
    unique = 7,
    crafted = 8,
    tempered = 9,
    _,
};

pub const Stat = struct { id: u16, value: i32, param: u32 = 0 };

pub const MAX_STATS = 48;

pub const Item = struct {
    flags: u32 = 0,
    version: u16 = 0,
    dest: u8 = 0,
    body_loc: u8 = 0, // eBodyLoc equip slot (only meaningful when dest == 1, "equipped")
    on_ground: bool = false,
    x: u16 = 0,
    y: u16 = 0,
    code: [4]u8 = [_]u8{0} ** 4,
    code_len: u8 = 0,
    compact: bool = false,
    crude: bool = false,
    ilvl: u8 = 0,
    quality: Quality = .invalid,
    sockets: u8 = 0,
    prefix: u16 = 0,
    suffix: u16 = 0,
    set_id: u16 = 0,
    unique_id: u16 = 0,
    runeword_id: u16 = 0,
    stats: [MAX_STATS]Stat = undefined,
    n_stats: u8 = 0,

    pub fn ethereal(self: Item) bool {
        return self.flags & flag.ETHEREAL != 0;
    }
    pub fn identified(self: Item) bool {
        return self.flags & flag.IDENTIFIED != 0;
    }
    pub fn codeSlice(self: *const Item) []const u8 {
        return self.code[0..self.code_len];
    }

    fn addStat(self: *Item, s: Stat) void {
        if (self.n_stats >= MAX_STATS) return;
        self.stats[self.n_stats] = s;
        self.n_stats += 1;
    }
};

fn isCharm(code: []const u8) bool {
    return std.mem.eql(u8, code, "cm1") or std.mem.eql(u8, code, "cm2") or std.mem.eql(u8, code, "cm3");
}
fn isScrollBook(code: []const u8) bool {
    return std.mem.eql(u8, code, "tsc") or std.mem.eql(u8, code, "isc") or
        std.mem.eql(u8, code, "tbk") or std.mem.eql(u8, code, "ibk");
}

/// Decode one generic stat (param-then-value, value = (raw - saveAdd) << valshift) and append it.
/// Returns false if the stat id has no known bit width — the caller must stop (can't realign).
fn addGeneric(r: *BitReader, it: *Item, id: u16) bool {
    const row = isc.get(id) orelse return false;
    const param: u32 = if (row.save_param_bits > 0) r.read(@intCast(row.save_param_bits)) & 0xFFFF else 0;
    const raw = r.read(@intCast(row.save_bits));
    const value = (@as(i32, @intCast(raw)) -% row.save_add) << @intCast(row.valshift);
    it.addStat(.{ .id = id, .value = value, .param = param });
    return true;
}

/// One stat-list instance: read 9-bit ids until the 0x1FF terminator; each entry may expand to
/// several consecutive rows (grouped min/max damage). Stops on an unknown id (can't realign).
///
/// At the 1.14d save version (nParam2 == 0x60) the shared stat-list loop
/// (ITEM_DeserializeFromBitBuffer @0x62cbe0, lines 6225-6424) version-gates OFF every packed
/// skill-mod / auto-affix special case: for 0x5c < nParam2 the addclassskills family (83-87),
/// singleskill/restinpeace/curse_resistance/fade/armor_override/unused183-187 (107-109,181-187),
/// elemskill(126), freeze(134), attack/damage_vs_montype(179-180), addskill_tab(188)+189-193,
/// skillon*(195-203) and charged_skill(204-212) all `goto` the generic default path
/// (switchD_0062d9ae_caseD_4 / LAB_0062e1a9). So EVERY stat here uses the generic
/// save_param_bits + save_bits split from ItemStatCost — no fixed-width packed reads.
fn decodeStatList(r: *BitReader, it: *Item) void {
    while (true) {
        // A truncated/empty item stream never reaches the 0x1FF terminator — past EOF the reader
        // returns 0 (a valid stat id), so without this guard the loop appends stat 0 forever.
        if (r.bitsLeft() < 9) return;
        const id: u16 = @intCast(r.read(9));
        if (id == isc.STAT_LIST_TERMINATOR) return;
        const ok = switch (id) {
            17 => addGeneric(r, it, 17) and addGeneric(r, it, 18),
            48 => addGeneric(r, it, 48) and addGeneric(r, it, 49),
            50 => addGeneric(r, it, 50) and addGeneric(r, it, 51),
            52 => addGeneric(r, it, 52) and addGeneric(r, it, 53),
            54 => addGeneric(r, it, 54) and addGeneric(r, it, 55) and addGeneric(r, it, 56),
            57 => addGeneric(r, it, 57) and addGeneric(r, it, 58) and addGeneric(r, it, 59),
            else => addGeneric(r, it, id),
        };
        if (!ok) return; // unknown width -> bitstream would desync; stop here
    }
}

/// Parse an item from the WIRE bit-stream (isSave=0), positioned at the item flags dword
/// (0x9C payload +8). No "JM" magic and no seed/timestamp block.
pub fn parse(r: *BitReader) Item {
    return parseInner(r, false);
}

/// Parse an item from the SAVE (.d2s) bit-stream (isSave=1), positioned at the "JM" magic that
/// prefixes every save item record. Advances the reader exactly one item so the caller can walk
/// the JM section. Two save-only differences vs the wire form (per ITEM_LoadFromSaveData /
/// ITEM_DeserializeFromBitBuffer @0x62cbe0):
///   1. a 16-bit "JM" (0x4D4A) magic PREFIX before the 32-bit flags (ITEM_LoadFromSaveData:
///      ReadSigned(0x10) == 0x4d4a, then ReadUnsigned(0x20) flags);
///   2. a 32-bit item seed read right after the 3-bit param field, before ilvl
///      (ITEM_DeserializeFromBitBuffer line 5420-5425, gated on nParam1/isSave).
/// Everything else — version(10), dest(3)+position, code(32), quality/affix block, base-type
/// fixed stats, sockets, and the shared stat list — is IDENTICAL to the wire form.
pub fn parseSave(r: *BitReader) Item {
    _ = r.read(16); // "JM" magic (0x4D4A); caller has already validated section, we just skip it
    return parseInner(r, true);
}

fn parseInner(r: *BitReader, is_save: bool) Item {
    var it = Item{};
    it.flags = r.read(32);
    it.compact = it.flags & flag.COMPACT != 0;
    it.version = @intCast(r.read(10));
    it.dest = @intCast(r.read(3));
    if (it.dest == 3 or it.dest == 5) { // Ground / Dropped
        it.on_ground = true;
        it.x = @intCast(r.read(16));
        it.y = @intCast(r.read(16));
    } else {
        it.body_loc = @intCast(r.read(4)); // eBodyLoc equip slot
        _ = r.read(4); // grid col
        _ = r.read(4); // grid row
        _ = r.read(3); // inventory page
    }
    var i: usize = 0;
    while (i < 4) : (i += 1) it.code[i] = @truncate(r.read(8));
    it.code_len = 4;
    while (it.code_len > 0 and (it.code[it.code_len - 1] == ' ' or it.code[it.code_len - 1] == 0)) it.code_len -= 1;

    // Compact "simple" items (gold/potion/scroll/quest) carry no quality/stat block; their
    // gold-amount / charge / quest-difficulty extras go through a separate header decoder we
    // don't replicate yet — stop after the shared header.
    if (it.compact) return it;

    it.crude = it.flags & flag.CRUDE != 0;
    if (it.crude) return it; // CRUDE: nothing past the item code

    _ = r.read(3); // param field, discarded on the ground-drop path
    if (is_save) _ = r.read(32); // seed (save-only; nInitSeed / sSeed.nSeedLow)
    it.ilvl = @intCast(r.read(7));
    it.quality = @enumFromInt(@as(u8, @intCast(r.read(4))));
    if (r.readBool()) _ = r.read(3); // variant
    if (r.readBool()) _ = r.read(11); // automagic

    const ident = it.identified();
    switch (@intFromEnum(it.quality)) {
        1, 3 => _ = r.read(3), // low / superior file index
        2 => {
            if (isCharm(it.codeSlice())) {
                if (ident) {
                    _ = r.read(1); // prefix/suffix selector
                    _ = r.read(11); // affix id
                }
            } else if (isScrollBook(it.codeSlice())) {
                _ = r.read(5);
            }
        },
        4 => if (ident) { // magic
            it.prefix = @intCast(r.read(11));
            it.suffix = @intCast(r.read(11));
        },
        5 => if (ident) {
            it.set_id = @intCast(r.read(12));
        },
        6, 8 => { // rare / crafted
            if (ident) {
                _ = r.read(8); // name prefix id
                _ = r.read(8); // name suffix id
            }
            var k: usize = 0;
            while (k < 3) : (k += 1) { // 3 prefix + 3 suffix affix slots, unconditional
                if (r.readBool()) _ = r.read(11);
                if (r.readBool()) _ = r.read(11);
            }
        },
        7 => if (ident) {
            it.unique_id = @intCast(r.read(12));
        },
        9 => if (ident) { // tempered
            _ = r.read(8);
            _ = r.read(8);
        },
        else => {},
    }

    var extended = false;
    if (it.flags & flag.RUNEWORD != 0) {
        it.runeword_id = @intCast(r.read(16));
        extended = true;
    }
    if (it.flags & flag.BODYPART != 0) { // ear
        _ = r.read(3); // class
        _ = r.read(7); // level
        while (r.read(7) != 0) {} // null-terminated 7-bit name
    } else if (it.flags & flag.PLAYERNAME != 0) {
        while (r.read(7) != 0) {} // personalization name
    }

    // Realm-data block: save-only (nParam1) and version > 0x56. One present-bit, then two 32-bit
    // realm dwords, plus a third at version > 0x5d (0x60 qualifies). ITEM_DeserializeFromBitBuffer
    // lines 5780-5791. Sits between the personalization name and the base-type fixed stats — the
    // block the wire form never has, and the one whose absence desynced every save-format item.
    if (is_save) { // nParam1 && 0x56 < nParam2 (== 0x60)
        if (r.readBool()) {
            _ = r.read(32);
            _ = r.read(32);
            _ = r.read(32); // version > 0x5d
        }
    }

    // base-type-dependent fixed stats (always present; append them as real stats)
    if (types.lookup(it.codeSlice())) |t| {
        switch (t.cat) {
            .armor => {
                _ = addGeneric(r, &it, 31); // armorclass
                appendDurability(r, &it);
            },
            .weapon => appendDurability(r, &it),
            .misc => {},
        }
        if (t.stackable) _ = r.read(9); // quantity (version >= 0x51)
    }

    if (it.flags & flag.SOCKETED != 0) {
        const sb = (isc.get(194) orelse return it).save_bits; // item_numsockets, no bias
        it.sockets = @intCast(r.read(@intCast(sb)));
    }

    if (!ident) return it; // unidentified: stream ends here, no stat list

    var list_count: i32 = 0;
    var set_mask: u32 = 0;
    if (it.version > 0x54 and it.quality == .set) {
        set_mask = r.read(5);
        list_count += 5;
    }
    if (extended) list_count += 1;

    var idx: i32 = -1;
    while (idx < list_count) : (idx += 1) {
        const do_list = idx == -1 or
            (idx >= 0 and idx < 5 and (set_mask & (@as(u32, 1) << @intCast(idx))) != 0) or
            (extended and idx == list_count - 1);
        if (do_list) decodeStatList(r, &it);
    }
    return it;
}

fn appendDurability(r: *BitReader, it: *Item) void {
    const maxdur_row = isc.get(73) orelse return; // maxdurability
    const maxdur = r.read(@intCast(maxdur_row.save_bits));
    it.addStat(.{ .id = 73, .value = @as(i32, @intCast(maxdur)) -% maxdur_row.save_add });
    if (maxdur != 0) _ = addGeneric(r, it, 72); // durability
}

const BitWriter = @import("bitreader.zig").BitWriter;

// Build a ground-drop item header shared by the tests: flags, version 0x60, dest=Ground, x/y,
// then the 4-char code. Returns the writer positioned right after the code.
fn writeHeader(w: *BitWriter, flags: u32, code: []const u8, x: u16, y: u16) void {
    w.write(flags, 32);
    w.write(0x60, 10);
    w.write(3, 3); // Ground
    w.write(x, 16);
    w.write(y, 16);
    var i: usize = 0;
    while (i < 4) : (i += 1) w.write(if (i < code.len) code[i] else ' ', 8);
}

/// Serialize an item to the WIRE bit-stream (isSave=0 — the S->C 0x9C payload), the inverse of `parse`.
/// Scoped to the forms the standalone server currently produces: a MISC-base item (ring/amulet/charm/
/// jewel — no armor/weapon base-type fixed stats) of any quality, with a single-stat stat list. Round-
/// trips with `parse` for those items. DEFERRED (documented): armor/weapon base stats (armorclass/
/// durability), grouped min/max damage stats, the set partial-list bonuses (mask bits >0), and the
/// ear/personalization blocks. `writeItemInto` returns the byte length written.
pub fn writeItem(w: *BitWriter, it: *const Item) void {
    w.write(it.flags, 32);
    w.write(it.version, 10);
    w.write(it.dest, 3);
    if (it.dest == 3 or it.dest == 5) {
        w.write(it.x, 16);
        w.write(it.y, 16);
    } else {
        w.write(it.body_loc, 4);
        w.write(0, 4); // grid col
        w.write(0, 4); // grid row
        w.write(0, 3); // inventory page
    }
    var i: usize = 0;
    while (i < 4) : (i += 1) w.write(if (i < it.code_len) it.code[i] else ' ', 8);

    if (it.compact or it.crude) return;

    w.write(0, 3); // param field
    w.write(it.ilvl, 7);
    w.write(@intFromEnum(it.quality), 4);
    w.write(0, 1); // no variant
    w.write(0, 1); // no automagic

    const ident = it.identified();
    switch (@intFromEnum(it.quality)) {
        1, 3 => w.write(0, 3), // low/superior file index (not ident-gated)
        4 => if (ident) {
            w.write(it.prefix, 11);
            w.write(it.suffix, 11);
        },
        5 => if (ident) w.write(it.set_id, 12),
        6, 8 => { // rare / crafted: name prefix+suffix, then 3 empty prefix/suffix affix slots
            if (ident) {
                w.write(0, 8);
                w.write(0, 8);
            }
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                w.write(0, 1);
                w.write(0, 1);
            }
        },
        7 => if (ident) w.write(it.unique_id, 12),
        9 => if (ident) {
            w.write(0, 8);
            w.write(0, 8);
        },
        else => {},
    }

    var extended = false;
    if (it.flags & flag.RUNEWORD != 0) {
        w.write(it.runeword_id, 16);
        extended = true;
    }

    // (misc/none base type: no armor/weapon fixed stats — a documented scope limit)

    if (it.flags & flag.SOCKETED != 0) {
        const sb = (isc.get(194) orelse return).save_bits; // item_numsockets
        w.write(it.sockets, @intCast(sb));
    }

    if (!ident) return;

    if (it.version > 0x54 and it.quality == .set) w.write(0, 5); // set partial-list mask (no partials)

    var s: usize = 0;
    while (s < it.n_stats) : (s += 1) writeStat(w, it.stats[s]);
    w.write(isc.STAT_LIST_TERMINATOR, 9); // base list terminator
    if (extended) w.write(isc.STAT_LIST_TERMINATOR, 9); // empty runeword extended list
}

/// Serialize `it` into `bytes` (creating the BitWriter), returning the number of bytes written.
pub fn writeItemInto(bytes: []u8, it: *const Item) usize {
    var w = BitWriter.init(bytes);
    writeItem(&w, it);
    return w.byteLen();
}

/// Encode one generic stat (id, optional param, then the value bits) — the inverse of addGeneric.
/// The host's mods come from single-stat property funcs, so no grouped min/max damage ids appear here.
fn writeStat(w: *BitWriter, s: Stat) void {
    const row = isc.get(s.id) orelse return;
    w.write(s.id, 9);
    if (row.save_param_bits > 0) w.write(s.param & 0xFFFF, @intCast(row.save_param_bits));
    const raw: i32 = (s.value >> @intCast(row.valshift)) +% row.save_add;
    w.write(@bitCast(raw), @intCast(row.save_bits));
}

test "writeItem round-trips a magic ring through parse" {
    var buf = [_]u8{0} ** 64;
    var it = Item{ .flags = flag.IDENTIFIED, .version = 0x60, .dest = 3, .on_ground = true, .x = 100, .y = 200, .ilvl = 50, .quality = .magic, .prefix = 5, .suffix = 7 };
    it.code = .{ 'r', 'i', 'n', 0 };
    it.code_len = 3;
    it.stats[0] = .{ .id = 0, .value = 10 }; // +10 strength
    it.n_stats = 1;
    var w = BitWriter.init(&buf);
    writeItem(&w, &it);

    var r = BitReader.init(&buf);
    const got = parse(&r);
    try std.testing.expectEqual(Quality.magic, got.quality);
    try std.testing.expect(got.on_ground and got.x == 100 and got.y == 200);
    try std.testing.expectEqualStrings("rin", got.codeSlice());
    try std.testing.expectEqual(@as(u8, 50), got.ilvl);
    try std.testing.expectEqual(@as(u16, 5), got.prefix);
    try std.testing.expectEqual(@as(u16, 7), got.suffix);
    try std.testing.expectEqual(@as(u8, 1), got.n_stats);
    try std.testing.expectEqual(@as(u16, 0), got.stats[0].id);
    try std.testing.expectEqual(@as(i32, 10), got.stats[0].value);
}

test "writeItem round-trips a unique amulet (equipped) with two stats" {
    var buf = [_]u8{0} ** 64;
    var it = Item{ .flags = flag.IDENTIFIED, .version = 0x60, .dest = 1, .body_loc = 2, .ilvl = 80, .quality = .unique, .unique_id = 123 };
    it.code = .{ 'a', 'm', 'u', 0 };
    it.code_len = 3;
    it.stats[0] = .{ .id = 0, .value = 20 }; // +20 strength (valshift 0)
    it.stats[1] = .{ .id = 2, .value = 15 }; // +15 dexterity (valshift 0)
    it.n_stats = 2;
    var w = BitWriter.init(&buf);
    writeItem(&w, &it);

    var r = BitReader.init(&buf);
    const got = parse(&r);
    try std.testing.expectEqual(Quality.unique, got.quality);
    try std.testing.expectEqual(@as(u16, 123), got.unique_id);
    try std.testing.expectEqual(@as(u8, 2), got.body_loc);
    try std.testing.expect(!got.on_ground);
    try std.testing.expectEqual(@as(u8, 2), got.n_stats);
    try std.testing.expectEqual(@as(i32, 20), got.stats[0].value);
    try std.testing.expectEqual(@as(u16, 2), got.stats[1].id);
    try std.testing.expectEqual(@as(i32, 15), got.stats[1].value);
}

test "writeItem round-trips a set item (the 5-bit set mask path)" {
    var buf = [_]u8{0} ** 64;
    var it = Item{ .flags = flag.IDENTIFIED, .version = 0x60, .dest = 3, .on_ground = true, .x = 1, .y = 2, .ilvl = 40, .quality = .set, .set_id = 55 };
    it.code = .{ 'r', 'i', 'n', 0 };
    it.code_len = 3;
    it.stats[0] = .{ .id = 0, .value = 5 };
    it.n_stats = 1;
    var w = BitWriter.init(&buf);
    writeItem(&w, &it);

    var r = BitReader.init(&buf);
    const got = parse(&r);
    try std.testing.expectEqual(Quality.set, got.quality);
    try std.testing.expectEqual(@as(u16, 55), got.set_id);
    try std.testing.expectEqual(@as(u8, 1), got.n_stats);
    try std.testing.expectEqual(@as(i32, 5), got.stats[0].value);
}

test "parse identified magic ring with a stat" {
    var buf = [_]u8{0} ** 64;
    var w = BitWriter.init(&buf);
    writeHeader(&w, flag.IDENTIFIED, "rin", 100, 200);
    w.write(0, 3); // param
    w.write(50, 7); // ilvl
    w.write(4, 4); // magic
    w.write(0, 1); // no variant
    w.write(0, 1); // no automagic
    w.write(5, 11); // prefix
    w.write(7, 11); // suffix
    // stat list: strength(id0, saveBits8, saveAdd32) value 10 -> raw 42
    w.write(0, 9);
    w.write(42, 8);
    w.write(isc.STAT_LIST_TERMINATOR, 9);

    var r = BitReader.init(&buf);
    const it = parse(&r);
    try std.testing.expectEqual(Quality.magic, it.quality);
    try std.testing.expect(it.on_ground and it.x == 100 and it.y == 200);
    try std.testing.expectEqualStrings("rin", it.codeSlice());
    try std.testing.expectEqual(@as(u8, 50), it.ilvl);
    try std.testing.expectEqual(@as(u16, 5), it.prefix);
    try std.testing.expectEqual(@as(u16, 7), it.suffix);
    try std.testing.expectEqual(@as(u8, 1), it.n_stats);
    try std.testing.expectEqual(@as(u16, 0), it.stats[0].id);
    try std.testing.expectEqual(@as(i32, 10), it.stats[0].value);
}

test "unidentified item stops before affixes and stats" {
    var buf = [_]u8{0} ** 64;
    var w = BitWriter.init(&buf);
    writeHeader(&w, 0, "rin", 5, 6); // no IDENTIFIED bit
    w.write(0, 3);
    w.write(30, 7);
    w.write(4, 4); // magic
    w.write(0, 1);
    w.write(0, 1);
    // no affix/stat bits follow on the wire for an unID'd item

    var r = BitReader.init(&buf);
    const it = parse(&r);
    try std.testing.expectEqual(Quality.magic, it.quality);
    try std.testing.expectEqual(@as(u16, 0), it.prefix); // gated off
    try std.testing.expectEqual(@as(u8, 0), it.n_stats);
    try std.testing.expect(!it.identified());
}

test "parseSave reads JM magic + seed and decodes an equipped armor's defense" {
    var buf = [_]u8{0} ** 96;
    var w = BitWriter.init(&buf);
    w.write(0x4D4A, 16); // "JM" save magic prefix
    w.write(flag.IDENTIFIED, 32);
    w.write(0x60, 10); // version
    w.write(1, 3); // location: equipped (not ground) -> body_loc/col/row/page block
    w.write(3, 4); // body_loc = 3 (torso)
    w.write(0, 4); // grid col
    w.write(0, 4); // grid row
    w.write(0, 3); // inventory page
    var i: usize = 0;
    while (i < 4) : (i += 1) w.write(if (i < 3) "uui"[i] else ' ', 8); // armor base code
    w.write(0, 3); // param
    w.write(0xDEADBEEF, 32); // SAVE-ONLY seed (parseSave must consume this)
    w.write(80, 7); // ilvl
    w.write(7, 4); // unique
    w.write(0, 1); // no variant
    w.write(0, 1); // no automagic
    w.write(123, 12); // unique_id
    w.write(0, 1); // realm-data present-bit (save-only, version > 0x56): 0 = no realm block
    // base-type fixed stats: armorclass(31) save_bits, then durability(73)+72
    const ac_row = isc.get(31).?;
    w.write(@as(u32, @intCast(500 + ac_row.save_add)), @intCast(ac_row.save_bits)); // defense 500
    const md_row = isc.get(73).?;
    w.write(0, @intCast(md_row.save_bits)); // maxdurability 0 -> no current-durability field follows
    // stat list: fireresist(39) value 30
    const fr = isc.get(39).?;
    w.write(39, 9);
    w.write(@as(u32, @intCast(30 + fr.save_add)), @intCast(fr.save_bits));
    w.write(isc.STAT_LIST_TERMINATOR, 9);

    var r = BitReader.init(&buf);
    const it = parseSave(&r);
    try std.testing.expectEqualStrings("uui", it.codeSlice());
    try std.testing.expectEqual(Quality.unique, it.quality);
    try std.testing.expectEqual(@as(u8, 1), it.dest); // equipped
    try std.testing.expectEqual(@as(u8, 3), it.body_loc);
    try std.testing.expectEqual(@as(u16, 123), it.unique_id);
    // defense (31) and fireresist (39) both decoded from the shared stat path
    var def: i32 = 0;
    var fire: i32 = 0;
    for (it.stats[0..it.n_stats]) |s| {
        if (s.id == 31) def = s.value;
        if (s.id == 39) fire = s.value;
    }
    try std.testing.expectEqual(@as(i32, 500), def);
    try std.testing.expectEqual(@as(i32, 30), fire);
}

test "compact item yields code + position only" {
    var buf = [_]u8{0} ** 32;
    var w = BitWriter.init(&buf);
    writeHeader(&w, flag.COMPACT, "gld", 10, 20);
    var r = BitReader.init(&buf);
    const it = parse(&r);
    try std.testing.expect(it.compact);
    try std.testing.expectEqualStrings("gld", it.codeSlice());
    try std.testing.expect(it.on_ground and it.x == 10 and it.y == 20);
    try std.testing.expectEqual(Quality.invalid, it.quality); // never read
}
