//! DCC encoder: the inverse of `dcc.parse`. `encode(alloc, &dcc)` turns the `Dcc` the
//! decoder returns back into a DCC byte stream that decodes to the same directions,
//! frame boxes and palette indices. Every cell is coded against an exact simulation of
//! the decoder's direction accumulator, so what is written is what `parse` reproduces,
//! whatever the options.
//!
//! With the default options a parsed game DCC re-encodes byte-identical in almost every
//! direction: the cell layout below is Blizzard's, and the two choices that cannot be
//! derived from decoded pixels (which optional streams a direction carries, and which
//! seen cells are EqualCells) are taken from `Direction.compression_flags` and
//! `Direction.equal_cells` when present and still valid. Blizzard's own EqualCell
//! choice apparently compared the art before it was reduced to 4 colours per cell: it
//! sometimes codes a cell a copy would reproduce exactly.
//!
//! Header size fields describe the DC6 the sprite converts to and are recomputed from
//! the pixels (the formulas hold for every frame of every shipped DCC):
//!   - frame CodedBytes: the frame's DC6 scanline-stream length (see dc6StreamLen);
//!   - direction OutSizeCoded: sum over its frames of CodedBytes + 35 (DC6 frame
//!     header + terminator);
//!   - file TotalSizeCoded: 24 + 4 * directions * frames_per_dir + sum of OutSizeCoded.
//!
//! Per direction:
//!   - Frame headers: the boxes from `Direction.frame_boxes` (the direction box for every
//!     frame when that is empty), Variable0 from `frame_meta` (0 when empty),
//!     OptionalBytes 0, bottom-up 0. Each field width is the header's original
//!     CRAZY_BIT_TABLE code when the values still fit it, else the narrowest that does.
//!   - Palette-entries bitmap: the colours inside the frame cells, plus colour 0 when any
//!     cell has fewer than 4 non-zero colours (its spare entry slots hold colour 0).
//!     Without colour 0, entry index 0 is the lowest colour; only the EqualCell "clear"
//!     path then produces colour 0, and the accumulator simulation accounts for that.
//!   - EqualCell (compression bit 1): a cell whose grid position an earlier frame
//!     covered is sent as "equal" when the decoder's copy-or-clear rule reproduces it.
//!   - PixelMask / values: `Strategy.blizzard` lays the cell's colours out as Blizzard
//!     does (blizzardLayout) and masks the slots that changed; `Strategy.smallest`
//!     searches for the cheapest mask, values and pixel width instead.
//!   - EncodingType / RawPixel (compression bit 0): each cell's value stack is written
//!     as displacements, or as raw bytes when that is strictly shorter.
//!   A stream whose flag is set but which no cell uses is dropped along with its flag.
//!
//! Refused: a coded cell holding more than 4 distinct colours (error.TooManyColoursInCell;
//! a DCC entry cannot represent it and nothing is quantised - an EqualCell copy may
//! repeat more, and such a cell is accepted when a copy reproduces it), a non-zero pixel
//! outside its frame's box (error.PixelOutsideFrameBox), frame boxes whose union is not
//! the direction box (error.BoxMismatch), and a sub-stream over the 20-bit size field
//! (error.StreamTooLarge). Optional-bytes and bottom-up frames are never written; the
//! decoder refuses both.

const std = @import("std");
const dcc = @import("dcc.zig");

const Rect = dcc.Rect;
const Dcc = dcc.Dcc;
const Direction = dcc.Direction;
const CRAZY_BIT_TABLE = dcc.CRAZY_BIT_TABLE;
const CELLS = dcc.CELLS_PER_ROW;

pub const Error = error{
    OutOfMemory,
    InvalidInput,
    BoxMismatch,
    PixelOutsideFrameBox,
    TooManyColoursInCell,
    StreamTooLarge,
};

const HEADER_SIZE = 15;
const STREAM_SIZE_BITS = 20;
/// A DC6 frame header (32 bytes) plus its 3-byte terminator.
const DC6_FRAME_OVERHEAD = 35;

pub const Strategy = enum {
    /// Blizzard's cell layout (blizzardLayout); follows `Direction.equal_cells` where valid.
    blizzard,
    /// Per cell, the cheapest mask / values / pixel width the decoder accepts.
    smallest,
};

/// Whether an optional sub-stream may be used. `on` allows it (it is still dropped when no
/// cell uses it), `auto` encodes the direction with and without it and keeps the shorter,
/// `keep` follows `Direction.compression_flags` and falls back to `auto` without them
/// (a pass that cannot code a cell without EqualCell is skipped, not an error).
pub const StreamMode = enum { off, on, auto, keep };

pub const Options = struct {
    strategy: Strategy = .blizzard,
    equal_cells: StreamMode = .keep,
    raw_pixels: StreamMode = .keep,
};

/// Serialise a DCC with the default options. Caller owns the result.
pub fn encode(alloc: std.mem.Allocator, sprite: *const Dcc) Error![]u8 {
    return encodeWith(alloc, sprite, .{});
}

/// Serialise a DCC. Caller owns the result.
pub fn encodeWith(alloc: std.mem.Allocator, sprite: *const Dcc, opts: Options) Error![]u8 {
    const ndir = sprite.directions.len;
    if (ndir == 0 or ndir > 255 or sprite.frames_per_dir == 0) return error.InvalidInput;
    if (sprite.frames_per_dir > std.math.maxInt(i32)) return error.InvalidInput;

    var dir_bytes = try alloc.alloc([]u8, ndir);
    var dc6_size: u64 = 24 + 4 * @as(u64, ndir) * sprite.frames_per_dir;
    var built: usize = 0;
    defer {
        for (dir_bytes[0..built]) |d| alloc.free(d);
        alloc.free(dir_bytes);
    }
    for (sprite.directions, 0..) |*d, i| {
        const enc = try encodeDirection(alloc, d, sprite.frames_per_dir, opts);
        dir_bytes[i] = enc.bytes;
        dc6_size += enc.dc6_size;
        built += 1;
    }

    var total: usize = HEADER_SIZE + 4 * ndir;
    for (dir_bytes) |d| total += d.len;
    if (total > std.math.maxInt(u32) or dc6_size > std.math.maxInt(u32)) return error.StreamTooLarge;

    const out = try alloc.alloc(u8, total);
    out[0] = dcc.DCC_SIGNATURE;
    out[1] = sprite.version;
    out[2] = @intCast(ndir);
    std.mem.writeInt(u32, out[3..7], sprite.frames_per_dir, .little);
    std.mem.writeInt(u32, out[7..11], 1, .little);
    std.mem.writeInt(u32, out[11..15], @intCast(dc6_size), .little);
    var at: usize = HEADER_SIZE + 4 * ndir;
    for (dir_bytes, 0..) |d, i| {
        std.mem.writeInt(u32, out[HEADER_SIZE + 4 * i ..][0..4], @intCast(at), .little);
        @memcpy(out[at..][0..d.len], d);
        at += d.len;
    }
    return out;
}

/// LSB-first bit writer; the mirror of dcc.zig's BitMuncher.
const BitWriter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    len: usize = 0,

    fn deinit(self: *BitWriter, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }
    fn bit(self: *BitWriter, alloc: std.mem.Allocator, b: u32) !void {
        if (self.len % 8 == 0) try self.buf.append(alloc, 0);
        if (b & 1 != 0) self.buf.items[self.len / 8] |= @as(u8, 1) << @intCast(self.len % 8);
        self.len += 1;
    }
    fn bits(self: *BitWriter, alloc: std.mem.Allocator, value: u32, n: u6) !void {
        var i: u6 = 0;
        while (i < n) : (i += 1) try self.bit(alloc, value >> @intCast(i));
    }
    fn getBit(self: *const BitWriter, i: usize) u32 {
        return (self.buf.items[i / 8] >> @intCast(i % 8)) & 1;
    }
    fn append(self: *BitWriter, alloc: std.mem.Allocator, other: *const BitWriter) !void {
        if (self.len % 8 == 0) {
            try self.buf.appendSlice(alloc, other.buf.items[0 .. (other.len + 7) / 8]);
            self.len += other.len;
            return;
        }
        var i: usize = 0;
        while (i < other.len) : (i += 1) try self.bit(alloc, other.getBit(i));
    }
};

/// Decoder state of one direction-grid cell.
const GridCell = struct {
    seen: bool = false,
    last_w: i32 = -1,
    last_h: i32 = -1,
    last_xoff: i32 = 0,
    last_yoff: i32 = 0,
    /// The pixel-buffer entry a pixel mask falls back on, in palette-entry index space.
    entry: [4]u8 = .{ 0, 0, 0, 0 },
    /// The entry Blizzard's layout is kept stable against: the last one written, or for
    /// an EqualCell, the layout of the colours it repeated.
    ref: [4]u8 = .{ 0, 0, 0, 0 },
};

/// How one coded cell is written.
const Choice = struct {
    mask: u4 = 0xF,
    /// The resulting pixel-buffer entry.
    v: [4]u8 = .{ 0, 0, 0, 0 },
    /// Newly coded values in stack (read) order.
    stack: [4]u8 = .{ 0, 0, 0, 0 },
    d: u3 = 0,
    n: u3 = 0,
    raw: bool = false,
    bpp: u2 = 0,
    cost: usize = std.math.maxInt(usize),
};


const EncodedDirection = struct { bytes: []u8, dc6_size: u64 };

/// Everything about a direction that does not depend on how its cells are coded.
const Prepared = struct {
    W: usize,
    H: usize,
    boxes: []Rect,
    used: [256]bool,
    index_of: [256]u8,
    coded: []u32,
    dc6_size: u64,
    field_codes: [7]u4,

    fn deinit(self: *Prepared, alloc: std.mem.Allocator) void {
        alloc.free(self.boxes);
        alloc.free(self.coded);
    }
};

fn prepare(alloc: std.mem.Allocator, dir: *const Direction, fpd: u32) Error!Prepared {
    const nframes: usize = fpd;
    if (dir.frames.len != nframes) return error.InvalidInput;
    if (dir.frame_boxes.len != 0 and dir.frame_boxes.len != nframes) return error.InvalidInput;
    if (dir.frame_meta.len != 0 and dir.frame_meta.len != nframes) return error.InvalidInput;

    const dbox = dir.box;
    if (dbox.width <= 0 or dbox.height <= 0) return error.InvalidInput;
    const W: usize = @intCast(dbox.width);
    const H: usize = @intCast(dbox.height);
    for (dir.frames) |f| if (f.len != W * H) return error.InvalidInput;

    const boxes = try alloc.alloc(Rect, nframes);
    errdefer alloc.free(boxes);
    if (dir.frame_boxes.len != 0) @memcpy(boxes, dir.frame_boxes) else @memset(boxes, dbox);

    // The decoder derives the direction box as the union of the frame boxes.
    {
        var minx: i32 = std.math.maxInt(i32);
        var miny: i32 = std.math.maxInt(i32);
        var maxx: i32 = std.math.minInt(i32);
        var maxy: i32 = std.math.minInt(i32);
        for (boxes) |b| {
            if (b.width < 0 or b.height < 0) return error.InvalidInput;
            minx = @min(minx, b.left);
            miny = @min(miny, b.top);
            maxx = @max(maxx, b.left + b.width);
            maxy = @max(maxy, b.top + b.height);
        }
        if (minx != dbox.left or miny != dbox.top or maxx - minx != dbox.width or maxy - miny != dbox.height)
            return error.BoxMismatch;
    }

    // Everything outside a frame's box decodes as 0.
    for (dir.frames, boxes) |f, b| {
        const x0: usize = @intCast(b.left - dbox.left);
        const y0: usize = @intCast(b.top - dbox.top);
        const bw: usize = @intCast(b.width);
        const bh: usize = @intCast(b.height);
        for (0..H) |y| {
            const inside_row = y >= y0 and y < y0 + bh;
            for (0..W) |x| {
                if (inside_row and x >= x0 and x < x0 + bw) continue;
                if (f[y * W + x] != 0) return error.PixelOutsideFrameBox;
            }
        }
    }

    // Palette-entries bitmap: the colours in the frame cells, plus colour 0 when any cell
    // has fewer than 4 non-zero colours and so an entry slot is filled with it.
    var used = [_]bool{false} ** 256;
    for (dir.frames, boxes) |f, b| {
        const split = try dcc.frameCells(alloc, b, dbox);
        defer alloc.free(split.cells);
        for (split.cells) |cell| {
            var seen_colour = [_]bool{false} ** 256;
            var nonzero: usize = 0;
            for (0..@as(usize, @intCast(cell.h))) |y| for (0..@as(usize, @intCast(cell.w))) |x| {
                const p = f[(@as(usize, @intCast(cell.yoff)) + y) * W + @as(usize, @intCast(cell.xoff)) + x];
                used[p] = true;
                if (p != 0 and !seen_colour[p]) nonzero += 1;
                seen_colour[p] = true;
            };
            if (nonzero < 4) used[0] = true;
        }
    }
    var index_of: [256]u8 = undefined;
    {
        var n: usize = 0;
        for (used, 0..) |u, c| if (u) {
            index_of[c] = @intCast(n);
            n += 1;
        };
    }

    // CodedBytes and OutSizeCoded describe the DC6 this direction converts to.
    const coded = try alloc.alloc(u32, nframes);
    errdefer alloc.free(coded);
    var dc6_size: u64 = 0;
    for (dir.frames, boxes, coded) |fr, b, *c| {
        c.* = dc6StreamLen(fr, W, dbox, b);
        dc6_size += @as(u64, c.*) + DC6_FRAME_OVERHEAD;
    }
    if (dc6_size > std.math.maxInt(u32)) return error.StreamTooLarge;

    // Header field widths.
    var codes7: [7]u4 = .{ 0, 0, 0, 0, 0, 0, 0 };
    {
        var vals: [7][2]i64 = undefined; // per field: min, max over frames
        for (&vals) |*v| v.* = .{ 0, 0 };
        for (boxes, 0..) |b, i| {
            for (frameFields(dir, boxes, coded, i), 0..) |x, k| {
                vals[k][0] = @min(vals[k][0], x);
                vals[k][1] = @max(vals[k][1], x);
            }
            _ = b;
        }
        for (0..7) |k| {
            const signed = k == 3 or k == 4;
            if (k == 5) continue;
            if (dir.field_codes) |fc| {
                if (fits(CRAZY_BIT_TABLE[fc[k]], vals[k], signed)) {
                    codes7[k] = fc[k];
                    continue;
                }
            }
            var code: u5 = 0;
            while (!fits(CRAZY_BIT_TABLE[code], vals[k], signed)) code += 1;
            codes7[k] = @intCast(code);
        }
    }

    return .{
        .W = W,
        .H = H,
        .boxes = boxes,
        .used = used,
        .index_of = index_of,
        .coded = coded,
        .dc6_size = dc6_size,
        .field_codes = codes7,
    };
}

/// A frame header's seven coded fields, in header order.
fn frameFields(dir: *const Direction, boxes: []const Rect, coded: []const u32, i: usize) [7]i64 {
    const b = boxes[i];
    const meta: dcc.FrameMeta = if (dir.frame_meta.len != 0) dir.frame_meta[i] else .{};
    return .{ meta.variable0, b.width, b.height, b.left, b.top + b.height - 1, 0, coded[i] };
}

fn encodeDirection(alloc: std.mem.Allocator, dir: *const Direction, fpd: u32, opts: Options) Error!EncodedDirection {
    var prep = try prepare(alloc, dir, fpd);
    defer prep.deinit(alloc);

    const choices = struct {
        fn of(mode: StreamMode, flags: ?u2, bit: u2) []const bool {
            return switch (mode) {
                .off => &.{false},
                .on => &.{true},
                .auto => &.{ false, true },
                .keep => if (flags) |f| (if (f & bit != 0) &.{true} else &.{false}) else &.{ false, true },
            };
        }
    };

    // A pass without EqualCell can fail on a cell only a copy can reproduce; that is an
    // error only when no allowed pass succeeds.
    var best: ?Pass = null;
    errdefer if (best) |b| alloc.free(b.bytes);
    var colour_error = false;
    for (choices.of(opts.equal_cells, dir.compression_flags, 2)) |ec| {
        for (choices.of(opts.raw_pixels, dir.compression_flags, 1)) |raw| {
            const p = encodePass(alloc, dir, &prep, opts.strategy, ec, raw) catch |e| switch (e) {
                error.TooManyColoursInCell => {
                    colour_error = true;
                    continue;
                },
                else => return e,
            };
            if (best == null or p.bits < best.?.bits) {
                if (best) |b| alloc.free(b.bytes);
                best = p;
            } else alloc.free(p.bytes);
        }
    }
    // `keep` without EqualCell (edited pixels under an old header): let a copy try.
    if (best == null and opts.equal_cells == .keep) {
        for (choices.of(opts.raw_pixels, dir.compression_flags, 1)) |raw| {
            const p = encodePass(alloc, dir, &prep, opts.strategy, true, raw) catch |e| switch (e) {
                error.TooManyColoursInCell => continue,
                else => return e,
            };
            if (best == null or p.bits < best.?.bits) {
                if (best) |b| alloc.free(b.bytes);
                best = p;
            } else alloc.free(p.bytes);
        }
    }
    if (best == null) {
        std.debug.assert(colour_error);
        return error.TooManyColoursInCell;
    }
    return .{ .bytes = best.?.bytes, .dc6_size = prep.dc6_size };
}

const Pass = struct { bytes: []u8, bits: usize };

/// Code every cell of a direction once, with EqualCell and raw values allowed or not.
fn encodePass(
    alloc: std.mem.Allocator,
    dir: *const Direction,
    prep: *const Prepared,
    strategy: Strategy,
    allow_ec: bool,
    allow_raw: bool,
) Error!Pass {
    const dbox = dir.box;
    const W = prep.W;

    // Direction grid, exactly as the decoder builds it.
    const h_cells: usize = @intCast(1 + @divTrunc(dbox.width - 1, CELLS));
    const v_cells: usize = @intCast(1 + @divTrunc(dbox.height - 1, CELLS));
    if (h_cells > 1024 or v_cells > 1024) return error.InvalidInput;
    const grid = try alloc.alloc(GridCell, h_cells * v_cells);
    defer alloc.free(grid);
    @memset(grid, .{});

    const acc = try alloc.alloc(u8, W * prep.H);
    defer alloc.free(acc);
    @memset(acc, 0);

    var ec: BitWriter = .{};
    defer ec.deinit(alloc);
    var pm: BitWriter = .{};
    defer pm.deinit(alloc);
    var et: BitWriter = .{};
    defer et.deinit(alloc);
    var rp: BitWriter = .{};
    defer rp.deinit(alloc);
    var codes: BitWriter = .{};
    defer codes.deinit(alloc);
    var pixels: BitWriter = .{};
    defer pixels.deinit(alloc);
    var used_ec = false;
    var used_raw = false;
    var ec_ord: usize = 0;

    for (dir.frames, prep.boxes) |frame, fbox| {
        const split = try dcc.frameCells(alloc, fbox, dbox);
        defer alloc.free(split.cells);

        for (split.cells) |cell| {
            const cxo: usize = @intCast(cell.xoff);
            const cyo: usize = @intCast(cell.yoff);
            const cw: usize = @intCast(cell.w);
            const ch: usize = @intCast(cell.h);
            const gx = cxo / CELLS;
            const gy = cyo / CELLS;
            if (gx >= h_cells or gy >= v_cells) return error.InvalidInput;
            const gc = &grid[gx + gy * h_cells];

            // Target pixels as colours (what the accumulator holds) and as entry indices.
            var pixels_raw: [25]u8 = undefined;
            var target: [25]u8 = undefined;
            var colours: [25]u8 = undefined;
            var ncolours: usize = 0;
            for (0..ch) |y| for (0..cw) |x| {
                const px = frame[(cyo + y) * W + cxo + x];
                const p = prep.index_of[px];
                target[y * cw + x] = p;
                pixels_raw[y * cw + x] = px;
                if (std.mem.indexOfScalar(u8, colours[0..ncolours], p) == null) {
                    colours[ncolours] = p;
                    ncolours += 1;
                }
            };

            if (gc.seen and allow_ec) {
                // The recorded choice wins when it is still valid: a recorded 0 is always
                // codable (up to the 4-colour limit), a recorded 1 only if the copy matches.
                const hint: ?bool = if (strategy == .blizzard and ec_ord < dir.equal_cells.len) dir.equal_cells[ec_ord] else null;
                ec_ord += 1;
                const want_ec = if (hint) |h| h or ncolours > 4 else true;
                if (want_ec and tryEqualCell(acc, W, gc, cell, pixels_raw[0 .. cw * ch])) {
                    try ec.bit(alloc, 1);
                    used_ec = true;
                    if (ncolours <= 4) gc.ref = blizzardLayout(gc.ref, colours[0..ncolours]);
                    setLast(gc, cell);
                    continue;
                }
                try ec.bit(alloc, 0);
            }
            // Only an EqualCell copy can repeat more than 4 colours.
            if (ncolours > 4) return error.TooManyColoursInCell;

            const c = switch (strategy) {
                .blizzard => blizzardCoding(gc.seen, gc.entry, if (gc.seen) gc.ref else null, colours[0..ncolours], allow_raw),
                .smallest => chooseCoding(gc.seen, gc.entry, colours[0..ncolours], cw * ch, allow_raw),
            };
            std.debug.assert(c.cost != std.math.maxInt(usize));

            if (gc.seen) try pm.bits(alloc, c.mask, 4);
            if (c.n > 0) {
                try et.bit(alloc, @intFromBool(c.raw));
                if (c.raw) used_raw = true;
            }
            var last: u32 = 0;
            for (c.stack[0..c.d]) |s| {
                if (c.raw) try rp.bits(alloc, s, 8) else try writeDisplacement(alloc, &codes, s - last);
                last = s;
            }
            if (c.d < c.n) {
                if (c.raw) try rp.bits(alloc, last, 8) else try codes.bits(alloc, 0, 4);
            }

            if (c.bpp > 0) {
                const slots: usize = @as(usize, 1) << c.bpp;
                for (target[0 .. cw * ch]) |p| {
                    const k = std.mem.indexOfScalar(u8, c.v[0..slots], p).?;
                    try pixels.bits(alloc, @intCast(k), c.bpp);
                }
            }
            for (0..ch) |y| @memcpy(acc[(cyo + y) * W + cxo ..][0..cw], pixels_raw[y * cw ..][0..cw]);
            gc.seen = true;
            gc.entry = c.v;
            gc.ref = c.v;
            setLast(gc, cell);
        }
    }

    if (!used_ec) ec.len = 0;
    if (!used_raw) {
        et.len = 0;
        rp.len = 0;
    }
    const limit: usize = @as(usize, 1) << STREAM_SIZE_BITS;
    if (ec.len >= limit or pm.len >= limit or et.len >= limit or rp.len >= limit) return error.StreamTooLarge;

    var out: BitWriter = .{};
    defer out.deinit(alloc);
    try out.bits(alloc, @intCast(prep.dc6_size), 32); // OutSizeCoded
    const flags: u32 = (@as(u32, @intFromBool(used_ec)) << 1) | @intFromBool(used_raw);
    try out.bits(alloc, flags, 2);
    for (prep.field_codes) |c| try out.bits(alloc, c, 4);
    for (0..prep.boxes.len) |i| {
        for (frameFields(dir, prep.boxes, prep.coded, i), prep.field_codes) |x, c| {
            try out.bits(alloc, @truncate(@as(u64, @bitCast(x))), @intCast(CRAZY_BIT_TABLE[c]));
        }
        try out.bit(alloc, 0); // bottom-up
    }
    if (used_ec) try out.bits(alloc, @intCast(ec.len), STREAM_SIZE_BITS);
    try out.bits(alloc, @intCast(pm.len), STREAM_SIZE_BITS);
    if (used_raw) {
        try out.bits(alloc, @intCast(et.len), STREAM_SIZE_BITS);
        try out.bits(alloc, @intCast(rp.len), STREAM_SIZE_BITS);
    }
    for (prep.used) |u| try out.bit(alloc, @intFromBool(u));
    try out.append(alloc, &ec);
    try out.append(alloc, &pm);
    try out.append(alloc, &et);
    try out.append(alloc, &rp);
    try out.append(alloc, &codes);
    try out.append(alloc, &pixels);

    const nbits = out.len;
    const bytes = try out.buf.toOwnedSlice(alloc);
    std.debug.assert(bytes.len == (nbits + 7) / 8);
    return .{ .bytes = bytes, .bits = nbits };
}

/// Blizzard's encoder: the entry is `blizzardLayout` of the cell's colours against the
/// cell's reference entry, the mask is the set of slots that differ from the entry the
/// decoder holds, and the values are raw only when that is strictly shorter.
fn blizzardCoding(seen: bool, old: [4]u8, ref: ?[4]u8, colours: []const u8, allow_raw: bool) Choice {
    const v = blizzardLayout(ref, colours);
    var mask: u4 = 0xF;
    if (seen) {
        mask = 0;
        for (0..4) |k| if (v[k] != old[k]) {
            mask |= @as(u4, 1) << @intCast(k);
        };
    }
    var seq: [4]u8 = undefined;
    var n: u3 = 0;
    for (0..4) |k| if (mask & (@as(u4, 1) << @intCast(k)) != 0) {
        seq[n] = v[k];
        n += 1;
    };
    var d: u3 = 0;
    while (d < n and seq[d] != 0) d += 1;

    var choice: Choice = .{ .v = v, .mask = mask, .n = n, .d = d };
    for (0..d) |i| choice.stack[i] = seq[d - 1 - i];
    const costs = stackCosts(choice.stack[0..d], d < n);
    if (costs.disp == null and !allow_raw) return blizzardCoding(seen, old, null, colours, allow_raw);
    choice.raw = allow_raw and (costs.disp == null or costs.raw < costs.disp.?);
    choice.bpp = if (v[0] == v[1]) 0 else if (v[1] == v[2]) 1 else 2;
    choice.cost = if (choice.raw) costs.raw else costs.disp.?;
    return choice;
}

/// Blizzard's slot layout for a cell's colours: the non-zero colours sorted high to low
/// fill the first slots in order, except that a colour `ref` already holds in one of
/// those first slots stays there. The remaining slots are 0. The slots that differ from
/// any entry, read in order, are therefore strictly decreasing and then zero, which is
/// what a displacement-coded stack needs.
fn blizzardLayout(ref: ?[4]u8, colours: []const u8) [4]u8 {
    var nz: [4]u8 = undefined;
    var m: usize = 0;
    for (colours) |c| if (c != 0) {
        nz[m] = c;
        m += 1;
    };
    std.mem.sort(u8, nz[0..m], {}, std.sort.desc(u8));

    var v = [4]u8{ 0, 0, 0, 0 };
    var placed = [4]bool{ false, false, false, false };
    var done = [4]bool{ false, false, false, false };
    if (ref) |old| {
        for (nz[0..m], 0..) |c, i| {
            for (0..m) |p| if (!placed[p] and old[p] == c) {
                v[p] = c;
                placed[p] = true;
                done[i] = true;
                break;
            };
        }
    }
    var p: usize = 0;
    for (nz[0..m], 0..) |c, i| if (!done[i]) {
        while (placed[p]) p += 1;
        v[p] = c;
        placed[p] = true;
    };
    return v;
}

const StackCosts = struct { raw: usize, disp: ?usize };

/// Bits for a value stack (read order) in either encoding; `disp` is null when the
/// values are not strictly increasing and so cannot be written as displacements.
fn stackCosts(stack: []const u8, terminated: bool) StackCosts {
    const raw = 8 * stack.len + (if (terminated) @as(usize, 8) else 0);
    var c: usize = if (terminated) 4 else 0;
    var last: u32 = 0;
    for (stack) |s| {
        if (s <= last) return .{ .raw = raw, .disp = null };
        c += 4 * ((s - last) / 15 + 1);
        last = s;
    }
    return .{ .raw = raw, .disp = c };
}

fn setLast(gc: *GridCell, cell: dcc.Cell) void {
    gc.last_w = cell.w;
    gc.last_h = cell.h;
    gc.last_xoff = cell.xoff;
    gc.last_yoff = cell.yoff;
}

/// Apply the decoder's EqualCell rule to `acc` and report whether it yields `target`.
/// On a mismatch `acc` is restored.
fn tryEqualCell(acc: []u8, W: usize, gc: *const GridCell, cell: dcc.Cell, target: []const u8) bool {
    const cxo: usize = @intCast(cell.xoff);
    const cyo: usize = @intCast(cell.yoff);
    const cw: usize = @intCast(cell.w);
    const ch: usize = @intCast(cell.h);

    var saved: [25]u8 = undefined;
    for (0..ch) |y| @memcpy(saved[y * cw ..][0..cw], acc[(cyo + y) * W + cxo ..][0..cw]);

    if (cell.w != gc.last_w or cell.h != gc.last_h) {
        for (0..ch) |y| @memset(acc[(cyo + y) * W + cxo ..][0..cw], 0);
    } else {
        const lxo: usize = @intCast(gc.last_xoff);
        const lyo: usize = @intCast(gc.last_yoff);
        for (0..ch) |y| for (0..cw) |x| {
            acc[(cyo + y) * W + cxo + x] = acc[(lyo + y) * W + lxo + x];
        };
    }

    var same = true;
    for (0..ch) |y| {
        if (!std.mem.eql(u8, acc[(cyo + y) * W + cxo ..][0..cw], target[y * cw ..][0..cw])) same = false;
    }
    if (!same) {
        for (0..ch) |y| @memcpy(acc[(cyo + y) * W + cxo ..][0..cw], saved[y * cw ..][0..cw]);
    }
    return same;
}

/// Pick the cheapest (mask, new values, encoding, pixel width) that makes the decoder
/// produce a cell holding exactly `colours`. An unseen cell is always read with mask 0xF.
fn chooseCoding(seen: bool, old: [4]u8, colours: []const u8, npix: usize, allow_raw: bool) Choice {
    // Candidate new values: the cell's non-zero colours, plus for a one-colour cell the
    // entries that could be duplicated to meet the solid / 1-bit equality rules.
    var alphabet: [6]u8 = undefined;
    var na: usize = 0;
    for (colours) |c| if (c != 0) {
        alphabet[na] = c;
        na += 1;
    };
    if (seen and colours.len <= 1) {
        for ([_]u8{ old[0], old[1], old[2] }) |o| {
            if (o != 0 and std.mem.indexOfScalar(u8, alphabet[0..na], o) == null) {
                alphabet[na] = o;
                na += 1;
            }
        }
    }

    var best: Choice = .{};
    var mask: u5 = if (seen) 0 else 0xF;
    while (mask <= 0xF) : (mask += 1) {
        var pos: [4]u8 = undefined;
        var n: u3 = 0;
        for (0..4) |k| if (mask & (@as(u5, 1) << @intCast(k)) != 0) {
            pos[n] = @intCast(k);
            n += 1;
        };
        var search: Search = .{
            .seen = seen,
            .old = old,
            .colours = colours,
            .npix = npix,
            .mask = @intCast(mask),
            .pos = pos,
            .n = n,
            .alphabet = alphabet[0..na],
            .allow_raw = allow_raw,
            .best = &best,
        };
        search.walk(0);
    }
    return best;
}

const Search = struct {
    seen: bool,
    old: [4]u8,
    colours: []const u8,
    npix: usize,
    mask: u4,
    pos: [4]u8,
    n: u3,
    alphabet: []const u8,
    allow_raw: bool,
    best: *Choice,
    /// New values in pixel-buffer order (the order they land in the mask's set slots).
    sel: [4]u8 = undefined,
    taken: u8 = 0,

    fn walk(self: *Search, depth: u3) void {
        self.evaluate(depth);
        if (depth == self.n) return;
        for (self.alphabet, 0..) |a, i| {
            const bitm = @as(u8, 1) << @intCast(i);
            if (self.taken & bitm != 0) continue;
            self.taken |= bitm;
            self.sel[depth] = a;
            self.walk(depth + 1);
            self.taken &= ~bitm;
        }
    }

    fn evaluate(self: *Search, d: u3) void {
        var v = self.old;
        for (0..self.n) |j| v[self.pos[j]] = if (j < d) self.sel[j] else 0;

        var bpp: u2 = undefined;
        if (v[0] == v[1]) {
            bpp = 0;
            for (self.colours) |c| if (c != v[0]) return;
        } else if (v[1] == v[2]) {
            bpp = 1;
            for (self.colours) |c| if (c != v[0] and c != v[1]) return;
        } else {
            bpp = 2;
            for (self.colours) |c| if (std.mem.indexOfScalar(u8, &v, c) == null) return;
        }

        // The decoder assigns the stack to the set slots in reverse, so the stack is `sel` reversed.
        var stack: [4]u8 = undefined;
        for (0..d) |i| stack[i] = self.sel[d - 1 - i];
        const terminated = d < self.n;

        const costs = stackCosts(stack[0..d], terminated);
        const raw = self.allow_raw and (costs.disp == null or costs.raw < costs.disp.?);
        if (!raw and costs.disp == null) return;
        const stack_cost = if (raw) costs.raw else costs.disp.?;

        const et_cost: usize = if (self.allow_raw and self.n > 0) 1 else 0;
        const cost = (if (self.seen) @as(usize, 4) else 0) + et_cost + stack_cost + self.npix * bpp;
        if (cost < self.best.cost) {
            self.best.* = .{
                .mask = self.mask,
                .v = v,
                .stack = stack,
                .d = d,
                .n = self.n,
                .raw = raw,
                .bpp = bpp,
                .cost = cost,
            };
        }
    }
};

/// Length of the DC6 scanline stream for the frame inside `b`: per row, transparent runs
/// (1 byte per 127 pixels) and opaque runs (1 byte + up to 127 indices), trailing
/// transparency dropped, one end-of-line byte. Matches every real DCC's CodedBytes.
fn dc6StreamLen(frame: []const u8, W: usize, dbox: Rect, b: Rect) u32 {
    const x0: usize = @intCast(b.left - dbox.left);
    const y0: usize = @intCast(b.top - dbox.top);
    const w: usize = @intCast(b.width);
    const h: usize = @intCast(b.height);
    var n: usize = 0;
    for (0..h) |y| {
        const row = frame[(y0 + y) * W + x0 ..][0..w];
        var x: usize = 0;
        while (x < w) {
            var gap: usize = 0;
            while (x + gap < w and row[x + gap] == 0) gap += 1;
            if (x + gap == w) break;
            n += (gap + 126) / 127;
            x += gap;
            var run: usize = 0;
            while (x + run < w and row[x + run] != 0 and run < 0x7f) run += 1;
            n += 1 + run;
            x += run;
        }
        n += 1;
    }
    return @intCast(@min(n, std.math.maxInt(u32)));
}

/// A displacement is written in 4-bit chunks; a chunk of 15 means "add 15 and read on".
fn writeDisplacement(alloc: std.mem.Allocator, w: *BitWriter, disp: u32) !void {
    var rem = disp;
    while (rem >= 15) : (rem -= 15) try w.bits(alloc, 15, 4);
    try w.bits(alloc, rem, 4);
}

fn fits(width: u8, range: [2]i64, signed: bool) bool {
    if (width >= 32) {
        if (signed) return range[0] >= std.math.minInt(i32) and range[1] <= std.math.maxInt(i32);
        return range[0] >= 0 and range[1] <= std.math.maxInt(u32);
    }
    if (width == 0) return range[0] == 0 and range[1] == 0;
    const span: i64 = @as(i64, 1) << @intCast(width);
    if (signed) return range[0] >= -@divExact(span, 2) and range[1] < @divExact(span, 2);
    return range[0] >= 0 and range[1] < span;
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;
const mpq = @import("mpq.zig");

/// Whether a test should print what it measured. Anything on stderr makes the build runner
/// report `failed command:`, so this is off unless `zig build test -Dverbose`. Referenced only
/// from tests, so a consumer of the library module never resolves the import.
fn verbose() bool {
    return @import("build_options").verbose;
}

const all_options = [_]Options{
    .{},
    .{ .strategy = .smallest },
    .{ .equal_cells = .off, .raw_pixels = .off },
    .{ .equal_cells = .on, .raw_pixels = .on },
    .{ .strategy = .smallest, .equal_cells = .on, .raw_pixels = .on },
    .{ .strategy = .smallest, .equal_cells = .off, .raw_pixels = .off },
};

/// A direction whose frames cover `boxes`, with `ctx.pixel(frame, x, y)` inside each box.
fn makeDirection(alloc: std.mem.Allocator, boxes: []const Rect, ctx: anytype) !Direction {
    var minx: i32 = std.math.maxInt(i32);
    var miny: i32 = std.math.maxInt(i32);
    var maxx: i32 = std.math.minInt(i32);
    var maxy: i32 = std.math.minInt(i32);
    for (boxes) |b| {
        minx = @min(minx, b.left);
        miny = @min(miny, b.top);
        maxx = @max(maxx, b.left + b.width);
        maxy = @max(maxy, b.top + b.height);
    }
    const dbox: Rect = .{ .left = minx, .top = miny, .width = maxx - minx, .height = maxy - miny };
    const W: usize = @intCast(dbox.width);
    const frames = try alloc.alloc([]u8, boxes.len);
    for (frames, boxes, 0..) |*fr, b, fi| {
        fr.* = try alloc.alloc(u8, W * @as(usize, @intCast(dbox.height)));
        @memset(fr.*, 0);
        var y = b.top;
        while (y < b.top + b.height) : (y += 1) {
            var x = b.left;
            while (x < b.left + b.width) : (x += 1) {
                fr.*[@as(usize, @intCast(y - dbox.top)) * W + @as(usize, @intCast(x - dbox.left))] = ctx.pixel(fi, x, y);
            }
        }
    }
    return .{ .box = dbox, .frames = frames, .frame_boxes = try alloc.dupe(Rect, boxes) };
}

fn makeDcc(alloc: std.mem.Allocator, dirs: []const Direction) !Dcc {
    return .{
        .directions = try alloc.dupe(Direction, dirs),
        .frames_per_dir = @intCast(dirs[0].frames.len),
        .allocator = alloc,
    };
}

fn expectSameSprite(want: *const Dcc, got: *const Dcc) !void {
    try testing.expectEqual(want.directions.len, got.directions.len);
    try testing.expectEqual(want.frames_per_dir, got.frames_per_dir);
    for (want.directions, got.directions) |a, b| {
        try testing.expectEqual(a.box, b.box);
        try testing.expectEqual(a.frames.len, b.frames.len);
        for (a.frames, b.frames) |fa, fb| try testing.expectEqualSlices(u8, fa, fb);
        try testing.expectEqual(a.frames.len, b.frame_boxes.len);
        for (b.frame_boxes, 0..) |fb, i| {
            try testing.expectEqual(if (a.frame_boxes.len != 0) a.frame_boxes[i] else a.box, fb);
        }
    }
}

/// Encode with every option set, decode, and require the same sprite back.
fn expectRoundTrip(sprite: *const Dcc) !void {
    for (all_options) |opts| {
        const bytes = try encodeWith(testing.allocator, sprite, opts);
        defer testing.allocator.free(bytes);
        var back = try dcc.parse(testing.allocator, bytes);
        defer back.deinit();
        try expectSameSprite(sprite, &back);
    }
}

/// Pixels from a per-frame 4-colour palette, so no cell can exceed 4 colours.
const PaletteCtx = struct {
    palettes: []const [4]u8,
    fn pixel(self: @This(), frame: usize, x: i32, y: i32) u8 {
        const k: usize = @intCast(@mod(x * 3 + y * 5 + @divFloor(x * y, 7), 4));
        return self.palettes[frame % self.palettes.len][k];
    }
};

test "encode: one direction, one frame" {
    const alloc = testing.allocator;
    const d = try makeDirection(alloc, &.{.{ .left = -3, .top = -4, .width = 7, .height = 5 }}, PaletteCtx{
        .palettes = &.{.{ 0, 17, 200, 255 }},
    });
    var sprite = try makeDcc(alloc, &.{d});
    defer sprite.deinit();
    try expectRoundTrip(&sprite);
}

test "encode: unaligned, partially overlapping frame boxes with transparent holes" {
    const alloc = testing.allocator;
    const boxes = [_]Rect{
        .{ .left = -5, .top = -9, .width = 7, .height = 6 },
        .{ .left = -2, .top = -7, .width = 9, .height = 4 },
        .{ .left = 1, .top = -12, .width = 3, .height = 11 },
        .{ .left = -6, .top = -3, .width = 1, .height = 1 },
        .{ .left = -1, .top = -10, .width = 5, .height = 5 },
    };
    const ctx = PaletteCtx{ .palettes = &.{ .{ 0, 3, 4, 90 }, .{ 250, 0, 7, 1 }, .{ 33, 34, 35, 36 }, .{ 0, 0, 0, 128 } } };
    var dirs: [2]Direction = undefined;
    dirs[0] = try makeDirection(alloc, &boxes, ctx);
    dirs[1] = try makeDirection(alloc, &.{ boxes[4], boxes[3], boxes[2], boxes[1], boxes[0] }, ctx);
    var sprite = try makeDcc(alloc, &dirs);
    defer sprite.deinit();
    try expectRoundTrip(&sprite);
}

test "encode: repeated frames are sent as EqualCells" {
    const alloc = testing.allocator;
    const box: Rect = .{ .left = -9, .top = -20, .width = 18, .height = 21 };
    const d = try makeDirection(alloc, &.{ box, box, box, box, box, box }, PaletteCtx{
        .palettes = &.{.{ 0, 40, 41, 160 }},
    });
    // One frame differs in a few pixels.
    d.frames[3][30] = 160;
    d.frames[3][31] = 40;
    var sprite = try makeDcc(alloc, &.{d});
    defer sprite.deinit();
    try expectRoundTrip(&sprite);

    const with_ec = try encodeWith(alloc, &sprite, .{ .equal_cells = .on });
    defer alloc.free(with_ec);
    const without = try encodeWith(alloc, &sprite, .{ .equal_cells = .off });
    defer alloc.free(without);
    try testing.expect(with_ec.len < without.len);
    const dir_at = std.mem.readInt(u32, with_ec[15..19], .little);
    try testing.expect(with_ec[dir_at + 4] & 2 != 0);
}

test "encode: a hand-built direction without frame boxes decodes with the direction box" {
    const alloc = testing.allocator;
    var d = try makeDirection(alloc, &.{
        .{ .left = 2, .top = -6, .width = 6, .height = 6 },
        .{ .left = 2, .top = -6, .width = 6, .height = 6 },
    }, PaletteCtx{ .palettes = &.{ .{ 0, 5, 6, 7 }, .{ 9, 0, 5, 6 } } });
    alloc.free(d.frame_boxes);
    d.frame_boxes = &.{};
    var sprite = try makeDcc(alloc, &.{d});
    defer sprite.deinit();
    try expectRoundTrip(&sprite);
}

test "encode: an opaque direction leaves colour 0 out of its palette bitmap" {
    const alloc = testing.allocator;
    // Two 4x4 cells, each exactly 4 non-zero colours.
    const d = try makeDirection(alloc, &.{.{ .left = 0, .top = -3, .width = 8, .height = 4 }}, struct {
        fn pixel(_: @This(), _: usize, x: i32, y: i32) u8 {
            return @intCast(10 + @mod(x + y, 4) + @as(i32, if (x >= 4) 100 else 0));
        }
    }{});
    var sprite = try makeDcc(alloc, &.{d});
    defer sprite.deinit();
    try expectRoundTrip(&sprite);
}

test "encode: refuses what a DCC cannot hold" {
    const alloc = testing.allocator;
    {
        const d = try makeDirection(alloc, &.{.{ .left = 0, .top = 0, .width = 4, .height = 4 }}, struct {
            fn pixel(_: @This(), _: usize, x: i32, _: i32) u8 {
                return @intCast(1 + x + (if (x == 0) @as(i32, 0) else 10));
            }
        }{});
        d.frames[0][15] = 99; // a fifth colour
        var sprite = try makeDcc(alloc, &.{d});
        defer sprite.deinit();
        try testing.expectError(error.TooManyColoursInCell, encode(alloc, &sprite));
    }
    {
        const d = try makeDirection(alloc, &.{
            .{ .left = 0, .top = 0, .width = 8, .height = 8 },
            .{ .left = 0, .top = 0, .width = 3, .height = 3 },
        }, PaletteCtx{ .palettes = &.{.{ 0, 1, 2, 3 }} });
        d.frames[1][7 * 8 + 7] = 1; // outside frame 1's box
        var sprite = try makeDcc(alloc, &.{d});
        defer sprite.deinit();
        try testing.expectError(error.PixelOutsideFrameBox, encode(alloc, &sprite));
    }
    {
        var d = try makeDirection(alloc, &.{.{ .left = 0, .top = 0, .width = 8, .height = 8 }}, PaletteCtx{ .palettes = &.{.{ 0, 1, 2, 3 }} });
        d.frame_boxes[0].width = 7; // union no longer the direction box
        var sprite = try makeDcc(alloc, &.{d});
        defer sprite.deinit();
        try testing.expectError(error.BoxMismatch, encode(alloc, &sprite));
    }
}

// Random frames: per-frame 4-colour palettes over a wide colour range (large entry indices,
// so raw values get used), frames that repeat the previous box and palette (EqualCells,
// masks against the previous entry), scribbles, and boxes off the 4-pixel grid.
test "encode: randomised sprites round-trip under every option set" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDCC0_2026);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 40) : (round += 1) {
        const ndir = rnd.intRangeAtMost(usize, 1, 3);
        const fpd = rnd.intRangeAtMost(usize, 1, 7);
        const dirs = try alloc.alloc(Direction, ndir);
        defer alloc.free(dirs);
        for (dirs) |*dir| {
            const boxes = try alloc.alloc(Rect, fpd);
            defer alloc.free(boxes);
            const palettes = try alloc.alloc([4]u8, fpd);
            defer alloc.free(palettes);
            for (boxes, palettes, 0..) |*b, *p, fi| {
                const repeat = fi > 0 and rnd.uintLessThan(u8, 3) == 0;
                b.* = if (repeat) boxes[fi - 1] else .{
                    .left = rnd.intRangeAtMost(i32, -20, 12),
                    .top = rnd.intRangeAtMost(i32, -30, 4),
                    .width = rnd.intRangeAtMost(i32, 1, 23),
                    .height = rnd.intRangeAtMost(i32, 1, 19),
                };
                if (repeat) {
                    p.* = palettes[fi - 1];
                } else for (p) |*c| {
                    c.* = if (rnd.uintLessThan(u8, 4) == 0) 0 else rnd.int(u8);
                }
            }
            dir.* = try makeDirection(alloc, boxes, PaletteCtx{ .palettes = palettes });
            // Scribble on some frames with their own palette, so cells change between frames.
            for (dir.frames, boxes, palettes) |fr, b, p| {
                if (rnd.boolean()) continue;
                const W: usize = @intCast(dir.box.width);
                var n = rnd.uintLessThan(usize, 12);
                while (n > 0) : (n -= 1) {
                    const x: usize = @intCast(b.left - dir.box.left + rnd.intRangeLessThan(i32, 0, b.width));
                    const y: usize = @intCast(b.top - dir.box.top + rnd.intRangeLessThan(i32, 0, b.height));
                    fr[y * W + x] = p[rnd.uintLessThan(usize, 4)];
                }
            }
        }
        var sprite = try makeDcc(alloc, dirs);
        defer sprite.deinit();
        try expectRoundTrip(&sprite);
    }
}

/// The game folder from `D2_DIR`, or null (the real-file tests then skip). Caller frees.
fn d2Dir(alloc: std.mem.Allocator) ?[]u8 {
    return testing.environ.getAlloc(alloc, "D2_DIR") catch null;
}

/// Game DCCs across units, missiles, overlays and objects. The last seven have cells an
/// EqualCell copy fills with more than 4 colours.
const shipped_dccs = [_][]const u8{
    "data\\global\\missiles\\BloodLarge02.dcc",
    "data\\global\\missiles\\Expansion\\hurricane_rocks.dcc",
    "data\\global\\missiles\\Extra\\FireArrowExplode.dcc",
    "data\\global\\missiles\\icestormfallvar03.dcc",
    "data\\global\\overlays\\Expansion\\CycloneArmorABack.dcc",
    "data\\global\\overlays\\ThunderstormCast.dcc",
    "data\\global\\objects\\3a\\tr\\3atrlitonhth.dcc",
    "data\\global\\objects\\62\\TR\\62trlits1hth.dcc",
    "data\\global\\objects\\8b\\tr\\8btrlitophth.dcc",
    "data\\global\\objects\\BP\\tr\\bptrlitONhth.dcc",
    "data\\global\\monsters\\0A\\HD\\0AHDFHMWL2HS.dcc",
    "data\\global\\monsters\\BT\\TR\\BTTRLITS4HTH.dcc",
    "data\\global\\monsters\\EH\\tr\\ehtrlits3hth.dcc",
    "data\\global\\monsters\\M1\\tr\\M1TRLITNUHTH.dcc",
    "data\\global\\monsters\\TH\\RA\\THRALITGHHTH.dcc",
    "data\\global\\monsters\\ZZ\\Hd\\ZZHDHD2NUHTH.dcc",
    "data\\global\\CHARS\\AI\\HD\\AIHDBHMA11HS.dcc",
    "data\\global\\CHARS\\AI\\LH\\AILHSKRSCHT2.dcc",
    "data\\global\\CHARS\\AI\\RH\\AIRHOPLS31HT.dcc",
    "data\\global\\CHARS\\DZ\\LA\\DZLAMEDSCXBW.dcc",
    "data\\global\\CHARS\\DZ\\SH\\DZSHKITA11HT.dcc",
    "data\\global\\CHARS\\AI\\LA\\AILAHVYNU2HS.dcc",
    "data\\global\\CHARS\\DZ\\RA\\DZRAMEDRN1HT.dcc",
    "data\\global\\CHARS\\DZ\\RH\\DZRHDGRNU1HT.dcc",
    "data\\global\\chars\\SO\\TR\\SOTRLITNUHTH.dcc",
    "data\\global\\chars\\BA\\TR\\BATRLITNUHTH.dcc",
    "data\\global\\chars\\NE\\TR\\NETRLITNUHTH.dcc",
    "data\\global\\chars\\am\\lg\\amlglita1bow.dcc",
    "data\\global\\chars\\am\\rh\\amrhhxbnuxbw.dcc",
    "data\\global\\chars\\ba\\hd\\bahdcaptnhth.dcc",
    "data\\global\\chars\\ba\\ra\\barahvynuhth.dcc",
    "data\\global\\chars\\pa\\rh\\parhwndtn1hs.dcc",
    "data\\global\\chars\\so\\ra\\sorahvytn1ht.dcc",
    "data\\global\\chars\\so\\rh\\sorhlaxrnstf.dcc",
};

/// Round-trips through the other strategy too, but are not byte-identical by default.
const shipped_not_identical = [_][]const u8{
    "data\\global\\CHARS\\DZ\\LA\\DZLAMEDA1BOW.dcc",
};

test "encode: shipped DCCs re-encode byte-identical and round-trip" {
    const alloc = testing.allocator;
    const dir = d2Dir(alloc) orelse return;
    defer alloc.free(dir);

    var set: mpq.Set = .{};
    defer set.deinit(alloc);
    var archives: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (archives.items) |a| alloc.free(a);
        archives.deinit(alloc);
    }
    for ([_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq", "d2char.mpq" }) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        defer alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, alloc, .limited(512 << 20)) catch continue;
        archives.append(alloc, bytes) catch |e| {
            alloc.free(bytes);
            return e;
        };
        try set.add(alloc, bytes);
    }
    if (set.archives.items.len == 0) return; // no install: skip

    var tested: usize = 0;
    var original_bytes: usize = 0;
    var smallest_bytes: usize = 0;
    for (shipped_dccs ++ shipped_not_identical, 0..) |name, i| {
        if (!set.has(name)) continue;
        const bytes = try set.read(alloc, name);
        defer alloc.free(bytes);
        var sprite = try dcc.parse(alloc, bytes);
        defer sprite.deinit();

        const again = try encode(alloc, &sprite);
        defer alloc.free(again);
        if (i < shipped_dccs.len) try testing.expectEqualSlices(u8, bytes, again);
        var back = try dcc.parse(alloc, again);
        defer back.deinit();
        try expectSameSprite(&sprite, &back);

        const small = try encodeWith(alloc, &sprite, .{ .strategy = .smallest, .equal_cells = .auto, .raw_pixels = .auto });
        defer alloc.free(small);
        var back_small = try dcc.parse(alloc, small);
        defer back_small.deinit();
        try expectSameSprite(&sprite, &back_small);

        tested += 1;
        original_bytes += bytes.len;
        smallest_bytes += small.len;
    }
    if (verbose()) std.debug.print("shipped DCCs: {d} round-tripped, smallest strategy {d} / {d} bytes\n", .{ tested, smallest_bytes, original_bytes });
    // With the three main archives present every listed file must be found.
    if (set.archives.items.len == 4) try testing.expectEqual(shipped_dccs.len + shipped_not_identical.len, tested);
}
