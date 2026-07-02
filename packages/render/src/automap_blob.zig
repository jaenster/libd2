//! Runtime accessor for the baked automap-sprite blob: the four per-act automap
//! DC6 sheets + the five per-act 256-colour RGB palettes, packed at build time from
//! assets/automap/ (tools/gen_automap_blob.zig) and embedded. Raw DC6 bytes are
//! kept as-is (small); callers decode on demand with dc6.zig. Layout (little-endian):
//!   MAGIC[4] "AMB2"
//!   u8  pal_count
//!   pal_count * u8[768]        (256 * RGB, index 0-based act: 0=ACT1 … 4=ACT5)
//!   u8  layer_count
//!   per layer: u8 name_len, name bytes, u32 data_len
//!   then each layer's raw DC6 bytes, in order.

const std = @import("std");

pub const MAGIC = "AMB2";
pub const PALETTE_LEN = 768;

pub const Layer = struct { name: []const u8, dc6: []const u8 };

pub const Blob = struct {
    palettes: [][]const u8, // each 768 bytes RGB; index = 0-based act
    layers: []Layer,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Blob) void {
        self.allocator.free(self.palettes);
        self.allocator.free(self.layers);
    }

    /// Palette for a 0-based act index (clamped to the available range).
    pub fn palette(self: *const Blob, act: usize) []const u8 {
        if (self.palettes.len == 0) return &[_]u8{};
        return self.palettes[@min(act, self.palettes.len - 1)];
    }

    /// Raw DC6 bytes for a layer by (case-insensitive) name, or null.
    pub fn layer(self: *const Blob, name: []const u8) ?[]const u8 {
        for (self.layers) |l| {
            if (std.ascii.eqlIgnoreCase(l.name, name)) return l.dc6;
        }
        return null;
    }
};

/// Parse the embedded blob (borrows `bytes` for the DC6/palette slices; only the
/// `palettes` + `layers` arrays are allocated). Caller calls deinit.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Blob {
    if (bytes.len < 5 or !std.mem.eql(u8, bytes[0..4], MAGIC)) return error.BadBlob;
    var o: usize = 4;
    const pal_count = bytes[o];
    o += 1;
    const palettes = try alloc.alloc([]const u8, pal_count);
    errdefer alloc.free(palettes);
    var p: usize = 0;
    while (p < pal_count) : (p += 1) {
        if (o + PALETTE_LEN > bytes.len) return error.BadBlob;
        palettes[p] = bytes[o .. o + PALETTE_LEN];
        o += PALETTE_LEN;
    }
    if (o >= bytes.len) return error.BadBlob;
    const count = bytes[o];
    o += 1;

    const layers = try alloc.alloc(Layer, count);
    errdefer alloc.free(layers);
    var lens = try alloc.alloc(u32, count);
    defer alloc.free(lens);
    var names = try alloc.alloc([]const u8, count);
    defer alloc.free(names);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (o >= bytes.len) return error.BadBlob;
        const nlen = bytes[o];
        o += 1;
        if (o + nlen + 4 > bytes.len) return error.BadBlob;
        names[i] = bytes[o .. o + nlen];
        o += nlen;
        lens[i] = std.mem.readInt(u32, bytes[o..][0..4], .little);
        o += 4;
    }
    i = 0;
    while (i < count) : (i += 1) {
        if (o + lens[i] > bytes.len) return error.BadBlob;
        layers[i] = .{ .name = names[i], .dc6 = bytes[o .. o + lens[i]] };
        o += lens[i];
    }
    return .{ .palettes = palettes, .layers = layers, .allocator = alloc };
}
