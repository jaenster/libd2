//! HD pack: replacement index images for sprite frames, filed under each frame's `framekey`.
//!
//! A pack holds, for every original frame it covers, the frame's bounding box (see `framekey`) at
//! `scale` times its size: the same palette indices, drawn larger by some upscaler. A renderer
//! that decodes a frame computes its key and box, looks them up, and places the stored image at
//! the box origin times `scale` in its enlarged buffer.
//!
//! Layout, all integers little-endian. Version 2, the one `encode` writes by default:
//!
//!     "D2HD"  u32 version (2)  u32 scale  u32 count                    16 bytes
//!     count x { u64 key, u16 bw, u16 bh, u32 offset, u32 length }     20 bytes each
//!     image data
//!
//! Version 1, the original raw form:
//!
//!     "D2HD"  u32 version (1)  u32 scale  u32 count                    16 bytes
//!     count x { u64 key, u16 bw, u16 bh, u32 offset }                 16 bytes each
//!     image data
//!
//! In both, the table is sorted by (key, bw, bh) and a (key, bw, bh) appears at most once. `bw` x
//! `bh` is the box at 1x; the entry's image is `bw*scale` x `bh*scale` indices, top row first. The
//! width and height take part in a lookup, so two frames whose keys collide but whose boxes differ
//! are told apart. `offset` counts from the start of the file.
//!
//! In version 1 the image is stored as-is, `bw*scale * bh*scale` bytes at `offset`.
//!
//! In version 2 an entry stores `length` bytes at `offset`, in one of two forms, told apart by the
//! length alone:
//!
//!   - `length == bw*scale * bh*scale`: the image itself, raw. The writer does this when zlib
//!     would not make the image smaller.
//!   - any other length: a zlib stream (RFC 1950: two-byte header, deflate, Adler-32 of the image,
//!     big-endian) that inflates to exactly `bw*scale * bh*scale` bytes. The writer uses it only
//!     when it is strictly shorter than the image.
//!
//! Entries whose images are byte-identical may share one stored copy: the same offset and length.
//! Offsets are u32, so a pack is at most 4 GiB - 1 bytes; a set that would not fit is split into
//! several packs.
//!
//! Reading, lookup and inflating are allocation-free and libc-free; writing takes an allocator.

const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;

pub const magic = "D2HD";
/// The version `encode` writes unless told otherwise.
pub const version: u32 = 2;
pub const header_len: usize = 16;
pub const entry_len_v1: usize = 16;
pub const entry_len_v2: usize = 20;
/// Scales a pack may declare.
pub const max_scale: u32 = 16;
/// The largest pack the format can address: offsets and lengths are u32.
pub const max_file_len: u64 = std.math.maxInt(u32);

pub const Error = error{ NotHdPack, UnsupportedVersion, BadScale, Truncated, Unsorted, BadEntry };

pub const Header = struct {
    version: u32,
    scale: u32,
    count: u32,
};

pub fn entryLen(v: u32) usize {
    return if (v == 1) entry_len_v1 else entry_len_v2;
}

/// The header alone: magic, a known version, scale, and an entry table that fits in `bytes`.
/// Constant time, so a lookup can afford it on every call.
pub fn header(bytes: []const u8) Error!Header {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotHdPack;
    const v = rd32(bytes, 4);
    if (v != 1 and v != 2) return error.UnsupportedVersion;
    const scale = rd32(bytes, 8);
    if (scale < 1 or scale > max_scale) return error.BadScale;
    const count = rd32(bytes, 12);
    if (@as(u64, count) * entryLen(v) > bytes.len - header_len) return error.Truncated;
    return .{ .version = v, .scale = scale, .count = count };
}

pub const Entry = struct {
    key: u64,
    bw: u16,
    bh: u16,
    offset: u32,
    /// The stored byte count. In a version 1 pack, always the image size.
    length: u64,
};

/// Entry `i` of the table `h` describes; `i < h.count` and the table inside `bytes` (as `header`
/// checks).
pub fn entryAt(bytes: []const u8, h: Header, i: usize) Entry {
    const e = bytes[header_len + i * entryLen(h.version) ..][0..entryLen(h.version)];
    const bw = std.mem.readInt(u16, e[8..10], .little);
    const bh = std.mem.readInt(u16, e[10..12], .little);
    return .{
        .key = std.mem.readInt(u64, e[0..8], .little),
        .bw = bw,
        .bh = bh,
        .offset = std.mem.readInt(u32, e[12..16], .little),
        .length = if (h.version == 1) imageLen(h.scale, bw, bh) else std.mem.readInt(u32, e[16..20], .little),
    };
}

/// The size of an entry's image: `bw*scale * bh*scale`.
pub fn imageLen(scale: u32, bw: u16, bh: u16) u64 {
    return @as(u64, bw) * scale * @as(u64, bh) * scale;
}

fn order(ak: u64, aw: u16, ah: u16, bk: u64, bw: u16, bh: u16) std.math.Order {
    if (ak != bk) return std.math.order(ak, bk);
    if (aw != bw) return std.math.order(aw, bw);
    return std.math.order(ah, bh);
}

/// A whole-file check, linear in the entry count: the header, the table's order, no duplicate or
/// empty entry, and every stored image inside the file's data area. It does not inflate anything,
/// so a damaged zlib stream still passes; `decode` reports that when the entry is used. Run it once
/// when a pack is loaded; `find` and `lookup` cannot read out of bounds even on a pack that fails
/// it, but only a pack that passes is known to answer every lookup correctly.
pub fn validate(bytes: []const u8) Error!Header {
    const h = try header(bytes);
    const data_start = header_len + @as(u64, h.count) * entryLen(h.version);
    var prev: ?Entry = null;
    for (0..h.count) |i| {
        const e = entryAt(bytes, h, i);
        if (e.bw == 0 or e.bh == 0 or e.length == 0) return error.BadEntry;
        if (h.version != 1 and e.offset < data_start) return error.BadEntry;
        if (@as(u64, e.offset) + e.length > bytes.len) return error.Truncated;
        if (prev) |p| if (order(p.key, p.bw, p.bh, e.key, e.bw, e.bh) != .lt) return error.Unsorted;
        prev = e;
    }
    return h;
}

/// An entry as stored.
pub const Found = struct {
    version: u32,
    scale: u32,
    bw: u16,
    bh: u16,
    /// The stored bytes: the image itself when `isRaw()`, otherwise a zlib stream of it.
    stored: []const u8,
    /// The image's size, `bw*scale * bh*scale`: what `decode` needs to be given.
    image_len: usize,

    pub fn isRaw(f: Found) bool {
        return f.stored.len == f.image_len;
    }
};

/// The entry filed under (`key`, `bw`, `bh`), or null. A binary search over the table; the header
/// and the found entry's bounds are checked, so a damaged pack gives null, never a read past
/// `bytes`. Pass `stored` and a buffer of `image_len` bytes to `decode` for the image.
pub fn find(bytes: []const u8, key: u64, bw: u16, bh: u16) ?Found {
    const h = header(bytes) catch return null;
    var lo: usize = 0;
    var hi: usize = h.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = entryAt(bytes, h, mid);
        switch (order(e.key, e.bw, e.bh, key, bw, bh)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => {
                const img = imageLen(h.scale, e.bw, e.bh);
                if (img == 0 or e.length == 0 or @as(u64, e.offset) + e.length > bytes.len) return null;
                return .{
                    .version = h.version,
                    .scale = h.scale,
                    .bw = e.bw,
                    .bh = e.bh,
                    .stored = bytes[e.offset..][0..@intCast(e.length)],
                    .image_len = @intCast(img),
                };
            },
        }
    }
    return null;
}

pub const Hit = struct {
    scale: u32,
    /// `bw*scale` x `bh*scale` indices, top row first.
    pixels: []const u8,
};

/// The image filed under (`key`, `bw`, `bh`) as a slice of `bytes`, or null. Every entry of a
/// version 1 pack; in a version 2 pack only an entry stored raw, since a compressed one has no
/// image in the file to point at. For those, `find` and `decode`.
pub fn lookup(bytes: []const u8, key: u64, bw: u16, bh: u16) ?Hit {
    const f = find(bytes, key, bw, bh) orelse return null;
    if (!f.isRaw()) return null;
    return .{ .scale = f.scale, .pixels = f.stored };
}

pub const DecodeError = error{
    /// Not a zlib stream, a damaged one, a bad checksum, or bytes after its end.
    Corrupt,
    /// A sound stream that inflates to more or fewer bytes than `out` holds.
    WrongSize,
};

/// An entry's image from its stored bytes, into `out`, which is the image's size: a copy when
/// `stored` is that size (the raw form), otherwise `inflate`. No allocation.
pub fn decode(stored: []const u8, out: []u8) DecodeError!void {
    if (stored.len == out.len) {
        @memcpy(out, stored);
        return;
    }
    return inflate(stored, out);
}

/// Inflate a zlib stream that must hold exactly `out.len` bytes into `out`. The header, the
/// deflate data, the Adler-32 and the size are all checked, and nothing may follow the stream.
/// No allocation; the state lives on the stack (a few KiB) and `out` is the history window.
pub fn inflate(stored: []const u8, out: []u8) DecodeError!void {
    if (stored.len < 2 + 2 + 4) return error.Corrupt;
    const cmf = stored[0];
    const flg = stored[1];
    // Deflate, a window of at most 32K, the check bits right, no preset dictionary.
    if (cmf & 0x0f != 8 or cmf >> 4 > 7 or ((@as(u16, cmf) << 8) | flg) % 31 != 0 or flg & 0x20 != 0)
        return error.Corrupt;
    var in: std.Io.Reader = .fixed(stored);
    var w: std.Io.Writer = .fixed(out);
    var d: flate.Decompress = .init(&in, .zlib, &.{});
    const n = d.reader.streamRemaining(&w) catch |e| return switch (e) {
        error.WriteFailed => error.WrongSize,
        error.ReadFailed => error.Corrupt,
    };
    if (in.seek != stored.len) return error.Corrupt;
    // std's inflater reads the Adler-32 but leaves checking it to the caller.
    if (std.hash.Adler32.hash(out[0..n]) != d.container_metadata.zlib.adler) return error.Corrupt;
    if (n != out.len) return error.WrongSize;
}

/// One image to write: the frame's key and 1x box size, and its `bw*scale` x `bh*scale` indices.
pub const Image = struct {
    key: u64,
    bw: u16,
    bh: u16,
    pixels: []const u8,
};

pub const Options = struct {
    /// 2 stores each image zlib-compressed where that is smaller; 1 writes the old raw form.
    version: u32 = version,
    /// The deflate effort; zlib's level 6 by default.
    level: flate.Compress.Options = .default,
    /// Compression threads; 0 is one per CPU. With more than one, the allocator given to `encode`
    /// must be thread-safe. The output does not depend on it.
    threads: usize = 0,
    /// The longest file `encode` may produce. The format's limit; tests lower it.
    max_len: u64 = max_file_len,
};

pub const EncodeError = std.mem.Allocator.Error || std.Thread.SpawnError || error{
    BadScale,
    BadEntry,
    UnsupportedVersion,
    /// The pack would be longer than `Options.max_len`: split the images over several packs.
    PackTooLarge,
};

/// Encode a pack. Entries are sorted by (key, bw, bh); where the same (key, bw, bh) is given more
/// than once, the first one in `images` is kept and the rest are dropped, so the output depends
/// only on the input order. Each image must hold `bw*scale * bh*scale` indices. In version 2,
/// entries with byte-identical images share one stored copy, placed where the first of them in
/// table order would be.
pub fn encode(gpa: std.mem.Allocator, scale: u32, images: []const Image, opts: Options) EncodeError![]u8 {
    if (scale < 1 or scale > max_scale) return error.BadScale;
    if (opts.version != 1 and opts.version != 2) return error.UnsupportedVersion;
    const idx = try sortedUnique(gpa, scale, images);
    defer gpa.free(idx);
    const n = idx.len;
    const el = entryLen(opts.version);
    const table_end = header_len + @as(u64, n) * el;
    if (table_end > opts.max_len) return error.PackTooLarge;

    // Version 1: every entry its own raw copy, as the format was first written.
    if (opts.version == 1) {
        var total: u64 = table_end;
        for (idx) |i| total += images[i].pixels.len;
        if (total > opts.max_len) return error.PackTooLarge;
        const out = try gpa.alloc(u8, @intCast(total));
        writeHeader(out, 1, scale, n);
        var off: usize = @intCast(table_end);
        for (idx, 0..) |i, j| {
            const im = images[i];
            writeEntry(out, 1, j, im, off, im.pixels.len);
            @memcpy(out[off..][0..im.pixels.len], im.pixels);
            off += im.pixels.len;
        }
        return out;
    }

    // Version 2. `slot[j]` is the stored copy entry j uses; `uniq` lists each distinct image once,
    // in the order its first entry comes in the table.
    const slot = try gpa.alloc(u32, n);
    defer gpa.free(slot);
    var uniq: std.ArrayListUnmanaged(u32) = .empty;
    defer uniq.deinit(gpa);
    {
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        defer seen.deinit(gpa);
        for (idx, 0..) |i, j| {
            const gop = try seen.getOrPut(gpa, images[i].pixels);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(uniq.items.len);
                try uniq.append(gpa, i);
            }
            slot[j] = gop.value_ptr.*;
        }
    }

    const stored = try gpa.alloc([]u8, uniq.items.len);
    for (stored) |*s| s.* = &.{};
    defer {
        for (stored) |s| gpa.free(s);
        gpa.free(stored);
    }
    try compressAll(gpa, images, uniq.items, stored, opts, table_end);

    var total: u64 = table_end;
    for (stored) |s| total += s.len;
    if (total > opts.max_len) return error.PackTooLarge;

    const out = try gpa.alloc(u8, @intCast(total));
    writeHeader(out, 2, scale, n);
    const offs = try gpa.alloc(u32, stored.len);
    defer gpa.free(offs);
    var off: usize = @intCast(table_end);
    for (stored, offs) |s, *o| {
        o.* = @intCast(off);
        @memcpy(out[off..][0..s.len], s);
        off += s.len;
    }
    for (idx, slot, 0..) |i, u, j| writeEntry(out, 2, j, images[i], offs[u], stored[u].len);
    return out;
}

/// The indices of `images` in table order, repeats of a (key, bw, bh) after the first dropped.
fn sortedUnique(gpa: std.mem.Allocator, scale: u32, images: []const Image) error{ OutOfMemory, BadEntry }![]u32 {
    const Ix = struct {
        img: []const Image,
        fn less(ctx: @This(), a: u32, b: u32) bool {
            const x = ctx.img[a];
            const y = ctx.img[b];
            return switch (order(x.key, x.bw, x.bh, y.key, y.bw, y.bh)) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    };
    const idx = try gpa.alloc(u32, images.len);
    errdefer gpa.free(idx);
    for (idx, 0..) |*p, i| p.* = @intCast(i);
    std.mem.sort(u32, idx, Ix{ .img = images }, Ix.less);

    var n: usize = 0;
    for (idx) |i| {
        const im = images[i];
        if (im.bw == 0 or im.bh == 0) return error.BadEntry;
        if (im.pixels.len != imageLen(scale, im.bw, im.bh)) return error.BadEntry;
        if (n > 0) {
            const p = images[idx[n - 1]];
            if (p.key == im.key and p.bw == im.bw and p.bh == im.bh) continue;
        }
        idx[n] = i;
        n += 1;
    }
    return gpa.realloc(idx, n);
}

/// Stores images for version 2 entries: each one's zlib stream when that is strictly shorter than
/// the image, else a copy of the image. Holds deflate's state (about 300 KiB), so one per thread.
pub const Compressor = struct {
    gpa: std.mem.Allocator,
    level: flate.Compress.Options,
    state: *flate.Compress,
    window: []u8,
    scratch: []u8,

    pub fn init(gpa: std.mem.Allocator, level: flate.Compress.Options) !Compressor {
        const state = try gpa.create(flate.Compress);
        errdefer gpa.destroy(state);
        const window = try gpa.alloc(u8, flate.max_window_len);
        return .{ .gpa = gpa, .level = level, .state = state, .window = window, .scratch = &.{} };
    }

    pub fn deinit(c: *Compressor) void {
        c.gpa.free(c.scratch);
        c.gpa.free(c.window);
        c.gpa.destroy(c.state);
    }

    /// The bytes to store for `pixels`, allocated with the compressor's allocator.
    pub fn store(c: *Compressor, pixels: []const u8) ![]u8 {
        // The sink must take more than 8 bytes; an image that small never compresses anyway.
        const want = @max(pixels.len, 16);
        if (c.scratch.len < want) {
            c.gpa.free(c.scratch);
            c.scratch = &.{};
            c.scratch = try c.gpa.alloc(u8, want);
        }
        // The sink is one byte shorter than the image, so filling it means zlib does not help.
        var sink: std.Io.Writer = .fixed(c.scratch[0..@max(pixels.len -| 1, 9)]);
        const zlib = z: {
            c.state.* = flate.Compress.init(&sink, c.window, .zlib, c.level) catch break :z null;
            c.state.writer.writeAll(pixels) catch break :z null;
            c.state.finish() catch break :z null;
            break :z sink.buffered();
        };
        if (zlib) |z| if (z.len < pixels.len) return c.gpa.dupe(u8, z);
        return c.gpa.dupe(u8, pixels);
    }
};

/// `stored[k]` = the stored form of `images[uniq[k]]`, over `opts.threads` workers. Stops early,
/// with PackTooLarge, once the stored bytes alone pass `opts.max_len`.
fn compressAll(gpa: std.mem.Allocator, images: []const Image, uniq: []const u32, stored: [][]u8, opts: Options, table_end: u64) EncodeError!void {
    const Shared = struct {
        images: []const Image,
        uniq: []const u32,
        stored: [][]u8,
        next: std.atomic.Value(usize) = .init(0),
        total: std.atomic.Value(u64),
        max_len: u64,
        failed: std.atomic.Value(u8) = .init(0), // 0 fine, 1 out of memory, 2 too large

        fn work(s: *@This(), c: *Compressor) void {
            while (s.failed.load(.monotonic) == 0) {
                const k = s.next.fetchAdd(1, .monotonic);
                if (k >= s.uniq.len) return;
                const bytes = c.store(s.images[s.uniq[k]].pixels) catch {
                    s.failed.store(1, .monotonic);
                    return;
                };
                s.stored[k] = bytes;
                if (s.total.fetchAdd(bytes.len, .monotonic) + bytes.len > s.max_len) {
                    s.failed.store(2, .monotonic);
                    return;
                }
            }
        }
    };
    var shared: Shared = .{ .images = images, .uniq = uniq, .stored = stored, .total = .init(table_end), .max_len = opts.max_len };

    const cpus = if (builtin.single_threaded) 1 else std.Thread.getCpuCount() catch 1;
    const want = if (opts.threads == 0) cpus else opts.threads;
    const nthreads = @max(1, @min(want, uniq.len));
    const comps = try gpa.alloc(Compressor, nthreads);
    defer gpa.free(comps);
    var made: usize = 0;
    defer for (comps[0..made]) |*c| c.deinit();
    while (made < nthreads) : (made += 1) comps[made] = try Compressor.init(gpa, opts.level);

    if (nthreads == 1 or builtin.single_threaded) {
        shared.work(&comps[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, nthreads - 1);
        defer gpa.free(threads);
        var started: usize = 0;
        defer for (threads[0..started]) |t| t.join();
        while (started < threads.len) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, Shared.work, .{ &shared, &comps[started + 1] }) catch |e| {
                shared.failed.store(3, .monotonic);
                return e;
            };
        }
        shared.work(&comps[0]);
    }
    return switch (shared.failed.load(.monotonic)) {
        0 => {},
        2 => error.PackTooLarge,
        else => error.OutOfMemory,
    };
}

fn writeHeader(out: []u8, v: u32, scale: u32, n: usize) void {
    @memcpy(out[0..4], magic);
    wr32(out, 4, v);
    wr32(out, 8, scale);
    wr32(out, 12, @intCast(n));
}

fn writeEntry(out: []u8, v: u32, j: usize, im: Image, off: usize, len: usize) void {
    const e = out[header_len + j * entryLen(v) ..][0..entryLen(v)];
    std.mem.writeInt(u64, e[0..8], im.key, .little);
    std.mem.writeInt(u16, e[8..10], im.bw, .little);
    std.mem.writeInt(u16, e[10..12], im.bh, .little);
    std.mem.writeInt(u32, e[12..16], @intCast(off), .little);
    if (v != 1) std.mem.writeInt(u32, e[16..20], @intCast(len), .little);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

const testing = std.testing;

/// The image under (key, bw, bh), decoded into a fresh allocation.
fn testImage(pack: []const u8, key: u64, bw: u16, bh: u16) ![]u8 {
    const f = find(pack, key, bw, bh) orelse return error.NotFound;
    const out = try testing.allocator.alloc(u8, f.image_len);
    errdefer testing.allocator.free(out);
    try decode(f.stored, out);
    return out;
}

fn expectImage(pack: []const u8, key: u64, bw: u16, bh: u16, want: []const u8) !void {
    const got = try testImage(pack, key, bw, bh);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

test "round trip, both versions: every image is found under its key and size, nothing else is" {
    const gpa = testing.allocator;
    const a = [_]u8{1} ** (2 * 2 * 4); // 2x2 at 1x, scale 2 -> 4x4
    const b = [_]u8{2} ** (1 * 3 * 4); // 1x3 -> 2x6
    const c = [_]u8{3} ** (3 * 1 * 4); // 3x1, same key as b: a collision the size resolves
    const d = [_]u8{4} ** (2 * 2 * 4); // a repeat of a's key and size: dropped
    const imgs = [_]Image{
        .{ .key = 50, .bw = 2, .bh = 2, .pixels = &a },
        .{ .key = 7, .bw = 1, .bh = 3, .pixels = &b },
        .{ .key = 7, .bw = 3, .bh = 1, .pixels = &c },
        .{ .key = 50, .bw = 2, .bh = 2, .pixels = &d },
    };
    for ([_]u32{ 1, 2 }) |v| {
        const pack = try encode(gpa, 2, &imgs, .{ .version = v });
        defer gpa.free(pack);

        const h = try validate(pack);
        try testing.expectEqual(Header{ .version = v, .scale = 2, .count = 3 }, h);
        if (v == 1) try testing.expectEqual(@as(usize, 16 + 3 * 16 + 16 + 12 + 12), pack.len);

        try expectImage(pack, 50, 2, 2, &a);
        try expectImage(pack, 7, 1, 3, &b);
        try expectImage(pack, 7, 3, 1, &c);
        try testing.expectEqual(@as(u32, 2), find(pack, 7, 3, 1).?.scale);
        try testing.expectEqual(@as(?Found, null), find(pack, 50, 2, 3));
        try testing.expectEqual(@as(?Found, null), find(pack, 8, 1, 3));
        try testing.expectEqual(@as(?Found, null), find(pack, 0, 0, 0));
        try testing.expectEqual(@as(?Found, null), find(pack, std.math.maxInt(u64), 1, 1));
        if (v == 1) try testing.expectEqualSlices(u8, &a, lookup(pack, 50, 2, 2).?.pixels);
    }
}

test "v2 compresses what shrinks, stores the rest raw, and decodes both" {
    const gpa = testing.allocator;
    // A flat 32x32 at 2x: 4096 bytes that deflate to a few dozen.
    const flat = [_]u8{7} ** (32 * 32 * 4);
    // 4x4 at 2x of noise: 64 bytes zlib cannot shrink.
    var noise: [4 * 4 * 4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1);
    rng.random().bytes(&noise);
    // 1x1 at 2x: too small for zlib's own overhead.
    const tiny = [_]u8{ 1, 2, 3, 4 };
    const pack = try encode(gpa, 2, &.{
        .{ .key = 1, .bw = 32, .bh = 32, .pixels = &flat },
        .{ .key = 2, .bw = 4, .bh = 4, .pixels = &noise },
        .{ .key = 3, .bw = 1, .bh = 1, .pixels = &tiny },
    }, .{});
    defer gpa.free(pack);
    _ = try validate(pack);

    const f = find(pack, 1, 32, 32).?;
    try testing.expect(!f.isRaw());
    try testing.expect(f.stored.len < 64);
    try testing.expectEqual(@as(u8, 0x78), f.stored[0]); // a zlib header
    try testing.expectEqual(@as(?Hit, null), lookup(pack, 1, 32, 32)); // no raw image to point at
    try expectImage(pack, 1, 32, 32, &flat);

    const r = find(pack, 2, 4, 4).?;
    try testing.expect(r.isRaw());
    try testing.expectEqualSlices(u8, &noise, r.stored);
    try testing.expectEqualSlices(u8, &noise, lookup(pack, 2, 4, 4).?.pixels);
    try expectImage(pack, 2, 4, 4, &noise);

    try testing.expect(find(pack, 3, 1, 1).?.isRaw());
    try expectImage(pack, 3, 1, 1, &tiny);

    // 16 + 3 x 20, then the stored bytes back to back.
    try testing.expectEqual(@as(usize, 16 + 60 + f.stored.len + 64 + 4), pack.len);
}

test "v2 stores identical images once" {
    const gpa = testing.allocator;
    const a = [_]u8{5} ** (8 * 8 * 4);
    const a2 = [_]u8{5} ** (8 * 8 * 4); // the same bytes in another buffer
    var b = [_]u8{5} ** (8 * 8 * 4);
    b[100] = 6;
    const imgs = [_]Image{
        .{ .key = 30, .bw = 8, .bh = 8, .pixels = &a },
        .{ .key = 10, .bw = 8, .bh = 8, .pixels = &a2 },
        .{ .key = 20, .bw = 8, .bh = 8, .pixels = &b },
        .{ .key = 40, .bw = 16, .bh = 4, .pixels = &a }, // same bytes, another box: shared too
    };
    const pack = try encode(gpa, 2, &imgs, .{});
    defer gpa.free(pack);
    const h = try validate(pack);
    try testing.expectEqual(@as(u32, 4), h.count);
    const e10 = entryAt(pack, h, 0);
    const e20 = entryAt(pack, h, 1);
    const e30 = entryAt(pack, h, 2);
    const e40 = entryAt(pack, h, 3);
    try testing.expectEqual(e10.offset, e30.offset);
    try testing.expectEqual(e10.length, e30.length);
    try testing.expectEqual(e10.offset, e40.offset);
    try testing.expect(e20.offset != e10.offset);
    // The shared copy sits where the first entry in table order (key 10) puts it.
    try testing.expectEqual(@as(u32, 16 + 4 * 20), e10.offset);
    try testing.expectEqual(@as(u64, pack.len), 16 + 4 * 20 + e10.length + e20.length);
    try expectImage(pack, 10, 8, 8, &a);
    try expectImage(pack, 20, 8, 8, &b);
    try expectImage(pack, 30, 8, 8, &a);
    try expectImage(pack, 40, 16, 4, &a);
}

test "the output depends only on the input, not on the thread count" {
    const gpa = testing.allocator;
    var imgs: [200]Image = undefined;
    var px: [200][16 * 16]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (&imgs, 0..) |*im, i| {
        // Some noise, some runs, some repeats of earlier images.
        for (&px[i], 0..) |*p, j| p.* = if (i % 3 == 0) rng.random().int(u8) else @intCast((j / (i % 7 + 1)) % 5);
        if (i % 11 == 10) px[i] = px[i - 5];
        im.* = .{ .key = (i * 2654435761) % 997, .bw = 8, .bh = 8, .pixels = &px[i] };
    }
    const one = try encode(gpa, 2, &imgs, .{ .threads = 1 });
    defer gpa.free(one);
    const two = try encode(gpa, 2, &imgs, .{ .threads = 1 });
    defer gpa.free(two);
    const many = try encode(gpa, 2, &imgs, .{ .threads = 5 });
    defer gpa.free(many);
    try testing.expectEqualSlices(u8, one, two);
    try testing.expectEqualSlices(u8, one, many);
    _ = try validate(one);
    for (imgs, 0..) |im, i| {
        // The first image under a key wins.
        const first = for (imgs[0..i]) |p| {
            if (p.key == im.key) break false;
        } else true;
        if (first) try expectImage(one, im.key, 8, 8, im.pixels);
    }
}

test "a pack over the size limit is refused" {
    const gpa = testing.allocator;
    var noise: [3][8 * 8 * 4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(3);
    for (&noise) |*n| rng.random().bytes(n);
    const imgs = [_]Image{
        .{ .key = 1, .bw = 8, .bh = 8, .pixels = &noise[0] },
        .{ .key = 2, .bw = 8, .bh = 8, .pixels = &noise[1] },
        .{ .key = 3, .bw = 8, .bh = 8, .pixels = &noise[2] },
    };
    // Noise is stored raw: 16 + 3 x 20 + 3 x 256 = 844 bytes.
    const exact = try encode(gpa, 2, &imgs, .{ .max_len = 844 });
    defer gpa.free(exact);
    try testing.expectEqual(@as(usize, 844), exact.len);
    for ([_]usize{ 1, 3 }) |t|
        try testing.expectError(error.PackTooLarge, encode(gpa, 2, &imgs, .{ .max_len = 843, .threads = t }));
    try testing.expectError(error.PackTooLarge, encode(gpa, 2, &imgs, .{ .max_len = 70 })); // the table alone
    try testing.expectError(error.PackTooLarge, encode(gpa, 2, &imgs, .{ .version = 1, .max_len = 16 + 48 + 767 }));
    // The real limit: 4 GiB - 1, since offsets are u32.
    try testing.expectEqual(@as(u64, 0xffff_ffff), (Options{}).max_len);
}

test "a version 1 pack written by the original writer still reads" {
    // The version 1 layout, field by field: scale 2, key 9 with a 1x2 box, then key
    // 0x0102030405060708 with a 1x1 box.
    var pack: [16 + 2 * 16 + 4 + 8]u8 = undefined;
    @memcpy(pack[0..4], "D2HD");
    wr32(&pack, 4, 1);
    wr32(&pack, 8, 2);
    wr32(&pack, 12, 2);
    std.mem.writeInt(u64, pack[16..24], 9, .little);
    std.mem.writeInt(u16, pack[24..26], 1, .little);
    std.mem.writeInt(u16, pack[26..28], 2, .little);
    std.mem.writeInt(u32, pack[28..32], 48, .little);
    std.mem.writeInt(u64, pack[32..40], 0x0102030405060708, .little);
    std.mem.writeInt(u16, pack[40..42], 1, .little);
    std.mem.writeInt(u16, pack[42..44], 1, .little);
    std.mem.writeInt(u32, pack[44..48], 56, .little);
    @memcpy(pack[48..56], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    @memcpy(pack[56..60], &[_]u8{ 9, 10, 11, 12 });

    try testing.expectEqual(Header{ .version = 1, .scale = 2, .count = 2 }, try validate(&pack));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, lookup(&pack, 9, 1, 2).?.pixels);
    try testing.expectEqualSlices(u8, &.{ 9, 10, 11, 12 }, lookup(&pack, 0x0102030405060708, 1, 1).?.pixels);
    try expectImage(&pack, 9, 1, 2, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expect(find(&pack, 9, 1, 2).?.isRaw());
    // The version 1 writer produces exactly those bytes.
    const again = try encode(testing.allocator, 2, &.{
        .{ .key = 0x0102030405060708, .bw = 1, .bh = 1, .pixels = &.{ 9, 10, 11, 12 } },
        .{ .key = 9, .bw = 1, .bh = 2, .pixels = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } },
    }, .{ .version = 1 });
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, &pack, again);
}

test "inflate rejects corrupt data and a wrong size" {
    const gpa = testing.allocator;
    var img: [64 * 64]u8 = undefined;
    for (&img, 0..) |*p, i| p.* = @intCast((i / 7) % 13);
    var c = try Compressor.init(gpa, .default);
    defer c.deinit();
    const z = try c.store(&img);
    defer gpa.free(z);
    try testing.expect(z.len < img.len);

    var out: [64 * 64 + 1]u8 = undefined;
    try inflate(z, out[0..img.len]);
    try testing.expectEqualSlices(u8, &img, out[0..img.len]);

    // Too small a buffer, and too large.
    try testing.expectError(error.WrongSize, inflate(z, out[0 .. img.len - 1]));
    try testing.expectError(error.WrongSize, inflate(z, out[0 .. img.len + 1]));
    try testing.expectError(error.WrongSize, decode(z, out[0..0]));

    const bad = try gpa.dupe(u8, z);
    defer gpa.free(bad);
    // A flipped bit anywhere in the deflate data or the checksum.
    for ([_]usize{ 2, z.len / 2, z.len - 1 }) |at| {
        @memcpy(bad, z);
        bad[at] ^= 0x10;
        if (inflate(bad, out[0..img.len])) |_| return error.TestUnexpectedResult else |e| switch (e) {
            error.Corrupt, error.WrongSize => {},
        }
    }
    @memcpy(bad, z);
    bad[z.len - 1] ^= 1;
    try testing.expectError(error.Corrupt, inflate(bad, out[0..img.len])); // the Adler-32
    @memcpy(bad, z);
    bad[0] = 0x79; // not deflate
    try testing.expectError(error.Corrupt, inflate(bad, out[0..img.len]));
    @memcpy(bad, z);
    bad[1] ^= 1; // header check bits
    try testing.expectError(error.Corrupt, inflate(bad, out[0..img.len]));
    // Truncated, and with a byte after the end.
    try testing.expectError(error.Corrupt, inflate(z[0 .. z.len - 1], out[0..img.len]));
    try testing.expectError(error.Corrupt, inflate(z[0..3], out[0..img.len]));
    try testing.expectError(error.Corrupt, inflate(&.{}, out[0..img.len]));
    const longer = try gpa.alloc(u8, z.len + 1);
    defer gpa.free(longer);
    @memcpy(longer[0..z.len], z);
    longer[z.len] = 0;
    try testing.expectError(error.Corrupt, inflate(longer, out[0..img.len]));
    // Random bytes never pass.
    var rng = std.Random.DefaultPrng.init(11);
    var junk: [200]u8 = undefined;
    for (0..200) |_| {
        rng.random().bytes(&junk);
        junk[0] = 0x78;
        junk[1] = 0x9c;
        try testing.expect(std.meta.isError(inflate(&junk, out[0..img.len])));
    }
}

test "an empty pack is valid and finds nothing" {
    const gpa = testing.allocator;
    for ([_]u32{ 1, 2 }) |v| {
        const pack = try encode(gpa, 4, &.{}, .{ .version = v });
        defer gpa.free(pack);
        try testing.expectEqual(Header{ .version = v, .scale = 4, .count = 0 }, try validate(pack));
        try testing.expectEqual(@as(?Found, null), find(pack, 1, 1, 1));
    }
}

test "damaged packs are refused, and lookups on them stay in bounds" {
    const gpa = testing.allocator;
    const a = [_]u8{9} ** 4;
    for ([_]u32{ 1, 2 }) |v| {
        const pack = try encode(gpa, 2, &.{.{ .key = 1, .bw = 1, .bh = 1, .pixels = &a }}, .{ .version = v });
        defer gpa.free(pack);

        try testing.expectError(error.NotHdPack, validate(pack[0..3]));
        try testing.expectError(error.Truncated, validate(pack[0 .. pack.len - 1]));
        try testing.expectEqual(@as(?Found, null), find(pack[0 .. pack.len - 1], 1, 1, 1));
        try testing.expectError(error.Truncated, validate(pack[0..20]));

        var bad = try gpa.dupe(u8, pack);
        defer gpa.free(bad);
        bad[4] = 3;
        try testing.expectError(error.UnsupportedVersion, validate(bad));
        bad[4] = @intCast(v);
        bad[8] = 0;
        try testing.expectError(error.BadScale, validate(bad));
        bad[8] = 2;
        bad[0] = 'X';
        try testing.expectError(error.NotHdPack, validate(bad));
        bad[0] = 'D';
        if (v == 2) {
            wr32(bad, 16 + 16, 0); // a zero length
            try testing.expectError(error.BadEntry, validate(bad));
            wr32(bad, 16 + 16, 4);
            wr32(bad, 16 + 12, 20); // an offset into the table
            try testing.expectError(error.BadEntry, validate(bad));
        }
    }

    try testing.expectError(error.BadEntry, encode(gpa, 2, &.{.{ .key = 1, .bw = 1, .bh = 1, .pixels = a[0..3] }}, .{}));
    try testing.expectError(error.BadScale, encode(gpa, 0, &.{}, .{}));
    try testing.expectError(error.UnsupportedVersion, encode(gpa, 2, &.{}, .{ .version = 3 }));
}

test "an out-of-order table is refused" {
    const gpa = testing.allocator;
    const a = [_]u8{1} ** 4;
    for ([_]u32{ 1, 2 }) |v| {
        const pack = try encode(gpa, 2, &.{
            .{ .key = 1, .bw = 1, .bh = 1, .pixels = &a },
            .{ .key = 2, .bw = 1, .bh = 1, .pixels = &a },
        }, .{ .version = v });
        defer gpa.free(pack);
        var bad = try gpa.dupe(u8, pack);
        defer gpa.free(bad);
        bad[16] = 3; // first key 1 -> 3, after the second
        try testing.expectError(error.Unsorted, validate(bad));
    }
}
