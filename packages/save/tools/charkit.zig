//! charkit build <spec> <out.d2s> --name <character name> [--created <epoch seconds>] [--seed <n>]
//! charkit inspect <file.d2s> [--items]
//!
//! `build` turns a character spec (see src/charkit.zig for the format) into a .d2s, reads the file back and
//! prints what it holds. `inspect` prints the same for any save. The item seed makes a build repeatable: the same
//! spec, name, creation time and seed give the same bytes.
const std = @import("std");
const save = @import("d2-save");
const charkit = save.charkit;
const kititem = save.kititem;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fwrite(buf: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;

const gpa = std.heap.c_allocator;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "error\n";
    _ = std.c.write(2, s.ptr, s.len);
    std.process.exit(1);
}

fn readFile(path: []const u8) ![]u8 {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const f = fopen(z, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const f = fopen(z, "wb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    if (fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.WriteFailed;
}

fn printItems(arena: std.mem.Allocator, label: []const u8, list: save.Items, level: u8) !void {
    var d = try save.describe.itemtext.Describer.init(arena);
    defer d.deinit();
    var items: std.ArrayList(save.wire.Item) = .empty;
    var it = list.iterator();
    while (it.next()) |w| try items.append(arena, w);
    const views = try d.describeList(arena, items.items, .{ .char_level = level });
    for (views) |v| {
        const loc = v.location;
        say("{s} {s} ({d},{d}) body={d} {s}{s} [{s}] ilvl {d} sockets {d}\n", .{ label, @tagName(loc.place), loc.x, loc.y, loc.body_loc, if (v.ethereal) "ETH " else "", v.name, v.code, v.ilvl, v.sockets });
        if (v.runeword) |rw| say("    runeword {s}\n", .{rw});
        for (v.lines) |l| say("    {s}\n", .{l.text});
        for (v.set_bonus) |l| say("    set: {s}\n", .{l.text});
        for (v.socketed) |k| say("    in socket: {s} [{s}]\n", .{ k.name, k.code });
    }
}

fn listItems(arena: std.mem.Allocator, bytes: []const u8) !void {
    const s = try save.parse(bytes);
    try printItems(arena, "player", s.items, s.header.level);
    if (std.mem.indexOf(u8, s.items.bytes, "jfJM")) |at| try printItems(arena, "merc  ", .{ .bytes = s.items.bytes[at + 2 ..] }, s.header.level);
}

fn report(bytes: []const u8) !void {
    const r = try charkit.readback(bytes);
    say("class {s} level {d}\n", .{ charkit.class_names[r.class], r.level });
    say("str {d} dex {d} vit {d} ene {d}  unspent stat points {d}, skill points {d}\n", .{ r.str, r.dex, r.vit, r.ene, r.unspent_stats, r.unspent_skills });
    say("life {d} mana {d} stamina {d}\n", .{ r.max_life, r.max_mana, r.max_stamina });
    say("skill points spent {d}\n", .{r.skill_points_spent});
    say("quests of Acts I-V all done: {}, Act VI quest words used: {d}\n", .{ r.quests_done, r.act6_quest_words });
    say("waypoints per difficulty: {d} {d} {d}\n", .{ r.waypoints[0], r.waypoints[1], r.waypoints[2] });
    say("items: player {d}, mercenary {d}; mercenary type {d}\n", .{ r.player_items, r.merc_items, r.merc_type });
    say("checksum ok: {}\n", .{r.checksum_ok});
    if (save.sections.d2s.parseHeader(bytes)) |h| {
        const nm = h.name[0 .. std.mem.indexOfScalar(u8, &h.name, 0) orelse h.name.len];
        if (charkit.engineRefusal(bytes, nm)) |code| say("engine load check: REFUSED, code {d}\n", .{code}) else say("engine load check: ok\n", .{});
    if (save.parse(bytes)) |sv| {
        if (charkit.itemListFault(sv.items.bytes)) |f| say("engine item load: REFUSED at top-level item {d}, byte {d} of the item section: {s}\n", .{ f.index, f.at, f.reason }) else say("engine item load: ok\n", .{});
    } else |_| {}
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse fatal("usage: charkit build <spec> <out.d2s> --name <name> [--created <secs>] [--seed <n>] | charkit inspect <file.d2s>", .{});
    if (std.mem.eql(u8, cmd, "inspect")) {
        const path = args.next() orelse fatal("inspect needs a file", .{});
        const bytes = readFile(path) catch fatal("cannot read {s}", .{path});
        try report(bytes);
        if (args.next()) |opt| {
            if (!std.mem.eql(u8, opt, "--items")) fatal("unknown option {s}", .{opt});
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            try listItems(arena.allocator(), bytes);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "patch")) {
        // charkit patch <played.d2s> <spec> <out.d2s> [--seed n]: the spec's mercenary items, and the spec's version of a
        // unique or set item that sits on another base in the save, written into a save that has been played
        const cur_path = args.next() orelse fatal("patch needs the save", .{});
        const spec_path = args.next() orelse fatal("patch needs a spec", .{});
        const out_path = args.next() orelse fatal("patch needs an output file", .{});
        var seed: u32 = 0x5eed;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--seed")) seed = std.fmt.parseInt(u32, args.next() orelse fatal("--seed needs a value", .{}), 0) catch fatal("bad --seed", .{}) else fatal("unknown option {s}", .{a});
        }
        const cur = readFile(cur_path) catch fatal("cannot read {s}", .{cur_path});
        const text = readFile(spec_path) catch fatal("cannot read {s}", .{spec_path});
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const spec = charkit.parseSpec(arena.allocator(), text) catch |e| fatal("spec: {s}", .{@errorName(e)});
        var maker = try kititem.Maker.init(gpa, .expansion, seed);
        defer maker.deinit();
        var diag = charkit.Diag{};
        const out = charkit.patchItems(gpa, cur, spec, .{ .diag = &diag }, charkit.kitSource(&maker)) catch |e| {
            if (diag.line.len != 0) fatal("item `{s}`: {s}", .{ diag.line, diag.err });
            fatal("patch: {s}", .{@errorName(e)});
        };
        try writeFile(out_path, out);
        say("wrote {s} ({d} bytes)\n", .{ out_path, out.len });
        try report(out);
        return;
    }
    if (!std.mem.eql(u8, cmd, "build")) fatal("unknown command {s}", .{cmd});
    const spec_path = args.next() orelse fatal("build needs a spec", .{});
    const out_path = args.next() orelse fatal("build needs an output file", .{});
    var name: []const u8 = "";
    var created: u32 = (charkit.Options{}).created;
    var seed: u32 = 0x5eed;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--name")) name = args.next() orelse fatal("--name needs a value", .{}) else if (std.mem.eql(u8, a, "--created")) created = std.fmt.parseInt(u32, args.next() orelse fatal("--created needs a value", .{}), 10) catch fatal("bad --created", .{}) else if (std.mem.eql(u8, a, "--seed")) seed = std.fmt.parseInt(u32, args.next() orelse fatal("--seed needs a value", .{}), 0) catch fatal("bad --seed", .{}) else fatal("unknown option {s}", .{a});
    }
    if (name.len == 0) fatal("--name is required", .{});
    const text = readFile(spec_path) catch fatal("cannot read {s}", .{spec_path});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const spec = charkit.parseSpec(arena.allocator(), text) catch |e| fatal("spec: {s}", .{@errorName(e)});
    var maker = try kititem.Maker.init(gpa, .expansion, seed);
    defer maker.deinit();
    var diag = charkit.Diag{};
    const out = charkit.compose(gpa, spec, name, .{ .created = created, .diag = &diag }, charkit.kitSource(&maker)) catch |e| {
        if (diag.line.len != 0) fatal("item `{s}`: {s}", .{ diag.line, diag.err });
        fatal("build: {s}", .{@errorName(e)});
    };
    try writeFile(out_path, out);
    say("wrote {s} ({d} bytes)\n", .{ out_path, out.len });
    try report(out);
}
