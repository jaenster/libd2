//! Forward-dependency stubs for the DRLG core transform.
//!
//! Anything the DRLG core files call that is NOT itself part of the core lives
//! here as a stub with the recon signature: the generators (Maze/Outdoors/Preset/...),
//! the top-level (Drlg/Dungeon), and a few opaque cross-module externals
//! (Fog::ErrorManager). Each stub panics or returns a benign default. Replace
//! with the real transform when its owning module lands.
//!
//! Pointer convention matches the rest of the DRLG core: C pointers `[*c]T`,
//! BOOL/eEnum -> i32, byte -> u8, char* -> [*c]u8, void* -> ?*anyopaque.

// generators / top-level (owner file noted)

// DRLGOUTDOOR_ApplySubstitutionGroup is now transformed in outdoors/OutSub.zig
// (faithful) and called directly by TileSub::AddSecondaryBorder.

// Table accessors not ported (owner: DataTbls/ObjectTbls)

/// Minimal Objects.txt row — only the fields the DRLG closure reads (SubClass
/// bit 0x40 = waypoint). Full row is an ObjectTbls concern.
pub const D2ObjectsTxt = extern struct {
    SubClass: i32,
};

/// DataTbls::ObjectTbls::TXT_Objects_GetLine — OWNER: ObjectTbls
pub fn objectsGetLine(nClassId: i32) [*c]D2ObjectsTxt {
    _ = nClassId;
    @panic("objectsGetLine: Phase-2 stub (Objects.txt not ported)");
}

/// DataTbls::LvlTbls::TXT_LvlWarp_Setup — OWNER: LvlTbls (loads warp
/// tile data into the table; no effect on geometry seeds).
pub fn lvlWarpSetup(nWarpId: i32, nDirection: u8) void {
    _ = .{ nWarpId, nDirection };
    // no-op stub
}

test "forward stubs resolve" {
    _ = lvlWarpSetup;
}
