//! dump_save_items — decode the "JM" item section of a .d2s save and print every item's
//! stats, then sum the resist / defense / +skill totals across all equipped gear.
//!
//! Verifies the save-format item bit-decoder (wire/item.zig parseSave). A .d2s item list is:
//!   767-byte char header, then marker sections; the item list is "JM" + u16 count, then
//!   `count` item records, each itself prefixed with "JM". parseSave consumes the JM magic,
//!   the 32-bit flags, version(10), dest(3)+position, code(32), param(3), the save-only
//!   32-bit seed, ilvl(7), quality(4), affixes, base-type fixed stats, sockets, then the
//!   SHARED stat list — advancing the reader exactly one record so we can walk the list.
//!
//! Usage: dump_save_items <path-to-save.d2s>
//!
//! Build/run (from packages/item):
//!   zig build-exe tools/dump_save_items.zig --dep d2item \
//!     -Mroot=tools/dump_save_items.zig -Md2item=src/lib.zig -femit-bin=/tmp/dump_save_items
//!   /tmp/dump_save_items /path/to/EpicSorc.d2s

const std = @import("std");
const d2item = @import("d2item");
const wire = d2item.wire;
const BitReader = d2item.WireBitReader;

// ItemStatCost ids (verified against src/excel/ItemStatCost.txt):
const ID_MAXHP = 7; // maxhp (+life)
const ID_DEFENSE = 31; // armorclass (defense)
const ID_FIRERES = 39; // fireresist
const ID_LIGHTRES = 41; // lightresist
const ID_COLDRES = 43; // coldresist
const ID_POISONRES = 45; // poisonresist
const ID_ADDCLASSSKILLS = 83; // item_addclassskills (per-class +skills)
const ID_SINGLESKILL = 107; // item_singleskill (+N to one skill)
const ID_ALLSKILLS = 127; // item_allskills (+all skills)

fn statVal(it: *const wire.Item, id: u16) i32 {
    var sum: i32 = 0;
    var i: usize = 0;
    while (i < it.n_stats) : (i += 1) {
        if (it.stats[i].id == id) sum += it.stats[i].value;
    }
    return sum;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var argv = std.process.Args.Iterator.init(init.args);
    _ = argv.next(); // argv[0]
    const path = argv.next() orelse {
        std.debug.print("usage: dump_save_items <path-to-save.d2s>\n", .{});
        return;
    };

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);

    std.debug.print("=== {s} ({d} bytes) ===\n", .{ path, data.len });

    // Find the item-list header: the FIRST "JM" whose following u16 is a sane item count and
    // whose next two bytes are ALSO "JM" (the first item record). The char save writes the
    // player's items right after the "if" skill section.
    var list_off: ?usize = null;
    var count: u16 = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, data, scan, "JM")) |m| {
        scan = m + 1;
        if (m + 6 > data.len) break;
        const c = std.mem.readInt(u16, data[m + 2 ..][0..2], .little);
        // header candidate: plausible count and an item record ("JM") immediately after.
        if (c > 0 and c < 512 and data[m + 4] == 'J' and data[m + 5] == 'M') {
            list_off = m;
            count = c;
            break;
        }
    }
    if (list_off == null) {
        std.debug.print("no JM item-list header found\n", .{});
        return;
    }
    std.debug.print("item list @ byte {d}, count = {d}\n\n", .{ list_off.?, count });

    // Walk `count` records starting right after the 4-byte list header. parseSave advances the
    // bit reader exactly one item; we byte-align to the next "JM" for the following record
    // (item records are byte-padded in the save stream).
    var r = BitReader.init(data[list_off.? + 4 ..]);

    var total_fire: i32 = 0;
    var total_cold: i32 = 0;
    var total_light: i32 = 0;
    var total_poison: i32 = 0;
    var total_defense: i32 = 0;
    var total_allskills: i32 = 0;
    var total_addclassskills: i32 = 0;
    var equipped: u32 = 0;
    var total_items: u32 = 0;

    var idx: u16 = 0;
    while (idx < count) : (idx += 1) {
        // Ensure we're positioned at a "JM" record start (byte-align + resync).
        var byte_pos = (r.bit_pos + 7) / 8;
        while (byte_pos + 2 <= (data.len - (list_off.? + 4)) and
            !(data[list_off.? + 4 + byte_pos] == 'J' and data[list_off.? + 4 + byte_pos + 1] == 'M')) : (byte_pos += 1)
        {}
        if (byte_pos + 2 > data.len - (list_off.? + 4)) break;
        r.bit_pos = byte_pos * 8;

        const it = wire.parseSave(&r);
        total_items += 1;

        // Item location (3-bit): 0=stored, 1=EQUIPPED (body_loc = slot), 2=belt, 4=cursor,
        // 6=socketed. Only location==1 is worn gear.
        const is_equipped = it.dest == 1;
        const fire = statVal(&it, ID_FIRERES);
        const cold = statVal(&it, ID_COLDRES);
        const light = statVal(&it, ID_LIGHTRES);
        const poison = statVal(&it, ID_POISONRES);
        const def = statVal(&it, ID_DEFENSE);
        const allsk = statVal(&it, ID_ALLSKILLS);
        const classsk = statVal(&it, ID_ADDCLASSSKILLS);
        const singlesk = statVal(&it, ID_SINGLESKILL);
        const life = statVal(&it, ID_MAXHP);

        std.debug.print("[{d:>2}] code='{s}' loc={d} slot={d} q={s} ilvl={d} stats={d}", .{
            idx, it.codeSlice(), it.dest, it.body_loc, @tagName(it.quality), it.ilvl, it.n_stats,
        });
        if (fire != 0) std.debug.print(" fireRes={d}", .{fire});
        if (cold != 0) std.debug.print(" coldRes={d}", .{cold});
        if (light != 0) std.debug.print(" lightRes={d}", .{light});
        if (poison != 0) std.debug.print(" poisonRes={d}", .{poison});
        if (def != 0) std.debug.print(" def={d}", .{def});
        if (allsk != 0) std.debug.print(" +allSkills={d}", .{allsk});
        if (classsk != 0) std.debug.print(" +classSkills={d}", .{classsk});
        if (singlesk != 0) std.debug.print(" +singleSkill={d}", .{singlesk});
        if (life != 0) std.debug.print(" +life={d}", .{life});
        if (is_equipped) std.debug.print("  <EQUIPPED>", .{});
        std.debug.print("\n", .{});

        if (is_equipped) {
            equipped += 1;
            total_fire += fire;
            total_cold += cold;
            total_light += light;
            total_poison += poison;
            total_defense += def;
            total_allskills += allsk;
            total_addclassskills += classsk;
        }
    }

    std.debug.print("\n=== TOTALS (equipped: {d} of {d} decoded) ===\n", .{ equipped, total_items });
    std.debug.print("fire  resist : {d}\n", .{total_fire});
    std.debug.print("cold  resist : {d}\n", .{total_cold});
    std.debug.print("light resist : {d}\n", .{total_light});
    std.debug.print("poison resist: {d}\n", .{total_poison});
    std.debug.print("total defense: {d}\n", .{total_defense});
    std.debug.print("+all skills  : {d}\n", .{total_allskills});
    std.debug.print("+class skills: {d}\n", .{total_addclassskills});
}
