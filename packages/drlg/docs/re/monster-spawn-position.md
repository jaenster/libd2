# Monster spawn POSITION + coord-list — 1.14d RE spec

Ground-truth spec for porting faithful seeded monster **positions** into `monpop.zig`
(the current port emits room-center placeholders and does NOT replay the position
room-seed advances, so the room-seed stream diverges after the first monster in a
room — corrupting subsequent monsters' TYPE rolls too). All addresses are 1.14d
Game.exe (Ghidra session 62fbfe69). Recovered 2026-06/07.

## SEED_Next (inline everywhere)

    u64 nNew = (u64)seed.nSeedLow * 0x6AC690C5 + seed.nSeedHigh;
    seed.nSeedLow  = (u32)nNew;
    seed.nSeedHigh = (u32)(nNew >> 32);

`RANDOM_RandomNumberSelector` @ 0x45c3e0: if `nModulo < 1` → return 0, **no advance**.
Else: 1 `SEED_Next`, return `seed.nSeedLow % nModulo` (or `& (mod-1)` if pow2).

## GetRoomCorners @ 0x54dac0 — no seed advances

World-subtile bounds. With a coord-list rect (already CoordsRoomToWorld'd):

    left   = rect.left + 1
    top    = rect.top  + 1
    width  = rect.right  - left      (= rect.right - rect.left - 1)
    height = rect.bottom - top       (= rect.bottom - rect.top - 1)

Sample: `x = RANDOM(seed,width)+left`, `y = RANDOM(seed,height)+top`. Range is one
subtile inset from the rect. Without a coord-list it uses
`dwXStart+1 / dwYStart+1 / dwXSize-1 / dwYSize-1` from DRLGROOM_GetRoomCoordinates.

## CreateMonster probe, nSpawnRadius = -1 (3 room-seed advances)

Called inside every FindPosition / GroupAtRandom probe. `nSpawnRadius=-1` skips the
ring search straight to `(nX,nY)`:

    A. SEED_Next(roomSeed)          // parity: is nSeedLow even?
    B. RANDOM(roomSeed, 0) -> 0     // NO advance (modulo<1 guard)
    C. SEED_Next(roomSeed)          // bit0: negate xOff (=0; no effect)
    D. SEED_Next(roomSeed)          // bit0: negate yOff (=0; no effect)

Then validity checks; nFlags=1 → sentinel (probe, no unit), nFlags=0 → create unit.

### nSpawnRadius = 3 (minion spawns): nMaxRadius=9, rings 3→6→9, per ring:

    A. SEED_Next(roomSeed)                 // parity
    B. RANDOM(roomSeed, ring)              // one axis offset in [0,ring)
    C. SEED_Next(roomSeed)                 // sign X
    D. SEED_Next(roomSeed)                 // sign Y

= 4 advances/ring, then a pure perimeter walk (no seed). ≤3 rings → ≤12 advances.
Accept: `PtInRect` + optional `GetGridIndex==nGridZoneIdx` + `MONSTERAI_CanSpawnMonsterAt`
+ `CheckCollision_BlockAll_Width(SizeX, spawnColMask)==COLLIDE_NONE`.
spawnCol mask from MonStats2.spawnCol: 0→0x3C01, 1→0x01C0, 2→0x3F11, 3→0 (no check).
SizeX: 0/1=single tile, 2=cross, 3=bounding box.

## SPAWN_FindRandomPositionForMonster @ 0x54dc40

Seed `pRoom->sSeed`. Up to 20 retries (nTryCount 0..19). Per attempt:

    Roll1: RANDOM(roomSeed, nRoomWidth)   -> x = nRoomLeft + roll   [1]
    Roll2: RANDOM(roomSeed, nRoomHeight)  -> y = nRoomTop  + roll   [1]
           CreateMonster probe at (x,y)                             [3]

= 5 advances/retry. If nParam=1: also `CheckWarpSpawnCoords(room,game,x,y)` before the
probe; non-zero → skip probe, count as retry (2 advances that attempt). Success writes
`*pX,*pY`, returns TRUE.

## SPAWN_SpawnMonsterGroupAtRandom @ 0x54ddc0

Seed `pRoom->sSeed`. Random base for the whole group, up to 20 retries. Per attempt:

    Roll1: RANDOM(roomSeed, nRoomWidth)  -> nBaseX = nRoomLeft + roll  [1]
    Roll2: RANDOM(roomSeed, nRoomHeight) -> nBaseY = nRoomTop  + roll  [1]
    for member i in 0..nGroupSize-1:
        x = nBaseX + pnParam[3 + 3*i]
        y = nBaseY + pnParam[4 + 3*i]
        if coordList and GetGridIndex(room,x,y) != nCoordListIdx: retry (no probe)
        CreateMonster probe at (x,y)                                  [3]
        if NULL: retry

Full success = `2 + nGroupSize*3` advances; a retry bailing at member k costs `2 + k*3`
(grid-check bail = 2). Success writes `*pOffsetX,*pOffsetY`, returns 1.
pnParam int32 stride 3: `[0]=groupSize … [3]=xOff0,[4]=yOff0,[6]=xOff1,[7]=yOff1,…`.

## SPAWN_SpawnMonsterWithMinions @ 0x54df80

    // Boss position
    FindRandomPositionForMonster(nParam=1): 5 (or 2 on warp reject) advances/retry, ≤20.
    // Boss creation
    SpawnMonsterInRoomCoordList(x,y, nFlags=0, nSpawnRadius=-1): 3 roomSeed advances.
       Unit gets its OWN sSeed (no roomSeed involvement).
    // Minion count  (boss unit seed, NOT room seed)
    nExtra = RANDOM(boss.sSeed, MaxGrp-MinGrp+1)        [1 boss-seed advance]
    minionCount = nExtra + (MinGrp-1)                   // [MinGrp-1, MaxGrp-1]
    // Minion placement, nSpawnRadius=3
    for i in 1..minionCount: SpawnMonsterAtCoordList(..., nSpawnRadius=3, nFlags=0)
       ring search on roomSeed: 4 advances/ring, ≤3 rings.

## Coord-list — DRLGLOGIC_BuildRoomCoordList @ 0x66d110

Built once per room at load. `D2RoomCoordListStrc` linked list (`pNext`):
- `nIndex`: orientation-zone id (low 28 bits of the orientation grid cell). 0 = skip.
- `bNode`: bit 29 of orientation flags. 1 = node/transition; `MONSTER_SpawnRoomMonsters`
  skips `bNode != 0`.
- `pRect`: RECT in **world subtile coords** (orientation-grid rectangles translated by
  `pRoomEx->sCoords.WorldPosition`).

`MONSTER_SpawnRoomMonsters` iterates `pCoordList->pNext`, filters `nIndex!=0 && bNode==0`,
and rolls `((right-left)/3)*((bottom-top)/3)` density slots **per rect** against
`pGame->pGameSeed`. (The current port treats the whole room as ONE rect → wrong game-seed
slot count AND wrong room-seed stream.)

`GetGridIndex(room,x,y)` → `sCoordIndexGrid` at `(x/5 - worldPos.x, y/5 - worldPos.y)`
gives which coord-list entry owns a world-subtile position.

## Accept/reject predicate (CheckCollision + AI) — recovered 2026-07

### CheckCollision_BlockAll_Width @ 0x64D9B0
`eColl __stdcall (D2RoomStrc* pRoom, int nX, int nY, eUnitSize nWidth, eColl mask)`.
Sample pattern by SizeX (from MonStats2.SizeX via MonStats.MonStatsEx):
- 0/1 (NONE/POINT): single cell (nX,nY)                      [CheckCollision_BlockPlayerMissile_Internal2 0x64D450]
- 2 (SMALL): cross center+4 cardinals (nX,nY),(nX±1,nY),(nX,nY±1)   [CheckCollision_Cross 0x64D100]
- 3 (BIG): 3x3 box x∈[nX-1,nX+1], y∈[nY-1,nY+1]                 [CheckCollision_BoundingBox1 0x64D4A0]
- >=4: COLLISION_ALL (always blocked)
OR all sampled cells' u16, AND with mask; return 0 (COLLIDE_NONE) if no bits, else the bits.
Off-room cells fall back to the neighbouring room's grid.

### Collision map
`DRLGROOM_GetCollisionGridFromRoom(pRoom)->pMapStart` (u16/subtile).
`cell = pMapStart[(nY - dwYStart)*dwXSize + (nX - dwXStart)]`; `(cell & mask)!=0` → blocked.
MUTATED mid-pass: each placed monster's footprint is written via CreateUnit →
UNITS_PlaceUnitInRoom → AllocDynamicPath → PATH_AddUnitCollision (0x649400), synchronously,
before CreateMonster returns — so later spawns in the room see earlier monsters.

### spawnCol → mask (CreateMonster switch 0x5B2AA7)
0 (or empty) → 0x3C01 ; 1 → 0x01C0 ; 2 → 0x3F11 ; 3 → 0x0000 (skip check).
spawnCol==1 && classId∉[0x102..0x107] && classId!=0x99 → FindDiagonalNonCollisionCoords
path instead of the ring-walk (NO seed advances, different algo).

### MONSTERAI_CanSpawnMonsterAt @ 0x5FD350 — pure, ZERO seed advances
Ordinary monsters (BaseId ∉ {0xCE,0xE4,0x12A,0x14E,0x210}) → return 1 immediately.
Special oversized → nudge + FindBetterNearbyRoom + CheckCollision(SMALL); bAllowSpecialCase=1
from CreateMonster so 0x12A always passes.

### Per-probe accept sequence (nSpawnRadius=-1), room seed
FindRandomPositionForMonster (0x54DC40), ≤20 attempts:
  adv1: nX = RANDOM(seed, nRoomWidth) + nRoomLeft
  adv2: nY = RANDOM(seed, nRoomHeight) + nRoomTop
  CreateMonster probe (0x5B2A00): adv3 parity; RANDOM(seed,0)→0 NO adv; adv4 sign-x; adv5 sign-y
     (offsets are 0 at radius -1 → candidate == (nX,nY))
  checks (pure, no advances): PtInRect ; [coordlist] GetGridIndex==idx ;
     MONSTERAI_CanSpawnMonsterAt ; CheckCollision_BlockAll_Width==0
  pass → CreateUnit (writes footprint), FindRandomPos returns (nX,nY).
  fail → nTryCount++, restart at adv1. 20 fails → FALSE.
= 5 room-seed advances per attempt; the 3 in CreateMonster fire unconditionally before checks.
