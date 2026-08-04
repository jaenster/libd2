# How teleport actually works in D2 1.14d

Reverse-engineered from `Game.exe` 1.14d (Ghidra session `62fbfe69`), with the collision-bit names
taken from the D2R debug build (session `eb3458d4`).

**A cast has to clear two independent gates, enforced in different layers.** Model only one and you
plan casts that silently fail — or, just as bad, refuse casts that would have worked.

| | Gate | Where | Rule |
|-|-|-|-|
| 1 | Distance | packet handler | Chebyshev ≤ **50 subtiles** — per axis, not radial |
| 2 | Topology | relocate | destination must resolve to your room or an adjacent room |

The skill implementation itself checks neither.

---

## Gate 1 — distance, at the packet handler

This is the one that is easy to miss, because it is nowhere near the skill code.

`SCMD_0x05_LeftSkillOnLocation` @ `0x549d00` and `SCMD_0x0C_RightSkillOnLocation` @ `0x549fc0` are
the "cast skill at these coordinates" handlers (the held-mouse variants `0x08` @ `0x549e80` and
`0x0F` @ `0x54a140` delegate to them). Both go through `CheckIfInrangeAndReassign` @ `0x5496f0`:

```c
nY = *(uint16_t *)(nParam + 3);      // straight off the packet
nX = *(uint16_t *)(nParam + 1);
nReturnStatus = CheckIfCoordsAreInRange(pUnit, 0x32, nX, nY);
if (nReturnStatus != SERVERSTATUS_OK) {
    if (0x19 < (pGame->dwGameFrame - pPlayerData->nGameFrame))
        NET_D2GS_SERVER_Send_0x15_ReassignPlayer(...);   // snap the client back
    return nReturnStatus;                                 // <-- and the cast never happens
}
```

and `CheckIfCoordsAreInRange` @ `0x548ef0` — whose own decompiler note calls it a guard "against
teleport/warp exploits":

```c
nUnitX = GetXPos(pUnit->pPath.pDynamicPath);
nUnitY = GetYPos(pUnit->pPath.pDynamicPath);

nUnitX = |nUnitX - nX|;  if (nUnitX <= nRange) {
nUnitY = |nUnitY - nY|;  if (nUnitY <= nRange) return SERVERSTATUS_OK; }
return SERVERSTATUS_BAD_TARGET;
```

with `nRange = 0x32 = 50`.

Three things matter here:

- **It is Chebyshev, not radial.** Each axis is tested separately, so a pure diagonal cast may span
  (50, 50) — about **70 subtiles** of actual ground. Treating the limit as a 50-radius circle, or as
  the folklore "about 40", throws away reach and costs extra casts.
- **The unit is SUBTILES.** The packet `nX`/`nY` are compared against `GetXPos`/`GetYPos` on the
  dynamic path, and the same values then go to `SUNIT_RelocateUnit` → `FindBetterNearbyRoom`, which
  tests them against the runtime room's subtile-resolution `sCoords`. The wire coordinates in
  packet `0x15` are the same space (cross-checked against this project's clientless decoder).
- **It rejects, it does not clamp.** Over the limit and the packet is dropped and your position is
  resynced — not moved as far as allowed.

Nothing downstream adds another distance check: `CastSkillOnLocation` @ `0x549ad0`,
`PLRMODES_MoveToLocation` @ `0x5809d0`, `SKILLS_SrvStartSkill` @ `0x56f640`,
`Skills_SrvDoFunc_027_Teleport` @ `0x5ca360` and `SUNIT_RelocateUnit` @ `0x554ea0` are all clean.
Teleport's `Skills.txt` `range` is the literal string `none` and its `aurarangecalc` is empty, and
neither is consulted server-side.

### Why people say 39 or 40

It is margin under gate 1, not the rule. The server compares against **its** view of your position,
which lags the client's; casting at exactly 50 risks a rejection and a resync mid-run. So bots pick
a number comfortably under. `max_cast` in this package defaults to the engine's real 50 — lower it
if you want the margin.

---

## Gate 2 — topology, at the relocate

### `Skills_SrvDoFunc_027_Teleport` @ `0x5ca360`

`Skills.txt` gives Teleport (Id 54) `srvdofunc = 27`, and that entry is this function:

```c
SKILLS_GetTargetOrCursorPos(pGame, pUnit, &nCursorX, &nCursorY);
pRoom = GetRoom(pUnit);
if (pRoom == NULL) return 0;

pLevelTxt = TXT_Levels_GetLine(DRLGROOM_GetLevelIdFromRoom(pRoom));
if (pLevelTxt == NULL || pLevelTxt->Teleport == 0)
    return 0;                                        // level forbids teleport

if (pLevelTxt->Teleport == 2 &&
    TestCollisionByCoordinates(pUnit, nCursorX, nCursorY, 0x804))
    return 0;                                        // level gates the destination

return SUNIT_RelocateUnit(pGame, pUnit, NULL, nCursorX, nCursorY, 0, 0);
```

No distance check, and **no line-of-sight check** on the normal (`Teleport == 1`) path — teleport
goes through walls. The `Levels.txt` `Teleport` column:

| Value | Meaning | Levels in 1.14d |
|-|-|-|
| 0 | The skill is refused outright | only level 0 (`Null`) |
| 1 | Free teleport | everything else |
| 2 | Destination must not carry `0x804` (door \| missile_barrier) | only level 73, Duriel's Lair |

### `SUNIT_RelocateUnit` @ `0x554ea0`

Called with `pRoom = NULL`, so the room is resolved from the coordinates:

```c
if ((pRoom == NULL &&
     (pRoom = DRLGROOM_FindBetterNearbyRoom(NULL, nX, nY)) == NULL) &&
     (pRoom = DRLGROOM_FindBetterNearbyRoom(pCurrentRoom, nX, nY)) == NULL)
    return 0;                                        // <-- the cast simply fails

GetFreeCoordinates_WithNeighboorRooms(               // snap to a free cell in that room
    pRoom, &ptTarget, GetUnitSizeX(pUnit),
    COLBIT_NOPATH | COLBIT_DOOR | COLBIT_OBJECT | COLBIT_NOPLAYER | COLBIT_WALL,  // = 0x1c09
    /* bAllowNeighboorRooms */ 0);

if (pRoom == NULL || PATH_GetCollisionMaskAt(...) == 0) return 0;
```

The first `FindBetterNearbyRoom` returns `NULL` immediately (null-room guard), so the second decides.
The snap mask `0x1c09` is exactly `COLMASK_PLAYER_PATH`.

### `DRLGROOM_FindBetterNearbyRoom` @ `0x463740`

```c
if (pRoom == NULL) return NULL;
if (nX, nY inside pRoom)  return pRoom;              // your own room
DRLGROOM_GetAdjacentRoomsList(pRoom, &ppRoomList, &nRoomCount);
for (each room in the adjacent list)
    if (nX, nY inside that room) return that room;   // an adjacent room
return NULL;                                          // -> teleport fails
```

### What lands in the adjacent list

Three mechanisms, and they are often conflated:

**Same level, by geometry** — `DefineRoomsNear` @ `0x66bc20`, built per room at generation over the
rooms of the same level only:

```c
gapX = (self.x < other.x) ? other.x - self.w - self.x
                          : self.x - other.w - other.x;
gapY = (self.y < other.y) ? other.y - self.h - self.y
                          : self.y - other.h - other.y;
near = (gapX < 6 && gapY < 6);
```

Signed, in **tiles**, so overlapping or touching rooms come out negative and a room is near itself.
Two rooms are adjacent when their bounding boxes are within 5 tiles (25 subtiles) on *both* axes.

**Another level, by warp link** — `DRLGROOMEX_InitNearRoomsAndVisTiles` @ `0x66c370` then walks the
room's set vis slots (`eRoomExFlags & 0xff0`) and calls `DRLGROOMEX_LinkNearRoomsByVis` @ `0x66c220`,
which resolves the destination *level* and appends rooms from that level's chain via
`DRLGROOMEX_LinkNearRoomByDirection` @ `0x66be80` → `DRLGROOMEX_ResizeArrayAndAddNewNearRoom`
@ `0x66bda0`. **So cross-level adjacency does exist** — but only across a warp/vis link, never by
plain geometry.

**Activation filter** — the runtime list is not the generation-time list.
`DRLGROOM_UpdateRoomsNearAndCount` @ `0x619800` builds `pRoom->ppRoomList` through
`GetRealRoomsNearCount` @ `0x66bd00`, which keeps only entries whose `->pRoom` is non-null, i.e.
rooms currently allocated server-side. (`DRLGROOM_AreAllNearRoomsActive` @ `0x61a460` additionally
tests each `ppRoomList[i]->eFlags & 1`.)

### Can you teleport across an area border?

- Across a **pure seam** — two outdoor levels adjacent by geometry with no vis link between them,
  which is every overworld border such as Blood Moor to Cold Plains: **no**. Those rooms never enter
  each other's lists, because geometric adjacency is same-level only. Crossing is a walk.
- Across a **warp-linked** border: **yes, in principle** — but only while the destination room is
  loaded, which is runtime state.

This package supports the warp-linked case behind `Options.teleport_across_levels`, off by default.
`d2-drlg` hands over the engine's own cross-level entries (`RoomLink`, harvested from
`ppDrlgRoomsExNear` after `LinkNearRoomsByVis` has run), and `World.crossLevelCast` accepts a
boundary cast only when a real link exists **and** the two cells clear the 50-subtile gate measured
in WORLD coordinates — the two rooms live in different level-local frames, and a warp destination is
usually placed far away in the shared world frame, so most linked pairs fail the distance gate and
correctly yield nothing.

Turn it on when the whole act is resident server-side, which makes the activation filter moot. Seam
borders remain walks under all settings, because those rooms are never linked at all.

Even then it is not taken blindly: a cast crossing drags you to the link room, which can be further
away than the ordinary exit. `route` builds both the walk-out leg and the cast-out leg and keeps the
cheaper one.

---

## What this package does with it

`rooms.zig` ports `DefineRoomsNear` verbatim and builds, per level, a tile→room lookup and a
room→near-set list. `teleport.zig` accepts a cast only when it clears **both** gates:

1. `max(|dx|, |dy|) <= max_cast` — Chebyshev, default `ENGINE_MAX_CAST = 50`, matching
   `CheckIfCoordsAreInRange`; and
2. the destination room is the caster's room or in its near set.

Landing cells are snapped with `COLMASK_PLAYER_PATH` (0x1c09), matching `SUNIT_RelocateUnit`, and a
level whose `Teleport` is 2 additionally ORs in `COLMASK_PLAYER_FLYING` (0x804) — read off the
instruction itself, `PUSH 0x804` at `0x5ca3a6`, not guessed from the parameter's name.

### Where this package is deliberately stricter than the engine

Two places, both in the safe direction — it will never emit a cast the server refuses, though it may
decline one the server would have accepted:

- **Landing cells.** `SUNIT_RelocateUnit` SNAPS a blocked request to a free cell inside the resolved
  room (`GetFreeCoordinates_WithNeighboorRooms`), so a cast aimed into a wall can still succeed.
  This package only ever emits cells that are already free under the landing mask.
- **Unit footprint.** The engine snaps using `GetUnitSizeX(pUnit)`; the search models a single
  subtile (`COLLISION_PATTERN_NONE`). In practice this changes where a cast lands by a subtile or
  two rather than whether it is accepted, because the engine snaps rather than rejects.

Cost is counted in **casts**, not distance, because that is what the character pays in mana and in
time. Two searches, chosen by whether a distance gate is in force:

- **bounded** — A* over the level's tile grid (25× fewer nodes than subtiles), each tile carrying a
  precomputed legal landing subtile, one unit of cost per hop. Because the gate is Chebyshev the
  neighbour offsets form a **square**, not a disk — the corners are legal and are where the reach is
  greatest.
- **`max_cast = null`** — gate 2 only. One cast then reaches any cell of an adjacent room, so the
  problem collapses to breadth-first search over the room adjacency graph: tens of nodes instead of
  tens of thousands. Useful for asking what the relocate code alone would permit; not for planning
  real casts.

The test `every teleport cast in a route is one the server would accept` (src/tests.zig) checks
every emitted cast of every Act 1 level against the landing mask, the room rule and the per-axis
distance gate.

---

## Summary

| Question | Answer | Source |
|-|-|-|
| Is there a maximum teleport distance? | Yes — Chebyshev 50 subtiles, per axis | `CheckIfCoordsAreInRange` @ `0x548ef0`, called with `0x32` from `0x5496f0` |
| Where is it enforced? | The cast packet handler, before the skill runs | `SCMD_0x05` @ `0x549d00`, `SCMD_0x0C` @ `0x549fc0` |
| Over the limit — clamped or rejected? | Rejected; client gets a `0x15` ReassignPlayer resync | `CheckIfInrangeAndReassign` @ `0x5496f0` |
| Is a diagonal cast longer than a straight one? | Yes — (50,50) is legal, ~70 subtiles of ground | Chebyshev metric, `0x548ef0` |
| Does the skill code check distance? | No | `Skills_SrvDoFunc_027_Teleport`, `SUNIT_RelocateUnit` |
| What else can fail a cast? | Destination must be in your room or an adjacent one | `DRLGROOM_FindBetterNearbyRoom` @ `0x463740` |
| When are two rooms adjacent? | Bbox gap < 6 tiles on both axes, same level | `DefineRoomsNear` @ `0x66bc20` |
| Cross-level adjacency? | Only across a warp/vis link, and only while loaded | `0x66c220` / `0x66be80`, filtered by `0x66bd00` |
| Can a cast cross a level boundary? | Yes, on a warp-linked pair also within 50 subtiles in world coords | `Options.teleport_across_levels` |
| Can you teleport through walls? | Yes — no line-of-sight check | `Skills_SrvDoFunc_027_Teleport` |
| Where must you land? | A free cell under mask `0x1c09` | `GetFreeCoordinates_WithNeighboorRooms` call in `0x554ea0` |
| Which levels forbid it? | `Levels.txt Teleport == 0` — only level 0 | `Skills_SrvDoFunc_027_Teleport` |
| Which levels gate it? | `== 2` — only Duriel's Lair (73); destination must be clear of `0x804` | `PUSH 0x804` at `0x5ca3a6` |
| Why do people use 39/40? | Margin under the 50 gate, because the server's view of your position lags | derived |
