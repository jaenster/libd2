//! BNFTP — Battle.net File Transfer, protocol selector 0x02 on the Battle.net port.
//!
//! After SID_AUTH_INFO names a version-check MPQ, the client opens a SECOND connection, sends
//! the byte 0x02, and requests that file. The MPQ carries the CheckRevision module whose output
//! is the client's version checksum, so a realm has to serve this correctly before anyone can
//! log in. It also carries ads, news and the MOTD.
//!
//! This is the wire format and nothing else: encode and decode, both directions, no sockets. The
//! transport belongs to whoever is doing the talking — that is what lets the same definitions
//! serve a client fetching a file, a server answering, and a probe pointed at Blizzard.
//!
//! Layout (BNFTP v1, protocol version 0x0100). Request, after the 0x02 selector:
//!
//!     u16 reqLen | u16 protocolVer | u32 platform | u32 product | u32 bannerId
//!     u32 bannerExt | u32 startPos | u64 fileTime | cstr filename
//!
//! Reply:
//!
//!     u32 headerLen | u32 fileSize | u32 bannerId | u32 bannerExt | u64 fileTime
//!     cstr filename | <file bytes from startPos>
//!
//! headerLen is a **u32**, not the u16 it is often written as: BnetDownloadFile_II @0x51f310
//! reads the first four bytes as the length and halts if the value exceeds 0xff, and
//! BNDOWNLOAD_GetCachedFileSize reads fileSize at 4, fileTime at 0x10 and the name at 0x18.
//! A server that writes u16 there puts fileSize two bytes off and the client reads garbage.
//!
//! A fileSize of zero is how a server says "not hosted". It is not an error and not an empty
//! file — the client is expected to carry on without it.

const std = @import("std");

/// The first byte of a BNFTP connection, in place of BNCS's 0x01.
pub const protocol_selector: u8 = 0x02;

/// The only protocol version 1.14d speaks.
pub const version_1: u16 = 0x0100;

pub const Error = error{
    /// Fewer bytes than the smallest possible header — the peer hung up early.
    Short,
    /// headerLen below the fixed part, so the documented offsets are not all present.
    BadHeaderLen,
    /// The caller's buffer cannot hold the encoded form.
    NoSpace,
    /// A cstr with no terminator inside the message.
    UnterminatedName,
};

/// A four-character code as it sits on the wire. D2 stores these reversed, so "IX86" is the
/// u32 0x36385849 — writing the string little-endian is what produces that.
pub fn fourcc(s: []const u8) u32 {
    var b = [_]u8{ 0, 0, 0, 0 };
    const n = @min(s.len, 4);
    @memcpy(b[0..n], s[0..n]);
    return std.mem.readInt(u32, &b, .little);
}

pub const platform_ix86 = fourcc("IX86");

pub const Request = struct {
    /// Everything up to the filename is fixed width: 2+2+4+4+4+4+4+8 = 32, plus at least the
    /// name's terminator. A request shorter than this cannot be one.
    pub const min_len: usize = 33;

    protocol_ver: u16 = version_1,
    platform: u32 = platform_ix86,
    product: u32,
    banner_id: u32 = 0,
    banner_ext: u32 = 0,
    /// Resume offset. Zero fetches the whole file.
    start_pos: u32 = 0,
    /// The copy the CLIENT already has, so the server can skip sending an unchanged file.
    /// Zero means "I have nothing".
    file_time: u64 = 0,
    filename: []const u8,

    /// Write the request into `buf`, length-prefix included, and return the bytes used. The
    /// 0x02 selector is NOT included: it is sent once when the connection opens, not per
    /// request, and putting it here would make it easy to send twice.
    pub fn encode(self: Request, buf: []u8) Error![]u8 {
        const n = 32 + self.filename.len + 1;
        if (buf.len < n or n > std.math.maxInt(u16)) return Error.NoSpace;
        std.mem.writeInt(u16, buf[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, buf[2..4], self.protocol_ver, .little);
        std.mem.writeInt(u32, buf[4..8], self.platform, .little);
        std.mem.writeInt(u32, buf[8..12], self.product, .little);
        std.mem.writeInt(u32, buf[12..16], self.banner_id, .little);
        std.mem.writeInt(u32, buf[16..20], self.banner_ext, .little);
        std.mem.writeInt(u32, buf[20..24], self.start_pos, .little);
        std.mem.writeInt(u64, buf[24..32], self.file_time, .little);
        @memcpy(buf[32..][0..self.filename.len], self.filename);
        buf[32 + self.filename.len] = 0;
        return buf[0..n];
    }

    /// Read a request. `filename` borrows from `buf`.
    pub fn decode(buf: []const u8) Error!Request {
        if (buf.len < min_len) return Error.Short;
        const req_len = std.mem.readInt(u16, buf[0..2], .little);
        if (req_len < min_len or req_len > buf.len) return Error.Short;
        const name_end = std.mem.indexOfScalarPos(u8, buf[0..req_len], 32, 0) orelse
            return Error.UnterminatedName;
        return .{
            .protocol_ver = std.mem.readInt(u16, buf[2..4], .little),
            .platform = std.mem.readInt(u32, buf[4..8], .little),
            .product = std.mem.readInt(u32, buf[8..12], .little),
            .banner_id = std.mem.readInt(u32, buf[12..16], .little),
            .banner_ext = std.mem.readInt(u32, buf[16..20], .little),
            .start_pos = std.mem.readInt(u32, buf[20..24], .little),
            .file_time = std.mem.readInt(u64, buf[24..32], .little),
            .filename = buf[32..name_end],
        };
    }

    /// How many bytes the request declares, read from just its first two. A server needs this
    /// before it can know how much more to read.
    pub fn declaredLen(prefix: []const u8) Error!u16 {
        if (prefix.len < 2) return Error.Short;
        return std.mem.readInt(u16, prefix[0..2], .little);
    }
};

pub const ReplyHeader = struct {
    /// headerLen, fileSize, bannerId, bannerExt, fileTime — the offsets the client reads by
    /// name. The filename follows at 0x18.
    pub const fixed_len: usize = 0x18;

    header_len: u32,
    /// Zero means the server is not hosting the file. Not an error.
    file_size: u32,
    banner_id: u32 = 0,
    banner_ext: u32 = 0,
    /// The server's last-write time as a Windows FILETIME (100ns ticks since 1601).
    file_time: u64 = 0,
    filename: []const u8,

    pub fn encode(self: ReplyHeader, buf: []u8) Error![]u8 {
        const n = fixed_len + self.filename.len + 1;
        if (buf.len < n) return Error.NoSpace;
        // Written last, because it counts itself.
        std.mem.writeInt(u32, buf[0..4], @intCast(n), .little);
        std.mem.writeInt(u32, buf[4..8], self.file_size, .little);
        std.mem.writeInt(u32, buf[8..12], self.banner_id, .little);
        std.mem.writeInt(u32, buf[12..16], self.banner_ext, .little);
        std.mem.writeInt(u64, buf[16..24], self.file_time, .little);
        @memcpy(buf[fixed_len..][0..self.filename.len], self.filename);
        buf[fixed_len + self.filename.len] = 0;
        return buf[0..n];
    }

    /// Read a reply header. `filename` borrows from `buf`, and is empty when the header stops
    /// at the fixed part.
    pub fn decode(buf: []const u8) Error!ReplyHeader {
        if (buf.len < fixed_len) return Error.Short;
        const hlen = std.mem.readInt(u32, buf[0..4], .little);
        if (hlen < fixed_len) return Error.BadHeaderLen;
        const name = if (buf.len > fixed_len and hlen > fixed_len) blk: {
            const end = @min(@as(usize, hlen), buf.len);
            const stop = std.mem.indexOfScalarPos(u8, buf[0..end], fixed_len, 0) orelse end;
            break :blk buf[fixed_len..stop];
        } else buf[0..0];
        return .{
            .header_len = hlen,
            .file_size = std.mem.readInt(u32, buf[4..8], .little),
            .banner_id = std.mem.readInt(u32, buf[8..12], .little),
            .banner_ext = std.mem.readInt(u32, buf[12..16], .little),
            .file_time = std.mem.readInt(u64, buf[16..24], .little),
            .filename = name,
        };
    }

    /// Total bytes of the reply: header plus payload. What a reader has to wait for before the
    /// file is complete — stopping early is a truncated file, not a short one, and a truncated
    /// MPQ looks like a corrupt archive rather than a network fault.
    pub fn totalLen(self: ReplyHeader) usize {
        return @as(usize, self.header_len) + self.file_size;
    }

    /// True when the server answered "I do not have that file".
    pub fn notHosted(self: ReplyHeader) bool {
        return self.file_size == 0;
    }
};

const testing = std.testing;

test "a request round-trips" {
    var buf: [256]u8 = undefined;
    const sent = try (Request{
        .product = fourcc("D2XP"),
        .filename = "ver-IX86-1.mpq",
        .start_pos = 0,
    }).encode(&buf);
    try testing.expectEqual(@as(usize, 32 + "ver-IX86-1.mpq".len + 1), sent.len);

    const got = try Request.decode(sent);
    try testing.expectEqual(version_1, got.protocol_ver);
    try testing.expectEqual(platform_ix86, got.platform);
    try testing.expectEqual(fourcc("D2XP"), got.product);
    try testing.expectEqualStrings("ver-IX86-1.mpq", got.filename);
}

test "the request a 1.14d client sends, byte for byte" {
    // Length, then protocol version, platform IX86, product D2XP, no banner, from the start,
    // no local copy, then the name and its terminator.
    var buf: [128]u8 = undefined;
    const sent = try (Request{ .product = fourcc("D2XP"), .filename = "tos.txt" }).encode(&buf);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x28, 0x00, // reqLen = 40
        0x00, 0x01, // protocolVer = 0x0100
        'I',  'X',  '8', '6', // platform
        'D',  '2',  'X', 'P', // product
        0x00, 0x00, 0x00, 0x00, // bannerId
        0x00, 0x00, 0x00, 0x00, // bannerExt
        0x00, 0x00, 0x00, 0x00, // startPos
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fileTime
        't',  'o',  's', '.', 't', 'x', 't', 0x00,
    }, sent);
}

test "the reply header length is a u32, so fileSize lands at 4" {
    // The bug this guards: written as a u16, fileSize would start at offset 2 and the client
    // would read a size built from half the length and half the size.
    var buf: [64]u8 = undefined;
    const hdr = try (ReplyHeader{
        .header_len = 0, // encode fills it in
        .file_size = 0x0001_2345,
        .file_time = 0x01DA_0000_0000_0000,
        .filename = "ver-IX86-1.mpq",
    }).encode(&buf);

    try testing.expectEqual(@as(u32, 0x18 + 14 + 1), std.mem.readInt(u32, hdr[0..4], .little));
    try testing.expectEqual(@as(u32, 0x0001_2345), std.mem.readInt(u32, hdr[4..8], .little));

    const got = try ReplyHeader.decode(hdr);
    try testing.expectEqual(@as(u32, 0x0001_2345), got.file_size);
    try testing.expectEqual(@as(u64, 0x01DA_0000_0000_0000), got.file_time);
    try testing.expectEqualStrings("ver-IX86-1.mpq", got.filename);
    try testing.expectEqual(@as(usize, 0x18 + 15 + 0x12345), got.totalLen());
    try testing.expect(!got.notHosted());
}

test "fileSize zero means not hosted, which is an answer and not a failure" {
    var buf: [64]u8 = undefined;
    const hdr = try (ReplyHeader{ .header_len = 0, .file_size = 0, .filename = "nope.mpq" }).encode(&buf);
    const got = try ReplyHeader.decode(hdr);
    try testing.expect(got.notHosted());
    try testing.expectEqual(got.header_len, got.totalLen());
}

test "a header claiming less than the fixed part is rejected" {
    var buf = [_]u8{0} ** 0x18;
    std.mem.writeInt(u32, buf[0..4], 0x10, .little); // below 0x18
    try testing.expectError(Error.BadHeaderLen, ReplyHeader.decode(&buf));
    try testing.expectError(Error.Short, ReplyHeader.decode(buf[0..8]));
}

test "a truncated or unterminated request is rejected rather than read past" {
    var buf: [128]u8 = undefined;
    const sent = try (Request{ .product = fourcc("D2DV"), .filename = "ads.txt" }).encode(&buf);
    try testing.expectError(Error.Short, Request.decode(sent[0 .. sent.len - 1]));

    var bad: [64]u8 = undefined;
    @memset(&bad, 'x');
    std.mem.writeInt(u16, bad[0..2], 64, .little);
    try testing.expectError(Error.UnterminatedName, Request.decode(&bad));
}

test "fourcc matches the reversed form D2 stores" {
    try testing.expectEqual(@as(u32, 0x3638_5849), fourcc("IX86"));
    try testing.expectEqual(@as(u32, 0x5058_3244), fourcc("D2XP"));
}
