# libd2 from Rust

```sh
cargo add libd2
```

The crate ships no binaries. A crate is source, and cargo already knows the target it is
building for, so the build script compiles the engine for exactly that one and links it
statically. That means `zig` 0.16+ has to be on PATH to build, and nothing at all is needed at
run time. Cross-compiling needs no extra toolchain:

```sh
cargo build --target aarch64-unknown-linux-musl   # from any host
```

## Generate a world from a seed

```rust
use libd2::drlg::{Difficulty, Generator};

// One generator, reused. Loading the game tables is the expensive part.
let drlg = Generator::new()?;

// act counts from zero the way the engine does: 0 is Act I, 4 is Act V.
let act = drlg.act(1337, 0).difficulty(Difficulty::Normal).generate()?;
println!("{act}");

for level in act.levels.iter().take(3) {
    println!("  {level}  {:?} {}", level.kind, level.size);
}
```

```text
Act 1 of seed 1337 (39 levels)
  Rogue Encampment (level 1, 35 rooms)  Preset 56x40
  Blood Moor (level 2, 83 rooms)  Wilderness 96x56
  Cold Plains (level 3, 97 rooms)  Wilderness 80x80
```

The same seed always gives the same world, matching the retail engine cell for cell.

## Coordinates carry their frame

The engine works in three frames and mixing them is the easiest mistake to make against this
data, so each is its own type. `Tile` is a world position in tiles, `Subtile` is a world
position in subtiles (five to a tile, the frame in-game coordinates use), and `Local` is a
position in one level's own frame, which is what its map data is authored in.

Only a `Level` can convert between the last two, because only it knows where the level sits:

```rust
let cold_plains = act.level(3).unwrap();

for shrine in cold_plains.shrines() {
    let kind = if shrine.is_well() { "well" } else { "shrine" };
    println!("{kind} at {} in the world, {} in the level", shrine.at, cold_plains.local(shrine.at));
}
```

```text
shrine at (4977, 5622) in the world, (57, 222) in the level
shrine at (4972, 5572) in the world, (52, 172) in the level
shrine at (5252, 5492) in the world, (332, 92) in the level
well at (5052, 5457) in the world, (132, 57) in the level
shrine at (5012, 5452) in the world, (92, 52) in the level
```

## Ids carry what they index

A preset unit holds its id inside its variant, so an Objects.txt row cannot be read as a
MonStats id:

```rust
for unit in &cold_plains.presets {
    let what = match unit.what {
        Preset::Monster(id) => format!("monster {id}"),
        Preset::Object(id) => id.name(),
        Preset::Exit(id) => format!("warp {id}"),
        Preset::Other { etype, txt_file_no } => format!("etype {etype} row {txt_file_no}"),
    };
    println!("{what} at {}", unit.at);
}
```

`presets` is what the level's own map data places. Some things you might expect are not in
there: a wilderness waypoint is positioned by the generator rather than by preset data, so it
will not appear among a wilderness level's presets.

`shrines()` above is a view over the same list rather than a second source, which is why it
needs neither the seed nor a round trip to find out. The C ABI has a separate entry point for
them that regenerates an act to answer; it is deprecated for exactly that reason, and this
crate does not bind it.

## Where a level leads

```rust
println!("{:?}", cold_plains.destinations());          // [LevelId(2), LevelId(4), LevelId(9), LevelId(17)]

for at in cold_plains.crossings_to(LevelId(4)) {
    println!("walk to {at} to leave");
}
```

There is one entry per set warp slot rather than one per destination, so a room with three
slots reports the same position three times.

## Collision

A grid is its own call rather than a field on every level, so nothing pays for one it never
looks at:

```rust
let grid = drlg.collision(1337, Difficulty::Normal, 3)?;

println!("{}x{}", grid.width(), grid.height());          // 400x400
println!("{}", grid.is_walkable(Local::new(200, 200)));  // true
println!("{:?}", grid.get(Local::new(200, 200)));        // OPEN
println!("{:?}", grid.get(Local::new(0, 0)));            // VOID — no room covers the corner
```

It is addressed in the level's own frame, so a `Local` indexes it directly. Reads off the edge
give `Collision::VOID` rather than panicking, because a pathfinder walking off a level is
asking a legitimate question. `Collision` is a flag set with the usual bit operators, so you
can reason about missiles or line of sight yourself rather than only about walking.

## Owned or borrowed

`generate()` copies everything out and frees the native act before returning, so an `Act` is
plain owned data: no lifetimes, `Send + Sync`, nothing left to release. It outlives the
generator that made it, and can be cached, sent between threads or serialised.

`open()` keeps the act native and reads only what you ask for, which is what you want for one
level out of an act:

```rust
let act = drlg.act(1337, 0).open()?;
let cold_plains = act.level(3).unwrap();
println!("{} rooms", cold_plains.rooms()?.len());   // only this level is ever copied
// the native act is freed when `act` goes out of scope
```

Freeing is the borrow ending rather than a call anyone has to remember, and the compiler holds
the chain together. Dropping the generator while an act is open does not compile:

```text
error[E0505]: cannot move out of `drlg` because it is borrowed
```

Neither does sending an open act to another thread, which would free it on the wrong one:

```text
error[E0277]: `NonNull<ActHandle>` cannot be sent between threads safely
```

## Threading

`Generator` is `Send` but not `Sync`, so it can move between threads and cannot be shared: the
engine keeps per-generation state that two concurrent calls would trample. One generator per
thread is the supported shape, and it is what the project's own cross-seed verifier does.

## Features

- `serde` — `Serialize` and `Deserialize` for every value type, including collision grids.

## Without the crate

If you would rather not build the engine, the shared library and header are attached to each
GitHub release and the C ABI is documented — see the [API reference](c.md). Declare the entry
points with `extern "C"` and mirror the structs with `#[repr(C)]`.
