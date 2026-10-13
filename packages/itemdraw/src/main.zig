//! item-draw: draw the items of a character save (or of a file of item records) to PNGs.
//!
//!   item-draw --mpq Patch_D2.mpq --mpq d2exp.mpq --mpq d2data.mpq --out DIR FILE.d2s|FILE.items
//!             [--class N --level N --str N --dex N] [--act N]
//!
//! For every top-level item: `NN-code.items` (its records), `NN-code-icon.png`, `NN-code-tooltip.png`,
//! `NN-code-card.png`, and one `items.txt` with each description top to bottom and the engine's string.

const std = @import("std");
const itemdraw = @import("d2-itemdraw");
const save = @import("d2-save");

fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    var mpqs: std.ArrayListUnmanaged([]const u8) = .empty;
    var out_dir: []const u8 = ".";
    var input: ?[]const u8 = null;
    var viewer: ?itemdraw.Viewer = null;
    var act: u8 = 1;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--mpq")) {
            try mpqs.append(gpa, args.next() orelse fatal("--mpq needs a path", .{}));
        } else if (std.mem.eql(u8, a, "--out")) {
            out_dir = args.next() orelse fatal("--out needs a directory", .{});
        } else if (std.mem.eql(u8, a, "--act")) {
            act = try std.fmt.parseInt(u8, args.next() orelse fatal("--act needs 1..5", .{}), 10);
        } else if (std.mem.eql(u8, a, "--class") or std.mem.eql(u8, a, "--level") or std.mem.eql(u8, a, "--str") or std.mem.eql(u8, a, "--dex")) {
            const v = try std.fmt.parseInt(i32, args.next() orelse fatal("{s} needs a number", .{a}), 10);
            if (viewer == null) viewer = .{ .class = 0, .level = 99, .strength = 1000, .dexterity = 1000 };
            if (std.mem.eql(u8, a, "--class")) viewer.?.class = @intCast(v) else if (std.mem.eql(u8, a, "--level")) viewer.?.level = v else if (std.mem.eql(u8, a, "--str")) viewer.?.strength = v else viewer.?.dexterity = v;
        } else input = a;
    }
    const path = input orelse fatal("usage: item-draw --mpq A [--mpq B ...] --out DIR FILE.d2s|FILE.items [--class N --level N --str N --dex N] [--act N]", .{});

    var assets = itemdraw.Assets.init(gpa);
    defer assets.deinit();
    var keep: std.ArrayListUnmanaged([]u8) = .empty;
    for (mpqs.items) |m| {
        const b = readFile(io, gpa, m) catch fatal("cannot read {s}", .{m});
        try keep.append(gpa, b);
        assets.addArchive(b) catch fatal("{s} is not an MPQ", .{m});
    }
    const drawer = itemdraw.Drawer.init(gpa, &assets, .{ .act = act }) catch |e| fatal("cannot load the art: {s}", .{@errorName(e)});
    defer drawer.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = readFile(io, gpa, path) catch fatal("cannot read {s}", .{path});
    var flat: std.ArrayListUnmanaged(save.wire.Item) = .empty;
    // each record's own bytes, for the NN-code.items files the bindings' tests read
    var raw: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.mem.endsWith(u8, path, ".d2s")) {
        const s = save.parse(bytes) catch fatal("{s} is not a save", .{path});
        var it = s.items.iterator();
        while (it.next()) |w| {
            try flat.append(a, w);
            try raw.append(a, s.items.bytes[it.pos - (w.bit_len + 7) / 8 .. it.pos]);
        }
    } else {
        try flat.appendSlice(a, try itemdraw.parseRecords(a, bytes, 4096));
        var pos: usize = 0;
        for (flat.items) |w| {
            const len = (w.bit_len + 7) / 8;
            try raw.append(a, bytes[pos .. pos + len]);
            pos += len;
        }
    }

    // with a viewer, the set pieces in the file are the ones the character has, the equipped ones worn
    if (viewer) |*v| {
        var owned: std.ArrayListUnmanaged(u16) = .empty;
        var worn: std.ArrayListUnmanaged(u16) = .empty;
        for (flat.items) |w| {
            if (w.quality != .set or !w.identified()) continue;
            try owned.append(a, w.set_id);
            if (w.dest == save.wire.Mode.equipped) try worn.append(a, w.set_id);
        }
        v.set_items_owned = owned.items;
        v.set_items_worn = worn.items;
    }
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};
    var listing: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var n: usize = 0;
    while (i < flat.items.len) : (n += 1) {
        const count = 1 + @min(flat.items[i].socketed_count, flat.items.len - i - 1);
        const recs = flat.items[i .. i + count];
        const rec_bytes = try std.mem.concat(a, u8, raw.items[i .. i + count]);
        i += count;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{d:0>2}-{s}.items", .{ out_dir, n, recs[0].codeSlice() }), .data = rec_bytes });
        const opts = itemdraw.DescOptions{ .viewer = viewer };
        const desc = try drawer.describe(a, recs, opts);
        try listing.print(a, "== {d:0>2} {s}\n{s}\n", .{ n, recs[0].codeSlice(), try itemdraw.itemdesc.plain(a, desc) });
        // the engine's own string, bottom line first, colour codes as {N}
        try listing.appendSlice(a, "   engine: ");
        var p: usize = 0;
        while (p < desc.text.len) : (p += 1) {
            if (std.mem.startsWith(u8, desc.text[p..], itemdraw.itemdesc.color_code) and p + 3 < desc.text.len) {
                try listing.print(a, "{{{c}}}", .{desc.text[p + 3]});
                p += 3;
            } else if (desc.text[p] == '\n') try listing.appendSlice(a, " | ") else try listing.append(a, desc.text[p]);
        }
        try listing.appendSlice(a, "\n\n");
        const kinds = [_][]const u8{ "icon", "tooltip", "card" };
        for (kinds) |k| {
            var img = if (std.mem.eql(u8, k, "icon"))
                try drawer.icon(recs, .{ .background = .normal })
            else if (std.mem.eql(u8, k, "tooltip"))
                try drawer.tooltip(desc)
            else
                try drawer.card(recs, opts);
            defer img.deinit(gpa);
            const png = try img.png(gpa);
            defer gpa.free(png);
            const name = try std.fmt.allocPrint(a, "{s}/{d:0>2}-{s}-{s}.png", .{ out_dir, n, recs[0].codeSlice(), k });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = png });
        }
    }
    const lp = try std.fmt.allocPrint(a, "{s}/items.txt", .{out_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = listing.items });
    std.debug.print("drew {d} items into {s}\n", .{ n, out_dir });
}
