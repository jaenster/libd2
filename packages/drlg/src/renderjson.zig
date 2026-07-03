//! Native DBM-shaped JSON serializer for a whole act. This is the Zig-native mirror
//! of the TS shim's `render()` (packages/drlg/npm/index.ts): it generates the act ONCE
//! via `generateActFull` and emits the exact DeadlyBossMods map JSON — same fields, same
//! DBM shaping (TitleCase name, obj/npc split, level-local subtile coords), same
//! collisionDeflateB64 (zlib-deflate of the LE u16 CollMap, base64). Semantically
//! byte-identical to the shim; produced in one buffer with no wasm/JS boundary.

const std = @import("std");
const lib = @import("lib.zig");

/// DBM `name` overrides: a few ids keep their classic short enum name instead of the
/// TitleCase(displayName) rule. Mirrors DBM_NAME_OVERRIDE in the shim.
fn dbmNameOverride(level_no: i32) ?[]const u8 {
    return switch (level_no) {
        1 => "RogueCamp",
        39 => "CowLevel",
        else => null,
    };
}

/// DBM `displayName` overrides: a few ids diverge from Levels.txt LevelName. Mirrors
/// DBM_DISPLAY_OVERRIDE in the shim.
fn dbmDisplayOverride(level_no: i32) ?[]const u8 {
    return switch (level_no) {
        39 => "The Secret Cow Level",
        else => null,
    };
}

fn dbmDisplayName(ctx: *lib.Ctx, level_no: i32) []const u8 {
    return dbmDisplayOverride(level_no) orelse lib.levelDisplayName(ctx, level_no);
}

/// TitleCase(displayName) with spaces removed (each space-separated word's first ASCII
/// byte uppercased, the rest kept verbatim), unless the id is name-overridden. Writes to
/// `w`. Faithful to `dbmLevelName` in the shim.
fn writeDbmName(w: *std.Io.Writer, level_no: i32, display_name: []const u8) !void {
    if (dbmNameOverride(level_no)) |o| return writeJsonString(w, o);
    try w.writeByte('"');
    var it = std.mem.splitScalar(u8, display_name, ' ');
    while (it.next()) |word| {
        if (word.len == 0) continue; // filter empty words (collapse runs of spaces)
        try writeJsonEscaped(w, word[0..1], true);
        try writeJsonEscaped(w, word[1..], false);
    }
    try w.writeByte('"');
}

/// Write a JSON string literal (with surrounding quotes), escaping per RFC 8259.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeJsonEscaped(w, s, false);
    try w.writeByte('"');
}

/// U+FFFD REPLACEMENT CHARACTER, UTF-8. The shim decodes Objects.txt strings through a
/// WHATWG `TextDecoder('utf-8', {fatal:false})`, which maps every ill-formed byte sequence
/// to this — so we sanitize the same way (some Objects.txt descriptions carry raw non-UTF-8
/// bytes) to stay byte-identical to the shim AND emit valid-UTF-8 JSON.
const replacement = "\xef\xbf\xbd";

/// Decode one UTF-8 sequence at `s[i]` (WHATWG rules): returns `.ok` (a full well-formed
/// char) with its byte length, or `.ok=false` with the number of bytes to skip and replace
/// with a single U+FFFD (matching TextDecoder's maximal-subpart substitution).
fn decodeStep(s: []const u8, i: usize) struct { ok: bool, len: usize } {
    const b0 = s[i];
    var len: usize = undefined;
    var lo2: u8 = 0x80;
    var hi2: u8 = 0xBF;
    switch (b0) {
        0xC2...0xDF => len = 2,
        0xE0 => {
            len = 3;
            lo2 = 0xA0;
        },
        0xE1...0xEC, 0xEE...0xEF => len = 3,
        0xED => {
            len = 3;
            hi2 = 0x9F;
        },
        0xF0 => {
            len = 4;
            lo2 = 0x90;
        },
        0xF1...0xF3 => len = 4,
        0xF4 => {
            len = 4;
            hi2 = 0x8F;
        },
        else => return .{ .ok = false, .len = 1 }, // invalid lead (incl. lone continuation)
    }
    if (i + 1 >= s.len) return .{ .ok = false, .len = 1 };
    if (s[i + 1] < lo2 or s[i + 1] > hi2) return .{ .ok = false, .len = 1 };
    var j: usize = 2;
    while (j < len) : (j += 1) {
        if (i + j >= s.len) return .{ .ok = false, .len = j };
        if (s[i + j] < 0x80 or s[i + j] > 0xBF) return .{ .ok = false, .len = j };
    }
    return .{ .ok = true, .len = len };
}

/// Escape `s` into `w` WITHOUT surrounding quotes, sanitizing invalid UTF-8 to U+FFFD. If
/// `upcase_first`, the first byte is ASCII-uppercased (the TitleCase name rule; level names
/// are ASCII).
fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8, upcase_first: bool) !void {
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            var c = b;
            if (first and upcase_first and c >= 'a' and c <= 'z') c -= 32;
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
            }
            i += 1;
        } else {
            const step = decodeStep(s, i);
            if (step.ok) {
                try w.writeAll(s[i .. i + step.len]);
            } else {
                try w.writeAll(replacement);
            }
            i += step.len;
        }
        first = false;
    }
}

/// Base64-encode already-`deflateZlib`'d CollMap bytes (the level holds only these), appending
/// the quoted string to `w`. When the level has NO collision (`deflated` empty), synthesize the
/// shim's `#actCollisionZlib` fallback: deflate a fw*fh 0xFFFF OOB-fill grid, then base64 it.
fn writeCollisionB64(
    w: *std.Io.Writer,
    scratch: std.mem.Allocator,
    deflated: []const u8,
    fw: i32,
    fh: i32,
    deflate_fn: ?lib.DeflateFn,
) !void {
    var bytes: []const u8 = deflated;
    if (bytes.len == 0) {
        const n: usize = @intCast(@max(fw, 0) * @max(fh, 0));
        const src = try scratch.alloc(u8, n * 2);
        @memset(src, 0xff); // 0xFFFF LE per cell — the shim's OOB-fill fallback
        bytes = if (deflate_fn) |df| try df(scratch, src) else try lib.deflateZlib(scratch, src);
    }
    const enc = std.base64.standard.Encoder;
    const b64 = try scratch.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(b64, bytes);
    try writeJsonString(w, b64);
}

/// Serialize a whole act to the DeadlyBossMods map JSON. Generates ONCE (`generateActFull`)
/// and emits every level's metadata / rooms / presets / adjacents / collision from that one
/// handle — the native equal of the shim's `render()`. `act_no` is 0-based (Act I = 0);
/// `diff` is normal/nightmare/hell. Returns the JSON bytes (owned by `alloc`).
/// `include_walk` gates the ADDITIVE pather fields (`walkDeflateB64`/`walkWidth`/`walkHeight`
/// per level + the `exits` array): false ⇒ output is byte-identical to the DBM-matched shim.
pub fn renderJson(ctx: *lib.Ctx, alloc: std.mem.Allocator, seed: u32, act_no: i32, diff: lib.Difficulty, deflate_fn: ?lib.DeflateFn, include_walk: bool) ![]u8 {
    // Per-render arena: the whole-act result + all transient serialize scratch. Freed here.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try lib.generateActFull(ctx, a, act_no, seed, diff, deflate_fn);

    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 1 << 16);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("{{\"seed\":{d},\"levels\":[", .{seed});
    for (result.levels, 0..) |lf, li| {
        if (li != 0) try w.writeByte(',');
        try writeLevel(w, a, ctx, act_no, lf, deflate_fn, include_walk);
    }
    try w.writeAll("]}");

    return out.toOwnedSlice();
}

/// Serialize a whole act to the DeadlyBossMods map JSON for a SINGLE level (one-element
/// `levels` array — same per-level shape as `renderJson`). Generates ONLY the target level
/// (`generateLevelFull`), so its `adjacents` are WARP DOORS ONLY: the cross-level seam bridges
/// are a whole-act Pass-3 product and are absent here. `act_no` is 0-based; `level_id` is a
/// Levels.txt id. Returns the JSON bytes (owned by `alloc`).
pub fn renderLevelJson(ctx: *lib.Ctx, alloc: std.mem.Allocator, seed: u32, act_no: i32, level_id: i32, diff: lib.Difficulty, deflate_fn: ?lib.DeflateFn, include_walk: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // A level belongs to exactly one act; render it in that act (the whole-act oracle) so
    // both the geometry and the emitted "act" field match, regardless of the caller's hint.
    const eff_act = lib.levelActNo(ctx, level_id) orelse act_no;
    const lf = try lib.generateLevelFull(ctx, a, eff_act, seed, level_id, diff, deflate_fn);

    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 1 << 14);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("{{\"seed\":{d},\"levels\":[", .{seed});
    try writeLevel(w, a, ctx, eff_act, lf, deflate_fn, include_walk);
    try w.writeAll("]}");

    return out.toOwnedSlice();
}

/// Emit one level's DBM object (metadata / rooms / presets / adjacents / tells / collision).
/// Shared by `renderJson` (every level) and `renderLevelJson` (one), so a level serializes
/// identically either way — modulo the seam adjacents only a whole-act render can supply.
fn writeLevel(w: *std.Io.Writer, a: std.mem.Allocator, ctx: *lib.Ctx, act_no: i32, lf: lib.LevelFull, deflate_fn: ?lib.DeflateFn, include_walk: bool) !void {
    const m = lf.meta;
    const level_no = m.level_id;
    const display_name = dbmDisplayName(ctx, level_no);

    try w.print("{{\"levelNo\":{d},\"name\":", .{level_no});
    try writeDbmName(w, level_no, display_name);
    try w.writeAll(",\"displayName\":");
    try writeJsonString(w, display_name);
    try w.print(",\"act\":{d},\"origin\":[{d},{d}],\"size\":[{d},{d}]", .{
        act_no + 1, m.origin_x * 5, m.origin_y * 5, m.width * 5, m.height * 5,
    });

    // rooms: level-local subtile rect + DS1 pick (roomNo == subNo == pickedFile)
    try w.writeAll(",\"rooms\":[");
    for (m.rooms, 0..) |r, ri| {
        if (ri != 0) try w.writeByte(',');
        try w.print("{{\"x\":{d},\"y\":{d},\"sizeX\":{d},\"sizeY\":{d},\"roomNo\":{d},\"subNo\":{d}}}", .{
            (r.x - m.origin_x) * 5, (r.y - m.origin_y) * 5, r.w * 5, r.h * 5, r.picked_file, r.picked_file,
        });
    }
    try w.writeAll("]");

    // presets: etype 2 => obj (with name/description), else => npc
    try w.writeAll(",\"presets\":[");
    for (lf.presets, 0..) |p, pi| {
        if (pi != 0) try w.writeByte(',');
        if (p.etype == 2) {
            try w.print("{{\"type\":\"obj\",\"txtFileNo\":{d},\"x\":{d},\"y\":{d},\"name\":", .{ p.txt_file_no, p.x, p.y });
            try writeJsonString(w, lib.objectName(p.txt_file_no));
            try w.writeAll(",\"description\":");
            try writeJsonString(w, lib.objectDescription(p.txt_file_no));
            try w.writeByte('}');
        } else {
            try w.print("{{\"type\":\"npc\",\"txtFileNo\":{d},\"x\":{d},\"y\":{d}}}", .{ p.txt_file_no, p.x, p.y });
        }
    }
    try w.writeAll("]");

    // adjacents: destination level bridge tiles (name/displayName resolved as render() does)
    try w.writeAll(",\"adjacents\":[");
    for (lf.adjacents, 0..) |adj, ai| {
        if (ai != 0) try w.writeByte(',');
        const dest = adj.dest_level_id;
        const dn = dbmDisplayName(ctx, dest);
        try w.print("{{\"levelNo\":{d},\"name\":", .{dest});
        try writeDbmName(w, dest, dn);
        try w.writeAll(",\"displayName\":");
        try writeJsonString(w, dn);
        try w.print(",\"bridgeX\":{d},\"bridgeY\":{d}}}", .{ adj.x, adj.y });
    }
    try w.writeAll("]");

    // tells: filled by a later phase (always empty, matches the shim)
    try w.writeAll(",\"tells\":[]");

    // collision: dims + base64(zlib-deflated LE u16 grid). Fallback fw/fh = size[0]/size[1].
    const cw = if (lf.coll_deflated.len != 0) lf.coll_w else m.width * 5;
    const ch = if (lf.coll_deflated.len != 0) lf.coll_h else m.height * 5;
    try w.print(",\"collisionWidth\":{d},\"collisionHeight\":{d},\"collisionDeflateB64\":", .{ cw, ch });
    try writeCollisionB64(w, a, lf.coll_deflated, m.width * 5, m.height * 5, deflate_fn);

    // ADDITIVE pather fields, gated so the default output stays DBM-byte-identical.
    if (include_walk) {
        // walk grid: same dims as the raw CollMap; 1 byte/cell (0=blocked, 1=walkable),
        // already zlib-deflated in the level handle. Omit when the level has no collision.
        if (lf.walk_deflated.len != 0) {
            try w.print(",\"walkWidth\":{d},\"walkHeight\":{d},\"walkDeflateB64\":", .{ lf.coll_w, lf.coll_h });
            const enc = std.base64.standard.Encoder;
            const b64 = try a.alloc(u8, enc.calcSize(lf.walk_deflated.len));
            _ = enc.encode(b64, lf.walk_deflated);
            try writeJsonString(w, b64);
        }
        // exits: pather-friendly view of `adjacents`, tagged warp vs seam with the dest name.
        try w.writeAll(",\"exits\":[");
        for (lf.adjacents, 0..) |adj, ai| {
            if (ai != 0) try w.writeByte(',');
            const dest = adj.dest_level_id;
            const dn = dbmDisplayName(ctx, dest);
            try w.print("{{\"targetLevelNo\":{d},\"targetName\":", .{dest});
            try writeJsonString(w, dn);
            try w.print(",\"x\":{d},\"y\":{d},\"type\":\"{s}\"}}", .{ adj.x, adj.y, @tagName(adj.kind) });
        }
        try w.writeAll("]");
    }

    try w.writeByte('}');
}
