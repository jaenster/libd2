//! Character persistence PORT. The game logic (join/leave) needs to load and save a character's
//! state and, in the real-.d2s test mode, its geared attributes — but it must not touch the disk
//! (the wasm/libc-free mandate). The host implements this interface with file I/O; the domain calls
//! it in its own terms (load a char, save a char), never "read a file".

const std = @import("std");
const character = @import("character.zig");

/// A real character's decoded stats (from a `.d2s` via the host's `D2GS_CHAR` test mode). All fields
/// are game-native; `has_attrs`/`has_gear` say which halves were decoded (0 = absent).
pub const RealChar = struct {
    level: i32 = 0,
    strength: i32 = 0,
    dexterity: i32 = 0,
    vitality: i32 = 0,
    energy: i32 = 0,
    maxhp: i32 = 0,
    maxmana: i32 = 0,
    fire: i32 = 0,
    cold: i32 = 0,
    light: i32 = 0,
    poison: i32 = 0,
    defense: i32 = 0,
    allskills: i32 = 0,
    classskills: i32 = 0,
    has_attrs: bool = false,
    has_gear: bool = false,
};

/// The persistence port the host provides. Vtable-based so the runtime game holds one `CharStore`
/// and calls through it; the host struct behind `ptr` owns the disk layout + save format.
pub const CharStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Load a character's persisted state (`.d2s` header + sidecar), or null on first play.
        load: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, account: []const u8, charname: []const u8) ?character.CharSave,
        /// Persist a character's state.
        save: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, account: []const u8, charname: []const u8, csv: character.CharSave) void,
        /// Decode the `D2GS_CHAR` real character (test mode), or an all-absent RealChar when unset.
        realChar: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) RealChar,
    };

    pub fn load(self: CharStore, gpa: std.mem.Allocator, account: []const u8, charname: []const u8) ?character.CharSave {
        return self.vtable.load(self.ptr, gpa, account, charname);
    }
    pub fn saveChar(self: CharStore, gpa: std.mem.Allocator, account: []const u8, charname: []const u8, csv: character.CharSave) void {
        self.vtable.save(self.ptr, gpa, account, charname, csv);
    }
    pub fn realChar(self: CharStore, gpa: std.mem.Allocator) RealChar {
        return self.vtable.realChar(self.ptr, gpa);
    }
};
