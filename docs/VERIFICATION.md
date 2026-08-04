# How libd2 is checked against the game

Nothing here is checked against itself. The retail engine was run, its output captured, and
this code compared against that capture.

## Map generation

The comparison is per cell. The tests print what they compared and by how much it differed:

```
[coll all-acts seed 1]          cells=11087850 | walkable off 0 | masked off 0 | exact off 0 | pct 100
[coll HOLDOUT seed 1033089920]  cells=11104250 | walkable off 0 | masked off 0 | exact off 0
```

That is 11.1M subtiles per seed, every level of all five acts, with zero differing cells.

The captured dumps live in `packages/drlg/src/golden/`:

| corpus | coverage |
|-|-|
| per-cell dumps | seeds 1, 2, 17, 18, 777, every level of all five acts, Nightmare only |
| blind holdouts | 2 further seeds, same depth and difficulty, captured and never looked at during development |
| masked CRC | 200 seeds × 3 difficulties, 26,200 level records each |

Difficulty is where that corpus is thinnest, though not as thin as it looks. Every per-cell
capture is Nightmare, so the *cell-exact* claim is a Nightmare claim. All three difficulties are
covered by the masked CRC over 200 seeds, and those three corpora are genuinely different
generations rather than one capture relabelled: Normal and Hell disagree on 1800 of 26,200
records, across the nine levels difficulty actually rescales. What a CRC cannot do is localise a
fault. It catches a level that generates differently; it will not catch a single wrong cell
inside a level that otherwise matches.

The holdouts carry the argument. Matching the seeds you developed against proves little; a seed
captured up front, never inspected, and only run at the end is the one that would have exposed a
rule fitted to the examples in front of us.

## Everything else

Depth is not uniform, and the packages do not rest on the same evidence.

| package | what it is checked against |
|-|-|
| `drlg` | engine dumps, cell for cell, plus the blind holdouts above |
| `save` | real `.d2s` files, byte-exact round trip |
| `item` | the treasure-class and affix tables, and rolls traced through the binary's own routine |
| `game` | the rules and tables read out of the binary, not against a live server |
| `net` | recovered packet layouts and size tables, not against a live server |
| `pathfinding` | generated maps, and the movement gates the server applies |

Where a rule was recovered from the disassembly rather than inferred from output, the address of
the routine it came from sits in the comment beside the code implementing it, so a claim can be
checked against the binary instead of taken on trust.

## Running it

```sh
zig build test               # every package
zig build test-drlg          # one package
```

In `drlg` the golden harnesses are split from the unit tests, because they are not the same kind
of test: each one regenerates whole acts and diffs them against captured engine data, so they are
bound by generation throughput. They build as their own artifact pinned to **ReleaseFast**, because in
Debug the same run takes minutes and can be OOM-killed, while the unit tests stay in Debug:

```sh
cd packages/drlg
zig build test-unit          # unit tests only, Debug, seconds: the edit/build loop
zig build verify             # the golden gate only, always ReleaseFast (~9 min, needs RAM)
zig build test               # both
```

`-Dtest-filter` applies to either, so a single check stays cheap:

```sh
zig build verify -Dtest-filter="all-acts golden"
zig build verify -Dtest-filter="BLIND holdout"
```
