//! Clean-room Diablo II 1.14d engine core.
//!
//! Give it a seed and it produces the same world the game does: rooms, objects, monsters,
//! level adjacency and subtile collision, for every level of all five acts. No game
//! installation is involved and nothing is read from disk; the tables are compiled in.
//!
//! ```no_run
//! use libd2::drlg::{Difficulty, Generator};
//!
//! # fn main() -> Result<(), libd2::Error> {
//! // One generator, reused. Loading the game tables is the expensive part.
//! let drlg = Generator::new()?;
//!
//! // act counts from zero the way the engine does: 0 is Act I, 4 is Act V.
//! let act = drlg.act(1337, 0).difficulty(Difficulty::Normal).generate()?;
//! println!("{act}");
//!
//! for level in act.levels.iter().take(3) {
//!     println!("  {level}  kind={:?} size={}", level.kind, level.size);
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ```text
//! Act 1 of seed 1337 (39 levels)
//!   Rogue Encampment (level 1, 35 rooms)  kind=Preset size=56x40
//!   Blood Moor (level 2, 83 rooms)  kind=Wilderness size=96x56
//!   Cold Plains (level 3, 97 rooms)  kind=Wilderness size=80x80
//! ```
//!
//! # Coordinates have types
//!
//! The engine works in three different frames, and mixing them is the easiest mistake to
//! make against this data. So each is its own type: [`Tile`] is a world position in tiles,
//! [`Subtile`] is a world position in subtiles (five to a tile, the frame in-game
//! coordinates use), and [`Local`] is a position in one level's own frame, which is what the
//! level's map data is authored in. Converting is explicit and only [`Level`] can do the
//! part that needs to know where the level sits:
//!
//! ```no_run
//! # use libd2::drlg::Generator;
//! # fn main() -> Result<(), libd2::Error> {
//! # let act = Generator::new()?.act(1337, 0).generate()?;
//! let cold_plains = act.level(3).unwrap();
//!
//! for (object, at) in cold_plains.objects() {
//!     println!("{} at {} in the level, {} in the world", object.name(), at, cold_plains.world(at));
//! }
//! # Ok(())
//! # }
//! ```
//!
//! # Ids have types
//!
//! For the same reason, a preset unit carries its id inside its variant, so an Objects.txt
//! row cannot be read as a MonStats id:
//!
//! ```
//! # use libd2::drlg::{Preset, PresetUnit};
//! # fn describe(unit: &PresetUnit) -> String {
//! match unit.what {
//!     Preset::Monster(id) => format!("monster {id}"),
//!     Preset::Object(id) => id.name(),
//!     Preset::Exit(id) => format!("warp {id}"),
//!     Preset::Other { etype, txt_file_no } => format!("etype {etype} row {txt_file_no}"),
//! }
//! # }
//! ```
//!
//! # Threading
//!
//! [`drlg::Generator`] is `Send` but not `Sync`: it can be moved to another thread, and the
//! compiler will stop you sharing one, because the engine keeps per-generation state that
//! two concurrent calls would trample. One generator per thread is the supported shape.
//!
//! What comes back out is different. An [`drlg::Act`] is plain owned data with no lifetimes
//! and nothing native still alive, so it is `Send + Sync` and can be moved, shared behind an
//! `Arc`, cached or serialised without further thought:
//!
//! ```
//! # use libd2::drlg::Act;
//! fn assert_send_sync<T: Send + Sync>() {}
//! assert_send_sync::<Act>();
//! ```
//!
//! # Features
//!
//! - `serde` derives `Serialize` and `Deserialize` for every value type.
//!
//! # Building
//!
//! The engine is Zig, built from source by this crate's build script and linked statically,
//! so `zig` 0.16+ must be on PATH to build. Nothing is needed at run time.

#![warn(missing_docs)]

pub mod drlg;

#[doc(inline)]
pub use drlg::{Level, Local, Subtile, Tile};

use std::ffi::c_char;
use std::fmt;

/// What can go wrong. Everything else in the crate is infallible.
#[derive(Clone, PartialEq, Eq, Debug)]
#[non_exhaustive]
pub enum Error {
    /// The engine could not load its tables. It has no configuration and reads no files, so
    /// in practice this means allocation failed.
    Unavailable,
    /// The linked native library speaks a different ABI than this crate was written
    /// against, which means the two came from different revisions.
    AbiMismatch {
        /// What this crate expects.
        expected: u32,
        /// What the linked library reports.
        found: u32,
    },
    /// Generation failed for this seed and act.
    Generate {
        /// The seed asked for.
        seed: u32,
        /// The 0-based act asked for.
        act: u8,
    },
    /// This level has no collision grid.
    NoCollision {
        /// The level asked for.
        level: i32,
    },
    /// A native call reported an error code.
    Native {
        /// Which entry point.
        call: &'static str,
        /// The code it returned.
        code: i32,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Unavailable => f.write_str("libd2: the engine could not load its tables"),
            Error::AbiMismatch { expected, found } => {
                write!(f, "libd2: the native library speaks ABI {found}, this crate speaks {expected}")
            }
            Error::Generate { seed, act } => {
                write!(f, "libd2: could not generate act {act} of seed {seed}")
            }
            Error::NoCollision { level } => write!(f, "libd2: level {level} has no collision grid"),
            Error::Native { call, code } => write!(f, "libd2: {call} failed with code {code}"),
        }
    }
}

impl std::error::Error for Error {}

/// Shorthand for a result carrying this crate's [`Error`].
pub type Result<T> = std::result::Result<T, Error>;

/// Read a counted list out of the C ABI, whose list calls all report the full count and
/// truncate to the capacity they were given. `hint` sizes the first attempt; a second only
/// happens when the first was too small.
///
/// A hint of 0 asks for the count first and then allocates exactly that, which is what the
/// act accessors want: the counting call is a bounds check returning a length, so guessing a
/// capacity buys nothing and leaves most of it unused. Guess only where the counting call is
/// itself expensive.
pub(crate) fn collect<T>(
    call: &'static str,
    hint: usize,
    mut probe: impl FnMut(*mut T, i32) -> i32,
) -> Result<Vec<T>> {
    let mut buf: Vec<T> = Vec::with_capacity(hint);
    let full = probe(buf.as_mut_ptr(), hint as i32);
    if full < 0 {
        return Err(Error::Native { call, code: full });
    }
    let full = full as usize;

    if full <= hint {
        // SAFETY: the call wrote `full` elements, which fit in the capacity it was given.
        unsafe { buf.set_len(full) };
        return Ok(buf);
    }

    buf.reserve_exact(full);
    let wrote = probe(buf.as_mut_ptr(), full as i32);
    if wrote < 0 {
        return Err(Error::Native { call, code: wrote });
    }
    // SAFETY: capacity is now `full`, and the call wrote min(wrote, full) elements.
    unsafe { buf.set_len(full.min(wrote as usize)) };
    Ok(buf)
}

/// Read a counted string out of the C ABI, which reports the full byte length the same way.
pub(crate) fn text(mut probe: impl FnMut(*mut c_char, i32) -> i32) -> String {
    let mut buf = vec![0u8; 128];
    let mut len = probe(buf.as_mut_ptr().cast::<c_char>(), buf.len() as i32);
    if len > buf.len() as i32 {
        buf = vec![0u8; len as usize + 1];
        len = probe(buf.as_mut_ptr().cast::<c_char>(), buf.len() as i32);
    }
    if len <= 0 {
        return String::new();
    }
    buf.truncate(len as usize);
    String::from_utf8_lossy(&buf).into_owned()
}
