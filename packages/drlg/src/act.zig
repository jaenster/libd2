//! Act-level DRLG graph: derives every level's world origin (x,y) + size (w,h)
//! and the inter-level warp adjacency for one act, from the game's init seed.
//!
//! Two positioning paths, exactly as the engine:
//!   - Levels listed in the act's placement graph get their origin from a
//!     backtracking placement walk (DRLGLEVEL_ParseLevelData, 1.14d 006774xx):
//!     each node is placed adjacent to its predecessor in an RNG-chosen
//!     direction, re-rolled on overlap until the whole chain fits.
//!   - Every other level is offset-chained off its Levels.txt Depend
//!     (DRLG_SetLevelPositionAndSize / DRLGLEVEL_SetLevelSizeAndAlignVsDependentLevel,
//!     1.14d 00642d10): pos = Offset + depend.pos, recursively.
//!
//! The placement RNG runs off the act seed AFTER the act-specific pre-rolls
//! (Act II Horadric/boss tomb selection, Act III jungle interlink) — see
//! DRLG_AllocDrlgActMisc (1.14d 00642da0). Placement callbacks, the 8-direction
//! tables and the FreeRoomEx overlap test are ported bit-exact from the binary.

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");
const oracle = @import("oracle.zig");

pub const Coords = oracle.Coords;

const MAX_NODES = 15; // D2DrlgLevelPlacementStrc fixed arrays (0xf entries)

/// One placement callback used by the level-data graph. Names map to the binary:
///   fixed   = fpLDE1                        (1.14d 006760f0) world origin = Levels.txt Offset
///   adj2    = DRLGPLACE_Adjacent2DirRandom  (1.14d 006769a0) 2-side, 1 roll
///   dir8    = fpLevelDataEntry              (1.14d 00676280) 8-dir half-size+8
///   dir8a   = DRLGPLACE_Adjacent8DirAligned (1.14d 00676ae0) 8-roll, 4 aligned edges
///   lde2    = fpLDE2                        (1.14d 00676150) 4-dir, 1 roll, +-0x10 nudge
///   lde3    = fpLDE3                        (1.14d 00676650) 4-dir + flip, resizes (Blood Moor)
///   lde4    = fpLDE4                        (1.14d 00676450) 4-dir + flip, +-8 nudge
///   lde5    = fpLDE5                        (1.14d 006768c0) deterministic dir 0, NO roll
///   mirror4 = DRLGPLACE_Adjacent4DirMirrored(1.14d 006762.. ) dir 3 fixed, 1 roll picks y-mirror
///   ofix    = DRLGPLACE_OrientedFixedOffset (1.14d 0067d830) 1 roll: 90° orient + size, off prev
///   oabs    = DRLGPLACE_OrientedAbsolutePos (1.14d 0067d8e0) 1 roll: orient + size, abs Offset
///   otab    = DRLGPLACE_OrientedTableLookup (1.14d 0067d980) 2-dir orient, table-offset off prev
const PlaceFn = enum { fixed, adj2, dir8, dir8a, lde2, lde3, lde4, lde5, mirror4, ofix, oabs, otab };

/// Per-list validation gate (the fpLevelDataFn1 passed to ParseLevelData).
///   none     = nullptr (Act V lists 1/2): first placement always accepted
///   overlap  = DRLGPLACE_ACT{2,4}_Validate.. / ACT5_List3: no overlap w/ non-prev nodes
///   act1_l1  = DRLGPLACE_ACT1_ValidatePlacementList1: overlap + Rogue-camp layout table +
///              Burial-grounds direction-uniqueness gap
///   act1_l2  = DRLGPLACE_ACT1_ValidatePlacementList2WithGap: overlap + a 200-tile clearance
///              band above the cow level (node 0)
const Validate = enum { none, overlap, act1_l1, act1_l2 };

const Node = struct {
    level_id: i64,
    place: PlaceFn,
    prev: i32, // node index this one is positioned against (-1 = none)
    next: i32, // forward warp link (-1 = none)
};

/// Act II placement graph (DRLGACTMISC_AllocDrlgLevelForAct, ACT_II branch).
/// List 1 is the town→desert→snakes chain; list 2 is the lone Canyon of the Magi.
const act2_list1 = [_]Node{
    .{ .level_id = 40, .place = .fixed, .prev = -1, .next = -1 }, // Lut Gholein (town)
    .{ .level_id = 41, .place = .adj2, .prev = 0, .next = -1 }, // Rocky Waste
    .{ .level_id = 42, .place = .dir8, .prev = 1, .next = -1 }, // Dry Hills
    .{ .level_id = 43, .place = .dir8, .prev = 2, .next = -1 }, // Far Oasis
    .{ .level_id = 44, .place = .dir8, .prev = 3, .next = -1 }, // Lost City
    .{ .level_id = 45, .place = .dir8a, .prev = 4, .next = -1 }, // Valley of Snakes
};
const act2_list2 = [_]Node{
    .{ .level_id = 46, .place = .fixed, .prev = -1, .next = -1 }, // Canyon of the Magi
};

/// Act I (DRLGACTMISC_AllocDrlgLevelForAct, ACT_I branch). List 1 is the wilderness
/// trunk anchored at Stony Field; list 2 is the Monastery approach + the cow level.
const act1_list1 = [_]Node{
    .{ .level_id = 4, .place = .fixed, .prev = -1, .next = -1 }, // Stony Field (anchor)
    .{ .level_id = 3, .place = .lde2, .prev = 0, .next = -1 }, // Cold Plains
    .{ .level_id = 2, .place = .lde3, .prev = 1, .next = -1 }, // Blood Moor (resizes)
    .{ .level_id = 1, .place = .lde4, .prev = 2, .next = -1 }, // Rogue Encampment (town)
    .{ .level_id = 17, .place = .lde2, .prev = 1, .next = -1 }, // Burial Grounds
};
const act1_list2 = [_]Node{
    .{ .level_id = 39, .place = .fixed, .prev = -1, .next = -1 }, // Moo Moo Farm (cow level)
    .{ .level_id = 26, .place = .fixed, .prev = -1, .next = -1 }, // Monastery Gate
    .{ .level_id = 7, .place = .lde5, .prev = 1, .next = -1 }, // Tamoe Highland
    .{ .level_id = 6, .place = .lde2, .prev = 2, .next = -1 }, // Black Marsh
    .{ .level_id = 5, .place = .lde2, .prev = 3, .next = -1 }, // Dark Wood
};

/// Act IV (ACT_IV branch). List 1 trunk off the Pandemonium Fortress; list 2 the lone
/// Chaos Sanctuary. Note: Act IV skips warp-wiring in ParseLevelData (nActNo==4).
const act4_list1 = [_]Node{
    .{ .level_id = 103, .place = .fixed, .prev = -1, .next = -1 }, // Pandemonium Fortress (town)
    .{ .level_id = 104, .place = .mirror4, .prev = 0, .next = -1 }, // Outer Steppes
    .{ .level_id = 105, .place = .lde2, .prev = 1, .next = -1 }, // Plains of Despair
    .{ .level_id = 106, .place = .lde2, .prev = 2, .next = -1 }, // City of the Damned
};
const act4_list2 = [_]Node{
    .{ .level_id = 108, .place = .fixed, .prev = -1, .next = -1 }, // Chaos Sanctuary
};

/// Act V (ACT_V branch). List 1 the foothills trunk off Harrogath; list 2 the lone
/// Frozen Tundra (absolute-positioned); list 3 the Forgotten Sands / Uber Tristram pair.
/// Lists 1 and 2 run with NO validation gate (first placement always taken).
const act5_list1 = [_]Node{
    .{ .level_id = 109, .place = .fixed, .prev = -1, .next = -1 }, // Harrogath (town)
    .{ .level_id = 110, .place = .fixed, .prev = 0, .next = -1 }, // Bloody Foothills
    .{ .level_id = 111, .place = .ofix, .prev = 1, .next = -1 }, // Frigid Highlands (orients)
    .{ .level_id = 112, .place = .otab, .prev = 2, .next = -1 }, // Arreat Plateau (orients)
};
const act5_list2 = [_]Node{
    .{ .level_id = 117, .place = .oabs, .prev = -1, .next = -1 }, // Frozen Tundra (abs offset)
};
const act5_list3 = [_]Node{
    .{ .level_id = 134, .place = .fixed, .prev = -1, .next = -1 }, // Forgotten Sands (uber)
    .{ .level_id = 136, .place = .fixed, .prev = -1, .next = -1 }, // Uber Tristram
};

/// DRLGPLACE_OrientedTableLookup offset table (1.14d data @ 006f1f7c, interleaved
/// gnDrlgLevelGenerationState/Flags). Indexed by curDir + prevDir*2; each entry is the
/// (dx,dy) of the placed level's origin relative to its predecessor's origin.
const orient_table_x = [4]i32{ 0, -96, -64, -160 };
const orient_table_y = [4]i32{ -160, -64, -96, 0 };

/// DRLGPLACE_ACT1_ValidatePlacementList1 RogueEncampentLayout[64] (1.14d .data): a
/// gate on (curDir,flip) of Rogue Encampment vs (curDir,flip) of its predecessor
/// Blood Moor. Index = curDir + 4*(flip + 2*(prevDir + 4*prevFlip)). 1 = allowed.
const rogue_layout = [64]u8{
    1, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 1, 0, 1, 0, 0,
    1, 0, 0, 0, 0, 0, 1, 1,
    0, 1, 0, 0, 0, 0, 0, 1,
    0, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 1, 1, 0,
    1, 0, 0, 0, 0, 0, 1, 1,
};

// DRLGLEVEL_ParseLevelData placement walk

const Placement = struct {
    seed: rng.Seed,
    nodes: []const Node,
    coords: [MAX_NODES]Coords = [_]Coords{.{}} ** MAX_NODES,
    initial_dir: [MAX_NODES]i32 = [_]i32{-1} ** MAX_NODES,
    cur_dir: [MAX_NODES]i32 = [_]i32{-1} ** MAX_NODES,
    flip: [MAX_NODES]i32 = [_]i32{-1} ** MAX_NODES, // aFlipState: rolled once, fixes cycle end
    step: [MAX_NODES]i32 = [_]i32{-1} ** MAX_NODES, // aStepCounter: alternates 0/1 each re-dispatch
    cur: usize = 0,

    fn prevCoords(self: *Placement, node: usize) *Coords {
        return &self.coords[@intCast(self.nodes[node].prev)];
    }

    /// fpLDE1: a fixed world origin straight from Levels.txt Offset. No RNG.
    fn placeFixed(self: *Placement, tb: *const tables.Tables) bool {
        const def = tb.level(self.nodes[self.cur].level_id).?;
        self.coords[self.cur].x = @intCast(def.offset_x);
        self.coords[self.cur].y = @intCast(def.offset_y);
        return true;
    }

    /// DRLGPLACE_Adjacent2DirRandom: place against the predecessor on one of two
    /// sides (left or above), the first chosen by a single RNG step.
    fn placeAdj2(self: *Placement) bool {
        const node = self.cur;
        if (self.initial_dir[node] == -1) {
            _ = self.seed.next();
            self.initial_dir[node] = @intCast((self.seed.low & 1) + 1);
            self.cur_dir[node] = self.initial_dir[node];
        } else {
            const nxt: i32 = 2 - @as(i32, if (self.cur_dir[node] != 1) 1 else 0);
            if (nxt == self.initial_dir[node]) return false;
            self.cur_dir[node] = nxt;
        }
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        if (self.cur_dir[node] != 1) {
            switch (self.cur_dir[node]) {
                0 => {
                    s.x = p.w - s.w + p.x;
                    s.y = p.h + p.y;
                },
                2 => {
                    s.x = p.x;
                    s.y = p.y - s.h;
                },
                3 => {
                    s.x = p.w + p.x;
                    s.y = p.y;
                },
                else => {},
            }
            return true;
        }
        s.x = p.x - s.w;
        s.y = p.y;
        return true;
    }

    /// Advance/seed an 8-way (mod-8) rotation; false once every direction is
    /// exhausted. Shared by fpLevelDataEntry and DRLGPLACE_Adjacent8DirAligned.
    fn rollDir8(self: *Placement) bool {
        const node = self.cur;
        if (self.initial_dir[node] == -1) {
            _ = self.seed.next();
            self.initial_dir[node] = @intCast(self.seed.low & 7);
            self.cur_dir[node] = self.initial_dir[node];
        } else {
            const nxt: i32 = (self.cur_dir[node] + 1) & 7;
            if (nxt == self.initial_dir[node]) return false;
            self.cur_dir[node] = nxt;
        }
        return true;
    }

    /// fpLevelDataEntry: 8 directions = 4 sides × 2 perpendicular shifts, each
    /// offsetting the half-size +8 tiles off the predecessor's matching edge.
    fn placeDir8(self: *Placement) bool {
        if (!self.rollDir8()) return false;
        const node = self.cur;
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        switch (self.cur_dir[node]) {
            0 => {
                s.x = p.x - 8 - @divTrunc(s.w, 2);
                s.y = p.y + p.h;
            },
            1 => {
                s.x = p.x + @divTrunc(s.w, 2) + 8;
                s.y = p.y + p.h;
            },
            2 => {
                s.x = p.x - s.w;
                s.y = p.y - @divTrunc(s.h, 2) - 8;
            },
            3 => {
                s.x = p.x - s.w;
                s.y = p.y + @divTrunc(s.h, 2) + 8;
            },
            4 => {
                s.x = p.x - 8 - @divTrunc(s.w, 2);
                s.y = p.y - s.h;
            },
            5 => {
                s.x = p.x + @divTrunc(s.w, 2) + 8;
                s.y = p.y - s.h;
            },
            6 => {
                s.x = p.x + p.w;
                s.y = p.y - @divTrunc(s.h, 2) - 8;
            },
            7 => {
                s.x = p.x + p.w;
                s.y = p.y + @divTrunc(s.h, 2) + 8;
            },
            else => {},
        }
        return true;
    }

    /// DRLGPLACE_Adjacent8DirAligned: same 8-way roll, but the pairs collapse to
    /// the four edge-aligned placements (no perpendicular shift).
    fn placeDir8Aligned(self: *Placement) bool {
        if (!self.rollDir8()) return false;
        const node = self.cur;
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        switch (self.cur_dir[node]) {
            0, 1 => {
                s.x = p.x;
                s.y = p.h + p.y;
            },
            2, 3 => {
                s.x = p.x - s.w;
                s.y = p.y;
            },
            4, 5 => {
                s.x = p.x;
                s.y = p.y - s.h;
            },
            6, 7 => {
                s.x = p.w + p.x;
                s.y = p.y;
            },
            else => {},
        }
        return true;
    }

    /// fpLDE2: place against the predecessor on one of four sides, chosen by a single
    /// mod-4 roll, each side nudged 0x10 tiles to leave a doorway gap.
    fn placeLDE2(self: *Placement) bool {
        const node = self.cur;
        if (self.initial_dir[node] == -1) {
            _ = self.seed.next();
            self.initial_dir[node] = @intCast(self.seed.low & 3);
            self.cur_dir[node] = self.initial_dir[node];
        } else {
            const nxt: i32 = (self.cur_dir[node] + 1) & 3;
            if (nxt == self.initial_dir[node]) return false;
            self.cur_dir[node] = nxt;
        }
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        switch (self.cur_dir[node]) {
            0 => {
                s.x = p.x - 16;
                s.y = p.y + p.h;
            },
            1 => {
                s.x = p.x - s.w;
                s.y = p.y - 16;
            },
            2 => {
                s.x = p.x + p.w - s.w + 16;
                s.y = p.y - s.h;
            },
            3 => {
                s.x = p.x + p.w;
                s.y = p.y + p.h - s.h + 16;
            },
            else => {},
        }
        return true;
    }

    /// fpLDE5: deterministic — always direction 0 (below the predecessor), consumes NO
    /// RNG. Re-running on a backtrack is therefore a no-op on the seed.
    fn placeLDE5(self: *Placement) bool {
        const node = self.cur;
        self.initial_dir[node] = 0;
        self.cur_dir[node] = 0;
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        s.x = p.x;
        s.y = p.y + p.h;
        return true;
    }

    /// fpLDE3/fpLDE4 share this roll: on first entry, two RNG steps seed a direction
    /// (mod 4) and a flip (mod 2); each re-dispatch advances dir by the running step
    /// counter and toggles the step, exhausting after all 8 (dir,flip) pairs.
    fn rollDir4Flip(self: *Placement) bool {
        const node = self.cur;
        if (self.initial_dir[node] == -1) {
            _ = self.seed.next();
            self.initial_dir[node] = @intCast(self.seed.low & 3);
            self.cur_dir[node] = self.initial_dir[node];
            _ = self.seed.next();
            self.flip[node] = @intCast(self.seed.low & 1);
            self.step[node] = self.flip[node];
        } else {
            const nxt_dir: i32 = (self.cur_dir[node] + self.step[node]) & 3;
            const nxt_flip: i32 = (self.step[node] + 1) & 1;
            if (nxt_dir == self.initial_dir[node] and nxt_flip == self.flip[node]) return false;
            self.cur_dir[node] = nxt_dir;
            self.step[node] = nxt_flip;
        }
        return true;
    }

    /// fpLDE4: 4-dir + flip placement, with an 8-tile gap nudge on the off-axis.
    fn placeLDE4(self: *Placement) bool {
        if (!self.rollDir4Flip()) return false;
        const node = self.cur;
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        if (self.step[node] != 0) {
            switch (self.cur_dir[node]) {
                0 => {
                    s.x = p.x;
                    s.y = p.y + p.h;
                },
                1 => {
                    s.x = p.x - s.w;
                    s.y = p.y + 8;
                },
                2 => {
                    s.x = p.x + p.w - s.w;
                    s.y = p.y - s.h;
                },
                3 => {
                    s.x = p.x + p.w;
                    s.y = p.y + p.h - s.h - 8;
                },
                else => {},
            }
        } else {
            switch (self.cur_dir[node]) {
                0 => {
                    s.x = p.x + p.w - s.w;
                    s.y = p.y + p.h;
                },
                1 => {
                    s.x = p.x - s.w;
                    s.y = p.y + p.h - s.h - 8;
                },
                2 => {
                    s.x = p.x;
                    s.y = p.y - s.h;
                },
                3 => {
                    s.x = p.x + p.w;
                    s.y = p.y + 8;
                },
                else => {},
            }
        }
        return true;
    }

    /// fpLDE3 (Blood Moor): 4-dir + flip, but first RESIZES the level by direction
    /// parity — odd dirs make it wide (0x60×0x38), even dirs tall (0x38×0x60) — then
    /// places with a 0x10 doorway nudge.
    fn placeLDE3(self: *Placement) bool {
        if (!self.rollDir4Flip()) return false;
        const node = self.cur;
        const s = &self.coords[node];
        const parity = self.cur_dir[node] & 1;
        s.w = if (parity != 0) 0x60 else 0x38;
        s.h = if (parity != 0) 0x38 else 0x60;
        const p = self.prevCoords(node);
        if (self.step[node] != 0) {
            switch (self.cur_dir[node]) {
                0 => {
                    s.x = p.x - 16;
                    s.y = p.y + p.h;
                },
                1 => {
                    s.x = p.x - s.w;
                    s.y = p.y - 16;
                },
                2 => {
                    s.x = p.x + p.w - s.w + 16;
                    s.y = p.y - s.h;
                },
                3 => {
                    s.x = p.x + p.w;
                    s.y = p.y + p.h - s.h + 16;
                },
                else => {},
            }
        } else {
            switch (self.cur_dir[node]) {
                0 => {
                    s.x = p.x + p.w - s.w + 16;
                    s.y = p.y + p.h;
                },
                1 => {
                    s.x = p.x - s.w;
                    s.y = p.y + p.h - s.h + 16;
                },
                2 => {
                    s.x = p.x - 16;
                    s.y = p.y - s.h;
                },
                3 => {
                    s.x = p.x + p.w;
                    s.y = p.y - 16;
                },
                else => {},
            }
        }
        return true;
    }

    /// DRLGPLACE_Adjacent4DirMirrored (Outer Steppes): direction is fixed at 3 (right of
    /// predecessor); a single roll mirrors the vertical alignment. Always succeeds, so it
    /// re-rolls (and re-consumes RNG) every time the walk backtracks into it.
    fn placeMirror4(self: *Placement) bool {
        const node = self.cur;
        self.initial_dir[node] = 3;
        self.cur_dir[node] = 3;
        _ = self.seed.next();
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        s.x = p.x + p.w;
        s.y = if (self.seed.low & 1 != 0) p.y + p.h - s.h + 8 else p.y - 8;
        return true;
    }

    /// Oriented size: even roll => 0x40×0xa0 (tall), odd => 0xa0×0x40 (wide).
    fn orientSize(self: *Placement, node: usize, dir: i32) void {
        const s = &self.coords[node];
        if (self.seed.low & 1 == 0) {
            s.w = 0x40;
            s.h = 0xa0;
        } else if (dir != 0) {
            s.w = 0xa0;
            s.h = 0x40;
        }
    }

    /// DRLGPLACE_OrientedFixedOffset (Frigid Highlands): one roll picks a 90° orientation
    /// (and matching size); origin sits to the left of the predecessor, bottom-aligned.
    fn placeOrientFixed(self: *Placement) bool {
        const node = self.cur;
        _ = self.seed.next();
        const d: i32 = @intCast(self.seed.low & 1);
        self.cur_dir[node] = d;
        self.initial_dir[node] = d;
        self.orientSize(node, d);
        const p = self.prevCoords(node);
        const s = &self.coords[node];
        s.x = p.x - s.w;
        s.y = p.y + p.h - s.h - 16;
        return true;
    }

    /// DRLGPLACE_OrientedAbsolutePos (Frozen Tundra): same orient roll, but the origin is
    /// the level's absolute Levels.txt Offset (not relative to any predecessor).
    fn placeOrientAbs(self: *Placement, tb: *const tables.Tables) bool {
        const node = self.cur;
        _ = self.seed.next();
        const d: i32 = @intCast(self.seed.low & 1);
        self.cur_dir[node] = d;
        self.initial_dir[node] = d;
        self.orientSize(node, d);
        const def = tb.level(self.nodes[node].level_id).?;
        const s = &self.coords[node];
        s.x = @intCast(def.offset_x);
        s.y = @intCast(def.offset_y);
        return true;
    }

    /// DRLGPLACE_OrientedTableLookup (Arreat Plateau): a 2-way orient roll; the origin is
    /// the predecessor's origin plus a table offset keyed on (curDir, predecessor's dir).
    fn placeOrientTable(self: *Placement) bool {
        const node = self.cur;
        if (self.initial_dir[node] == -1) {
            _ = self.seed.next();
            self.initial_dir[node] = @intCast(self.seed.low & 1);
            self.cur_dir[node] = self.initial_dir[node];
        } else {
            const nxt: i32 = if (self.cur_dir[node] == 0) 1 else 0;
            if (nxt == self.initial_dir[node]) return false;
            self.cur_dir[node] = nxt;
        }
        const dir = self.cur_dir[node];
        const s = &self.coords[node];
        if (dir == 0) {
            s.w = 0x40;
            s.h = 0xa0;
        } else {
            s.w = 0xa0;
            s.h = 0x40;
        }
        const prev_dir = self.cur_dir[@intCast(self.nodes[node].prev)];
        const idx: usize = @intCast(dir + prev_dir * 2);
        const p = self.prevCoords(node);
        s.x = orient_table_x[idx] + p.x;
        s.y = orient_table_y[idx] + p.y;
        return true;
    }

    fn dispatch(self: *Placement, tb: *const tables.Tables) bool {
        return switch (self.nodes[self.cur].place) {
            .fixed => self.placeFixed(tb),
            .adj2 => self.placeAdj2(),
            .dir8 => self.placeDir8(),
            .dir8a => self.placeDir8Aligned(),
            .lde2 => self.placeLDE2(),
            .lde3 => self.placeLDE3(),
            .lde4 => self.placeLDE4(),
            .lde5 => self.placeLDE5(),
            .mirror4 => self.placeMirror4(),
            .ofix => self.placeOrientFixed(),
            .oabs => self.placeOrientAbs(tb),
            .otab => self.placeOrientTable(),
        };
    }
};

/// DRLGCOORDS_IsWithinDistance(.., nSize=0) wrapped by FreeRoomEx (1.14d 0066b860):
/// "free" (true) unless the two rects overlap on BOTH axes.
fn freeRoomEx(a: Coords, b: Coords) bool {
    const dx = if (a.x < b.x) b.x - a.w - a.x else a.x - b.w - b.x;
    const dy = if (a.y < b.y) b.y - a.h - a.y else a.y - b.h - b.y;
    return !(dx < 0 and dy < 0);
}

/// The common overlap gate (DRLGPLACE_ACT{2,4}_Validate.. / ACT5_List3 / the first half
/// of the Act I gates): the freshly placed node must not overlap any already-placed node
/// other than its own predecessor.
fn validateNoOverlap(p: *Placement, node: usize) bool {
    var i: usize = 0;
    while (i < node) : (i += 1) {
        if (@as(i32, @intCast(i)) != p.nodes[node].prev) {
            if (!freeRoomEx(p.coords[node], p.coords[i])) return false;
        }
    }
    return true;
}

/// DRLGPLACE_ACT1_ValidatePlacementList1: overlap gate, plus two extra constraints.
/// Rogue Encampment must land on an allowed (dir,flip)×(prevDir,prevFlip) combo per the
/// layout table; Burial Grounds must not share a direction with its sibling (Blood Moor,
/// the other branch off Cold Plains).
fn validateAct1List1(p: *Placement, node: usize) bool {
    if (!validateNoOverlap(p, node)) return false;
    const lvl = p.nodes[node].level_id;
    if (lvl == 1) { // Rogue Encampment
        const prev: usize = @intCast(p.nodes[node].prev);
        const i: usize = @intCast(p.cur_dir[node] + 4 * (p.step[node] + 2 * (p.cur_dir[prev] + 4 * p.step[prev])));
        return rogue_layout[i] != 0;
    }
    if (lvl == 17) { // Burial Grounds
        const prev_id = p.nodes[node].prev;
        for (p.nodes, 0..) |n, i| {
            if (i != node and n.prev == prev_id and p.cur_dir[node] == p.cur_dir[i]) return false;
        }
    }
    return true;
}

/// DRLGPLACE_ACT1_ValidatePlacementList2WithGap: overlap gate, plus a 200-tile clearance
/// band raised above the cow level (node 0) that the placed node must also stay clear of.
fn validateAct1List2(p: *Placement, node: usize) bool {
    if (!validateNoOverlap(p, node)) return false;
    if (node == 0) return true;
    var cow = p.coords[0];
    cow.h += 200;
    cow.y -= 200;
    return freeRoomEx(cow, p.coords[node]);
}

fn runValidate(p: *Placement, node: usize, kind: Validate) bool {
    return switch (kind) {
        .none => true,
        .overlap => validateNoOverlap(p, node),
        .act1_l1 => validateAct1List1(p, node),
        .act1_l2 => validateAct1List2(p, node),
    };
}

/// Run one level-data list: size every node from Levels.txt, then walk the chain
/// placing each node and backtracking on overlap. Writes derived origins into
/// `out` keyed by level id. `seed` is taken by value (the engine copies the act
/// seed into the placement state and never writes it back).
fn runPlacement(
    tb: *const tables.Tables,
    nodes: []const Node,
    seed: rng.Seed,
    validate: Validate,
) Placement {
    var p = Placement{ .seed = seed, .nodes = nodes };
    for (nodes, 0..) |n, i| {
        const def = tb.level(n.level_id).?;
        p.coords[i].w = @intCast(def.size_x);
        p.coords[i].h = @intCast(def.size_y);
    }

    var node: i32 = 0;
    while (node >= 0 and node < nodes.len) {
        p.cur = @intCast(node);
        if (!p.dispatch(tb)) {
            // Placement exhausted: clear this node's per-walk state and backtrack.
            p.initial_dir[@intCast(node)] = -1;
            p.cur_dir[@intCast(node)] = -1;
            p.flip[@intCast(node)] = -1;
            p.step[@intCast(node)] = -1;
            node -= 1;
        } else if (runValidate(&p, @intCast(node), validate)) {
            node += 1;
        }
        // else: placed but rejected by the gate — re-dispatch the same node next iteration.
    }
    return p;
}

fn parseLevelData(
    allocator: std.mem.Allocator,
    tb: *const tables.Tables,
    nodes: []const Node,
    seed: rng.Seed,
    validate: Validate,
    out: *std.AutoHashMapUnmanaged(i64, Coords),
) !void {
    const p = runPlacement(tb, nodes, seed, validate);
    for (nodes, 0..) |n, i| try out.put(allocator, n.level_id, p.coords[i]);
}

/// DRLGLEVEL_ParseLevelData Cathedral→Courtyard write (1.14d 006772c0, pass 2,
/// `eD2LevelId == 6` branch): the Black Marsh placement direction selects whether the
/// act seed is rolled and which jail-exit variant (nPickedFile) the Courtyard (level
/// 0x1b) receives — overwriting the courtyard's own InitializeWithPresetArea selector
/// pick. The Barracks (level 0x1c, GenerateBarracksLayout 0x673120) later reads that
/// courtyard nPickedFile as its jail-exit layout variant.
///
/// `dir == 1` → roll, pick = 2 - (newLow & 1); `dir == 3` → roll, pick = ~newLow & 1;
/// any other direction → no write (returns null, courtyard keeps its selector pick).
/// The roll consumes pDrlg->nSeed, which the placement walk leaves untouched (it rolls
/// a private copy in pLevelUnknown.sSeed), so it is the pristine ACT_I placement seed.
pub fn act1CourtyardPick(tb: *const tables.Tables, init_seed: u32) ?i32 {
    const seed = placementSeed(0, init_seed); // == pDrlg->nSeed for an ACT_I game
    const p = runPlacement(tb, &act1_list2, seed, .act1_l2);
    var dir: i32 = -1;
    for (act1_list2, 0..) |n, i| {
        if (n.level_id == 6) dir = p.cur_dir[i]; // Black Marsh node
    }
    if (dir != 1 and dir != 3) return null;
    var ns = seed; // the placement copy never wrote back, so this is still the act seed
    _ = ns.next();
    if (dir == 1) return 2 - @as(i32, @intCast(ns.low & 1));
    return @as(i32, @intCast(~ns.low & 1));
}

/// DRLGLEVEL_ParseLevelData Rogue-Encampment write (1.14d 006772c0, pass 2,
/// `eD2LevelId == 1` branch): a PresetArea town takes its nPickedFile directly
/// from its own placement direction (aCurrentDir[node]), overwriting the
/// InitializeWithPresetArea selector pick (which is 0/TownN1 because the LvlPrest
/// has Files<1). The town's File1..4 = TownN1/E1/S1/W1 (index 0=N,1=E,2=S,3=W),
/// the same 0..3 as the lde4 placement direction of the town relative to its
/// predecessor Blood Moor — so the town renders the variant facing the neighbour
/// it was placed against. Unconditional (the engine always writes for level 1),
/// so this returns the direction rather than an optional.
pub fn act1TownPick(tb: *const tables.Tables, init_seed: u32) i32 {
    const seed = placementSeed(0, init_seed); // == pDrlg->nSeed for an ACT_I game
    const p = runPlacement(tb, &act1_list1, seed, .act1_l1);
    for (act1_list1, 0..) |n, i| {
        if (n.level_id == 1) return p.cur_dir[i]; // Rogue Encampment node
    }
    return 0;
}

/// DRLGLEVEL_ParseLevelData pass-2 write for Lut Gholein (1.14d 006772c0,
/// `eD2LevelId == 0x28` branch): unlike the Act-I town (which takes its own node's
/// aCurrentDir), the Act-II town takes aCurrentDir[node+1] — the placement direction
/// of the level placed directly AFTER it in the list (Rocky Waste). Lut Gholein is
/// node 0 of act2_list1, so node+1 is Rocky Waste (level 41, placeAdj2 → dir 1 or 2).
/// That nPickedFile then selects the town DS1 (File2=LutW / File3=LutN) and feeds
/// AUTOMAP_RevealTownCallback's town-sprite variant (picked==1 → cells 0..19,
/// else → 20..39). Unconditional write, so this returns the direction directly.
pub fn act2TownPick(tb: *const tables.Tables, init_seed: u32) i32 {
    const seed = placementSeed(1, init_seed); // == pDrlg->nSeed for an ACT_II game
    const p = runPlacement(tb, &act2_list1, seed, .overlap);
    // Lut Gholein is node 0; the engine reads aCurrentDir[node+1] = the next node.
    for (act2_list1, 0..) |n, i| {
        if (n.level_id == 40) {
            const nxt = i + 1;
            if (nxt < act2_list1.len) return p.cur_dir[nxt];
        }
    }
    return 0;
}

// act seed pipeline

/// The act seed that drives level placement: the init seed stepped once, then
/// the act-specific pre-rolls of DRLG_AllocDrlgActMisc consumed.
fn placementSeed(act_no: i64, init_seed: u32) rng.Seed {
    var s = rng.Seed.init(init_seed, 0x29a);
    _ = s.next(); // dwStartSeed capture (one step)
    switch (act_no) {
        1 => { // ACT_II: re-roll staff/boss tomb levels until they differ
            while (true) {
                _ = s.next();
                const staff = s.low % 7;
                _ = s.next();
                const boss = s.low % 7;
                if (staff != boss) break;
            }
        },
        2 => _ = s.next(), // ACT_III: jungle-interlink bit
        else => {},
    }
    return s;
}

// public API

/// A built act: derived world coords for every graph-placed level, plus the
/// directed warp adjacency between consecutive graph levels.
pub const Act = struct {
    act_no: i64,
    start_seed: u32, // level-RNG base (DRLG dwStartSeed)
    positions: std.AutoHashMapUnmanaged(i64, Coords) = .empty,
    warps: std.ArrayListUnmanaged([2]i64) = .empty,

    pub fn deinit(self: *Act, allocator: std.mem.Allocator) void {
        self.positions.deinit(allocator);
        self.warps.deinit(allocator);
    }

    /// World coords (origin + size) of any level in this act. Graph levels come
    /// from the placement walk; the rest fall back to the Depend offset chain.
    pub fn coords(self: *const Act, tb: *const tables.Tables, level_id: i64) Coords {
        if (self.positions.get(level_id)) |c| return c;
        const lv = tb.level(level_id) orelse return .{};
        var base = Coords{};
        if (lv.depend != 0) base = self.coords(tb, lv.depend);
        return .{
            .x = @as(i32, @intCast(lv.offset_x)) + base.x,
            .y = @as(i32, @intCast(lv.offset_y)) + base.y,
            .w = @intCast(lv.size_x),
            .h = @intCast(lv.size_y),
        };
    }
};

/// Build an act's level graph for a game init seed. `act_no` is the 0-based act
/// index (Levels.txt Act column): Act I = 0, Act II = 1, …
pub fn build(allocator: std.mem.Allocator, tb: *const tables.Tables, act_no: i64, init_seed: u32) !Act {
    var act = Act{ .act_no = act_no, .start_seed = rng.actStartSeed(init_seed) };
    errdefer act.deinit(allocator);

    // Each ParseLevelData call copies the act seed afresh and never writes it back, so
    // every list of an act starts from the same placement seed (the level-6 cathedral
    // reseed is the sole exception, and no ported act's first list contains level 6).
    const seed = placementSeed(act_no, init_seed);
    switch (act_no) {
        0 => { // Act I
            try parseLevelData(allocator, tb, &act1_list1, seed, .act1_l1, &act.positions);
            try parseLevelData(allocator, tb, &act1_list2, seed, .act1_l2, &act.positions);
            try addChainWarps(allocator, &act1_list1, &act.warps);
            try addChainWarps(allocator, &act1_list2, &act.warps);
        },
        1 => { // Act II
            try parseLevelData(allocator, tb, &act2_list1, seed, .overlap, &act.positions);
            try parseLevelData(allocator, tb, &act2_list2, seed, .overlap, &act.positions);
            try addChainWarps(allocator, &act2_list1, &act.warps);
            try addChainWarps(allocator, &act2_list2, &act.warps);
        },
        // Act III (act_no 2) has no RNG placement walk: DRLGActMisc_InitAct3 pins Kurast
        // Docktown at its Levels.txt Offset and everything else rides the Depend chain,
        // which the coords() fallback already reproduces.
        3 => { // Act IV
            try parseLevelData(allocator, tb, &act4_list1, seed, .overlap, &act.positions);
            try parseLevelData(allocator, tb, &act4_list2, seed, .overlap, &act.positions);
            try addChainWarps(allocator, &act4_list1, &act.warps);
            try addChainWarps(allocator, &act4_list2, &act.warps);
        },
        4 => { // Act V
            try parseLevelData(allocator, tb, &act5_list1, seed, .none, &act.positions);
            try parseLevelData(allocator, tb, &act5_list2, seed, .none, &act.positions);
            try parseLevelData(allocator, tb, &act5_list3, seed, .overlap, &act.positions);
            try addChainWarps(allocator, &act5_list1, &act.warps);
            try addChainWarps(allocator, &act5_list2, &act.warps);
            try addChainWarps(allocator, &act5_list3, &act.warps);
        },
        else => {}, // Act III: offset-chain only
    }
    return act;
}

/// The DRLGACT_SetWarpConnection wiring done inside ParseLevelData: a bidirectional
/// warp between every node and its prev/next neighbour in the chain.
fn addChainWarps(allocator: std.mem.Allocator, nodes: []const Node, out: *std.ArrayListUnmanaged([2]i64)) !void {
    for (nodes, 0..) |n, i| {
        if (n.prev >= 0) {
            const a = nodes[@intCast(n.prev)].level_id;
            try out.append(allocator, .{ a, n.level_id });
            try out.append(allocator, .{ n.level_id, a });
        }
        _ = i;
    }
}

// verification against the engine oracle

const testing = std.testing;

const GoldenCase = struct { init: u32, jsonl: []const u8 };

const golden_cases = [_]GoldenCase{
    .{ .init = 1, .jsonl = @embedFile("golden/seed_1.jsonl") },
    .{ .init = 2, .jsonl = @embedFile("golden/seed_2.jsonl") },
    .{ .init = 1000, .jsonl = @embedFile("golden/seed_1000.jsonl") },
    .{ .init = 65535, .jsonl = @embedFile("golden/seed_65535.jsonl") },
    .{ .init = 305419896, .jsonl = @embedFile("golden/seed_305419896.jsonl") },
    .{ .init = 3133731337, .jsonl = @embedFile("golden/seed_3133731337.jsonl") },
};

test "derived act-graph level origins match the engine oracle for every seed" {
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();

    for (golden_cases) |gc| {
        const levels = try oracle.parseJsonl(testing.allocator, gc.jsonl);
        defer {
            for (levels) |*lv| lv.deinit(testing.allocator);
            testing.allocator.free(levels);
        }
        try testing.expect(levels.len > 0);

        const act_no = tb.level(levels[0].id).?.act;
        var act = try build(testing.allocator, &tb, act_no, gc.init);
        defer act.deinit(testing.allocator);

        for (levels) |lv| {
            const got = act.coords(&tb, lv.id);
            if (!got.eql(lv.coords)) {
                std.debug.print(
                    "seed {d} level {d}: derived ({d},{d} {d}x{d}) != golden ({d},{d} {d}x{d})\n",
                    .{ gc.init, lv.id, got.x, got.y, got.w, got.h, lv.coords.x, lv.coords.y, lv.coords.w, lv.coords.h },
                );
            }
            try testing.expect(got.eql(lv.coords));
        }
    }
}

const DeepCase = struct { init: u32, jsonl: []const u8 };

const deep_cases = [_]DeepCase{
    .{ .init = 305419896, .jsonl = @embedFile("golden/deep_seed_305419896.jsonl") },
    .{ .init = 1, .jsonl = @embedFile("golden/deep_seed_1.jsonl") },
    .{ .init = 2, .jsonl = @embedFile("golden/deep_seed_2.jsonl") },
};

/// Levels whose world origin is NOT produced by the act placement graph and so cannot be
/// derived here. Two distinct reasons:
///   - Mazes 28 (Barracks) & 107 (River of Flame): Levels.txt Offset is (-1,-1) with no
///     Depend; the engine positions them lazily at generation time aligned against their
///     warp parent, and their size is the MAZE bounding box — both come from the maze
///     generator (maze.zig), not from any DRLGACTMISC list.
///   - Act III 76..83 (Jungles / Kurast / Travincal): Act III has no ParseLevelData graph;
///     DRLGActMisc_InitAct3 places the three Jungle levels (76-78) via the outdoor
///     sub-level placement (DRLGLEVEL_FixDrlgLevelForSpiderForest — a preset-map DS1
///     distance-field placement + sort over generated grid data), then stacks the Kurast
///     chain (79-83) off Jungle 3. That subsystem lives in the outdoor generator, not the
///     act graph, so it is out of scope for this file.
fn graphDerivable(level_id: i32) bool {
    return switch (level_id) {
        28, 107 => false,
        76, 77, 78, 79, 80, 81, 82, 83 => false,
        else => true,
    };
}

test "derived origins match the engine across all five acts (deep goldens)" {
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();

    var match = [_]usize{0} ** 5;
    var total = [_]usize{0} ** 5;
    var deferred = [_]usize{0} ** 5;
    var ok = true;

    for (deep_cases) |gc| {
        const levels = try oracle.parseJsonl(testing.allocator, gc.jsonl);
        defer {
            for (levels) |*lv| lv.deinit(testing.allocator);
            testing.allocator.free(levels);
        }

        var acts: [5]Act = undefined;
        for (0..5) |a| acts[a] = try build(testing.allocator, &tb, @intCast(a), gc.init);
        defer for (0..5) |a| acts[a].deinit(testing.allocator);

        for (levels) |lv| {
            const def = tb.level(lv.id) orelse continue;
            const a: usize = @intCast(def.act);
            total[a] += 1;
            if (!graphDerivable(lv.id)) {
                deferred[a] += 1;
                continue;
            }
            const got = acts[a].coords(&tb, lv.id);
            if (got.eql(lv.coords)) {
                match[a] += 1;
            } else {
                ok = false;
                std.debug.print(
                    "seed {d} act {d} level {d}: derived ({d},{d} {d}x{d}) != golden ({d},{d} {d}x{d})\n",
                    .{ gc.init, a, lv.id, got.x, got.y, got.w, got.h, lv.coords.x, lv.coords.y, lv.coords.w, lv.coords.h },
                );
            }
        }
    }

    for (0..5) |a| std.debug.print(
        "act {d}: {d}/{d} graph origins match ({d} deferred — see graphDerivable)\n",
        .{ a + 1, match[a], total[a] - deferred[a], deferred[a] },
    );
    try testing.expect(ok);
}

test "act1 courtyard jail-exit pick (cathedral roll) matches the engine for seed 6" {
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();
    // Engine ground truth: game-seed 6 → Courtyard (0x1b) nPickedFile == 1.
    try testing.expectEqual(@as(?i32, 1), act1CourtyardPick(&tb, 6));
}

test "act2 town pick reads Rocky Waste placement direction (node+1)" {
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();
    // Lut Gholein's nPickedFile is aCurrentDir[node+1] = Rocky Waste's placeAdj2 dir,
    // always 1 or 2 (File2=LutW / File3=LutN). Reading its own fixed-placement node
    // would give -1, so this guards the node+1 convention (ParseLevelData 006772c0).
    for ([_]u32{ 1, 2, 1000, 65535, 305419896, 3133731337 }) |sd| {
        const pick = act2TownPick(&tb, sd);
        try testing.expect(pick == 1 or pick == 2);
    }
}

test "act II town anchors the desert and wires a warp to it" {
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();

    var act = try build(testing.allocator, &tb, 1, 305419896);
    defer act.deinit(testing.allocator);

    // Lut Gholein sits at its fixed Levels.txt offset; Rocky Waste is adjacent.
    try testing.expect(act.coords(&tb, 40).eql(.{ .x = 1000, .y = 1000, .w = 56, .h = 56 }));
    const desert = act.coords(&tb, 41);
    try testing.expectEqual(@as(i32, 80), desert.w);
    try testing.expect((desert.x == 920 and desert.y == 1000) or (desert.x == 1000 and desert.y == 920));

    var found = false;
    for (act.warps.items) |w| {
        if (w[0] == 40 and w[1] == 41) found = true;
    }
    try testing.expect(found);
}
