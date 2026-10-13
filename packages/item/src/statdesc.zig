//! Stat descriptions: an item's merged stat list turned into the property lines of its tooltip, the way
//! 1.14d Game.exe writes them.
//!
//! The rules, by function:
//!   * Order. ItemStatCost rows with a descfunc are sorted once at load by descpriority, ascending, with the
//!     Visual Studio 2005 CRT qsort (0x00685b50, comparator SORT_ItemDescPriority 0x006379d0). That qsort is
//!     not stable, and the order inside a tie is part of what the player sees, so `sortedStats` runs the
//!     same algorithm rather than a stable sort.
//!   * Walk (SKILLDESC_BuildStatBuffDesc 0x004e60a0, SKILLDESC_BuildStatListDesc 0x004e49c0). Stats are
//!     visited in that order; each stat's entries by param, ascending. The blunt-weapon undead line comes
//!     before the walk and the "Indestructible" fallback after it.
//!   * Damage pairs (SKILLDESC_BuildStatDescription 0x004e5a20): min/max damage, the elemental pairs and
//!     enhanced damage print as one line at the min member; the max member only reports whether the pair
//!     exists.
//!   * One stat (ItemStatCost_DescFunc_DGrpFunc 0x004e4d80): the value transform of
//!     SKILLDESC_CalcStatGroupValue 0x004e4c50 (per-level ops read the local player's level), the group
//!     rule of SKILLDESC_CalcStatGroupMinMax 0x004e4ce0, descfuncs 1..28 and the descstr2 suffix.
//!
//! Text is appended in the engine's order. The tooltip is drawn bottom-up, so the first line appended
//! is the lowest on screen: the highest priority ends up on top.

const std = @import("std");
const txt = @import("txt.zig");
const tables = @import("tables.zig");
const strings = @import("strings.zig");
const itemtype = @import("itemtype.zig");
const d2data = @import("d2-data");

/// The string id a failed key lookup resolves to (`dummy`, "an evil force").
pub const missing_string: u16 = 5382;

pub const id = struct {
    pub const comma: u16 = 3852;
    pub const colorcode: u16 = 3994;
    pub const space: u16 = 3995;
    pub const colon: u16 = 3997;
    pub const newline: u16 = 3998;
    pub const percent: u16 = 4001;
    pub const plus: u16 = 4002;
    pub const to: u16 = 4003;
    pub const enhanced_damage: u16 = 10023;
    pub const based_on_level: u16 = 11091;
    pub const indestructible: u16 = 21240;
    pub const repairs_per_second: u16 = 21241;
    pub const repairs_in_seconds: u16 = 21242;
    pub const level: u16 = 21249;
    pub const damage_to_undead: u16 = 3554;
    pub const fire_one: u16 = 3612;
    pub const fire_range: u16 = 3613;
    pub const cold_one: u16 = 3614;
    pub const cold_range: u16 = 3615;
    pub const light_one: u16 = 3616;
    pub const light_range: u16 = 3617;
    pub const magic_one: u16 = 3618;
    pub const magic_range: u16 = 3619;
    pub const poison_one: u16 = 3620;
    pub const poison_range: u16 = 3621;
    pub const damage_range: u16 = 3623;
};

/// The time-of-day line of a by-time stat, by its peak (0x006dbd88).
const by_time_strings = [4]u16{ 21235, 21237, 21234, 21236 };

/// One (stat, param) entry of a stat list.
pub const Entry = struct { stat: u16, param: u16 = 0, value: i32 };

/// A stat list as STATLIST_AddStatValue keeps it: sorted by (stat << 16 | param), values summed per key,
/// a key whose sum reaches zero removed.
pub const StatList = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    fn key(e: Entry) u32 {
        return (@as(u32, e.stat) << 16) | e.param;
    }

    pub fn add(self: *StatList, gpa: std.mem.Allocator, stat: u16, param: u16, value: i32) !void {
        if (value == 0) return;
        const k = (@as(u32, stat) << 16) | param;
        var i: usize = 0;
        while (i < self.entries.items.len and key(self.entries.items[i]) < k) : (i += 1) {}
        if (i < self.entries.items.len and key(self.entries.items[i]) == k) {
            self.entries.items[i].value +%= value;
            if (self.entries.items[i].value == 0) _ = self.entries.orderedRemove(i);
            return;
        }
        try self.entries.insert(gpa, i, .{ .stat = stat, .param = param, .value = value });
    }

    /// The value at (stat, param), 0 when absent.
    pub fn get(self: *const StatList, stat: u16, param: u16) i32 {
        for (self.entries.items) |e| if (e.stat == stat and e.param == param) return e.value;
        return 0;
    }

    /// Every entry of one stat, param ascending.
    pub fn ofStat(self: *const StatList, stat: u16) []const Entry {
        var lo: usize = 0;
        while (lo < self.entries.items.len and self.entries.items[lo].stat < stat) : (lo += 1) {}
        var hi = lo;
        while (hi < self.entries.items.len and self.entries.items[hi].stat == stat) : (hi += 1) {}
        return self.entries.items[lo..hi];
    }
};

/// What the walk needs to know about the item and the viewer besides the stats.
pub const Env = struct {
    /// The local player's level, which the per-level ops read.
    player_level: i32 = 99,
    /// The viewing character's class (0..6), for the own-class oskill cap. Null: no cap.
    player_class: ?u8 = null,
    /// The item is a blunt weapon: undead damage gets +50 and a plain blunt weapon the fixed line.
    blunt: bool = false,
    /// Current poison_count of the item (it divides the poison length).
    poison_count: i32 = 0,
    /// The game's time of day for by-time stats. Null: no act loaded, the engine's own branch.
    time_of_day: ?i32 = null,
    /// The Indestructible fallback applies (txt durability without a maximum and no stat 152).
    indestructible_fallback: bool = false,
};

/// The tables the descriptions read, resolved once.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    t: *const tables.Tables,
    s: *const strings.Strings,
    char_stats: txt.Table,
    /// CharStats rows by class id (the loader drops the `Expansion` row).
    class_rows: [7]usize,
    skill_desc: txt.Table,
    mon_stats: txt.Table,
    mon_type: txt.Table,
    /// ItemStatCost row by stat id.
    isc_row: [512]i32,
    /// Stats with a descfunc, in the engine's walk order.
    order: []u16,
    /// Bits of a skill-on-event param that hold the level (ItemStatCost row 0 `stuff`).
    skill_bits: u4,

    pub fn init(gpa: std.mem.Allocator, t: *const tables.Tables, s: *const strings.Strings) !Ctx {
        var c: Ctx = undefined;
        c.gpa = gpa;
        c.t = t;
        c.s = s;
        c.char_stats = try txt.Table.parse(gpa, d2data.current("CharStats"));
        errdefer c.char_stats.deinit();
        var n: usize = 0;
        for (c.char_stats.rows, 0..) |r, i| {
            if (r.len == 0 or std.mem.eql(u8, r[0], "Expansion")) continue;
            if (n < 7) c.class_rows[n] = i;
            n += 1;
        }
        c.skill_desc = try txt.Table.parse(gpa, d2data.current("SkillDesc"));
        errdefer c.skill_desc.deinit();
        c.mon_stats = try txt.Table.parse(gpa, d2data.current("MonStats"));
        errdefer c.mon_stats.deinit();
        c.mon_type = try txt.Table.parse(gpa, d2data.current("MonType"));
        errdefer c.mon_type.deinit();
        const isc = &t.item_stat_cost;
        @memset(&c.isc_row, -1);
        for (0..isc.rowCount()) |r| {
            const sid = isc.int(r, "ID");
            if (sid >= 0 and sid < 512 and isc.str(r, "Stat").len != 0 and c.isc_row[@intCast(sid)] < 0) c.isc_row[@intCast(sid)] = @intCast(r);
        }
        c.order = try sortedStats(gpa, isc);
        const stuff = isc.int(0, "stuff");
        c.skill_bits = if (stuff >= 1 and stuff <= 8) @intCast(stuff) else 6;
        return c;
    }

    pub fn deinit(self: *Ctx) void {
        self.gpa.free(self.order);
        self.char_stats.deinit();
        self.skill_desc.deinit();
        self.mon_stats.deinit();
        self.mon_type.deinit();
    }

    pub fn row(self: *const Ctx, stat: u16) ?usize {
        if (stat >= 512) return null;
        const r = self.isc_row[stat];
        return if (r < 0) null else @intCast(r);
    }

    fn iscInt(self: *const Ctx, stat: u16, col: []const u8) i64 {
        const r = self.row(stat) orelse return 0;
        return self.t.item_stat_cost.int(r, col);
    }

    /// Text of a txt string column: the key's string, or null where the loader would have stored 5382.
    pub fn keyText(self: *const Ctx, key: []const u8) ?[]const u8 {
        if (key.len == 0) return null;
        return self.s.find(key);
    }

    /// Text of a fixed string id.
    pub fn idText(_: *const Ctx, sid: u16) []const u8 {
        return strings.byId(sid) orelse "";
    }

    /// The text a string id stored by the loader shows: a missing key shows string 5382.
    fn shown(self: *const Ctx, t: ?[]const u8) []const u8 {
        return t orelse self.idText(missing_string);
    }

    /// SKILLDESC_GetStatNameString 0x004e6ce0: SkillDesc[Skills[id].skilldesc].`str name`.
    pub fn skillName(self: *const Ctx, skill: u32) ?[]const u8 {
        const sk = &self.t.skills;
        const r = sk.findByInt("Id", skill) orelse return null;
        const desc = sk.str(r, "skilldesc");
        const dr = self.skill_desc.findByStr("skilldesc", desc) orelse return self.idText(missing_string);
        return self.shown(self.keyText(self.skill_desc.str(dr, "str name")));
    }

    fn skillClass(self: *const Ctx, skill: u32) ?u8 {
        const sk = &self.t.skills;
        const r = sk.findByInt("Id", skill) orelse return null;
        return classOfCode(sk.str(r, "charclass"));
    }

    pub fn classStr(self: *const Ctx, class: usize, col: []const u8) ?[]const u8 {
        if (class >= 7) return null;
        return self.shown(self.keyText(self.char_stats.str(self.class_rows[class], col)));
    }
};

pub fn classOfCode(code: []const u8) ?u8 {
    const codes = [_][]const u8{ "ama", "sor", "nec", "pal", "bar", "dru", "ass" };
    for (codes, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, code)) return @intCast(i);
    return null;
}

// -------------------------------------------------------------------------------------------------
// the walk order

const Prio = struct { stat: u16, prio: i16 };

fn cmpPrio(a: Prio, b: Prio) i32 {
    if (a.prio < b.prio) return -1;
    if (a.prio > b.prio) return 1;
    return 0;
}

/// Stats with a descfunc in row order, sorted by descpriority with the VS2005 CRT qsort.
pub fn sortedStats(gpa: std.mem.Allocator, isc: *const txt.Table) ![]u16 {
    var list: std.ArrayListUnmanaged(Prio) = .empty;
    defer list.deinit(gpa);
    for (0..isc.rowCount()) |r| {
        if (isc.str(r, "Stat").len == 0) continue;
        if (isc.int(r, "descfunc") == 0) continue;
        try list.append(gpa, .{ .stat = @intCast(isc.int(r, "ID")), .prio = @truncate(isc.int(r, "descpriority")) });
    }
    crtQsort(Prio, list.items, cmpPrio);
    const out = try gpa.alloc(u16, list.items.len);
    for (list.items, 0..) |p, i| out[i] = p.stat;
    return out;
}

/// The quicksort of the Visual Studio 2005 C runtime: median of three on (lo, mid, hi), partitions of
/// eight or fewer finished by a max-to-the-end selection sort, the larger half deferred on an explicit
/// stack. Elements comparing equal are not kept in their order, and which order they end up in is
/// exactly what this reproduces.
pub fn crtQsort(comptime T: type, a: []T, cmp: fn (T, T) i32) void {
    if (a.len < 2) return;
    const cutoff = 8;
    var lo_stack: [64]isize = undefined;
    var hi_stack: [64]isize = undefined;
    var sp: usize = 0;
    var lo: isize = 0;
    var hi: isize = @intCast(a.len - 1);
    const at = struct {
        fn f(xs: []T, i: isize) T {
            return xs[@intCast(i)];
        }
        fn swap(xs: []T, i: isize, j: isize) void {
            std.mem.swap(T, &xs[@intCast(i)], &xs[@intCast(j)]);
        }
    };
    while (true) {
        const size = hi - lo + 1;
        if (size <= cutoff) {
            shortSort(T, a, @intCast(lo), @intCast(hi), cmp);
        } else {
            var mid = lo + @divTrunc(size, 2);
            if (cmp(at.f(a, lo), at.f(a, mid)) > 0) at.swap(a, lo, mid);
            if (cmp(at.f(a, lo), at.f(a, hi)) > 0) at.swap(a, lo, hi);
            if (cmp(at.f(a, mid), at.f(a, hi)) > 0) at.swap(a, mid, hi);
            var loguy = lo;
            var higuy = hi;
            while (true) {
                if (mid > loguy) {
                    loguy += 1;
                    while (loguy < mid and cmp(at.f(a, loguy), at.f(a, mid)) <= 0) loguy += 1;
                }
                if (mid <= loguy) {
                    loguy += 1;
                    while (loguy <= hi and cmp(at.f(a, loguy), at.f(a, mid)) <= 0) loguy += 1;
                }
                higuy -= 1;
                while (higuy > mid and cmp(at.f(a, higuy), at.f(a, mid)) > 0) higuy -= 1;
                if (higuy < loguy) break;
                at.swap(a, loguy, higuy);
                if (mid == higuy) mid = loguy;
            }
            higuy += 1;
            if (mid < higuy) {
                higuy -= 1;
                while (higuy > mid and cmp(at.f(a, higuy), at.f(a, mid)) == 0) higuy -= 1;
            }
            if (mid >= higuy) {
                higuy -= 1;
                while (higuy > lo and cmp(at.f(a, higuy), at.f(a, mid)) == 0) higuy -= 1;
            }
            if (higuy - lo >= hi - loguy) {
                if (lo < higuy) {
                    lo_stack[sp] = lo;
                    hi_stack[sp] = higuy;
                    sp += 1;
                }
                if (loguy < hi) {
                    lo = loguy;
                    continue;
                }
            } else {
                if (loguy < hi) {
                    lo_stack[sp] = loguy;
                    hi_stack[sp] = hi;
                    sp += 1;
                }
                if (lo < higuy) {
                    hi = higuy;
                    continue;
                }
            }
        }
        if (sp == 0) return;
        sp -= 1;
        lo = lo_stack[sp];
        hi = hi_stack[sp];
    }
}

fn shortSort(comptime T: type, a: []T, lo: usize, hi_in: usize, cmp: fn (T, T) i32) void {
    var hi = hi_in;
    while (hi > lo) {
        var max = lo;
        var p = lo + 1;
        while (p <= hi) : (p += 1) {
            if (cmp(a[p], a[max]) > 0) max = p;
        }
        std.mem.swap(T, &a[max], &a[hi]);
        hi -= 1;
    }
}

// -------------------------------------------------------------------------------------------------
// text

/// A growing UTF-8 buffer in engine order.
pub const Text = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn s(self: *Text, bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }
    pub fn int(self: *Text, v: i64) !void {
        try self.buf.print(self.gpa, "{d}", .{v});
    }
    pub fn items(self: *const Text) []const u8 {
        return self.buf.items;
    }
};

pub const Arg = union(enum) { i: i64, s: []const u8 };

/// UNICODE_FormatWideString 0x005269d0: `%d`, `%u`, `%s` and `%%`, every one of them taking an argument
/// (a `%%` is fed a dummy). An empty `%s` argument ends the formatting there.
pub fn format(out: *Text, tmpl: []const u8, args: []const Arg) !void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] != '%' or i + 1 >= tmpl.len) {
            try out.buf.append(out.gpa, tmpl[i]);
            continue;
        }
        i += 1;
        const a: ?Arg = if (n < args.len) args[n] else null;
        n += 1;
        switch (tmpl[i]) {
            '%' => try out.buf.append(out.gpa, '%'),
            'd', 'i', 'u' => if (a) |v| switch (v) {
                .i => |x| try out.int(x),
                .s => |x| try out.s(x),
            },
            's' => if (a) |v| switch (v) {
                .s => |x| {
                    try out.s(x);
                    if (x.len == 0) return;
                },
                .i => |x| try out.int(x),
            } else return,
            else => {
                try out.buf.append(out.gpa, '%');
                try out.buf.append(out.gpa, tmpl[i]);
            },
        }
    }
}

// -------------------------------------------------------------------------------------------------
// one stat

/// SKILLDESC_CalcStatGroupValue 0x004e4c50: the value a stat shows.
pub fn shownValue(c: *const Ctx, stat: u16, raw_in: i32, env: Env) i32 {
    const r = c.row(stat) orelse return raw_in;
    const isc = &c.t.item_stat_cost;
    var raw = raw_in;
    const op = isc.int(r, "op");
    if (op >= 2 and op <= 5) {
        // the op base is `level` in every vanilla row; level has no value shift
        const b: i32 = env.player_level;
        const shift: u5 = @intCast(@min(isc.int(r, "op param"), 31));
        raw = (b *% raw_in) >> shift;
    }
    const vs: u5 = @intCast(@min(isc.int(r, "ValShift"), 31));
    var v = raw >> vs;
    if (stat == 122 and env.blunt) v += 50;
    return v;
}

const Strs = struct { func: i64, val: i64, pos: ?[]const u8, neg: ?[]const u8, str2: ?[]const u8 };

fn strsOf(c: *const Ctx, r: usize, group: bool) Strs {
    const isc = &c.t.item_stat_cost;
    if (group) return .{
        .func = isc.int(r, "dgrpfunc"),
        .val = isc.int(r, "dgrpval"),
        .pos = c.keyText(isc.str(r, "dgrpstrpos")),
        .neg = c.keyText(isc.str(r, "dgrpstrneg")),
        .str2 = c.keyText(isc.str(r, "dgrpstr2")),
    };
    return .{
        .func = isc.int(r, "descfunc"),
        .val = isc.int(r, "descval"),
        .pos = c.keyText(isc.str(r, "descstrpos")),
        .neg = c.keyText(isc.str(r, "descstrneg")),
        .str2 = c.keyText(isc.str(r, "descstr2")),
    };
}

/// SKILLDESC_CalcStatGroupMinMax 0x004e4ce0. Null: the stat is not grouped. Otherwise whether this stat
/// is the group's lowest id, the one that prints.
fn groupState(c: *const Ctx, list: *const StatList, stat: u16, v: i32, env: Env) ?bool {
    const isc = &c.t.item_stat_cost;
    const r = c.row(stat) orelse return null;
    const grp = isc.int(r, "dgrp");
    if (grp == 0) return null;
    var last = false;
    var rr: usize = isc.rowCount();
    while (rr > 0) {
        rr -= 1;
        if (isc.int(rr, "dgrp") != grp) continue;
        const sid: u16 = @intCast(isc.int(rr, "ID"));
        last = sid == stat;
        if (shownValue(c, sid, list.get(sid, 0), env) != v) return null;
    }
    return last;
}

/// ItemStatCost_DescFunc_DGrpFunc 0x004e4d80. Null: no line. An empty slice is an empty line.
pub fn describeStat(c: *const Ctx, a: std.mem.Allocator, list: *const StatList, e: Entry, env: Env) !?[]const u8 {
    const r = c.row(e.stat) orelse return null;
    var v = shownValue(c, e.stat, e.value, env);
    var group = false;
    if (groupState(c, list, e.stat, v, env)) |lowest| {
        if (!lowest) return null;
        group = true;
    }
    const st = strsOf(c, r, group);
    var out = Text{ .gpa = a };
    const sp = c.idText(id.space);
    const pct = c.idText(id.percent);
    const plus = c.idText(id.plus);
    var num_buf: [24]u8 = undefined;
    var S: []const u8 = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch "";
    const strP = c.shown(if (v >= 0) st.pos else (st.neg orelse st.pos));
    const func = st.func;
    switch (func) {
        1, 6, 12 => {
            var fb_buf: [32]u8 = undefined;
            const fb: []const u8 = if (v < 1) S else if (func == 12 and v == 1) "" else std.fmt.bufPrint(&fb_buf, "{s}{s}", .{ plus, S }) catch S;
            switch (st.val) {
                1 => {
                    try out.s(fb);
                    try out.s(sp);
                    try out.s(strP);
                },
                2 => {
                    try out.s(strP);
                    try out.s(sp);
                    try out.s(fb);
                },
                else => {},
            }
        },
        2, 7, 5, 10 => {
            if (func == 5 or func == 10) S = std.fmt.bufPrint(&num_buf, "{d}", .{@divTrunc(v * 100, 128)}) catch "";
            switch (st.val) {
                1 => {
                    try out.s(S);
                    try out.s(pct);
                    try out.s(sp);
                    try out.s(strP);
                },
                2 => {
                    try out.s(strP);
                    try out.s(sp);
                    try out.s(S);
                    try out.s(pct);
                },
                else => try out.s(strP),
            }
        },
        3, 9 => switch (st.val) {
            1 => {
                try out.s(S);
                try out.s(sp);
                try out.s(strP);
            },
            2 => {
                try out.s(strP);
                try out.s(sp);
                try out.s(S);
            },
            else => try out.s(strP),
        },
        4, 8, 20, 21, 22 => {
            if (func == 20 or func == 21) {
                v = -v;
                S = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch "";
            }
            const p = if (func == 22) (c.shown(if (v >= 0) st.pos else (st.neg orelse st.pos))) else c.shown(if (v >= 0) st.pos else (st.neg orelse st.pos));
            switch (st.val) {
                1 => {
                    if (v >= 0) try out.s(plus);
                    try out.s(S);
                    try out.s(pct);
                    try out.s(sp);
                    try out.s(p);
                },
                2 => {
                    try out.s(p);
                    try out.s(sp);
                    if (v >= 0) try out.s(plus);
                    try out.s(S);
                    try out.s(pct);
                },
                else => try out.s(p),
            }
            if (func == 22) {
                if (e.param < c.mon_type.rowCount()) {
                    if (c.keyText(c.mon_type.str(e.param, "strplur"))) |pl| {
                        try out.s(c.idText(id.colon));
                        try out.s(sp);
                        try out.s(pl);
                    }
                }
            }
        },
        11 => {
            if (v <= 0) {
                try format(&out, c.idText(id.repairs_per_second), &.{.{ .i = 25 }});
            } else {
                const n = @divTrunc(@as(i32, 2500), v);
                if (n <= 30) {
                    try format(&out, c.idText(id.repairs_per_second), &.{.{ .i = 1 }});
                } else try format(&out, c.idText(id.repairs_in_seconds), &.{ .{ .i = 1 }, .{ .i = @divTrunc(n + 12, 25) } });
            }
            return out.items();
        },
        13 => {
            if (v == 0) return null;
            const cls: usize = e.param;
            const all = c.classStr(cls, "StrAllSkills") orelse return null;
            var fb_buf: [32]u8 = undefined;
            const fb: []const u8 = if (v >= 1) std.fmt.bufPrint(&fb_buf, "{s}{s}", .{ plus, S }) catch S else S;
            switch (st.val) {
                1 => {
                    try out.s(fb);
                    try out.s(sp);
                    try out.s(all);
                },
                2 => {
                    try out.s(all);
                    try out.s(sp);
                    try out.s(fb);
                },
                else => {},
            }
        },
        14 => {
            const cls: usize = e.param >> 3;
            const tab: usize = e.param & 7;
            if (tab > 2 or cls >= 7) return null;
            const cols = [3][]const u8{ "StrSkillTab1", "StrSkillTab2", "StrSkillTab3" };
            const tmpl = c.classStr(cls, cols[tab]) orelse return null;
            try format(&out, tmpl, &.{.{ .i = v }});
            try out.s(sp);
            try out.s(c.classStr(cls, "StrClassOnly") orelse "");
        },
        15 => {
            const mask: u16 = (@as(u16, 1) << c.skill_bits) - 1;
            const skill: u32 = e.param >> c.skill_bits;
            const lvl: i64 = e.param & mask;
            if (skill < 1 or skill >= c.t.skills.rowCount()) return null;
            const name = c.skillName(skill) orelse return null;
            try format(&out, c.shown(st.pos), &.{ .{ .i = v }, .{ .i = 0 }, .{ .i = lvl }, .{ .s = name } });
            return out.items();
        },
        16 => {
            const name = c.skillName(e.param) orelse return null;
            try format(&out, strP, &.{ .{ .i = v }, .{ .s = name } });
            return out.items();
        },
        17, 18 => {
            const peak: i32 = v & 3;
            const mn: i32 = ((v >> 2) & 0x3ff) - 256;
            const mx: i32 = ((v >> 12) & 0x3ff) - 256;
            var R: i32 = mn;
            if (env.time_of_day) |t| {
                const d: i32 = @intCast(@abs(t - peak * 90));
                var f: i32 = @divTrunc(d + 7, 15) * 15;
                if (f < 1) f = 0;
                if (f >= 359) f = 1 else if (f >= 181) f = 360 - f;
                R = mx - @divTrunc((mx - mn) * f, 180);
            }
            try out.s(c.idText(by_time_strings[@intCast(std.math.clamp(peak, 0, 3))]));
            try out.s(c.idText(id.newline));
            var fb_buf: [32]u8 = undefined;
            var fb: []const u8 = if (R < 0) (if (v < 0) (std.fmt.bufPrint(&fb_buf, "{d}", .{R}) catch "") else "") else std.fmt.bufPrint(&fb_buf, "{s}{d}", .{ plus, R }) catch "";
            var fb2_buf: [40]u8 = undefined;
            if (func == 18) fb = std.fmt.bufPrint(&fb2_buf, "{s}{s}", .{ fb, pct }) catch fb;
            const p = c.shown(if (R >= 0) st.pos else (st.neg orelse st.pos));
            switch (st.val) {
                1 => {
                    try out.s(fb);
                    try out.s(sp);
                    try out.s(p);
                },
                2 => {
                    try out.s(p);
                    try out.s(sp);
                    try out.s(fb);
                },
                else => {},
            }
            return out.items();
        },
        19 => {
            try format(&out, strP, &.{.{ .i = v }});
            return out.items();
        },
        23 => {
            const m = c.mon_stats.findByInt("hcIdx", e.param) orelse return null;
            switch (st.val) {
                1 => {
                    try out.s(S);
                    try out.s(pct);
                    try out.s(sp);
                    try out.s(strP);
                },
                2 => {
                    try out.s(strP);
                    try out.s(sp);
                    try out.s(S);
                    try out.s(pct);
                },
                else => try out.s(strP),
            }
            try out.s(sp);
            try out.s(c.shown(c.keyText(c.mon_stats.str(m, "NameStr"))));
        },
        24 => {
            const mask: u16 = (@as(u16, 1) << c.skill_bits) - 1;
            const lvl: i64 = e.param & mask;
            const name = c.skillName(e.param >> c.skill_bits) orelse return "";
            try out.s(c.idText(id.level));
            try out.s(sp);
            try out.int(lvl);
            try out.s(sp);
            try out.s(name);
            try out.s(sp);
            try format(&out, c.shown(st.pos), &.{ .{ .i = v & 0xff }, .{ .i = v >> 8 } });
            return out.items();
        },
        25, 26 => {
            var fb_buf: [32]u8 = undefined;
            const fb: []const u8 = if (v >= 0) S else std.fmt.bufPrint(&fb_buf, "{s}{s}", .{ plus, S }) catch S;
            switch (st.val) {
                1 => {
                    try out.s(fb);
                    try out.s(sp);
                    try out.s(strP);
                },
                2 => {
                    try out.s(strP);
                    try out.s(sp);
                    try out.s(fb);
                },
                else => {},
            }
        },
        27, 28 => {
            if (v == 0) return "";
            const name = c.skillName(e.param) orelse return "";
            if (func == 28) {
                const cls = c.skillClass(e.param);
                if (cls != null and env.player_class != null and cls.? == env.player_class.? and v > 3) {
                    v = 3;
                    S = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch "";
                }
            }
            if (v >= 1) try out.s(plus);
            try out.s(S);
            try out.s(sp);
            try out.s(c.idText(id.to));
            try out.s(sp);
            try out.s(name);
            if (func == 27) {
                try out.s(sp);
                if (c.skillClass(e.param)) |cls| try out.s(c.classStr(cls, "StrClassOnly") orelse "");
            }
            return out.items();
        },
        else => return null,
    }
    if ((func >= 6 and func <= 10) or func == 21) {
        try out.s(sp);
        try out.s(st.str2 orelse c.idText(id.based_on_level));
    }
    return out.items();
}

// -------------------------------------------------------------------------------------------------
// damage pairs

const Damage = struct {
    min: i32,
    max: i32,
    min_pct: i32,
    max_pct: i32,
    fire: [2]i32,
    light: [2]i32,
    magic: [2]i32,
    cold: [2]i32,
    poison: [2]i32,
    poison_len: i32,
    printed: bool = false,
    phys_pair: bool,

    fn of(list: *const StatList) Damage {
        var d: Damage = undefined;
        d.min = list.get(21, 0);
        if (d.min == 0) d.min = list.get(23, 0);
        d.max = list.get(22, 0);
        if (d.max == 0) d.max = list.get(24, 0);
        d.min_pct = list.get(18, 0);
        d.max_pct = list.get(17, 0);
        d.fire = .{ list.get(48, 0), list.get(49, 0) };
        d.light = .{ list.get(50, 0), list.get(51, 0) };
        d.magic = .{ list.get(52, 0), list.get(53, 0) };
        d.cold = .{ list.get(54, 0), list.get(55, 0) };
        d.poison = .{ list.get(57, 0), list.get(58, 0) };
        d.poison_len = list.get(59, 0);
        d.printed = false;
        d.phys_pair = d.min > 0 and d.max > 0;
        return d;
    }
};

fn pair(p: [2]i32) bool {
    return p[0] > 0 and p[1] > 0;
}

/// SKILLDESC_BuildStatDescription 0x004e5a20. Returns true when the stat is handled here (a line may have
/// been appended, already ending in the newline its string carries).
fn damageSpecial(c: *const Ctx, out: *Text, d: *Damage, stat: u16, env: Env) !bool {
    switch (stat) {
        17 => return d.min_pct > 0 and d.max_pct > 0,
        18 => {
            if (!(d.min_pct > 0 and d.max_pct > 0)) return false;
            try out.s(c.idText(id.plus));
            try out.int(d.min_pct);
            try out.s(c.idText(id.percent));
            try out.s(c.idText(id.space));
            try out.s(c.idText(id.enhanced_damage));
            return true;
        },
        21, 22, 23 => {
            if (d.printed) return true;
            if (!d.phys_pair) return false;
            if (d.min < d.max) {
                try format(out, c.idText(id.damage_range), &.{ .{ .i = d.min }, .{ .i = d.max } });
                d.printed = true;
                return true;
            }
            d.phys_pair = false;
            return false;
        },
        24 => return d.printed or d.phys_pair,
        48, 50, 52, 54 => {
            const p = switch (stat) {
                48 => d.fire,
                50 => d.light,
                52 => d.magic,
                else => d.cold,
            };
            if (!pair(p)) return false;
            const ids: [2]u16 = switch (stat) {
                48 => .{ id.fire_one, id.fire_range },
                50 => .{ id.light_one, id.light_range },
                52 => .{ id.magic_one, id.magic_range },
                else => .{ id.cold_one, id.cold_range },
            };
            if (p[0] < p[1]) try format(out, c.idText(ids[1]), &.{ .{ .i = p[0] }, .{ .i = p[1] } }) else try format(out, c.idText(ids[0]), &.{.{ .i = p[1] }});
            return true;
        },
        49 => return pair(d.fire),
        51 => return pair(d.light),
        53 => return pair(d.magic),
        55 => return pair(d.cold),
        57 => {
            if (!pair(d.poison)) return false;
            const cnt = @max(env.poison_count, 1);
            const len = @divTrunc(d.poison_len, cnt);
            const secs = @divTrunc(len, 25);
            const mn = (d.poison[0] *% len + 128) >> 8;
            const mx = (d.poison[1] *% len + 128) >> 8;
            if (mn < mx) try format(out, c.idText(id.poison_range), &.{ .{ .i = mn }, .{ .i = mx }, .{ .i = secs } }) else try format(out, c.idText(id.poison_one), &.{ .{ .i = mx }, .{ .i = secs } });
            return true;
        },
        58, 59 => return pair(d.poison),
        else => return false,
    }
}

/// SKILLDESC_BuildStatListDesc 0x004e49c0 with the undead and Indestructible lines of
/// SKILLDESC_BuildStatBuffDesc 0x004e60a0. Appends the property lines of `list` to `out` in engine order
/// (lowest priority first). `newline` is the line mode: true ends every line with a newline, false
/// separates descfunc lines with ", ".
pub fn describeList(c: *const Ctx, out: *Text, list: *const StatList, env: Env, newline: bool, undead_line: bool) !void {
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (undead_line and env.blunt and shownValue(c, 122, list.get(122, 0), .{}) == 0) {
        try out.s(c.idText(id.plus));
        try out.s("50");
        try out.s(c.idText(id.percent));
        try out.s(c.idText(id.space));
        try out.s(c.idText(id.damage_to_undead));
        try out.s(c.idText(id.newline));
    }
    var d = Damage.of(list);
    var had_line = false;
    for (c.order) |stat| {
        for (list.ofStat(stat)) |e| {
            if (e.value == 0) continue;
            if (try damageSpecial(c, out, &d, stat, env)) continue;
            const line = (try describeStat(c, a, list, e, env)) orelse continue;
            if (stat == 23 and list.get(21, 0) != 0) continue;
            if (stat == 24 and list.get(22, 0) != 0) continue;
            if (!newline and had_line) {
                try out.s(c.idText(id.comma));
                try out.s(c.idText(id.space));
            }
            try out.s(line);
            if (newline) try out.s(c.idText(id.newline));
            had_line = true;
        }
    }
    if (env.indestructible_fallback and list.get(152, 0) < 1) {
        if (!newline and had_line) {
            try out.s(c.idText(id.comma));
            try out.s(c.idText(id.space));
        }
        try out.s(c.idText(id.indestructible));
        if (newline) try out.s(c.idText(id.newline));
    }
}

// -------------------------------------------------------------------------------------------------
// tests: the expected text is what the engine's rules give for the stock tables

const testing = std.testing;

const Fixture = struct {
    t: tables.Tables,
    s: strings.Strings,
    c: Ctx,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Fixture) !void {
        self.t = try tables.Tables.load(testing.allocator);
        self.s = try strings.Strings.load(testing.allocator);
        self.c = try Ctx.init(testing.allocator, &self.t, &self.s);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.c.deinit();
        self.s.deinit();
        self.t.deinit();
    }
    /// The block for these entries, its lines top to bottom as the screen shows them.
    fn lines(self: *Fixture, entries: []const Entry, env: Env) ![]const u8 {
        const a = self.arena.allocator();
        var list = StatList{};
        for (entries) |e| try list.add(a, e.stat, e.param, e.value);
        var out = Text{ .gpa = a };
        try describeList(&self.c, &out, &list, env, true, true);
        // reverse the line order: the engine buffer's first line is the bottom one
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.items(), "\n"), '\n');
        while (it.next()) |p| try parts.append(a, p);
        std.mem.reverse([]const u8, parts.items);
        return std.mem.join(a, "|", parts.items);
    }
};

fn expectLines(f: *Fixture, entries: []const Entry, env: Env, want: []const u8) !void {
    const got = try f.lines(entries, env);
    try testing.expectEqualStrings(want, got);
}

test "the walk order is the engine's unstable qsort over descpriority" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // the order the VS2005 qsort gives for the stock ItemStatCost
    const want = [_]u16{ 91, 252, 204, 253, 75, 254, 125, 89, 240, 87, 80, 239, 79, 114, 85, 238, 78, 128, 139, 86, 138, 155, 110, 118, 153, 35, 34, 36, 142, 144, 148, 146, 143, 235, 145, 236, 149, 234, 233, 147, 45, 231, 39, 232, 41, 230, 43, 37, 40, 42, 44, 46, 38, 241, 28, 154, 242, 11, 27, 217, 77, 9, 74, 216, 76, 7, 222, 1, 223, 3, 221, 2, 220, 0, 32, 33, 31, 214, 215, 16, 120, 81, 150, 134, 112, 113, 117, 107, 108, 97, 248, 135, 250, 141, 247, 136, 306, 305, 335, 308, 329, 330, 60, 336, 307, 331, 332, 333, 334, 62, 229, 58, 57, 226, 55, 54, 228, 51, 50, 227, 49, 48, 53, 52, 246, 124, 180, 244, 122, 179, 245, 123, 243, 121, 224, 19, 225, 119, 116, 115, 249, 137, 111, 24, 23, 218, 22, 21, 219, 17, 18, 157, 156, 158, 20, 102, 99, 105, 93, 96, 83, 188, 126, 127, 151, 195, 197, 198, 199, 201, 152, 196, 280, 281, 282, 283, 284, 285, 286, 272, 288, 289, 290, 279, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 278, 271, 277, 276, 275, 274, 292, 270, 273, 269, 268, 287 };
    try testing.expectEqualSlices(u16, &want, f.c.order);
}

test "descfuncs 1 to 5 and 11, 12" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{.{ .stat = 0, .value = 15 }}, .{}, "+15 to Strength");
    try expectLines(&f, &.{.{ .stat = 0, .value = -5 }}, .{}, "-5 to Strength");
    try expectLines(&f, &.{.{ .stat = 7, .value = 20 << 8 }}, .{}, "+20 to Life");
    try expectLines(&f, &.{.{ .stat = 80, .value = 25 }}, .{}, "25% Better Chance of Getting Magic Items");
    try expectLines(&f, &.{.{ .stat = 75, .value = 50 }}, .{}, "Increase Maximum Durability 50%");
    try expectLines(&f, &.{.{ .stat = 34, .value = 7 }}, .{}, "Damage Reduced by 7");
    try expectLines(&f, &.{.{ .stat = 152, .value = 1 }}, .{}, "Indestructible");
    try expectLines(&f, &.{.{ .stat = 39, .value = 30 }}, .{}, "Fire Resist +30%");
    try expectLines(&f, &.{.{ .stat = 93, .value = 20 }}, .{}, "+20% Increased Attack Speed");
    try expectLines(&f, &.{.{ .stat = 112, .value = 64 }}, .{}, "Hit Causes Monster to Flee 50%");
    try expectLines(&f, &.{.{ .stat = 252, .value = 1 }}, .{}, "Repairs 1 durability in 100 seconds");
    try expectLines(&f, &.{.{ .stat = 252, .value = 100 }}, .{}, "Repairs 1 durability per second");
    try expectLines(&f, &.{.{ .stat = 134, .value = 3 }}, .{}, "Freezes target +3");
    try expectLines(&f, &.{.{ .stat = 134, .value = 1 }}, .{}, "Freezes target ");
}

test "per-level descfuncs 6 to 9 read the player's level and add the str2 suffix" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{.{ .stat = 216, .value = 2048 }}, .{ .player_level = 10 }, "+10 to Life (Based on Character Level)");
    try expectLines(&f, &.{.{ .stat = 239, .value = 10 }}, .{ .player_level = 80 }, "100% Extra Gold from Monsters (Based on Character Level)");
    try expectLines(&f, &.{.{ .stat = 215, .value = 8 }}, .{ .player_level = 50 }, "+50% Enhanced Defense (Based on Character Level)");
    try expectLines(&f, &.{.{ .stat = 238, .value = 8 }}, .{ .player_level = 12 }, "Attacker Takes Damage of 12 (Based on Character Level)");
}

test "skill descfuncs 13 to 16, 24, 27, 28" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{.{ .stat = 83, .param = 3, .value = 2 }}, .{}, "+2 to Paladin Skill Levels");
    try expectLines(&f, &.{.{ .stat = 188, .param = 0, .value = 3 }}, .{}, "+3 to Bow and Crossbow Skills (Amazon Only)");
    try expectLines(&f, &.{.{ .stat = 198, .param = (44 << 6) | 5, .value = 10 }}, .{}, "10% Chance to cast level 5 Frost Nova on striking");
    try expectLines(&f, &.{.{ .stat = 151, .param = 102, .value = 8 }}, .{}, "Level 8 Holy Fire Aura When Equipped");
    try expectLines(&f, &.{.{ .stat = 204, .param = (54 << 6) | 3, .value = 20 | (20 << 8) }}, .{}, "Level 3 Teleport (20/20 Charges)");
    try expectLines(&f, &.{.{ .stat = 107, .param = 54, .value = 1 }}, .{}, "+1 to Teleport (Sorceress Only)");
    try expectLines(&f, &.{.{ .stat = 97, .param = 54, .value = 1 }}, .{ .player_class = 0 }, "+1 to Teleport");
    try expectLines(&f, &.{.{ .stat = 97, .param = 54, .value = 5 }}, .{ .player_class = 1 }, "+3 to Teleport");
}

test "by-time descfuncs 17 and 18 put the time line below the value line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{.{ .stat = 274, .value = 0 | (261 << 2) | (281 << 12) }}, .{}, "+5 to Strength|(Increases During Daytime)");
    try expectLines(&f, &.{.{ .stat = 274, .value = 0 | (261 << 2) | (281 << 12) }}, .{ .time_of_day = 90 }, "+15 to Strength|(Increases During Daytime)");
    try expectLines(&f, &.{.{ .stat = 285, .value = 2 | (266 << 2) | (276 << 12) }}, .{}, "Fire Resist +10%|(Increases During Nighttime)");
}

test "groups, negated and monster descfuncs 19 to 23" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{ .{ .stat = 39, .value = 20 }, .{ .stat = 41, .value = 20 }, .{ .stat = 43, .value = 20 }, .{ .stat = 45, .value = 20 } }, .{}, "All Resistances +20");
    try expectLines(&f, &.{ .{ .stat = 0, .value = 5 }, .{ .stat = 1, .value = 5 }, .{ .stat = 2, .value = 5 }, .{ .stat = 3, .value = 5 } }, .{}, "+5 to all Attributes");
    try expectLines(&f, &.{.{ .stat = 306, .value = 15 }}, .{}, "-15% to Enemy Fire Resistance");
    try expectLines(&f, &.{.{ .stat = 180, .param = 12, .value = 50 }}, .{}, "+50% to Damage versus: Fallen");
    try expectLines(&f, &.{.{ .stat = 155, .param = 1, .value = 10 }}, .{}, "10% Reanimate as: Returned");
}

test "damage pairs print once at the min member" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try expectLines(&f, &.{ .{ .stat = 21, .value = 5 }, .{ .stat = 22, .value = 10 } }, .{}, "Adds 5-10 damage");
    try expectLines(&f, &.{ .{ .stat = 17, .value = 150 }, .{ .stat = 18, .value = 150 } }, .{}, "+150% Enhanced Damage");
    try expectLines(&f, &.{ .{ .stat = 48, .value = 10 }, .{ .stat = 49, .value = 20 } }, .{}, "Adds 10-20 fire damage");
    try expectLines(&f, &.{ .{ .stat = 48, .value = 20 }, .{ .stat = 49, .value = 20 } }, .{}, "+20 fire damage");
    try expectLines(&f, &.{ .{ .stat = 57, .value = 512 }, .{ .stat = 58, .value = 1024 }, .{ .stat = 59, .value = 75 } }, .{}, "Adds 150-300 poison damage over 3 seconds");
    try expectLines(&f, &.{ .{ .stat = 57, .value = 512 }, .{ .stat = 58, .value = 512 }, .{ .stat = 59, .value = 75 } }, .{}, "+150 poison damage over 3 seconds");
    try expectLines(&f, &.{}, .{ .blunt = true }, "+50% Damage to Undead");
}
