//! Recursive size-prefixed block serialization for DRLG goldens — a compact binary
//! alternative to JSONL so verification can scale to thousands of seeds. The engine
//! dump and our generator emit the SAME bytes, so comparing a seed is a fast walk
//! (or memcmp), and the size prefixes let a reader skip a whole level/room block
//! without parsing it.
//!
//! Format (all little-endian). ONE LEVEL RECORD per level (like a JSONL line), each a
//! size-prefixed block. Blocks nest: a level holds room blocks; a room block carries
//! its fields plus the adjacent room INDICES — index "pointers" into this level's room
//! array (the adjacency graph), so rooms reference other room blocks without offsets.
//!
//!   block  = u32 size  (bytes of payload that follow), then payload
//!   level  = block{ i32 id, u32 drlgType, u32 seed, i32 x,y,w,h, u32 nRooms, room[nRooms] }
//!   room   = block{ i32 x,y,w,h, u32 seed, i32 def, pickedFile, nType, nPresetType,
//!                   near, u32 nAdj, i32 adj[nAdj] }

const std = @import("std");
const oracle = @import("oracle.zig");

pub const Writer = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Writer {
        return .{ .a = a };
    }
    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.a);
    }

    fn putU32(self: *Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.a, &b);
    }
    fn putI32(self: *Writer, v: i32) !void {
        try self.putU32(@bitCast(v));
    }

    /// Reserve a size slot (backpatched by `endBlock`); returns its byte index.
    fn beginBlock(self: *Writer) !usize {
        const at = self.buf.items.len;
        try self.putU32(0);
        return at;
    }
    fn endBlock(self: *Writer, at: usize) void {
        const size: u32 = @intCast(self.buf.items.len - at - 4);
        std.mem.writeInt(u32, self.buf.items[at..][0..4], size, .little);
    }

    /// Append one level record (a size-prefixed block, with nested room blocks).
    pub fn writeLevel(self: *Writer, lv: oracle.Level) !void {
        const at = try self.beginBlock();
        try self.putI32(lv.id);
        try self.putU32(@as(u32, lv.drlg_type));
        try self.putU32(lv.seed);
        try self.putI32(lv.coords.x);
        try self.putI32(lv.coords.y);
        try self.putI32(lv.coords.w);
        try self.putI32(lv.coords.h);
        try self.putU32(@intCast(lv.rooms.len));
        for (lv.rooms) |r| try self.writeRoom(r);
        self.endBlock(at);
    }

    fn writeRoom(self: *Writer, r: oracle.Room) !void {
        const at = try self.beginBlock();
        try self.putI32(r.coords.x);
        try self.putI32(r.coords.y);
        try self.putI32(r.coords.w);
        try self.putI32(r.coords.h);
        try self.putU32(r.seed);
        try self.putI32(r.def);
        try self.putI32(r.picked_file);
        try self.putI32(r.n_type);
        try self.putI32(r.n_preset_type);
        try self.putI32(r.near);
        try self.putU32(@intCast(r.adj.len));
        for (r.adj) |idx| try self.putI32(idx);
        self.endBlock(at);
    }
};

/// Reads the block stream back into `oracle.Level`s. Caller owns the slice and must
/// `deinit` each Level + free the slice (same ownership as oracle.parseJsonl).
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn getU32(self: *Reader) u32 {
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn getI32(self: *Reader) i32 {
        return @bitCast(self.getU32());
    }

    fn readRoom(self: *Reader, a: std.mem.Allocator) !oracle.Room {
        const size = self.getU32();
        const end = self.pos + size;
        var r: oracle.Room = .{};
        r.coords = .{ .x = self.getI32(), .y = self.getI32(), .w = self.getI32(), .h = self.getI32() };
        r.seed = self.getU32();
        r.def = self.getI32();
        r.picked_file = self.getI32();
        r.n_type = self.getI32();
        r.n_preset_type = self.getI32();
        r.near = self.getI32();
        const n_adj = self.getU32();
        const adj = try a.alloc(i32, n_adj);
        for (adj) |*x| x.* = self.getI32();
        r.adj = adj;
        self.pos = end; // tolerate trailing block bytes (forward-compat)
        return r;
    }

    pub fn parse(a: std.mem.Allocator, bytes: []const u8) ![]oracle.Level {
        var levels: std.ArrayListUnmanaged(oracle.Level) = .empty;
        errdefer {
            for (levels.items) |*lv| lv.deinit(a);
            levels.deinit(a);
        }
        var rd = Reader{ .data = bytes };
        while (rd.pos + 4 <= bytes.len) {
            const size = rd.getU32();
            const end = rd.pos + size;
            var lv: oracle.Level = .{};
            lv.id = rd.getI32();
            lv.drlg_type = @intCast(rd.getU32());
            lv.seed = rd.getU32();
            lv.coords = .{ .x = rd.getI32(), .y = rd.getI32(), .w = rd.getI32(), .h = rd.getI32() };
            const n_rooms = rd.getU32();
            const rooms = try a.alloc(oracle.Room, n_rooms);
            for (rooms) |*room| room.* = try rd.readRoom(a);
            lv.rooms = rooms;
            rd.pos = end;
            try levels.append(a, lv);
        }
        return levels.toOwnedSlice(a);
    }
};

/// Serialize a whole set of levels to one binary blob (one record per level).
pub fn serialize(a: std.mem.Allocator, levels: []const oracle.Level) ![]u8 {
    var w = Writer.init(a);
    errdefer w.deinit();
    for (levels) |lv| try w.writeLevel(lv);
    return w.buf.toOwnedSlice(a);
}

const testing = std.testing;

test "block serializer round-trips a deep golden level (coords + adjacency pointers)" {
    const a = testing.allocator;
    // A deep golden level carries rooms WITH adjacency index-pointers — the hardest case.
    const src = try oracle.parseJsonl(a, @embedFile("golden/deep_seed_305419896.jsonl"));
    defer {
        for (src) |*lv| lv.deinit(a);
        a.free(src);
    }
    try testing.expect(src.len > 0);

    const bytes = try serialize(a, src);
    defer a.free(bytes);
    const back = try Reader.parse(a, bytes);
    defer {
        for (back) |*lv| lv.deinit(a);
        a.free(back);
    }

    try testing.expectEqual(src.len, back.len);
    for (src, back) |s, b| {
        try testing.expectEqual(s.id, b.id);
        try testing.expectEqual(s.drlg_type, b.drlg_type);
        try testing.expectEqual(s.seed, b.seed);
        try testing.expect(s.coords.eql(b.coords));
        try testing.expectEqual(s.rooms.len, b.rooms.len);
        for (s.rooms, b.rooms) |sr, br| {
            try testing.expect(sr.coords.eql(br.coords)); // x/y/w/h — the core check
            try testing.expectEqual(sr.seed, br.seed);
            try testing.expectEqual(sr.def, br.def);
            try testing.expectEqual(sr.picked_file, br.picked_file);
            try testing.expectEqual(sr.n_type, br.n_type);
            try testing.expectEqual(sr.n_preset_type, br.n_preset_type);
            try testing.expectEqual(sr.adj.len, br.adj.len);
            for (sr.adj, br.adj) |sa, ba| try testing.expectEqual(sa, ba); // adjacency pointers
        }
    }
}

test "binary form is much smaller than the JSONL it replaces" {
    const a = testing.allocator;
    const jsonl = @embedFile("golden/deep_seed_305419896.jsonl");
    const src = try oracle.parseJsonl(a, jsonl);
    defer {
        for (src) |*lv| lv.deinit(a);
        a.free(src);
    }
    const bytes = try serialize(a, src);
    defer a.free(bytes);
    // The packed blocks should be a fraction of the JSON text size (fast to load at scale).
    try testing.expect(bytes.len < jsonl.len);
}
