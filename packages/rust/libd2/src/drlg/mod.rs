//! Map generation: rooms, objects, monsters, level adjacency and subtile collision.
//!
//! There are two ways to hold a generated act, and the difference is who owns the native
//! memory.
//!
//! [`ActRequest::generate`] copies everything out and frees the native act before it
//! returns, so you get an [`Act`] of plain owned data: no lifetimes, `Send + Sync`, and
//! nothing left to release. That is the default and almost always what you want.
//!
//! Collision grids are not part of either, because a whole act of them is tens of megabytes
//! and almost nobody wants all of it. They are their own call: [`Generator::collision`] from
//! a seed, or [`LevelRef::collision`] when an act is already open.
//!
//! [`ActRequest::open`] hands back an [`ActRef`] that still owns the native act. Nothing is
//! copied until you ask for it, and the act is freed when the ref is dropped. The borrow
//! checker keeps that honest: an [`ActRef`] borrows the [`Generator`], a [`LevelRef`]
//! borrows the [`ActRef`], and neither can outlive what it reads from.

mod ffi;
mod model;

pub use model::{
    Act, Adjacent, Collision, CollisionGrid, Difficulty, Level, LevelId, LevelKind, Local,
    MonsterId, ObjectId, Preset, PresetUnit, Room, Shrine, Size, Subtile, Tile, UnknownDifficulty,
    WarpId, SUBTILES,
};

use crate::{collect, text, Error, Result};
use std::fmt;
use std::marker::PhantomData;
use std::ptr::NonNull;

/// The loaded game tables, and the only thing in the crate owning anything native.
///
/// Creating one loads every table generation needs, so make one and keep it. Dropping it
/// releases the native side, and the borrow checker will not let you drop it while an
/// [`ActRef`] is still open on it.
///
/// # Threading
///
/// `Generator` is `Send` but deliberately not `Sync`: it can be moved to another thread, and
/// the compiler will stop you sharing one, because two concurrent generations would trample
/// the per-generation state this context owns. One generator per thread is the supported
/// shape, and it is what the project's own cross-seed verifier does.
pub struct Generator {
    ctx: NonNull<ffi::Ctx>,
}

// Sound because the engine wires its per-generation state on the calling thread at the start
// of every call, so a generator may move threads freely. The absence of a `Sync` impl is what
// keeps two threads from generating through one context at once.
unsafe impl Send for Generator {}

impl Generator {
    /// Load the game tables.
    pub fn new() -> Result<Self> {
        let found = unsafe { ffi::d2drlg_abi_version() };
        if found != ffi::EXPECTED_ABI {
            return Err(Error::AbiMismatch { expected: ffi::EXPECTED_ABI, found });
        }
        let ctx = NonNull::new(unsafe { ffi::d2drlg_ctx_create() }).ok_or(Error::Unavailable)?;
        Ok(Self { ctx })
    }

    /// Describe an act to generate. Nothing happens until you call
    /// [`generate`](ActRequest::generate) or [`open`](ActRequest::open).
    ///
    /// `act` counts from zero the way the engine does: 0 is Act I, 4 is Act V.
    ///
    /// ```no_run
    /// # use libd2::drlg::{Difficulty, Generator};
    /// # fn main() -> Result<(), libd2::Error> {
    /// # let drlg = Generator::new()?;
    /// let act = drlg.act(1337, 2).difficulty(Difficulty::Hell).generate()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn act(&self, seed: u32, act: u8) -> ActRequest<'_> {
        ActRequest { drlg: self, seed, act, difficulty: Difficulty::Normal }
    }

    /// The in-game name of a level, or an empty string for an id that has none.
    pub fn level_name(&self, id: impl Into<LevelId>) -> String {
        let id = id.into();
        text(|buf, cap| unsafe { ffi::d2drlg_level_name(self.ctx.as_ptr(), id.0, buf, cap) })
    }

    /// A level's subtile collision grid.
    ///
    /// This generates the act internally, so when you want more than one level's worth,
    /// [`open`](ActRequest::open) the act once and use [`LevelRef::collision`] instead.
    pub fn collision(
        &self,
        seed: u32,
        difficulty: Difficulty,
        level: impl Into<LevelId>,
    ) -> Result<CollisionGrid> {
        let level = level.into();
        let (mut w, mut h) = (0, 0);
        // Hint 0: ask for the dimensions first, then allocate exactly one grid.
        let cells = collect("d2drlg_level_collision_raw", 0, |out: *mut Collision, cap| unsafe {
            ffi::d2drlg_level_collision_raw(
                self.ctx.as_ptr(),
                seed,
                difficulty as i32,
                level.0,
                out.cast::<u16>(),
                cap,
                &mut w,
                &mut h,
            )
        })?;
        if cells.is_empty() {
            return Err(Error::NoCollision { level: level.0 });
        }
        Ok(CollisionGrid::new(cells, w as usize, h as usize))
    }
}

impl Drop for Generator {
    fn drop(&mut self) {
        unsafe { ffi::d2drlg_ctx_destroy(self.ctx.as_ptr()) };
    }
}

impl fmt::Debug for Generator {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Generator")
    }
}

/// An act about to be generated, from [`Generator::act`].
#[derive(Debug)]
#[must_use = "an ActRequest only describes an act; call generate() or open() to produce one"]
pub struct ActRequest<'a> {
    drlg: &'a Generator,
    seed: u32,
    act: u8,
    difficulty: Difficulty,
}

impl<'a> ActRequest<'a> {
    /// Generate for this difficulty instead of Normal. Nine levels change size with it.
    pub fn difficulty(mut self, difficulty: Difficulty) -> Self {
        self.difficulty = difficulty;
        self
    }

    /// Generate the act and copy all of it out.
    ///
    /// The native act is freed before this returns, so the [`Act`] you get back owns
    /// everything it contains, carries no lifetime and outlives the generator that made it.
    pub fn generate(self) -> Result<Act> {
        self.open()?.to_act()
    }

    /// Generate the act and keep it native, reading out of it only what you ask for.
    ///
    /// The returned [`ActRef`] frees the act when it is dropped, and borrows the generator
    /// until then. Use this when you want one level out of an act, or want to decide what to
    /// read after looking at the act.
    ///
    /// ```no_run
    /// # use libd2::drlg::Generator;
    /// # fn main() -> Result<(), libd2::Error> {
    /// # let drlg = Generator::new()?;
    /// let act = drlg.act(1337, 0).open()?;
    /// let cold_plains = act.level(3).expect("Act I has Cold Plains");
    ///
    /// // Only this level's rooms are ever copied out.
    /// println!("{} rooms", cold_plains.rooms()?.len());
    /// # Ok(())
    /// # }   // the native act is freed here
    /// ```
    pub fn open(self) -> Result<ActRef<'a>> {
        let raw = unsafe {
            ffi::d2drlg_gen_act(
                self.drlg.ctx.as_ptr(),
                self.seed,
                self.difficulty as i32,
                self.act as i32,
            )
        };
        let handle = NonNull::new(raw).ok_or(Error::Generate { seed: self.seed, act: self.act })?;
        let act = ActRef {
            handle,
            drlg: self.drlg,
            seed: self.seed,
            act: self.act,
            difficulty: self.difficulty,
            _borrow: PhantomData,
        };

        let count = unsafe { ffi::d2drlg_act_level_count(handle.as_ptr()) };
        if count < 0 {
            // `act` drops here and frees the native handle.
            return Err(Error::Native { call: "d2drlg_act_level_count", code: count });
        }
        Ok(act)
    }
}

/// A generated act that is still native, from [`ActRequest::open`].
///
/// Owns the act and frees it on drop, so freeing is the borrow ending rather than a call you
/// have to remember. It borrows the [`Generator`] for as long as it lives, and every
/// [`LevelRef`] taken from it borrows it in turn, so nothing here can be read after the
/// memory behind it is gone.
///
/// Neither `Send` nor `Sync`: the act must be freed on the thread that generated it.
pub struct ActRef<'a> {
    handle: NonNull<ffi::ActHandle>,
    drlg: &'a Generator,
    seed: u32,
    act: u8,
    difficulty: Difficulty,
    _borrow: PhantomData<&'a Generator>,
}

impl Drop for ActRef<'_> {
    fn drop(&mut self) {
        unsafe { ffi::d2drlg_act_free(self.handle.as_ptr()) };
    }
}

impl<'a> ActRef<'a> {
    /// The seed it was generated from.
    pub fn seed(&self) -> u32 {
        self.seed
    }

    /// Which act, counting from zero: 0 is Act I, 4 is Act V.
    pub fn act(&self) -> u8 {
        self.act
    }

    /// The difficulty it was generated for.
    pub fn difficulty(&self) -> Difficulty {
        self.difficulty
    }

    /// How many levels the act has.
    pub fn len(&self) -> usize {
        unsafe { ffi::d2drlg_act_level_count(self.handle.as_ptr()) }.max(0) as usize
    }

    /// True when the act has no levels, which would mean generation produced nothing.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The level at this position in the act's own order.
    pub fn get(&self, index: usize) -> Option<LevelRef<'_>> {
        (index < self.len()).then_some(LevelRef { act: self, index: index as i32 })
    }

    /// Every level, in the act's own order.
    pub fn levels(&self) -> impl ExactSizeIterator<Item = LevelRef<'_>> + '_ {
        (0..self.len()).map(move |index| LevelRef { act: self, index: index as i32 })
    }

    /// The level with this id.
    pub fn level(&self, id: impl Into<LevelId>) -> Option<LevelRef<'_>> {
        let id = id.into();
        self.levels().find(|l| l.id() == id)
    }

    /// Copy the whole act out into owned data, freeing nothing: the [`ActRef`] stays usable
    /// and is still released when it drops.
    pub fn to_act(&self) -> Result<Act> {
        let levels = self.levels().map(|l| l.to_level()).collect::<Result<Vec<_>>>()?;
        Ok(Act { seed: self.seed, difficulty: self.difficulty, act: self.act, levels })
    }
}

impl fmt::Debug for ActRef<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ActRef")
            .field("seed", &self.seed)
            .field("act", &self.act)
            .field("difficulty", &self.difficulty)
            .field("levels", &self.len())
            .finish()
    }
}

/// One level of an [`ActRef`], read on demand.
///
/// Borrows the act it came from, so it cannot outlive the native memory it reads. The cheap
/// facts are plain accessors; the lists copy when called, and are the reason to hold a
/// `LevelRef` rather than a whole [`Act`].
#[derive(Clone, Copy)]
pub struct LevelRef<'a> {
    act: &'a ActRef<'a>,
    index: i32,
}

impl LevelRef<'_> {
    fn handle(&self) -> *mut ffi::ActHandle {
        self.act.handle.as_ptr()
    }

    /// Which level this is. Stable across seeds.
    pub fn id(&self) -> LevelId {
        LevelId(unsafe { ffi::d2drlg_act_level_id(self.handle(), self.index) })
    }

    /// The in-game name, for example `Cold Plains`.
    pub fn name(&self) -> String {
        self.act.drlg.level_name(self.id())
    }

    /// How the level is laid out.
    pub fn kind(&self) -> LevelKind {
        unsafe { ffi::d2drlg_act_level_drlg_type(self.handle(), self.index) }.into()
    }

    /// True when the act's placement graph positioned it on the surface, false for an
    /// interior reached through a warp.
    pub fn placed(&self) -> bool {
        (unsafe { ffi::d2drlg_act_level_placed(self.handle(), self.index) }) == 1
    }

    /// Where the level sits in the world, in tiles.
    pub fn origin(&self) -> Result<Tile> {
        let (mut x, mut y) = (0, 0);
        let code = unsafe { ffi::d2drlg_act_level_origin(self.handle(), self.index, &mut x, &mut y) };
        if code < 0 {
            return Err(Error::Native { call: "d2drlg_act_level_origin", code });
        }
        Ok(Tile::new(x, y))
    }

    /// How big the level is, in tiles.
    pub fn size(&self) -> Result<Size> {
        let (mut w, mut h) = (0, 0);
        let code = unsafe { ffi::d2drlg_act_level_size(self.handle(), self.index, &mut w, &mut h) };
        if code < 0 {
            return Err(Error::Native { call: "d2drlg_act_level_size", code });
        }
        Ok(Size { width: w, height: h })
    }

    /// The rooms the generator placed.
    pub fn rooms(&self) -> Result<Vec<Room>> {
        let (handle, index) = (self.handle(), self.index);
        Ok(collect("d2drlg_act_rooms", 0, |out, cap| unsafe {
            ffi::d2drlg_act_rooms(handle, index, out, cap)
        })?
        .into_iter()
        .map(|r| Room {
            origin: Tile::new(r.x, r.y),
            size: Size { width: r.w, height: r.h },
            kind: r.n_type,
            preset_type: r.n_preset_type,
            picked_file: r.picked_file,
        })
        .collect())
    }

    /// Monsters, objects and exits the level's own map data places.
    pub fn presets(&self) -> Result<Vec<PresetUnit>> {
        let (handle, index) = (self.handle(), self.index);
        Ok(collect("d2drlg_act_level_presets", 0, |out, cap| unsafe {
            ffi::d2drlg_act_level_presets(handle, index, out, cap)
        })?
        .into_iter()
        .map(|p| PresetUnit { what: Preset::new(p.etype, p.txt_file_no), at: Local::new(p.x, p.y) })
        .collect())
    }

    /// Where this level touches others.
    pub fn adjacents(&self) -> Result<Vec<Adjacent>> {
        let (handle, index) = (self.handle(), self.index);
        Ok(collect("d2drlg_act_level_adjacents", 0, |out, cap| unsafe {
            ffi::d2drlg_act_level_adjacents(handle, index, out, cap)
        })?
        .into_iter()
        .map(|a| Adjacent { to: LevelId(a.dest_level_id), at: Local::new(a.bridge_x, a.bridge_y) })
        .collect())
    }

    /// This level's subtile collision grid.
    ///
    /// A grid is a few hundred kilobytes, which is why it is a call of its own rather than
    /// part of every [`Level`].
    pub fn collision(&self) -> Result<CollisionGrid> {
        let (handle, index) = (self.handle(), self.index);
        let (mut w, mut h) = (0, 0);
        // Hint 0: ask for the dimensions first, then allocate exactly one grid.
        let cells = collect("d2drlg_act_level_collision", 0, |out: *mut Collision, cap| unsafe {
            ffi::d2drlg_act_level_collision(handle, index, out.cast::<u16>(), cap, &mut w, &mut h)
        })?;
        if cells.is_empty() {
            return Err(Error::NoCollision { level: self.id().0 });
        }
        Ok(CollisionGrid::new(cells, w as usize, h as usize))
    }

    /// Copy this level out into owned data.
    pub fn to_level(&self) -> Result<Level> {
        Ok(Level {
            id: self.id(),
            name: self.name(),
            kind: self.kind(),
            placed: self.placed(),
            origin: self.origin()?,
            size: self.size()?,
            rooms: self.rooms()?,
            presets: self.presets()?,
            adjacents: self.adjacents()?,
        })
    }
}

impl fmt::Debug for LevelRef<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LevelRef").field("id", &self.id()).field("name", &self.name()).finish()
    }
}

impl fmt::Display for LevelRef<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (level {})", self.name(), self.id())
    }
}

/// The Objects.txt name of an object, for example `Waypoint`.
///
/// The object table is static, so this needs no [`Generator`].
pub fn object_name(id: impl Into<ObjectId>) -> String {
    let id = id.into();
    text(|buf, cap| unsafe { ffi::d2drlg_object_name(id.0, buf, cap) })
}

/// The ABI version of the linked native library.
pub fn abi_version() -> u32 {
    unsafe { ffi::d2drlg_abi_version() }
}
