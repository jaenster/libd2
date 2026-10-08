//! An item as the game stores it in a character save and in a shared stash page: the save form of the item
//! bit-stream (`JM`, flags, version, place, code, then the quality block, the base stats and the stat lists),
//! padded to a whole byte. libd2 reads this form (`wire.parseSave`) and writes only the wire form of the
//! packets; this is the writer of the save form, the inverse of `parseSave` for what a granted item needs:
//! a simple item (gems, runes, potions), and a normal, magic, rare or unique item with its stats.
//!
//! The bit order is the engine's (ITEM_SaveToBitBuffer): the stat list is in ascending stat id, a grouped
//! stat (the elemental damages, the enhanced damage pair) is one id followed by every member's value, and the
//! base stats (defense, durability) sit before the sockets and the list. `parseSave` of the bytes returns the
//! item that was written; the donor save's records are written back byte for byte (see the test below), which
//! is the check that the order is the engine's and not only self-consistent.
const std = @import("std");
const core = @import("d2-core");
const wire = core.wire;
const bitreader = core.bitreader;
const isc = core.itemstatcost;
const types = core.itemtypes;

pub const max_record = 1024;

/// What is written beyond what `wire.Item` carries.
pub const Extra = struct {
    /// The item's seed (what the game keeps as the unit's initial seed).
    seed: u32,
    /// The base stats of an armor or weapon, and a stackable's count, are in `item.stats`; a stackable's
    /// quantity is here because `parseSave` reads it into `item.quantity`.
    quantity: u16 = 0,
    /// The 5-bit field a Tome of Town Portal or Identify carries after its quality block (the spell the tome holds).
    book: u5 = 0,
};

pub const Error = error{ Unsupported, TooLong };

/// A stat of the item as one entry of its list. Two stats with the same id and param are one.
pub const Entry = struct { id: u16, param: u32, value: i32 };

fn isGroupHead(id: u16) bool {
    return switch (id) {
        17, 48, 50, 52, 54, 57 => true,
        else => false,
    };
}

/// The ids that follow a group head in the list; they are never written alone.
fn isGroupMember(id: u16) bool {
    return switch (id) {
        18, 49, 51, 53, 55, 56, 58, 59 => true,
        else => false,
    };
}

fn groupLen(head: u16) u16 {
    return switch (head) {
        17, 48, 50, 52 => 2,
        54, 57 => 3,
        else => 1,
    };
}

fn valueOf(stats: []const wire.Stat, list: u8, id: u16, param: u32) i32 {
    var total: i32 = 0;
    for (stats) |s| {
        if (s.id == id and s.list == list and s.param == param) total += s.value;
    }
    return total;
}

fn baseValue(it: *const wire.Item, id: u16) i32 {
    for (it.stats[0..it.n_stats]) |s| if (s.id == id and s.list == wire.list_base) return s.value;
    return 0;
}

fn writeValue(w: *bitreader.BitWriter, id: u16, value: i32) void {
    const row = isc.get(id).?;
    const raw: i32 = (value >> @intCast(row.valshift)) +% row.save_add;
    w.write(@bitCast(raw), @intCast(row.save_bits));
}

fn writeStat(w: *bitreader.BitWriter, id: u16, param: u32, value: i32) void {
    const row = isc.get(id).?;
    if (row.save_param_bits > 0) w.write(param & 0xFFFF, @intCast(row.save_param_bits));
    writeValue(w, id, value);
}

/// The save-form record of `it` into `out` (zeroed first), its length in bytes. The place bits are the item's own
/// (`it.dest`, `it.x`, `it.y`, `it.page_raw`); a page entry is retargeted by whoever stores it.
pub fn encode(out: []u8, it: *const wire.Item, ex: Extra) Error!usize {
    if (it.flags & (wire.flag.PLAYERNAME | wire.flag.BODYPART) != 0) return error.Unsupported;
    if (it.dest == 3 or it.dest == 5) return error.Unsupported;
    @memset(out, 0);
    var w = bitreader.BitWriter.init(out);
    w.write(0x4D4A, 16); // JM
    w.write(it.flags, 32);
    w.write(it.version, 10);
    w.write(it.dest, 3);
    w.write(it.body_loc, 4);
    w.write(it.x, 4);
    w.write(it.y, 4);
    w.write(it.page_raw, 3);
    var i: usize = 0;
    while (i < 4) : (i += 1) w.write(if (i < it.code_len) it.code[i] else ' ', 8);

    if (it.flags & wire.flag.COMPACT != 0) {
        w.write(it.socketed_count & 1, 1);
        return finish(&w, out);
    }
    if (it.flags & wire.flag.CRUDE != 0) return error.Unsupported;

    w.write(it.socketed_count, 3);
    w.write(ex.seed, 32);
    w.write(it.ilvl, 7);
    w.write(@intFromEnum(it.quality), 4);
    w.write(@intFromBool(it.has_variant), 1);
    if (it.has_variant) w.write(it.variant, 3);
    w.write(@intFromBool(it.automagic != 0), 1);
    if (it.automagic != 0) w.write(it.automagic, 11);

    const ident = it.identified();
    switch (@intFromEnum(it.quality)) {
        1, 3 => w.write(it.file_index, 3),
        2 => {
            if (isCharm(it.codeSlice())) return error.Unsupported;
            if (isBook(it.codeSlice())) w.write(ex.book, 5);
        },
        5 => if (ident) w.write(it.set_id, 12),
        4 => if (ident) {
            w.write(it.prefix, 11);
            w.write(it.suffix, 11);
        },
        6, 8 => {
            if (ident) {
                w.write(it.rare_name1, 8);
                w.write(it.rare_name2, 8);
            }
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                w.write(@intFromBool(it.rare_prefixes[k] != 0), 1);
                if (it.rare_prefixes[k] != 0) w.write(it.rare_prefixes[k], 11);
                w.write(@intFromBool(it.rare_suffixes[k] != 0), 1);
                if (it.rare_suffixes[k] != 0) w.write(it.rare_suffixes[k], 11);
            }
        },
        7 => if (ident) w.write(it.unique_id, 12),
        else => return error.Unsupported,
    }

    if (it.flags & wire.flag.RUNEWORD != 0) w.write(it.runeword_id, 16);
    w.write(0, 1); // no realm data

    const stats = it.stats[0..it.n_stats];
    if (types.lookup(it.codeSlice())) |t| {
        switch (t.cat) {
            .armor => {
                writeValue(&w, 31, baseValue(it, 31));
                try writeDurability(&w, it);
            },
            .weapon => try writeDurability(&w, it),
            .misc => {},
        }
        if (t.stackable) w.write(ex.quantity, 9);
    }
    if (it.flags & wire.flag.SOCKETED != 0) w.write(it.sockets, @intCast((isc.get(194) orelse return error.Unsupported).save_bits));

    if (!ident) return finish(&w, out);
    // The lists: the item's own, then (a set item) the five partial bonus lists its mask names, then (a runeword)
    // the runeword's own. A partial list is present when the record has a stat in it.
    var set_mask: u32 = 0;
    if (it.quality == .set) {
        for (stats) |s| if (s.list >= 1 and s.list <= 5) {
            set_mask |= @as(u32, 1) << @intCast(s.list - 1);
        };
        w.write(set_mask, 5);
    }
    try writeList(&w, stats, 0);
    if (it.quality == .set) {
        var k: u8 = 0;
        while (k < 5) : (k += 1) if (set_mask & (@as(u32, 1) << @intCast(k)) != 0) try writeList(&w, stats, k + 1);
    }
    if (it.flags & wire.flag.RUNEWORD != 0) try writeList(&w, stats, wire.list_runeword);
    return finish(&w, out);
}

/// One stat list: ascending by id, then param; the same (id, param) is one entry; the 0x1FF terminator.
fn writeList(w: *bitreader.BitWriter, stats: []const wire.Stat, list: u8) Error!void {
    var entries: [wire.MAX_STATS]Entry = undefined;
    var n: usize = 0;
    for (stats) |s| {
        if (s.list != list or isGroupMember(s.id)) continue;
        if (isc.get(s.id) == null) return error.Unsupported;
        var seen = false;
        for (entries[0..n]) |e| if (e.id == s.id and e.param == s.param) {
            seen = true;
        };
        if (seen) continue;
        entries[n] = .{ .id = s.id, .param = s.param, .value = 0 };
        n += 1;
    }
    // a group's members count even when only a member was rolled (the head's entry is made for it)
    for (stats) |s| {
        if (s.list != list or !isGroupMember(s.id)) continue;
        const head = headOf(s.id);
        var seen = false;
        for (entries[0..n]) |e| if (e.id == head and e.param == s.param) {
            seen = true;
        };
        if (!seen) {
            entries[n] = .{ .id = head, .param = s.param, .value = 0 };
            n += 1;
        }
    }
    std.mem.sortUnstable(Entry, entries[0..n], {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return if (a.id != b.id) a.id < b.id else a.param < b.param;
        }
    }.less);
    for (entries[0..n]) |e| {
        w.write(e.id, 9);
        if (isGroupHead(e.id)) {
            var m: u16 = 0;
            while (m < groupLen(e.id)) : (m += 1) {
                const id = e.id + m;
                writeStat(w, id, e.param, valueOf(stats, list, id, e.param));
            }
        } else writeStat(w, e.id, e.param, valueOf(stats, list, e.id, e.param));
    }
    w.write(isc.STAT_LIST_TERMINATOR, 9);
}

fn headOf(member: u16) u16 {
    return switch (member) {
        18 => 17,
        49 => 48,
        51 => 50,
        53 => 52,
        55, 56 => 54,
        58, 59 => 57,
        else => member,
    };
}

fn writeDurability(w: *bitreader.BitWriter, it: *const wire.Item) Error!void {
    const maxdur = baseValue(it, 73);
    const row = isc.get(73) orelse return error.Unsupported;
    const raw: i32 = (maxdur >> @intCast(row.valshift)) +% row.save_add;
    w.write(@bitCast(raw), @intCast(row.save_bits));
    if (raw != 0) writeValue(w, 72, baseValue(it, 72));
}

fn finish(w: *bitreader.BitWriter, out: []u8) Error!usize {
    const n = w.byteLen();
    if (w.bit_pos > out.len * 8) return error.TooLong;
    return n;
}

fn isCharm(code: []const u8) bool {
    return std.mem.eql(u8, code, "cm1") or std.mem.eql(u8, code, "cm2") or std.mem.eql(u8, code, "cm3");
}

fn isBook(code: []const u8) bool {
    return std.mem.eql(u8, code, "tsc") or std.mem.eql(u8, code, "isc") or std.mem.eql(u8, code, "tbk") or std.mem.eql(u8, code, "ibk");
}

// ---- tests ----------------------------------------------------------------------------------------

const testing = std.testing;
const sections = @import("sections.zig");
const donor_save = @embedFile("testdata/EpicSorc.d2s");

/// The 5 bits a book carries after its quality block, read from an engine record.
/// Whether the first record of `rec` is written back by this writer exactly as it is: the check that the form a maker
/// produced is one `wire.parseSave` reads and `encode` writes the same.
pub fn testRoundTrips(rec: []const u8) bool {
    var r = bitreader.BitReader.init(rec);
    var parsed = wire.parseSave(&r);
    markBase(&parsed);
    const len = (parsed.bit_len + 7) / 8;
    const first = rec[0..len];
    const seed: u32 = if (parsed.flags & wire.flag.COMPACT != 0) 0 else seedOf(first);
    const book: u5 = if (isBook(parsed.codeSlice())) bookOf(first) else 0;
    var buf: [max_record]u8 = undefined;
    const n = encode(&buf, &parsed, .{ .seed = seed, .quantity = parsed.quantity, .book = book }) catch return false;
    return std.mem.eql(u8, first, buf[0..n]);
}

pub fn testBookOf(rec: []const u8) u5 {
    return bookOf(rec);
}

fn bookOf(rec: []const u8) u5 {
    var r = bitreader.BitReader.init(rec);
    _ = r.read(16);
    _ = r.read(32);
    _ = r.read(10);
    _ = r.read(3 + 4 + 4 + 4 + 3);
    _ = r.read(32);
    _ = r.read(3);
    _ = r.read(32);
    _ = r.read(7 + 4);
    if (r.read(1) != 0) _ = r.read(3);
    if (r.read(1) != 0) _ = r.read(11);
    return @intCast(r.read(5));
}

fn seedOf(rec: []const u8) u32 {
    var r = bitreader.BitReader.init(rec);
    _ = r.read(16);
    _ = r.read(32);
    _ = r.read(10);
    _ = r.read(3 + 4 + 4 + 4 + 3);
    _ = r.read(32);
    _ = r.read(3);
    return r.read(32);
}

/// `parseSave` files the base maximum durability under the item's own list; the first one is the base.
fn markBase(it: *wire.Item) void {
    for (it.stats[0..it.n_stats]) |*s| if (s.id == 73) {
        s.list = wire.list_base;
        return;
    };
}

const Tally = struct { same: usize = 0, runewords: usize = 0, books: usize = 0, ethereals: usize = 0, by_quality: [16]usize = [_]usize{0} ** 16 };

fn writeBack(bytes: []const u8, tally: *Tally) !void {
    const sv = try sections.parse(bytes);
    var it = sv.items.iterator();
    var buf: [max_record]u8 = undefined;
    while (true) {
        const start = it.pos;
        _ = it.next() orelse break;
        const rec = sv.items.bytes[start..it.pos];
        // the record as parsed again: the place bits are the item's own
        var r = bitreader.BitReader.init(rec);
        var parsed = wire.parseSave(&r);
        markBase(&parsed);
        const seed: u32 = if (parsed.flags & wire.flag.COMPACT != 0) 0 else seedOf(rec);
        // forms the writer does not produce (a personalised item, a charm of Normal quality) are not part of this claim
        const book: u5 = if (isBook(parsed.codeSlice())) bookOf(rec) else 0;
        const n = encode(&buf, &parsed, .{ .seed = seed, .quantity = parsed.quantity, .book = book }) catch continue;
        testing.expectEqualSlices(u8, rec, buf[0..n]) catch |e| {
            std.debug.print("sockets={d} n_stats={d} dur={d}\n", .{ parsed.sockets, parsed.n_stats, baseValue(&parsed, 73) });
            for (parsed.stats[0..parsed.n_stats]) |st| std.debug.print("  stat {d} param {d} value {d} list {d}\n", .{ st.id, st.param, st.value, st.list });
            std.debug.print("record at {d} code={s} flags=0x{x} quality={d} differs\n", .{ start, parsed.codeSlice(), parsed.flags, @intFromEnum(parsed.quality) });
            return e;
        };
        tally.same += 1;
        tally.by_quality[@intFromEnum(parsed.quality) & 15] += 1;
        if (parsed.flags & wire.flag.RUNEWORD != 0) tally.runewords += 1;
        if (isBook(parsed.codeSlice())) tally.books += 1;
        if (parsed.ethereal()) tally.ethereals += 1;
    }
}

test "the engine's records are written back byte for byte" {
    var tally = Tally{};
    try writeBack(donor_save, &tally);
    try writeBack(@embedFile("testdata/seed/EpicSorc.d2s"), &tally);
    try writeBack(@embedFile("testdata/seed/EpicAma.d2s"), &tally);
    // the forms this writer exists for are among them
    try testing.expect(tally.by_quality[4] > 0 and tally.by_quality[6] > 0 and tally.by_quality[7] > 0);
    try testing.expect(tally.same > 60);
    // and the forms a kit needs: a runeword, a tome, an ethereal item
    try testing.expect(tally.runewords > 0 and tally.books > 0 and tally.ethereals > 0);
}

