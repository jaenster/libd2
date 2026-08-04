//! Raw declarations for the `d2drlg` C ABI. Everything here is private to the crate: the
//! public surface deals in owned Rust values and never in pointers.

use std::os::raw::{c_char, c_int, c_uint};

#[repr(C)]
pub struct Ctx {
    _private: [u8; 0],
}

#[repr(C)]
pub struct ActHandle {
    _private: [u8; 0],
}

/// The ABI this binding was written against; checked once when a generator is created.
pub const EXPECTED_ABI: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RawRoom {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub n_type: i32,
    pub n_preset_type: i32,
    pub picked_file: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RawPreset {
    pub etype: i32,
    pub txt_file_no: i32,
    pub x: i32,
    pub y: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RawAdjacent {
    pub dest_level_id: i32,
    pub bridge_x: i32,
    pub bridge_y: i32,
}

extern "C" {
    pub fn d2drlg_ctx_create() -> *mut Ctx;
    pub fn d2drlg_ctx_destroy(ctx: *mut Ctx);
    pub fn d2drlg_gen_act(ctx: *mut Ctx, seed: c_uint, difficulty: c_int, act_no: c_int) -> *mut ActHandle;
    pub fn d2drlg_act_free(act: *mut ActHandle);
    pub fn d2drlg_act_level_count(act: *mut ActHandle) -> c_int;
    pub fn d2drlg_act_level_id(act: *mut ActHandle, index: c_int) -> c_int;
    pub fn d2drlg_act_level_drlg_type(act: *mut ActHandle, index: c_int) -> c_int;
    pub fn d2drlg_act_level_placed(act: *mut ActHandle, index: c_int) -> c_int;
    pub fn d2drlg_act_level_origin(act: *mut ActHandle, index: c_int, ox: *mut c_int, oy: *mut c_int) -> c_int;
    pub fn d2drlg_act_level_size(act: *mut ActHandle, index: c_int, w: *mut c_int, h: *mut c_int) -> c_int;
    pub fn d2drlg_act_rooms(act: *mut ActHandle, index: c_int, out: *mut RawRoom, cap: c_int) -> c_int;
    pub fn d2drlg_act_level_presets(act: *mut ActHandle, index: c_int, out: *mut RawPreset, cap: c_int) -> c_int;
    pub fn d2drlg_act_level_adjacents(act: *mut ActHandle, index: c_int, out: *mut RawAdjacent, cap: c_int) -> c_int;
    pub fn d2drlg_act_level_collision(act: *mut ActHandle, index: c_int, out: *mut u16, cap: c_int, w: *mut c_int, h: *mut c_int) -> c_int;
    pub fn d2drlg_level_collision_raw(ctx: *mut Ctx, seed: c_uint, difficulty: c_int, level_id: c_int, out: *mut u16, cap: c_int, w: *mut c_int, h: *mut c_int) -> c_int;
    pub fn d2drlg_level_name(ctx: *mut Ctx, level_id: c_int, buf: *mut c_char, cap: c_int) -> c_int;
    pub fn d2drlg_object_name(txt_file_no: c_int, buf: *mut c_char, cap: c_int) -> c_int;
    pub fn d2drlg_abi_version() -> c_uint;
}
