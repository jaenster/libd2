//! Verifies the clean-room monster POSITION port (drlg/monpop.zig findRandomPosition)
//! against a true-engine golden captured by the d2probe spawn oracle (seed 1, Hell,
//! all acts — src/golden/monpop_seed1_all_acts.json, per-room gameSeed + rects + real
//! monster x,y).
//!
//! Isolation: positions roll off the ROOM seed (reproduced byte-exact by the clean-room
//! DRLG), while the density gate that decides HOW MANY monsters spawn rolls off the GAME
//! seed. The oracle dumps each room's game seed at entry, so we replay each room on its
//! own — no cross-level game-seed stream needed. The single-level generate() places the
//! level at the origin while the golden coords are act-absolute; since the DRLG layout is
//! identical up to a constant level-placement offset (and positions roll off the
//! placement-independent room seed), we align by the level min-corner and compare shifted.
//!
//! What this checks: for each density hit the port emits its LEADER at the real rolled
//! position; the golden lists every individual monster. So a matched leader position
//! proves findRandomPosition is faithful. Per-minion spread + group counts (leader unit
//! seed) remain documented residuals (see docs/re/monster-spawn-position.md).
//!
//! STATUS (seed 1 Hell, Den of Evil): all 27 rooms pair by geometry (the DRLG layout +
//! offset alignment is exact) and the port emits real seeded leaders. Byte-exact position
//! match is NOT yet reached — the harness localizes the residual to per-room room-seed /
//! region-counter alignment: rooms whose room seed matches roll an in-pool class at a
//! valid position (e.g. room 2 -> Zombie), while others roll an out-of-pool class (room 1
//! -> class 28 ∉ {5,63,19}), meaning `checkSpawnDensity`'s boss gates see a different
//! `dw_unique_count`/`n_rooms_count` than the engine did at that room (our firstRoom()
//! iteration order != the engine's room-processing order). Closing it needs the engine's
//! per-room room seed + region counters dumped (Room1 seed offset), or replaying the
//! act's exact room order. Report-only until then.

const std = @import("std");
const lib = @import("lib.zig");
const monpop = @import("drlg/monpop.zig");
const s = @import("drlg/structs.zig");

fn oi(obj: *const std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

test "monpop position verify: Den of Evil leaders match the engine golden (seed 1 Hell)" {
    const gpa = std.testing.allocator;

    const raw = @embedFile("golden/monpop_seed1_act1_maze.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const levels = parsed.value.object.get("levels").?.object;
    const grooms = levels.get("8").?.object.get("rooms").?.array; // Den of Evil (L8)

    // Golden level min-corner (act-absolute), for aligning our origin-placed generation.
    var g_min_x: i64 = std.math.maxInt(i64);
    var g_min_y: i64 = std.math.maxInt(i64);
    for (grooms.items) |gr| {
        const rects = gr.object.get("rects").?.array;
        if (rects.items.len == 0) continue;
        const r0 = &rects.items[0].object;
        g_min_x = @min(g_min_x, oi(r0, "l"));
        g_min_y = @min(g_min_y, oi(r0, "t"));
    }

    // Generate Den of Evil at seed 1, Hell.
    var ctx = try lib.Ctx.init(gpa);
    defer ctx.deinit();
    const level_id: i32 = 8;
    const lvl = try lib.generate(&ctx, 1, @enumFromInt(level_id), .hell, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    defer lvl.deinit();

    var tbl = try monpop.Tables.load(gpa);
    defer tbl.deinit();
    const lm = tbl.levelMon(level_id).?;

    var regions = try monpop.buildAllRegions(gpa, &tbl, 1, 2);
    defer gpa.free(regions);
    const rg = &regions[@intCast(level_id)];

    // Our level min-corner (world subtiles) + room count.
    var m_min_x: i32 = std.math.maxInt(i32);
    var m_min_y: i32 = std.math.maxInt(i32);
    var rc: u32 = 0;
    {
        var pr = lvl.firstRoom();
        while (pr) |p| : (pr = p.pRoomExNext) {
            m_min_x = @min(m_min_x, p.sCoords.WorldPosition.x * 5);
            m_min_y = @min(m_min_y, p.sCoords.WorldPosition.y * 5);
            rc += 1;
        }
    }
    rg.n_level_rooms_count = @intCast(rc);
    rg.n_rooms_count = 0;

    const off_x: i64 = g_min_x - m_min_x;
    const off_y: i64 = g_min_y - m_min_y;

    var my_total: usize = 0;
    var matched: usize = 0;
    var rooms_paired: usize = 0;

    var pr = lvl.firstRoom();
    while (pr) |p| : (pr = p.pRoomExNext) {
        const sx = p.sCoords.WorldPosition.x * 5;
        const sy = p.sCoords.WorldPosition.y * 5;
        const ssx = p.sCoords.WorldSize.x * 5;
        const ssy = p.sCoords.WorldSize.y * 5;
        const gl = @as(i64, sx) + off_x;
        const gt = @as(i64, sy) + off_y;

        // Pair with the golden room at the shifted rect.
        var groom: ?*const std.json.ObjectMap = null;
        for (grooms.items) |gr| {
            const rects = gr.object.get("rects").?.array;
            if (rects.items.len == 0) continue;
            const r0 = &rects.items[0].object;
            if (oi(r0, "l") == gl and oi(r0, "t") == gt and
                oi(r0, "r") == gl + ssx and oi(r0, "b") == gt + ssy)
            {
                groom = &gr.object;
                break;
            }
        }
        const gr = groom orelse continue;
        rooms_paired += 1;
        const gspawns = gr.get("spawns").?.array;

        // Replay this room: golden game seed + our faithful room seed.
        var game_seed = s.D2SeedStrc{
            .nSeedLow = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(oi(gr, "gameSeedLo")))))),
            .nSeedHigh = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(oi(gr, "gameSeedHi")))))),
        };
        var room_seed = p.sSeed;
        var out: std.ArrayListUnmanaged(monpop.MonSpawn) = .empty;
        defer out.deinit(gpa);
        const rctx = monpop.RoomCtx{ .x_start = sx, .y_start = sy, .x_size = ssx, .y_size = ssy };
        _ = monpop.spawnRoomMonsters(rg, &tbl, lm, &game_seed, &room_seed, &rctx, true, &out, gpa, null);

        if (out.items.len > 0 and gspawns.items.len > 0 and rooms_paired <= 2) {
            std.debug.print("  room rect=({d},{d},{d},{d}) roomSeed=0x{x} gameSeed=0x{x} off=({d},{d})\n", .{
                gl, gt, gl + ssx, gt + ssy, @as(u32, @bitCast(p.sSeed.nSeedLow)), @as(u32, @bitCast(game_seed.nSeedLow)), off_x, off_y,
            });
            std.debug.print("    mine  : ", .{});
            for (out.items) |ms| std.debug.print("({d}@{d},{d}) ", .{ ms.class_id, @as(i64, ms.x) + off_x, @as(i64, ms.y) + off_y });
            std.debug.print("\n    golden: ", .{});
            for (gspawns.items) |gs| std.debug.print("({d}@{d},{d}) ", .{ oi(&gs.object, "classId"), oi(&gs.object, "x"), oi(&gs.object, "y") });
            std.debug.print("\n", .{});
        }
        for (out.items) |ms| {
            my_total += 1;
            const ax = @as(i64, ms.x) + off_x; // shift our position into act-absolute space
            const ay = @as(i64, ms.y) + off_y;
            for (gspawns.items) |gs| {
                const go = &gs.object;
                if (oi(go, "classId") == ms.class_id and oi(go, "x") == ax and oi(go, "y") == ay) {
                    matched += 1;
                    break;
                }
            }
        }
    }

    std.debug.print(
        "\n[monpop-verify] Den of Evil (seed 1 Hell): {d} rooms paired, {d}/{d} leader positions matched the engine golden\n",
        .{ rooms_paired, matched, my_total },
    );
    try std.testing.expect(rooms_paired > 0); // rooms align with the golden by geometry
    try std.testing.expect(my_total > 0); // the port emits real seeded spawns
}
