# d2-item

A clean-room Zig reimplementation of Diablo II 1.14d **item generation** — the
deterministic, seed-driven drop pipeline: treasure-class resolution, quality
determination, affix/unique/set selection, and the property value rolls.

Sibling to [`drlg`](../drlg) (the map-generation clean-room port); same
philosophy: **faithful-to-Ghidra, all-Zig, no C deps, seeded + verifiable,
roll-exact**. Ported from the reconstructed 1.14d `Game.exe` sources
(Ghidra session `62fbfe69`); every ported function cites its 1.14d address.

The value proposition: **given a game seed + a drop seed + treasure class +
monster level + magic find, reproduce D2's exact item.** One extra or missing RNG
step desyncs every subsequent item off the same seed, so the whole roll cascade is
modelled roll-exact — no curve-fitting, no approximation.

## The three seed streams

The engine does not derive an item's affix seed from the monster that dropped it.
`SUnit::CreateUnit` 0x555230 steps the game's single global seed counter **twice**
per item — once for the unit's own `sSeed`, once for the item's MOD seed — so
reproducing a drop needs the game seed as well as the dropping unit's:

| stream | what it drives |
|-|-|
| drop seed (the dropping unit's `sSeed`) | the TreasureClassEx walk, NoDrop, `GAME_GetItemQuality` (+MF) |
| game seed (`D2GameStrc.pGameSeed`) | two steps per created item, producing the two seeds below |
| item MOD seed | affixes, unique/set/superior selection, property values, sockets, ethereal, stack size |

`rollDrop` takes the drop seed and the game seed and advances both exactly as the
engine does.

## Status

| Component | Addr | State |
|-|-|-|
| Seed RNG (`D2SeedStrc` LCG, low-word reductions) | 0x45c3e0 / 0x472280 | done |
| Excel table parser + loaders | — | done |
| TreasureClassEx resolution (NoDrop walk, sub-TC recursion, party scale) | 0x55a6d0 / 0x654e00 | done, roll-exact |
| Auto item-type classes (`weap3`/`armo24`/…) | 0x6541c0 | done |
| Negative Picks ("each entry once", RNG-free) | 0x55a6d0 | done |
| TC unique/set link entries (forced quality + row) | 0x654440 | done |
| Drop-time quality + Magic Find | 0x558640 / 0x558610 | done, roll-exact |
| Item creation seeds (game counter, two steps) | 0x555230 / 0x552df0 / 0x552e90 | done |
| Quality + affix dispatch, incl. the fallback cascade | 0x557450 | done |
| Item-seed quality cascade | 0x556f60 | done |
| Magic prefix/suffix (weights, class gate, `rare` gate) | 0x5c1560 / 0x5565e0 | done, roll-exact |
| Rare affixes + rare names (`GetMaxToRoll`) | 0x5c21d0 / 0x5c1ab0 | done, roll-exact |
| Affix type eligibility (itype/etype + Equiv chain) | 0x65e620 | done |
| Unique selection (ladder gate, found-bitmask) | 0x5566b0 | done |
| Set selection | 0x5c25c0 | done |
| Superior (QualityItems) bonus | 0x5c2970 | done |
| Low quality (LowQualityItems) | 0x5c2d40 | done |
| Automagic affix (base `auto prefix` group) | 0x557450 tail | done |
| Ethereal roll | 0x556ca0 / 0x65e4d0 | done |
| Socket count | 0x556b60 | done |
| Gold amount + `mul=` rescale | 0x557ab0 | done |
| Stackable / quiver stack size | 0x557ab0 | done |
| Property value rolls (PROPERTIESFUNCTIONS dispatch) | 0x65fd70 | done, 24 of 24 handlers |
| Unique / set / partial-set property application | 0x65fec0 | done |
| Runeword detection + property application | 0x62bed0 / 0x6600a0 | done |
| Gem/rune socket-filler properties | — | done |

### Known residuals
- **stat side effects** the drop model does not carry: the ethereal damage/AC
  x3/2 and halved durability, the crude-quality 75% damage / 33% durability
  penalty, and the x2 / x3 durability bumps on a failed set / unique roll. The
  rolls and their RNG cost are faithful; only the resulting durability and
  damage numbers are left to the unit/stat layer.
- **crafted / tempered** are cube recipes, not drops (`GAME_GetItemQuality` never
  rolls them). Their affix roll is wired (both use the rare roller), but the cube
  recipe that produces them lives outside this package.
- per-entry TC quality modifiers (`cu=`/`cs=`/`cr=`/`cm=`/`ce=`/`cg=`) are parsed
  by the engine but never read by the drop path; only `mul=` changes an outcome
  and only that one is modelled.
- the NoDrop party scale uses the documented `ratio^players` curve; the engine's
  exact float→int rounding at the end of that computation was not recoverable
  from the decompile.
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
