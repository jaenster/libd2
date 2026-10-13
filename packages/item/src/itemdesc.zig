//! The hover description of an item, built the way 1.14d Game.exe builds it: one string, lines separated
//! by newlines, colour codes `ÿcN` in front of each block, the FIRST line the BOTTOM one on screen (the
//! draw starts at the bottom of the box and steps up on every newline), so the item name is appended
//! last. `Desc.text` is that string, ready for the tooltip draw; `Desc.lines` reads it top to bottom.
//!
//! The rules, by function:
//!   * LoadItemDesc 0x0048dd90: the dispatch (set items, tomes, transmogrify, the general card), the block
//!     order and the colour of every block, the quest item lines.
//!   * GetItemName 0x0048c060: the name lines per quality, runewords, personalised items, ears.
//!   * ITEM_BuildSetItemTooltip 0x0048d1d0: the set item card with its own block order and member list.
//!   * The line formatters: Defense 0x00485ee0, damage 0x00485410 (with INV_CalcWeaponDamageRange
//!     0x00485240), block 0x00485be0, durability 0x00484e90, attack speed 0x004861d0
//!     (ITEM_CalcWeaponAttackSpeed 0x0062a710), required level 0x00484ff0 (ITEM_CalcRequiredLevel
//!     0x0062b5b0), strength/dexterity 0x004850a0/0x00485170, quantity 0x00486100, spell description
//!     0x00486370, ethereal/socketed 0x00484b10, rune letters 0x00486670, socket fillers 0x004865d0 with
//!     SKILLDESC_BuildMagicAffixDesc 0x004e6850.
//!   * The numbers come from the item's stats as STATSEX_GetCurrentStat 0x00625480 combines them: the base
//!     stats the record and the txt give on load (ITEM_DeserializeFromBitBuffer 0x0062cbe0: weapon damage
//!     from the txt, three quarters for low quality, half again for ethereal), plus the own, runeword and
//!     socket-filler lists, plus the percent-of-base ops (op 13) and the per-level ops (4, 5).
//!
//! The viewing character. The engine always has one; a description without a `Viewer` uses a neutral
//! character instead: every requirement met, no class (no class block factor, no kick or smite line, no
//! attack-speed line), per-level stats at `Options.level`, no set piece owned or worn.

const std = @import("std");
const wire = @import("d2-core").wire;
const d2data = @import("d2-data");
const tables = @import("tables.zig");
const txt = @import("txt.zig");
const strings = @import("strings.zig");
const properties = @import("properties.zig");
const rng = @import("rng.zig");
const itemtype = @import("itemtype.zig");
const statdesc = @import("statdesc.zig");

const StatList = statdesc.StatList;
const Text = statdesc.Text;

pub const Viewer = struct {
    /// 0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin.
    class: u8,
    level: i32,
    strength: i32,
    dexterity: i32,
    /// SetItems ids (the record's set id) of the set pieces the character has, worn or carried: their
    /// member lines are green.
    set_items_owned: []const u16 = &.{},
    /// SetItems ids of the pieces the character wears: which partial set bonus lists show.
    set_items_worn: []const u16 = &.{},
};

pub const Options = struct {
    viewer: ?Viewer = null,
    /// The level per-level stats are evaluated at without a viewer.
    level: i32 = 99,
    /// `data/global/animdata.d2`, for the attack-speed line (needs a viewer).
    animdata: ?[]const u8 = null,
    /// The item is in the viewer's own inventory panel (page 0): tomes and quest items show their
    /// right-click lines.
    own_inventory: bool = true,
};

pub const Desc = struct {
    /// The engine's description string (UTF-8): first line at the bottom, `ÿcN` colour codes.
    text: []const u8,
    /// The colour the draw starts in (0, or 4 for quest items).
    base_color: u8 = 0,
    /// Each line centred (the general and set cards) or left aligned (tomes, transmogrify).
    centered: bool = true,
};

/// Where a colour code starts: `ÿ` in UTF-8, then `c`, then the digit.
pub const color_code = "\xc3\xbfc";

/// A run of text in one colour.
pub const Span = struct { color: u8, text: []const u8 };
pub const Line = struct { spans: []const Span };

/// The description read top to bottom, colours resolved the way the draw resolves them: a code sets the
/// colour until the next one, across newlines, in buffer order (bottom to top).
pub fn lines(arena: std.mem.Allocator, d: Desc) ![]Line {
    var raw: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, d.text, '\n');
    while (it.next()) |l| try raw.append(arena, l);
    var out = try arena.alloc(Line, raw.items.len);
    var color: u8 = d.base_color;
    for (raw.items, 0..) |l, i| {
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        var start: usize = 0;
        var k: usize = 0;
        while (k < l.len) {
            if (k + 3 < l.len and std.mem.startsWith(u8, l[k..], color_code)) {
                if (k > start) try spans.append(arena, .{ .color = color, .text = l[start..k] });
                const v: i32 = @as(i32, l[k + 3]) - '0';
                color = if (v > 12 or v < 0) 0 else @intCast(v);
                k += 4;
                start = k;
                continue;
            }
            k += 1;
        }
        if (l.len > start) try spans.append(arena, .{ .color = color, .text = l[start..] });
        out[raw.items.len - 1 - i] = .{ .spans = try spans.toOwnedSlice(arena) };
    }
    return out;
}

/// The description as plain text, top to bottom, one line per line, colour codes removed.
pub fn plain(arena: std.mem.Allocator, d: Desc) ![]const u8 {
    const ls = try lines(arena, d);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (ls, 0..) |l, i| {
        if (i != 0) try out.append(arena, '\n');
        for (l.spans) |s| try out.appendSlice(arena, s.text);
    }
    return out.items;
}

// -------------------------------------------------------------------------------------------------
// string ids

const sid = struct {
    const newline: u16 = 3998;
    const space: u16 = 3995;
    const dash: u16 = 3996;
    const comma: u16 = 3852;
    const to: u16 = 3464;
    const of: u16 = 3463;
    const unidentified: u16 = 3455;
    const socketable: u16 = 3453;
    const ethereal: u16 = 22745;
    const durability: u16 = 3457;
    const req_str: u16 = 3458;
    const req_dex: u16 = 3459;
    const defense: u16 = 3461;
    const quantity: u16 = 3462;
    const one_hand: u16 = 3465;
    const two_hand: u16 = 3466;
    const throw: u16 = 3467;
    const smite: u16 = 3468;
    const req_level: u16 = 3469;
    const kick: u16 = 21782;
    const block: u16 = 11018;
    const class_only: u16 = 10917;
    const keep_in_inventory: u16 = 20438;
    const can_be_inserted: u16 = 11080;
    const shields: u16 = 11074;
    const helms: u16 = 11073;
    const armor: u16 = 11076;
    const weapons: u16 = 11075;
    const rune_quote: u16 = 20506;
    const right_click_read: u16 = 2205;
    const right_click_open: u16 = 2204;
    const right_click_use: u16 = 2203;
    const insert_scrolls: u16 = 2206;
    const right_click_make: u16 = 5387;
    const name2: u16 = 1712; // "%0 %1" low quality
    const superior_fmt: u16 = 1711;
    const magic_fmt: u16 = 1714;
    const gemmed_fmt: u16 = 1715;
    const rare_fmt: u16 = 1718;
    const set_fmt: u16 = 10089;
    const superior: u16 = 1727;
    const gemmed: u16 = 1728;
    const hardcore: u16 = 5126;
    const level: u16 = 4141;
    const dummy: u16 = 5382;
};

const ear_classes = [7]u16{ 4011, 4010, 4009, 4008, 4007, 10097, 10098 };

/// The weapon class words of INV_FormatAttackSpeedText, first match wins (0x00721eb0).
const weapon_classes = [_]struct { t: []const u8, s: u16 }{
    .{ .t = "staf", .s = 4085 }, .{ .t = "axe", .s = 4078 },  .{ .t = "swor", .s = 4079 }, .{ .t = "knif", .s = 4080 },
    .{ .t = "tpot", .s = 4081 }, .{ .t = "jave", .s = 4082 }, .{ .t = "spea", .s = 4083 }, .{ .t = "bow", .s = 4084 },
    .{ .t = "pole", .s = 4086 }, .{ .t = "xbow", .s = 4087 }, .{ .t = "h2h", .s = 21258 }, .{ .t = "h2h2", .s = 21258 },
    .{ .t = "orb", .s = 4085 },  .{ .t = "wand", .s = 4085 }, .{ .t = "blun", .s = 4077 },
};

/// Attack speed class by speed (0x00721f10), read at `speed*5 - 50 + yOffset`.
const speed_table = [90]u8{
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1, 2, 2, 2,
    2, 2, 3, 2, 2, 3, 2, 3, 3, 2, 3, 2, 3, 3, 3, 3, 2, 4, 3, 3, 4, 3, 4, 4, 3, 4, 3, 4, 4, 4,
    4, 3, 5, 4, 4, 5, 4, 5, 5, 4, 5, 4, 5, 5, 5, 5, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
};
/// yOffset by class and melee/ranged (0x00722078).
const speed_offset = [14]u8{ 0, 2, 1, 4, 1, 4, 0, 3, 0, 3, 1, 4, 0, 3 };
const speed_words = [7]u16{ 4088, 4089, 4090, 4091, 4092, 4093, 4094 };
/// PlrType tokens by class, which name the class's animations in animdata.d2.
const class_tokens = [7][]const u8{ "AM", "SO", "NE", "PA", "BA", "DZ", "AI" };

const flag_broken: u32 = 0x100;

// -------------------------------------------------------------------------------------------------
// the describer

pub const Describer = struct {
    gpa: std.mem.Allocator,
    t: *const tables.Tables,
    s: *const strings.Strings,
    sd: statdesc.Ctx,
    auto_magic: txt.Table,
    arena: std.heap.ArenaAllocator,
    unique_rows: []usize,
    set_rows: []usize,
    prefix_rows: []usize,
    suffix_rows: []usize,
    rare_prefix_rows: []usize,
    rare_suffix_rows: []usize,

    pub fn init(gpa: std.mem.Allocator, t: *const tables.Tables, s: *const strings.Strings) !Describer {
        var d: Describer = undefined;
        d.gpa = gpa;
        d.t = t;
        d.s = s;
        d.sd = try statdesc.Ctx.init(gpa, t, s);
        errdefer d.sd.deinit();
        d.auto_magic = try txt.Table.parse(gpa, d2data.current("AutoMagic"));
        errdefer d.auto_magic.deinit();
        d.arena = std.heap.ArenaAllocator.init(gpa);
        const a = d.arena.allocator();
        d.unique_rows = try compact(a, &t.unique_items);
        d.set_rows = try compact(a, &t.set_items);
        d.prefix_rows = try compact(a, &t.magic_prefix);
        d.suffix_rows = try compact(a, &t.magic_suffix);
        d.rare_prefix_rows = try compact(a, &t.rare_prefix);
        d.rare_suffix_rows = try compact(a, &t.rare_suffix);
        return d;
    }

    pub fn deinit(self: *Describer) void {
        self.arena.deinit();
        self.auto_magic.deinit();
        self.sd.deinit();
    }

    fn idText(_: *const Describer, id: u16) []const u8 {
        return strings.byId(id) orelse "";
    }

    fn keyText(self: *const Describer, key: []const u8) []const u8 {
        return self.s.find(key) orelse (strings.byId(sid.dummy) orelse key);
    }

    /// The description of `host`, with `kids` the records socketed into it (in record order).
    pub fn describe(self: *const Describer, arena: std.mem.Allocator, host: *const wire.Item, kids: []const wire.Item, opts: Options) !Desc {
        var it = Item.init(self, arena, host, kids, opts) catch |e| return e;
        if (it.ref == null) return .{ .text = try arena.dupe(u8, host.codeSlice()) };
        if (it.bt.int(it.row, "Transmogrify") != 0 and host.identified()) return self.transmogrify(arena, &it);
        if (host.quality == .set and host.identified()) return self.setCard(arena, &it);
        if (it.types.has("book")) return self.bookCard(arena, &it);
        return self.generalCard(arena, &it);
    }

    // ---------------------------------------------------------------------------------------------
    // the general card (LoadItemDesc)

    fn generalCard(self: *const Describer, a: std.mem.Allocator, it: *Item) !Desc {
        const nl = self.idText(sid.newline);
        const h = it.host;
        const ident = h.identified() or h.compact;
        const weapon = it.types.has("weap");
        const armor = it.types.has("armo");

        var class_line = Text{ .gpa = a };
        var class_color: u8 = 0;
        if (it.itemClass()) |cls| {
            try class_line.s(self.idText(sid.class_only + cls));
            try class_line.s(nl);
            if (it.viewer) |v| {
                if (v.class != cls) class_color = 1;
            }
        }

        var durability = Text{ .gpa = a };
        if (!it.types.has("misl")) try self.durabilityLine(&durability, it);

        var req_level = Text{ .gpa = a };
        var req_level_color: u8 = 0;
        if (ident) {
            const rl = self.requiredLevel(it, h, it.kids);
            if (rl > 1) {
                if (it.viewer) |v| {
                    if (v.level < rl) req_level_color = 1;
                }
                try numberLine(&req_level, self.idText(sid.req_level), self.idText(sid.space), rl, nl);
            }
        }

        var filler = Text{ .gpa = a };
        if (it.types.has("sock")) try self.socketFillerDesc(&filler, it);

        var runes = Text{ .gpa = a };
        if (it.bt.int(it.row, "hasinv") != 0) try self.runeLetters(&runes, it);

        var charm = Text{ .gpa = a };
        if (it.types.has("char")) {
            try charm.s(self.idText(sid.keep_in_inventory));
            try charm.s(nl);
        }

        var eth_sock = Text{ .gpa = a };
        var req_str = Text{ .gpa = a };
        var req_dex = Text{ .gpa = a };
        var req_str_color: u8 = 0;
        var req_dex_color: u8 = 0;
        var damage = Text{ .gpa = a };
        var speed = Text{ .gpa = a };
        var kick_smite = Text{ .gpa = a };
        var block = Text{ .gpa = a };
        var defense = Text{ .gpa = a };
        if (weapon or armor) {
            try self.etherealSocketed(&eth_sock, h);
            const rq = it.requirements();
            if (rq.dex_txt != 0) {
                if (it.viewer) |v| {
                    if (v.dexterity < rq.dex) req_dex_color = 1;
                }
                if (rq.dex >= 1) try numberLine(&req_dex, self.idText(sid.req_dex), self.idText(sid.space), rq.dex, nl);
            }
            if (rq.str_txt != 0) {
                if (it.viewer) |v| {
                    if (v.strength < rq.str) req_str_color = 1;
                }
                if (rq.str >= 1) try numberLine(&req_str, self.idText(sid.req_str), self.idText(sid.space), rq.str, nl);
            }
            if (weapon) {
                try self.damageLines(&damage, it);
                try self.attackSpeed(&speed, it);
            }
            if (!it.types.has("shld")) {
                if (it.types.has("boot")) if (it.viewer) |v| if (v.class == 6) try self.kickSmite(&kick_smite, it, sid.kick);
            } else {
                if (it.viewer) |v| if (v.class == 3 and (it.itemClass() == null or it.itemClass().? == 3)) try self.kickSmite(&kick_smite, it, sid.smite);
                try self.blockLine(&block, it);
            }
            if (armor and it.base(31) > 0) try self.defenseLine(&defense, it);
        }

        var color: u8 = switch (@intFromEnum(h.quality)) {
            4 => 3,
            5 => 2,
            6 => 9,
            7 => 4,
            8 => 8,
            9 => 10,
            else => if (h.flags & wire.flag.SOCKETED != 0 or h.ethereal()) 5 else 0,
        };

        var unident = Text{ .gpa = a };
        var props = Text{ .gpa = a };
        var stat_cost = Text{ .gpa = a };
        if (!ident) {
            try unident.s(self.idText(sid.unidentified));
            try unident.s(nl);
        } else {
            if (h.dest != wire.Mode.socketed) try self.quantityLine(&stat_cost, it);
            try statdesc.describeList(&self.sd, &props, &it.list, it.env(), true, true);
        }
        try self.spellDesc(&stat_cost, it);

        var name = Text{ .gpa = a };
        try self.itemName(&name, it);

        const code = h.codeSlice();
        const orange = [_][]const u8{ "ceh", "bet", "tes", "fed", "toa", "dhn", "bey", "mbr", "pk1", "pk2", "pk3" };
        for (orange) |o| if (std.mem.eql(u8, code, o)) {
            color = 8;
        };
        if (it.types.has("rune")) color = 8;
        if (h.flags & flag_broken != 0) color = 1;

        var out = Text{ .gpa = a };
        try block_(&out, eth_sock.items(), 3);
        try block_(&out, props.items(), 3);
        try block_(&out, unident.items(), 1);
        try block_(&out, speed.items(), 0);
        try block_(&out, req_level.items(), req_level_color);
        try block_(&out, req_str.items(), req_str_color);
        try block_(&out, req_dex.items(), req_dex_color);
        try block_(&out, class_line.items(), class_color);
        try block_(&out, durability.items(), 0);
        try block_(&out, filler.items(), 0);
        try block_(&out, charm.items(), 0);
        try block_(&out, stat_cost.items(), 0);
        try block_(&out, damage.items(), 0);
        try block_(&out, kick_smite.items(), 0);
        try block_(&out, block.items(), 0);
        try block_(&out, defense.items(), 0);
        try block_(&out, runes.items(), 4);
        try block_(&out, name.items(), color);

        var desc = Desc{ .text = out.items() };
        if (it.bt.int(it.row, "quest") != 0 and !std.mem.eql(u8, code, "leg")) {
            var q = Text{ .gpa = a };
            if (it.opts.own_inventory and h.dest == wire.Mode.stored) {
                if (std.mem.eql(u8, code, "bkd")) {
                    try q.s(self.idText(sid.right_click_read));
                    try q.s(nl);
                } else if (std.mem.eql(u8, code, "box")) {
                    try q.s(self.idText(sid.right_click_open));
                    try q.s(nl);
                }
            }
            try q.s(desc.text);
            var q2 = Text{ .gpa = a };
            try block_(&q2, q.items(), 4);
            desc = .{ .text = q2.items(), .base_color = 4 };
        }
        return desc;
    }

    // ---------------------------------------------------------------------------------------------
    // the set item card (ITEM_BuildSetItemTooltip)

    fn setCard(self: *const Describer, a: std.mem.Allocator, it: *Item) !Desc {
        const nl = self.idText(sid.newline);
        const h = it.host;
        var stats = Text{ .gpa = a };
        const rl = self.requiredLevel(it, h, it.kids);
        const rq = it.requirements();
        const weapon = it.types.has("weap");
        const armor = it.types.has("armo");
        // the stats block, bottom first
        {
            var t = Text{ .gpa = a };
            if (rl > 1) try numberLine(&t, self.idText(sid.req_level), self.idText(sid.space), rl, nl);
            try block_(&stats, t.items(), if (it.viewer) |v| @intFromBool(v.level < rl) else 0);
        }
        if (weapon or armor) {
            var t = Text{ .gpa = a };
            if (rq.str_txt != 0 and rq.str >= 1) try numberLine(&t, self.idText(sid.req_str), self.idText(sid.space), rq.str, nl);
            try block_(&stats, t.items(), if (it.viewer) |v| @intFromBool(v.strength < rq.str) else 0);
            var t2 = Text{ .gpa = a };
            if (rq.dex_txt != 0 and rq.dex >= 1) try numberLine(&t2, self.idText(sid.req_dex), self.idText(sid.space), rq.dex, nl);
            try block_(&stats, t2.items(), if (it.viewer) |v| @intFromBool(v.dexterity < rq.dex) else 0);
        }
        if (it.itemClass()) |cls| {
            var t = Text{ .gpa = a };
            try t.s(self.idText(sid.class_only + cls));
            try t.s(nl);
            try block_(&stats, t.items(), if (it.viewer) |v| @intFromBool(v.class != cls) else 0);
        }
        {
            var t = Text{ .gpa = a };
            if (!it.types.has("misl")) try self.durabilityLine(&t, it);
            try block_(&stats, t.items(), 0);
        }
        if (weapon) {
            var t = Text{ .gpa = a };
            try self.attackSpeed(&t, it);
            try block_(&stats, t.items(), 0);
            var t2 = Text{ .gpa = a };
            try self.damageLines(&t2, it);
            try block_(&stats, t2.items(), 0);
        }
        if (it.types.has("shld")) {
            var t = Text{ .gpa = a };
            if (it.viewer) |v| if (v.class == 3) try self.kickSmite(&t, it, sid.smite);
            try block_(&stats, t.items(), 0);
            var t2 = Text{ .gpa = a };
            try self.blockLine(&t2, it);
            try block_(&stats, t2.items(), 0);
        }
        if (armor and it.base(31) > 0) {
            var t = Text{ .gpa = a };
            try self.defenseLine(&t, it);
            try block_(&stats, t.items(), 0);
        }
        var name = Text{ .gpa = a };
        try self.itemName(&name, it);
        try block_(&stats, name.items(), if (h.flags & flag_broken != 0) 1 else 2);

        var out = Text{ .gpa = a };
        // the members of the set, each green when the character has it
        const set_row = it.set_row orelse return .{ .text = stats.items() };
        const set_key = self.t.set_items.str(set_row, "set");
        for (self.set_rows, 0..) |r, set_id| {
            if (!std.ascii.eqlIgnoreCase(self.t.set_items.str(r, "set"), set_key)) continue;
            var t = Text{ .gpa = a };
            try positionalFormat(&t, self.idText(sid.set_fmt), &.{self.keyText(self.t.set_items.str(r, "index"))});
            try t.s(nl);
            const owned = if (it.viewer) |v| contains(v.set_items_owned, @intCast(set_id)) else false;
            try block_(&out, t.items(), if (owned) 2 else 1);
        }
        if (self.t.sets.findByStr("index", set_key)) |sr| {
            try out.s(color_code);
            try out.s("4");
            try out.s(self.keyText(self.t.sets.str(sr, "name")));
            try out.s(nl);
        }
        var full = Text{ .gpa = a };
        try self.setBonusByState(&full, it, set_key);
        if (full.items().len != 0) {
            try out.s(nl);
            try out.s(color_code);
            try out.s("4");
            try out.s(full.items());
        }
        try out.s(nl);
        var partial = Text{ .gpa = a };
        try self.setBonusLists(&partial, it);
        if (partial.items().len != 0) {
            try out.s(color_code);
            try out.s("2");
            try out.s(partial.items());
        }
        var own = Text{ .gpa = a };
        if (h.flags & wire.flag.SOCKETED != 0) try self.etherealSocketed(&own, h);
        try statdesc.describeList(&self.sd, &own, &it.list, it.env(), true, true);
        try block_(&out, own.items(), 3);
        try out.s(stats.items());
        return .{ .text = out.items() };
    }

    /// SKILLDESC_AppendSetBonusTextByStateValue 0x004e6680: an equipped set item shows the bonuses its set
    /// gives the wearer, the state list the engine builds from Sets.txt for the pieces worn: the two-piece
    /// through five-piece lines for each count reached, and the full-set lines once every piece is worn.
    fn setBonusByState(self: *const Describer, out: *Text, it: *Item, set_key: []const u8) !void {
        const v = it.viewer orelse return;
        if (it.host.dest != wire.Mode.equipped) return;
        const sr = self.t.sets.findByStr("index", set_key) orelse return;
        var members: usize = 0;
        var worn: usize = 0;
        for (self.set_rows, 0..) |r, set_id| {
            if (!std.ascii.eqlIgnoreCase(self.t.set_items.str(r, "set"), set_key)) continue;
            members += 1;
            if (contains(v.set_items_worn, @intCast(set_id))) worn += 1;
        }
        if (worn < 2) return;
        var rolled: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        var seed = rng.Seed.init(1, 0x29a);
        const sets = &self.t.sets;
        var buf: [4][12]u8 = undefined;
        var k: usize = 2;
        while (k <= @min(worn, 5)) : (k += 1) {
            for ([_]u8{ 'a', 'b' }) |ab| {
                const code = sets.str(sr, std.fmt.bufPrint(&buf[0], "PCode{d}{c}", .{ k, ab }) catch unreachable);
                if (code.len == 0) continue;
                const par: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[1], "PParam{d}{c}", .{ k, ab }) catch unreachable));
                const lo: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[2], "PMin{d}{c}", .{ k, ab }) catch unreachable));
                const hi: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[3], "PMax{d}{c}", .{ k, ab }) catch unreachable));
                try properties.applyProperty(it.a, &rolled, &seed, self.t, code, par, lo, hi, .{});
            }
        }
        if (worn == members) {
            var f: usize = 1;
            while (f <= 8) : (f += 1) {
                const code = sets.str(sr, std.fmt.bufPrint(&buf[0], "FCode{d}", .{f}) catch unreachable);
                if (code.len == 0) continue;
                const par: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[1], "FParam{d}", .{f}) catch unreachable));
                const lo: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[2], "FMin{d}", .{f}) catch unreachable));
                const hi: i32 = @intCast(sets.int(sr, std.fmt.bufPrint(&buf[3], "FMax{d}", .{f}) catch unreachable));
                try properties.applyProperty(it.a, &rolled, &seed, self.t, code, par, lo, hi, .{});
            }
        }
        var list = StatList{};
        for (rolled.items) |rs| {
            const st: u16 = @intCast(rs.stat);
            const vs: u5 = if (self.sd.row(st)) |r| @intCast(@min(self.t.item_stat_cost.int(r, "ValShift"), 16)) else 0;
            try list.add(it.a, st, @intCast(@max(rs.layer, 0)), rs.value << vs);
        }
        try statdesc.describeList(&self.sd, out, &list, it.env(), true, false);
    }

    /// The partial set bonus lists of the item that the worn pieces switch on (SKILLDESC_AppendItemBuffText
    /// 0x004e6560): SetItems `add func` 1 keys a list to each other worn member, 2 shows one list per worn
    /// piece beyond the first.
    fn setBonusLists(self: *const Describer, out: *Text, it: *Item) !void {
        const v = it.viewer orelse return;
        const sr = it.set_row orelse return;
        const set_key = self.t.set_items.str(sr, "set");
        var own_index: usize = 0;
        var mask: u32 = 0;
        var n: usize = 0;
        for (self.set_rows, 0..) |r, set_id| {
            if (!std.ascii.eqlIgnoreCase(self.t.set_items.str(r, "set"), set_key)) continue;
            if (r == sr) own_index = n;
            if (contains(v.set_items_worn, @intCast(set_id))) mask |= @as(u32, 1) << @intCast(n);
            n += 1;
        }
        var show = [5]bool{ false, false, false, false, false };
        switch (self.t.set_items.int(sr, "add func")) {
            1 => for (0..n) |i| {
                if (i == own_index or mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                const k = if (i < own_index) i else i - 1;
                if (k < 5) show[k] = true;
            },
            2 => {
                const worn = @popCount(mask);
                var k: usize = 0;
                while (k + 1 < worn and k < 5) : (k += 1) show[k] = true;
            },
            else => {},
        }
        for (0..5) |k| {
            if (!show[k]) continue;
            var list = StatList{};
            for (it.host.stats[0..it.host.n_stats]) |st| {
                if (st.list == k + 1) try list.add(it.a, st.id, @truncate(st.param), st.value);
            }
            try statdesc.describeList(&self.sd, out, &list, it.env(), true, false);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // tomes and transmogrify

    fn bookCard(self: *const Describer, a: std.mem.Allocator, it: *Item) !Desc {
        const nl = self.idText(sid.newline);
        var out = Text{ .gpa = a };
        try self.quantityLine(&out, it);
        if (it.opts.own_inventory) {
            try out.s(self.idText(sid.right_click_use));
            try out.s(nl);
            try out.s(self.idText(sid.insert_scrolls));
            try out.s(nl);
        }
        try self.itemName(&out, it);
        return .{ .text = out.items(), .centered = false };
    }

    fn transmogrify(self: *const Describer, a: std.mem.Allocator, it: *Item) !Desc {
        const nl = self.idText(sid.newline);
        var out = Text{ .gpa = a };
        const target = it.bt.str(it.row, "TMogType");
        if (self.t.itemRef(target)) |tr| try out.s(self.keyText(self.t.itemTable(tr.table).str(tr.row, "namestr")));
        try out.s(nl);
        try out.s(self.idText(sid.right_click_make));
        try out.s(nl);
        try self.itemName(&out, it);
        return .{ .text = out.items(), .centered = false };
    }

    // ---------------------------------------------------------------------------------------------
    // the name (GetItemName)

    fn itemName(self: *const Describer, out: *Text, it: *Item) !void {
        const a = it.a;
        const h = it.host;
        const nl = self.idText(sid.newline);
        const base = it.base_name;
        var name = Text{ .gpa = a };
        const personal = h.flags & wire.flag.PLAYERNAME != 0 and h.ownerSlice().len != 0;
        const q = @intFromEnum(h.quality);
        if (h.flags & wire.flag.BODYPART != 0) {
            // an ear: the possessive name, the class, the level
            try name.s(self.idText(sid.level));
            try name.s(self.idText(sid.space));
            try name.int(h.ear_level);
            try name.s(nl);
            try name.s(self.idText(ear_classes[@min(h.ear_class, 6)]));
            try name.s(nl);
            try possessive(&name, h.ownerSlice(), base);
        } else if (h.flags & wire.flag.RUNEWORD != 0) {
            try name.s(base);
            try name.s(nl);
            try name.s(color_code);
            try name.s("4");
            try name.s(strings.byId(h.runeword_id) orelse " ");
        } else if (!h.identified() and !h.compact) {
            try name.s(base);
        } else switch (q) {
            1 => {
                const lq = self.t.low_quality_items.str(@min(h.file_index, @as(u8, @intCast(self.t.low_quality_items.rowCount() -| 1))), "Name");
                try positionalFormat(&name, self.idText(sid.name2), &.{ self.keyText(lq), base });
            },
            3 => try positionalFormat(&name, self.idText(sid.superior_fmt), &.{ self.idText(sid.superior), base }),
            4 => {
                const pre = if (h.prefix != 0 and h.prefix - 1 < self.prefix_rows.len) self.keyText(self.t.magic_prefix.str(self.prefix_rows[h.prefix - 1], "Name")) else "";
                const suf = if (h.suffix != 0 and h.suffix - 1 < self.suffix_rows.len) self.keyText(self.t.magic_suffix.str(self.suffix_rows[h.suffix - 1], "Name")) else "";
                try positionalFormat(&name, self.idText(sid.magic_fmt), &.{ pre, base, suf });
            },
            5 => {
                try name.s(base);
                try name.s(nl);
                const sn = if (it.set_row) |r| self.keyText(self.t.set_items.str(r, "index")) else "";
                if (personal) try possessive(&name, h.ownerSlice(), sn) else try positionalFormat(&name, self.idText(sid.set_fmt), &.{sn});
            },
            6, 8, 9 => {
                try name.s(base);
                try name.s(nl);
                var rare = Text{ .gpa = a };
                try positionalFormat(&rare, self.idText(sid.rare_fmt), &.{ self.rareWord(h.rare_name1), self.rareWord(h.rare_name2) });
                if (personal) try possessive(&name, h.ownerSlice(), rare.items()) else try name.s(rare.items());
            },
            7 => {
                if (it.bt.int(it.row, "SkipName") == 0) {
                    try name.s(base);
                    try name.s(nl);
                }
                const un = if (it.unique_row) |r| self.keyText(self.t.unique_items.str(r, "index")) else base;
                if (personal) try possessive(&name, h.ownerSlice(), un) else try name.s(un);
            },
            else => {
                if (h.flags & wire.flag.SOCKETED != 0 and it.kids.len != 0 and !h.compact) {
                    try positionalFormat(&name, self.idText(sid.gemmed_fmt), &.{ self.idText(sid.gemmed), base });
                } else try name.s(base);
            },
        }
        if (personal and q >= 1 and q <= 4 and h.flags & wire.flag.BODYPART == 0) {
            var p = Text{ .gpa = a };
            try possessive(&p, h.ownerSlice(), name.items());
            name = p;
        }
        if (it.bt.int(it.row, "quest") != 0 and !std.mem.eql(u8, h.codeSlice(), "leg")) {
            try out.s(color_code);
            try out.s("4");
        }
        try out.s(name.items());
    }

    fn rareWord(self: *const Describer, id: u8) []const u8 {
        if (id == 0) return "";
        const i: usize = id - 1;
        if (i < self.rare_suffix_rows.len) return self.keyText(self.t.rare_suffix.str(self.rare_suffix_rows[i], "name"));
        const p = i - self.rare_suffix_rows.len;
        if (p < self.rare_prefix_rows.len) return self.keyText(self.t.rare_prefix.str(self.rare_prefix_rows[p], "name"));
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // lines

    fn etherealSocketed(self: *const Describer, out: *Text, h: *const wire.Item) !void {
        const eth = h.ethereal();
        if (eth) try out.s(self.idText(sid.ethereal));
        if (h.flags & wire.flag.SOCKETED != 0) {
            if (eth) try out.s(", ");
            try out.s(self.idText(sid.socketable));
            try out.s(self.idText(sid.space));
            try out.buf.print(out.gpa, "({d})", .{h.sockets});
            try out.s(self.idText(sid.newline));
            return;
        }
        if (eth) try out.s(self.idText(sid.newline));
    }

    fn durabilityLine(self: *const Describer, out: *Text, it: *Item) !void {
        if (!it.hasDurability()) return;
        const max = it.full(73);
        if (max <= 0) return;
        if (it.types.has("thro")) return;
        try out.s(self.idText(sid.durability));
        try out.s(self.idText(sid.space));
        try out.int(it.full(72));
        try out.s(self.idText(sid.space));
        try out.s(self.idText(sid.of));
        try out.s(self.idText(sid.space));
        if (it.list.get(75, 0) != 0) {
            try out.s(color_code);
            try out.s("3");
        }
        try out.int(max);
        try out.s(self.idText(sid.newline));
    }

    fn defenseLine(self: *const Describer, out: *Text, it: *Item) !void {
        const ac = it.full(31);
        try out.s(self.idText(sid.defense));
        try out.s(self.idText(sid.space));
        if (ac != it.base(31)) {
            try out.s(color_code);
            try out.s("3");
        }
        try out.int(ac);
        try out.s(self.idText(sid.newline));
    }

    fn blockLine(self: *const Describer, out: *Text, it: *Item) !void {
        var b = it.full(20);
        if (it.viewer) |v| {
            const cs = &self.sd.char_stats;
            if (v.class < 7) b += @intCast(cs.int(self.sd.class_rows[v.class], "BlockFactor"));
            if (b > 75) b = 75;
        } else if (b == 0) return;
        var num = Text{ .gpa = it.a };
        try num.buf.print(it.a, "{d}%\n", .{b});
        try out.s(color_code);
        try out.s("0");
        try out.s(self.idText(sid.block));
        if (b > it.bt.int(it.row, "block")) {
            try out.s(color_code);
            try out.s("3");
        }
        try out.s(num.items());
    }

    fn kickSmite(self: *const Describer, out: *Text, it: *Item, label: u16) !void {
        try out.s(self.idText(label));
        try out.s(self.idText(sid.space));
        try out.int(it.bt.int(it.row, "mindam"));
        try out.s(self.idText(sid.space));
        try out.s(self.idText(sid.to));
        try out.s(self.idText(sid.space));
        try out.int(it.bt.int(it.row, "maxdam"));
        try out.s(self.idText(sid.newline));
    }

    fn damageRange(it: *Item, min_stat: u16, max_stat: u16, modified: *bool) [2]i32 {
        const mn = it.full(min_stat);
        var mx = it.full(max_stat);
        if (it.base(min_stat) < mn or it.base(max_stat) < mx) modified.* = true;
        if (mx < mn) mx = mn;
        return .{ mn, mx };
    }

    fn damageLine(self: *const Describer, out: *Text, label: u16, r: [2]i32, modified: bool, clamp: bool) !void {
        var mx = r[1];
        if (clamp and mx <= r[0] + 1) mx = r[0] + 1;
        try out.s(self.idText(label));
        try out.s(self.idText(sid.space));
        if (modified) {
            try out.s(color_code);
            try out.s("3");
        }
        try out.int(r[0]);
        try out.s(self.idText(sid.space));
        try out.s(self.idText(sid.to));
        try out.s(self.idText(sid.space));
        try out.int(mx);
        try out.s(self.idText(sid.newline));
    }

    fn damageLines(self: *const Describer, out: *Text, it: *Item) !void {
        if (it.types.has("tpot")) return; // missile potions: elemental damage from Missiles.txt, not drawn here
        var modified = false;
        const barb_both = if (it.viewer) |v| v.class == 4 and it.bt.int(it.row, "1or2handed") != 0 else false;
        if (barb_both) {
            const two = damageRange(it, 23, 24, &modified);
            var t2 = Text{ .gpa = it.a };
            try self.damageLine(&t2, sid.two_hand, two, modified, false);
            const one = damageRange(it, 21, 22, &modified);
            var t1 = Text{ .gpa = it.a };
            try self.damageLine(&t1, sid.one_hand, one, modified, false);
            try block_(out, t2.items(), 0);
            try block_(out, t1.items(), 0);
        } else if (it.bt.int(it.row, "2handed") != 0) {
            try self.damageLine(out, sid.two_hand, damageRange(it, 23, 24, &modified), modified, true);
        } else {
            try self.damageLine(out, sid.one_hand, damageRange(it, 21, 22, &modified), modified, true);
        }
        if (!it.types.has("thro")) return;
        modified = it.list.get(18, 0) != 0 or it.list.get(17, 0) != 0 or it.list.get(159, 0) != 0 or it.list.get(160, 0) != 0;
        const r = damageRange(it, 159, 160, &modified);
        try out.s(color_code);
        try out.s("0");
        try out.s(self.idText(sid.throw));
        try out.s(self.idText(sid.space));
        try out.s(color_code);
        try out.s(if (modified) "3" else "0");
        try out.int(r[0]);
        try out.s(self.idText(sid.space));
        try out.s(self.idText(sid.to));
        try out.s(self.idText(sid.space));
        try out.s(color_code);
        try out.s(if (modified) "3" else "0");
        try out.int(r[1]);
        try out.s(self.idText(sid.newline));
    }

    fn attackSpeed(self: *const Describer, out: *Text, it: *Item) !void {
        const v = it.viewer orelse return;
        const anim = it.opts.animdata orelse return;
        if (v.class >= 7) return;
        var wclass_buf: [8]u8 = undefined;
        var wl: usize = 0;
        for (it.bt.str(it.row, "wclass")) |ch| if (ch != ' ' and wl < wclass_buf.len) {
            wclass_buf[wl] = ch;
            wl += 1;
        };
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}A1{s}", .{ class_tokens[v.class], wclass_buf[0..wl] }) catch return;
        const rec = animRecord(anim, key) orelse AnimRecord{ .frames = 0, .speed = 0 };
        var frames = rec.frames;
        var aspeed = rec.speed;
        if (!rec.found) {
            frames = 0;
            aspeed = 0;
        }
        const ias = it.full(93);
        const rate = it.full(68);
        const d = @divTrunc((ias + 100 + rate) * @as(i32, @intCast(aspeed)), 100);
        const s: i32 = if (d == 0 or frames == 0) 45 else @divTrunc(@as(i32, @intCast(frames)) << 8, d);
        var cls: usize = 0;
        if (s >= 28) cls = 5 else if (s < 10) cls = 1 else {
            const ranged: usize = @intFromBool(it.types.has("xbow") or it.types.has("bow"));
            const idx: i32 = s * 5 - 50 + speed_offset[ranged + @as(usize, v.class) * 2];
            cls = speed_table[@intCast(std.math.clamp(idx, 0, 89))];
        }
        for (weapon_classes) |wc| if (it.types.has(wc.t)) {
            try out.s(self.idText(wc.s));
            try out.s(self.idText(sid.space));
            try out.s(self.idText(sid.dash));
            try out.s(self.idText(sid.space));
            break;
        };
        if (it.list.get(93, 0) != 0) {
            try out.s(color_code);
            try out.s("3");
        }
        try out.s(self.idText(speed_words[cls]));
        try out.s(self.idText(sid.newline));
    }

    fn quantityLine(self: *const Describer, out: *Text, it: *Item) !void {
        const qty: i32 = it.host.quantity;
        if (qty < 1 and it.bt.int(it.row, "maxstack") < 1) return;
        if (qty < 1 and it.bt.int(it.row, "stackable") == 0) return;
        try numberLine(out, self.idText(sid.quantity), self.idText(sid.space), qty, self.idText(sid.newline));
    }

    /// INV_FormatItemStatCostText 0x00486370: the Items.txt spell description of potions and the like.
    fn spellDesc(self: *const Describer, out: *Text, it: *Item) !void {
        const mode = it.bt.int(it.row, "spelldesc");
        if (mode == 0) return;
        const key = it.bt.str(it.row, "spelldescstr");
        const str = self.s.find(key) orelse return;
        const nl = self.idText(sid.newline);
        switch (mode) {
            1 => {
                out.buf.clearRetainingCapacity();
                try out.s(str);
                try out.s(nl);
            },
            2, 3 => {
                // the calc is a plain number in every stock row; difficulty adjustments not applied
                const v = it.bt.int(it.row, "calc1");
                out.buf.clearRetainingCapacity();
                try out.s(str);
                try out.s(self.idText(sid.space));
                try out.int(v);
                try out.s(nl);
            },
            4 => {
                try statdesc.format(out, str, &.{.{ .i = it.bt.int(it.row, "calc1") }});
                try out.s(nl);
            },
            else => {},
        }
    }

    /// INV_FormatRunewordName 0x00486670: the letters of the runes in the item, in socket order.
    fn runeLetters(self: *const Describer, out: *Text, it: *Item) !void {
        var any = false;
        for (it.kids) |*k| {
            const types = itemtype.typesForItem(it.a, self.t, k.codeSlice()) catch continue;
            if (!types.has("rune")) continue;
            const gr = self.t.gems.findByStr("code", k.codeSlice()) orelse continue;
            if (!any) try out.s(self.idText(sid.rune_quote));
            any = true;
            try out.s(self.t.gems.str(gr, "letter"));
        }
        if (any) {
            try out.s(self.idText(sid.rune_quote));
            try out.s(self.idText(sid.newline));
        }
    }

    /// INV_FormatSocketFillerDesc 0x004865d0 with SKILLDESC_BuildMagicAffixDesc 0x004e6850.
    fn socketFillerDesc(self: *const Describer, out: *Text, it: *Item) !void {
        const nl = self.idText(sid.newline);
        const code = it.host.codeSlice();
        const gem = it.types.has("gem");
        const rune = it.types.has("rune");
        if (gem or rune) {
            const slots = [_]struct { label: u16, target: properties.SocketTarget }{
                .{ .label = sid.shields, .target = .shield },
                .{ .label = sid.helms, .target = .helm },
                .{ .label = sid.armor, .target = .helm },
                .{ .label = sid.weapons, .target = .weapon },
            };
            for (slots) |sl| {
                try out.s(nl);
                var label = Text{ .gpa = it.a };
                try label.s(self.idText(sl.label));
                try label.s(self.idText(sid.space));
                var list = StatList{};
                try self.fillerStats(it.a, &list, code, sl.target);
                var stats = Text{ .gpa = it.a };
                try statdesc.describeList(&self.sd, &stats, &list, it.env(), rune, false);
                try prefixed(out, stats.items(), label.items(), nl, self.idText(sid.comma));
                // SKILLDESC_FormatMagicPrefixDesc 0x004e6720 and FormatMagicSuffixDesc 0x004e67d0 drop the newline the text ends in
                if (out.buf.items.len != 0 and out.buf.items[out.buf.items.len - 1] == '\n') out.buf.items.len -= 1;
            }
            try out.s(nl);
            try out.s(nl);
        }
        try out.s(self.idText(sid.can_be_inserted));
        try out.s(nl);
    }

    fn fillerStats(self: *const Describer, a: std.mem.Allocator, list: *StatList, code: []const u8, target: properties.SocketTarget) !void {
        var rolled: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        var seed = rng.Seed.init(1, 0x29a);
        try properties.rollSocketFillerStats(a, &rolled, &seed, self.t, code, target, .{ .code = code });
        for (rolled.items) |rs| {
            const st: u16 = @intCast(rs.stat);
            const vs: u5 = if (self.sd.row(st)) |r| @intCast(@min(self.t.item_stat_cost.int(r, "ValShift"), 16)) else 0;
            try list.add(a, st, @intCast(@max(rs.layer, 0)), rs.value << vs);
        }
    }

    /// ITEM_CalcRequiredLevel 0x0062b5b0.
    fn requiredLevel(self: *const Describer, it: *Item, h: *const wire.Item, kids: []const wire.Item) i32 {
        const v = it.viewer;
        var q: i64 = 0;
        const R = struct {
            fn of(d: *const Describer, tbl: *const txt.Table, row: usize, viewer: ?Viewer) i64 {
                const cls = tbl.str(row, "class");
                if (cls.len != 0) if (viewer) |vv| if (statdesc.classOfCode(cls)) |c| if (c == vv.class) return tbl.int(row, "classlevelreq");
                _ = d;
                return tbl.int(row, "levelreq");
            }
        };
        const ref = self.t.itemRef(h.codeSlice()) orelse return 0;
        const bt = self.t.itemTable(ref.table);
        switch (@intFromEnum(h.quality)) {
            4 => {
                if (h.prefix != 0 and h.prefix - 1 < self.prefix_rows.len) q = @max(q, R.of(self, &self.t.magic_prefix, self.prefix_rows[h.prefix - 1], v));
                if (h.suffix != 0 and h.suffix - 1 < self.suffix_rows.len) q = @max(q, R.of(self, &self.t.magic_suffix, self.suffix_rows[h.suffix - 1], v));
                if (h.automagic != 0 and h.automagic - 1 < self.auto_magic.rowCount()) q = @max(q, R.of(self, &self.auto_magic, h.automagic - 1, v));
            },
            6, 8 => {
                var n_pre: i64 = 0;
                var n_suf: i64 = 0;
                for (h.rare_prefixes) |p| if (p != 0 and p - 1 < self.prefix_rows.len) {
                    q = @max(q, R.of(self, &self.t.magic_prefix, self.prefix_rows[p - 1], v));
                    n_pre += 1;
                };
                for (h.rare_suffixes) |sx| if (sx != 0 and sx - 1 < self.suffix_rows.len) {
                    q = @max(q, R.of(self, &self.t.magic_suffix, self.suffix_rows[sx - 1], v));
                    n_suf += 1;
                };
                if (h.quality == .crafted) {
                    q += 10 + 3 * n_pre + 3 * n_suf;
                    if (q > 98) q = 98;
                } else if (h.automagic != 0 and h.automagic - 1 < self.auto_magic.rowCount()) q = @max(q, R.of(self, &self.auto_magic, h.automagic - 1, v));
            },
            5 => if (h.set_id < self.set_rows.len) {
                const l = self.t.set_items.int(self.set_rows[h.set_id], "lvl req");
                if (l >= 0) q = l;
            },
            7 => if (h.unique_id < self.unique_rows.len) {
                const l = self.t.unique_items.int(self.unique_rows[h.unique_id], "lvl req");
                if (l >= 0) q = l;
            },
            else => {},
        }
        q = @max(q, bt.int(ref.row, "levelreq"));
        for (kids) |*k| q = @max(q, self.requiredLevel(it, k, &.{}));
        if (h == it.host) {
            for (it.list.ofStat(107)) |e| if (self.t.skills.findByInt("Id", e.param)) |sr| {
                q = @max(q, self.t.skills.int(sr, "reqlevel"));
            };
            for (it.list.ofStat(97)) |e| if (self.t.skills.findByInt("Id", e.param)) |sr| {
                var req = self.t.skills.int(sr, "reqlevel") + 6;
                if (v) |vv| if (statdesc.classOfCode(self.t.skills.str(sr, "charclass"))) |c| if (c == vv.class) {
                    req -= 6;
                };
                q = @max(q, req);
            };
            q += it.list.get(92, 0);
        }
        return @intCast(@max(0, q));
    }
};

// -------------------------------------------------------------------------------------------------
// one item and its numbers

const Requirements = struct { str: i32, dex: i32, str_txt: i64, dex_txt: i64 };

const Item = struct {
    d: *const Describer,
    a: std.mem.Allocator,
    host: *const wire.Item,
    kids: []const wire.Item,
    opts: Options,
    viewer: ?Viewer,
    ref: ?tables.Tables.ItemRef,
    bt: *const txt.Table,
    row: usize,
    types: itemtype.TypeSet,
    base_name: []const u8,
    unique_row: ?usize,
    set_row: ?usize,
    /// The own list, the runeword list and the socket fillers, merged (what the walk and the numbers read).
    list: StatList,
    base_stats: [512]i32,

    fn init(d: *const Describer, a: std.mem.Allocator, h: *const wire.Item, kids: []const wire.Item, opts: Options) !Item {
        var it: Item = undefined;
        it.d = d;
        it.a = a;
        it.host = h;
        it.kids = kids;
        it.opts = opts;
        it.viewer = opts.viewer;
        it.ref = d.t.itemRef(h.codeSlice());
        it.list = .{};
        @memset(&it.base_stats, 0);
        const ref = it.ref orelse return it;
        it.bt = d.t.itemTable(ref.table);
        it.row = ref.row;
        it.types = try itemtype.typesForItem(a, d.t, h.codeSlice());
        it.base_name = d.keyText(it.bt.str(it.row, "namestr"));
        it.unique_row = if (h.quality == .unique and h.unique_id < d.unique_rows.len) d.unique_rows[h.unique_id] else null;
        it.set_row = if (h.quality == .set and h.set_id < d.set_rows.len) d.set_rows[h.set_id] else null;

        for (h.stats[0..h.n_stats]) |st| {
            if (st.list == wire.list_base) {
                if (st.id < 512) it.base_stats[st.id] = st.value;
            } else if (st.list == 0 or st.list == wire.list_runeword) {
                try it.list.add(a, st.id, @truncate(st.param), st.value);
            }
        }
        const apply: properties.SocketTarget = switch (it.bt.int(it.row, "gemapplytype")) {
            1 => .helm,
            2 => .shield,
            else => .weapon,
        };
        for (kids) |*k| {
            if (k.compact) {
                try d.fillerStats(a, &it.list, k.codeSlice(), apply);
            } else for (k.stats[0..k.n_stats]) |st| {
                if (st.list == 0) try it.list.add(a, st.id, @truncate(st.param), st.value);
            }
        }
        it.loadBase();
        return it;
    }

    /// The base stats the engine sets when it loads the record (ITEM_DeserializeFromBitBuffer 0x0062cbe0).
    fn loadBase(it: *Item) void {
        const bt = it.bt;
        const r = it.row;
        if (it.types.has("armo")) {
            it.base_stats[20] = @intCast(bt.int(r, "block"));
            it.base_stats[67] = -@as(i32, @intCast(bt.int(r, "speed")));
        }
        if (!it.types.has("weap")) return;
        it.base_stats[68] = -@as(i32, @intCast(bt.int(r, "speed")));
        const pairs = [_]struct { lo: u16, hi: u16, clo: []const u8, chi: []const u8 }{
            .{ .lo = 21, .hi = 22, .clo = "mindam", .chi = "maxdam" },
            .{ .lo = 23, .hi = 24, .clo = "2handmindam", .chi = "2handmaxdam" },
            .{ .lo = 159, .hi = 160, .clo = "minmisdam", .chi = "maxmisdam" },
        };
        for (pairs, 0..) |p, i| {
            var lo: i32 = @intCast(bt.int(r, p.clo));
            var hi: i32 = @intCast(bt.int(r, p.chi));
            if (i == 2 and hi == 0) continue;
            if (it.host.quality == .low) {
                if (lo != 0 or i == 2) {
                    lo = (lo * 3) >> 2;
                    if (lo < 1) lo = 1;
                }
                if (hi != 0) {
                    hi = (hi * 3) >> 2;
                    if (hi < 2) hi = 2;
                }
            }
            if (it.host.ethereal()) {
                lo = @divTrunc(lo * 3, 2);
                hi = @divTrunc(hi * 3, 2);
            }
            // a record carrying enhanced damage raises a base below the txt back to it
            const txt_lo: i32 = @intCast(bt.int(r, p.clo));
            const txt_hi: i32 = @intCast(bt.int(r, p.chi));
            if (i != 2 or it.types.has("thro")) {
                if (it.list.get(17, 0) != 0 or it.list.get(18, 0) != 0) {
                    if (txt_hi != 0 and hi < txt_hi) hi = txt_hi;
                    if (txt_lo != 0 and lo < txt_lo) lo = txt_lo;
                }
            }
            it.base_stats[p.lo] = lo;
            it.base_stats[p.hi] = hi;
        }
    }

    fn base(it: *const Item, stat: u16) i32 {
        return it.base_stats[stat];
    }

    fn level(it: *const Item) i32 {
        return if (it.viewer) |v| v.level else it.opts.level;
    }

    /// STATSEX_GetCurrentStat of the item while it hangs on the viewer: base + the merged lists + the ops
    /// that target the stat (op 13 percent of base, op 4/5 per level).
    fn full(it: *const Item, stat: u16) i32 {
        const b = it.base(stat);
        var total: i32 = b + it.list.get(stat, 0);
        const isc = &it.d.t.item_stat_cost;
        const name = isc.str(it.d.sd.row(stat) orelse return total, "Stat");
        var prev: i32 = total;
        for (0..isc.rowCount()) |r| {
            const op = isc.int(r, "op");
            if (op == 0) continue;
            const hits = std.mem.eql(u8, isc.str(r, "op stat1"), name) or std.mem.eql(u8, isc.str(r, "op stat2"), name) or std.mem.eql(u8, isc.str(r, "op stat3"), name);
            if (!hits) continue;
            const src: u16 = @intCast(isc.int(r, "ID"));
            const sv = it.list.get(src, 0);
            if (sv == 0) continue;
            const shift: u5 = @intCast(@min(isc.int(r, "op param"), 31));
            switch (op) {
                13 => {
                    prev = b;
                    if (prev != 0) total += applyPercent(prev, sv);
                },
                4 => total += (sv *% it.level()) >> shift,
                5 => total += applyPercent(prev, (sv *% it.level()) >> shift),
                else => {},
            }
        }
        return total;
    }

    fn hasDurability(it: *const Item) bool {
        return it.bt.int(it.row, "nodurability") == 0 and it.bt.int(it.row, "durability") != 0;
    }

    /// The (Class) Only class of the item's type, if any.
    fn itemClass(it: *const Item) ?u8 {
        const tr = it.d.t.itypeRow(it.bt.str(it.row, "type")) orelse return null;
        return statdesc.classOfCode(it.d.t.item_types.str(tr, "Class"));
    }

    fn requirements(it: *const Item) Requirements {
        const pct = it.list.get(91, 0);
        const rs = it.bt.int(it.row, "reqstr");
        const rd = it.bt.int(it.row, "reqdex");
        var adj_s: i64 = if (pct != 0) @divTrunc(rs * pct, 100) else 0;
        var adj_d: i64 = if (pct != 0) @divTrunc(rd * pct, 100) else 0;
        if (it.host.ethereal()) {
            adj_s -= 10;
            adj_d -= 10;
        }
        return .{ .str = @intCast(rs + adj_s), .dex = @intCast(rd + adj_d), .str_txt = rs, .dex_txt = rd };
    }

    fn env(it: *const Item) statdesc.Env {
        return .{
            .player_level = it.level(),
            .player_class = if (it.viewer) |v| v.class else null,
            .blunt = it.types.has("blun"),
            .poison_count = it.list.get(326, 0),
            .indestructible_fallback = it.hasDurability() and it.full(73) == 0,
        };
    }
};

/// D2ApplyPercent 0x00483360 for the item-sized values a tooltip sees: `v * p / 100`, truncated.
fn applyPercent(v: i32, p: i32) i32 {
    return @intCast(@divTrunc(@as(i64, v) * p, 100));
}

const AnimRecord = struct { frames: u32, speed: u32, found: bool = true };

/// ANIMDATA_GetFramesSpeedAndTrigger 0x0066aa80: 256 buckets keyed by the byte sum of the upper-case
/// name, each a u32 count and 160-byte records (name[8], frames per direction, speed, events).
fn animRecord(bytes: []const u8, name: []const u8) ?AnimRecord {
    var key: [8]u8 = @splat(0);
    var sum: u32 = 0;
    for (name, 0..) |ch, i| {
        if (i >= 8) break;
        key[i] = std.ascii.toUpper(ch);
        sum +%= key[i];
    }
    const bucket = sum & 0xff;
    var pos: usize = 0;
    var b: u32 = 0;
    while (b < 256) : (b += 1) {
        if (pos + 4 > bytes.len) return null;
        const count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (b == bucket) {
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                const at = pos + @as(usize, k) * 160;
                if (at + 16 > bytes.len) return null;
                if (std.mem.eql(u8, bytes[at..][0..8], &key)) return .{
                    .frames = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little),
                    .speed = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little),
                };
            }
            return null;
        }
        pos += @as(usize, count) * 160;
    }
    return null;
}

// -------------------------------------------------------------------------------------------------
// text helpers

/// AppendAsWideChar 0x004521c0 then append: a non-empty block gets `ÿc` and its colour digit in front.
fn block_(out: *Text, text: []const u8, color: u8) !void {
    if (text.len == 0) return;
    try out.s(color_code);
    try out.buf.append(out.gpa, '0' + color);
    try out.s(text);
}

fn numberLine(out: *Text, label: []const u8, sp: []const u8, v: i64, nl: []const u8) !void {
    try out.s(label);
    try out.s(sp);
    try out.int(v);
    try out.s(nl);
}

/// SKILLDESC_AppendStatBuffText 0x004e6410 with a prefix: the label goes in front of the last line of the
/// stats (the top one on screen), which then ends in a comma when there are lines below it.
fn prefixed(out: *Text, stats: []const u8, label: []const u8, nl: []const u8, comma: []const u8) !void {
    if (stats.len == 0) return;
    if (stats.len >= 3) {
        var n: usize = stats.len - 2;
        while (n > 0 and stats[n] != '\n') n -= 1;
        if (n > 0) {
            try out.s(stats[0..n]);
            try out.s(nl);
            try out.s(label);
            var tail = stats[n + 1 ..];
            if (tail.len != 0 and tail[tail.len - 1] == '\n') tail = tail[0 .. tail.len - 1];
            try out.s(tail);
            try out.s(comma);
            try out.s(nl);
            return;
        }
    }
    try out.s(label);
    try out.s(stats);
}

/// The game's `%0 %1 %2` name templates (D2Lang): positional arguments, the blanks of an empty argument
/// kept as the template has them.
fn positionalFormat(out: *Text, tmpl: []const u8, args: []const []const u8) !void {
    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] == '%' and i + 1 < tmpl.len and tmpl[i + 1] >= '0' and tmpl[i + 1] <= '9') {
            const n = tmpl[i + 1] - '0';
            i += 1;
            if (n < args.len) try out.s(args[n]);
        } else try out.buf.append(out.gpa, tmpl[i]);
    }
}

/// UNICODE_FormatPossessiveName 0x005272b0, English: the name, then `'s ` (only `' ` after a name ending
/// in a lower-case s), then the text.
fn possessive(out: *Text, owner: []const u8, what: []const u8) !void {
    try out.s(owner);
    try out.s(if (owner.len != 0 and owner[owner.len - 1] == 's') "' " else "'s ");
    try out.s(what);
}

fn contains(list: []const u16, v: u16) bool {
    for (list) |x| if (x == v) return true;
    return false;
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

/// Consecutive save-format item records (each starts with `JM`, byte aligned), up to `max`.
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

// -------------------------------------------------------------------------------------------------
// tests

const testing = std.testing;

const Fixture = struct {
    t: tables.Tables,
    s: strings.Strings,
    d: Describer,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) !void {
        f.t = try tables.Tables.load(testing.allocator);
        f.s = try strings.Strings.load(testing.allocator);
        f.d = try Describer.init(testing.allocator, &f.t, &f.s);
        f.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.d.deinit();
        f.s.deinit();
        f.t.deinit();
    }
    fn text(f: *Fixture, it: *const wire.Item, kids: []const wire.Item, opts: Options) ![]const u8 {
        const a = f.arena.allocator();
        return plain(a, try f.d.describe(a, it, kids, opts));
    }
};

fn record(code: []const u8, quality: wire.Quality) wire.Item {
    var it = wire.Item{ .flags = wire.flag.IDENTIFIED, .version = 0x65, .ilvl = 80, .quality = quality };
    @memcpy(it.code[0..code.len], code);
    it.code_len = @intCast(code.len);
    it.n_stats = 0;
    return it;
}

fn addStat(it: *wire.Item, id: u16, param: u32, value: i32, list: u8) void {
    it.stats[it.n_stats] = .{ .id = id, .param = param, .value = value, .list = list };
    it.n_stats += 1;
}

test "a plain weapon: name, damage, durability, requirements, in the engine's order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("ssd", .normal); // Short Sword: 2-7, durability 24, no str/dex requirement
    addStat(&it, 73, 0, 24, wire.list_base);
    addStat(&it, 72, 0, 20, wire.list_base);
    try testing.expectEqualStrings("Short Sword\nOne-Hand Damage: 2 to 7\nDurability: 20 of 24", try f.text(&it, &.{}, .{}));
}

test "enhanced damage turns the damage blue and raises it by percent of the base" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("ssd", .magic);
    it.prefix = 0;
    addStat(&it, 73, 0, 24, wire.list_base);
    addStat(&it, 72, 0, 24, wire.list_base);
    addStat(&it, 17, 0, 100, 0);
    addStat(&it, 18, 0, 100, 0);
    const a = f.arena.allocator();
    const d = try f.d.describe(a, &it, &.{}, .{});
    const ls = try lines(a, d);
    // a magic name with neither affix keeps the blanks of "%0 %1 %2": GetItemName substitutes, it does not trim
    try testing.expectEqualStrings(" Short Sword ", ls[0].spans[0].text);
    try testing.expectEqual(@as(u8, 3), ls[0].spans[0].color);
    // "One-Hand Damage: " white, "4 to 14" blue
    try testing.expectEqualStrings("One-Hand Damage: ", ls[1].spans[0].text);
    try testing.expectEqual(@as(u8, 0), ls[1].spans[0].color);
    try testing.expectEqualStrings("4 to 14", ls[1].spans[1].text);
    try testing.expectEqual(@as(u8, 3), ls[1].spans[1].color);
    try testing.expectEqualStrings("+100% Enhanced Damage", ls[ls.len - 1].spans[0].text);
}

test "ethereal armor: defense from the record, requirement minus 10, the ethereal line at the bottom" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("utp", .normal); // Archon Plate: str 103
    it.flags |= wire.flag.ETHEREAL | wire.flag.SOCKETED;
    it.sockets = 3;
    addStat(&it, 31, 0, 1000, wire.list_base);
    addStat(&it, 73, 0, 31, wire.list_base);
    addStat(&it, 72, 0, 31, wire.list_base);
    try testing.expectEqualStrings("Archon Plate\nDefense: 1000\nDurability: 31 of 31\nRequired Strength: 93\nRequired Level: 63\nEthereal (Cannot be Repaired), Socketed (3)", try f.text(&it, &.{}, .{}));
}

test "the unidentified card shows the base name and Unidentified in red" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("rin", .unique);
    it.flags = 0;
    const a = f.arena.allocator();
    const d = try f.d.describe(a, &it, &.{}, .{});
    try testing.expectEqualStrings("Ring\nUnidentified", try plain(a, d));
    const ls = try lines(a, d);
    try testing.expectEqual(@as(u8, 4), ls[0].spans[0].color);
    try testing.expectEqual(@as(u8, 1), ls[1].spans[0].color);
}

test "a low quality weapon: its name from LowQualityItems and three quarters of the txt damage" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("ssd", .low);
    it.file_index = 0;
    addStat(&it, 73, 0, 24, wire.list_base);
    addStat(&it, 72, 0, 24, wire.list_base);
    try testing.expectEqualStrings("Crude Short Sword\nOne-Hand Damage: 1 to 5\nDurability: 24 of 24", try f.text(&it, &.{}, .{}));
}

test "a personalised name ending in s takes only an apostrophe" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var it = record("ssd", .superior);
    it.flags |= wire.flag.PLAYERNAME;
    @memcpy(it.owner[0..4], "Jens");
    const a = f.arena.allocator();
    const ls = try lines(a, try f.d.describe(a, &it, &.{}, .{}));
    try testing.expectEqualStrings("Jens' Superior Short Sword", ls[0].spans[0].text);
}
