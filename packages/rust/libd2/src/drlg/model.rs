//! The values a generated world is made of.
//!
//! All of it is plain owned data: no lifetimes, no native pointers, `Send + Sync`, `Clone`
//! and `Debug`. With the `serde` feature it is all serialisable too.

use std::fmt;
use std::ops::{BitAnd, BitAndAssign, BitOr, BitOrAssign, Index, Not};

#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

macro_rules! id {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
        #[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
        #[repr(transparent)]
        pub struct $name(pub i32);

        impl From<i32> for $name {
            fn from(v: i32) -> Self {
                Self(v)
            }
        }

        impl From<$name> for i32 {
            fn from(v: $name) -> i32 {
                v.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                fmt::Display::fmt(&self.0, f)
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, concat!(stringify!($name), "({})"), self.0)
            }
        }
    };
}

id! {
    /// A row of Levels.txt. Stable across seeds, so it is the way to name a level.
    LevelId
}
id! {
    /// A row of MonStats.txt.
    MonsterId
}
id! {
    /// A row of Objects.txt.
    ObjectId
}
id! {
    /// A warp, as the level's own map data numbers them.
    WarpId
}

impl ObjectId {
    /// The Objects.txt name, for example `Waypoint`.
    pub fn name(self) -> String {
        super::object_name(self)
    }
}

/// A world position in TILES.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Tile {
    /// World X in tiles.
    pub x: i32,
    /// World Y in tiles.
    pub y: i32,
}

/// A world position in SUBTILES. This is the frame in-game coordinates use, five to a tile.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Subtile {
    /// World X in subtiles.
    pub x: i32,
    /// World Y in subtiles.
    pub y: i32,
}

/// A LEVEL-LOCAL position in SUBTILES, measured from the level's own top-left corner.
///
/// This is the frame the level's map data is authored in, so preset units and warps come
/// back in it. [`Level::world`] converts to the world frame; the two are not
/// interchangeable, and this type is what stops you mixing them up.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Local {
    /// Level-local X in subtiles.
    pub x: i32,
    /// Level-local Y in subtiles.
    pub y: i32,
}

/// Subtiles per tile.
pub const SUBTILES: i32 = 5;

impl Tile {
    /// A tile position.
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }

    /// The subtile at this tile's top-left corner.
    pub const fn subtiles(self) -> Subtile {
        Subtile { x: self.x * SUBTILES, y: self.y * SUBTILES }
    }
}

impl Subtile {
    /// A world subtile position.
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }

    /// The tile this subtile falls in.
    pub const fn tile(self) -> Tile {
        Tile { x: self.x.div_euclid(SUBTILES), y: self.y.div_euclid(SUBTILES) }
    }

    /// Steps along the grid between two positions, counting diagonals as two.
    pub const fn manhattan(self, other: Self) -> i32 {
        (self.x - other.x).abs() + (self.y - other.y).abs()
    }

    /// Straight-line distance between two positions, in subtiles.
    pub fn distance(self, other: Self) -> f64 {
        let (dx, dy) = ((self.x - other.x) as f64, (self.y - other.y) as f64);
        dx.hypot(dy)
    }
}

impl Local {
    /// A level-local subtile position.
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }

    /// Steps along the grid between two positions, counting diagonals as two.
    pub const fn manhattan(self, other: Self) -> i32 {
        (self.x - other.x).abs() + (self.y - other.y).abs()
    }

    /// Straight-line distance between two positions, in subtiles.
    pub fn distance(self, other: Self) -> f64 {
        let (dx, dy) = ((self.x - other.x) as f64, (self.y - other.y) as f64);
        dx.hypot(dy)
    }
}

impl fmt::Display for Tile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

impl fmt::Display for Subtile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

impl fmt::Display for Local {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

/// A width and height in TILES.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Size {
    /// Width in tiles.
    pub width: i32,
    /// Height in tiles.
    pub height: i32,
}

impl Size {
    /// The same extent measured in subtiles.
    pub const fn subtiles(self) -> (i32, i32) {
        (self.width * SUBTILES, self.height * SUBTILES)
    }
}

impl fmt::Display for Size {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}

/// Which difficulty a world is generated for. Nine levels change size with it.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
#[repr(i32)]
pub enum Difficulty {
    /// Normal.
    #[default]
    Normal = 0,
    /// Nightmare.
    Nightmare = 1,
    /// Hell.
    Hell = 2,
}

impl fmt::Display for Difficulty {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Difficulty::Normal => "normal",
            Difficulty::Nightmare => "nightmare",
            Difficulty::Hell => "hell",
        })
    }
}

impl TryFrom<i32> for Difficulty {
    type Error = UnknownDifficulty;

    fn try_from(v: i32) -> Result<Self, UnknownDifficulty> {
        match v {
            0 => Ok(Difficulty::Normal),
            1 => Ok(Difficulty::Nightmare),
            2 => Ok(Difficulty::Hell),
            _ => Err(UnknownDifficulty),
        }
    }
}

impl std::str::FromStr for Difficulty {
    type Err = UnknownDifficulty;

    fn from_str(s: &str) -> Result<Self, UnknownDifficulty> {
        match s.to_ascii_lowercase().as_str() {
            "normal" | "n" | "0" => Ok(Difficulty::Normal),
            "nightmare" | "nm" | "1" => Ok(Difficulty::Nightmare),
            "hell" | "h" | "2" => Ok(Difficulty::Hell),
            _ => Err(UnknownDifficulty),
        }
    }
}

/// Returned when a value does not name a difficulty.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct UnknownDifficulty;

impl fmt::Display for UnknownDifficulty {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("not a difficulty: expected normal, nightmare or hell")
    }
}

impl std::error::Error for UnknownDifficulty {}

/// How a level is laid out. Mirrors the Levels.txt `DrlgType` column.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub enum LevelKind {
    /// Built from maze tiles: the Catacombs, the Durance.
    Maze,
    /// A hand-authored preset area: towns, the Cathedral.
    Preset,
    /// Open outdoor ground: Cold Plains, the Jungle.
    Wilderness,
    /// A value this binding has no name for, kept rather than discarded.
    Other(i32),
}

impl From<i32> for LevelKind {
    fn from(v: i32) -> Self {
        match v {
            1 => LevelKind::Maze,
            2 => LevelKind::Preset,
            3 => LevelKind::Wilderness,
            other => LevelKind::Other(other),
        }
    }
}

/// One generated room, as a world rectangle in TILES.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Room {
    /// Top-left corner, in world tiles.
    pub origin: Tile,
    /// Extent, in tiles.
    pub size: Size,
    /// The engine's `RoomEx.nType`.
    pub kind: i32,
    /// The engine's `RoomEx.nPresetType`.
    pub preset_type: i32,
    /// Which map file the room picked, or -1 where the room has no such selector.
    pub picked_file: i32,
}

impl Room {
    /// True when this tile falls inside the room.
    pub const fn contains(&self, t: Tile) -> bool {
        t.x >= self.origin.x
            && t.y >= self.origin.y
            && t.x < self.origin.x + self.size.width
            && t.y < self.origin.y + self.size.height
    }
}

/// A seeded outdoor shrine or well.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Shrine {
    /// Which object it is.
    pub id: ObjectId,
    /// Where it stands, in world subtiles.
    pub at: Subtile,
}

impl Shrine {
    /// True for a well rather than a shrine.
    pub fn is_well(&self) -> bool {
        self.id == ObjectId(130)
    }
}

/// The Objects.txt rows the outdoor shrine spawner can place: four shrine variants and the
/// well. Taken from the engine's own LvlSub Type-5 variant table, which is the whole set it
/// draws from, so filtering a level's objects on it reproduces what the spawner produced.
const SHRINE_CLASSES: [i32; 5] = [2, 81, 83, 84, 130];

/// What a preset unit is, and what it is.
///
/// The id lives inside the variant, so an Objects.txt row cannot be read as a MonStats id:
///
/// ```
/// # use libd2::drlg::{Preset, PresetUnit, Local};
/// # fn describe(unit: &PresetUnit) -> String {
/// match unit.what {
///     Preset::Monster(id) => format!("monster {id}"),
///     Preset::Object(id) => id.name(),
///     Preset::Exit(id) => format!("warp {id}"),
///     Preset::Other { etype, txt_file_no } => format!("etype {etype} row {txt_file_no}"),
/// }
/// # }
/// ```
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub enum Preset {
    /// A monster.
    Monster(MonsterId),
    /// An object: a chest, a shrine, a waypoint, scenery.
    Object(ObjectId),
    /// A warp out of the level.
    Exit(WarpId),
    /// A value this binding has no name for, kept rather than discarded.
    Other {
        /// The engine's unit type.
        etype: i32,
        /// The row it indexes.
        txt_file_no: i32,
    },
}

impl Preset {
    pub(crate) fn new(etype: i32, txt_file_no: i32) -> Self {
        match etype {
            1 => Preset::Monster(MonsterId(txt_file_no)),
            2 => Preset::Object(ObjectId(txt_file_no)),
            5 => Preset::Exit(WarpId(txt_file_no)),
            _ => Preset::Other { etype, txt_file_no },
        }
    }
}

/// Something the level's own map data places, at level-local subtile coordinates.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct PresetUnit {
    /// What it is.
    pub what: Preset,
    /// Where it is, in the level's own frame.
    pub at: Local,
}

/// A place you can cross into another level.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Adjacent {
    /// The level this crossing leads to.
    pub to: LevelId,
    /// Where the crossing is, in this level's own frame.
    pub at: Local,
}

/// The engine's collision flags for one subtile, and the masks built from them.
///
/// A `u16` newtype rather than a bare integer, so a mask cannot be confused with a
/// coordinate, and it composes with the usual bit operators:
///
/// ```
/// use libd2::drlg::Collision;
/// let blocked = Collision::WALL | Collision::NO_PLAYER;
/// assert!(blocked.intersects(Collision::WALL));
/// assert!(!blocked.intersects(Collision::PRESET));
/// assert_eq!(format!("{blocked:?}"), "WALL|NO_PLAYER");
/// ```
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default, PartialOrd, Ord)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
#[repr(transparent)]
pub struct Collision(pub u16);

impl Collision {
    /// Nothing set: open ground.
    pub const OPEN: Self = Self(0x0000);
    /// Blocks movement outright.
    pub const WALL: Self = Self(0x0001);
    /// Line of sight passes, movement does not.
    pub const VISIBLE: Self = Self(0x0002);
    /// Stops a missile but not a walking player.
    pub const MISSILE_BARRIER: Self = Self(0x0004);
    /// Players may not stand here.
    pub const NO_PLAYER: Self = Self(0x0008);
    /// Placed by the level preset rather than the tile art.
    pub const PRESET: Self = Self(0x0010);
    /// No floor tile covers this cell.
    pub const NO_FLOOR: Self = Self(0x0020);

    /// Cells no room covers.
    pub const VOID: Self = Self(0xFFFF);

    /// What blocks a walking player.
    pub const PLAYER_PATH: Self = Self(0x1C09);
    /// What blocks a missile in flight.
    pub const MISSILE_FLIGHT: Self = Self(0x0005);

    /// The raw flags.
    pub const fn bits(self) -> u16 {
        self.0
    }

    /// True when any flag in `mask` is set here.
    pub const fn intersects(self, mask: Self) -> bool {
        self.0 & mask.0 != 0
    }

    /// True when every flag in `mask` is set here.
    pub const fn contains(self, mask: Self) -> bool {
        self.0 & mask.0 == mask.0
    }

    /// True for open ground: no flag set at all.
    pub const fn is_open(self) -> bool {
        self.0 == 0
    }
}

impl BitOr for Collision {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl BitAnd for Collision {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self {
        Self(self.0 & rhs.0)
    }
}

impl BitOrAssign for Collision {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

impl BitAndAssign for Collision {
    fn bitand_assign(&mut self, rhs: Self) {
        self.0 &= rhs.0;
    }
}

impl Not for Collision {
    type Output = Self;
    fn not(self) -> Self {
        Self(!self.0)
    }
}

impl fmt::Debug for Collision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        const NAMES: [(u16, &str); 6] = [
            (0x0001, "WALL"),
            (0x0002, "VISIBLE"),
            (0x0004, "MISSILE_BARRIER"),
            (0x0008, "NO_PLAYER"),
            (0x0010, "PRESET"),
            (0x0020, "NO_FLOOR"),
        ];
        match self.0 {
            0xFFFF => return f.write_str("VOID"),
            0 => return f.write_str("OPEN"),
            _ => {}
        }
        let mut rest = self.0;
        let mut first = true;
        for (bit, name) in NAMES {
            if self.0 & bit != 0 {
                if !first {
                    f.write_str("|")?;
                }
                f.write_str(name)?;
                first = false;
                rest &= !bit;
            }
        }
        if rest != 0 {
            if !first {
                f.write_str("|")?;
            }
            write!(f, "{rest:#06x}")?;
        }
        Ok(())
    }
}

/// A level's subtile collision, one cell per subtile, row-major from the level's top-left.
///
/// Indexed in the level's own frame, so a [`Local`] addresses it directly. Reads outside the
/// grid give [`Collision::VOID`] rather than panicking, because a pathfinder walking off the
/// edge of a level is asking a legitimate question.
#[derive(Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
#[cfg_attr(feature = "serde", serde(try_from = "GridRepr", into = "GridRepr"))]
pub struct CollisionGrid {
    cells: Vec<Collision>,
    width: usize,
    height: usize,
}

impl CollisionGrid {
    pub(crate) fn new(cells: Vec<Collision>, width: usize, height: usize) -> Self {
        debug_assert_eq!(cells.len(), width * height);
        Self { cells, width, height }
    }

    /// Width in subtiles.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in subtiles.
    pub fn height(&self) -> usize {
        self.height
    }

    /// The flags at a position, or [`Collision::VOID`] outside the grid.
    pub fn get(&self, at: Local) -> Collision {
        if at.x < 0 || at.y < 0 || at.x as usize >= self.width || at.y as usize >= self.height {
            return Collision::VOID;
        }
        self.cells[at.y as usize * self.width + at.x as usize]
    }

    /// True where a walking player fits.
    pub fn is_walkable(&self, at: Local) -> bool {
        !self.get(at).intersects(Collision::PLAYER_PATH)
    }

    /// True where a missile in flight passes.
    pub fn is_clear_for_missiles(&self, at: Local) -> bool {
        !self.get(at).intersects(Collision::MISSILE_FLIGHT)
    }

    /// Every cell, row-major.
    pub fn cells(&self) -> &[Collision] {
        &self.cells
    }

    /// The grid one row at a time.
    pub fn rows(&self) -> impl ExactSizeIterator<Item = &[Collision]> {
        self.cells.chunks_exact(self.width)
    }

    /// Every position and its flags.
    pub fn iter(&self) -> impl Iterator<Item = (Local, Collision)> + '_ {
        let width = self.width;
        self.cells
            .iter()
            .enumerate()
            .map(move |(i, &c)| (Local::new((i % width) as i32, (i / width) as i32), c))
    }
}

impl Index<Local> for CollisionGrid {
    type Output = Collision;

    /// Panics outside the grid. Use [`CollisionGrid::get`] where the position may be out of
    /// bounds.
    fn index(&self, at: Local) -> &Collision {
        assert!(
            at.x >= 0 && at.y >= 0 && (at.x as usize) < self.width && (at.y as usize) < self.height,
            "{at} is outside the {}x{} grid",
            self.width,
            self.height
        );
        &self.cells[at.y as usize * self.width + at.x as usize]
    }
}

impl fmt::Debug for CollisionGrid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CollisionGrid")
            .field("width", &self.width)
            .field("height", &self.height)
            .finish_non_exhaustive()
    }
}

/// Serialised shape of a [`CollisionGrid`], which exists so that deserialising cannot
/// produce a grid whose cell count disagrees with its dimensions.
#[cfg(feature = "serde")]
#[derive(Serialize, Deserialize)]
struct GridRepr {
    width: usize,
    height: usize,
    cells: Vec<Collision>,
}

#[cfg(feature = "serde")]
impl From<CollisionGrid> for GridRepr {
    fn from(g: CollisionGrid) -> Self {
        Self { width: g.width, height: g.height, cells: g.cells }
    }
}

#[cfg(feature = "serde")]
impl TryFrom<GridRepr> for CollisionGrid {
    type Error = &'static str;

    fn try_from(r: GridRepr) -> Result<Self, &'static str> {
        if r.cells.len() != r.width * r.height {
            return Err("collision grid cell count does not match its dimensions");
        }
        Ok(Self { cells: r.cells, width: r.width, height: r.height })
    }
}

/// One level of a generated act.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Level {
    /// Which level this is. Stable across seeds.
    pub id: LevelId,
    /// The in-game name, for example `Cold Plains`.
    pub name: String,
    /// How the level is laid out.
    pub kind: LevelKind,
    /// True when the act's placement graph positioned it on the surface, false for an
    /// interior reached through a warp.
    pub placed: bool,
    /// Where the level sits in the world, in tiles.
    pub origin: Tile,
    /// How big it is, in tiles.
    pub size: Size,
    /// The rooms the generator placed.
    pub rooms: Vec<Room>,
    /// Monsters, objects and exits the level's own map data places.
    pub presets: Vec<PresetUnit>,
    /// Where this level touches others.
    pub adjacents: Vec<Adjacent>,
}

impl Level {
    /// Where a level-local position sits in the world.
    pub const fn world(&self, at: Local) -> Subtile {
        Subtile { x: self.origin.x * SUBTILES + at.x, y: self.origin.y * SUBTILES + at.y }
    }

    /// Where a world position sits in this level's own frame. The result is outside the
    /// grid if the position is not in this level; [`Level::contains`] says which.
    pub const fn local(&self, at: Subtile) -> Local {
        Local { x: at.x - self.origin.x * SUBTILES, y: at.y - self.origin.y * SUBTILES }
    }

    /// Where a world tile, such as a [`Room`] corner, sits in this level's own frame.
    pub const fn local_of(&self, t: Tile) -> Local {
        Local { x: (t.x - self.origin.x) * SUBTILES, y: (t.y - self.origin.y) * SUBTILES }
    }

    /// True when a world position falls inside this level's bounds.
    pub const fn contains(&self, at: Subtile) -> bool {
        let local = self.local(at);
        local.x >= 0
            && local.y >= 0
            && local.x < self.size.width * SUBTILES
            && local.y < self.size.height * SUBTILES
    }

    /// The monsters the level's map data places.
    pub fn monsters(&self) -> impl Iterator<Item = (MonsterId, Local)> + '_ {
        self.presets.iter().filter_map(|u| match u.what {
            Preset::Monster(id) => Some((id, u.at)),
            _ => None,
        })
    }

    /// The objects the level's map data places.
    pub fn objects(&self) -> impl Iterator<Item = (ObjectId, Local)> + '_ {
        self.presets.iter().filter_map(|u| match u.what {
            Preset::Object(id) => Some((id, u.at)),
            _ => None,
        })
    }

    /// The seeded outdoor shrines and wells, in world subtiles.
    ///
    /// These are part of [`presets`](Self::presets) already, so this costs nothing beyond a
    /// filter. It is the same set [`Generator::shrines`](super::Generator::shrines) returns,
    /// without needing the seed and difficulty again or regenerating the act to find out.
    pub fn shrines(&self) -> impl Iterator<Item = Shrine> + '_ {
        self.presets.iter().filter_map(|u| match u.what {
            Preset::Object(id) if SHRINE_CLASSES.contains(&id.0) => {
                Some(Shrine { id, at: self.world(u.at) })
            }
            _ => None,
        })
    }

    /// The warps the level's map data places.
    pub fn exits(&self) -> impl Iterator<Item = (WarpId, Local)> + '_ {
        self.presets.iter().filter_map(|u| match u.what {
            Preset::Exit(id) => Some((id, u.at)),
            _ => None,
        })
    }

    /// Every crossing into one particular level.
    pub fn crossings_to(&self, to: LevelId) -> impl Iterator<Item = Local> + '_ {
        self.adjacents.iter().filter(move |a| a.to == to).map(|a| a.at)
    }

    /// The levels this one leads to, each once, in ascending order.
    pub fn destinations(&self) -> Vec<LevelId> {
        let mut ids: Vec<LevelId> = self.adjacents.iter().map(|a| a.to).collect();
        ids.sort_unstable();
        ids.dedup();
        ids
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (level {}, {} rooms)", self.name, self.id, self.rooms.len())
    }
}

/// A generated act: every level of it, for one seed and difficulty.
///
/// Plain owned data. Nothing native is still alive by the time you hold one, so it can be
/// moved between threads, shared behind an [`std::sync::Arc`], cached or serialised freely.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Act {
    /// The seed it was generated from.
    pub seed: u32,
    /// The difficulty it was generated for.
    pub difficulty: Difficulty,
    /// Which act, counting from zero the way the engine does: 0 is Act I, 4 is Act V.
    pub act: u8,
    /// Every level of the act, in the engine's own order.
    pub levels: Vec<Level>,
}

impl Act {
    /// The level with this id.
    pub fn level(&self, id: impl Into<LevelId>) -> Option<&Level> {
        let id = id.into();
        self.levels.iter().find(|l| l.id == id)
    }

    /// The level with this id, mutably.
    pub fn level_mut(&mut self, id: impl Into<LevelId>) -> Option<&mut Level> {
        let id = id.into();
        self.levels.iter_mut().find(|l| l.id == id)
    }

    /// The level containing a world position, if any.
    pub fn level_at(&self, at: Subtile) -> Option<&Level> {
        self.levels.iter().find(|l| l.contains(at))
    }
}

impl fmt::Display for Act {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Act {} of seed {} ({} levels)", self.act as u32 + 1, self.seed, self.levels.len())
    }
}

impl<'a> IntoIterator for &'a Act {
    type Item = &'a Level;
    type IntoIter = std::slice::Iter<'a, Level>;

    fn into_iter(self) -> Self::IntoIter {
        self.levels.iter()
    }
}

impl IntoIterator for Act {
    type Item = Level;
    type IntoIter = std::vec::IntoIter<Level>;

    fn into_iter(self) -> Self::IntoIter {
        self.levels.into_iter()
    }
}
