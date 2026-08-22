//! The pre-1.09 `.d2s` header — the 0x82-byte block written by 1.00 through 1.08.
//!
//! Diablo II changed its save header once, and the engine says exactly where: 1.14d's
//! `SERVER_LoadPlayerFromSaveFile` (Game.exe 0x00534330) dispatches on
//!
//!     if (pSavefile->dwFileVersion < 0x5c) -> SEVER_loadFrom_Old_Savegame
//!                                        else -> PLAYERSAVE_LoadModernFormat
//!
//! so `0x5c` is the boundary, not a guess and not an era name. 1.09 (0x5c) already writes the
//! modern layout and differs from 1.10+ only in the number in the version field.
//!
//! Every offset below is read off `_oldSaveGameLoadingPart` (Game.exe 0x00532690), which copies
//! 0x82 bytes to a stack local and then reads it field by field; the offsets are that function's
//! own stack layout, relative to the start of the copy. Cross-checked against saves written by
//! real 1.06b, 1.07 and 1.08 engines.
//!
//! Two consequences of the layout are worth stating outright, because both look like bugs:
//!
//!   * There is NO CHECKSUM. `name[16]` runs 0x08..0x18, so it covers the offset the modern header
//!     keeps its checksum at. An old save is not checksummed and must not have one written into it.
//!   * `nTxtSkillsCount` at 0x1c is the number of rows Skills.txt had when the save was written —
//!     221 on classic 1.06b, 319 on the 1.07/1.08 expansion. The engine refuses a save claiming
//!     more skills than its own table has, which is why the number is version-specific rather than
//!     arbitrary.

const std = @import("std");

/// The whole header. The engine checks this exact value at 0x20 and refuses anything else.
pub const header_size: usize = 0x82;
pub const signature: u32 = 0xaa55aa55;

/// The first version the modern layout appears in. From the engine's own dispatcher.
pub const first_modern_version: u32 = 0x5c;

/// The oldest version 1.14d will still load. `_oldSaveGameLoadingPart` rejects anything outside
/// `0x47..=0x60` outright, so this is the real floor rather than the oldest one documented.
pub const oldest_loadable_version: u32 = 0x47;

/// Which header layout a `.d2s` uses. The only thing the version number decides on its own.
pub const Era = enum { old, modern };

pub fn era(version: u32) Era {
    return if (version < first_modern_version) .old else .modern;
}

/// Whether 1.14d would load this at all. Outside the range it returns error 9 without looking at
/// anything else, so a reader that accepts more than this accepts saves the game never would.
pub fn loadable(version: u32) bool {
    return version >= oldest_loadable_version and version <= 0x60;
}

/// Offsets inside the 0x82 header, from `_oldSaveGameLoadingPart`'s stack frame.
pub const off_signature = 0x00;
pub const off_version = 0x04;
pub const off_name = 0x08; // char[16] — covers 0x0c, hence no checksum
pub const off_flags = 0x18; // u32
pub const off_txt_skills = 0x1c; // u16
pub const off_skill_tabs = 0x1e; // u16
pub const off_header_size = 0x20; // u16, always 0x82
pub const off_class = 0x22; // u16
pub const off_hotkeys = 0x46; // u8[16] — eight (skill, page) pairs
pub const off_left_hotkey = 0x56;
pub const off_right_hotkey = 0x57;
pub const off_difficulty = 0x58; // low nibble act, high nibble difficulty
pub const off_init_seed = 0x79;

/// Status bits in the u32 at 0x18. The low byte is what the modern header keeps at 0x24 and the
/// next five bits are its `progression` at 0x25 — which is what makes the two convertible.
pub const flag_bnet = 0x0001;
pub const flag_hardcore = 0x0004;
pub const flag_died = 0x0008;
pub const flag_expansion = 0x0020;
pub const flag_weapon_swap = 0x2000; // bit 13, read as (flags >> 0xd) & 1

/// Decoded 0x82-byte header. Unnamed runs are kept verbatim so `write` reproduces the source
/// bytes exactly — a save this cannot round-trip is a save we do not understand well enough to
/// hand back to the game.
pub const Header = struct {
    signature: u32 = signature,
    version: u32 = 0,
    name: [16]u8 = @splat(0),
    flags: u32 = 0,
    txt_skills_count: u16 = 0,
    skill_tab_count: u16 = 0,
    /// Always 0x82; kept as a field because the engine compares it and a wrong one is a refusal.
    header_size_field: u16 = @intCast(header_size),
    class: u16 = 0,
    unk_0x24: [0x22]u8 = @splat(0),
    hotkeys: [16]u8 = @splat(0),
    left_hotkey: u8 = 0,
    right_hotkey: u8 = 0,
    /// `act | difficulty << 4`. The engine refuses act > 4 or difficulty > 2.
    difficulty: u8 = 0,
    /// 0x59..0x79 — guild flags, tag, name and info. Carried whole: the sub-fields are read
    /// individually by the engine but nothing here needs them apart, and splitting a region on a
    /// decompiler's array sizing is how a round trip stops being byte-exact.
    guild: [0x20]u8 = @splat(0),
    init_seed: u8 = 0,
    unk_0x7a: [8]u8 = @splat(0),

    pub fn nameSlice(self: *const Header) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn hardcore(self: *const Header) bool {
        return self.flags & flag_hardcore != 0;
    }
    pub fn died(self: *const Header) bool {
        return self.flags & flag_died != 0;
    }
    pub fn expansion(self: *const Header) bool {
        return self.flags & flag_expansion != 0;
    }
    pub fn weaponSwap(self: *const Header) bool {
        return self.flags & flag_weapon_swap != 0;
    }
    /// Difficulty completion, `wCharFlags >> 8 & 0x1f` — the modern header's `progression`.
    pub fn progression(self: *const Header) u8 {
        return @truncate((self.flags >> 8) & 0x1f);
    }
    pub fn act(self: *const Header) u8 {
        return self.difficulty & 0x0f;
    }
    pub fn difficultyLevel(self: *const Header) u8 {
        return self.difficulty >> 4;
    }
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

/// Decode the header from the front of an old `.d2s`. Null when the buffer is too short. Does not
/// validate — use `validate` for that, so a caller can inspect a save the game would reject.
pub fn parse(data: []const u8) ?Header {
    if (data.len < header_size) return null;
    var h = Header{
        .signature = rd32(data, off_signature),
        .version = rd32(data, off_version),
        .flags = rd32(data, off_flags),
        .txt_skills_count = rd16(data, off_txt_skills),
        .skill_tab_count = rd16(data, off_skill_tabs),
        .header_size_field = rd16(data, off_header_size),
        .class = rd16(data, off_class),
        .left_hotkey = data[off_left_hotkey],
        .right_hotkey = data[off_right_hotkey],
        .difficulty = data[off_difficulty],
        .init_seed = data[off_init_seed],
    };
    @memcpy(&h.name, data[off_name..][0..16]);
    @memcpy(&h.unk_0x24, data[0x24..0x46]);
    @memcpy(&h.hotkeys, data[off_hotkeys..][0..16]);
    @memcpy(&h.guild, data[0x59..0x79]);
    @memcpy(&h.unk_0x7a, data[0x7a..0x82]);
    return h;
}

pub fn write(h: *const Header, out: *[header_size]u8) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[off_signature..][0..4], h.signature, .little);
    std.mem.writeInt(u32, out[off_version..][0..4], h.version, .little);
    @memcpy(out[off_name..][0..16], &h.name);
    std.mem.writeInt(u32, out[off_flags..][0..4], h.flags, .little);
    std.mem.writeInt(u16, out[off_txt_skills..][0..2], h.txt_skills_count, .little);
    std.mem.writeInt(u16, out[off_skill_tabs..][0..2], h.skill_tab_count, .little);
    std.mem.writeInt(u16, out[off_header_size..][0..2], h.header_size_field, .little);
    std.mem.writeInt(u16, out[off_class..][0..2], h.class, .little);
    @memcpy(out[0x24..0x46], &h.unk_0x24);
    @memcpy(out[off_hotkeys..][0..16], &h.hotkeys);
    out[off_left_hotkey] = h.left_hotkey;
    out[off_right_hotkey] = h.right_hotkey;
    out[off_difficulty] = h.difficulty;
    @memcpy(out[0x59..0x79], &h.guild);
    out[off_init_seed] = h.init_seed;
    @memcpy(out[0x7a..0x82], &h.unk_0x7a);
}

/// What `_oldSaveGameLoadingPart` checks before it will build a unit, in the order it checks it.
/// Everything here is a refusal in the engine, so a save failing any of it is one the game will
/// not load however well-formed it looks.
pub fn validate(data: []const u8) bool {
    const h = parse(data) orelse return false;
    if (h.signature != signature) return false;
    if (h.header_size_field != header_size) return false;
    if (!loadable(h.version)) return false;
    if (h.skill_tab_count > 0x10) return false;
    if (h.act() > 4) return false;
    if (h.difficultyLevel() > 2) return false;
    return true;
}
