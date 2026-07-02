//! Compact serialization of the DS1 "level structure" the DRLG closure consumes.
//!
//! The runtime used to read each .ds1 off disk (assets/tiles/) and parse it with
//! ds1.zig at generation time. This module bakes the SAME reduced structure — the
//! fields fillDrlgFileFromDs1 reads — into one blob (src/ds1_blob.bin, built by
//! tools/gen_ds1_blob.zig) so the binary needs no assets/ at runtime.
//!
//! Blob layout (little-endian):
//!   [8]u8  MAGIC
//!   u32    count
//!   count x index entry: u16 keyLen, key bytes (lowercased rel path),
//!                        u32 recOff (absolute), u32 recLen
//!   records back-to-back
//!
//! Record: the exact inputs fillDrlgFileFromDs1 pulls from a parsed Ds1. Cell
//! grids are RLE'd (value:u32 + varint runLen) — they are extremely repetitive.

const std = @import("std");
/// Re-exported so the generator (a separate build module) shares this exact ds1
/// module instance — keeping ds1.Ds1 one type across pack and unpack.
pub const ds1 = @import("ds1.zig");

const flate = std.compress.flate;

pub const MAGIC = "D2DS1B01";

const U8List = std.ArrayListUnmanaged(u8);

// ---- whole-blob deflate wrapper -------------------------------------------
// RLE alone leaves the varied wall/floor grids at ~4.4MB; a deflate pass over
// the whole blob squeezes it well under target. The embedded file is the
// compressed form; buildIndex operates on the decompressed bytes.

pub fn compress(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Non-zero initial capacity: Compress.init asserts output.buffer.len > 8.
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, 64 * 1024);
    errdefer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, .raw, flate.Compress.Options.best);
    try c.writer.writeAll(raw);
    try c.finish();
    return out.toOwnedSlice();
}

pub fn decompress(gpa: std.mem.Allocator, comp: []const u8) ![]u8 {
    var in = std.Io.Reader.fixed(comp);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, .raw, &window);
    return d.reader.allocRemaining(gpa, .unlimited);
}

// ---- pack side (tools/gen_ds1_blob.zig) ------------------------------------

fn putU32(l: *U8List, a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try l.appendSlice(a, &b);
}

fn putI32(l: *U8List, a: std.mem.Allocator, v: i32) !void {
    try putU32(l, a, @bitCast(v));
}

fn putVarint(l: *U8List, a: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try l.append(a, byte);
        if (v == 0) break;
    }
}

/// RLE a cell array (value:u32 + varint runLen). Cell count is derived from
/// width*height at unpack time, so no length prefix is stored.
fn packCells(l: *U8List, a: std.mem.Allocator, cells: []const ds1.Cell) !void {
    var i: usize = 0;
    while (i < cells.len) {
        const v = cells[i].raw;
        var run: u64 = 1;
        while (i + run < cells.len and cells[i + run].raw == v) run += 1;
        try putU32(l, a, v);
        try putVarint(l, a, run);
        i += run;
    }
}

/// Serialize one parsed DS1 into a self-contained record (appended to `l`).
pub fn packRecord(l: *U8List, a: std.mem.Allocator, d: *const ds1.Ds1) !void {
    try putU32(l, a, d.width);
    try putU32(l, a, d.height);
    try putI32(l, a, d.act);
    try putI32(l, a, d.act_id);

    try putU32(l, a, @intCast(d.wall_layers.len));
    for (d.wall_layers) |wl| {
        try packCells(l, a, wl.wall);
        try packCells(l, a, wl.orient);
    }

    try putU32(l, a, @intCast(d.floor_layers.len));
    for (d.floor_layers) |fl| try packCells(l, a, fl);

    try packCells(l, a, d.shadow);

    if (d.subst_tags) |st| {
        try l.append(a, 1);
        try packCells(l, a, st);
    } else {
        try l.append(a, 0);
    }

    try putU32(l, a, @intCast(d.subst_groups.len));
    for (d.subst_groups) |g| {
        try putI32(l, a, g.x);
        try putI32(l, a, g.y);
        try putI32(l, a, g.w);
        try putI32(l, a, g.h);
        try putI32(l, a, g.unknown);
    }

    try putU32(l, a, @intCast(d.objects.len));
    for (d.objects) |o| {
        try putI32(l, a, o.kind);
        try putI32(l, a, o.id);
        try putI32(l, a, o.x);
        try putI32(l, a, o.y);
        try putI32(l, a, o.flags);
    }
}

// ---- unpack side (runtime) -------------------------------------------------

const Cursor = struct {
    b: []const u8,
    pos: usize = 0,

    fn u32v(self: *Cursor) !u32 {
        if (self.pos + 4 > self.b.len) return error.BadBlob;
        const v = std.mem.readInt(u32, self.b[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn i32v(self: *Cursor) !i32 {
        return @bitCast(try self.u32v());
    }
    fn varint(self: *Cursor) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.b.len) return error.BadBlob;
            const byte = self.b[self.pos];
            self.pos += 1;
            result |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }
    fn cells(self: *Cursor, a: std.mem.Allocator, total: usize) ![]ds1.Cell {
        const out = try a.alloc(ds1.Cell, total);
        errdefer a.free(out);
        var i: usize = 0;
        while (i < total) {
            const v = try self.u32v();
            const run: usize = @intCast(try self.varint());
            if (i + run > total) return error.BadBlob;
            // Same decode ds1.Cell.from performs (it is file-private).
            const cell = ds1.Cell{
                .raw = v,
                .prop1 = @truncate(v),
                .prop2 = @truncate(v >> 8),
                .orientation = @truncate(v >> 16),
            };
            for (0..run) |k| out[i + k] = cell;
            i += run;
        }
        return out;
    }
};

/// Rebuild a ds1.Ds1 from a record. Faithful to what ds1.parse would have
/// produced for the fields fillDrlgFileFromDs1 reads; npc_paths is left empty
/// (the DRLG closure never reads it). Caller owns the returned Ds1 (deinit()).
pub fn unpack(a: std.mem.Allocator, rec: []const u8) !ds1.Ds1 {
    var c = Cursor{ .b = rec };
    const width = try c.u32v();
    const height = try c.u32v();
    const act = try c.i32v();
    const act_id = try c.i32v();
    const total: usize = @as(usize, width) * @as(usize, height);

    const n_wall = try c.u32v();
    const wall_layers = try a.alloc(ds1.WallLayer, n_wall);
    errdefer a.free(wall_layers);
    for (wall_layers) |*wl| {
        wl.wall = try c.cells(a, total);
        wl.orient = try c.cells(a, total);
    }

    const n_floor = try c.u32v();
    const floor_layers = try a.alloc([]ds1.Cell, n_floor);
    errdefer a.free(floor_layers);
    for (floor_layers) |*fl| fl.* = try c.cells(a, total);

    const shadow = try c.cells(a, total);

    var subst_tags: ?[]ds1.Cell = null;
    const has_tags = if (c.pos < c.b.len) c.b[c.pos] else return error.BadBlob;
    c.pos += 1;
    if (has_tags == 1) subst_tags = try c.cells(a, total);

    const n_groups = try c.u32v();
    const subst_groups = try a.alloc(ds1.SubstGroup, n_groups);
    errdefer a.free(subst_groups);
    for (subst_groups) |*g| {
        g.x = try c.i32v();
        g.y = try c.i32v();
        g.w = try c.i32v();
        g.h = try c.i32v();
        g.unknown = try c.i32v();
    }

    const n_obj = try c.u32v();
    const objects = try a.alloc(ds1.Object, n_obj);
    errdefer a.free(objects);
    for (objects) |*o| {
        o.kind = try c.i32v();
        o.id = try c.i32v();
        o.x = try c.i32v();
        o.y = try c.i32v();
        o.flags = try c.i32v();
    }

    return .{
        .allocator = a,
        .version = 0,
        .width = width,
        .height = height,
        .act = act,
        .act_id = act_id,
        .wall_layers = wall_layers,
        .floor_layers = floor_layers,
        .shadow = shadow,
        .subst_tags = subst_tags,
        .objects = objects,
        .subst_groups = subst_groups,
        .npc_paths = try a.alloc(ds1.NpcPath, 0),
        .bytes_consumed = c.pos,
        .npc_paths_deferred = false,
    };
}

// ---- index / lookup --------------------------------------------------------

pub const Index = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    keys: U8List = .empty,
    a: std.mem.Allocator,

    pub fn deinit(self: *Index) void {
        self.map.deinit(self.a);
        self.keys.deinit(self.a);
    }

    pub fn get(self: *const Index, rel: []const u8) ?[]const u8 {
        var buf: [512]u8 = undefined;
        if (rel.len > buf.len) return null;
        for (rel, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return self.map.get(buf[0..rel.len]);
    }
};

/// Parse the blob header into a key -> record-slice map. `blob` must outlive the
/// index (it is a slice into the embedded bytes; only the key strings are copied).
pub fn buildIndex(a: std.mem.Allocator, blob: []const u8) !Index {
    if (blob.len < 12 or !std.mem.eql(u8, blob[0..8], MAGIC)) return error.BadBlob;
    var idx = Index{ .a = a };
    errdefer idx.deinit();
    const count = std.mem.readInt(u32, blob[8..12], .little);
    var pos: usize = 12;
    try idx.map.ensureTotalCapacity(a, count);
    // Copy all key bytes into one arena so map keys stay stable regardless of
    // any future reallocation of the source (they alias `idx.keys`).
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 2 > blob.len) return error.BadBlob;
        const key_len = std.mem.readInt(u16, blob[pos..][0..2], .little);
        pos += 2;
        if (pos + key_len + 8 > blob.len) return error.BadBlob;
        const key_off = idx.keys.items.len;
        try idx.keys.appendSlice(a, blob[pos .. pos + key_len]);
        pos += key_len;
        const rec_off = std.mem.readInt(u32, blob[pos..][0..4], .little);
        const rec_len = std.mem.readInt(u32, blob[pos + 4 ..][0..4], .little);
        pos += 8;
        if (rec_off + rec_len > blob.len) return error.BadBlob;
        _ = .{ key_off, rec_off, rec_len };
    }
    // Second pass: keys arena is now stable; wire the map to its slices.
    pos = 12;
    var koff: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const key_len = std.mem.readInt(u16, blob[pos..][0..2], .little);
        pos += 2 + key_len;
        const rec_off = std.mem.readInt(u32, blob[pos..][0..4], .little);
        const rec_len = std.mem.readInt(u32, blob[pos + 4 ..][0..4], .little);
        pos += 8;
        const key = idx.keys.items[koff .. koff + key_len];
        koff += key_len;
        idx.map.putAssumeCapacity(key, blob[rec_off .. rec_off + rec_len]);
    }
    return idx;
}
