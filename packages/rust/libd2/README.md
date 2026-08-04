# libd2

Clean-room Diablo II 1.14d engine core, as a Rust crate.

Give it a seed and it produces the same world the game does: rooms, objects, monsters, level
adjacency and subtile collision, for every level of all five acts. No game installation, and
nothing read from disk — the tables are compiled in.

```sh
cargo add libd2
```

```rust
use libd2::drlg::{Difficulty, Generator};

let drlg = Generator::new()?;
let act = drlg.act(1337, 0).difficulty(Difficulty::Normal).generate()?;
println!("{act}");

for level in act.levels.iter().take(3) {
    println!("  {level}  {:?} {}", level.kind, level.size);
}
# Ok::<(), libd2::Error>(())
```

```text
Act 1 of seed 1337 (39 levels)
  Rogue Encampment (level 1, 35 rooms)  Preset 56x40
  Blood Moor (level 2, 83 rooms)  Wilderness 96x56
  Cold Plains (level 3, 97 rooms)  Wilderness 80x80
```

The engine itself is Zig, built from source by the build script and linked statically, so
`zig` 0.16+ has to be on PATH to build. Nothing is needed at run time.

## Coordinates and ids have types

The engine works in three coordinate frames and mixing them is the easiest mistake to make
against this data, so each is its own type: `Tile` is a world position in tiles, `Subtile` is
a world position in subtiles (five to a tile, the frame in-game coordinates use) and `Local`
is a position in one level's own frame, which is what its map data is authored in. Only a
`Level` can convert between the last two, because only it knows where the level sits:

```rust
for (object, at) in cold_plains.objects() {
    println!("{} at {} in the level, {} in the world", object.name(), at, cold_plains.world(at));
}
```

```text
Shrine at (57, 222) in the level, (4977, 5622) in the world
```

For the same reason a preset unit carries its id inside its variant, so an Objects.txt row
cannot be read as a MonStats id:

```rust
match unit.what {
    Preset::Monster(id) => format!("monster {id}"),
    Preset::Object(id) => id.name(),
    Preset::Exit(id) => format!("warp {id}"),
    Preset::Other { etype, txt_file_no } => format!("etype {etype} row {txt_file_no}"),
}
```

## Owned or borrowed

`generate()` copies everything out and frees the native act before returning, so an `Act` is
plain owned data: no lifetimes, `Send + Sync`, nothing left to release. It outlives the
generator that made it, and can be cached, sent between threads or serialised.

`open()` keeps the act native and reads out of it only what you ask for, which is what you
want when you need one level out of an act, or want to look before deciding what to read:

```rust
let act = drlg.act(1337, 0).open()?;
let cold_plains = act.level(3).unwrap();
println!("{} rooms", cold_plains.rooms()?.len());   // only this level is ever copied
// the native act is freed when `act` goes out of scope
```

Freeing is the borrow ending rather than a call anyone has to remember, and the compiler
holds the whole chain together. Dropping the generator while an act is open:

```text
error[E0505]: cannot move out of `drlg` because it is borrowed
```

Sending an open act to another thread, which would free it on the wrong one:

```text
error[E0277]: `NonNull<ActHandle>` cannot be sent between threads safely
```

`Generator` is `Send` but not `Sync`, so it can move between threads and cannot be shared:
the engine keeps per-generation state that two concurrent calls would trample. One generator
per thread is the supported shape.

## Collision

A collision grid is its own call rather than a field on every level, so nothing pays for one
it never looks at, and there is no optional field that is empty only because you forgot to
ask for it:

```rust
let grid = drlg.collision(1337, Difficulty::Normal, 3)?;
println!("{}x{}", grid.width(), grid.height());          // 400x400
println!("{}", grid.is_walkable(Local::new(200, 200)));  // true
println!("{:?}", grid.get(Local::new(200, 200)));        // OPEN
println!("{:?}", grid.get(Local::new(0, 0)));            // VOID — no room covers the corner
```

It is indexed in the level's own frame, so a `Local` addresses it directly, and reads off the
edge give `Collision::VOID` rather than panicking, because a pathfinder walking off a level is
asking a legitimate question. Have an act open already? `level.collision()?` reads the same
grid without regenerating.

## Features

- `serde` — `Serialize` and `Deserialize` for every value type.

## Is it right?

Every claim above is checked against captures taken from the retail engine, per cell, not
against this code's own output. See
[VERIFICATION.md](https://github.com/jaenster/libd2/blob/main/docs/VERIFICATION.md).

## Licence

MIT.
