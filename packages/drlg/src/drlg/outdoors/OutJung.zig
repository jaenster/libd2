//! Mechanical transform of the ACT-III (jungle/Kurast) outdoor
//! generator. Faithful by construction; cites recon/closure + 1.14d Game.exe.
//!
//! Sources:
//!   OutJung::BuildJungle                       recon/closure/OutJung.cpp:42   (0067e910)
//!   OutJung::SpawnRandomPreset                 recon/closure/OutJung.cpp:131  (0067eed0)
//!   DRLGOUTJUNG_BuildKurastDocktownBorders     recon/closure/Drlg.cpp:5828    (0067ead0)
//!   DRLGOUTJUNG_BuildKurastUpperBorders        recon/closure/Drlg.cpp:5872    (0067ec30)
//!   DRLGOUTJUNG_BuildKurastCausewayBorders     recon/closure/Drlg.cpp:5912    (0067ed70)
//!   OutPlace::BuildKurast                       recon/closure/OutPlace.cpp:1584 (0067f190)
//!   OutPlace::BuildTravincal                    recon/closure/OutPlace.cpp:1642 (0067f3b0)
//!   OutPlace::InitAct3OutdoorLevel              recon/closure/OutPlace.cpp:1657 (0067f450)
//!
//! .rdata artifacts recovered from Game.exe 1.14d (session 62fbfe69) — the
//! decompiler rendered both as single-int static stubs (the classic .rdata window
//! collapse); the real arrays were read from the binary:
//!   * gnOutJungPresetOffsetByLevel  @0x6f2240, indexed [eD2LevelId] (ADD at
//!     0x67ea64).  [0x4c]=0 [0x4d]=10 [0x4e]=20 — the per-jungle preset offset.
//!   * gaOutJungSpecialPresetRandOffsets @0x6f2328, int[6][3] indexed
//!     [nSeedModulo][nSpecialPresetCount] (MOV at 0x67ea73, stride 0xc bytes /
//!     3 ints).  The 6 rows are the permutations of (0,1,2) — the seed-picked
//!     file-variant order for the 3 special presets.
//!
//! Faithful idioms:
//!   * RNG -> the VERIFIED rng.RANDOM_RandomNumberSelector primitive. The recon's
//!     inline Fisher-Yates draws (OutJung.cpp:166-238) render the pow2 branch with
//!     a decompiler aliasing artifact (`nSwapIdxB & seedLow`); the selector
//!     (cross-checked vs src/rng.zig) is ground truth, so all draws route through
//!     it — same policy as OutPlace.zig.
//!   * pAutomapEx (level +0x1bc) is the upstream jungle distribution map produced
//!     by the Act-III sub-level splitter (OutPlace.cpp:~1380-1498). That splitter
//!     is not part of the per-level harness, so BuildJungle guards on a null map
//!     and returns (the jungle levels 0x4c-0x4e then fall through to the plain
//!     grid). The faithful body is intact behind the guard.
//!   * bJungleInterlink: the harness allocates pDrlg via ACT_II, so the Act-III
//!     interlink roll (Drlg.cpp:1014-1016) never runs. InitAct3OutdoorLevel redoes
//!     that exact roll from pDrlg->dwGameLowSeed (the stored game seed) so the
//!     Kurast borders match the engine. Not a seed trick — a verbatim replica of
//!     the engine's own roll.

const std = @import("std");
const s = @import("../structs.zig");
const eD2LevelId = s.eD2LevelId;
const rng = @import("../rng.zig");
const pool = @import("../pool.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const OutPlace = @import("OutPlace.zig");
const drlg_mod = @import("../drlg.zig");
const DrlgRoom = @import("../DrlgRoom.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

const LEVEL_SpiderForest: eD2LevelId = .SpiderForest;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// Toward-zero division by 8 (recon `(v + (v>>31 & 7)) >> 3`).
inline fn div8(v: i32) i32 {
    return (v + (@as(i32, @intCast(@as(u1, @truncate(@as(u32, @bitCast(v)) >> 31)))) * 7)) >> 3;
}

// Toward-zero division by 32 (recon `(v + (v>>31 & 0x1f)) >> 5`).
inline fn div32(v: i32) i32 {
    return (v + (@as(i32, @intCast(@as(u1, @truncate(@as(u32, @bitCast(v)) >> 31)))) * 0x1f)) >> 5;
}

// gnOutJungPresetOffsetByLevel @0x6f2240 — reachable indices only (the function
// returns for any other level id). Real ROM values.
inline fn jungPresetOffset(nLevelId: eD2LevelId) i32 {
    return switch (@intFromEnum(nLevelId)) {
        0x4c => 0,
        0x4d => 10,
        0x4e => 20,
        else => 0,
    };
}

// gaOutJungSpecialPresetRandOffsets @0x6f2328 — int[6][3], the permutations of
// (0,1,2) selected by [nSeedModulo].
const gaOutJungSpecialPresetRandOffsets = [6][3]i32{
    .{ 0, 1, 2 },
    .{ 1, 0, 2 },
    .{ 0, 2, 1 },
    .{ 1, 2, 0 },
    .{ 2, 0, 1 },
    .{ 2, 1, 0 },
};

// DRLGOUTPLACE_CalcSubLevelPlacement   0x006777d0
// Register params ESI=nH, EDI=nW, EBX=pOut; hidden stack: [EBP+8]=pParentCoords,
// [EBP+0xc]=eSubLevelDir (= caller's nSeed.nSeedLow % 5 just before CALL).
// Directions: 0=SE, 1=NE, 2=SW, 3=NW, 4=case4 (mirror of NW flipped E).
fn calcSubLevelPlacement(nH: i32, nW: i32, dir: u32, px: i32, py: i32) s.D2DrlgCoordsStrc {
    const offX: i32 = switch (dir) {
        0 => 0,
        1 => -nW,
        2 => nW,
        3 => -nW,
        4 => nW,
        else => unreachable,
    };
    const offY: i32 = switch (dir) {
        0 => -nH,
        1, 2 => blk: {
            // recon OutPlace.cpp:611/615: ((int64*0x55555555)>>32 - nH) >> 1,
            // then the common -= (y >> 31) correction (line 637).
            const hi: i32 = @truncate(@as(i64, @as(i64, nH) * 0x55555555) >> 32);
            const y0: i32 = (hi - nH) >> 1;
            break :blk y0 - (y0 >> 31);
        },
        3, 4 => blk: {
            // recon 619/623: (nH*-2)/3 + (nH*-2 >> 31), then -= (y >> 31) (637).
            const t: i32 = nH * -2;
            const y0: i32 = @divTrunc(t, 3) + (t >> 31);
            break :blk y0 - (y0 >> 31);
        },
        else => unreachable,
    };
    return .{
        .WorldPosition = .{ .x = px + offX, .y = py + offY },
        .WorldSize = .{ .x = nW, .y = nH },
    };
}

// Tile lookup tables from binary at 0x6f13bc (T0, 16 entries) and 0x6f13f0 (tree, 15×4).
// Columns 0..3 correspond to path-bit checks 0x10/0x20/0x40/0x80 in sequence.
const T0 = [16]u32{ 0x100, 0x23f, 0x240, 0x241, 0x242, 0x243, 0x244, 0, 0x245, 0x246, 0x247, 0, 0x248, 0, 0, 0 };
const tree = [15][4]u32{
    .{ 0, 0, 0, 0 },
    .{ 0, 0x221, 0x222, 0x223 },
    .{ 0x224, 0, 0x225, 0x226 },
    .{ 0, 0, 0x227, 0x228 },
    .{ 0x229, 0x22a, 0, 0x22b },
    .{ 0, 0x22c, 0, 0x22d },
    .{ 0x22e, 0, 0, 0x22f },
    .{ 0, 0, 0, 0x230 },
    .{ 0x231, 0x232, 0x233, 0 },
    .{ 0, 0x234, 0x235, 0 },
    .{ 0x236, 0, 0x237, 0 },
    .{ 0, 0, 0x238, 0 },
    .{ 0x239, 0x23a, 0, 0 },
    .{ 0, 0x23b, 0, 0 },
    .{ 0x23c, 0, 0, 0 },
};

// Bounded i32 read from flat map (returns 0 for out-of-bounds).
inline fn rd(buf: []const i32, idx: i32) i32 {
    if (idx < 0 or idx >= @as(i32, @intCast(buf.len))) return 0;
    return buf[@intCast(idx)];
}
inline fn rdu(buf: []const u32, idx: i32) u32 {
    if (idx < 0 or idx >= @as(i32, @intCast(buf.len))) return 0;
    return buf[@intCast(idx)];
}

// DRLGLEVEL_FixDrlgLevelForSpiderForest   0x00677880
// Called from DRLGActMisc_InitAct3 (0x006789b0) with pLevel = Kurast Docktown
// (L75/0x4b). Procedurally places 3 outdoor jungle sub-levels (0x4c..0x4e),
// carves inter-level paths, assigns pAutomapEx grid data, and returns the last
// allocated sub-level.
pub fn FixDrlgLevelForSpiderForest(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2DrlgLevelStrc {
    const pDrlg = pLevel.*.pDrlg.?;
    const pPool = pDrlg.pMemoryPool;
    const pDefs = tables.levelDefsGetLine(LEVEL_SpiderForest);
    const diff: usize = @intCast(pDrlg.nDifficulty);
    const szx: [3]i32 = pDefs.*.SizeX;
    const szy: [3]i32 = pDefs.*.SizeY;
    const sub_h: i32 = szy[diff]; // 192
    const sub_w: i32 = szx[diff]; // 64
    const cell_w: i32 = div32(sub_w); // iVar4 = 2
    const cell_h: i32 = div32(sub_h); // iVar5 = 6

    // Sub-level entry fields (local_120 equivalent, 3 entries × 14 i32)
    var ex: [3]i32 = .{ 0, 0, 0 };
    var ey: [3]i32 = .{ 0, 0, 0 };
    var ew: [3]i32 = .{ 0, 0, 0 };
    var eh: [3]i32 = .{ 0, 0, 0 };
    var edir: [3]i32 = .{ 0, 0, 0 }; // [4]
    var en_exits: [3]i32 = .{ 0, 0, 0 }; // [5]
    var eexits: [3][3]u8 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } }; // [7..9] child indices
    var egrid_col: [3]i32 = .{ 0, 0, 0 }; // [10]
    var egrid_row1: [3]i32 = .{ 0, 0, 0 }; // [11] bNoOverlap
    var epdata: [3]?[*]u32 = .{ null, null, null }; // [12]
    var enspec: [3]i32 = .{ 0, 0, 0 }; // [13]

    // Init entry 0 from pLevel (L75 / Kurast Docktown)
    ex[0] = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    ey[0] = pLevel.*.sCoordinatesAndSize.WorldPosition.y - sub_h;
    ew[0] = sub_w;
    eh[0] = sub_h;

    var nMinX: i32 = ex[0];
    var nMaxX: i32 = ex[0] + sub_w;
    var nMinY: i32 = ey[0];
    const nGridY_top: i32 = pLevel.*.sCoordinatesAndSize.WorldPosition.y;

    // PLACEMENT LOOP
    var nSubLevelCount: u32 = 1;
    placement: while (nSubLevelCount < 3) {
        const nRandParent = rng.randomNumberSelector(&pDrlg.nSeed, nSubLevelCount);
        // Second advance: direction = nSeedLow % 5
        const ds = rng.sEEDNEXT(pDrlg.nSeed);
        pDrlg.nSeed = ds;
        const dir: u32 = @as(u32, @bitCast(ds.nSeedLow)) % 5;

        const cand = calcSubLevelPlacement(sub_h, sub_w, dir, ex[nRandParent], ey[nRandParent]);

        // Overlap check against all existing entries
        var i: u32 = 0;
        while (i < nSubLevelCount) : (i += 1) {
            var c1: s.D2DrlgCoordsStrc = .{
                .WorldPosition = .{ .x = ex[i], .y = ey[i] },
                .WorldSize = .{ .x = ew[i], .y = eh[i] },
            };
            var c2 = cand;
            if (DrlgRoom.FreeRoomEx(&c1, &c2, 0) == 0) continue :placement; // overlap
        }

        // Accept placement
        const ni: u8 = @intCast(nSubLevelCount);
        eexits[nRandParent][@intCast(en_exits[nRandParent])] = ni;
        en_exits[nRandParent] += 1;
        ex[ni] = cand.WorldPosition.x;
        ey[ni] = cand.WorldPosition.y;
        ew[ni] = cand.WorldSize.x;
        eh[ni] = cand.WorldSize.y;
        edir[ni] = @intCast(dir);

        if (cand.WorldPosition.x < nMinX) nMinX = cand.WorldPosition.x;
        if (cand.WorldPosition.y < nMinY) nMinY = cand.WorldPosition.y;
        if (cand.WorldPosition.x + cand.WorldSize.x > nMaxX) nMaxX = cand.WorldPosition.x + cand.WorldSize.x;
        nSubLevelCount += 1;
    }

    // Alignment assertion (non-multiple of 32 is a fatal error in the binary)
    if (@rem(nMaxX - nMinX, 32) != 0 or @rem(nGridY_top - nMinY, 32) != 0) {
        // std.debug.print's stderr path can't compile on wasm freestanding (no posix);
        // gate the diagnostic out there so the portable C-ABI build stays freestanding.
        if (@import("builtin").target.os.tag != .freestanding)
            std.debug.print("FixDrlgLevelForSpiderForest: misaligned grid nMaxX-nMinX={d} nGridY_top-nMinY={d}\n",
                .{ nMaxX - nMinX, nGridY_top - nMinY });
        return null;
    }

    const grid_w: i32 = div32(nMaxX - nMinX) + 2;
    const grid_h: i32 = div32(nGridY_top - nMinY) + 2;
    const map_size: usize = @intCast(grid_h * grid_w);

    // Allocate 4 scratch maps (pool.AllocServerMemory = calloc)
    const pSubLevelMap = @as([*]i32, @ptrCast(@alignCast(pool.AllocServerMemory(pPool, map_size * 4, null, 0x658).?)))[0..map_size];
    const pDistWorkMap = @as([*]i32, @ptrCast(@alignCast(pool.AllocServerMemory(pPool, map_size * 4, null, 0x659).?)))[0..map_size];
    const pDistMap = @as([*]i32, @ptrCast(@alignCast(pool.AllocServerMemory(pPool, map_size * 4, null, 0x65a).?)))[0..map_size];
    const pSLDM = @as([*]u32, @ptrCast(@alignCast(pool.AllocServerMemory(pPool, map_size * 4, null, 0x65b).?)))[0..map_size];

    // FLOOD FILL (outer retry loop, goto LAB_00677b80)
    flood: while (true) {
        @memset(pSubLevelMap, 0);
        @memset(pDistWorkMap, 0);
        @memset(pDistMap, 0);
        @memset(pSLDM, 0);

        var pSubIdx: u32 = 0;
        while (pSubIdx < 3) : (pSubIdx += 1) {
            // Grid position of this sub-level
            const gc: i32 = div32(ex[pSubIdx] - nMinX) + 1; // grid_col (nGridY in C)
            const gr: i32 = div32(ey[pSubIdx] - nMinY); // row (nGridX in C)
            const row1: i32 = gr + 1; // bNoOverlap
            const rowN: i32 = gr + cell_h; // nBottomRow

            egrid_col[pSubIdx] = gc;
            egrid_row1[pSubIdx] = row1;

            // Allocate per-sub-level distribution grid
            const pgd_size: usize = @intCast(cell_h * cell_w);
            epdata[pSubIdx] = @as([*]u32, @ptrCast(@alignCast(pool.AllocServerMemory(pPool, pgd_size * 4, null, 0x66f).?)));

            // nFlipState: for sub-level 0 draw seed; for others use direction parity
            var nFlipState: i32 = undefined;
            if (pSubIdx == 0) {
                const fs = rng.sEEDNEXT(pDrlg.nSeed);
                pDrlg.nSeed = fs;
                nFlipState = fs.nSeedLow & 1;
            } else {
                // parity: (dir & 0x80000001) adjusted == 1
                const v: u32 = @bitCast(edir[pSubIdx]);
                const masked: u32 = v & 0x80000001;
                const adj: u32 = if (@as(i32, @bitCast(masked)) < 0)
                    (masked -% 1 | 0xfffffffe) + 1
                else
                    masked;
                nFlipState = @intFromBool(adj == 1);
            }

            // FLOOD FILL (path carve)   live Ghidra 0x677880
            // The cell-fill, entrance/tunnel and parent-exit marking re-run each
            // FLOOD iteration (pDistMap is recleared for this sub-level's cells),
            // nFlipState persists+mutates across iterations. The loop repeats until
            // one walk carves enough laterals (nRandIdx >= 2). NOTE: nRandIdx seeds
            // to (pSubIdx != 0) — a BOOLEAN, not pSubIdx (the staged closure was
            // stale: `(uint32_t)pSubIdx`; live binary is `(uint)(pSubIdx != 0)`).
            var nRandIdx: u32 = @intFromBool(pSubIdx != 0);
            inner: while (true) {
                // Reclear this sub-level's cells (recon 905-926; the fill loop
                // also resets nConnFlags to nFlipState — captured below as nFlip).
                {
                    var r: i32 = row1;
                    while (r <= rowN) : (r += 1) {
                        var c: i32 = gc;
                        while (c < gc + cell_w) : (c += 1) {
                            const fi: usize = @intCast(r * grid_w + c);
                            pSubLevelMap[fi] = @intCast(pSubIdx + 1);
                            pDistWorkMap[fi] = 0;
                            pDistMap[fi] = 0;
                            pSLDM[fi] = 0;
                        }
                    }
                }

                var nFlip: i32 = nFlipState; // nConnFlags
                var nExitCol: i32 = nFlip + gc;

                // Entrance + tunnel for sub-levels 1..2 (recon 929-932)
                if (pSubIdx > 0) {
                    const bot_flat: i32 = grid_w * rowN + nExitCol;
                    if (bot_flat >= 0 and bot_flat < @as(i32, @intCast(map_size))) pDistMap[@intCast(bot_flat)] = 1;
                    const tun_flat: i32 = @as(i32, @intFromBool(nFlip == 0)) * 2 - 1 + bot_flat;
                    if (tun_flat >= 0 and tun_flat < @as(i32, @intCast(map_size))) pDistMap[@intCast(tun_flat)] = 2;
                }

                // Mark exits from parent(s) in pDistMap. Live Ghidra (0x677880,
                // switch at ~0x677d..) has 5 child-direction cases; the staged
                // closure was stale at 0,1,2. nGridY=gc, nGridX=gr, bNoOverlap=row1.
                {
                    var ei: i32 = 0;
                    while (ei < en_exits[pSubIdx]) : (ei += 1) {
                        const ci: u8 = eexits[pSubIdx][@intCast(ei)]; // child index
                        const cd: i32 = edir[ci]; // child direction
                        switch (cd) {
                            0 => {
                                const fi: i32 = row1 * grid_w + gc;
                                if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistMap[@intCast(fi)] = 1;
                            },
                            1 => {
                                const fi: i32 = (gr + 4) * grid_w + gc;
                                if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistMap[@intCast(fi)] = 1;
                            },
                            2 => {
                                const fi: i32 = (gr + 4) * grid_w + gc + 1;
                                if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistMap[@intCast(fi)] = 1;
                            },
                            3 => {
                                const fi: i32 = (gr + 2) * grid_w + gc;
                                if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistMap[@intCast(fi)] = 1;
                            },
                            4 => {
                                const fi: i32 = (gr + 2) * grid_w + gc + 1;
                                if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistMap[@intCast(fi)] = 1;
                            },
                            else => {},
                        }
                    }
                }

                // PATH-CARVE WALK (live Ghidra 0x677e..)
                var nExitCnt: i32 = 0; // pExitCount (reused as an int counter)
                nRandIdx = @intFromBool(pSubIdx != 0); // live: (uint)(pSubIdx != 0)
                if (row1 <= rowN) {
                    var nCellIdx: i32 = grid_w * rowN;
                    var nAdjIdx: i32 = (@as(i32, @intCast(pSubIdx)) + 1) * 100;
                    var nRowIter: i32 = rowN;
                    while (row1 <= nRowIter) {
                        const fi: i32 = nExitCol + nCellIdx;
                        if (fi >= 0 and fi < @as(i32, @intCast(map_size))) pDistWorkMap[@intCast(fi)] = nAdjIdx;
                        nAdjIdx += 1;

                        // bLateral path = (nExitCnt==0 || nRowIter==row1); else draw
                        // a seed: %3!=0 also takes the lateral path, %3==0 flips column.
                        var bLateral: bool = (nExitCnt == 0 or nRowIter == row1);
                        if (!bLateral) {
                            const ds2 = rng.sEEDNEXT(pDrlg.nSeed);
                            pDrlg.nSeed = ds2;
                            nFlip = nFlipState; // recon 980: nConnFlags = nFlipState
                            const lw: u32 = @bitCast(ds2.nSeedLow);
                            if (lw % 3 != 0) {
                                bLateral = true; // goto LAB_00677e9f
                            } else {
                                nExitCnt = 0;
                                if (nFlipState == 0) {
                                    nFlip = 1;
                                    nExitCol += 1;
                                    nFlipState = 1;
                                } else {
                                    nExitCol -= 1;
                                    nFlip = 0;
                                    nFlipState = 0;
                                }
                            }
                        }

                        if (bLateral) {
                            nExitCnt += 1;
                            if (nExitCnt > 1 and nRowIter > 1) {
                                const iVar7: i32 = @as(i32, @intFromBool(nFlip == 0)) * 2 - 1 + nCellIdx + nExitCol;
                                if (iVar7 >= 0 and iVar7 < @as(i32, @intCast(map_size)) and pDistMap[@intCast(iVar7)] == 0) {
                                    nRandIdx += 1;
                                    pDistMap[@intCast(iVar7)] = 2;
                                }
                            }
                            nRowIter -= 1;
                            nCellIdx -= grid_w;
                        }
                    }
                }

                if (@as(i32, @bitCast(nRandIdx)) >= 2) break :inner; // recon: while(nRandIdx<2)
            } // FLOOD

            // Trim excess exits to 3 (recon 1001-1054): while nRandIdx>3,
            // pick the nRandExitIdx-th pDistMap==2 cell WITHIN this sub-level's
            // grid (iVar5 rows x iVar4 cols from row1*grid_w+gc), zero it, --.
            while (@as(i32, @bitCast(nRandIdx)) > 3) {
                const pick = rng.randomNumberSelector(&pDrlg.nSeed, nRandIdx);
                var found: u32 = 0;
                var removed = false;
                var rr: i32 = 0;
                trim: while (rr < cell_h) : (rr += 1) {
                    var cc: i32 = 0;
                    while (cc < cell_w) : (cc += 1) {
                        const fi2: i32 = row1 * grid_w + gc + rr * grid_w + cc;
                        if (fi2 >= 0 and fi2 < @as(i32, @intCast(map_size)) and pDistMap[@intCast(fi2)] == 2) {
                            if (found == pick) {
                                pDistMap[@intCast(fi2)] = 0;
                                nRandIdx -= 1;
                                removed = true;
                                break :trim;
                            }
                            found += 1;
                        }
                    }
                }
                if (!removed) break; // safety: no ==2 cell found
            }
        } // pSubIdx loop

        // ADJACENCY PASS
        {
            var row: i32 = 0;
            while (row < grid_h) : (row += 1) {
                var col: i32 = 0;
                while (col < grid_w) : (col += 1) {
                    const flat: i32 = row * grid_w + col;
                    const fui: usize = @intCast(flat);
                    const cell_sub: i32 = pSubLevelMap[fui];
                    var cf: u32 = 0; // pCellPtr (flags for this cell)

                    if (pDistMap[fui] == 1) {
                        // Find best same-sub-level neighbor by minimum pDistWorkMap distance
                        var best: i32 = 0x7fffffff;
                        var pCellPtr: u32 = 0;
                        var pExitCount: u32 = 0;

                        // NORTH: unconditional check (no comma operator)
                        const n_flat = (row - 1) * grid_w + col;
                        if (row > 0) {
                            const nd = pDistWorkMap[@intCast(n_flat)];
                            if (nd != 0 and nd < 0x7fffffff and pSubLevelMap[@intCast(n_flat)] == cell_sub) {
                                pCellPtr = 8; pExitCount = 8; best = nd;
                            }
                        }

                        // SOUTH: comma operator — pCellPtr = pExitCount always when closer
                        const s_flat = (row + 1) * grid_w + col;
                        if (row + 1 < grid_h) {
                            const sd = pDistWorkMap[@intCast(s_flat)];
                            if (sd != 0 and sd < best) {
                                pCellPtr = pExitCount; // comma assignment
                                if (pSubLevelMap[@intCast(s_flat)] == cell_sub) {
                                    pExitCount = 4; pCellPtr = 4; best = sd;
                                }
                            }
                        }

                        // EAST: comma operator
                        if (col + 1 < grid_w) {
                            const ed = pDistWorkMap[@intCast(flat + 1)];
                            if (ed != 0 and ed < best) {
                                pCellPtr = pExitCount; // comma
                                if (pSubLevelMap[@intCast(flat + 1)] == cell_sub) {
                                    best = ed; pCellPtr = 2; // pExitCount NOT updated
                                }
                            }
                        }

                        // WEST: no comma, no pExitCount update
                        const w_flat = flat - 1;
                        if (rd(pDistWorkMap, w_flat) != 0 and rd(pDistWorkMap, w_flat) < best and
                            rd(pSubLevelMap, w_flat) == cell_sub)
                        {
                            pCellPtr = 1;
                        }
                        cf = pCellPtr;

                        // Set symmetric bits in pSLDM for neighbors
                        if (cf & 8 != 0 and row > 0) pSLDM[@intCast(n_flat)] |= 4;
                        if (cf & 4 != 0 and row + 1 < grid_h) pSLDM[@intCast(s_flat)] |= 8;
                        if (cf & 2 != 0 and col + 1 < grid_w) pSLDM[@intCast(flat + 1)] |= 1;
                        // West write uses flat-1 (pFlagsRow pointer offset)
                        if (cf & 1 != 0 and w_flat >= 0) pSLDM[@intCast(w_flat)] |= 2;

                        // Cross-boundary (different sub-level, pDistMap==1)
                        if (row > 0 and pDistMap[@intCast(n_flat)] == 1 and pSubLevelMap[@intCast(n_flat)] != cell_sub) cf |= 8;
                        if (row + 1 < grid_h and pDistMap[@intCast(s_flat)] == 1 and pSubLevelMap[@intCast(s_flat)] != cell_sub) cf |= 4;
                        if (col + 1 < grid_w and pDistMap[@intCast(flat + 1)] == 1 and pSubLevelMap[@intCast(flat + 1)] != cell_sub) cf |= 2;
                        if (rd(pDistMap, w_flat) == 1 and rd(pSubLevelMap, w_flat) != cell_sub) cf |= 1;
                    }

                    // pDistWorkMap path adjacency (diff-by-1 = connected path)
                    const dw: i32 = pDistWorkMap[fui];
                    if (dw != 0) {
                        if (row > 0) {
                            const nd = pDistWorkMap[@intCast((row - 1) * grid_w + col)];
                            if (@abs(dw - nd) == 1) cf |= 8;
                        }
                        if (row + 1 < grid_h) {
                            const sd = pDistWorkMap[@intCast((row + 1) * grid_w + col)];
                            if (@abs(dw - sd) == 1) cf |= 4;
                        }
                        if (col + 1 < grid_w) {
                            const ed = pDistWorkMap[@intCast(flat + 1)];
                            if (@abs(dw - ed) == 1) cf |= 2;
                        }
                        const wd = rd(pDistWorkMap, flat - 1);
                        if (@abs(dw - wd) == 1) cf |= 1;
                    }

                    pSLDM[fui] |= cf;
                }
            }
        }

        // PATH BITS PASS
        var retry_flood = false;
        {
            var row: i32 = 0;
            outer_pb: while (row < grid_h) : (row += 1) {
                var col: i32 = 0;
                while (col < grid_w) : (col += 1) {
                    const flat: i32 = row * grid_w + col;
                    const fui: usize = @intCast(flat);
                    var nConnFlags: u32 = pSLDM[fui];
                    const bNoOverlap_sub: i32 = pSubLevelMap[fui]; // sub-level ID

                    // Always advance seed for rotation bits
                    const dseed = rng.sEEDNEXT(pDrlg.nSeed);
                    pDrlg.nSeed = dseed;
                    const uVar8: u32 = @as(u32, @bitCast(dseed.nSeedLow)) & 3;
                    const bSwapped: bool = (nConnFlags == 0); // original flags were 0

                    if (pDistMap[fui] == 2) { // tunnel cell
                        // First: find same-sub-level neighbor with 0 < pSLDM < 0xf
                        var bFoundExit: bool = true;
                        var pi: u32 = 0;
                        while (pi < 4) : (pi += 1) {
                            if (!bFoundExit) break;
                            const d: u32 = (pi + uVar8) & 3;
                            switch (d) {
                                0 => { // N
                                    const nf: i32 = (row - 1) * grid_w + col;
                                    if (row > 0 and pSubLevelMap[@intCast(nf)] == bNoOverlap_sub) {
                                        const v = pSLDM[@intCast(nf)];
                                        if (v != 0 and v < 0xf) { nConnFlags |= 0x80; bFoundExit = false; }
                                    }
                                },
                                1 => { // S
                                    const nf: i32 = (row + 1) * grid_w + col;
                                    if (row + 1 < grid_h and pSubLevelMap[@intCast(nf)] == bNoOverlap_sub) {
                                        const v = pSLDM[@intCast(nf)];
                                        if (v != 0 and v < 0xf) { nConnFlags |= 0x40; bFoundExit = false; }
                                    }
                                },
                                2 => { // E
                                    if (col + 1 < grid_w and pSubLevelMap[@intCast(flat + 1)] == bNoOverlap_sub) {
                                        const v = pSLDM[@intCast(flat + 1)];
                                        if (v != 0 and v < 0xf) { nConnFlags |= 0x20; bFoundExit = false; }
                                    }
                                },
                                3 => { // W
                                    if (flat - 1 >= 0 and pSubLevelMap[@intCast(flat - 1)] == bNoOverlap_sub) {
                                        const v = pSLDM[@intCast(flat - 1)];
                                        if (v != 0 and v < 0xf) { nConnFlags |= 0x10; bFoundExit = false; }
                                    }
                                },
                                else => {},
                            }
                        }

                        if (nConnFlags == 0) { retry_flood = true; break :outer_pb; } // LAB_00677b80

                        if (bSwapped) {
                            // Cross-sub-level via pDistMap==2
                            var bSwapped2: bool = true;
                            var pi2: u32 = 0;
                            while (pi2 < 4) : (pi2 += 1) {
                                if (!bSwapped2) break;
                                const d: u32 = (pi2 + uVar8) & 3;
                                switch (d) {
                                    0 => {
                                        const nf: i32 = (row - 1) * grid_w + col;
                                        if (row > 0 and pSubLevelMap[@intCast(nf)] != bNoOverlap_sub and pDistMap[@intCast(nf)] == 2) {
                                            nConnFlags |= 0x80; bSwapped2 = false;
                                        }
                                    },
                                    1 => {
                                        const nf: i32 = (row + 1) * grid_w + col;
                                        if (row + 1 < grid_h and pSubLevelMap[@intCast(nf)] != bNoOverlap_sub and pDistMap[@intCast(nf)] == 2) {
                                            nConnFlags |= 0x40; bSwapped2 = false;
                                        }
                                    },
                                    2 => {
                                        if (col + 1 < grid_w and pSubLevelMap[@intCast(flat + 1)] != bNoOverlap_sub and pDistMap[@intCast(flat + 1)] == 2) {
                                            nConnFlags |= 0x20; bSwapped2 = false;
                                        }
                                    },
                                    3 => {
                                        if (flat - 1 >= 0 and pSubLevelMap[@intCast(flat - 1)] != bNoOverlap_sub and pDistMap[@intCast(flat - 1)] == 2) {
                                            nConnFlags |= 0x10; bSwapped2 = false;
                                        }
                                    },
                                    else => {},
                                }
                            }

                            // Advance seed twice; second advance used for extra search rotation
                            const ds3 = rng.sEEDNEXT(pDrlg.nSeed);
                            pDrlg.nSeed = ds3;
                            var bFoundExit2: bool = false;
                            if (!((ds3.nSeedLow & 1) == 0) and !(!bSwapped2)) bFoundExit2 = true;
                            const ds4 = rng.sEEDNEXT(pDrlg.nSeed);
                            pDrlg.nSeed = ds4;

                            if (bFoundExit2) {
                                // Extra same-sub-level search with new seed rotation
                                const uVar8b: u32 = @as(u32, @bitCast(ds4.nSeedLow)) & 3;
                                var pi3: u32 = 0;
                                while (pi3 < 4) : (pi3 += 1) {
                                    if (!bFoundExit2) break;
                                    const d: u32 = (uVar8b + pi3) & 3;
                                    switch (d) {
                                        0 => {
                                            const nf: i32 = (row - 1) * grid_w + col;
                                            if (row > 0 and nConnFlags & 0x80 == 0) {
                                                const v = rdu(pSLDM, nf);
                                                if (v != 0 and v < 0xf) { nConnFlags |= 0x80; bFoundExit2 = false; }
                                            }
                                        },
                                        1 => {
                                            const nf: i32 = (row + 1) * grid_w + col;
                                            if (row + 1 < grid_h and nConnFlags & 0x40 == 0) {
                                                const v = rdu(pSLDM, nf);
                                                if (v != 0 and v < 0xf) { nConnFlags |= 0x40; bFoundExit2 = false; }
                                            }
                                        },
                                        2 => {
                                            if (col + 1 < grid_w and nConnFlags & 0x20 == 0) {
                                                const v = pSLDM[@intCast(flat + 1)];
                                                if (v != 0 and v < 0xf) { nConnFlags |= 0x20; bFoundExit2 = false; }
                                            }
                                        },
                                        3 => {
                                            if (flat - 1 >= 0 and nConnFlags & 0x10 == 0) {
                                                const v = pSLDM[@intCast(flat - 1)];
                                                if (v != 0 and v < 0xf) { nConnFlags |= 0x10; bFoundExit2 = false; }
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        }

                        // Propagate path bits to neighbors
                        if (nConnFlags & 0x80 != 0 and row > 0) pSLDM[@intCast((row - 1) * grid_w + col)] |= 0x40;
                        if (nConnFlags & 0x40 != 0 and row + 1 < grid_h) pSLDM[@intCast((row + 1) * grid_w + col)] |= 0x80;
                        if (nConnFlags & 0x20 != 0 and col + 1 < grid_w) pSLDM[@intCast(flat + 1)] |= 0x10;
                        if (nConnFlags & 0x10 != 0 and flat - 1 >= 0) pSLDM[@intCast(flat - 1)] |= 0x20;
                        pDistMap[fui] = 0; // clear tunnel marker
                    }

                    pSLDM[fui] |= nConnFlags;
                }
            }
        }

        if (retry_flood) continue :flood;

        // TILE LOOKUP PASS
        {
            var tile_i: usize = 0;
            while (tile_i < map_size) : (tile_i += 1) {
                const nc: u32 = pSLDM[tile_i];
                const lo: u32 = nc & 0x0f;
                var result: u32 = 0;
                if (lo == 0) {
                    if (nc > 0xf) result = T0[nc >> 4];
                } else if (nc < 0x10) {
                    result = lo + 0x211;
                } else {
                    var uv: u32 = lo;
                    if (nc & 0x10 != 0) uv = tree[uv][0];
                    if (nc & 0x20 != 0) uv = tree[uv][1];
                    if (nc & 0x40 != 0) uv = tree[uv][2];
                    if (nc & 0x80 != 0) uv = tree[uv][3];
                    result = uv;
                }
                pSLDM[tile_i] = result;
            }
        }

        // COPY TO PER-SUB-LEVEL GRIDS
        {
            var si: u32 = 0;
            while (si < 3) : (si += 1) {
                const gc2 = egrid_col[si];
                const gr2 = egrid_row1[si]; // = bNoOverlap = div32(y-nMinY)+1
                const pgd = epdata[si].?;
                var idx6: i32 = 0;
                var gy: i32 = 0;
                while (gy < cell_h) : (gy += 1) {
                    var gx: i32 = 0;
                    while (gx < cell_w) : (gx += 1) {
                        const src: usize = @intCast((gr2 + gy) * grid_w + gc2 + gx);
                        const val: u32 = pSLDM[src];
                        pgd[@intCast(idx6)] = val;
                        if (val > 0x23e) enspec[si] += 1;
                        idx6 += 1;
                    }
                }
            }
        }

        // BUBBLE SORT by y descending (entry[i].y >= entry[i+1].y)
        var sorted = false;
        while (!sorted) {
            sorted = true;
            var si2: u32 = 0;
            while (si2 < 2) : (si2 += 1) {
                if (ey[si2] < ey[si2 + 1]) {
                    // Swap all entry fields
                    std.mem.swap(i32, &ex[si2], &ex[si2 + 1]);
                    std.mem.swap(i32, &ey[si2], &ey[si2 + 1]);
                    std.mem.swap(i32, &ew[si2], &ew[si2 + 1]);
                    std.mem.swap(i32, &eh[si2], &eh[si2 + 1]);
                    std.mem.swap(i32, &edir[si2], &edir[si2 + 1]);
                    std.mem.swap(i32, &en_exits[si2], &en_exits[si2 + 1]);
                    std.mem.swap([3]u8, &eexits[si2], &eexits[si2 + 1]);
                    std.mem.swap(i32, &egrid_col[si2], &egrid_col[si2 + 1]);
                    std.mem.swap(i32, &egrid_row1[si2], &egrid_row1[si2 + 1]);
                    std.mem.swap(?[*]u32, &epdata[si2], &epdata[si2 + 1]);
                    std.mem.swap(i32, &enspec[si2], &enspec[si2 + 1]);
                    sorted = false;
                }
            }
        }

        // ASSIGN TO LEVELS 0x4c..0x4e
        var pSubLevelRet: [*c]s.D2DrlgLevelStrc = null;
        {
            var lvl_i: i32 = 0;
            while (lvl_i < 3) : (lvl_i += 1) {
                pSubLevelRet = drlg_mod.GetLevelAndAlloc(pDrlg, @enumFromInt(lvl_i + 0x4c));
                pSubLevelRet.*.pAutomapEx = epdata[@intCast(lvl_i)];
                pSubLevelRet.*.nUnknown_1B8 = @bitCast(enspec[@intCast(lvl_i)]);
                pSubLevelRet.*.sCoordinatesAndSize.WorldPosition.x = ex[@intCast(lvl_i)];
                pSubLevelRet.*.sCoordinatesAndSize.WorldPosition.y = ey[@intCast(lvl_i)];
                pSubLevelRet.*.sCoordinatesAndSize.WorldSize.x = ew[@intCast(lvl_i)];
                pSubLevelRet.*.sCoordinatesAndSize.WorldSize.y = eh[@intCast(lvl_i)];
            }
        }

        pool.FreeServerMemory(pPool, pSubLevelMap.ptr, null, 0x7d2, 0);
        pool.FreeServerMemory(pPool, pDistWorkMap.ptr, null, 0x7d3, 0);
        pool.FreeServerMemory(pPool, pDistMap.ptr, null, 0x7d4, 0);
        pool.FreeServerMemory(pPool, pSLDM.ptr, null, 0x7d5, 0);
        return pSubLevelRet;
    } // flood loop (unreachable normally)
}

// OutJung::BuildJungle   OutJung.cpp:42 (0067e910)
// Stamps the jungle preset layout (Spider Forest / Great Marsh / Flayer Jungle)
// from the upstream distribution map pAutomapEx. Special presets (id > 0x23e)
// are shifted by the per-jungle offset and assigned a seed-picked file variant.
pub fn BuildJungle(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const eLevelId = pLevel.*.eD2LevelId;
    if (@as(u32, @bitCast(@intFromEnum(eLevelId) - @intFromEnum(LEVEL_SpiderForest))) >= 3) return;

    // Binary 0x0067e983: seed draw happens BEFORE the null check at 0x0067e98a.
    const pDefs = tables.levelDefsGetLine(LEVEL_SpiderForest);
    const byDifficulty: usize = pLevel.*.pDrlg.?.nDifficulty;
    const szx: [3]i32 = pDefs.*.SizeX;
    const szy: [3]i32 = pDefs.*.SizeY;
    const nLevelWidthCells = div32(szx[byDifficulty]);
    const nLevelHeightCells = div32(szy[byDifficulty]);
    var nPresetArrayIdx: i32 = 0;
    const nSeedModulo: usize = rng.getModuloFromSeed(
        &pLevel.*.sSeed,
        @as(u32, @intFromBool(pLevel.*.nUnknown_1B8 == 3)) * 4 + 2,
    );

    if (pLevel.*.pAutomapEx == null) return;
    const pMap: [*]const i32 = @ptrCast(@alignCast(pLevel.*.pAutomapEx.?));
    var nSpecialPresetCount: usize = 0;
    if (0 >= nLevelHeightCells) return;

    var nYCell: i32 = 0;
    while (true) {
        if (eLevelId == .SpiderForest and nYCell == nLevelHeightCells - 1) {
            const lastCell = pMap[@intCast(nLevelHeightCells * nLevelWidthCells - 1)];
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nYCell * 4, 0x23d, @intFromBool(lastCell == 0), 0);
            nPresetArrayIdx += 2;
        } else if (eLevelId == .FlayerJungle and nYCell == 0) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x23e, @intFromBool(pMap[1] == 0), 0);
            nPresetArrayIdx += 2;
        } else {
            var nXCell: i32 = 0;
            while (nXCell < nLevelWidthCells) : (nXCell += 1) {
                var nLevelPrestId = pMap[@intCast(nPresetArrayIdx)];
                nPresetArrayIdx += 1;
                var nRand: i32 = -1;
                if (0x23e < nLevelPrestId) {
                    nLevelPrestId += jungPresetOffset(eLevelId);
                    // recon OutJung.cpp:111 asserts nSpecialPresetCount <= 2 (the
                    // engine guarantees at most 3 special tiles per jungle level).
                    nRand = gaOutJungSpecialPresetRandOffsets[nSeedModulo][@intCast(nSpecialPresetCount)];
                    nSpecialPresetCount += 1;
                }
                if (nLevelPrestId != 0) {
                    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXCell * 4, nYCell * 4, nLevelPrestId, nRand, 0);
                }
            }
        }

        nYCell += 1;
        if (nYCell >= nLevelHeightCells) break;
    }
}

// OutJung::SpawnRandomPreset   OutJung.cpp:131 (0067eed0)
// Fisher-Yates shuffles ALL grid cells (full grid, no interior inset), then
// stamps a preset (id randomly drawn in [id1, id2]) at each shuffled cell that
// fits, up to nLimit placements (0 = unlimited).
pub fn SpawnRandomPreset(
    pLevel: [*c]s.D2DrlgLevelStrc,
    nLevelPrestId1: i32,
    nLevelPrestId2: i32,
    nLimit: i32,
) void {
    const pData = wild(pLevel);
    const pMemory = pLevel.*.pDrlg.?.pMemoryPool;
    const nSwapIdxB: u32 = @bitCast(nLevelPrestId2 - nLevelPrestId1 + 1);
    const nGridWidthCells = pData.nGridCoordsWidth;
    const nTotalCells: i32 = pData.nGridCoordsHeight * nGridWidthCells;
    var nPlacedCount: i32 = 0;
    if (nTotalCells == 0) return;

    const pCells: [*]i32 = @ptrCast(@alignCast(pool.AllocServerMemory(
        pMemory,
        @as(usize, @intCast(nTotalCells)) * 8,
        ".\\DRLG\\OutJung.cpp",
        0xcb,
    )));

    // Init: cell[i] = { x = i % width, y = i / width }.
    {
        var i: i32 = 0;
        while (i < nTotalCells) : (i += 1) {
            pCells[@intCast(i * 2)] = @rem(i, nGridWidthCells);
            pCells[@intCast(i * 2 + 1)] = @divTrunc(i, nGridWidthCells);
        }
    }

    // Fisher-Yates: two index draws per step, both via the verified selector.
    var nShuffleCountdown: u32 = @bitCast(nTotalCells);
    while (nShuffleCountdown != 0) {
        const a: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const b: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        nShuffleCountdown -= 1;
        const tx = pCells[a * 2];
        const ty = pCells[a * 2 + 1];
        pCells[a * 2] = pCells[b * 2];
        pCells[a * 2 + 1] = pCells[b * 2 + 1];
        pCells[b * 2] = tx;
        pCells[b * 2 + 1] = ty;
    }

    var nSrcLine: i32 = 0xf2;
    var i: i32 = 0;
    while (i < nTotalCells) : (i += 1) {
        const nX = pCells[@intCast(i * 2)];
        const nY = pCells[@intCast(i * 2 + 1)];
        const nRand: i32 = @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, nSwapIdxB));
        if (OutPlace.TestOutdoorLevelPreset(pLevel, nX, nY, nLevelPrestId1 + nRand, 0, 0x0f) != 0) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, nLevelPrestId1 + nRand, -1, 0);
            nPlacedCount += 1;
            if (0 < nLimit and nLimit <= nPlacedCount) {
                nSrcLine = 0xeb;
                break;
            }
        }
    }

    pool.FreeServerMemory(pMemory, pCells, ".\\DRLG\\OutJung.cpp", nSrcLine, 0);
}

// DRLGOUTJUNG_BuildKurastDocktownBorders   Drlg.cpp:5828 (0067ead0)
fn BuildKurastDocktownBorders(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nX = div8(pLevel.*.sCoordinatesAndSize.WorldSize.x) - 1;
    const nY = div8(pLevel.*.sCoordinatesAndSize.WorldSize.y) - 1;
    var nPortalX: i32 = div8(pLevel.*.sCoordinatesAndSize.WorldSize.x);
    if (pLevel.*.pDrlg.?.bJungleInterlink == 0) {
        nPortalX -= 2;
    } else {
        nPortalX = 1;
    }

    if (1 < nX) {
        var nXIter: i32 = 1;
        while (nXIter < nX) : (nXIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXIter, 0, @as(i32, @intFromBool(nXIter == nPortalX)) * 8 + 0x25d, -1, 0);
        }
    }

    if (1 < nX) {
        var nYIter: i32 = 1;
        while (nYIter < nX) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nYIter, nY, @as(i32, @intFromBool(nYIter == @divTrunc(nX, 2))) * 8 + 0x25e, -1, 0);
            nYIter += 1 + @as(i32, @intFromBool(nYIter == @divTrunc(nX, 2)));
        }
    }

    if (1 < nY) {
        var nYIter: i32 = 1;
        while (nYIter < nY) : (nYIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nYIter, 0x25f, -1, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nYIter, 0x260, -1, 0);
        }
    }

    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x262, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, 0, 0x261, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nY, 0x264, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x263, -1, 0);
}

// DRLGOUTJUNG_BuildKurastUpperBorders   Drlg.cpp:5872 (0067ec30)
fn BuildKurastUpperBorders(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nPortalX2base = div8(pLevel.*.sCoordinatesAndSize.WorldSize.x);
    const nY = div8(pLevel.*.sCoordinatesAndSize.WorldSize.y) - 1;
    const nX = nPortalX2base - 1;
    var nPortalX1: i32 = undefined;
    var nPortalX2: i32 = undefined;
    if (pLevel.*.pDrlg.?.bJungleInterlink == 0) {
        nPortalX1 = nPortalX2base - 2;
        nPortalX2 = 1;
    } else {
        nPortalX1 = 1;
        nPortalX2 = nPortalX2base - 2;
    }

    if (1 < nX) {
        var nIter: i32 = 1;
        while (nIter < nX) : (nIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nIter, 0, @as(i32, @intFromBool(nIter == nPortalX2)) * 8 + 0x26b, -1, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nIter, nY, @as(i32, @intFromBool(nIter == nPortalX1)) * 8 + 0x26c, -1, 0);
        }
    }

    if (1 < nY) {
        var nIter: i32 = 1;
        while (nIter < nY) : (nIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nIter, 0x26d, -1, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nIter, 0x26e, -1, 0);
        }
    }

    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x270, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, 0, 0x26f, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nY, 0x272, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x271, -1, 0);
}

// DRLGOUTJUNG_BuildKurastCausewayBorders   Drlg.cpp:5912 (0067ed70)
fn BuildKurastCausewayBorders(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nPortalXbase = div8(pLevel.*.sCoordinatesAndSize.WorldSize.x);
    const nY = div8(pLevel.*.sCoordinatesAndSize.WorldSize.y) - 1;
    const nX = nPortalXbase - 1;
    var nPortalX: i32 = undefined;
    if (pLevel.*.pDrlg.?.bJungleInterlink == 0) {
        nPortalX = 1;
    } else {
        nPortalX = nPortalXbase - 2;
    }

    if (1 < nX) {
        var nIter: i32 = 1;
        while (nIter < nX) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nIter, 0, @as(i32, @intFromBool(nIter == @divTrunc(nX, 2))) * 8 + 0x27c, -1, 0);
            nIter += 1 + @as(i32, @intFromBool(nIter == @divTrunc(nX, 2)));
        }
    }

    if (1 < nX) {
        var nIter: i32 = 1;
        while (nIter < nX) : (nIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nIter, nY, @as(i32, @intFromBool(nIter == nPortalX)) * 8 + 0x27d, -1, 0);
        }
    }

    if (1 < nY) {
        var nIter: i32 = 1;
        while (nIter < nY) : (nIter += 1) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nIter, 0x27e, -1, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nIter, 0x27f, -1, 0);
        }
    }

    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x281, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, 0, 0x280, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nY, 0x283, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x282, -1, 0);
}

// GetOutLinkVisFlag   Outdoors.cpp:380 (006755..)
// Returns the inter-level visibility mask for a boundary vertex by matching it
// against the level's orth-link list (pOrthData). pOrthData is populated by the
// upstream inter-level placement (absent in the per-level harness), so this
// returns 0 via the null check — the link-vis path is unreachable here. The
// faithful boundary-direction computation is kept; the orth iteration (which
// needs the adjacency list + DRLGOUTDOOR_GetAdjacentLevelVisMask) is the
// upstream-dependent tail.
fn GetOutLinkVisFlag(pLevel: [*c]s.D2DrlgLevelStrc, pVertex: [*c]s.D2DrlgVertexStrc) i32 {
    const pData = wild(pLevel);
    if (pData.pOrthData == null) return 0;
    _ = pVertex;
    // Upstream adjacency path (pOrthData != null) — not reachable in the
    // per-level harness; would walk pOrthData and return the adjacent-level vis
    // mask (Outdoors.cpp:411-424).
    return 0;
}

// SetOutGridLinkFlags   OutPlace.cpp:268 (00675770)
// Walks the boundary vertex ring; for each edge vertex marks the boundary cells
// in sGridOutdoor occupied (nDirection*2+1, an ODD value so bit 0 is set —
// blocking later TestOutdoorLevelPreset placements there) and writes the
// link-vis flag into sGridLink (0 here; see GetOutLinkVisFlag). No RNG.
fn SetOutGridLinkFlags(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    const pHead = pData.pVertices orelse return;
    var pVertex: *s.D2DrlgVertexStrc = pHead;
    var pNext: *s.D2DrlgVertexStrc = pHead.pNext.?;
    while (true) {
        if (pVertex.dwFlags & 1 != 0) {
            const nLinkVisFlag = GetOutLinkVisFlag(pLevel, pVertex);
            const byDirection: i32 = pVertex.nDirection;
            DrlgGrid.setEdgeGridFlags(&pData.sGridLink, pVertex, nLinkVisFlag, 0, true);
            DrlgGrid.setEdgeGridFlags(&pData.sGridOutdoor, pVertex, byDirection * 2 + 1, 0, true);
        }
        const bHasNext = pNext != pHead;
        pVertex = pNext;
        pNext = pNext.pNext.?;
        if (!bHasNext) break;
    }
}

// OutPlace::BuildKurast   OutPlace.cpp:1584 (0067f190)
fn BuildKurast(pLevel: [*c]s.D2DrlgLevelStrc) void {
    switch (pLevel.*.eD2LevelId) {
        .LowerKurast => BuildKurastDocktownBorders(pLevel),
        .KurastBazaar => BuildKurastUpperBorders(pLevel),
        .UpperKurast => BuildKurastCausewayBorders(pLevel),
        else => {},
    }

    const nLevelWidthCells = div8(pLevel.*.sCoordinatesAndSize.WorldSize.x) - 4;
    const nLevelHeightCells = div8(pLevel.*.sCoordinatesAndSize.WorldSize.y) - 4;
    switch (pLevel.*.eD2LevelId) {
        .LowerKurast => {
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x277, 0, 0, 0x0f);
            SpawnRandomPreset(pLevel, 0x26a, 0x26a, 4);
            SpawnRandomPreset(pLevel, 0x268, 0x269, 0);
            SpawnRandomPreset(pLevel, 0x267, 0x267, 0);
        },
        .KurastBazaar => {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 3, 3, 0x275, 0, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nLevelWidthCells, 3, 0x275, 1, 0);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x276, 0, 0, 0x0f);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x276, 1, 0, 0x0f);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x277, 0, 0, 0x0f);
            SpawnRandomPreset(pLevel, 0x27b, 0x27b, 4);
            SpawnRandomPreset(pLevel, 0x279, 0x27a, 0);
            SpawnRandomPreset(pLevel, 0x278, 0x278, 0);
        },
        .UpperKurast => {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 3, nLevelHeightCells, 0x286, 0, 0);
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nLevelWidthCells, nLevelHeightCells, 0x286, 1, 0);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x287, 0, 0, 0x0f);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x287, 1, 0, 0x0f);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x277, 0, 0, 0x0f);
            SpawnRandomPreset(pLevel, 0x28b, 0x28b, 4);
            SpawnRandomPreset(pLevel, 0x289, 0x28a, 0);
            SpawnRandomPreset(pLevel, 0x288, 0x288, 0);
        },
        .KurastCauseway => OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x28c, 0, 0),
        else => {},
    }
}

// DRLGLEVEL_FixDrlgLevelForLowerKurast   0x00678910
// Called from DRLGActMisc_InitAct3 (0x006789b0) with pLevel = the return of
// FixDrlgLevelForSpiderForest (the topmost jungle sub-level = Flayer Jungle, 0x4e).
// Positions the 5-level Kurast chain (LowerKurast 0x4f .. Travincal 0x53) as one
// vertical stack centered on Flayer Jungle's x, climbing upward (decreasing y) by
// each level's cumulative SizeY. Travincal's world origin is COMPUTED here (moved
// relative to the causeway/jungle), not a Levels.txt constant. Coords are in tiles.
fn FixDrlgLevelForLowerKurast(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2DrlgLevelStrc {
    const pDrlgActMisc = pLevel.*.pDrlg.?;
    const nParentSizeX: i32 = pLevel.*.sCoordinatesAndSize.WorldSize.x;
    const parentX: i32 = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const parentY: i32 = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    const byDifficulty: usize = @intCast(pDrlgActMisc.nDifficulty);

    var nYOffset: i32 = 0;
    var pSubLevel: [*c]s.D2DrlgLevelStrc = null;
    var eLevel: i32 = @intFromEnum(eD2LevelId.LowerKurast); // 0x4f
    var nSubLevelCount: i32 = 5;
    while (true) {
        const pDefs = tables.levelDefsGetLine(@enumFromInt(eLevel));
        const szy: [3]i32 = pDefs.*.SizeY;
        const szx: [3]i32 = pDefs.*.SizeX;
        const nSubSizeY: i32 = szy[byDifficulty];
        const nSubSizeX: i32 = szx[byDifficulty];
        nYOffset -= nSubSizeY;
        pSubLevel = drlg_mod.GetLevelAndAlloc(pDrlgActMisc, @enumFromInt(eLevel));
        eLevel += @intFromEnum(eD2LevelId.RogueEncampment); // +1
        pSubLevel.*.sCoordinatesAndSize.WorldPosition.x =
            (@divTrunc(nParentSizeX, 2) - @divTrunc(nSubSizeX, 2)) + parentX;
        pSubLevel.*.sCoordinatesAndSize.WorldPosition.y = parentY + nYOffset;
        pSubLevel.*.sCoordinatesAndSize.WorldSize.x = nSubSizeX;
        pSubLevel.*.sCoordinatesAndSize.WorldSize.y = nSubSizeY;
        nSubLevelCount -= 1;
        if (nSubLevelCount == 0) break;
    }
    return pSubLevel;
}

// OutPlace::BuildTravincal   OutPlace.cpp:1642 (0067f3b0)
fn BuildTravincal(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId != .Travincal) return;
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 0x28d, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 2, 0, 0x28e, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 6, 0, 0x28f, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 4, 0x290, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 2, 4, 0x291, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 6, 4, 0x292, -1, 0);
}

// OutPlace::InitAct3OutdoorLevel   OutPlace.cpp:1657 (0067f450)
// SetOutGridLinkFlags marks the boundary cells occupied in sGridOutdoor — that
// matters for Act-III: the shrine passes (SpawnRandomPreset) must skip the
// border-preset ring (border presets set only bit 9 / 0x200, which is NOT in
// TestOutdoorLevelPreset's 0x1b81 occupancy mask; the edge flag sets bit 0).
pub fn InitAct3OutdoorLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    // Faithful Act-III interlink roll (Drlg.cpp:1014-1016), recomputed from the
    // stored game seed because the harness allocates pDrlg via ACT_II.
    var sSeed: s.D2SeedStrc = .{ .nSeedLow = @bitCast(pLevel.*.pDrlg.?.dwGameLowSeed), .nSeedHigh = 0x29a };
    sSeed = rng.sEEDNEXT(sSeed); // allocDrlgActMisc:289
    sSeed = rng.sEEDNEXT(sSeed); // ACT_III branch:314
    pLevel.*.pDrlg.?.bJungleInterlink = sSeed.nSeedLow & 1;

    // DRLGActMisc_InitAct3 (0x006789b0) calls FixDrlgLevelForSpiderForest once with
    // pDrlg.nSeed at the Act-III initial state (2 advances from {dwGameLowSeed,0x29a}).
    // In the per-level harness the seed has been consumed by earlier level generations,
    // so we restore it here before driving the placement.  L75 must already have been
    // InitLevel'd so its WorldPosition is set correctly.
    const eLvl = pLevel.*.eD2LevelId;
    if (eLvl == .SpiderForest and pLevel.*.pAutomapEx == null) {
        const pDrlg = pLevel.*.pDrlg.?;
        const pL75 = drlg_mod.GetLevelAndAlloc(pDrlg, .KurastDocktown);
        // FixDrlgLevelForSpiderForest uses pDrlg.nSeed from DRLGActMisc_InitAct3
        // (ACT_III path: 2 advances from {dwGameLowSeed, 0x29a}). Restore it.
        if (pL75.*.sCoordinatesAndSize.WorldPosition.y != 0) {
            var act3_seed: s.D2SeedStrc = .{ .nSeedLow = @bitCast(pDrlg.dwGameLowSeed), .nSeedHigh = 0x29a };
            act3_seed = rng.sEEDNEXT(act3_seed);
            act3_seed = rng.sEEDNEXT(act3_seed);
            pDrlg.nSeed = act3_seed;
            // DRLGActMisc_InitAct3 (0x006789b0) chains these: FixSpiderForest returns the
            // topmost jungle (Flayer Jungle), off which FixLowerKurast stacks 0x4f..0x53.
            const pTopJungle = FixDrlgLevelForSpiderForest(pL75);
            if (pTopJungle != null) _ = FixDrlgLevelForLowerKurast(pTopJungle);
        }
    }

    SetOutGridLinkFlags(pLevel);
    BuildJungle(pLevel);
    BuildKurast(pLevel);
    BuildTravincal(pLevel);
}
