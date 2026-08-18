# d2-game

A clean-room Zig reimplementation of the Diablo II 1.14d **runtime game simulation** —
the stateful engine that turns units, stats and RNG into gameplay.

[`d2-drlg`](../drlg) generates a world and [`d2-item`](../item) generates drops; both are
pure, stateless content. **This package is the stateful runtime that composes them.**
Same philosophy: faithful-to-Ghidra, pure Zig (no C, no `@cImport`), seeded and verifiable.
Ported from the reconstructed 1.14d `Game.exe` (Ghidra session `62fbfe69`); every ported
function cites its 1.14d address.

## What it covers

| area | what is in it |
|-|-|
| units and stats | the `StatList`/ItemStatCost model, derived life/mana, character save state |
| combat | chance-to-hit, physical and elemental damage, resists, blocking, monster attacks |
| skills | the catalog for all seven classes, plus monster skills and casting |
| missiles | spawn, advance, collision, on-hit |
| monsters | level-scaled stats, unique modifiers, and the AI behaviour scripts |
| world objects | shrines, chests, doors and portals, and the level state holding them |
| the game itself | `GameInstance` — the server-side loop: clients, levels, timers, events |

Each module's header names its own gaps, and a stub says so at the site that would have
done the work. Read those rather than trusting a status table to stay true.

## Dependencies

`d2-core`, `d2-data`, `d2-drlg`, `d2-item`, `d2-net`, `d2-pathfinding`, `d2-world`, all
wired as path deps in `build.zig.zon`. From another project, take the package by name:

```zig
.dependencies = .{ .d2_game = .{ .path = "../game" } },
```

or reach it through the umbrella as `libd2.game` — see
[docs/consuming-libd2.md](../../docs/consuming-libd2.md).

## Build & test

```
zig build          # builds the lib + demo CLI
zig build test     # runs the unit tests
zig build run      # resolves a demo attack for a fixed seed
```

## Verification

Determinism is unit-tested: identical `(attacker, defender, seed)` yields an identical hit
result and damage number. That is weaker evidence than `d2-drlg`'s cell-exact capture, and
[docs/VERIFICATION.md](../../docs/VERIFICATION.md) says so package by package. The standing
follow-up is a `srvtrace` combat golden — log live `DAMAGE_*` inputs and outputs from a real
1.14d server and replay them through `resolveAttack`, so the formulas are checked against the
engine rather than against themselves.
