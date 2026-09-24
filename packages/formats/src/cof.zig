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
    /// The four weapon-class bytes exactly as stored, padding included, for `encode`.
    weapon_class_raw: [4]u8 = .{ 0, 0, 0, 0 },
    /// The selectable and transparent bytes as stored; `encode` writes them when they still agree with the flags.
    flag_bytes: [2]u8 = .{ 0, 0 },

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
    /// Per-frame animation event bytes (0 none, 1 attack, 2 missile, 3 sound, 4 skill), framesPerDir long.
    anim_frames: []u8 = &.{},
    /// The header and body bytes the parser does not interpret (offsets 3..24 and 25..27), kept for `encode`.
    reserved: [RESERVED_BYTES]u8 = @splat(0),
    /// Whatever follows the priority table. Empty in every retail file seen; carried so a round trip is exact.
    trailer: []u8 = &.{},

    pub fn deinit(self: *Cof) void {
        self.allocator.free(self.layers);
        self.allocator.free(self.priority);
        if (self.anim_frames.len > 0) self.allocator.free(self.anim_frames);
        if (self.trailer.len > 0) self.allocator.free(self.trailer);
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
const RESERVED_BYTES = 24;

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
            .weapon_class_raw = b[5..9].*,
            .flag_bytes = .{ b[2], b[3] },
        };
        off += LAYER_BYTES;
    }

    if (off + frames_per_dir > bytes.len) return error.InvalidCof;
    const anim_frames = try alloc.dupe(u8, bytes[off .. off + frames_per_dir]);
    errdefer alloc.free(anim_frames);
    off += frames_per_dir;

    const prio_len = @as(usize, num_directions) * frames_per_dir * num_layers;
    if (off + prio_len > bytes.len) return error.InvalidCof;
    const priority = try alloc.dupe(u8, bytes[off .. off + prio_len]);
    errdefer alloc.free(priority);
    off += prio_len;

    const trailer: []u8 = if (off < bytes.len) try alloc.dupe(u8, bytes[off..]) else &.{};

    var reserved: [RESERVED_BYTES]u8 = undefined;
    @memcpy(reserved[0..21], bytes[3..24]);
    @memcpy(reserved[21..24], bytes[25..28]);

    return .{
        .num_layers = num_layers,
        .frames_per_dir = frames_per_dir,
        .num_directions = num_directions,
        .speed = speed,
        .layers = layers,
        .priority = priority,
        .anim_frames = anim_frames,
        .reserved = reserved,
        .trailer = trailer,
        .allocator = alloc,
    };
}

/// Serialise a COF. Caller owns the result. `encode(parse(bytes))` is `bytes`.
///
/// Layer flags are written as their stored bytes when those still agree with `selectable` and
/// `transparent`, and as 0/1 otherwise; the weapon class likewise keeps its stored padding when
/// the class is unchanged. A COF built from scratch has no `anim_frames`, which are written as zero.
pub fn encode(alloc: std.mem.Allocator, c: *const Cof) ![]u8 {
    if (c.layers.len != c.num_layers) return error.InvalidCof;
    const prio_len = @as(usize, c.num_directions) * c.frames_per_dir * c.num_layers;
    if (c.priority.len != prio_len) return error.InvalidCof;
    if (c.anim_frames.len != 0 and c.anim_frames.len != c.frames_per_dir) return error.InvalidCof;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, &.{ c.num_layers, c.frames_per_dir, c.num_directions });
    try out.appendSlice(alloc, c.reserved[0..21]);
    try out.append(alloc, c.speed);
    try out.appendSlice(alloc, c.reserved[21..24]);

    for (c.layers) |*l| {
        const sel: u8 = if ((l.flag_bytes[0] > 0) == l.selectable) l.flag_bytes[0] else @intFromBool(l.selectable);
        const trn: u8 = if ((l.flag_bytes[1] > 0) == l.transparent) l.flag_bytes[1] else @intFromBool(l.transparent);
        try out.appendSlice(alloc, &.{ l.component, l.shadow, sel, trn, l.draw_effect });
        try out.appendSlice(alloc, &weaponClassBytes(l));
    }

    if (c.anim_frames.len == 0) {
        try out.appendNTimes(alloc, 0, c.frames_per_dir);
    } else {
        try out.appendSlice(alloc, c.anim_frames);
    }
    try out.appendSlice(alloc, c.priority);
    try out.appendSlice(alloc, c.trailer);
    return out.toOwnedSlice(alloc);
}

fn weaponClassBytes(l: *const Layer) [4]u8 {
    var trimmed: [4]u8 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    for (l.weapon_class_raw) |ch| {
        if (ch == 0 or ch == ' ') continue;
        trimmed[n] = ch;
        n += 1;
    }
    if (std.mem.eql(u8, trimmed[0..n], l.wclass())) return l.weapon_class_raw;
    var out: [4]u8 = .{ 0, 0, 0, 0 };
    @memcpy(out[0..l.weapon_class_len], l.wclass());
    return out;
}

test "cof: parse and encode are inverses, and a built COF encodes to what parses back" {
    const alloc = std.testing.allocator;
    // 2 layers, 3 frames, 1 direction.
    var raw: [28 + 2 * 9 + 3 + 6]u8 = undefined;
    for (raw[0..28], 0..) |*b, i| b.* = @intCast(i * 7 % 251);
    raw[0] = 2;
    raw[1] = 3;
    raw[2] = 1;
    raw[24] = 0x80;
    const l0 = [9]u8{ 1, 1, 1, 0, 0, 'H', 'T', 'H', 0 };
    const l1 = [9]u8{ 5, 0, 2, 1, 3, '1', 'H', 'S', ' ' };
    @memcpy(raw[28..37], &l0);
    @memcpy(raw[37..46], &l1);
    @memcpy(raw[46..49], &[_]u8{ 0, 1, 0 });
    @memcpy(raw[49..55], &[_]u8{ 1, 5, 5, 1, 1, 5 });

    var c = try parse(alloc, &raw);
    defer c.deinit();
    try std.testing.expectEqualStrings("1HS", c.layers[1].wclass());
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, c.anim_frames);

    const back = try encode(alloc, &c);
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u8, &raw, back);

    // Changing a class drops the stored padding for the canonical NUL-padded form.
    c.layers[1].weapon_class = .{ 'B', 'O', 'W', 0 };
    const changed = try encode(alloc, &c);
    defer alloc.free(changed);
    try std.testing.expectEqualSlices(u8, &.{ 'B', 'O', 'W', 0 }, changed[37 + 5 ..][0..4]);
    var again = try parse(alloc, changed);
    defer again.deinit();
    try std.testing.expectEqualStrings("BOW", again.layers[1].wclass());
}
