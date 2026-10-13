//! Where the art comes from. libd2 carries none of it: the caller hands in the game's archives (searched in
//! the order they were added, as the game searches Patch_D2, d2exp, d2data) and loose files, which win over
//! the archives. Names are the game's own paths; case and `/` versus `\` do not matter.

const std = @import("std");
const formats = @import("d2-formats");
const mpq = formats.mpq;

pub const Error = error{ NoSuchFile, OutOfMemory };

pub const Assets = struct {
    gpa: std.mem.Allocator,
    archives: mpq.Set = .{},
    files: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn init(gpa: std.mem.Allocator) Assets {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Assets) void {
        self.archives.deinit(self.gpa);
        var it = self.files.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.files.deinit(self.gpa);
    }

    /// Add an MPQ. The bytes are not copied and must outlive the assets.
    pub fn addArchive(self: *Assets, bytes: []const u8) !void {
        try self.archives.add(self.gpa, bytes);
    }

    /// Add one file under its game path. The bytes are copied.
    pub fn addFile(self: *Assets, name: []const u8, bytes: []const u8) !void {
        const key = try normalise(self.gpa, name);
        errdefer self.gpa.free(key);
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        const gop = try self.files.getOrPut(self.gpa, key);
        if (gop.found_existing) {
            self.gpa.free(key);
            self.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = copy;
    }

    /// The bytes of `name`, owned by the caller.
    pub fn read(self: *const Assets, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: [260]u8 = undefined;
        if (name.len > buf.len) return Error.NoSuchFile;
        for (name, 0..) |ch, i| buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        const key = buf[0..name.len];
        if (self.files.get(key)) |b| return gpa.dupe(u8, b);
        // MPQ names use backslashes; the hash is case-insensitive
        for (key) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
        if (!self.archives.has(key)) return Error.NoSuchFile;
        return self.archives.read(gpa, key) catch Error.NoSuchFile;
    }

    pub fn has(self: *const Assets, name: []const u8) bool {
        var buf: [260]u8 = undefined;
        if (name.len > buf.len) return false;
        for (name, 0..) |ch, i| buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        if (self.files.contains(buf[0..name.len])) return true;
        for (buf[0..name.len]) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
        return self.archives.has(buf[0..name.len]);
    }
};

fn normalise(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |ch, i| out[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
    return out;
}

test "loose files are found by any spelling of their path" {
    var a = Assets.init(std.testing.allocator);
    defer a.deinit();
    try a.addFile("DATA\\GLOBAL\\items\\invamu1.dc6", "x");
    const b = try a.read(std.testing.allocator, "data/global/ITEMS/invamu1.dc6");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("x", b);
    try std.testing.expect(!a.has("data/global/items/invamu2.dc6"));
}
