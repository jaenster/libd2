//! The same world the game generates, checked against known values.

use libd2::drlg::{object_name, Collision, Difficulty, Generator, LevelId, LevelKind, Local, Preset, Shrine, Subtile};

fn drlg() -> Generator {
    Generator::new().expect("the game tables load")
}

#[test]
fn act_one_of_seed_1337() {
    let act = drlg().act(1337, 0).generate().unwrap();
    assert_eq!(act.to_string(), "Act 1 of seed 1337 (39 levels)");

    let cold_plains = act.level(3).unwrap();
    assert_eq!(cold_plains.to_string(), "Cold Plains (level 3, 97 rooms)");
    assert_eq!(cold_plains.kind, LevelKind::Wilderness);
    assert!(cold_plains.placed);
    assert_eq!(cold_plains.size.to_string(), "80x80");
    assert_eq!(cold_plains.destinations(), [2, 4, 9, 17].map(LevelId));

    assert_eq!(act.level(1).unwrap().kind, LevelKind::Preset);
    assert_eq!(act.level(1).unwrap().name, "Rogue Encampment");
}

#[test]
fn the_same_seed_generates_the_same_world() {
    let drlg = drlg();
    let a = drlg.act(1337, 0).generate().unwrap();
    let b = drlg.act(1337, 0).generate().unwrap();
    assert_eq!(a.level(3).unwrap().rooms, b.level(3).unwrap().rooms);
}

#[test]
fn difficulty_changes_the_levels_that_rescale() {
    let drlg = drlg();
    let normal = drlg.act(1337, 0).generate().unwrap();
    let hell = drlg.act(1337, 0).difficulty(Difficulty::Hell).generate().unwrap();
    assert_ne!(normal.levels.len(), 0);
    assert_eq!(normal.levels.len(), hell.levels.len());
}

#[test]
fn shrines_are_where_the_engine_puts_them() {
    let act = drlg().act(1337, 0).generate().unwrap();
    let shrines: Vec<_> = act.level(3).unwrap().shrines().collect();
    assert_eq!(shrines.len(), 5);
    assert!(shrines.iter().any(|s| s.at == Subtile::new(4977, 5622)));
    assert!(shrines.iter().any(Shrine::is_well));
}

#[test]
fn collision_is_a_call_of_its_own() {
    let drlg = drlg();
    let grid = drlg.collision(1337, Difficulty::Normal, 3).unwrap();
    assert_eq!((grid.width(), grid.height()), (400, 400));
    assert_eq!(grid.cells().len(), 400 * 400);
    assert!(grid.is_walkable(Local::new(200, 200)));

    // Off the edge of a level is a legitimate question with a definite answer.
    assert_eq!(grid.get(Local::new(-1, 0)), Collision::VOID);
    assert!(!grid.is_walkable(Local::new(-1, 0)));
}

#[test]
fn preset_ids_are_typed_by_what_they_index() {
    let act = drlg().act(1337, 0).generate().unwrap();
    let cold_plains = act.level(3).unwrap();

    let counted = cold_plains.monsters().count()
        + cold_plains.objects().count()
        + cold_plains.exits().count();
    assert_eq!(counted, cold_plains.presets.len());
    assert!(cold_plains.objects().any(|(id, _)| id.name() == "Shrine"));

    let unnamed = cold_plains.presets.iter().find(|u| matches!(u.what, Preset::Other { .. }));
    assert!(unnamed.is_none(), "every preset kind in Act I should be named: {unnamed:?}");
}

#[test]
fn coordinate_frames_convert_through_the_level() {
    let act = drlg().act(1337, 0).generate().unwrap();
    let cold_plains = act.level(3).unwrap();

    let corner = Local::new(0, 0);
    let world = cold_plains.world(corner);
    assert_eq!(world, cold_plains.origin.subtiles());
    assert_eq!(cold_plains.local(world), corner);
    assert!(cold_plains.contains(world));

    // One subtile past the far edge is outside the level.
    let (w, h) = cold_plains.size.subtiles();
    assert!(!cold_plains.contains(cold_plains.world(Local::new(w, h))));

    // A room's world tile and its level-local subtile describe the same place.
    let room = cold_plains.rooms[0];
    assert_eq!(cold_plains.local_of(room.origin), cold_plains.local(room.origin.subtiles()));
    assert!(room.contains(room.origin));
}

#[test]
fn the_borrowed_form_reads_only_what_it_is_asked_for() {
    let drlg = drlg();
    let act = drlg.act(1337, 0).open().unwrap();

    assert_eq!(act.len(), 39);
    let cold_plains = act.level(3).unwrap();
    assert_eq!(cold_plains.name(), "Cold Plains");
    assert_eq!(cold_plains.rooms().unwrap().len(), 97);

    // Reading a grid through an already-open act gives the same one, without regenerating.
    assert_eq!(
        cold_plains.collision().unwrap().cells(),
        drlg.collision(1337, Difficulty::Normal, 3).unwrap().cells()
    );

    // And copies out to exactly what generate() would have produced.
    let owned = act.to_act().unwrap();
    assert_eq!(owned.level(3).unwrap().rooms, cold_plains.rooms().unwrap());
}

#[test]
fn an_act_outlives_the_generator_that_made_it() {
    let act = drlg().act(1337, 0).generate().unwrap();
    let act = std::thread::spawn(move || act).join().unwrap();
    assert_eq!(act.levels.len(), 39);
}

#[test]
fn collision_flags_read_as_names() {
    assert_eq!(format!("{:?}", Collision::WALL | Collision::NO_PLAYER), "WALL|NO_PLAYER");
    assert_eq!(format!("{:?}", Collision::VOID), "VOID");
    assert_eq!(format!("{:?}", Collision::OPEN), "OPEN");
    assert!(Collision::PLAYER_PATH.contains(Collision::WALL));
    assert!(!Collision::PLAYER_PATH.contains(Collision::VISIBLE));
}

#[test]
fn difficulty_parses_the_way_a_command_line_would_spell_it() {
    assert_eq!("hell".parse(), Ok(Difficulty::Hell));
    assert_eq!("NM".parse(), Ok(Difficulty::Nightmare));
    assert_eq!(Difficulty::try_from(2), Ok(Difficulty::Hell));
    assert!("purgatory".parse::<Difficulty>().is_err());
}

#[test]
fn object_names_need_no_generator() {
    assert_eq!(object_name(2), "Shrine");
}

#[cfg(feature = "serde")]
#[test]
fn an_act_and_a_grid_round_trip_through_json() {
    let drlg = drlg();
    let act = drlg.act(1337, 0).generate().unwrap();
    let back: libd2::drlg::Act = serde_json::from_str(&serde_json::to_string(&act).unwrap()).unwrap();
    assert_eq!(back.level(3).unwrap().rooms, act.level(3).unwrap().rooms);

    let grid = drlg.collision(1337, Difficulty::Normal, 3).unwrap();
    let back: libd2::drlg::CollisionGrid =
        serde_json::from_str(&serde_json::to_string(&grid).unwrap()).unwrap();
    assert_eq!(back.cells(), grid.cells());
}

#[test]
fn shrines_are_a_view_over_presets_not_a_second_source() {
    let act = drlg().act(1337, 0).generate().unwrap();
    let cold_plains = act.level(3).unwrap();

    // Every shrine is one of the level's own objects, at the same place.
    for shrine in cold_plains.shrines() {
        let local = cold_plains.local(shrine.at);
        assert!(cold_plains.objects().any(|(id, at)| id == shrine.id && at == local));
    }
}
