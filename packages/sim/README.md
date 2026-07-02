# d2-sim

A clean-room Zig reimplementation of the Diablo II 1.14d **runtime game
simulation** — the stateful engine that turns units, stats and RNG into gameplay.

Sibling to the standalone content libraries [`d2-drlg`](../d2-drlg) (map
generation) and [`d2-items`](../d2-items) (item generation). Those two are pure,
stateless content generators; **d2-sim is the stateful runtime that composes
them**. Same philosophy: **faithful-to-Ghidra, pure Zig (no C, no `@cImport`),
seeded + verifiable**. Ported from the reconstructed 1.14d `Game.exe` (Ghidra
session `62fbfe69`); every ported function cites its 1.14d address.

## Status — combat core

| Component | 1.14d addr | State |
|-|-|-|
| Seed RNG (`D2SeedStrc` LCG, low-word reductions) | 0x45c3e0 | vendored from d2-items |
| Unit-stat model (`StatList` + ItemStatCost ids) | — | done |
| Chance-to-hit (AR vs defense, clamp 5..95) | 0x57d9b0 | done |
| Physical damage (base + str/dex + ED, seeded roll) | 0x57b420 | done |
| Damage application (flat DR then resist%) | 0x57bf80 | done, physical only |
| Defense (`armorclass + dex/4`, ×item_armor%) | 0x6223f0 | done |
| Attack rating | 0x6449f0 | partial (character-AR base) |

### Out of scope this pass (follow-ups, stubbed/TODO)
- Full skill catalog + skill dispatch, missiles, monster AI.
- Elemental / poison / DOT damage (only physical is applied).
- Blocking, dodge/evade, crushing blow, open wounds, deadly strike.
- PvP damage penalty.

## Dependencies

The intended architecture is to depend on the two content libs via `build.zig.zon`
path deps (`d2drlg`, `d2items`). That is not wired yet: neither sibling ships a
`build.zig.zon` and `d2-drlg` is exe-only (no `b.addModule`), so `b.dependency`
cannot resolve them without modifying those repos. Following the d2-items
precedent, the shared **seed-RNG foundation is vendored** (`src/rng.zig`, copied
verbatim from d2-items) so this repo stays self-contained and green. **Follow-up:**
expose consumable modules on the siblings and switch to real path deps.

## Build & test

```
zig build          # builds the lib + demo CLI
zig build test     # runs the unit tests
zig build run      # resolves a demo attack for a fixed seed
```

## Verification

Determinism is unit-tested: identical `(attacker, defender, seed)` yields an
identical hit result + damage number. **Stretch:** a d2gs `srvtrace` combat golden
(log live `DAMAGE_*` inputs/outputs from a real 1.14d server and replay them
through `resolveAttack`) would validate the formulas against the true engine,
exactly like d2-drlg validates map gen against the DRLG oracle.
