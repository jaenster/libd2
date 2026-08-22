//! Diablo II string tables — `data/local/lng/<lang>/*.tbl`.
//!
//! Every label the game shows is a number, and this is what turns one back into words. Three files
//! hold them and which one answers depends on the number's size; `Set` implements that routing so a
//! caller only ever has an id.
//!
//! ## Layout
//!
//!     0x00 u16 crc
//!     0x02 u16 element count       ids run 0..count-1
//!     0x04 u32 hash table size     how many entries follow
//!     0x08 u8  version
//!     0x09 u32 data start offset
//!     0x0d u32 hash max tries      only the by-name lookup needs it
//!     0x11 u32 file size           equals the file's real length, which is how to check a parse
//!     0x15     u16 index[count]    id -> entry number
//!              entry[hash size]    17 bytes each
//!
//! An entry is `u8 used, u16 id, u32 hash, u32 key offset, u32 string offset, u16 length`. The key
//! is a name for the string and is almost always the placeholder `"x"`, which is why the value sits
//! two bytes past it. Both are NUL-terminated; `length` counts the terminator.
//!
//! Lookup is `index[id]`, not the hash. The hash exists for finding a string by its key name, which
//! is what the .txt loaders do; the UI only ever has a number.
const std = @import("std");

pub const Error = error{ ShortStringTable, BadStringTable };

pub const header_len = 0x15;
pub const entry_len = 17;

/// The offsets `GetLocaleString` adds before consulting the patch and expansion tables. They are
/// deliberately applied with u16 wraparound — that is what the game does, and the numbers only make
/// sense modulo 65536.
pub const patch_bias: u16 = 0xd8f0;
pub const expansion_bias: u16 = 0xb1e0;
pub const patch_min: u16 = 10000;
pub const expansion_min: u16 = 20000;

pub const Table = struct {
    /// Borrowed. The strings point into it, so it must outlive every slice handed out.
    bytes: []const u8,
    count: u16,
    hash_size: u32,

    pub fn parse(bytes: []const u8) Error!Table {
        if (bytes.len < header_len) return Error.ShortStringTable;

        const count = std.mem.readInt(u16, bytes[2..4], .little);
        const hash_size = std.mem.readInt(u32, bytes[4..8], .little);
        const file_size = std.mem.readInt(u32, bytes[0x11..0x15], .little);

        // The header records its own file's length. Anything else means this is not one of these.
        if (file_size != bytes.len) return Error.BadStringTable;

        const need = header_len + @as(usize, count) * 2 + @as(usize, hash_size) * entry_len;
        if (bytes.len < need) return Error.ShortStringTable;

        return .{ .bytes = bytes, .count = count, .hash_size = hash_size };
    }

    /// The string for an id, or null if this table does not have it.
    pub fn get(self: *const Table, id: u16) ?[]const u8 {
        if (id >= self.count) return null;

        const slot = std.mem.readInt(u16, self.bytes[header_len + @as(usize, id) * 2 ..][0..2], .little);
        if (slot >= self.hash_size) return null;

        const at = header_len + @as(usize, self.count) * 2 + @as(usize, slot) * entry_len;
        if (self.bytes[at] != 1) return null;

        const str_off = std.mem.readInt(u32, self.bytes[at + 11 ..][0..4], .little);
        if (str_off >= self.bytes.len) return null;

        const end = std.mem.indexOfScalarPos(u8, self.bytes, str_off, 0) orelse return null;
        return self.bytes[str_off..end];
    }
};

/// The three tables, consulted the way `GetLocaleString` consults them.
pub const Set = struct {
    base: ?Table = null,
    patch: ?Table = null,
    expansion: ?Table = null,

    /// Highest number first, and each table gets a chance before the next: an id above 19999 is
    /// looked for in the expansion table, one above 9999 in the patch table, and everything falls
    /// through to the base. A miss falls through rather than failing, which is how a patch adds
    /// strings without restating the ones it did not change.
    pub fn get(self: *const Set, id: u16) ?[]const u8 {
        if (id >= expansion_min) {
            if (self.expansion) |t| {
                if (t.get(id +% expansion_bias)) |s| return s;
            }
        }
        if (id >= patch_min) {
            if (self.patch) |t| {
                if (t.get(id +% patch_bias)) |s| return s;
            }
        }
        if (self.base) |t| return t.get(id);
        return null;
    }
};

const testing = std.testing;

/// Build a one-entry table so the parser is exercised against the layout rather than a real file.
fn stub(gpa: std.mem.Allocator, id: u16, value: []const u8) ![]u8 {
    const count: u16 = id + 1;
    const hash_size: u32 = 1;
    const strings_at = header_len + @as(usize, count) * 2 + @as(usize, hash_size) * entry_len;
    const key = "x";
    const total = strings_at + key.len + 1 + value.len + 1;

    const b = try gpa.alloc(u8, total);
    @memset(b, 0);
    std.mem.writeInt(u16, b[2..4], count, .little);
    std.mem.writeInt(u32, b[4..8], hash_size, .little);
    std.mem.writeInt(u32, b[0x11..0x15], @intCast(total), .little);

    // Every id points at entry 0; only `id` is marked used, so the others miss.
    const at = header_len + @as(usize, count) * 2;
    b[at] = 1;
    std.mem.writeInt(u16, b[at + 1 ..][0..2], id, .little);
    std.mem.writeInt(u32, b[at + 7 ..][0..4], @intCast(strings_at), .little);
    std.mem.writeInt(u32, b[at + 11 ..][0..4], @intCast(strings_at + 2), .little);
    std.mem.writeInt(u16, b[at + 15 ..][0..2], @intCast(value.len + 1), .little);

    @memcpy(b[strings_at..][0..1], key);
    @memcpy(b[strings_at + 2 ..][0..value.len], value);
    return b;
}

test "an id resolves through the index array to its string" {
    const gpa = testing.allocator;
    const b = try stub(gpa, 3, "Select Hero Class");
    defer gpa.free(b);

    const t = try Table.parse(b);
    try testing.expectEqualStrings("Select Hero Class", t.get(3).?);
}

test "an id past the end is a miss, not a crash" {
    const gpa = testing.allocator;
    const b = try stub(gpa, 3, "EXIT");
    defer gpa.free(b);

    const t = try Table.parse(b);
    try testing.expect(t.get(9999) == null);
}

test "a file whose recorded length disagrees with its own is refused" {
    const gpa = testing.allocator;
    const b = try stub(gpa, 1, "OK");
    defer gpa.free(b);

    std.mem.writeInt(u32, b[0x11..0x15], 12345, .little);
    try testing.expectError(Error.BadStringTable, Table.parse(b));
}

test "the expansion table answers a high id, and the base one the rest" {
    const gpa = testing.allocator;

    // 0x57f7 lands on 2519 in the expansion table once the bias wraps.
    const exp_b = try stub(gpa, 0x57f7 +% expansion_bias, "Schooled in the Martial Arts");
    defer gpa.free(exp_b);
    const base_b = try stub(gpa, 0xfa9, "Necromancer");
    defer gpa.free(base_b);

    const set: Set = .{
        .base = try Table.parse(base_b),
        .expansion = try Table.parse(exp_b),
    };

    try testing.expectEqualStrings("Schooled in the Martial Arts", set.get(0x57f7).?);
    try testing.expectEqualStrings("Necromancer", set.get(0xfa9).?);
}

test "a patch id the patch table does not have falls through to the base" {
    const gpa = testing.allocator;

    const patch_b = try stub(gpa, 5, "unrelated");
    defer gpa.free(patch_b);
    const base_b = try stub(gpa, 0x2771, "from base");
    defer gpa.free(base_b);

    const set: Set = .{
        .base = try Table.parse(base_b),
        .patch = try Table.parse(patch_b),
    };
    try testing.expectEqualStrings("from base", set.get(0x2771).?);
}
