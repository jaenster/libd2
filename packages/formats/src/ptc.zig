//! Blizzard's PrePatch records, and the script a patch installer follows.
//!
//! A `D2Patch_*.exe` / `LODPatch_*.exe` is a stub executable with an MPQ appended to it. Each
//! member of that archive is either a file to install or a 24-byte record plus payload — before
//! 1.11b usually a binary delta against the version being upgraded rather than the file itself.
//!
//! A record never names a version. It names the bytes it expects: a CRC32 and a length. The
//! installer selects records by member NAME, from the mapping tables the archive also carries,
//! and the CRC only guards against applying one to the wrong build. Both halves matter — the
//! name finds it, the checksum proves it fits.
//!
//! Reversed from `Ptc.cpp` in LODPatch_109d's BNUpdate.exe: applier @0x406f00, stream-A @0x407140,
//! stream-B @0x407300, shared varint reader @0x407610.

const std = @import("std");

pub const Record = struct {
    header_size: u16,
    kind: u16,
    src_crc32: u32,
    src_size: u32,
    tgt_size: u32,
    tgt_filetime: u64,
    payload: []const u8,

    /// A full file is stored verbatim; anything else is a delta needing the source.
    pub fn isFull(self: Record) bool {
        return self.kind >> 8 == 1;
    }

    pub fn parse(bytes: []const u8) !Record {
        // BNUpdate.exe + D2VidTst.exe ship unwrapped, so a leading MZ is the file itself.
        if (bytes.len >= 2 and bytes[0] == 'M' and bytes[1] == 'Z') return .{
            .header_size = 0,
            .kind = 0x0100,
            .src_crc32 = 0,
            .src_size = 0,
            .tgt_size = @intCast(bytes.len),
            .tgt_filetime = 0,
            .payload = bytes,
        };
        if (bytes.len < 0x18) return error.Truncated;
        const hs = std.mem.readInt(u16, bytes[0..2], .little);
        if (hs != 0x18) return error.BadHeaderSize;
        return .{
            .header_size = hs,
            .kind = std.mem.readInt(u16, bytes[2..4], .little),
            .src_crc32 = std.mem.readInt(u32, bytes[4..8], .little),
            .src_size = std.mem.readInt(u32, bytes[8..12], .little),
            .tgt_size = std.mem.readInt(u32, bytes[12..16], .little),
            .tgt_filetime = std.mem.readInt(u64, bytes[16..24], .little),
            .payload = bytes[hs..],
        };
    }
};

/// The 1/2/3/4-byte varint both streams are coded with. `signed` sign-extends to the width the
/// payload actually carries; the encoder picks the width from the signed value, so a wide form can
/// still hold a small negative number.
const Varint = struct {
    value: i32,
    next: usize,

    fn read(b: []const u8, pos: usize, signed: bool) !Varint {
        if (pos >= b.len) return error.Truncated;
        const f = b[pos];
        var v: u32 = undefined;
        var n: usize = undefined;
        var bits: u5 = undefined;
        if (f & 0x80 == 0) {
            v = f & 0x7F;
            n = 1;
            bits = 7;
        } else if (f & 0x40 == 0) {
            v = (f & 0x3F) | (@as(u32, b[pos + 1]) << 6);
            n = 2;
            bits = 14;
        } else if (f & 0x20 == 0) {
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13);
            n = 3;
            bits = 21;
        } else {
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13) |
                (@as(u32, b[pos + 3]) << 21);
            n = 4;
            bits = 29;
        }
        if (pos + n > b.len) return error.Truncated;
        var out: i32 = @bitCast(v);
        if (signed and v & (@as(u32, 1) << (bits - 1)) != 0) {
            out = @bitCast(v -% (@as(u32, 1) << bits));
        }
        return .{ .value = out, .next = pos + n };
    }
};

fn u16At(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], .little);
}

fn setU16(b: []u8, i: usize, v: u16) void {
    std.mem.writeInt(u16, b[i..][0..2], v, .little);
}

/// Apply `rec` to `src`, returning the reconstructed file. Caller owns the result.
pub fn apply(gpa: std.mem.Allocator, rec: Record, src: []const u8) ![]u8 {
    if (rec.isFull()) return gpa.dupe(u8, rec.payload[0..rec.tgt_size]);
    if (src.len != rec.src_size) return error.SourceSizeMismatch;
    // A record never names a version. It names the bytes it expects: this CRC32 at this length.
    // That is what makes a chain walkable without tracking version numbers - and what stops a
    // delta being applied to the wrong build, which would corrupt silently rather than fail.
    // Standard CRC-32, confirmed against D2Patch_101: all 20 of its records that name a file
    // present in the 1.14b payload's PC-100 tree match it exactly, and none match on size alone.
    if (rec.src_crc32 != 0 and std.hash.Crc32.hash(src) != rec.src_crc32) return error.SourceCrcMismatch;
    if (rec.payload.len < 8) return error.Truncated;

    const size_a = std.mem.readInt(u32, rec.payload[0..4], .little);
    const size_b = std.mem.readInt(u32, rec.payload[4..8], .little);
    if (8 + size_a + size_b > rec.payload.len) return error.Truncated;
    const a = rec.payload[8..][0..size_a];
    const b = rec.payload[8 + size_a ..][0..size_b];

    // The source is first-differenced over u16 lanes, high to low, so that code which only moved
    // by a constant differences to a constant and codes almost to nothing.
    const diffed = try gpa.dupe(u8, src);
    defer gpa.free(diffed);
    var i: usize = if (rec.src_size >= 2) rec.src_size - 2 else 0;
    while (i >= 2) : (i -= 2) {
        setU16(diffed, i, u16At(diffed, i) -% u16At(diffed, i - 2));
    }

    const out = try gpa.alloc(u8, rec.tgt_size + 1);
    errdefer gpa.free(out);
    @memset(out, 0);

    var pa: usize = 0;
    var op: usize = 0;
    var sp: usize = 0;
    while (pa < size_a) {
        if (pa + 2 > size_a) return error.Truncated;
        const tok = u16At(a, pa);
        pa += 2;
        const code = tok & 0xC000;
        const len: usize = tok & 0x3FFF;
        if (code == 0x4000 or code == 0x8000) {
            const v = try Varint.read(a, pa, true);
            pa = v.next;
            sp = @intCast(@as(i64, @intCast(sp)) + v.value);
        }
        switch (code) {
            0x0000 => { // literal bytes carried in stream A
                @memcpy(out[op..][0..len], a[pa..][0..len]);
                sp += len;
                op += len;
                pa += len;
            },
            0x4000 => { // verbatim run from the untouched source
                @memcpy(out[op..][0..len], src[sp..][0..len]);
                op += len;
                sp += len;
            },
            0x8000 => { // running sum against the differenced source
                var n = len / 2;
                while (n > 0) : (n -= 1) {
                    const prev: u16 = if (op >= 2) u16At(out, op - 2) else 0;
                    setU16(out, op, u16At(diffed, sp) +% prev);
                    op += 2;
                    sp += 2;
                }
            },
            else => { // 0xC000: zero fill
                @memset(out[op..][0..len], 0);
                op += len;
                sp += len;
            },
        }
    }

    // Stream B re-applies the absolute-address fixups: groups of (accumulated value, then a
    // delta-coded list of offsets to add it at). A zero ends a list; a zero value ends the stream.
    // The values are one ascending run, so only the opening one can be negative and only it is
    // sign-extended; every later value is a positive step. Missing that costs a whole 2^bits, which
    // is invisible on the 3-byte form the DLL deltas use but wrecks the 1- and 2-byte ones.
    var pb: usize = 0;
    var acc: i64 = 0;
    var opening = true;
    while (pb < size_b) {
        const dv = try Varint.read(b, pb, opening);
        opening = false;
        pb = dv.next;
        if (dv.value == 0) break;
        acc += dv.value;
        const first = try Varint.read(b, pb, false);
        pb = first.next;
        var off: i64 = first.value;
        setU16(out, @intCast(off), u16At(out, @intCast(off)) +% @as(u16, @truncate(@as(u64, @bitCast(acc)))));
        while (pb < size_b) {
            const step = try Varint.read(b, pb, false);
            pb = step.next;
            if (step.value == 0) break;
            off += step.value;
            setU16(out, @intCast(off), u16At(out, @intCast(off)) +% @as(u16, @truncate(@as(u64, @bitCast(acc)))));
        }
    }

    return gpa.realloc(out, rec.tgt_size);
}

/// Locate the MPQ the installer stub carries after itself. The offset moved between versions
/// (0x22000, 0x23000, 0x29000 are all in use), so scan rather than assume.
pub fn carve(bytes: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 32 <= bytes.len) : (i += 1) {
        if (!std.mem.eql(u8, bytes[i..][0..4], "MPQ\x1a")) continue;
        const hs = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        const asz = std.mem.readInt(u32, bytes[i + 8 ..][0..4], .little);
        if (hs == 32 and asz > 0 and asz <= bytes.len - i) return bytes[i..][0..asz];
    }
    return null;
}

// ── the mapping tables a patch archive carries ───────────────────────────────────────────────

/// One line of a patch's file map: which member goes where.
pub const Mapping = struct {
    /// Member name inside the patch archive.
    member: []const u8,
    /// Where it lands, with `$(InstallPath)` still in it unless a symbol was supplied.
    destination: []const u8,

    /// The file name alone, separators normalised — what the destination amounts to on disk.
    pub fn basename(self: Mapping) []const u8 {
        var last: usize = 0;
        for (self.destination, 0..) |c, i| if (c == '\\' or c == '/') { last = i + 1; };
        return self.destination[last..];
    }
};

/// Read a patch's `member;destination` table.
///
/// The archive carries two of these: one for files that land on disk, one for files that go
/// inside an archive being patched (those carry a third field). Blank lines and `*` comments are
/// skipped, as the installer's own scripts use them.
pub fn parseMap(gpa: std.mem.Allocator, text: []const u8) ![]Mapping {
    var out: std.ArrayList(Mapping) = .empty;
    var lines = std.mem.splitAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '*') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const member = std.mem.trim(u8, line[0..semi], " \t");
        var rest = std.mem.trim(u8, line[semi + 1 ..], " \t");
        // The archive-internal table adds a flags field; the destination is still the second.
        if (std.mem.indexOfScalar(u8, rest, ';')) |cut| rest = rest[0..cut];
        if (member.len == 0 or rest.len == 0) continue;
        try out.append(gpa, .{ .member = member, .destination = rest });
    }
    return out.toOwnedSlice(gpa);
}

/// Substitute `$(Name)` references, the way a patch script writes them.
pub fn expand(gpa: std.mem.Allocator, text: []const u8, name: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$' and i + 2 < text.len and text[i + 1] == '(') {
            if (std.mem.indexOfScalarPos(u8, text, i, ')')) |end| {
                if (std.mem.eql(u8, text[i + 2 .. end], name)) {
                    try out.appendSlice(gpa, value);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ── tests ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a full record is the file itself" {
    const gpa = testing.allocator;
    var rec = [_]u8{0} ** (0x18 + 4);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0104, .little);
    std.mem.writeInt(u32, rec[12..16], 4, .little);
    @memcpy(rec[0x18..], "abcd");
    const parsed = try Record.parse(&rec);
    try testing.expect(parsed.isFull());
    const out = try apply(gpa, parsed, &[_]u8{});
    defer gpa.free(out);
    try testing.expectEqualStrings("abcd", out);
}

test "a delta refuses a source of the wrong size or the wrong content" {
    const gpa = testing.allocator;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var rec = [_]u8{0} ** 0x18;
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0004, .little);
    std.mem.writeInt(u32, rec[8..12], src.len, .little);
    std.mem.writeInt(u32, rec[12..16], src.len, .little);

    std.mem.writeInt(u32, rec[4..8], std.hash.Crc32.hash(&src), .little);
    try testing.expectError(error.SourceSizeMismatch, apply(gpa, try Record.parse(&rec), &[_]u8{1}));

    std.mem.writeInt(u32, rec[4..8], std.hash.Crc32.hash(&src) ^ 1, .little);
    try testing.expectError(error.SourceCrcMismatch, apply(gpa, try Record.parse(&rec), &src));
}

test "the file map is read, comments and blanks and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text =
        \\* which member goes where
        \\binkw32.dll;$(InstallPath)\binkw32.dll
        \\
        \\D2Client.dll;$(InstallPath)\D2Client.dll
        \\data\GLOBAL\Excel\LvlSub.txt;LvlSub.txt;0x0
    ;
    const map = try parseMap(gpa, text);
    try testing.expectEqual(@as(usize, 3), map.len);
    try testing.expectEqualStrings("binkw32.dll", map[0].member);
    try testing.expectEqualStrings("binkw32.dll", map[0].basename());
    // the archive-internal form keeps the member and drops the trailing flags
    try testing.expectEqualStrings("data\\GLOBAL\\Excel\\LvlSub.txt", map[2].member);
    try testing.expectEqualStrings("LvlSub.txt", map[2].destination);
}

test "install path substitution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const got = try expand(gpa, "$(InstallPath)\\a.dll", "InstallPath", "/games/d2");
    try testing.expectEqualStrings("/games/d2\\a.dll", got);
    // an unknown reference is left alone rather than silently emptied
    const kept = try expand(gpa, "$(Other)\\a", "InstallPath", "/x");
    try testing.expectEqualStrings("$(Other)\\a", kept);
}
