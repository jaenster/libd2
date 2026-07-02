//! Faithful Zig transform of recon/closure/DrlgVer.cpp
//! (D2Common::Drlg::DrlgVer — DRLG border/path vertex ring construction).
//!
//! RESOLUTIONS (cited inline):
//!  * `void* pDrlgRoomData` is a D2DrlgOrthStrc* (linked via pNext@0x14). The
//!    recon's raw byte offsets map to named fields:
//!      +0x04 neDrlgDirection, +0x08 bIsDrlgTypePresetArea,
//!      +0x10 psCoordinatesAndSize, +0x14 pNext.
//!    psCoordinatesAndSize (D2DrlgCoordsStrc, WorldPosition/WorldSize) is read
//!    as a D2DrlgCoordStrc (nPosX/nPosY/nWidth/nHeight) — identical 4×i32 layout.
//!  * vertex alloc size 0x14 (32-bit sizeof) -> @sizeOf(D2DrlgVertexStrc) for the
//!    64-bit standalone (the closure-to-Zig 64-bit key).
//!  * decompiler precedence artifact `*pSizePtr--` (decrements the pointer) is
//!    the engine's `(*pSizePtr)--` (decrement the coord size) — resolved as such,
//!    matching the symmetric restore loop. (CreateRoomVertices lines 176/178/235/237)

const std = @import("std");
const s = @import("structs.zig");
const pool = @import("pool.zig");
const forward = @import("forward.zig");

const D2DrlgVertexStrc = s.D2DrlgVertexStrc;
const D2DrlgCoordStrc = s.D2DrlgCoordStrc;
const D2DrlgOrthStrc = s.D2DrlgOrthStrc;
const D2PoolManagerStrc = s.D2PoolManagerStrc;

/// DrlgVer.cpp:25 (1.14d 0067cdd0)
pub fn allocVertex(pMemory: ?*D2PoolManagerStrc, nDirection: u8) [*c]D2DrlgVertexStrc {
    const pVertex: [*c]D2DrlgVertexStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2DrlgVertexStrc), ".\\DRLG\\DrlgVer.cpp", 0x13)));
    pVertex.*.nPosX = 0;
    pVertex.*.nPosY = 0;
    pVertex.*.nDirection = 0;
    pVertex.*.dwFlags = 0;
    pVertex.*.pNext = null;
    pVertex.*.nDirection = nDirection;
    return pVertex;
}

/// DrlgVer.cpp:38 (1.14d 0067ce00)
pub fn setVertexFlags(pVertex: [*c]D2DrlgVertexStrc, nFlag: i32) void {
    pVertex.*.dwFlags |= 1;
    if (nFlag == 0) {
        return;
    }
    pVertex.*.dwFlags |= 2;
}

/// DrlgVer.cpp:49 (1.14d 0067ce20)
pub fn createVerticesFromEdges(pMemory: ?*D2PoolManagerStrc, pFirstVertex: [*c]D2DrlgVertexStrc, pDrlgCoord: [*c]D2DrlgCoordStrc, nDirection: u8, pDrlgRoomData: ?*anyopaque) [*c]D2DrlgVertexStrc {
    var nEdgeMin: i32 = undefined;
    var pNewVertex: [*c]D2DrlgVertexStrc = undefined;
    var nEdgeMax: i32 = undefined;
    var nCoordMax: i32 = undefined;
    var nCoordMin: i32 = undefined;
    var pEdgeVertex: [*c]D2DrlgVertexStrc = undefined;
    var nAnchorPos: i32 = undefined;
    var nEdgeVtxPos: i32 = undefined;
    var bHasGap: bool = undefined;

    const pVertex1 = pFirstVertex.*.pNext;
    const pThirdVertex = pVertex1.?.pNext;
    const pVertex2 = pThirdVertex.?.pNext; // 4th ring vertex (cases 2/3)

    var pOrth: [*c]D2DrlgOrthStrc = @ptrCast(@alignCast(pDrlgRoomData));
    if (pOrth == null) {
        return @ptrCast(&pThirdVertex.?.pNext);
    }

    while (true) {
        // +0x10 psCoordinatesAndSize, read as D2DrlgCoordStrc; null -> pDrlgCoord
        var pEffectiveCoord: [*c]D2DrlgCoordStrc = @ptrCast(@alignCast(pOrth.*.psCoordinatesAndSize));
        if (pOrth.*.psCoordinatesAndSize == null) {
            pEffectiveCoord = pDrlgCoord;
        }

        // The closure decompile (recon DrlgVer.cpp:75) lost the switch's cases 2/3
        // to a dropped jump table (the "dup default" artifact). Cases 0..3 recovered
        // FAITHFULLY from Ghidra Game.exe 1.14d @0067ce20 (session 62fbfe69): the four
        // edges are Y-top(0)/X-right(1)/Y-bottom(2)/X-left(3) with the per-edge anchor
        // vertex + comparison sign below.
        switch (pOrth.*.neDrlgDirection) { // +0x04
            0 => {
                nCoordMax = pEffectiveCoord.*.nPosY;
                nAnchorPos = pVertex1.?.nPosY;
                nEdgeMin = pFirstVertex.*.nPosY;
                bHasGap = true;
                nEdgeVtxPos = -1;
                nCoordMin = pEffectiveCoord.*.nHeight + nCoordMax;
                pEdgeVertex = pFirstVertex;
            },
            1 => {
                nCoordMin = pEffectiveCoord.*.nPosX;
                nEdgeVtxPos = 1;
                nCoordMax = pEffectiveCoord.*.nWidth + nCoordMin;
                pNewVertex = pThirdVertex;
                pEdgeVertex = pVertex1;
                bHasGap = false; // LAB_0067ceb7
                nAnchorPos = pNewVertex.*.nPosX;
                nEdgeMin = pEdgeVertex.*.nPosX;
            },
            2 => {
                nCoordMin = pEffectiveCoord.*.nPosY;
                nAnchorPos = pVertex2.?.nPosY;
                nEdgeMin = pThirdVertex.?.nPosY;
                nEdgeVtxPos = 1;
                bHasGap = true;
                nCoordMax = pEffectiveCoord.*.nHeight + nCoordMin;
                pEdgeVertex = pThirdVertex;
            },
            3 => {
                nCoordMax = pEffectiveCoord.*.nPosX;
                nEdgeVtxPos = -1;
                nCoordMin = pEffectiveCoord.*.nWidth + nCoordMax;
                pNewVertex = pFirstVertex;
                pEdgeVertex = pVertex2;
                bHasGap = false; // LAB_0067ceb7
                nAnchorPos = pNewVertex.*.nPosX;
                nEdgeMin = pEdgeVertex.*.nPosX;
            },
            else => {
                @panic("DRLGVER: unrecoverable internal error (recon 0x6d)");
            },
        }

        nEdgeMin *= nEdgeVtxPos;
        nEdgeMax = nCoordMin * nEdgeVtxPos;
        var run_lab = false;
        if ((nEdgeMax - nEdgeMin) == 0 or nEdgeMax < nEdgeMin) {
            if (nEdgeMin <= nCoordMax * nEdgeVtxPos) {
                run_lab = true;
            }
        } else if ((nEdgeMax - nAnchorPos * nEdgeVtxPos) == 0 or nEdgeMax < nAnchorPos * nEdgeVtxPos) {
            pNewVertex = allocVertex(pMemory, nDirection);
            if (bHasGap) {
                pNewVertex.*.nPosX = pEdgeVertex.*.nPosX;
                pNewVertex.*.nPosY = nCoordMin;
            } else {
                pNewVertex.*.nPosY = pEdgeVertex.*.nPosY;
                pNewVertex.*.nPosX = nCoordMin;
            }
            pNewVertex.*.pNext = pEdgeVertex.*.pNext;
            pEdgeVertex.*.pNext = pNewVertex;
            pEdgeVertex = pNewVertex;
            run_lab = true; // goto LAB_0067cf79
        }

        if (run_lab) {
            // LAB_0067cf79
            nCoordMin = pOrth.*.bIsDrlgTypePresetArea; // +0x08
            pEdgeVertex.*.dwFlags |= 1;
            if (nCoordMin != 0) {
                pEdgeVertex.*.dwFlags |= 2;
            }
            if (nCoordMax * nEdgeVtxPos < nAnchorPos * nEdgeVtxPos) {
                pNewVertex = allocVertex(pMemory, nDirection);
                if (bHasGap) {
                    pNewVertex.*.nPosX = pEdgeVertex.*.nPosX;
                    pNewVertex.*.nPosY = nCoordMax;
                } else {
                    pNewVertex.*.nPosY = pEdgeVertex.*.nPosY;
                    pNewVertex.*.nPosX = nCoordMax;
                }
                pNewVertex.*.pNext = pEdgeVertex.*.pNext;
                pEdgeVertex.*.pNext = pNewVertex;
            }
        }

        pOrth = @ptrCast(@alignCast(pOrth.*.pNext)); // +0x14
        if (pOrth == null) {
            return null;
        }
    }
}

/// DrlgVer.cpp:169 (1.14d 0067d050)
pub fn createRoomVertices(pMemory: ?*D2PoolManagerStrc, ppVertices: [*c][*c]D2DrlgVertexStrc, pDrlgCoord: [*c]D2DrlgCoordStrc, nDirection: u8, pDrlgRoomData: ?*anyopaque) void {
    pDrlgCoord.*.nWidth -= 1;
    pDrlgCoord.*.nHeight -= 1;

    var pRoomData: [*c]D2DrlgOrthStrc = @ptrCast(@alignCast(pDrlgRoomData));
    while (pRoomData != null) : (pRoomData = @ptrCast(@alignCast(pRoomData.*.pNext))) {
        const pCoord: [*c]D2DrlgCoordStrc = @ptrCast(@alignCast(pRoomData.*.psCoordinatesAndSize)); // +0x10
        pCoord.*.nWidth -= 1; // +0x08, resolved (*pSizePtr)--
        pCoord.*.nHeight -= 1; // +0x0c
    }

    var pVertex = allocVertex(pMemory, nDirection);
    ppVertices.* = pVertex;
    pVertex.*.nPosX = pDrlgCoord.*.nPosX;
    pVertex.*.nPosY = pDrlgCoord.*.nPosY + pDrlgCoord.*.nHeight;

    var pVertexNext = allocVertex(pMemory, nDirection);
    pVertex.*.pNext = pVertexNext;
    pVertexNext.*.nPosX = pDrlgCoord.*.nPosX;
    pVertexNext.*.nPosY = pDrlgCoord.*.nPosY;

    pVertex = allocVertex(pMemory, nDirection);
    pVertexNext.*.pNext = pVertex;
    pVertex.*.nPosX = pDrlgCoord.*.nPosX + pDrlgCoord.*.nWidth;
    pVertex.*.nPosY = pDrlgCoord.*.nPosY;

    pVertexNext = allocVertex(pMemory, nDirection);
    pVertex.*.pNext = pVertexNext;
    pVertexNext.*.nPosX = pDrlgCoord.*.nPosX + pDrlgCoord.*.nWidth;
    pVertexNext.*.nPosY = pDrlgCoord.*.nPosY + pDrlgCoord.*.nHeight;
    pVertexNext.*.pNext = ppVertices.*;

    _ = createVerticesFromEdges(pMemory, ppVertices.*, pDrlgCoord, nDirection, pDrlgRoomData);

    pVertex = ppVertices.*;
    pVertexNext = pVertex;
    while (true) {
        pVertexNext.*.nPosX -= pDrlgCoord.*.nPosX;
        pVertexNext.*.nPosY -= pDrlgCoord.*.nPosY;
        pVertexNext = pVertexNext.*.pNext;
        if (pVertexNext == pVertex) break;
    }

    pDrlgCoord.*.nWidth += 1;
    pDrlgCoord.*.nHeight += 1;
    var pRestore: [*c]D2DrlgOrthStrc = @ptrCast(@alignCast(pDrlgRoomData));
    while (pRestore != null) : (pRestore = @ptrCast(@alignCast(pRestore.*.pNext))) {
        const pCoord: [*c]D2DrlgCoordStrc = @ptrCast(@alignCast(pRestore.*.psCoordinatesAndSize));
        pCoord.*.nWidth += 1; // resolved (*pSizePtr)++
        pCoord.*.nHeight += 1;
    }
}

/// DrlgVer.cpp:243 (1.14d 0067d1e0)
pub fn freeVertices(pMemory: ?*D2PoolManagerStrc, ppVertices: [*c][*c]D2DrlgVertexStrc) void {
    if (ppVertices.* == null) {
        return;
    }

    var pNext: [*c]D2DrlgVertexStrc = null;
    var freed_ring = false;
    var pCurrent = ppVertices.*.*.pNext;
    if (pCurrent == null) {
        freed_ring = true; // goto LAB_0067d22f
    } else {
        while (true) {
            pNext = pCurrent.?.pNext;
            pool.FreeServerMemory(pMemory, pCurrent, ".\\DRLG\\DrlgVer.cpp", 0x114, 0);
            pCurrent = pNext;
            if (pNext == ppVertices.*) break;
        }
        pool.FreeServerMemory(pMemory, pNext, ".\\DRLG\\DrlgVer.cpp", 0x117, 0);
        if (pNext == null) {
            freed_ring = true;
        }
    }

    if (freed_ring) {
        pool.FreeServerMemory(pMemory, ppVertices.*, ".\\DRLG\\DrlgVer.cpp", 0x11f, 0);
    }
    ppVertices.* = null;
}

/// DrlgVer.cpp:271 (1.14d 0067d280)
pub fn GetCoordDiff(pDrlgVertex: [*c]D2DrlgVertexStrc, pDiffX: [*c]i32, pDiffY: [*c]i32) void {
    pDiffX.* = pDrlgVertex.*.pNext.?.nPosX - pDrlgVertex.*.nPosX;
    pDiffY.* = pDrlgVertex.*.pNext.?.nPosY - pDrlgVertex.*.nPosY;
    if (pDiffX.* < 0) {
        pDiffX.* = -1;
    } else if (0 < pDiffX.*) {
        pDiffX.* = 1;
    }
    if (pDiffY.* < 0) {
        pDiffY.* = -1;
        return;
    }
    if (0 >= pDiffY.*) {
        return;
    }
    pDiffY.* = 1;
}

test "DrlgVer: vertex alloc + flags + coord diff" {
    const v = allocVertex(null, 3);
    defer pool.FreeServerMemory(null, v, "", 0, 0);
    try std.testing.expectEqual(@as(u8, 3), v.*.nDirection);
    setVertexFlags(v, 1);
    try std.testing.expectEqual(@as(i32, 3), v.*.dwFlags);

    const a = allocVertex(null, 0);
    const b = allocVertex(null, 0);
    defer pool.FreeServerMemory(null, a, "", 0, 0);
    defer pool.FreeServerMemory(null, b, "", 0, 0);
    a.*.nPosX = 2;
    a.*.nPosY = 5;
    b.*.nPosX = 7;
    b.*.nPosY = 1;
    a.*.pNext = b;
    var dx: i32 = 0;
    var dy: i32 = 0;
    GetCoordDiff(a, &dx, &dy);
    try std.testing.expectEqual(@as(i32, 1), dx);
    try std.testing.expectEqual(@as(i32, -1), dy);
}
