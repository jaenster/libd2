# d2-items

A clean-room Zig reimplementation of Diablo II 1.14d **item generation** — the
deterministic, seed-driven drop pipeline: treasure-class resolution, item-class
roll by level, quality determination, and magic/rare affix selection.

Sibling to [`d2-drlg`](../d2-drlg) (the map-generation clean-room port); same
philosophy: **faithful-to-Ghidra, all-Zig, no C deps, seeded + verifiable,
roll-exact**. Ported from the reconstructed 1.14d `Game.exe` sources
(Ghidra session `62fbfe69`); every ported function cites its 1.14d address.

The value proposition: **given a seed + treasure class + monster level + magic
find, reproduce D2's exact item.** One extra or missing RNG step desyncs every
subsequent item off the same seed, so the whole roll cascade is modelled
roll-exact — no curve-fitting, no approximation.

## Status

| Component | Addr | State |
|-|-|-|
| Seed RNG (`D2SeedStrc` LCG, low-word reductions) | 0x45c3e0 / 0x472280 | done |
| Excel table parser + loaders | — | done |
| TreasureClassEx resolution (NoDrop walk, sub-TC recursion, party scale) | 0x55a6d0 / 0x654e00 | done, roll-exact |
| Drop-time quality + Magic Find | 0x558640 / 0x558610 | done, roll-exact |
| Item-seed quality cascade (fallback re-roll) | 0x556f60 | done |
| Magic prefix/suffix (frequency-weighted) | 0x5c1560 / 0x5565e0 | done, roll-exact |
| Rare affixes (1..N, no-dup-group, rare names) | 0x5c21d0 | done (name-pick internals residual) |
| Affix type eligibility (itype/etype + Equiv chain) | 0x65e620 | done |
| Socket count | 0x556b60 | done |
| Item-class-by-level (type tokens `weap3`/`armo3`) | 0x556240 | residual (needs compiled Items array) |
| Unique / set / crafted / runeword | 0x5566b0 | stubbed (TODO) |

### Known residuals
- **drop-seed → item-seed derivation** lives in `SUnit::CreateUnit` (not
  decompiled). A dropped item has two seed streams (base `sSeed` + affix "mod"
  seed); this port is roll-exact **given** both seeds — see `src/verify.zig`.
- **type-token entries** (`weap3`, `armo3`, …) select from the engine's compiled
  unified normal/exceptional/elite Items array (`ITEMDROP_RollItemClassByLevel`);
  reproducing that index space needs the item-compile sort order.
- unique/set/crafted/runeword affixes; rare-name pick internals (`GetMaxToRoll`);
  class-specific affix restriction; magiclvl weight multiplier.

## Build

```bash
zig build test          # unit tests (determinism, TC resolution, affix groups)
zig build run -- <seed> <treasureclass> <mlvl> [mf]
```

Zig 0.16.

## Data (private)

`src/excel/*.txt` are Blizzard's game data tables (`data/global/excel`), required
at build time via `@embedFile`. They are copyrighted — this repo is **private**
and must not be published with them. Regenerate from your own 1.14d install.

## Golden verification

Roll-exactness is validated against the live engine via a `d2gs` `srvtrace`
item-drop capture (seed + TC + mlvl + MF -> the exact item the engine rolled).
See `src/verify.zig` for the golden-diff harness shape.
