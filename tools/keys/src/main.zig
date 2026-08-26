//! What key material a Diablo II installation is carrying, and what a key decodes to.
//!
//! Diablo II does not keep the CD key in the registry. It keeps it inside one of the game's own
//! MPQs, under the name of an ordinary asset — a cursor sound for the classic key, an Amazon
//! animation for the expansion one — so neither a directory listing nor a glance at the archive
//! shows anything unusual. `d2-bnet`'s `keystore` holds the names and the search order; this
//! walks a real installation with them.
//!
//! No key is written anywhere by this program, and none is committed to the repository.

const std = @import("std");
const bnet = @import("d2-bnet");
const formats = @import("d2-formats");

const keystore = bnet.keystore;
const cdkey = bnet.cdkey;
const mpq = formats.mpq;

const Dir = std.Io.Dir;

const usage =
    \\keys — the CD key material in a Diablo II installation
    \\
    \\  keys find <game-dir>     which archive holds the key blobs, and whether they look intact
    \\  keys decode <key>        what a 16- or 26-character key decodes to
    \\
    \\`find` reads only; it never writes to the installation.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 3) {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    }

    if (std.mem.eql(u8, argv[1], "decode")) return decode(argv[2]);
    if (std.mem.eql(u8, argv[1], "find")) return find(gpa, init.io, argv[2]);

    std.debug.print("{s}", .{usage});
    return error.Usage;
}

/// A key on its own says which product it is for and carries the two values Battle.net checks.
/// Sixteen characters is classic, twenty-six is the expansion; nothing else is a Diablo II key.
fn decode(key: []const u8) !void {
    if (key.len == 16) {
        const d = cdkey.decode16(key) orelse {
            std.debug.print("not a valid 16-character key\n", .{});
            return error.BadKey;
        };
        std.debug.print("classic key\n  product {d}\n  public  {d}\n  private {d}\n", .{ d.product, d.public, d.private });
        return;
    }
    if (key.len == 26) {
        const d = cdkey.decode26(key) orelse {
            std.debug.print("not a valid 26-character key\n", .{});
            return error.BadKey;
        };
        std.debug.print("expansion key\n  product {d}\n  public  {d}\n", .{ d.product, d.public });
        return;
    }
    std.debug.print("a Diablo II key is 16 characters (classic) or 26 (expansion); this is {d}\n", .{key.len});
    return error.BadKey;
}

/// Walk the archives the game itself searches, in its order, and report every blob found. The
/// container is not stable across releases — a 2001 install put the classic key in d2sfx.mpq
/// where a 1.14b one puts it in d2data.mpq — so every archive is tried rather than one assumed.
fn find(gpa: std.mem.Allocator, io: std.Io, game: []const u8) !void {
    std.debug.print("{s}\n", .{game});

    var seen: usize = 0;
    for (keystore.search_order) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, name });
        defer gpa.free(path);
        const bytes = readFile(gpa, io, path) catch continue;
        defer gpa.free(bytes);
        var archive = mpq.Archive.open(gpa, bytes) catch continue;
        defer archive.deinit(gpa);

        for ([_]Wanted{
            .{ .label = "classic key", .member = keystore.Product.classic.member() },
            .{ .label = "expansion key", .member = keystore.Product.expansion.member() },
            .{ .label = "owner", .member = keystore.owner_member },
        }) |w| {
            const blob = archive.read(gpa, w.member) catch continue;
            defer gpa.free(blob);
            seen += 1;
            std.debug.print("  {s: <14} {s: <12} {d} bytes  {s}\n", .{
                w.label,
                name,
                blob.len,
                if (keystore.plausible(blob)) "header + whole blocks" else "NOT a key blob shape",
            });
        }
    }

    if (seen == 0) {
        std.debug.print("  no key material — this installation has never had a key entered\n", .{});
        return;
    }
    // Saying so is the honest thing: the blobs are found, the cipher over them is not ported.
    std.debug.print("\n  found {d}; reading their contents needs the Bnclient cipher, which is not ported yet\n", .{seen});
}

const Wanted = struct { label: []const u8, member: []const u8 };

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = if (std.fs.path.isAbsolute(path))
        try Dir.openFileAbsolute(io, path, .{ .mode = .read_only })
    else
        try Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}
