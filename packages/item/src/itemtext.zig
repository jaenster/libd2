//! Item text — turns a decoded save/stash item record into what the game's tooltip shows: the display
//! name, the grid cell and size, the inventory graphic, sockets with their contents, and the full list of
//! property lines, formatted the way the engine formats ItemStatCost rows.
//!
//! Where the rules come from (1.14d Game.exe):
//!   * Affix ids. The magic table the engine indexes is the concatenation of the txt loaders' rows with the
//!     `Expansion` separator row dropped. A prefix/suffix id `n` on disk is row `n - 1` of the compacted
//!     MagicPrefix/MagicSuffix. Unique and set ids index the compacted UniqueItems/SetItems from zero. The
//!     rare name words index one combined table, suffix rows first (TXT_RareAffixes_GetLine 0x00634260).
//!     A runeword's 16 bits are the string id of its name (Items.cpp, GetItemName 0x0048c060).
//!   * Name composition (GetItemName 0x0048c060): magic `%0 %1 %2` = prefix, base, suffix (string 0x6b2); rare
//!     `%0 %1` (0x6b6); low quality 0x6b0; superior 0x6af; gemmed 0x6b3.
//!   * Property lines (SKILLDESC_BuildStatBuffDesc 0x004e60a0, ItemStatCost_DescFunc_DGrpFunc 0x004e4d80,
//!     SKILLDESC_BuildStatDescription 0x004e5a20): stats are listed in descending `descpriority`; a stat whose
//!     `dgrp` group is complete and equal prints once through the group columns (all resistances, all
//!     attributes); the damage min/max pairs print as one `Adds x-y` line.
//!
//! Not covered: the live-character terms of a tooltip (red requirements, the set-bonus lines that depend
//! on what else is worn), cube/charm-specific footers, and the by-class description of the Archon-style
//! unidentified items. A per-level stat is evaluated at `Options.char_level`.

const std = @import("std");
const wire = @import("d2-core").wire;
const tables = @import("tables.zig");
const txt = @import("txt.zig");
const strings = @import("strings.zig");
const properties = @import("properties.zig");
const rng = @import("rng.zig");
const itemtype = @import("itemtype.zig");
const d2data = @import("d2-data");

/// The record quality (normal, magic, set, rare, unique ...).
pub const Quality = wire.Quality;

pub const Color = enum { white, blue, gold, green, yellow, orange, grey, red };

pub const Line = struct { text: []const u8, color: Color = .blue };

pub const Options = struct {
    /// The level per-level stats are evaluated at. The game uses the viewing character's level.
    char_level: u8 = 99,
};

pub const Place = enum { grid, equipped, belt, cursor, ground, socketed, other };

/// Where the item is, and how much room it takes there.
pub const Location = struct {
    place: Place,
    /// The item page of a grid item: 0 inventory, 3 cube, 4 stash. Null outside a grid.
    page: ?u8 = null,
    /// Top left cell (grid, belt column) .
    x: u16 = 0,
    y: u16 = 0,
    /// Size in cells.
    w: u8 = 1,
    h: u8 = 1,
    /// The equip slot when equipped (eBodyLoc).
    body_loc: u8 = 0,
};

pub const ItemView = struct {
    location: Location,
    /// Base item code ("hax", "r31").
    code: []const u8,
    quality: wire.Quality,
    /// The title colour of the item.
    color: Color,
    /// The title line: "Gimmershred", "Beast Hold", "Sparking Large Charm of Vita", "Enigma".
    name: []const u8,
    /// The base item's name ("Flying Axe"). Equal to `name` for a normal item.
    base_name: []const u8,
    /// Inventory graphic code (an `invfile`, with the unique/set specific one when the item has it).
    invfile: []const u8,
    /// The alternate picture index when the record carries one (charms, jewels, rings, amulets).
    variant: ?u8,
    ilvl: u8,
    ethereal: bool,
    identified: bool,
    /// The personalised owner name.
    personalized: ?[]const u8,
    runeword: ?[]const u8,
    set_name: ?[]const u8,
    quantity: u16,
    /// Total sockets and the items in them.
    sockets: u8,
    socketed: []ItemView,
    /// The tooltip body below the title lines, in display order: base lines (damage, defense, durability,
    /// requirements), then the properties by descending priority, then the sockets line.
    lines: []Line,
    /// The set bonus lines the item carries (green in the game); empty for non-set items.
    set_bonus: []Line,
};

const Arg = union(enum) { i: i64, s: []const u8 };

pub const Describer = struct {
    gpa: std.mem.Allocator,
    t: tables.Tables,
    s: strings.Strings,
    unique_rows: []usize,
    set_rows: []usize,
    prefix_rows: []usize,
    suffix_rows: []usize,
    rare_prefix_rows: []usize,
    rare_suffix_rows: []usize,
    isc_row: []i32,
    char_stats: txt.Table,
    skill_desc: txt.Table,
    mon_stats: txt.Table,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) !Describer {
        var d: Describer = undefined;
        d.gpa = gpa;
        d.t = try tables.Tables.load(gpa);
        errdefer d.t.deinit();
        d.s = try strings.Strings.load(gpa);
        errdefer d.s.deinit();
        d.char_stats = try txt.Table.parse(gpa, d2data.current("CharStats"));
        errdefer d.char_stats.deinit();
        d.skill_desc = try txt.Table.parse(gpa, d2data.current("SkillDesc"));
        errdefer d.skill_desc.deinit();
        d.mon_stats = try txt.Table.parse(gpa, d2data.current("MonStats"));
        errdefer d.mon_stats.deinit();
        d.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer d.arena.deinit();
        const a = d.arena.allocator();
        d.unique_rows = try compact(a, &d.t.unique_items);
        d.set_rows = try compact(a, &d.t.set_items);
        d.prefix_rows = try compact(a, &d.t.magic_prefix);
        d.suffix_rows = try compact(a, &d.t.magic_suffix);
        d.rare_prefix_rows = try compact(a, &d.t.rare_prefix);
        d.rare_suffix_rows = try compact(a, &d.t.rare_suffix);
        d.isc_row = try a.alloc(i32, 512);
        @memset(d.isc_row, -1);
        for (0..d.t.item_stat_cost.rowCount()) |r| {
            const id = d.t.item_stat_cost.int(r, "ID");
            if (id >= 0 and id < 512 and d.t.item_stat_cost.str(r, "Stat").len != 0 and d.isc_row[@intCast(id)] < 0)
                d.isc_row[@intCast(id)] = @intCast(r);
        }
        return d;
    }

    pub fn deinit(self: *Describer) void {
        self.arena.deinit();
        self.char_stats.deinit();
        self.skill_desc.deinit();
        self.mon_stats.deinit();
        self.s.deinit();
        self.t.deinit();
    }

    // ---------------------------------------------------------------------------------------------
    // public entry points

    /// Describe a flat item list in record order (a save's player list, or a stash entry's records): every
    /// record that is not socketed into another becomes a view, followed by the `socketed_count` records it
    /// owns. Views and their strings live in `arena`.
    pub fn describeList(self: *const Describer, arena: std.mem.Allocator, items: []const wire.Item, opts: Options) ![]ItemView {
        var out: std.ArrayListUnmanaged(ItemView) = .empty;
        var i: usize = 0;
        while (i < items.len) {
            const host = &items[i];
            i += 1;
            const n: usize = @min(host.socketed_count, items.len - i);
            const kids = items[i .. i + n];
            i += n;
            if (host.dest == wire.Mode.socketed) continue; // an orphaned filler
            try out.append(arena, try self.describe(arena, host, kids, opts));
        }
        return out.toOwnedSlice(arena);
    }

    /// Describe one item and the records socketed into it.
    pub fn describe(self: *const Describer, arena: std.mem.Allocator, it: *const wire.Item, kids: []const wire.Item, opts: Options) anyerror!ItemView {
        const code = it.codeSlice();
        const ref = self.t.itemRef(code);
        const base_tbl: ?*const txt.Table = if (ref) |r| self.t.itemTable(r.table) else null;
        const row: usize = if (ref) |r| r.row else 0;

        var base_name: []const u8 = code;
        var inv_w: u8 = 1;
        var inv_h: u8 = 1;
        var invfile: []const u8 = "";
        if (base_tbl) |bt| {
            base_name = trimLine(self.s.get(bt.str(row, "namestr")));
            inv_w = clampDim(bt.int(row, "invwidth"));
            inv_h = clampDim(bt.int(row, "invheight"));
            invfile = bt.str(row, "invfile");
        }

        const quality = it.quality;
        var color: Color = .white;
        var name: []const u8 = base_name;
        var set_name: ?[]const u8 = null;
        var runeword: ?[]const u8 = null;
        var unique_row: ?usize = null;
        var set_row: ?usize = null;
        const is_rw = it.flags & wire.flag.RUNEWORD != 0;

        if (it.compact) {
            // gems, runes, potions, keys: the base name is the whole title
        } else if (is_rw) {
            if (strings.byId(it.runeword_id)) |n| {
                name = trimLine(n);
                runeword = name;
            }
            color = .gold;
        } else if (!it.identified() and quality != .normal and quality != .low and quality != .superior) {
            // unidentified: the base name only
            color = .white;
        } else switch (@intFromEnum(quality)) {
            1 => {
                const lq = self.t.low_quality_items.str(@min(it.file_index, 3), "Name");
                name = try self.format(arena, 0x6b0, &.{ .{ .s = self.s.get(lq) }, .{ .s = base_name } });
                color = .grey;
            },
            3 => {
                name = try self.format(arena, 0x6af, &.{ .{ .s = self.s.get("Hiquality") }, .{ .s = base_name } });
            },
            4 => {
                const pre = if (it.prefix != 0 and it.prefix - 1 < self.prefix_rows.len) self.s.get(self.t.magic_prefix.str(self.prefix_rows[it.prefix - 1], "Name")) else "";
                const suf = if (it.suffix != 0 and it.suffix - 1 < self.suffix_rows.len) self.s.get(self.t.magic_suffix.str(self.suffix_rows[it.suffix - 1], "Name")) else "";
                name = try self.format(arena, 0x6b2, &.{ .{ .s = pre }, .{ .s = base_name }, .{ .s = suf } });
                color = .blue;
            },
            5 => {
                if (it.set_id < self.set_rows.len) {
                    set_row = self.set_rows[it.set_id];
                    name = self.s.get(self.t.set_items.str(set_row.?, "index"));
                    const set_key = self.t.set_items.str(set_row.?, "set");
                    if (self.t.sets.findByStr("index", set_key)) |sr| set_name = self.s.get(self.t.sets.str(sr, "name"));
                }
                color = .green;
            },
            6, 8, 9 => {
                const s_n = self.rare_suffix_rows.len;
                const w1 = self.rareWord(it.rare_name1, s_n);
                const w2 = self.rareWord(it.rare_name2, s_n);
                name = try self.format(arena, 0x6b6, &.{ .{ .s = w1 }, .{ .s = w2 } });
                color = if (quality == .rare) .yellow else .orange;
            },
            7 => {
                if (it.unique_id < self.unique_rows.len) {
                    unique_row = self.unique_rows[it.unique_id];
                    name = self.s.get(self.t.unique_items.str(unique_row.?, "index"));
                }
                color = .gold;
            },
            else => {
                if (it.sockets > 0 or it.ethereal()) color = .grey;
                if (it.socketed_count > 0 and !it.compact) name = try self.format(arena, 0x6b3, &.{ .{ .s = strings.byId(0x6c0) orelse "Gemmed" }, .{ .s = base_name } });
            },
        }

        // graphic: unique / set specific files override the base one
        if (base_tbl) |bt| {
            if (unique_row) |ur| {
                const own = self.t.unique_items.str(ur, "invfile");
                if (own.len != 0) invfile = own else if (bt.str(row, "uniqueinvfile").len != 0) invfile = bt.str(row, "uniqueinvfile");
            } else if (set_row) |sr| {
                const own = self.t.set_items.str(sr, "invfile");
                if (own.len != 0) invfile = own else if (bt.str(row, "setinvfile").len != 0) invfile = bt.str(row, "setinvfile");
            }
        }

        var personalized: ?[]const u8 = null;
        if (it.ownerSlice().len != 0 and it.flags & wire.flag.BODYPART == 0) {
            personalized = try arena.dupe(u8, it.ownerSlice());
            name = try std.fmt.allocPrint(arena, "{s}'s {s}", .{ personalized.?, name });
        }

        // children
        var views: std.ArrayListUnmanaged(ItemView) = .empty;
        const target = self.socketTarget(code);
        for (kids) |*k| {
            var kv = try self.describe(arena, k, &.{}, opts);
            kv.location = .{ .place = .socketed, .x = k.x, .y = k.y, .w = kv.location.w, .h = kv.location.h };
            if (is_rw) kv.lines = &.{} else if (k.compact) kv.lines = try self.fillerLines(arena, k.codeSlice(), target, opts);
            try views.append(arena, kv);
        }

        // property collection
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var set_entries: [5]std.ArrayListUnmanaged(Entry) = @splat(.empty);
        var base_ac: i32 = 0;
        var cur_dur: i32 = 0;
        var max_dur: i32 = 0;
        for (it.stats[0..it.n_stats]) |st| {
            if (st.list == wire.list_base) {
                switch (st.id) {
                    31 => base_ac = st.value,
                    72 => cur_dur = st.value,
                    73 => max_dur = st.value,
                    else => {},
                }
                continue;
            }
            if (st.list >= 1 and st.list <= 5) {
                try addEntry(arena, &set_entries[st.list - 1], st.id, st.param, st.value);
            } else try addEntry(arena, &entries, st.id, st.param, st.value);
        }
        var seed = rng.Seed.init(1, 0x29a);
        for (kids) |*k| {
            if (k.compact) {
                if (is_rw) continue; // a runeword's own list replaces what the runes would add
                var rolled: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
                try properties.rollSocketFillerStats(arena, &rolled, &seed, &self.t, k.codeSlice(), target, .{ .code = code });
                for (rolled.items) |rs| try addEntry(arena, &entries, @intCast(rs.stat), @intCast(rs.layer), shiftUp(self, @intCast(rs.stat), rs.value));
            } else for (k.stats[0..k.n_stats]) |st| {
                if (st.list == wire.list_base) continue;
                try addEntry(arena, &entries, st.id, st.param, st.value);
            }
        }

        var lines: std.ArrayListUnmanaged(Line) = .empty;
        try self.baseLines(arena, &lines, it, ref, base_tbl, row, base_ac, cur_dur, max_dur, entries.items, quality, kids, unique_row, set_row);
        if (it.compact and it.dest != wire.Mode.socketed) try self.gemOverview(arena, &lines, code, opts);
        if (it.ethereal()) try lines.append(arena, .{ .text = trimLine(strings.byId(0x58d9) orelse "Ethereal (Cannot be Repaired)") });
        if (it.identified() or it.compact or quality == .normal) try self.propertyLines(arena, &lines, entries.items, opts, .blue);
        if (it.flags & wire.flag.SOCKETED != 0 and it.sockets > 0)
            try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} ({d})", .{ trimLine(self.s.get("Socketable")), it.sockets }) });

        var bonus: std.ArrayListUnmanaged(Line) = .empty;
        for (&set_entries) |*se| try self.propertyLines(arena, &bonus, se.items, opts, .green);

        const loc: Location = blk: {
            const place: Place = switch (it.dest) {
                wire.Mode.stored => if (it.gridPage() != null) .grid else .other,
                wire.Mode.equipped => .equipped,
                wire.Mode.belt => .belt,
                wire.Mode.ground, wire.Mode.dropping => .ground,
                wire.Mode.cursor => .cursor,
                wire.Mode.socketed => .socketed,
                else => .other,
            };
            break :blk .{ .place = place, .page = it.gridPage(), .x = it.x, .y = it.y, .w = inv_w, .h = inv_h, .body_loc = it.body_loc };
        };

        return .{
            .location = loc,
            .code = try arena.dupe(u8, code),
            .quality = quality,
            .color = color,
            .name = name,
            .base_name = base_name,
            .invfile = invfile,
            .variant = if (it.has_variant) it.variant else null,
            .ilvl = it.ilvl,
            .ethereal = it.ethereal(),
            .identified = it.identified() or it.compact,
            .personalized = personalized,
            .runeword = runeword,
            .set_name = set_name,
            .quantity = it.quantity,
            .sockets = if (it.flags & wire.flag.SOCKETED != 0) it.sockets else 0,
            .socketed = try views.toOwnedSlice(arena),
            .lines = try lines.toOwnedSlice(arena),
            .set_bonus = try bonus.toOwnedSlice(arena),
        };
    }

    // ---------------------------------------------------------------------------------------------
    // helpers

    fn rareWord(self: *const Describer, id: u8, suffix_count: usize) []const u8 {
        if (id == 0) return "";
        const i: usize = id - 1;
        if (i < suffix_count) return self.s.get(self.t.rare_suffix.str(self.rare_suffix_rows[i], "name"));
        const p = i - suffix_count;
        if (p < self.rare_prefix_rows.len) return self.s.get(self.t.rare_prefix.str(self.rare_prefix_rows[p], "name"));
        return "";
    }

    fn socketTarget(self: *const Describer, code: []const u8) properties.SocketTarget {
        const ref = self.t.itemRef(code) orelse return .helm;
        if (ref.table == .weapons) return .weapon;
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var types = itemtype.typesForItem(fba.allocator(), &self.t, code) catch return .helm;
        defer types.deinit(fba.allocator());
        return if (types.has("shld")) .shield else .helm;
    }

    /// Format string id `id` with `%0 %1 ...` positional arguments, collapsing the blanks an empty argument leaves.
    fn format(self: *const Describer, arena: std.mem.Allocator, id: u16, args: []const Arg) ![]const u8 {
        _ = self;
        const tmpl = strings.byId(id) orelse "%0 %1 %2";
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < tmpl.len) : (i += 1) {
            if (tmpl[i] == '%' and i + 1 < tmpl.len and tmpl[i + 1] >= '0' and tmpl[i + 1] <= '9') {
                const n = tmpl[i + 1] - '0';
                i += 1;
                if (n < args.len) switch (args[n]) {
                    .s => |s| try out.appendSlice(arena, s),
                    .i => |v| try out.print(arena, "{d}", .{v}),
                };
            } else try out.append(arena, tmpl[i]);
        }
        return collapse(arena, out.items);
    }

    /// A loose gem or rune lists what it adds to each kind of item it can be socketed into.
    fn gemOverview(self: *const Describer, arena: std.mem.Allocator, lines: *std.ArrayListUnmanaged(Line), code: []const u8, opts: Options) !void {
        if (self.t.gems.findByStr("code", code) == null) return;
        const targets = [_]struct { t: properties.SocketTarget, key: []const u8 }{
            .{ .t = .weapon, .key = "GemXp3" },
            .{ .t = .helm, .key = "GemXp4" },
            .{ .t = .shield, .key = "StrGemX2" },
        };
        for (targets) |tg| {
            const ls = try self.fillerLines(arena, code, tg.t, opts);
            if (ls.len == 0) continue;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try out.appendSlice(arena, trimLine(self.s.get(tg.key)));
            for (ls, 0..) |l, i| {
                try out.appendSlice(arena, if (i == 0) " " else ", ");
                try out.appendSlice(arena, l.text);
            }
            try lines.append(arena, .{ .text = out.items });
        }
    }

    fn fillerLines(self: *const Describer, arena: std.mem.Allocator, code: []const u8, target: properties.SocketTarget, opts: Options) ![]Line {
        var seed = rng.Seed.init(1, 0x29a);
        var rolled: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        try properties.rollSocketFillerStats(arena, &rolled, &seed, &self.t, code, target, .{});
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        for (rolled.items) |rs| try addEntry(arena, &entries, @intCast(rs.stat), @intCast(rs.layer), shiftUp(self, @intCast(rs.stat), rs.value));
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        try self.propertyLines(arena, &lines, entries.items, opts, .blue);
        return lines.toOwnedSlice(arena);
    }

    // ---------------------------------------------------------------------------------------------
    // base lines: damage, defense, durability, quantity, requirements

    fn baseLines(
        self: *const Describer,
        arena: std.mem.Allocator,
        lines: *std.ArrayListUnmanaged(Line),
        it: *const wire.Item,
        ref: ?tables.Tables.ItemRef,
        bt_opt: ?*const txt.Table,
        row: usize,
        base_ac: i32,
        cur_dur: i32,
        max_dur: i32,
        entries: []const Entry,
        quality: wire.Quality,
        kids: []const wire.Item,
        unique_row: ?usize,
        set_row: ?usize,
    ) !void {
        _ = quality;
        const bt = bt_opt orelse return;
        const r = ref.?;
        const sum = struct {
            fn of(es: []const Entry, id: u16) i32 {
                var v: i32 = 0;
                for (es) |e| if (e.id == id) {
                    v += e.value;
                };
                return v;
            }
        }.of;
        const ed_dmg = sum(entries, 17);
        const eth = it.ethereal();

        if (r.table == .weapons) {
            const two = bt.int(row, "2handed") != 0;
            const one_min: i64 = bt.int(row, "mindam");
            const one_max: i64 = bt.int(row, "maxdam");
            const two_min: i64 = bt.int(row, "2handmindam");
            const two_max: i64 = bt.int(row, "2handmaxdam");
            const mis_min: i64 = bt.int(row, "minmisdam");
            const mis_max: i64 = bt.int(row, "maxmisdam");
            const mod = ed_dmg != 0 or sum(entries, 21) != 0 or sum(entries, 22) != 0 or eth;
            if (!two and one_max > 0) try self.damageLine(arena, lines, "ItemStats1l", one_min, one_max, sum(entries, 21), sum(entries, 22), ed_dmg, eth, mod);
            if ((two or two_max > 0) and two_max > 0) try self.damageLine(arena, lines, "ItemStats1m", two_min, two_max, sum(entries, 23), sum(entries, 24), ed_dmg, eth, mod);
            if (mis_max > 0) try self.damageLine(arena, lines, "ItemStats1n", mis_min, mis_max, sum(entries, 159), sum(entries, 160), ed_dmg, eth, mod);
        }
        if (r.table == .armor and max_dur >= 0 and (base_ac != 0 or bt.int(row, "maxac") != 0)) {
            const ed = sum(entries, 16);
            const flat = sum(entries, 31);
            const total = @divTrunc(base_ac * (100 + ed), 100) + flat;
            try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d}", .{ self.s.get("ItemStats1h"), total }), .color = if (ed != 0 or flat != 0 or eth) .blue else .white });
        }
        if (max_dur > 0 and sum(entries, 152) == 0) {
            const ofs = if (self.s.find("ItemStats1j")) |_| "of" else "of";
            try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d} {s} {d}", .{ self.s.get("ItemStats1d"), cur_dur, ofs, max_dur }), .color = .white });
        }
        if (it.quantity > 0) try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d}", .{ self.s.get("ItemStats1i"), it.quantity }), .color = .white });

        // requirements
        const req_pct = sum(entries, 91);
        const rs = scaleReq(bt.int(row, "reqstr"), req_pct);
        const rd = scaleReq(bt.int(row, "reqdex"), req_pct);
        var rl: i64 = bt.int(row, "levelreq");
        if (unique_row) |u| rl = @max(rl, self.t.unique_items.int(u, "lvl req"));
        if (set_row) |s| rl = @max(rl, self.t.set_items.int(s, "lvl req"));
        if (it.quality == .magic) {
            if (it.prefix != 0 and it.prefix - 1 < self.prefix_rows.len) rl = @max(rl, self.t.magic_prefix.int(self.prefix_rows[it.prefix - 1], "levelreq"));
            if (it.suffix != 0 and it.suffix - 1 < self.suffix_rows.len) rl = @max(rl, self.t.magic_suffix.int(self.suffix_rows[it.suffix - 1], "levelreq"));
        }
        if (it.quality == .rare or it.quality == .crafted) {
            for (it.rare_prefixes) |p| if (p != 0 and p - 1 < self.prefix_rows.len) {
                rl = @max(rl, self.t.magic_prefix.int(self.prefix_rows[p - 1], "levelreq"));
            };
            for (it.rare_suffixes) |sx| if (sx != 0 and sx - 1 < self.suffix_rows.len) {
                rl = @max(rl, self.t.magic_suffix.int(self.suffix_rows[sx - 1], "levelreq"));
            };
        }
        if (it.flags & wire.flag.RUNEWORD != 0) {
            for (kids) |k| if (self.t.itemRef(k.codeSlice())) |kr| {
                rl = @max(rl, self.t.itemTable(kr.table).int(kr.row, "levelreq"));
            };
        }
        if (rd > 0) try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d}", .{ self.s.get("ItemStats1f"), rd }), .color = .white });
        if (rs > 0) try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d}", .{ self.s.get("ItemStats1e"), rs }), .color = .white });
        if (rl > 1) try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d}", .{ self.s.get("ItemStats1p"), rl }), .color = .white });
    }

    fn damageLine(self: *const Describer, arena: std.mem.Allocator, lines: *std.ArrayListUnmanaged(Line), key: []const u8, bmin: i64, bmax: i64, fmin: i32, fmax: i32, ed: i32, eth: bool, mod: bool) !void {
        var lo: i64 = bmin;
        var hi: i64 = bmax;
        if (eth) {
            lo = @divTrunc(lo * 3, 2);
            hi = @divTrunc(hi * 3, 2);
        }
        lo = @divTrunc(lo * (100 + ed), 100) + fmin;
        hi = @divTrunc(hi * (100 + ed), 100) + fmax;
        if (lo < 1) lo = 1;
        if (hi < lo) hi = lo;
        try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} {d} to {d}", .{ self.s.get(key), lo, hi }), .color = if (mod) .blue else .white });
    }

    // ---------------------------------------------------------------------------------------------
    // property lines

    const Entry = struct { id: u16, param: u32, value: i32 };

    fn addEntry(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(Entry), id: u16, param: u32, value: i32) !void {
        for (list.items) |*e| if (e.id == id and e.param == param) {
            e.value += value;
            return;
        };
        try list.append(a, .{ .id = id, .param = param, .value = value });
    }

    /// RolledStat values are plain numbers; the wire decoder keeps stats shifted up by `ValShift`.
    fn shiftUp(self: *const Describer, id: u16, v: i32) i32 {
        const r = self.iscRow(id) orelse return v;
        const sh: u5 = @intCast(@min(self.t.item_stat_cost.int(r, "ValShift"), 16));
        return v << sh;
    }

    fn iscRow(self: *const Describer, id: u16) ?usize {
        if (id >= self.isc_row.len) return null;
        const r = self.isc_row[id];
        return if (r < 0) null else @intCast(r);
    }

    const Pending = struct { prio: i64, id: u16, text: []const u8 };

    fn propertyLines(self: *const Describer, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(Line), entries: []const Entry, opts: Options, color: Color) !void {
        const isc = &self.t.item_stat_cost;
        var pend: std.ArrayListUnmanaged(Pending) = .empty;
        var consumed = try arena.alloc(bool, entries.len);
        @memset(consumed, false);

        const valueOf = struct {
            fn f(es: []const Entry, id: u16) ?i32 {
                for (es) |e| if (e.id == id) return e.value;
                return null;
            }
            fn idx(es: []const Entry, id: u16) ?usize {
                for (es, 0..) |e, i| if (e.id == id) return i;
                return null;
            }
        };

        // damage pairs and enhanced damage, which the engine writes as one line
        const pairs = [_]struct { lo: u16, hi: u16, one: u16, range: u16, len: u16 }{
            .{ .lo = 48, .hi = 49, .one = 0xe1c, .range = 0xe1d, .len = 0 },
            .{ .lo = 54, .hi = 55, .one = 0xe1e, .range = 0xe1f, .len = 56 },
            .{ .lo = 50, .hi = 51, .one = 0xe20, .range = 0xe21, .len = 0 },
            .{ .lo = 52, .hi = 53, .one = 0xe22, .range = 0xe23, .len = 0 },
            .{ .lo = 57, .hi = 58, .one = 0xe24, .range = 0xe25, .len = 59 },
        };
        for (pairs) |p| {
            const li = valueOf.idx(entries, p.lo) orelse continue;
            const hi_i = valueOf.idx(entries, p.hi) orelse continue;
            var lo = entries[li].value;
            var hi = entries[hi_i].value;
            var secs: i32 = 0;
            if (p.lo == 57) {
                const len_i = valueOf.idx(entries, 59);
                const len: i32 = if (len_i) |x| entries[x].value else 0;
                if (len_i) |x| consumed[x] = true;
                lo = (lo * len + 128) >> 8;
                hi = (hi * len + 128) >> 8;
                secs = @divTrunc(len, 25);
            }
            if (p.len == 56) if (valueOf.idx(entries, 56)) |x| {
                consumed[x] = true;
            };
            consumed[li] = true;
            consumed[hi_i] = true;
            const prio = isc.int(self.iscRow(p.hi).?, "descpriority");
            const text: []const u8 = blk: {
                if (lo < hi) {
                    const tmpl = strings.byId(p.range) orelse continue;
                    break :blk try cfmt(arena, tmpl, if (p.lo == 57) &.{ .{ .i = lo }, .{ .i = hi }, .{ .i = secs } } else &.{ .{ .i = lo }, .{ .i = hi } });
                }
                const tmpl = strings.byId(p.one) orelse continue;
                break :blk try cfmt(arena, tmpl, if (p.lo == 57) &.{ .{ .i = hi }, .{ .i = secs } } else &.{.{ .i = hi }});
            };
            try pend.append(arena, .{ .prio = prio, .id = p.lo, .text = text });
        }
        // physical min/max
        if (valueOf.idx(entries, 21)) |li| if (valueOf.idx(entries, 22)) |hi_i| if (entries[li].value < entries[hi_i].value) {
            consumed[li] = true;
            consumed[hi_i] = true;
            const tmpl = strings.byId(0xe27) orelse "Adds %d-%d damage";
            try pend.append(arena, .{ .prio = isc.int(self.iscRow(22).?, "descpriority"), .id = 21, .text = try cfmt(arena, tmpl, &.{ .{ .i = entries[li].value }, .{ .i = entries[hi_i].value } }) });
        };
        // enhanced damage
        if (valueOf.idx(entries, 17)) |hi_i| if (valueOf.idx(entries, 18)) |li| if (entries[li].value == entries[hi_i].value) {
            consumed[li] = true;
            consumed[hi_i] = true;
            const ed = std.mem.trim(u8, strings.byId(0x2727) orelse "Enhanced Damage", " \r\n");
            try pend.append(arena, .{ .prio = isc.int(self.iscRow(18).?, "descpriority"), .id = 17, .text = try std.fmt.allocPrint(arena, "{s}{d}% {s}", .{ if (entries[li].value >= 0) "+" else "", entries[li].value, ed }) });
        };

        // everything else, through the group columns when a complete equal group exists
        for (entries, 0..) |e, ei| {
            if (consumed[ei]) continue;
            const row = self.iscRow(e.id) orelse continue;
            const func = isc.int(row, "descfunc");
            if (func == 0) continue;
            var v = e.value;
            const op = isc.int(row, "op");
            const shift: u5 = @intCast(@min(isc.int(row, "ValShift"), 16));
            if (op >= 2 and op <= 5 and opts.char_level > 0) {
                v = @intCast((@as(i64, v) * opts.char_level) >> @intCast(@min(isc.int(row, "op param"), 24)));
            }
            v = v >> shift;
            if (e.id == 0x7a) {} // undead damage: the +50 on blunt weapons needs the weapon class

            const grp = isc.int(row, "dgrp");
            if (grp != 0) {
                // complete + equal group?
                var all_equal = true;
                var lowest = e.id;
                var members: usize = 0;
                for (0..isc.rowCount()) |r2| {
                    if (isc.int(r2, "dgrp") != grp) continue;
                    members += 1;
                    const mid: u16 = @intCast(isc.int(r2, "ID"));
                    const mi = valueOf.idx(entries, mid) orelse {
                        all_equal = false;
                        break;
                    };
                    const msh: u5 = @intCast(@min(isc.int(r2, "ValShift"), 16));
                    if ((entries[mi].value >> msh) != v) {
                        all_equal = false;
                        break;
                    }
                    if (mid < lowest) lowest = mid;
                }
                if (all_equal and members > 1) {
                    if (e.id != lowest) {
                        consumed[ei] = true;
                        continue;
                    }
                    // mark every member consumed
                    for (0..isc.rowCount()) |r2| {
                        if (isc.int(r2, "dgrp") != grp) continue;
                        const mid: u16 = @intCast(isc.int(r2, "ID"));
                        if (valueOf.idx(entries, mid)) |mi| consumed[mi] = true;
                    }
                    if (try self.describeStat(arena, e, v, isc.int(row, "dgrpfunc"), isc.int(row, "dgrpval"), isc.str(row, "dgrpstrpos"), isc.str(row, "dgrpstrneg"), isc.str(row, "dgrpstr2"))) |text|
                        try pend.append(arena, .{ .prio = isc.int(row, "descpriority"), .id = e.id, .text = text });
                    continue;
                }
            }
            if (try self.describeStat(arena, e, v, func, isc.int(row, "descval"), isc.str(row, "descstrpos"), isc.str(row, "descstrneg"), isc.str(row, "descstr2"))) |text|
                try pend.append(arena, .{ .prio = isc.int(row, "descpriority"), .id = e.id, .text = text });
        }

        std.mem.sort(Pending, pend.items, {}, struct {
            fn lt(_: void, a: Pending, b: Pending) bool {
                if (a.prio != b.prio) return a.prio > b.prio;
                return a.id < b.id;
            }
        }.lt);
        for (pend.items) |p| try out.append(arena, .{ .text = p.text, .color = color });
    }

    fn skillName(self: *const Describer, id: u32) ?[]const u8 {
        const sk = &self.t.skills;
        const row = sk.findByInt("Id", id) orelse return null;
        const desc = sk.str(row, "skilldesc");
        const dr = self.skill_desc.findByStr("skilldesc", desc) orelse return null;
        return self.s.get(self.skill_desc.str(dr, "str name"));
    }

    fn classOnly(self: *const Describer, cls: usize) []const u8 {
        if (cls >= 7) return "";
        return self.s.get(self.char_stats.str(cls, "StrClassOnly"));
    }

    fn classOfSkill(self: *const Describer, id: u32) ?usize {
        const row = self.t.skills.findByInt("Id", id) orelse return null;
        const cc = self.t.skills.str(row, "charclass");
        const codes = [_][]const u8{ "ama", "sor", "nec", "pal", "bar", "dru", "ass" };
        for (codes, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, cc)) return i;
        return null;
    }

    /// One stat as the game's ItemStatCost_DescFunc_DGrpFunc prints it.
    fn describeStat(self: *const Describer, arena: std.mem.Allocator, e: Entry, v: i32, func: i64, val: i64, pos_key: []const u8, neg_key: []const u8, str2_key: []const u8) !?[]const u8 {
        const key = if (v < 0 and neg_key.len != 0) neg_key else pos_key;
        const text = if (key.len == 0) "" else self.s.get(key);
        const str2 = if (str2_key.len == 0) "" else self.s.get(str2_key);

        switch (func) {
            13 => { // +N to <class> skill levels
                const cls: usize = @intCast(e.param);
                if (cls >= 7) return null;
                const t2 = self.s.get(self.char_stats.str(cls, "StrAllSkills"));
                return try std.fmt.allocPrint(arena, "+{d} {s}", .{ v, trimLine(t2) });
            },
            14 => { // +N to <tab> skills (<class> only)
                const cls: usize = e.param >> 3;
                const tab: usize = e.param & 7;
                if (cls >= 7 or tab > 2) return null;
                var col_buf: [16]u8 = undefined;
                const col = std.fmt.bufPrint(&col_buf, "StrSkillTab{d}", .{tab + 1}) catch unreachable;
                const tmpl = self.s.get(self.char_stats.str(cls, col));
                const body = try cfmt(arena, tmpl, &.{.{ .i = v }});
                return try std.fmt.allocPrint(arena, "{s} {s}", .{ trimLine(body), trimLine(self.classOnly(cls)) });
            },
            15 => { // chance to cast on event
                const lvl: i64 = e.param & 63;
                const sk = self.skillName(e.param >> 6) orelse return null;
                return try cfmt(arena, text, &.{ .{ .i = v }, .{ .i = lvl }, .{ .s = sk } });
            },
            16 => { // aura
                const sk = self.skillName(e.param) orelse return null;
                return try cfmt(arena, text, &.{ .{ .i = v }, .{ .s = sk } });
            },
            24 => { // charges
                const lvl: i64 = e.param & 63;
                const sk = self.skillName(e.param >> 6) orelse return null;
                const cur: i64 = v & 0xff;
                const max: i64 = (v >> 8) & 0xff;
                const lvl_word = trimLine(strings.byId(0x5301) orelse "Level");
                return try std.fmt.allocPrint(arena, "{s} {d} {s} {s}", .{ lvl_word, lvl, sk, trimLine(try cfmt(arena, text, &.{ .{ .i = cur }, .{ .i = max } })) });
            },
            27 => { // +N to <skill> (<class> only)
                const sk = self.skillName(e.param) orelse return null;
                const cls = self.classOfSkill(e.param);
                const only = if (cls) |c| self.classOnly(c) else "";
                return try std.fmt.allocPrint(arena, "+{d} to {s} {s}", .{ v, sk, trimLine(only) });
            },
            28 => {
                const sk = self.skillName(e.param) orelse return null;
                return try std.fmt.allocPrint(arena, "+{d} to {s}", .{ v, sk });
            },
            else => {},
        }

        if (text.len == 0 and func != 19) return null;
        var num_buf: [32]u8 = undefined;
        var num: []const u8 = "";
        var tail_str2 = false;
        switch (func) {
            1, 6 => {
                num = std.fmt.bufPrint(&num_buf, "{s}{d}", .{ if (v >= 0) "+" else "", v }) catch "";
                tail_str2 = func == 6;
            },
            12 => num = std.fmt.bufPrint(&num_buf, "{s}{d}", .{ if (v >= 0) "+" else "", v }) catch "",
            2, 7 => {
                num = std.fmt.bufPrint(&num_buf, "{d}%", .{v}) catch "";
                tail_str2 = func == 7;
            },
            3, 9 => {
                num = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch "";
                tail_str2 = func == 9;
            },
            4, 8 => {
                num = std.fmt.bufPrint(&num_buf, "{s}{d}%", .{ if (v >= 0) "+" else "", v }) catch "";
                tail_str2 = func == 8;
            },
            5, 10 => {
                const p = @divTrunc(v * 100, 128);
                num = std.fmt.bufPrint(&num_buf, "{d}%", .{p}) catch "";
                tail_str2 = func == 10;
            },
            19 => return try cfmt(arena, text, &.{.{ .i = v }}),
            20 => num = std.fmt.bufPrint(&num_buf, "{d}%", .{-v}) catch "",
            21 => {
                num = std.fmt.bufPrint(&num_buf, "{d}", .{-v}) catch "";
                tail_str2 = true;
            },
            22 => num = std.fmt.bufPrint(&num_buf, "{d}%", .{v}) catch "",
            23 => num = std.fmt.bufPrint(&num_buf, "{d}%", .{v}) catch "",
            11 => {
                const secs: i32 = if (v != 0) @divTrunc(2500, v) else 0;
                return try std.fmt.allocPrint(arena, "Repairs 1 Durability In {d} Seconds", .{@divTrunc(secs, 25)});
            },
            else => return null,
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const t_text = trimLine(text);
        const flat1 = func == 12 and v == 1;
        switch (val) {
            1 => {
                if (!flat1) {
                    try out.appendSlice(arena, num);
                    try out.append(arena, ' ');
                }
                try out.appendSlice(arena, t_text);
            },
            2 => {
                try out.appendSlice(arena, t_text);
                if (!flat1) {
                    try out.append(arena, ' ');
                    try out.appendSlice(arena, num);
                }
            },
            else => try out.appendSlice(arena, t_text),
        }
        if (func == 23) {
            const mrow = self.mon_stats.findByInt("Id", e.param);
            if (mrow) |m| {
                try out.append(arena, ' ');
                try out.appendSlice(arena, self.s.get(self.mon_stats.str(m, "NameStr")));
            }
        }
        if (tail_str2 and str2.len != 0) {
            try out.append(arena, ' ');
            try out.appendSlice(arena, trimLine(str2));
        }
        return out.items;
    }
};

// -------------------------------------------------------------------------------------------------
// small utilities

fn clampDim(v: i64) u8 {
    return @intCast(std.math.clamp(v, 1, 6));
}

fn scaleReq(base: i64, pct: i32) i64 {
    if (base <= 0) return 0;
    return @divTrunc(base * (100 + pct), 100);
}

/// The indices of a table's rows once the loader's `Expansion` separator rows are dropped.
fn compact(a: std.mem.Allocator, t: *const txt.Table) ![]usize {
    var out: std.ArrayListUnmanaged(usize) = .empty;
    for (t.rows, 0..) |r, i| {
        if (r.len != 0 and std.mem.eql(u8, r[0], "Expansion")) continue;
        try out.append(a, i);
    }
    return out.toOwnedSlice(a);
}

/// The text with line terminators and trailing blanks removed (string.tbl strings end with "\n").
fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n");
}

fn collapse(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var prev_space = true;
    for (s) |c| {
        if (c == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        try out.append(arena, c);
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

/// printf for the game's strings: %d, %s and %%.
fn cfmt(arena: std.mem.Allocator, tmpl_raw: []const u8, args: []const Arg) ![]const u8 {
    const tmpl = trimLine(tmpl_raw);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] != '%' or i + 1 >= tmpl.len) {
            try out.append(arena, tmpl[i]);
            continue;
        }
        i += 1;
        switch (tmpl[i]) {
            '%' => try out.append(arena, '%'),
            'd', 'i' => {
                if (n < args.len) switch (args[n]) {
                    .i => |v| try out.print(arena, "{d}", .{v}),
                    .s => |s| try out.appendSlice(arena, s),
                };
                n += 1;
            },
            's' => {
                if (n < args.len) switch (args[n]) {
                    .s => |s| try out.appendSlice(arena, s),
                    .i => |v| try out.print(arena, "{d}", .{v}),
                };
                n += 1;
            },
            else => {
                try out.append(arena, '%');
                try out.append(arena, tmpl[i]);
            },
        }
    }
    return out.items;
}

/// Decode consecutive save-format item records (each starts with `JM`, byte aligned) into `arena`.
/// Stops at `max` records or when the bytes run out / no longer start with `JM`. Socketed items are
/// separate records following their host, exactly as in a .d2s list or a stash entry.
pub fn parseRecords(arena: std.mem.Allocator, bytes: []const u8, max: usize) ![]wire.Item {
    var out: std.ArrayListUnmanaged(wire.Item) = .empty;
    var pos: usize = 0;
    while (out.items.len < max and pos + 2 <= bytes.len and bytes[pos] == 'J' and bytes[pos + 1] == 'M') {
        var r = @import("d2-core").bitreader.BitReader.init(bytes[pos..]);
        const it = wire.parseSave(&r);
        try out.append(arena, it);
        const len = (it.bit_len + 7) / 8;
        if (len == 0) break;
        pos += len;
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

fn identified(code: []const u8, quality: wire.Quality) wire.Item {
    var it = wire.Item{ .flags = wire.flag.IDENTIFIED, .version = 0x65, .ilvl = 80, .quality = quality };
    @memcpy(it.code[0..code.len], code);
    it.code_len = @intCast(code.len);
    return it;
}

test "a set item takes its name, set and own graphic from the compacted SetItems" {
    var d = try Describer.init(testing.allocator);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var id: u16 = 0;
    for (d.set_rows, 0..) |r, i| {
        if (std.mem.eql(u8, d.t.set_items.str(r, "index"), "Tal Rasha's Horadric Crest")) id = @intCast(i);
    }
    try testing.expect(id != 0);
    var it = identified("xsk", .set);
    it.set_id = id;
    const v = try d.describe(arena.allocator(), &it, &.{}, .{});
    try testing.expectEqualStrings("Tal Rasha's Horadric Crest", v.name);
    try testing.expectEqualStrings("Death Mask", v.base_name);
    try testing.expectEqualStrings("Tal Rasha's Wrappings", v.set_name.?);
    try testing.expectEqual(Color.green, v.color);
    try testing.expectEqualStrings("invmsk", v.invfile);
}

test "a magic item reads its affixes from the compacted tables and drops an empty slot" {
    var d = try Describer.init(testing.allocator);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var it = identified("cm1", .magic);
    it.prefix = 322;
    const v = try d.describe(arena.allocator(), &it, &.{}, .{});
    try testing.expectEqualStrings("Shimmering Small Charm", v.name);
    try testing.expectEqual(Color.blue, v.color);
}

test "personalised, low quality and superior names" {
    var d = try Describer.init(testing.allocator);
    defer d.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var it = identified("ssd", .low);
    it.file_index = 0;
    var v = try d.describe(arena.allocator(), &it, &.{}, .{});
    try testing.expectEqualStrings("Crude Short Sword", v.name);
    it.quality = .superior;
    v = try d.describe(arena.allocator(), &it, &.{}, .{});
    try testing.expectEqualStrings("Superior Short Sword", v.name);
    @memcpy(it.owner[0..3], "Joe");
    v = try d.describe(arena.allocator(), &it, &.{}, .{});
    try testing.expectEqualStrings("Joe's Superior Short Sword", v.name);
    try testing.expectEqualStrings("Joe", v.personalized.?);
}
