//! C-ABI shim for the d2-drlg package: exposes faithful D2 1.14d map generation
//! (per-act room layout + optional composited subtile collision) to C/C++/C#/Node
//! and to a wasm reactor module. NO Zig types cross the boundary — only C
//! primitives, fixed ints, pointers and `extern struct`s. Every export catches all
//! Zig errors and returns a negative status / null; nothing escapes.
//!
//! Allocator note: page_allocator for the caller-facing handles and smp_allocator
//! for the generation core's live-allocation registry (drlg/pool.zig reg_allocator).
//! Both are libc-free, so no artifact links libc and the wasm build targets
//! wasm32-freestanding (no WASI).

const std = @import("std");
const lib = @import("lib.zig");

/// One generated room's world rectangle + type. Field order/types MUST match the
/// `D2DrlgRoom` in d2drlg.h. Mirrors `lib.RoomRect`.
pub const D2DrlgRoom = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    n_type: i32,
    n_preset_type: i32,
    picked_file: i32,
};

/// Opaque context: the loaded game tables, built once. The C side only ever sees
/// `*D2DrlgCtx` (an opaque pointer).
pub const Ctx = struct {
    inner: lib.Ctx,
};

/// Opaque generated-act handle: owns an arena holding the whole ActResult (levels
/// + their room slices). Freed wholesale by `d2drlg_act_free`.
pub const Act = struct {
    arena: std.heap.ArenaAllocator,
    result: lib.ActResult,
};

/// Loads the game tables. Returns null on any failure.
export fn d2drlg_ctx_create() ?*Ctx {
    const pa = std.heap.page_allocator;
    const ctx = pa.create(Ctx) catch return null;
    ctx.inner = lib.Ctx.init(pa) catch {
        pa.destroy(ctx);
        return null;
    };
    return ctx;
}

/// Frees a context (null-safe).
export fn d2drlg_ctx_destroy(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.inner.deinit();
    std.heap.page_allocator.destroy(c);
}

fn diffFromInt(difficulty: i32) ?lib.Difficulty {
    return switch (difficulty) {
        0 => .normal,
        1 => .nightmare,
        2 => .hell,
        else => null,
    };
}

/// Generate an entire act with faithful inter-level placement. `difficulty` is
/// 0=normal 1=nightmare 2=hell; `act_no` is 0-based (Act I = 0 … Act V = 4).
/// Returns an opaque act handle (free with `d2drlg_act_free`) or null on error.
export fn d2drlg_gen_act(ctx: ?*Ctx, seed: u32, difficulty: i32, act_no: i32) ?*Act {
    const c = ctx orelse return null;
    const diff = diffFromInt(difficulty) orelse return null;
    if (act_no < 0 or act_no > 4) return null;

    const pa = std.heap.page_allocator;
    const act = pa.create(Act) catch return null;
    act.arena = std.heap.ArenaAllocator.init(pa);
    const a = act.arena.allocator();
    act.result = lib.generateAct(&c.inner, a, act_no, seed, diff) catch {
        act.arena.deinit();
        pa.destroy(act);
        return null;
    };
    return act;
}

/// Frees a generated-act handle (null-safe).
export fn d2drlg_act_free(act: ?*Act) void {
    const a = act orelse return;
    a.arena.deinit();
    std.heap.page_allocator.destroy(a);
}

/// Number of levels in the generated act, or -1 on error.
export fn d2drlg_act_level_count(act: ?*Act) i32 {
    const a = act orelse return -1;
    return @intCast(a.result.levels.len);
}

/// The Levels.txt id of the level at `level_index`, or -1 if out of range.
export fn d2drlg_act_level_id(act: ?*Act, level_index: i32) i32 {
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -1;
    return a.result.levels[@intCast(level_index)].level_id;
}

/// The level's DrlgType (1 maze, 2 preset, 3 wilderness), or -1 if out of range.
export fn d2drlg_act_level_drlg_type(act: ?*Act, level_index: i32) i32 {
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -1;
    return a.result.levels[@intCast(level_index)].drlg_type;
}

/// 1 if the level was placed by the act placement graph (surface overworld), 0 if
/// it fell back to the Depend offset chain (interior), or -1 if out of range.
export fn d2drlg_act_level_placed(act: ?*Act, level_index: i32) i32 {
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -1;
    return if (a.result.levels[@intCast(level_index)].placed) 1 else 0;
}

/// Room count of the level at `level_index`, or -1 if out of range.
export fn d2drlg_act_level_room_count(act: ?*Act, level_index: i32) i32 {
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -1;
    return @intCast(a.result.levels[@intCast(level_index)].rooms.len);
}

/// Writes up to `cap` rooms of the level at `level_index` into `out`; returns the
/// FULL room count (>=0, may exceed `cap` => truncated) or a negative error code.
export fn d2drlg_act_rooms(act: ?*Act, level_index: i32, out: [*]D2DrlgRoom, cap: i32) i32 {
    const a = act orelse return -1;
    if (cap < 0) return -2;
    if (level_index < 0 or level_index >= a.result.levels.len) return -3;
    const rooms = a.result.levels[@intCast(level_index)].rooms;
    const cap_us: usize = @intCast(cap);
    const n = @min(rooms.len, cap_us);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = rooms[i];
        out[i] = .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
            .n_type = r.n_type,
            .n_preset_type = r.n_preset_type,
            .picked_file = r.picked_file,
        };
    }
    return @intCast(rooms.len);
}

/// The level's generated world ORIGIN in TILES (WorldPosition). Writes *ox/*oy and
/// returns 0, or a negative error code (leaving *ox/*oy at 0). Multiply by 5 for the
/// subtile frame DBM reports.
export fn d2drlg_act_level_origin(act: ?*Act, level_index: i32, ox: *i32, oy: *i32) i32 {
    ox.* = 0;
    oy.* = 0;
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -2;
    const lr = a.result.levels[@intCast(level_index)];
    ox.* = lr.origin_x;
    oy.* = lr.origin_y;
    return 0;
}

/// The level's generated world SIZE in TILES (WorldSize). Writes *w/*h and returns 0,
/// or a negative error code (leaving *w/*h at 0). Multiply by 5 for subtiles.
export fn d2drlg_act_level_size(act: ?*Act, level_index: i32, w: *i32, h: *i32) i32 {
    w.* = 0;
    h.* = 0;
    const a = act orelse return -1;
    if (level_index < 0 or level_index >= a.result.levels.len) return -2;
    const lr = a.result.levels[@intCast(level_index)];
    w.* = lr.width;
    h.* = lr.height;
    return 0;
}

/// Write a level's Levels.txt LevelName (in-game display name) into `buf` (NUL-terminated
/// if it fits) and return its byte length (>=0), or a negative error. Length 0 if the id
/// is unknown.
export fn d2drlg_level_name(ctx: ?*Ctx, level_id: i32, buf: [*]u8, cap: i32) i32 {
    const c = ctx orelse return -1;
    if (cap < 0) return -2;
    return writeCStr(lib.levelDisplayName(&c.inner, level_id), buf, cap);
}

/// Generate a level's composited subtile-collision grid (one byte per subtile,
/// CompState: 0x00 open, 0x02 los-block, 0x01 blocked-terrain, 0x80 void). Writes
/// up to `cap` bytes into `out` and always sets *out_w / *out_h to the full grid
/// dims (so truncation is detectable). Returns the FULL cell count (w*h, >=0, may
/// exceed `cap`), 0 if the level has no collision grid, or a negative error code.
/// NOTE: this regenerates the level's whole act internally, so it is not cheap —
/// prefer caching the act if you need many levels.
export fn d2drlg_level_collision(
    ctx: ?*Ctx,
    seed: u32,
    difficulty: i32,
    level_id: i32,
    out: [*]u8,
    cap: i32,
    out_w: *i32,
    out_h: *i32,
) i32 {
    out_w.* = 0;
    out_h.* = 0;
    const c = ctx orelse return -1;
    const diff = diffFromInt(difficulty) orelse return -2;
    if (cap < 0) return -3;

    // Which act owns this level (Levels.txt Act column).
    const tlv = c.inner.act.level(level_id) orelse return -4;
    const act_no: i32 = @intCast(tlv.act);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var comp = lib.generateActComposite(&c.inner, a, act_no, seed, diff) catch return -5;
    defer comp.deinit(a);

    for (comp.levels) |lc| {
        if (lc.level_id != level_id) continue;
        out_w.* = @intCast(lc.w);
        out_h.* = @intCast(lc.h);
        const total = lc.w * lc.h;
        const cap_us: usize = @intCast(cap);
        const n = @min(total, cap_us);
        @memcpy(out[0..n], lc.cells[0..n]);
        return @intCast(total);
    }
    return 0; // no collision grid for this level
}

/// One outdoor shrine/well: resolved objects.txt class id + world SUBTILE position.
/// Field order/types MUST match `D2DrlgShrine` in d2drlg.h. Mirrors `lib.OutdoorShrine`.
/// x/y are subtile coords (÷5 for tile coords).
pub const D2DrlgShrine = extern struct {
    class_id: i32,
    x: i32,
    y: i32,
};

/// Generate an act and write up to `cap` of a level's seeded OUTDOOR SHRINES/WELLS
/// (SpawnAct12Shrines → LvlSub Type-5) into `out`. `difficulty` is 0=normal
/// 1=nightmare 2=hell. Returns the FULL shrine count (>=0, may exceed `cap` =>
/// truncated), 0 if the level has none, or a negative error code. x/y are world
/// SUBTILE coords (÷5 for tiles); class_id 130=Well, 84/2/81/83=Shrine variants.
/// NOTE: regenerates the level's whole act internally, so it is not cheap.
export fn d2drlg_level_shrines(
    ctx: ?*Ctx,
    seed: u32,
    difficulty: i32,
    level_id: i32,
    out: [*]D2DrlgShrine,
    cap: i32,
) i32 {
    const c = ctx orelse return -1;
    const diff = diffFromInt(difficulty) orelse return -2;
    if (cap < 0) return -3;

    // Which act owns this level (Levels.txt Act column).
    const tlv = c.inner.act.level(level_id) orelse return -4;
    const act_no: i32 = @intCast(tlv.act);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shrines = lib.generateLevelShrines(&c.inner, a, act_no, seed, diff, level_id) catch return -5;
    const cap_us: usize = @intCast(cap);
    const n = @min(shrines.len, cap_us);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = .{ .class_id = shrines[i].class_id, .x = shrines[i].x, .y = shrines[i].y };
    }
    return @intCast(shrines.len);
}

/// One preset unit for the DBM-shaped shim. Field order/types MUST match
/// `D2DrlgPreset` in d2drlg.h. Mirrors `lib.PresetUnit`. etype: 1 npc, 2 obj, 5 exit.
/// x/y are level-LOCAL subtile coords (DBM frame). txt_file_no: MonStats id (npc),
/// Objects.txt row (obj), or warp id (exit).
pub const D2DrlgPreset = extern struct {
    etype: i32,
    txt_file_no: i32,
    x: i32,
    y: i32,
};

/// Generate an act and write up to `cap` of a level's PRESET UNITS (npc/obj/exit,
/// deduped, level-local subtile coords) into `out`. Returns the FULL count (>=0, may
/// exceed `cap` => truncated), or a negative error code. `difficulty` 0/1/2.
/// NOTE: regenerates the level's whole act internally, so it is not cheap.
export fn d2drlg_level_presets(
    ctx: ?*Ctx,
    seed: u32,
    difficulty: i32,
    level_id: i32,
    out: [*]D2DrlgPreset,
    cap: i32,
) i32 {
    const c = ctx orelse return -1;
    const diff = diffFromInt(difficulty) orelse return -2;
    if (cap < 0) return -3;

    const tlv = c.inner.act.level(level_id) orelse return -4;
    const act_no: i32 = @intCast(tlv.act);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const presets = lib.generateLevelPresets(&c.inner, a, act_no, seed, diff, level_id) catch return -5;
    const cap_us: usize = @intCast(cap);
    const n = @min(presets.len, cap_us);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = .{ .etype = presets[i].etype, .txt_file_no = presets[i].txt_file_no, .x = presets[i].x, .y = presets[i].y };
    }
    return @intCast(presets.len);
}

/// Write an object row's Objects.txt "Name" into `buf` (NUL-terminated if it fits) and
/// return its byte length (>=0), or a negative error. `txt_file_no` is a preset obj's
/// txtFileNo (0-based Objects.txt row). Empty (length 0) if the row is out of range.
export fn d2drlg_object_name(txt_file_no: i32, buf: [*]u8, cap: i32) i32 {
    if (cap < 0) return -1;
    return writeCStr(lib.objectName(txt_file_no), buf, cap);
}

/// Write an object row's Objects.txt description (col "description - not loaded") into
/// `buf`. Same contract as d2drlg_object_name.
export fn d2drlg_object_desc(txt_file_no: i32, buf: [*]u8, cap: i32) i32 {
    if (cap < 0) return -1;
    return writeCStr(lib.objectDescription(txt_file_no), buf, cap);
}

fn writeCStr(s: []const u8, buf: [*]u8, cap: i32) i32 {
    const cap_us: usize = @intCast(cap);
    const n = @min(s.len, cap_us);
    @memcpy(buf[0..n], s[0..n]);
    if (n < cap_us) buf[n] = 0;
    return @intCast(s.len);
}

export fn d2drlg_abi_version() u32 {
    return 1;
}
