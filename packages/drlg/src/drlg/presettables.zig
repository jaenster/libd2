//! Faithful transform of the preset-unit classId resolution the engine performs
//! at DS1-parse time — D2Common::Drlg::Preset::ParsePresetsOfDrlgFile (1.14d
//! 0x665950) — feeding DRLGPRESET_AddPresetUnitToDrlgMap (preset.zig).
//!
//! AddPresetUnit steps the level seed once per QUALIFYING preset unit, and whether
//! a unit qualifies keys on its TRUE game classId. The transform previously handed
//! AddPresetUnit an empty unit list (0 steps), so preset per-room nSeed diverged for
//! every Scan/Pops preset (e.g. lvl40 Lut Gholein). This module resolves each DS1
//! unit's classId exactly as the engine does.
//!
//! Resolution rules (cited):
//!  - Monsters (DS1 unit type 1): the DS1 id indexes the act's MonPreset block
//!    (MONSTERTBLS_GetMonPresetRecord 0x659b40 -> sgtDataTable.pTxtMonPresetPerAct[act],
//!    block = MonPreset.txt rows with Act == act_id+1, in file order). Each "Place"
//!    string was resolved at compile by DATATBLS_LinkerMonsterPreset (0x6597e0):
//!      SuperUniques.txt -> nType=2, MonStats.txt -> nType=1, MonPlace.txt -> nType=0,
//!      else nType=0/wPlace=0. classId (disasm 0x665c66..0x665c94):
//!        nType==1            -> wPlace (a MonStats classId)
//!        nType==0 OR nType==2 -> wPlace + nTxtMonStatsSize (object-as-monster, idx=wPlace)
//!      DS1 id >= block count -> classId = raw id (recon ~line 235 false branch).
//!    The Act3/Act5 monster->object remaps (0x665cb2..) only ever yield non-qualifying
//!    objects (0x17e/0x194/0x1cd/0x3f5-id), so they never change the seed-step count
//!    and are omitted.
//!  - Objects (DS1 unit type 2): id < 0x96 -> gpsPresetObjectTable[act*0x96 + id]
//!    (DRLGPRESET_GetObjectIdFromActTable 0x6658e0; static .data @0x748ad8, a 5*150
//!    int32 array extracted verbatim to PresetObjectTable.bin); id >= 0x96 -> id - 0x96.
//!  - Items (type 4) / any other: never reach a seed-stepping branch -> ignored.
//!
//! nTxtMonStatsSize forms object-as-monster classIds (+size) AND splits them back in
//! AddPresetUnit (idx = classId - size); the constant cancels, so any value larger
//! than every real monster classId is self-consistent. We use the MonStats row count.

const std = @import("std");
const txt = @import("../txt.zig");

const monpreset_src = @embedFile("../excel/MonPreset.txt");
const monstats_src = @embedFile("../excel/MonStats.txt");
const superuniques_src = @embedFile("../excel/SuperUniques.txt");
const monplace_src = @embedFile("../excel/MonPlace.txt");
const objtable_bin = @embedFile("../excel/PresetObjectTable.bin");

/// sgptDataTable->nTxtMonStatsSize — the MonStats.txt row count. Set on load.
pub var mon_size: i32 = 0;

const Tables = struct {
    /// per act_id (0..4): resolved monster classId per DS1 monster id (file order).
    mon: [5][]const i32,
    /// gpsPresetObjectTable: 5 acts * 150 slots of object classIds.
    obj: [750]i32,
};

var g: ?Tables = null;

fn nameIndexMap(a: std.mem.Allocator, src: []const u8, col_name: []const u8) struct {
    t: txt.Table,
    m: std.StringHashMapUnmanaged(i32),
} {
    var t = txt.Table.parse(a, src) catch unreachable;
    var m: std.StringHashMapUnmanaged(i32) = .{};
    var i: usize = 0;
    while (i < t.rowCount()) : (i += 1) {
        const key = t.str(i, col_name);
        // First occurrence wins (engine link tables index by file order).
        if (!m.contains(key)) m.put(a, key, @intCast(i)) catch unreachable;
    }
    return .{ .t = t, .m = m };
}

/// Build the resolver tables once. Loaded into the page allocator so they survive
/// the per-seed arena reset the verify harness applies to the pool allocator.
pub fn ensureLoaded() *const Tables {
    if (g) |*t| return t;
    const a = std.heap.page_allocator;

    const mon_tbl = nameIndexMap(a, monstats_src, "Id");
    mon_size = @intCast(mon_tbl.t.rowCount());
    const su = nameIndexMap(a, superuniques_src, "Superunique");
    const mp = nameIndexMap(a, monplace_src, "code");

    // MonPreset: resolve each row's "Place" -> classId, grouped per act (Act-1).
    var mpr = txt.Table.parse(a, monpreset_src) catch unreachable;
    var blocks: [5]std.ArrayListUnmanaged(i32) = .{ .empty, .empty, .empty, .empty, .empty };
    var r: usize = 0;
    while (r < mpr.rowCount()) : (r += 1) {
        const act = mpr.int(r, "Act"); // 1..5
        if (act < 1 or act > 5) continue;
        const place = mpr.str(r, "Place");
        // DATATBLS_LinkerMonsterPreset link order: SuperUniques, MonStats, MonPlace.
        var n_type: i32 = 0;
        var w_place: i32 = 0;
        if (su.m.get(place)) |idx| {
            n_type = 2;
            w_place = idx;
        } else if (mon_tbl.m.get(place)) |idx| {
            n_type = 1;
            w_place = idx;
        } else if (mp.m.get(place)) |idx| {
            n_type = 0;
            w_place = idx;
        }
        const class_id: i32 = if (n_type == 1) w_place else w_place + mon_size;
        blocks[@intCast(act - 1)].append(a, class_id) catch unreachable;
    }

    var mon: [5][]const i32 = undefined;
    for (0..5) |i| mon[i] = blocks[i].toOwnedSlice(a) catch unreachable;

    // gpsPresetObjectTable from the extracted .data blob (little-endian i32).
    var obj: [750]i32 = undefined;
    std.debug.assert(objtable_bin.len >= 750 * 4);
    for (0..750) |i| {
        obj[i] = std.mem.readInt(i32, objtable_bin[i * 4 ..][0..4], .little);
    }

    g = .{ .mon = mon, .obj = obj };
    return &g.?;
}

/// Resolved monster classId for a DS1 monster unit (type 1).
pub fn monsterClassId(act_id: i32, id: i32) i32 {
    const t = ensureLoaded();
    if (act_id < 0 or act_id > 4) return id;
    const blk = t.mon[@intCast(act_id)];
    if (id < 0 or id >= blk.len) return id; // recon: block-miss keeps the raw id
    return blk[@intCast(id)];
}

/// Resolved object classId for a DS1 object unit (type 2).
pub fn objectClassId(act_id: i32, id: i32) i32 {
    const t = ensureLoaded();
    if (id < 0x96) {
        const ai: usize = if (act_id < 0) 0 else @intCast(act_id & 0xff);
        const slot = ai * 0x96 + @as(usize, @intCast(id));
        if (slot >= t.obj.len) return -1;
        return t.obj[slot];
    }
    return id - 0x96;
}

test "preset tables: LutW Act2 monsters resolve to 204/205" {
    // act_id 1 (Act2), DS1 monster ids 25/26 -> act2vendor1/2 -> classId 204/205.
    try std.testing.expectEqual(@as(i32, 204), monsterClassId(1, 25));
    try std.testing.expectEqual(@as(i32, 205), monsterClassId(1, 26));
    // place_group25/50/75 (monplace idx 33/34/35) -> object-as-monster idx 0x21..0x23.
    try std.testing.expectEqual(@as(i32, 33), monsterClassId(1, 37) - mon_size);
    // Act2 object slot 22 -> waypoint classId 261 (0x105).
    try std.testing.expectEqual(@as(i32, 261), objectClassId(1, 22));
}
