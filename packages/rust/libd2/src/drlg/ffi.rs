//! The `d2drlg` C ABI as this module uses it: the generated declarations (`crate::sys::d2drlg`)
//! under the names the safe wrapper was written with.

#![allow(dead_code)]

pub use crate::sys::d2drlg::*;

pub type Ctx = D2DrlgCtx;
pub type ActHandle = D2DrlgAct;
pub type RawRoom = D2DrlgRoom;
pub type RawPreset = D2DrlgPreset;
pub type RawAdjacent = D2DrlgAdjacent;
