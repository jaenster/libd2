//! Where sprite bytes come from: a stack of MPQs searched in the game's order, the names their
//! listfiles know, and loose files on disk.
//!
//! Member names are presented lowercased with `/` separators. MPQ name hashing folds case and
//! treats `/` and `\` alike, so that spelling reads the same member and is one a shell can quote
//! without escaping.

const std = @import("std");
const formats = @import("d2-formats");
const mpq = formats.mpq;
const Dir = std.Io.Dir;

pub const default_archives = [_][]const u8{ "patch_d2.mpq", "d2exp.mpq", "d2data.mpq", "d2char.mpq" };

pub const Source = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    set: mpq.Set = .{},
    /// Every listed name that resolves in at least one archive, lowercased, `/`-separated, sorted.
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    archive_paths: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Open the archives at `paths`, then read the names from each one's `(listfile)` and from
    /// every file in `listfiles`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8, listfiles: []const []const u8) !Source {
        var s: Source = .{ .gpa = gpa, .io = io };
        for (paths) |p| {
            const bytes = try readFile(gpa, io, p);
            try s.set.add(gpa, bytes);
            try s.archive_paths.append(gpa, p);
        }

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (s.set.archives.items) |a| {
            const lf = a.read(gpa, "(listfile)") catch continue;
            try s.addNames(&seen, lf);
        }
        for (listfiles) |p| try s.addNames(&seen, try readFile(gpa, io, p));
        std.mem.sort([]const u8, s.names.items, {}, lessThan);
        return s;
    }

    fn addNames(s: *Source, seen: *std.StringHashMapUnmanaged(void), text: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, text, "\r\n;");
        while (it.next()) |raw| {
            const name = try normalise(s.gpa, std.mem.trim(u8, raw, " \t"));
            if (name.len == 0 or seen.contains(name)) continue;
            if (!s.set.has(name)) continue;
            try seen.put(s.gpa, name, {});
            try s.names.append(s.gpa, name);
        }
    }

    /// A member of the archives, or a file on disk when `name` names one.
    pub fn read(s: *const Source, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        if (isLooseFile(s.io, name)) return readFile(gpa, s.io, name);
        return s.set.read(gpa, name) catch |e| switch (e) {
            error.NoSuchFile => error.FileNotFound,
            else => e,
        };
    }

    pub fn has(s: *const Source, name: []const u8) bool {
        return isLooseFile(s.io, name) or s.set.has(name);
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn normalise(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, name);
    for (out) |*c| c.* = if (c.* == '\\') '/' else std.ascii.toLower(c.*);
    return out;
}

fn isLooseFile(io: std.Io, name: []const u8) bool {
    const st = Dir.cwd().statFile(io, name, .{}) catch return false;
    return st.kind == .file;
}

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

/// The default archives present in `game_dir`, matched without regard to case, in search order.
pub fn defaultArchives(gpa: std.mem.Allocator, io: std.Io, game_dir: []const u8) ![]const []const u8 {
    var dir = Dir.cwd().openDir(io, game_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var found: [default_archives.len]?[]const u8 = @splat(null);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        for (default_archives, 0..) |want, i| {
            if (std.ascii.eqlIgnoreCase(e.name, want)) found[i] = try std.fs.path.join(gpa, &.{ game_dir, e.name });
        }
    }
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (found) |f| if (f) |p| try out.append(gpa, p);
    return out.toOwnedSlice(gpa);
}

/// Glob over a normalised name: `*` stops at `/`, `**` does not, `?` is one character. Case is
/// folded and `\` in the pattern reads as `/`.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    // Backtrack point for the most recent star.
    var star_p: ?usize = null;
    var star_n: usize = 0;
    var star_deep = false;
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_deep = p + 1 < pattern.len and pattern[p + 1] == '*';
            p += if (star_deep) 2 else 1;
            star_p = p;
            star_n = n;
            continue;
        }
        if (p < pattern.len and charEq(pattern[p], name[n])) {
            p += 1;
            n += 1;
            continue;
        }
        if (star_p) |sp| {
            if (!star_deep and name[star_n] == '/') return false;
            star_n += 1;
            n = star_n;
            p = sp;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn charEq(pc: u8, nc: u8) bool {
    if (pc == '?') return nc != '/';
    const a = if (pc == '\\') '/' else std.ascii.toLower(pc);
    return a == nc;
}

test "glob: a star stays in its directory, two stars do not" {
    try std.testing.expect(globMatch("data/global/items/*.dc6", "data/global/items/invcap.dc6"));
    try std.testing.expect(!globMatch("data/global/items/*.dc6", "data/global/items/palette/x.dc6"));
    try std.testing.expect(globMatch("data/**.dc6", "data/global/items/palette/x.dc6"));
    try std.testing.expect(globMatch("DATA\\Global\\items\\INV???.DC6", "data/global/items/invcap.dc6"));
    try std.testing.expect(!globMatch("*.dcc", "data/x.dc6"));
    try std.testing.expect(globMatch("**", "a/b/c"));
}
