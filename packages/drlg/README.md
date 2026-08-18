# d2-drlg

A clean-room Zig reimplementation of Diablo II 1.14d **DRLG** (Diablo Resource Level
Generation) — the deterministic, seed-driven map generator. Give it a seed and it
produces the same world the game does: rooms, tiles, collision, roads, level adjacency,
and the placed objects and monsters, for every level of all five acts.

Ported from the reconstructed 1.14d `D2Common/Drlg` (Ghidra session `62fbfe69`); every
ported function cites its 1.14d address.

## Does it match the game?

Yes, cell for cell. The retail engine was run headless, its collision dumped, and this
code compared against that capture — 11.1M subtiles per seed, every level of all five
acts, **zero differing cells**. Two of the seeds are blind holdouts: captured up front,
never looked at while developing, only run at the end.

The per-cell corpus is Nightmare; all three difficulties are covered by a masked CRC over
200 seeds. [docs/VERIFICATION.md](../../docs/VERIFICATION.md) is honest about what each
of those can and cannot catch.

## Using it

```zig
const drlg = @import("d2-drlg");

var ctx = try drlg.Ctx.init(gpa);
defer ctx.deinit();

// act 0 is Act I; `opts` picks how much to compute (room links, walk grid, raw collision).
var act = try drlg.generateActFull(&ctx, gpa, 0, 0x13572468, .normal, .{ .room_links = true });
defer act.deinit(gpa);
```

There is also a C ABI (`src/capi.zig` + `include/d2drlg.h`), so `zig build` here writes a
native shared/static lib and a freestanding wasm module for every target Zig supports.

## Build

```bash
zig build test        # unit tests + the golden verification gate
zig build test-unit   # only the unit tests — seconds, for the edit/build loop
zig build verify      # only the golden gate (always ReleaseFast; the gate is slow in Debug)
zig build run -- help # the DRLG tool: rng rolls, table dumps, generation smoke tests
```

Zig 0.16.

## About the baked assets

`src/blobs/` and `src/maps/` hold small pre-baked binaries derived from Blizzard game
data — level structure, subtile collision flags, and a few `.dt1`/`.ds1` fixtures —
included only so the generator builds and self-verifies out of the box. They are not
redistributable game content. Diablo II is © Blizzard Entertainment.
