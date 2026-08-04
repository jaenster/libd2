//! Print what a seed generates.
//!
//!     cargo run --example world -- 1337 0

use libd2::drlg::{Collision, Difficulty, Generator};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let seed: u32 = args.next().unwrap_or_else(|| "1337".into()).parse()?;
    let number: u8 = args.next().unwrap_or_else(|| "0".into()).parse()?;
    let difficulty: Difficulty = args.next().unwrap_or_else(|| "normal".into()).parse()?;

    let drlg = Generator::new()?;
    let act = drlg.act(seed, number).difficulty(difficulty).generate()?;
    println!("{act} on {difficulty}\n");

    for level in &act {
        println!("{level}  {:?} {}", level.kind, level.size);
    }

    let Some(cold_plains) = act.level(3) else { return Ok(()) };
    println!("\n{} leads to {:?}", cold_plains.name, cold_plains.destinations());

    println!("\nwhat the map data places in {}:", cold_plains.name);
    let mut counts = std::collections::BTreeMap::new();
    for (object, _) in cold_plains.objects() {
        *counts.entry(object.name()).or_insert(0usize) += 1;
    }
    let mut counts: Vec<_> = counts.into_iter().collect();
    counts.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    for (name, n) in counts.iter().take(4) {
        println!("  {n} x {name}");
    }

    println!("\nshrines and wells in {}:", cold_plains.name);
    for shrine in cold_plains.shrines() {
        let kind = if shrine.is_well() { "well" } else { "shrine" };
        println!("  {kind} at {} in the world, {} in the level", shrine.at, cold_plains.local(shrine.at));
    }

    // Collision is its own call, so nothing pays for a grid it never looks at.
    let grid = drlg.collision(seed, difficulty, cold_plains.id)?;
    let walkable = grid.cells().iter().filter(|c| !c.intersects(Collision::PLAYER_PATH)).count();
    println!(
        "\n{}x{} subtiles of collision, {walkable} walkable ({}%)",
        grid.width(),
        grid.height(),
        walkable * 100 / grid.cells().len()
    );

    Ok(())
}
