//! COF (Component Object Format) parser — the per-mode layout that ties a unit's
//! token+mode+weaponclass to its per-layer DCC/DC6 files, draw order and frame
//! count. Faithful port of OpenDiablo2 d2common/d2fileformats/d2cof/cof.go.
//!
//! Layout (all little-endian bytes):
//!   header  25 bytes: [0]=layers [1]=framesPerDir [2]=directions [3..24]=unknown [24]=speed
//!   body     3 unknown bytes
//!   layers   layers*9 bytes: [0]=CompositeType [1]=shadow [2]=selectable [3]=transparent
//!                            [4]=drawEffect [5..8]=weaponClass (4 chars, NUL-padded)
//!   animFrames  framesPerDir bytes
//!   priority    directions*framesPerDir*layers bytes (draw order = CompositeType per slot)

const std = @import("std");

/// CompositeType -> 2-letter component directory code. Index is the COF layer's
/// first byte. Order per OD2 d2enum.CompositeType (HD,TR,LG,RA,LA,RH,LH,SH,S1..S8).
pub const COMPONENT_CODES = [16][]const u8{
    "HD", "TR", "LG", "RA", "LA", "RH", "LH", "SH",
    "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8",
};

pub const Layer = struct {
    /// CompositeType (0..15). Index into COMPONENT_CODES for the dir/file name.
    component: u8,
    shadow: u8,
    selectable: bool,
    transparent: bool,
    draw_effect: u8,
    /// 3-char weapon class, e.g. "HTH", "1HS". NUL/space trimmed.
    weapon_class: [4]u8,
    weapon_class_len: u8,

    pub fn wclass(self: *const Layer) []const u8 {
        return self.weapon_class[0..self.weapon_class_len];
    }
    pub fn compCode(self: *const Layer) []const u8 {
        return if (self.component < 16) COMPONENT_CODES[self.component] else "??";
    }
};

pub const Cof = struct {
    num_layers: u8,
    frames_per_dir: u8,
    num_directions: u8,
    speed: u8,
    layers: []Layer,
    /// priority[dir][frame][slot] = CompositeType, back-to-front draw order.
    priority: []u8, // flat: dir*framesPerDir*numLayers + frame*numLayers + slot
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cof) void {
        self.allocator.free(self.layers);
        self.allocator.free(self.priority);
    }

    /// Draw-order slice of CompositeTypes for a given dir/frame.
    pub fn drawOrder(self: *const Cof, dir: usize, frame: usize) []const u8 {
        const nl = self.num_layers;
        const base = (dir * self.frames_per_dir + frame) * nl;
        return self.priority[base .. base + nl];
    }
};

const HEADER_BYTES = 25;
const BODY_BYTES = 3;
const LAYER_BYTES = 9;

pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Cof {
    if (bytes.len < HEADER_BYTES + BODY_BYTES) return error.InvalidCof;
    const num_layers = bytes[0];
    const frames_per_dir = bytes[1];
    const num_directions = bytes[2];
    const speed = bytes[24];

    if (num_layers == 0 or frames_per_dir == 0 or num_directions == 0) return error.InvalidCof;

    var off: usize = HEADER_BYTES + BODY_BYTES;

    const layers = try alloc.alloc(Layer, num_layers);
    errdefer alloc.free(layers);
    for (layers) |*l| {
        if (off + LAYER_BYTES > bytes.len) return error.InvalidCof;
        const b = bytes[off .. off + LAYER_BYTES];
        var wc: [4]u8 = .{ 0, 0, 0, 0 };
        var wlen: u8 = 0;
        for (b[5..9]) |ch| {
            if (ch == 0 or ch == ' ') continue;
            wc[wlen] = ch;
            wlen += 1;
        }
        l.* = .{
            .component = b[0],
            .shadow = b[1],
            .selectable = b[2] > 0,
            .transparent = b[3] > 0,
            .draw_effect = b[4],
            .weapon_class = wc,
            .weapon_class_len = wlen,
        };
        off += LAYER_BYTES;
    }

    // Animation frames (skipped; not needed for a static composite).
    off += frames_per_dir;

    const prio_len = @as(usize, num_directions) * frames_per_dir * num_layers;
    if (off + prio_len > bytes.len) return error.InvalidCof;
    const priority = try alloc.dupe(u8, bytes[off .. off + prio_len]);

    return .{
        .num_layers = num_layers,
        .frames_per_dir = frames_per_dir,
        .num_directions = num_directions,
        .speed = speed,
        .layers = layers,
        .priority = priority,
        .allocator = alloc,
    };
}
