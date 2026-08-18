//! Blizzard PrePatch — the binary delta a D2 patch installer carries instead of a whole file.
//!
//! Every member of a `D2Patch_*.exe` / `LODPatch_*.exe` archive is a 24-byte record plus payload,
//! and before 1.11b the payload is a delta against the retail install rather than the file itself.
//! This reverses `Ptc.cpp` out of BNUpdate.exe (applier @0x404fee, stream-A @0x4051e9, stream-B
//! @0x4053a3, varints @0x40532a signed / @0x40545d unsigned), so a version can be reconstructed
//! offline instead of by running the installer.
//!
//! The payload is two coded streams. Stream A rebuilds the file out of literal runs, verbatim
//! source runs, running sums against a first-differenced copy of the source, and zero fills.
//! Stream B then re-applies the absolute-address fixups the differencing destroyed. Members come
//! out of the archive with `mpq.Archive` — they are FIX_KEY encrypted, so a protected installer
//! needs `mpq.Archive.recoverKey` first.

const std = @import("std");

/// The record that fronts every archive member.
pub const Record = struct {
    header_size: u16,
    kind: u16,
    src_crc32: u32,
    src_size: u32,
    tgt_size: u32,
    tgt_filetime: u64,
    payload: []const u8,

    pub const encoded_len = 0x18;

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
        if (bytes.len < encoded_len) return error.Truncated;
        const hs = std.mem.readInt(u16, bytes[0..2], .little);
        if (hs != encoded_len) return error.BadHeaderSize;
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
/// length actually carries, which is what separates the stream-A reader from the stream-B one.
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
            if (pos + 2 > b.len) return error.Truncated;
            v = (f & 0x3F) | (@as(u32, b[pos + 1]) << 6);
            n = 2;
            bits = 14;
        } else if (f & 0x20 == 0) {
            if (pos + 3 > b.len) return error.Truncated;
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13);
            n = 3;
            bits = 21;
        } else {
            if (pos + 4 > b.len) return error.Truncated;
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13) |
                (@as(u32, b[pos + 3]) << 21);
            n = 4;
            bits = 29;
        }
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
    if (rec.isFull()) {
        if (rec.payload.len < rec.tgt_size) return error.Truncated;
        return gpa.dupe(u8, rec.payload[0..rec.tgt_size]);
    }
    if (src.len != rec.src_size) return error.SourceSizeMismatch;
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

    // One byte of slack: a running-sum run writes u16s and the last one can start on the final
    // byte of the target.
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
                if (pa + len > size_a or op + len > out.len) return error.Truncated;
                @memcpy(out[op..][0..len], a[pa..][0..len]);
                sp += len;
                op += len;
                pa += len;
            },
            0x4000 => { // verbatim run from the untouched source
                if (sp + len > src.len or op + len > out.len) return error.Truncated;
                @memcpy(out[op..][0..len], src[sp..][0..len]);
                op += len;
                sp += len;
            },
            0x8000 => { // running sum against the differenced source
                if (sp + len > diffed.len or op + len > out.len) return error.Truncated;
                var n = len / 2;
                while (n > 0) : (n -= 1) {
                    const prev: u16 = if (op >= 2) u16At(out, op - 2) else 0;
                    setU16(out, op, u16At(diffed, sp) +% prev);
                    op += 2;
                    sp += 2;
                }
            },
            else => { // 0xC000: zero fill
                if (op + len > out.len) return error.Truncated;
                @memset(out[op..][0..len], 0);
                op += len;
                sp += len;
            },
        }
    }

    // Stream B re-applies the absolute-address fixups: groups of (accumulated value, then a
    // delta-coded list of offsets to add it at). A zero ends a list; a zero value ends the stream.
    var pb: usize = 0;
    var acc: i64 = 0;
    while (pb < size_b) {
        const dv = try Varint.read(b, pb, false);
        pb = dv.next;
        if (dv.value == 0) break;
        acc += dv.value;
        const first = try Varint.read(b, pb, false);
        pb = first.next;
        var off: i64 = first.value;
        try fixup(out, off, acc);
        while (pb < size_b) {
            const step = try Varint.read(b, pb, false);
            pb = step.next;
            if (step.value == 0) break;
            off += step.value;
            try fixup(out, off, acc);
        }
    }

    return gpa.realloc(out, rec.tgt_size);
}

fn fixup(out: []u8, off: i64, acc: i64) !void {
    if (off < 0 or off + 2 > out.len) return error.FixupOutOfRange;
    const at: usize = @intCast(off);
    setU16(out, at, u16At(out, at) +% @as(u16, @truncate(@as(u64, @bitCast(acc)))));
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

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "varint widths and sign extension" {
    // one byte, 7-bit
    try testing.expectEqual(@as(i32, 0x41), (try Varint.read(&[_]u8{0x41}, 0, false)).value);
    try testing.expectEqual(@as(usize, 1), (try Varint.read(&[_]u8{0x41}, 0, false)).next);
    // one byte, sign-extended from 7 bits
    try testing.expectEqual(@as(i32, -1), (try Varint.read(&[_]u8{0x7F}, 0, true)).value);
    try testing.expectEqual(@as(i32, 0x7F), (try Varint.read(&[_]u8{0x7F}, 0, false)).value);
    // two bytes: low 6 bits then the next byte at <<6
    try testing.expectEqual(@as(i32, 0x01 | (0x02 << 6)), (try Varint.read(&[_]u8{ 0x81, 0x02 }, 0, false)).value);
    try testing.expectEqual(@as(usize, 2), (try Varint.read(&[_]u8{ 0x81, 0x02 }, 0, false)).next);
    // three bytes: 5 bits, then <<5, then <<13
    const three = [_]u8{ 0xC1, 0x02, 0x03 };
    try testing.expectEqual(@as(i32, 0x01 | (0x02 << 5) | (0x03 << 13)), (try Varint.read(&three, 0, false)).value);
    try testing.expectEqual(@as(usize, 3), (try Varint.read(&three, 0, false)).next);
    // four bytes are selected by the 0x20 bit of the first byte
    const four = [_]u8{ 0xE1, 0x02, 0x03, 0x04 };
    try testing.expectEqual(
        @as(i32, 0x01 | (0x02 << 5) | (0x03 << 13) | (0x04 << 21)),
        (try Varint.read(&four, 0, false)).value,
    );
    try testing.expectEqual(@as(usize, 4), (try Varint.read(&four, 0, false)).next);
    try testing.expectError(error.Truncated, Varint.read(&[_]u8{0x81}, 0, false));
}

test "record parse: delta, full, and an unwrapped PE" {
    var delta: [Record.encoded_len]u8 = @splat(0);
    std.mem.writeInt(u16, delta[0..2], 0x18, .little);
    std.mem.writeInt(u16, delta[2..4], 0x0004, .little);
    std.mem.writeInt(u32, delta[4..8], 0xdeadbeef, .little);
    std.mem.writeInt(u32, delta[8..12], 802816, .little);
    std.mem.writeInt(u32, delta[12..16], 831541, .little);
    const d = try Record.parse(&delta);
    try testing.expect(!d.isFull());
    try testing.expectEqual(@as(u32, 0xdeadbeef), d.src_crc32);
    try testing.expectEqual(@as(u32, 802816), d.src_size);
    try testing.expectEqual(@as(u32, 831541), d.tgt_size);
    try testing.expectEqual(@as(usize, 0), d.payload.len);

    std.mem.writeInt(u16, delta[2..4], 0x0104, .little);
    std.mem.writeInt(u32, delta[8..12], 0, .little);
    try testing.expect((try Record.parse(&delta)).isFull());

    // BNUpdate.exe and D2VidTst.exe are stored with no record at all.
    const raw = [_]u8{ 'M', 'Z', 0x90, 0x00 };
    const r = try Record.parse(&raw);
    try testing.expect(r.isFull());
    try testing.expectEqual(@as(u32, 4), r.tgt_size);
    try testing.expectEqualSlices(u8, &raw, r.payload);

    try testing.expectError(error.Truncated, Record.parse(&[_]u8{ 0x18, 0x00 }));
    var bad: [Record.encoded_len]u8 = @splat(0);
    std.mem.writeInt(u16, bad[0..2], 0x20, .little);
    try testing.expectError(error.BadHeaderSize, Record.parse(&bad));
}

test "apply: full records copy through verbatim" {
    const gpa = testing.allocator;
    var rec: [Record.encoded_len + 5]u8 = @splat(0);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0104, .little);
    std.mem.writeInt(u32, rec[12..16], 5, .little);
    @memcpy(rec[Record.encoded_len..], "hello");
    const out = try apply(gpa, try Record.parse(&rec), &[_]u8{});
    defer gpa.free(out);
    try testing.expectEqualStrings("hello", out);
}

/// Wrap a stream-A/stream-B payload in a delta record header.
fn deltaRecord(buf: []u8, src_size: u32, tgt_size: u32, a: []const u8, b: []const u8) []u8 {
    @memset(buf, 0);
    std.mem.writeInt(u16, buf[0..2], Record.encoded_len, .little);
    std.mem.writeInt(u16, buf[2..4], 0x0004, .little);
    std.mem.writeInt(u32, buf[8..12], src_size, .little);
    std.mem.writeInt(u32, buf[12..16], tgt_size, .little);
    const p = buf[Record.encoded_len..];
    std.mem.writeInt(u32, p[0..4], @intCast(a.len), .little);
    std.mem.writeInt(u32, p[4..8], @intCast(b.len), .little);
    @memcpy(p[8..][0..a.len], a);
    @memcpy(p[8 + a.len ..][0..b.len], b);
    return buf[0 .. Record.encoded_len + 8 + a.len + b.len];
}

test "apply: every stream-A opcode against a known source" {
    const gpa = testing.allocator;
    const src = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44 };

    // literal "hi" | verbatim 4 from source offset 0 | zero fill 2 | running sum 2 at offset 4.
    var a: [17]u8 = undefined;
    var n: usize = 0;
    std.mem.writeInt(u16, a[n..][0..2], 0x0000 | 2, .little);
    n += 2;
    a[n] = 'h';
    a[n + 1] = 'i';
    n += 2;
    std.mem.writeInt(u16, a[n..][0..2], 0x4000 | 4, .little);
    n += 2;
    a[n] = 0x7E; // signed varint -2: source pointer moves back to 0
    n += 1;
    std.mem.writeInt(u16, a[n..][0..2], 0xC000 | 2, .little);
    n += 2;
    std.mem.writeInt(u16, a[n..][0..2], 0x8000 | 2, .little);
    n += 2;
    a[n] = 0x7E; // -2: back to source offset 4
    n += 1;

    var buf: [64]u8 = undefined;
    const rec = deltaRecord(&buf, src.len, 10, a[0..n], &.{});
    const out = try apply(gpa, try Record.parse(rec), &src);
    defer gpa.free(out);

    // The differenced source at lane 4 is src[4..6] - src[2..4] = 0x2211 - 0xDDCC = 0x4445, and
    // the running sum adds the previous output lane, which the zero fill left at 0.
    try testing.expectEqualSlices(u8, &[_]u8{ 'h', 'i', 0xAA, 0xBB, 0xCC, 0xDD, 0x00, 0x00, 0x45, 0x44 }, out);
}

test "apply: stream B adds its accumulator at each delta-coded offset" {
    const gpa = testing.allocator;
    const src = [_]u8{0} ** 8;

    // Stream A: eight zero-filled bytes, so stream B is the only thing that writes.
    var a: [2]u8 = undefined;
    std.mem.writeInt(u16, a[0..2], 0xC000 | 8, .little);
    // Stream B: value 3 at offsets 0 and 4, then a value of 0 to end the stream.
    const b = [_]u8{ 3, 0, 4, 0, 0 };

    var buf: [64]u8 = undefined;
    const rec = deltaRecord(&buf, src.len, 8, &a, &b);
    const out = try apply(gpa, try Record.parse(rec), &src);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 0, 0, 3, 0, 0, 0 }, out);
}

test "apply: refuses a source of the wrong size" {
    const gpa = testing.allocator;
    var rec: [Record.encoded_len]u8 = @splat(0);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0004, .little);
    std.mem.writeInt(u32, rec[8..12], 802816, .little);
    try testing.expectError(error.SourceSizeMismatch, apply(gpa, try Record.parse(&rec), &[_]u8{ 1, 2, 3 }));
}

test "carve finds an MPQ at an arbitrary offset" {
    var buf: [128]u8 = @splat(0);
    @memcpy(buf[64..68], "MPQ\x1a");
    std.mem.writeInt(u32, buf[68..72], 32, .little); // headerSize
    std.mem.writeInt(u32, buf[72..76], 64, .little); // archiveSize
    const got = carve(&buf) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 64), got.len);
    try testing.expect(carve(buf[0..32]) == null);
}
