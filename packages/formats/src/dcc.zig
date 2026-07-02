//! DCC sprite decoder — Diablo II's compressed, non-byte-aligned bitstream sprite
//! format (used for units: players, monsters, objects, missiles). Faithful port of
//! OpenDiablo2's decoder (d2common/d2fileformats/d2dcc: dcc.go, dcc_direction.go,
//! dcc_direction_frame.go, dcc_cell.go, dcc_pixel_buffer_entry.go) cross-checked
//! against the Phrozen Keep / Paul Siramy DCC format notes.
//!
//! A DCC holds N directions, each with F frames. Every frame decodes to a buffer of
//! palette indices laid out in the DIRECTION's bounding box (so all frames/cells in
//! one direction share an origin). `index 0 = transparent`. Apply an act palette
//! (768-byte B,G,R) to get RGBA — see objgfx.compositeToRgba / dc6.frameToRgba.
//!
//! Bit order matches OD2's BitMuncher: bits are consumed LSB-first within each byte.

const std = @import("std");

pub const Rect = struct { left: i32, top: i32, width: i32, height: i32 };

/// One decoded direction: `box` is the direction bounding box (sprite-local
/// coords, object pivot at 0,0); each frame is box.width*box.height palette indices.
pub const Direction = struct {
    box: Rect,
    /// frames[f] = box.width*box.height indices, row-major, top-down. 0 = transparent.
    frames: [][]u8,
};

pub const Dcc = struct {
    directions: []Direction,
    frames_per_dir: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dcc) void {
        for (self.directions) |d| {
            for (d.frames) |f| self.allocator.free(f);
            self.allocator.free(d.frames);
        }
        self.allocator.free(self.directions);
    }
};

const DCC_SIGNATURE = 0x74;
const DIR_OFFSET_MULT = 8;
const CELLS_PER_ROW = 4;

// crazyBitTable: 4-bit index -> actual field bit-width.
const CRAZY_BIT_TABLE = [16]u8{ 0, 1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 26, 28, 30, 32 };
// pixelMaskLookup: 4-bit mask -> popcount (number of encoded pixel values).
const PIXEL_MASK_LOOKUP = [16]u8{ 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 };

/// LSB-first bit reader over a byte slice; bit position tracked in bits.
const BitMuncher = struct {
    data: []const u8,
    offset: usize, // in bits
    bits_read: usize = 0,

    fn init(data: []const u8, bit_offset: usize) BitMuncher {
        return .{ .data = data, .offset = bit_offset, .bits_read = 0 };
    }
    /// A copy positioned at the same offset with its own zeroed bits_read counter.
    fn copy(self: BitMuncher) BitMuncher {
        return .{ .data = self.data, .offset = self.offset, .bits_read = 0 };
    }
    fn getBit(self: *BitMuncher) u32 {
        const byte_i = self.offset / 8;
        const b: u32 = if (byte_i < self.data.len) self.data[byte_i] else 0;
        const r = (b >> @intCast(self.offset % 8)) & 1;
        self.offset += 1;
        self.bits_read += 1;
        return r;
    }
    fn getBits(self: *BitMuncher, bits: u6) u32 {
        if (bits == 0) return 0;
        var result: u32 = 0;
        var i: u6 = 0;
        while (i < bits) : (i += 1) result |= self.getBit() << @intCast(i);
        return result;
    }
    fn getSignedBits(self: *BitMuncher, bits: u6) i32 {
        return makeSigned(self.getBits(bits), bits);
    }
    fn getByte(self: *BitMuncher) u8 {
        return @intCast(self.getBits(8));
    }
    fn getU32(self: *BitMuncher) u32 {
        return self.getBits(32);
    }
    fn getI32(self: *BitMuncher) i32 {
        return @bitCast(self.getBits(32));
    }
    fn skipBits(self: *BitMuncher, bits: usize) void {
        self.offset += bits;
        self.bits_read += bits;
    }
};

/// Two's-complement sign extension. Matches OD2 MakeSigned incl. the 1-bit case
/// (a set single bit reads as -1).
fn makeSigned(value: u32, bits: u6) i32 {
    if (bits == 0) return 0;
    const sign_bit: u32 = @as(u32, 1) << @intCast(bits - 1);
    if (value & sign_bit == 0) return @bitCast(value);
    // Negative: subtract 2^bits (guard bits==32 where 1<<32 overflows u32).
    if (bits >= 32) return @bitCast(value);
    const span: i64 = @as(i64, 1) << @intCast(bits);
    return @intCast(@as(i64, value) - span);
}

const Cell = struct {
    w: i32,
    h: i32,
    xoff: i32,
    yoff: i32,
    last_w: i32 = -1,
    last_h: i32 = -1,
    last_xoff: i32 = 0,
    last_yoff: i32 = 0,
};

const PixelBufferEntry = struct {
    value: [4]u8 = .{ 0, 0, 0, 0 },
    frame: i32 = -1,
    frame_cell_index: i32 = -1,
};

const FrameHeader = struct {
    box: Rect,
    width: i32,
    height: i32,
    xoffset: i32,
    yoffset: i32,
    h_cells: i32 = 0,
    v_cells: i32 = 0,
    cells: []Cell = &.{},
};

/// Parse a whole DCC into per-direction, per-frame palette-index buffers.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Dcc {
    var bm = BitMuncher.init(bytes, 0);
    if (bm.getByte() != DCC_SIGNATURE) return error.InvalidDcc;
    _ = bm.getByte(); // version
    const ndir = bm.getByte();
    const frames_per_dir: u32 = @bitCast(bm.getI32());
    if (bm.getI32() != 1) return error.InvalidDcc;
    _ = bm.getI32(); // TotalSizeCoded

    if (ndir == 0 or frames_per_dir == 0) return error.InvalidDcc;

    const dir_offsets = try alloc.alloc(u32, ndir);
    defer alloc.free(dir_offsets);
    for (dir_offsets) |*o| o.* = @bitCast(bm.getI32());

    var directions = try alloc.alloc(Direction, ndir);
    var built: usize = 0;
    errdefer {
        for (directions[0..built]) |d| {
            for (d.frames) |f| alloc.free(f);
            alloc.free(d.frames);
        }
        alloc.free(directions);
    }

    for (dir_offsets, 0..) |off, i| {
        directions[i] = try decodeDirection(alloc, bytes, off * DIR_OFFSET_MULT, frames_per_dir);
        built += 1;
    }

    return .{ .directions = directions, .frames_per_dir = frames_per_dir, .allocator = alloc };
}

fn decodeDirection(alloc: std.mem.Allocator, bytes: []const u8, bit_offset: usize, frames_per_dir: u32) !Direction {
    var bm = BitMuncher.init(bytes, bit_offset);

    _ = bm.getU32(); // OutSizeCoded
    const compression_flags = bm.getBits(2);
    const variable0_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const width_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const height_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const xoffset_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const yoffset_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const optional_bits = CRAZY_BIT_TABLE[bm.getBits(4)];
    const coded_bytes_bits = CRAZY_BIT_TABLE[bm.getBits(4)];

    const frames = try alloc.alloc(FrameHeader, frames_per_dir);
    defer {
        for (frames) |fr| if (fr.cells.len > 0) alloc.free(fr.cells);
        alloc.free(frames);
    }

    var minx: i32 = 100000;
    var miny: i32 = 100000;
    var maxx: i32 = -100000;
    var maxy: i32 = -100000;

    for (frames) |*fr| {
        _ = bm.getBits(@intCast(variable0_bits)); // Variable0
        const width = @as(i32, @intCast(bm.getBits(@intCast(width_bits))));
        const height = @as(i32, @intCast(bm.getBits(@intCast(height_bits))));
        const xoffset = bm.getSignedBits(@intCast(xoffset_bits));
        const yoffset = bm.getSignedBits(@intCast(yoffset_bits));
        _ = bm.getBits(@intCast(optional_bits)); // NumberOfOptionalBytes
        _ = bm.getBits(@intCast(coded_bytes_bits)); // NumberOfCodedBytes
        const bottom_up = bm.getBit() == 1;
        if (bottom_up) return error.BottomUpUnsupported;

        const box: Rect = .{ .left = xoffset, .top = yoffset - height + 1, .width = width, .height = height };
        fr.* = .{ .box = box, .width = width, .height = height, .xoffset = xoffset, .yoffset = yoffset };

        minx = @min(minx, box.left);
        miny = @min(miny, box.top);
        maxx = @max(maxx, box.left + box.width); // Right()
        maxy = @max(maxy, box.top + box.height); // Bottom()
    }

    const dbox: Rect = .{ .left = minx, .top = miny, .width = maxx - minx, .height = maxy - miny };
    if (dbox.width <= 0 or dbox.height <= 0) return error.InvalidDcc;

    if (optional_bits > 0) return error.OptionalDataUnsupported;

    var equal_cells_size: usize = 0;
    if (compression_flags & 0x2 != 0) equal_cells_size = bm.getBits(20);
    const pixel_mask_size: usize = bm.getBits(20);
    var encoding_type_size: usize = 0;
    var raw_pixel_size: usize = 0;
    if (compression_flags & 0x1 != 0) {
        encoding_type_size = bm.getBits(20);
        raw_pixel_size = bm.getBits(20);
    }

    var palette_entries: [256]u8 = undefined;
    var pal_count: usize = 0;
    {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            if (bm.getBit() != 0) {
                palette_entries[pal_count] = @intCast(i);
                pal_count += 1;
            }
        }
    }

    // Bit-exact sub-streams positioned back-to-back after the palette bitmap.
    var ec = bm.copy();
    bm.skipBits(equal_cells_size);
    var pm = bm.copy();
    bm.skipBits(pixel_mask_size);
    var et = bm.copy();
    bm.skipBits(encoding_type_size);
    var rp = bm.copy();
    bm.skipBits(raw_pixel_size);
    var pcd = bm.copy();

    // Direction cell grid.
    const h_cells: i32 = 1 + @divTrunc(dbox.width - 1, CELLS_PER_ROW);
    const v_cells: i32 = 1 + @divTrunc(dbox.height - 1, CELLS_PER_ROW);
    const dir_cells = try alloc.alloc(Cell, @intCast(h_cells * v_cells));
    defer alloc.free(dir_cells);
    buildDirectionCells(dir_cells, dbox, h_cells, v_cells);

    // Per-frame cell grids.
    for (frames) |*fr| try recalcFrameCells(alloc, fr, dbox);

    // Pixel buffer.
    const pixel_buffer = try fillPixelBuffer(alloc, &ec, &pm, &et, &rp, &pcd, frames, dir_cells, dbox, h_cells, v_cells, equal_cells_size, encoding_type_size, palette_entries);
    defer alloc.free(pixel_buffer);

    // Generate the per-frame index bitmaps (direction-box sized).
    const out_frames = try generateFrames(alloc, &pcd, frames, dir_cells, pixel_buffer, dbox, h_cells);

    return .{ .box = dbox, .frames = out_frames };
}

fn buildDirectionCells(cells: []Cell, dbox: Rect, h_cells: i32, v_cells: i32) void {
    const hc: usize = @intCast(h_cells);
    const vc: usize = @intCast(v_cells);
    var widths = [_]i32{0} ** 1024;
    var heights = [_]i32{0} ** 1024;
    if (hc == 1) {
        widths[0] = dbox.width;
    } else {
        var i: usize = 0;
        while (i < hc - 1) : (i += 1) widths[i] = 4;
        widths[hc - 1] = dbox.width - 4 * @as(i32, @intCast(hc - 1));
    }
    if (vc == 1) {
        heights[0] = dbox.height;
    } else {
        var i: usize = 0;
        while (i < vc - 1) : (i += 1) heights[i] = 4;
        heights[vc - 1] = dbox.height - 4 * @as(i32, @intCast(vc - 1));
    }
    var yoff: i32 = 0;
    var y: usize = 0;
    while (y < vc) : (y += 1) {
        var xoff: i32 = 0;
        var x: usize = 0;
        while (x < hc) : (x += 1) {
            cells[x + y * hc] = .{ .w = widths[x], .h = heights[y], .xoff = xoff, .yoff = yoff };
            xoff += 4;
        }
        yoff += 4;
    }
}

fn recalcFrameCells(alloc: std.mem.Allocator, fr: *FrameHeader, dbox: Rect) !void {
    const w0 = 4 - @mod(fr.box.left - dbox.left, 4); // first-column width
    if (fr.width - w0 <= 1) {
        fr.h_cells = 1;
    } else {
        const tmp = fr.width - w0 - 1;
        fr.h_cells = 2 + @divTrunc(tmp, 4);
        if (@mod(tmp, 4) == 0) fr.h_cells -= 1;
    }
    const h0 = 4 - @mod(fr.box.top - dbox.top, 4); // first-row height
    if (fr.height - h0 <= 1) {
        fr.v_cells = 1;
    } else {
        const tmp = fr.height - h0 - 1;
        fr.v_cells = 2 + @divTrunc(tmp, 4);
        if (@mod(tmp, 4) == 0) fr.v_cells -= 1;
    }

    const hc: usize = @intCast(fr.h_cells);
    const vc: usize = @intCast(fr.v_cells);
    var widths = try alloc.alloc(i32, hc);
    defer alloc.free(widths);
    var heights = try alloc.alloc(i32, vc);
    defer alloc.free(heights);

    if (hc == 1) {
        widths[0] = fr.width;
    } else {
        widths[0] = w0;
        var i: usize = 1;
        while (i < hc - 1) : (i += 1) widths[i] = 4;
        widths[hc - 1] = fr.width - w0 - 4 * @as(i32, @intCast(hc - 2));
    }
    if (vc == 1) {
        heights[0] = fr.height;
    } else {
        heights[0] = h0;
        var i: usize = 1;
        while (i < vc - 1) : (i += 1) heights[i] = 4;
        heights[vc - 1] = fr.height - h0 - 4 * @as(i32, @intCast(vc - 2));
    }

    fr.cells = try alloc.alloc(Cell, hc * vc);
    var offy = fr.box.top - dbox.top;
    var y: usize = 0;
    while (y < vc) : (y += 1) {
        var offx = fr.box.left - dbox.left;
        var x: usize = 0;
        while (x < hc) : (x += 1) {
            fr.cells[x + y * hc] = .{ .w = widths[x], .h = heights[y], .xoff = offx, .yoff = offy };
            offx += widths[x];
        }
        offy += heights[y];
    }
}

fn fillPixelBuffer(
    alloc: std.mem.Allocator,
    ec: *BitMuncher,
    pm: *BitMuncher,
    et: *BitMuncher,
    rp: *BitMuncher,
    pcd: *BitMuncher,
    frames: []FrameHeader,
    dir_cells: []Cell,
    dbox: Rect,
    h_cells: i32,
    v_cells: i32,
    equal_cells_size: usize,
    encoding_type_size: usize,
    palette_entries: [256]u8,
) ![]PixelBufferEntry {
    _ = dir_cells;
    var max_cell_x: usize = 0;
    var max_cell_y: usize = 0;
    for (frames) |fr| {
        max_cell_x += @intCast(fr.h_cells);
        max_cell_y += @intCast(fr.v_cells);
    }

    const pixel_buffer = try alloc.alloc(PixelBufferEntry, max_cell_x * max_cell_y);
    for (pixel_buffer) |*e| e.* = .{ .value = .{ 0, 0, 0, 0 }, .frame = -1, .frame_cell_index = -1 };

    // cellBuffer: the direction grid, tracking the last pixel-buffer entry per cell.
    const grid = try alloc.alloc(?usize, @intCast(h_cells * v_cells));
    defer alloc.free(grid);
    @memset(grid, null);

    var frame_index: i32 = -1;
    var pb_index: i32 = -1;
    var pixel_mask: u32 = 0;

    for (frames) |fr| {
        frame_index += 1;
        const origin_cx = @divTrunc(fr.box.left - dbox.left, CELLS_PER_ROW);
        const origin_cy = @divTrunc(fr.box.top - dbox.top, CELLS_PER_ROW);

        var cy: i32 = 0;
        while (cy < fr.v_cells) : (cy += 1) {
            const cur_cy = cy + origin_cy;
            var cx: i32 = 0;
            while (cx < fr.h_cells) : (cx += 1) {
                const current_cell: usize = @intCast(origin_cx + cx + cur_cy * h_cells);
                var next_cell = false;

                if (grid[current_cell] != null) {
                    var tmp: u32 = 0;
                    if (equal_cells_size > 0) tmp = ec.getBit();
                    if (tmp == 0) {
                        pixel_mask = pm.getBits(4);
                    } else {
                        next_cell = true;
                    }
                } else {
                    pixel_mask = 0x0F;
                }
                if (next_cell) continue;

                var pixel_stack = [4]u32{ 0, 0, 0, 0 };
                var last_pixel: u32 = 0;
                const num_pixel_bits = PIXEL_MASK_LOOKUP[pixel_mask];
                var encoding_type: u32 = 0;
                if (num_pixel_bits != 0 and encoding_type_size > 0) encoding_type = et.getBit();

                var decoded_pixel: i32 = 0;
                var i: usize = 0;
                while (i < num_pixel_bits) : (i += 1) {
                    if (encoding_type != 0) {
                        pixel_stack[i] = rp.getBits(8);
                    } else {
                        pixel_stack[i] = last_pixel;
                        var disp = pcd.getBits(4);
                        pixel_stack[i] +%= disp;
                        while (disp == 15) {
                            disp = pcd.getBits(4);
                            pixel_stack[i] +%= disp;
                        }
                    }
                    if (pixel_stack[i] == last_pixel) {
                        pixel_stack[i] = 0;
                        break;
                    } else {
                        last_pixel = pixel_stack[i];
                        decoded_pixel += 1;
                    }
                }

                const old_entry = grid[current_cell];
                pb_index += 1;
                const pbi: usize = @intCast(pb_index);
                var cur_idx: i32 = decoded_pixel - 1;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    if (pixel_mask & (@as(u32, 1) << @intCast(k)) != 0) {
                        if (cur_idx >= 0) {
                            pixel_buffer[pbi].value[k] = @intCast(pixel_stack[@intCast(cur_idx)]);
                            cur_idx -= 1;
                        } else {
                            pixel_buffer[pbi].value[k] = 0;
                        }
                    } else {
                        pixel_buffer[pbi].value[k] = pixel_buffer[old_entry.?].value[k];
                    }
                }
                grid[current_cell] = pbi;
                pixel_buffer[pbi].frame = frame_index;
                pixel_buffer[pbi].frame_cell_index = cx + cy * fr.h_cells;
            }
        }
    }

    // Map present-index values through the palette-entry table.
    var i: i32 = 0;
    while (i <= pb_index) : (i += 1) {
        const pbi: usize = @intCast(i);
        var x: usize = 0;
        while (x < 4) : (x += 1) pixel_buffer[pbi].value[x] = palette_entries[pixel_buffer[pbi].value[x]];
    }

    return pixel_buffer;
}

fn generateFrames(
    alloc: std.mem.Allocator,
    pcd: *BitMuncher,
    frames: []FrameHeader,
    dir_cells: []Cell,
    pixel_buffer: []PixelBufferEntry,
    dbox: Rect,
    h_cells: i32,
) ![][]u8 {
    for (dir_cells) |*c| {
        c.last_w = -1;
        c.last_h = -1;
    }
    const bw: usize = @intCast(dbox.width);
    const bh: usize = @intCast(dbox.height);

    const pix_data = try alloc.alloc(u8, bw * bh); // direction accumulator
    defer alloc.free(pix_data);
    @memset(pix_data, 0);

    const out = try alloc.alloc([]u8, frames.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |f| alloc.free(f);
        alloc.free(out);
    }

    var pb_idx: usize = 0;
    var frame_index: i32 = -1;
    for (frames) |fr| {
        frame_index += 1;
        const fbuf = try alloc.alloc(u8, bw * bh);
        @memset(fbuf, 0);

        var c: i32 = -1;
        for (fr.cells) |cell| {
            c += 1;
            const cell_x = @divTrunc(cell.xoff, CELLS_PER_ROW);
            const cell_y = @divTrunc(cell.yoff, CELLS_PER_ROW);
            const cell_index: usize = @intCast(cell_x + cell_y * h_cells);
            var buffer_cell = &dir_cells[cell_index];
            const pbe = pixel_buffer[pb_idx];

            const cw: usize = @intCast(cell.w);
            const ch: usize = @intCast(cell.h);
            const cxo: usize = @intCast(cell.xoff);
            const cyo: usize = @intCast(cell.yoff);

            if (pbe.frame != frame_index or pbe.frame_cell_index != c) {
                // EqualCell reference: copy old cell or clear.
                if (cell.w != buffer_cell.last_w or cell.h != buffer_cell.last_h) {
                    var y: usize = 0;
                    while (y < ch) : (y += 1) {
                        var x: usize = 0;
                        while (x < cw) : (x += 1) pix_data[x + cxo + (y + cyo) * bw] = 0;
                    }
                } else {
                    const lxo: usize = @intCast(buffer_cell.last_xoff);
                    const lyo: usize = @intCast(buffer_cell.last_yoff);
                    var fy: usize = 0;
                    while (fy < ch) : (fy += 1) {
                        var fx: usize = 0;
                        while (fx < cw) : (fx += 1)
                            pix_data[fx + cxo + (fy + cyo) * bw] = pix_data[fx + lxo + (fy + lyo) * bw];
                    }
                    fy = 0;
                    while (fy < ch) : (fy += 1) {
                        var fx: usize = 0;
                        while (fx < cw) : (fx += 1)
                            fbuf[fx + cxo + (fy + cyo) * bw] = pix_data[cxo + fx + (cyo + fy) * bw];
                    }
                }
            } else {
                if (pbe.value[0] == pbe.value[1]) {
                    var y: usize = 0;
                    while (y < ch) : (y += 1) {
                        var x: usize = 0;
                        while (x < cw) : (x += 1) pix_data[x + cxo + (y + cyo) * bw] = pbe.value[0];
                    }
                } else {
                    var bits_to_read: u6 = 1;
                    if (pbe.value[1] != pbe.value[2]) bits_to_read = 2;
                    var y: usize = 0;
                    while (y < ch) : (y += 1) {
                        var x: usize = 0;
                        while (x < cw) : (x += 1) {
                            const pi = pcd.getBits(bits_to_read);
                            pix_data[x + cxo + (y + cyo) * bw] = pbe.value[@intCast(pi)];
                        }
                    }
                }
                var fy: usize = 0;
                while (fy < ch) : (fy += 1) {
                    var fx: usize = 0;
                    while (fx < cw) : (fx += 1)
                        fbuf[fx + cxo + (fy + cyo) * bw] = pix_data[fx + cxo + (fy + cyo) * bw];
                }
                pb_idx += 1;
            }

            buffer_cell.last_w = cell.w;
            buffer_cell.last_h = cell.h;
            buffer_cell.last_xoff = cell.xoff;
            buffer_cell.last_yoff = cell.yoff;
        }

        out[frame_index_usize(frame_index)] = fbuf;
        built += 1;
    }
    return out;
}

fn frame_index_usize(i: i32) usize {
    return @intCast(i);
}
