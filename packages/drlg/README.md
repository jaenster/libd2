# d2-drlg

A clean-room Zig reimplementation of Diablo II 1.14d **DRLG** (Diablo Resource
Level Generation) — the deterministic, seed-driven map generator. Goal: given a
random seed, generate the room/tile layout for every level in all five acts, and
render it.

Ported from the reconstructed 1.14d sources (`D2Common/Drlg`), verified
bit-exact against the live headless `d2gs` engine (the oracle).

## Status

| Component | State |
|-|-|
| Seed RNG (`D2SeedStrc` LCG) | done, tested |
| DRLG dump oracle (d2gs hook) | todo |
| Data tables (Levels/LvlPrest/LvlTypes/LvlSub) | todo |
| Generation pipeline (maze/outdoor/preset) | todo |
| Map renderer + per-act verification | todo |

## Build

```bash
zig build test        # unit tests
zig build run -- 12345 # smoke: first RNG rolls for a seed
```

Zig 0.16.
