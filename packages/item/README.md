# d2-item

A clean-room Zig reimplementation of Diablo II 1.14d **item generation** — the
deterministic, seed-driven drop pipeline: treasure-class resolution, quality
determination, affix/unique/set selection, and the property value rolls.

Sibling to [`drlg`](../drlg) (the map-generation clean-room port); same
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
| Auto item-type classes (`weap3`/`armo24`/…) | 0x6541c0 | done |
| Negative Picks ("each entry once", RNG-free) | 0x55a6d0 | done |
| Unique / set selection | 0x5566b0 / 0x5c25c0 | done, weighted |
| Superior (QualityItems) bonus | 0x5c2970 | done |
| Property value rolls (PROPERTIESFUNCTIONS dispatch) | 0x65fd70 | done, 22 of 24 handlers |
| Runeword detection | — | done (props not applied) |

### Known residuals
- **drop-seed → item-seed derivation** lives in `SUnit::CreateUnit` (not
  decompiled). A dropped item has two seed streams (base `sSeed` + affix "mod"
  seed); this port is roll-exact **given** both seeds — see `src/verify.zig`.
- **charged-skill properties** (property funcs 11/19) only apply when the level is
  given explicitly; the derived-from-item-level branch needs Skills.txt req/max
  levels. Funcs 14 (sockets) and 23 (ethereal) set item flags, not mod stats.
- rare-name pick internals (`GetMaxToRoll`); class-specific affix restriction;
  magiclvl weight multiplier; per-entry TC quality modifiers (`cu=`/`cs=`/`cr=`/
  `cm=`) — only the `mul=` gold multiplier is parsed.
- crafted / tempered are cube recipes, not drops (`GAME_GetItemQuality` never
  rolls them), so they are out of this package's scope.
- classic (non-expansion) resolution carries its own cumulative weights but is far
  less exercised than the expansion path.

## Build

```bash
zig build test          # unit tests (determinism, TC resolution, affix groups)
zig build run -- <seed> <treasureclass> <mlvl> [mf]
```

Zig 0.16.

## Data

The Blizzard excel tables live in [`d2-data`](../data), which owns them and
`@embedFile`s every one — this package holds no copy of its own and needs no
filesystem at runtime.

## Golden verification

Roll-exactness is validated against the live engine via a `d2gs` `srvtrace`
item-drop capture (seed + TC + mlvl + MF -> the exact item the engine rolled).
See `src/verify.zig` for the golden-diff harness shape.
