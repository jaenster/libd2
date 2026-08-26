//! What key material a Diablo II installation is carrying, and what a key decodes to.
//!
//! Diablo II does not keep the CD key in the registry. It keeps it inside one of the game's own
//! MPQs, under the name of an ordinary asset — a cursor sound for the classic key, an Amazon
//! animation for the expansion one — so neither a directory listing nor a glance at the archive
//! shows anything unusual. `d2-bnet`'s `keystore` holds the names and the search order; this
//! walks a real installation with them.
//!
//! Verified against the game: `d2-bnet`'s wrapper produces blobs the real Bnclient.dll accepts,
//! so what `show` prints is what the game would read.
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
    \\  keys show <game-dir>     the keys and owner an installation is carrying
    \\  keys find <game-dir>     which archive holds the key blobs, without decrypting them
    \\  keys decode <key>        what a 16- or 26-character key decodes to
    \\
    \\Both `show` and `find` read only; neither writes to the installation.
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
    if (std.mem.eql(u8, argv[1], "find")) return walk(gpa, init.io, argv[2], false);
    if (std.mem.eql(u8, argv[1], "show")) return walk(gpa, init.io, argv[2], true);

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
fn walk(gpa: std.mem.Allocator, io: std.Io, game: []const u8, reveal: bool) !void {
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
            if (!reveal) {
                std.debug.print("  {s: <14} {s: <12} {d} bytes  {s}\n", .{
                    w.label,
                    name,
                    blob.len,
                    if (keystore.plausible(blob)) "header + whole blocks" else "NOT a key blob shape",
                });
                continue;
            }
            const pw = keystore.blockKey();
            const n = keystore.decrypt(blob, &pw) orelse {
                std.debug.print("  {s: <14} {s: <12} {d} bytes, would not decrypt\n", .{ w.label, name, blob.len });
                continue;
            };
            // The length includes the NUL the installer encrypted with the text.
            const text = std.mem.sliceTo(blob[0..n], 0);
            std.debug.print("  {s: <14} {s: <12} {s}\n", .{ w.label, name, text });
        }
    }

    if (seen == 0) {
        std.debug.print("  no key material — this installation has never had a key entered\n", .{});
        return;
    }
    if (!reveal) std.debug.print("\n  found {d}; `keys show` reads them\n", .{seen});
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
