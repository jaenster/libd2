//! The items of a character kit: one line of text in, the save-form record of the item (with the records of what
//! is socketed in it) out.
//!
//!   kind:name;option;option=value;...
//!
//! kinds: `unique:<UniqueItems index>`, `set:<SetItems index>`, `rare:<base code>`, `magic:<base code>`,
//! `base:<base code>` (a Normal weapon or armour, the base of a runeword) and `item:<code>` (a rune, gem, key, tome,
//! the Horadric Cube ...). Names may hold spaces and apostrophes.
//!
//! options:
//!   eth                 ethereal: the engine's own rule (ITEMMOD_ApplyEtherealBonus, ITEM_ApplyEthereal): defense x3/2,
//!                       maximum durability halved plus one; a weapon's damage follows from the flag when it is loaded
//!   upgrade=exceptional|elite   a unique put through the cube: the same item on the next tier of its OWN base line, read from
//!                       Armor.txt / Weapons.txt (a Normal base goes to its ubercode, an Exceptional one to its ultracode).
//!                       The quality and the mods stay. Set items cannot be upgraded in the cube, so this refuses them
//!   sockets=N           N sockets (a Larzuk socket: limited by the base's own sockets and its item level band)
//!   fill=<code>,...     what sits in them: a gem or a rune per socket
//!   runeword=<name>     a runeword (Runes.txt `Rune Name`) on a `base:` item: sockets and runes follow from the table
//!   class=<name>        for the Hellfire Torch: the class its skill bonus is for
//!   prefix=<name>,...   explicit affixes of a magic or rare item (the table's `Name`, its text, or `#row`)
//!   suffix=<name>,...
//!   variant=N           the inventory picture of a ring, amulet, charm or jewel
//!   ilvl=N              the item level (99)
//!   automod=<Name>      on a `base:` item, the AutoMagic.txt row of that name (`Chromatic`: all resistances 35-45), at its best
//!   qty=N               a stack's size (a tome holds 20 scrolls)
//!   nomax               roll the values like a drop does instead of taking every one at its best
//!
//! Every value is at its best unless `nomax`: a property at the top of its range, the base defense at the top of the
//! base's range, durability full. The tables are libd2's stock 1.14d ones.
const std = @import("std");
const core = @import("d2-core");
const item = @import("d2-item");
const d2data = @import("d2-data");
const record = @import("itemwrite.zig");

const wire = core.wire;
const rng = item.rng;

pub const Scope = enum {
    classic,
    expansion,

    pub fn isExpansion(s: Scope) bool {
        return s == .expansion;
    }
};

pub const Error = error{
    BadSpec,
    UnknownItem,
    NotInScope,
    /// an upgrade the cube cannot do: a set item, or a base with no tier above it
    NotUpgradable,
    BadSockets,
    BadRuneword,
    BadAffix,
    NoTable,
    /// an item the generation code can never make (see `validate`)
    Impossible,
    NoRoll,
    Unsupported,
    OutOfMemory,
    TooLong,
};

/// Where the record says the item is: stored in a grid (`dest` 0, `page_raw` the page plus one, `x` and `y` the cell),
/// worn (`dest` 1 and the body location) or in the belt (`dest` 2).
pub const Place = struct {
    dest: u8 = 0,
    body_loc: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    page_raw: u8 = page_raw_stash,
};

/// The flags of a stored, identified item as the game's own saves carry them, and of a simple one.
pub const flags_identified: u32 = 0x00800010;
pub const flags_simple: u32 = 0x00a00010;
/// The item version the game writes (1.14d).
pub const item_version: u16 = 101;
/// The item page of a shared stash page's items, as the record keeps it (page + 1).
pub const page_raw_stash: u8 = 5;
pub const page_raw_inventory: u8 = 1;

pub const Made = struct {
    /// The save-form record of the item, then the records of what is socketed in it. Owned.
    rec: []u8,
    /// How many item records `rec` holds: the item and what sits in it. A save's item list counts them all.
    n_records: u16,
    w: u8,
    h: u8,
    /// What it is, for a person reading a plan.
    label: []u8,

    pub fn deinit(m: *Made, gpa: std.mem.Allocator) void {
        gpa.free(m.rec);
        gpa.free(m.label);
    }
};

const Kind = enum { unique, set, rare, magic, base, plain };

const Upgrade = enum { none, exceptional, elite };

const Kit = struct {
    kind: Kind,
    name: []const u8,
    eth: bool = false,
    upgrade: Upgrade = .none,
    sockets: u8 = 0,
    fill: []const u8 = "",
    runeword: []const u8 = "",
    nomax: bool = false,
    variant: ?u8 = null,
    ilvl: ?u8 = null,
    class: ?u8 = null,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    qty: ?u16 = null,
    automod: []const u8 = "",
};

pub const class_names = [_][]const u8{ "amazon", "sorceress", "necromancer", "paladin", "barbarian", "druid", "assassin" };

fn parseKit(line: []const u8) Error!Kit {
    var parts = std.mem.splitScalar(u8, line, ';');
    const head = std.mem.trim(u8, parts.next() orelse return error.BadSpec, " ");
    const colon = std.mem.indexOfScalar(u8, head, ':') orelse return error.BadSpec;
    const kind_text = head[0..colon];
    const kind: Kind = if (std.mem.eql(u8, kind_text, "unique")) .unique else if (std.mem.eql(u8, kind_text, "set")) .set else if (std.mem.eql(u8, kind_text, "rare")) .rare else if (std.mem.eql(u8, kind_text, "magic")) .magic else if (std.mem.eql(u8, kind_text, "base")) .base else if (std.mem.eql(u8, kind_text, "item")) .plain else return error.BadSpec;
    var k = Kit{ .kind = kind, .name = std.mem.trim(u8, head[colon + 1 ..], " ") };
    if (k.name.len == 0) return error.BadSpec;
    while (parts.next()) |raw| {
        const opt = std.mem.trim(u8, raw, " ");
        if (opt.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, opt, '=');
        const key = if (eq) |e| opt[0..e] else opt;
        const val = if (eq) |e| opt[e + 1 ..] else "";
        if (std.mem.eql(u8, key, "eth")) {
            k.eth = true;
        } else if (std.mem.eql(u8, key, "nomax")) {
            k.nomax = true;
        } else if (std.mem.eql(u8, key, "upgrade")) {
            k.upgrade = if (std.mem.eql(u8, val, "exceptional")) .exceptional else if (std.mem.eql(u8, val, "elite")) .elite else return error.BadSpec;
        } else if (std.mem.eql(u8, key, "sockets")) {
            k.sockets = std.fmt.parseInt(u8, val, 10) catch return error.BadSpec;
            if (k.sockets == 0 or k.sockets > 6) return error.BadSpec;
        } else if (std.mem.eql(u8, key, "fill")) {
            k.fill = val;
        } else if (std.mem.eql(u8, key, "runeword")) {
            k.runeword = val;
        } else if (std.mem.eql(u8, key, "class")) {
            for (class_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, val)) {
                k.class = @intCast(i);
            };
            if (k.class == null) return error.BadSpec;
        } else if (std.mem.eql(u8, key, "prefix")) {
            k.prefix = val;
        } else if (std.mem.eql(u8, key, "suffix")) {
            k.suffix = val;
        } else if (std.mem.eql(u8, key, "variant")) {
            k.variant = std.fmt.parseInt(u8, val, 10) catch return error.BadSpec;
        } else if (std.mem.eql(u8, key, "ilvl")) {
            k.ilvl = std.fmt.parseInt(u8, val, 10) catch return error.BadSpec;
            if (k.ilvl.? == 0 or k.ilvl.? > 99) return error.BadSpec;
        } else if (std.mem.eql(u8, key, "automod")) {
            k.automod = val;
        } else if (std.mem.eql(u8, key, "qty")) {
            k.qty = std.fmt.parseInt(u16, val, 10) catch return error.BadSpec;
        } else return error.BadSpec;
    }
    if (k.automod.len != 0 and k.kind != .base) return error.BadSpec;
    if (k.runeword.len != 0 and k.kind != .base) return error.BadSpec;
    if (k.upgrade != .none and k.kind != .unique and k.kind != .set) return error.BadSpec;
    if ((k.prefix.len != 0 or k.suffix.len != 0) and k.kind != .rare and k.kind != .magic) return error.BadSpec;
    if (k.fill.len != 0 and k.sockets == 0 and k.runeword.len == 0) return error.BadSpec;
    return k;
}

pub const Maker = struct {
    gpa: std.mem.Allocator,
    t: item.Tables,
    scope: Scope,
    seed: rng.Seed,
    unique_rows: []usize,
    set_rows: []usize,
    prefix_rows: []usize,
    suffix_rows: []usize,
    rare_prefix_rows: []usize,
    rare_suffix_rows: []usize,
    /// The seeds already given out, so no two items of a run share one.
    used: std.ArrayList(u32) = .empty,
    /// The item version a made item is saved with.
    version: u16 = item_version,
    /// Where the next item is put.
    place: Place = .{},

    pub fn init(gpa: std.mem.Allocator, scope: Scope, seed: u32) !Maker {
        var t = try item.Tables.load(gpa);
        errdefer t.deinit();
        var m: Maker = .{
            .gpa = gpa,
            .t = t,
            .scope = scope,
            .seed = rng.Seed.init(seed, 0x29a),
            .unique_rows = &.{},
            .set_rows = &.{},
            .prefix_rows = &.{},
            .suffix_rows = &.{},
            .rare_prefix_rows = &.{},
            .rare_suffix_rows = &.{},
        };
        errdefer m.deinit();
        m.unique_rows = try compact(gpa, &m.t.unique_items);
        m.set_rows = try compact(gpa, &m.t.set_items);
        m.prefix_rows = try compact(gpa, &m.t.magic_prefix);
        m.suffix_rows = try compact(gpa, &m.t.magic_suffix);
        m.rare_prefix_rows = try compact(gpa, &m.t.rare_prefix);
        m.rare_suffix_rows = try compact(gpa, &m.t.rare_suffix);
        return m;
    }

    pub fn deinit(m: *Maker) void {
        m.gpa.free(m.unique_rows);
        m.gpa.free(m.set_rows);
        m.gpa.free(m.prefix_rows);
        m.gpa.free(m.suffix_rows);
        m.gpa.free(m.rare_prefix_rows);
        m.gpa.free(m.rare_suffix_rows);
        m.used.deinit(m.gpa);
        m.t.deinit();
    }

    /// The item a kit line names, made.
    pub fn makeKit(m: *Maker, line: []const u8) Error!Made {
        const k = try parseKit(line);
        return switch (k.kind) {
            .unique => m.kitUnique(k),
            .set => m.kitSet(k),
            .rare, .magic => m.kitAffixed(k),
            .base => m.kitBase(k),
            .plain => m.kitPlain(k),
        };
    }

    // ---- the kinds ------------------------------------------------------------------------------------------

    fn kitUnique(m: *Maker, k: Kit) Error!Made {
        const row = m.uniqueRow(k.name) orelse return error.UnknownItem;
        const ut = &m.t.unique_items;
        if (!m.scope.isExpansion() and ut.int(row, "version") >= 100) return error.NotInScope;
        const own = ut.str(row, "code");
        const code = try m.upgraded(own, k.upgrade);
        try m.checkBase(code, own, k.upgrade != .none);
        const ilvl = m.ilvlOf(k, @intCast(ut.int(row, "lvl")));
        var b = try m.begin(code, .unique, ilvl, k);
        defer b.deinit(m.gpa);
        b.it.unique_id = @intCast(compactIndex(m.unique_rows, row) orelse return error.Unsupported);
        const ctx = item.properties.PropContext{ .code = code, .item_level = ilvl, .is_expansion = m.scope.isExpansion() };
        var list: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
        defer list.deinit(m.gpa);
        try m.tableProps(&list, ut, row, "prop", "par", "min", "max", 12, ctx, k);
        try m.pushRolled(&b.it, list.items, 0, k);
        try m.baseStats(&b.it, code, k);
        try m.sockets(&b, k, null);
        return m.finish(&b, ut.str(row, "index"));
    }

    fn kitSet(m: *Maker, k: Kit) Error!Made {
        const st = &m.t.set_items;
        var row: usize = st.rowCount();
        for (0..st.rowCount()) |r| {
            if (std.ascii.eqlIgnoreCase(st.str(r, "index"), k.name)) {
                row = r;
                break;
            }
        }
        if (row == st.rowCount()) return error.UnknownItem;
        const own = st.str(row, "item");
        if (k.upgrade != .none) return error.NotUpgradable; // no cube recipe takes a set item
        const code = own;
        try m.checkBase(code, own, false);
        const ilvl = m.ilvlOf(k, @intCast(st.int(row, "lvl")));
        var b = try m.begin(code, .set, ilvl, k);
        defer b.deinit(m.gpa);
        b.it.set_id = @intCast(compactIndex(m.set_rows, row) orelse return error.Unsupported);
        const ctx = item.properties.PropContext{ .code = code, .item_level = ilvl, .is_expansion = m.scope.isExpansion() };
        var list: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
        defer list.deinit(m.gpa);
        // the item's own properties: nine slots, two on a Classic item
        try m.tableProps(&list, st, row, "prop", "par", "min", "max", if (m.scope.isExpansion()) 9 else 2, ctx, k);
        try m.pushRolled(&b.it, list.items, 0, k);
        // the partial bonuses the item carries, one list for each tier that has any (Expansion only)
        if (m.scope.isExpansion()) {
            var tier: u8 = 1;
            while (tier <= 5) : (tier += 1) {
                var tl: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
                defer tl.deinit(m.gpa);
                for ([2]u8{ 'a', 'b' }) |half| {
                    var cb: [12]u8 = undefined;
                    var pb: [12]u8 = undefined;
                    var lb: [12]u8 = undefined;
                    var hb: [12]u8 = undefined;
                    const prop = st.str(row, std.fmt.bufPrint(&cb, "aprop{d}{c}", .{ tier, half }) catch unreachable);
                    if (prop.len == 0) continue;
                    const par: i32 = m.paramOf(st, row, std.fmt.bufPrint(&pb, "apar{d}{c}", .{ tier, half }) catch unreachable);
                    const lo: i32 = @intCast(st.int(row, std.fmt.bufPrint(&lb, "amin{d}{c}", .{ tier, half }) catch unreachable));
                    const hi: i32 = @intCast(st.int(row, std.fmt.bufPrint(&hb, "amax{d}{c}", .{ tier, half }) catch unreachable));
                    try m.applyProp(&tl, prop, par, lo, hi, ctx, k);
                }
                try m.pushRolled(&b.it, tl.items, tier, k);
            }
        }
        try m.baseStats(&b.it, code, k);
        try m.sockets(&b, k, null);
        return m.finish(&b, st.str(row, "index"));
    }

    /// A magic or rare item with the affixes named: a rare takes up to three prefixes and three suffixes, a magic item
    /// one of each.
    fn kitAffixed(m: *Maker, k: Kit) Error!Made {
        const code = k.name;
        const ref = m.t.itemRef(code) orelse return error.UnknownItem;
        if (!m.scope.isExpansion() and m.t.itemTable(ref.table).int(ref.row, "version") >= 100) return error.NotInScope;
        const rare = k.kind == .rare;
        const ilvl = m.ilvlOf(k, 1);
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return error.OutOfMemory;
        defer types.deinit(m.gpa);

        var pre: [3]u16 = .{ 0, 0, 0 };
        var suf: [3]u16 = .{ 0, 0, 0 };
        const np = try m.affixRows(&m.t.magic_prefix, k.prefix, &types, ilvl, rare, &pre);
        const ns = try m.affixRows(&m.t.magic_suffix, k.suffix, &types, ilvl, rare, &suf);
        if (np + ns == 0) return error.BadAffix;
        if (!rare and (np > 1 or ns > 1)) return error.BadAffix;

        var b = try m.begin(code, if (rare) .rare else .magic, ilvl, k);
        defer b.deinit(m.gpa);
        const ctx = item.properties.PropContext{ .code = code, .item_level = ilvl, .is_expansion = m.scope.isExpansion() };
        var list: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
        defer list.deinit(m.gpa);
        for (pre[0..np]) |row1| try m.affixProps(&list, &m.t.magic_prefix, row1 - 1, ctx, k);
        for (suf[0..ns]) |row1| try m.affixProps(&list, &m.t.magic_suffix, row1 - 1, ctx, k);
        if (rare) {
            for (pre[0..np], 0..) |row1, i| b.it.rare_prefixes[i] = @intCast((compactIndex(m.prefix_rows, row1 - 1) orelse return error.Unsupported) + 1);
            for (suf[0..ns], 0..) |row1, i| b.it.rare_suffixes[i] = @intCast((compactIndex(m.suffix_rows, row1 - 1) orelse return error.Unsupported) + 1);
            // the name: a prefix word and a suffix word of the rare tables that fit the base
            const pw = try m.rareWord(&m.t.rare_prefix, m.rare_prefix_rows, &types);
            const sw = try m.rareWord(&m.t.rare_suffix, m.rare_suffix_rows, &types);
            b.it.rare_name1 = @intCast(m.rare_suffix_rows.len + pw + 1);
            b.it.rare_name2 = @intCast(sw + 1);
        } else {
            if (np > 0) b.it.prefix = @intCast((compactIndex(m.prefix_rows, pre[0] - 1) orelse return error.Unsupported) + 1);
            if (ns > 0) b.it.suffix = @intCast((compactIndex(m.suffix_rows, suf[0] - 1) orelse return error.Unsupported) + 1);
        }
        try m.pushRolled(&b.it, list.items, 0, k);
        try m.baseStats(&b.it, code, k);
        try m.sockets(&b, k, null);
        return m.finish(&b, "");
    }

    /// A Normal weapon or armour, with sockets and what is in them, or a runeword.
    fn kitBase(m: *Maker, k: Kit) Error!Made {
        const code = k.name;
        const ref = m.t.itemRef(code) orelse return error.UnknownItem;
        if (ref.table == .misc) return error.Unsupported;
        if (!m.scope.isExpansion() and m.t.itemTable(ref.table).int(ref.row, "version") >= 100) return error.NotInScope;
        const ilvl = m.ilvlOf(k, 1);
        var b = try m.begin(code, .normal, ilvl, k);
        defer b.deinit(m.gpa);
        try m.baseStats(&b.it, code, k);
        if (k.automod.len != 0) try m.automod(&b.it, code, ilvl, k);
        var rw: ?Runeword = null;
        if (k.runeword.len != 0) rw = try m.runeword(code, k.runeword);
        if (rw) |r| {
            b.it.flags |= wire.flag.RUNEWORD;
            b.it.runeword_id = r.id;
            const ctx = item.properties.PropContext{ .code = code, .item_level = ilvl, .is_expansion = m.scope.isExpansion() };
            var list: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
            defer list.deinit(m.gpa);
            try m.tableProps(&list, &m.t.runes, r.row, "T1Code", "T1Param", "T1Min", "T1Max", 7, ctx, k);
            try m.pushRolled(&b.it, list.items, wire.list_runeword, k);
        }
        try m.sockets(&b, k, rw);
        return m.finish(&b, if (rw) |r| m.t.runes.str(r.row, "Rune Name") else "");
    }

    /// A simple item (a rune, a gem), or a Normal one that is not saved compact (a tome, a key, the Cube).
    fn kitPlain(m: *Maker, k: Kit) Error!Made {
        const code = k.name;
        const ref = m.t.itemRef(code) orelse return error.UnknownItem;
        const tbl = m.t.itemTable(ref.table);
        if (!m.scope.isExpansion() and tbl.int(ref.row, "version") >= 100) return error.NotInScope;
        const types = core.itemtypes.lookup(code) orelse return error.UnknownItem;
        if (ref.table != .misc) return error.Unsupported;
        if (tbl.int(ref.row, "compactsave") != 0) {
            var it = wire.Item{ .flags = flags_simple, .version = m.version };
            m.setPlace(&it);
            setCode(&it, code);
            it.compact = true;
            var b = Build{ .it = it };
            defer b.deinit(m.gpa);
            return m.finishWith(&b, .{ .seed = 0 }, code, "");
        }
        const ilvl = m.ilvlOf(k, 1);
        var b = try m.begin(code, .normal, ilvl, k);
        defer b.deinit(m.gpa);
        var ex = record.Extra{ .seed = b.seed };
        if (types.stackable) {
            const max: u16 = @intCast(tbl.int(ref.row, "maxstack"));
            ex.quantity = k.qty orelse (if (max != 0) max else 1);
            if (ex.quantity > max and max != 0) return error.BadSpec;
        }
        if (std.mem.eql(u8, code, "ibk")) ex.book = 1;
        return m.finishWith(&b, ex, code, "");
    }

    // ---- building blocks ------------------------------------------------------------------------------------

    const Build = struct {
        it: wire.Item,
        seed: u32 = 0,
        kids: std.ArrayListUnmanaged([]u8) = .empty,

        fn deinit(b: *Build, gpa: std.mem.Allocator) void {
            for (b.kids.items) |kid| gpa.free(kid);
            b.kids.deinit(gpa);
        }
    };

    fn setPlace(m: *Maker, it: *wire.Item) void {
        it.dest = m.place.dest;
        it.body_loc = m.place.body_loc;
        it.x = m.place.x;
        it.y = m.place.y;
        it.page_raw = m.place.page_raw;
    }

    /// An identified item of `code` and quality at `ilvl`, with its own seed, the place and the ethereal flag.
    fn begin(m: *Maker, code: []const u8, quality: wire.Quality, ilvl: u8, k: Kit) Error!Build {
        var it = wire.Item{ .flags = flags_identified, .version = m.version, .ilvl = ilvl, .quality = quality };
        m.setPlace(&it);
        setCode(&it, code);
        if (k.eth) {
            if (!m.hasDurability(code)) return error.Unsupported;
            it.flags |= wire.flag.ETHEREAL;
        }
        // a ring, an amulet, a charm and a jewel have several pictures
        if (m.varGfx(code)) |n| {
            it.has_variant = true;
            it.variant = if (k.variant) |v| (if (v >= n) return error.BadSpec else v) else @intCast(m.nextSeeds().unit.low % n);
        } else if (k.variant != null) return error.BadSpec;
        const seeds = m.nextSeeds();
        return .{ .it = it, .seed = seeds.unit.low };
    }

    fn varGfx(m: *Maker, code: []const u8) ?u8 {
        const ref = m.t.itemRef(code) orelse return null;
        const tbl = m.t.itemTable(ref.table);
        const row = m.t.itypeRow(tbl.str(ref.row, "type")) orelse return null;
        const n = m.t.item_types.int(row, "VarInvGfx");
        return if (n > 0) @intCast(n) else null;
    }

    fn hasDurability(m: *Maker, code: []const u8) bool {
        const ref = m.t.itemRef(code) orelse return false;
        if (ref.table == .misc) return false;
        const tbl = m.t.itemTable(ref.table);
        return tbl.int(ref.row, "nodurability") == 0 and tbl.int(ref.row, "durability") > 0;
    }

    fn ilvlOf(m: *Maker, k: Kit, row_level: u8) u8 {
        _ = m;
        return k.ilvl orelse @max(99, row_level);
    }

    /// `own` is the row's base; a replacement must be a base of the same kind (the cube keeps the item's type).
    /// The base a cube upgrade puts a unique on: the next tier of the unique's own base line, from the Armor.txt /
    /// Weapons.txt columns normcode, ubercode and ultracode. Exceptional takes a Normal base to its ubercode, Elite takes
    /// an Exceptional base to its ultracode; a base already at the top, or in the wrong tier, cannot be upgraded.
    fn upgraded(m: *Maker, own: []const u8, up: Upgrade) Error![]const u8 {
        if (up == .none) return own;
        const ref = m.t.itemRef(own) orelse return error.UnknownItem;
        if (ref.table == .misc) return error.NotUpgradable;
        const tbl = m.t.itemTable(ref.table);
        const norm = tbl.str(ref.row, "normcode");
        const uber = tbl.str(ref.row, "ubercode");
        const ultra = tbl.str(ref.row, "ultracode");
        const to = switch (up) {
            .exceptional => if (std.mem.eql(u8, own, norm)) uber else return error.NotUpgradable,
            .elite => if (std.mem.eql(u8, own, uber) and !std.mem.eql(u8, own, ultra)) ultra else return error.NotUpgradable,
            .none => unreachable,
        };
        if (to.len == 0 or std.mem.eql(u8, to, own)) return error.NotUpgradable;
        return to;
    }

    fn checkBase(m: *Maker, code: []const u8, own: []const u8, replaced: bool) Error!void {
        const ref = m.t.itemRef(code) orelse return error.UnknownItem;
        if (!m.scope.isExpansion() and m.t.itemTable(ref.table).int(ref.row, "version") >= 100) return error.NotInScope;
        if (!replaced) return;
        const oref = m.t.itemRef(own) orelse return error.UnknownItem;
        const want = m.t.itemTable(oref.table).str(oref.row, "type");
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return error.OutOfMemory;
        defer types.deinit(m.gpa);
        if (!types.has(want)) return error.BadSpec;
    }

    /// Defense, maximum durability and durability: the base's own, at the best of the range, and what the engine does to
    /// an ethereal item.
    fn baseStats(m: *Maker, it: *wire.Item, code: []const u8, k: Kit) Error!void {
        const ref = m.t.itemRef(code) orelse return error.UnknownItem;
        const tbl = m.t.itemTable(ref.table);
        const eth = it.flags & wire.flag.ETHEREAL != 0;
        switch (ref.table) {
            .armor => {
                const lo: i32 = @intCast(tbl.int(ref.row, "minac"));
                const hi: i32 = @intCast(tbl.int(ref.row, "maxac"));
                var ac: i32 = hi;
                if (k.nomax and hi > lo) ac = lo + @as(i32, @intCast(m.seed.pick(@intCast(hi - lo + 1))));
                if (eth) ac = @divTrunc(ac * 3, 2);
                addStat(it, .{ .id = 31, .value = ac, .list = wire.list_base }) catch return error.TooLong;
                try m.durability(it, tbl, ref.row, eth);
            },
            .weapons => try m.durability(it, tbl, ref.row, eth),
            .misc => {},
        }
    }

    fn durability(m: *Maker, it: *wire.Item, tbl: *const item.txt.Table, row: usize, eth: bool) Error!void {
        _ = m;
        var dur: i32 = @intCast(tbl.int(row, "durability"));
        if (tbl.int(row, "nodurability") != 0 or dur <= 0) {
            addStat(it, .{ .id = 73, .value = 0, .list = wire.list_base }) catch return error.TooLong;
            return;
        }
        if (eth) dur = @divTrunc(dur, 2) + 1;
        addStat(it, .{ .id = 73, .value = dur, .list = wire.list_base }) catch return error.TooLong;
        addStat(it, .{ .id = 72, .value = dur, .list = wire.list_base }) catch return error.TooLong;
    }

    /// A property's parameter: a number, or the name of a skill (Venom, Oak Sage ...), which is its id.
    fn paramOf(m: *Maker, tbl: *const item.txt.Table, row: usize, col: []const u8) i32 {
        const s = tbl.str(row, col);
        if (s.len == 0) return 0;
        if (std.fmt.parseInt(i32, s, 10)) |v| return v else |_| {}
        if (m.t.skills.findByStr("skill", s)) |r| return @intCast(m.t.skills.int(r, "Id"));
        return 0;
    }

    /// A property whose roll is a range is taken at the top of it; one whose min and max mean something else (a
    /// charge count and a skill level, a chance, a random class) is applied as the table has it.
    fn isRanged(m: *Maker, code: []const u8) bool {
        const prow = m.t.properties.findByStr("code", code) orelse return false;
        return switch (m.t.properties.int(prow, "func1")) {
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 17, 21, 22, 24 => true,
            else => false,
        };
    }

    fn applyProp(m: *Maker, out: *std.ArrayListUnmanaged(item.properties.RolledStat), code: []const u8, par: i32, min: i32, max: i32, ctx: item.properties.PropContext, k: Kit) Error!void {
        var lo = min;
        var hi = max;
        if (!k.nomax and m.isRanged(code)) {
            const best = @max(min, max);
            lo = best;
            hi = best;
        }
        item.properties.applyProperty(m.gpa, out, &m.seed, &m.t, code, par, lo, hi, ctx) catch return error.OutOfMemory;
    }

    /// The `<prop>N`, `<par>N`, `<min>N`, `<max>N` slots of a table row. An empty property slot is skipped.
    fn tableProps(m: *Maker, out: *std.ArrayListUnmanaged(item.properties.RolledStat), tbl: *const item.txt.Table, row: usize, prop: []const u8, par: []const u8, min: []const u8, max: []const u8, slots: usize, ctx: item.properties.PropContext, k: Kit) Error!void {
        var n: usize = 1;
        while (n <= slots) : (n += 1) {
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            var b3: [16]u8 = undefined;
            var b4: [16]u8 = undefined;
            const code = tbl.str(row, std.fmt.bufPrint(&b1, "{s}{d}", .{ prop, n }) catch unreachable);
            if (code.len == 0) {
                // a runeword's list stops at the first empty slot
                if (std.mem.eql(u8, prop, "T1Code")) break;
                continue;
            }
            const p: i32 = m.paramOf(tbl, row, std.fmt.bufPrint(&b2, "{s}{d}", .{ par, n }) catch unreachable);
            const lo: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&b3, "{s}{d}", .{ min, n }) catch unreachable));
            const hi: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&b4, "{s}{d}", .{ max, n }) catch unreachable));
            try m.applyProp(out, code, p, lo, hi, ctx, k);
        }
    }

    /// The `mod1code..mod3` slots of an affix row; the walk stops at the first empty one.
    fn affixProps(m: *Maker, out: *std.ArrayListUnmanaged(item.properties.RolledStat), tbl: *const item.txt.Table, row: usize, ctx: item.properties.PropContext, k: Kit) Error!void {
        var n: usize = 1;
        while (n <= 3) : (n += 1) {
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            var b3: [16]u8 = undefined;
            var b4: [16]u8 = undefined;
            const code = tbl.str(row, std.fmt.bufPrint(&b1, "mod{d}code", .{n}) catch unreachable);
            if (code.len == 0) break;
            const p: i32 = m.paramOf(tbl, row, std.fmt.bufPrint(&b2, "mod{d}param", .{n}) catch unreachable);
            const lo: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&b3, "mod{d}min", .{n}) catch unreachable));
            const hi: i32 = @intCast(tbl.int(row, std.fmt.bufPrint(&b4, "mod{d}max", .{n}) catch unreachable));
            try m.applyProp(out, code, p, lo, hi, ctx, k);
        }
    }

    /// The automod of a base (AutoMagic.txt, picked by its `Name`, `Chromatic`): the item keeps the row's number and its
    /// properties, each at the top of its range. The row has to fit the base's types and the item level, as the engine's
    /// own pick of one does.
    fn automod(m: *Maker, it: *wire.Item, code: []const u8, ilvl: u8, k: Kit) Error!void {
        var t = d2data.load(m.gpa, "AutoMagic") catch return error.NoTable;
        defer t.deinit();
        var row: ?usize = null;
        for (0..t.rowCount()) |r| if (std.ascii.eqlIgnoreCase(t.get(r, "Name"), k.automod)) {
            row = r;
        };
        const r = row orelse return error.BadSpec;
        if (!m.scope.isExpansion() and (t.getInt(i32, r, "version") orelse 0) >= 100) return error.NotInScope;
        if ((t.getInt(i32, r, "level") orelse 0) > ilvl) return error.BadSpec;
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return error.OutOfMemory;
        defer types.deinit(m.gpa);
        var itypes: [7][]const u8 = undefined;
        var etypes: [4][]const u8 = undefined;
        var nb: [8]u8 = undefined;
        inline for (0..7) |i| itypes[i] = t.get(r, std.fmt.bufPrint(&nb, "itype{d}", .{i + 1}) catch unreachable);
        inline for (0..4) |i| etypes[i] = t.get(r, std.fmt.bufPrint(&nb, "etype{d}", .{i + 1}) catch unreachable);
        if (!item.itemtype.affixMatchesTypes(&types, &itypes, &etypes)) return error.BadSpec;
        const ctx = item.properties.PropContext{ .code = code, .item_level = ilvl, .is_expansion = m.scope.isExpansion() };
        var list: std.ArrayListUnmanaged(item.properties.RolledStat) = .empty;
        defer list.deinit(m.gpa);
        var n: usize = 1;
        while (n <= 3) : (n += 1) {
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            var b3: [16]u8 = undefined;
            var b4: [16]u8 = undefined;
            const mod = t.get(r, std.fmt.bufPrint(&b1, "mod{d}code", .{n}) catch unreachable);
            if (mod.len == 0) break;
            const par: i32 = t.getInt(i32, r, std.fmt.bufPrint(&b2, "mod{d}param", .{n}) catch unreachable) orelse 0;
            const lo: i32 = t.getInt(i32, r, std.fmt.bufPrint(&b3, "mod{d}min", .{n}) catch unreachable) orelse 0;
            const hi: i32 = t.getInt(i32, r, std.fmt.bufPrint(&b4, "mod{d}max", .{n}) catch unreachable) orelse 0;
            try m.applyProp(&list, mod, par, lo, hi, ctx, k);
        }
        it.automagic = @intCast(r + 1);
        try m.pushRolled(it, list.items, 0, k);
    }

    /// Put rolled stats on the item, in list `list` (0 its own, 1..5 a set tier, 6 the runeword's).
    fn pushRolled(m: *Maker, it: *wire.Item, rolled: []const item.properties.RolledStat, list: u8, k: Kit) Error!void {
        _ = m;
        for (rolled) |rs| {
            if (rs.stat < 0 or rs.stat >= 512) return error.Unsupported;
            const row = core.itemstatcost.get(@intCast(rs.stat)) orelse return error.Unsupported;
            var layer = rs.layer;
            var value = rs.value;
            // the Torch's class skill bonus is for the class asked for
            if (rs.stat == 83 and k.class != null) layer = k.class.?;
            // charges of a charged skill: the best is a full set of them
            if (rs.stat == 204 and !k.nomax) value = (value & ~@as(i32, 0xff)) | (value >> 8);
            addStat(it, .{ .id = @intCast(rs.stat), .value = value << @intCast(row.valshift), .param = @intCast(@as(u32, @bitCast(layer)) & 0xFFFF), .list = list }) catch return error.TooLong;
        }
    }

    // ---- sockets and what is in them ------------------------------------------------------------------------

    const Runeword = struct { row: usize, id: u16, runes: [6][]const u8, n: u8 };

    fn runeword(m: *Maker, code: []const u8, name: []const u8) Error!Runeword {
        const rt = &m.t.runes;
        var row: usize = rt.rowCount();
        for (0..rt.rowCount()) |r| {
            if (std.ascii.eqlIgnoreCase(rt.str(r, "Rune Name"), name) or std.ascii.eqlIgnoreCase(rt.str(r, "Name"), name)) {
                row = r;
                break;
            }
        }
        if (row == rt.rowCount()) return error.BadRuneword;
        var out = Runeword{ .row = row, .id = 0, .runes = undefined, .n = 0 };
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            var b: [8]u8 = undefined;
            const rune = rt.str(row, std.fmt.bufPrint(&b, "Rune{d}", .{i + 1}) catch unreachable);
            if (rune.len == 0) break;
            out.runes[i] = rune;
            out.n += 1;
        }
        if (out.n == 0) return error.BadRuneword;
        // the base must be one the runeword is made for, with that many sockets
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return error.OutOfMemory;
        defer types.deinit(m.gpa);
        const found = item.affix.detectRuneword(m.gpa, &m.t, &types, out.runes[0..out.n]) catch return error.OutOfMemory;
        if (found == null or found.? != row + 1) return error.BadRuneword;
        // the 16 bits are the string id of the runeword's name
        out.id = stringId(rt.str(row, "Name")) orelse return error.BadRuneword;
        return out;
    }

    /// Sockets, the items in them (a runeword's runes, or `fill`) and the socket flag.
    fn sockets(m: *Maker, b: *Build, k: Kit, rw: ?Runeword) Error!void {
        const code = b.it.codeSlice();
        var total: u8 = k.sockets;
        var fill: []const u8 = k.fill;
        var rune_buf: [6][]const u8 = undefined;
        var rune_n: usize = 0;
        if (rw) |r| {
            total = r.n;
            for (r.runes[0..r.n]) |rune| {
                rune_buf[rune_n] = rune;
                rune_n += 1;
            }
            fill = "";
        }
        if (total == 0) return;
        const ref = m.t.itemRef(code).?;
        const tbl = m.t.itemTable(ref.table);
        var cap: i32 = @min(item.sockets.maxSockForItem(&m.t, code, b.it.ilvl), @as(i32, @intCast(tbl.int(ref.row, "gemsockets"))));
        if (!m.scope.isExpansion()) cap = @min(cap, if (m.isHelm(code)) @as(i32, 2) else 3);
        if (total > cap) return error.BadSockets;
        b.it.flags |= wire.flag.SOCKETED;
        b.it.sockets = total;
        if (fill.len != 0) {
            var gi = std.mem.splitScalar(u8, fill, ',');
            while (gi.next()) |g| {
                if (rune_n >= rune_buf.len) return error.BadSockets;
                rune_buf[rune_n] = std.mem.trim(u8, g, " ");
                rune_n += 1;
            }
        }
        if (rune_n > total) return error.BadSockets;
        var idx: u16 = 0;
        for (rune_buf[0..rune_n]) |g| {
            const gref = m.t.itemRef(g) orelse return error.UnknownItem;
            if (!m.scope.isExpansion() and m.t.itemTable(gref.table).int(gref.row, "version") >= 100) return error.NotInScope;
            if (m.t.gems.findByStr("code", g) == null) return error.BadSockets;
            var kid = wire.Item{ .flags = flags_simple, .version = m.version, .dest = 6, .x = idx };
            setCode(&kid, g);
            var kb: [record.max_record]u8 = undefined;
            const kn = record.encode(&kb, &kid, .{ .seed = 0 }) catch return error.Unsupported;
            b.kids.append(m.gpa, m.gpa.dupe(u8, kb[0..kn]) catch return error.OutOfMemory) catch return error.OutOfMemory;
            idx += 1;
        }
        b.it.socketed_count = @intCast(idx);
    }

    fn isHelm(m: *Maker, code: []const u8) bool {
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return false;
        defer types.deinit(m.gpa);
        return types.has("helm");
    }

    // ---- affixes --------------------------------------------------------------------------------------------

    /// The 1-based rows of the affixes `names` (comma separated) of `tbl`, each checked against the base's types, the
    /// item level and (a rare) the table's rare column. Returns how many.
    fn affixRows(m: *Maker, tbl: *const item.txt.Table, names: []const u8, types: *const item.itemtype.TypeSet, ilvl: u8, rare: bool, out: *[3]u16) Error!usize {
        if (names.len == 0) return 0;
        var s = item.strings.Strings.load(m.gpa) catch return error.OutOfMemory;
        defer s.deinit();
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            if (n >= 3) return error.BadAffix;
            var row: usize = tbl.rowCount();
            if (name[0] == '#') {
                row = std.fmt.parseInt(usize, name[1..], 10) catch return error.BadAffix;
            } else {
                for (0..tbl.rowCount()) |r| {
                    const key = tbl.str(r, "Name");
                    if (key.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(key, name) or std.ascii.eqlIgnoreCase(s.get(key), name)) {
                        if (!m.affixFits(tbl, r, types, ilvl, rare)) continue;
                        // a name the table holds twice (a Classic row and an Expansion one): the later is the Expansion row
                        row = r;
                        if (!m.scope.isExpansion()) break;
                    }
                }
            }
            if (row >= tbl.rowCount()) return error.BadAffix;
            if (!m.affixFits(tbl, row, types, ilvl, rare)) return error.BadAffix;
            out[n] = @intCast(row + 1);
            n += 1;
        }
        return n;
    }

    fn affixFits(m: *Maker, tbl: *const item.txt.Table, row: usize, types: *const item.itemtype.TypeSet, ilvl: u8, rare: bool) bool {
        if (!m.scope.isExpansion() and tbl.int(row, "version") >= 100) return false;
        if (tbl.int(row, "level") > ilvl) return false;
        if (rare and tbl.int(row, "rare") == 0) return false;
        var itypes: [7][]const u8 = undefined;
        var etypes: [4][]const u8 = undefined;
        var nb: [8]u8 = undefined;
        inline for (0..7) |i| itypes[i] = tbl.str(row, std.fmt.bufPrint(&nb, "itype{d}", .{i + 1}) catch unreachable);
        inline for (0..4) |i| etypes[i] = tbl.str(row, std.fmt.bufPrint(&nb, "etype{d}", .{i + 1}) catch unreachable);
        return item.itemtype.affixMatchesTypes(types, &itypes, &etypes);
    }

    /// One row (an index into the compacted rare name table) that fits the base, picked off the seed.
    fn rareWord(m: *Maker, tbl: *const item.txt.Table, rows: []const usize, types: *const item.itemtype.TypeSet) Error!usize {
        var fit: std.ArrayList(usize) = .empty;
        defer fit.deinit(m.gpa);
        for (rows, 0..) |r, i| {
            var itypes: [7][]const u8 = undefined;
            var etypes: [4][]const u8 = undefined;
            var nb: [8]u8 = undefined;
            inline for (0..7) |j| itypes[j] = tbl.str(r, std.fmt.bufPrint(&nb, "itype{d}", .{j + 1}) catch unreachable);
            inline for (0..4) |j| etypes[j] = tbl.str(r, std.fmt.bufPrint(&nb, "etype{d}", .{j + 1}) catch unreachable);
            if (item.itemtype.affixMatchesTypes(types, &itypes, &etypes)) fit.append(m.gpa, i) catch return error.OutOfMemory;
        }
        if (fit.items.len == 0) return error.NoRoll;
        return fit.items[m.seed.pick(@intCast(fit.items.len))];
    }

    // ---- the end --------------------------------------------------------------------------------------------

    fn finish(m: *Maker, b: *Build, name: []const u8) Error!Made {
        var ex = record.Extra{ .seed = b.seed };
        const code = b.it.codeSlice();
        if (core.itemtypes.lookup(code)) |t| if (t.stackable) {
            ex.quantity = 1;
        };
        return m.finishWith(b, ex, code, name);
    }

    /// What the engine's generation rules out, checked on every made item. Ethereal (ITEMS_MakeEthereal, and the
    /// Ethereal property): only a weapon or armor that ITEMS_HasDurability, which is false for an item whose base has no
    /// durability or that carries the Indestructible stat among its own generation mods (Crown of Ages). A runeword's mods and what is socketed come after the ethereal base exists, so they never block it; never an Inferior or Set
    /// item, never a quest item.
    fn validate(m: *Maker, it: *const wire.Item, code: []const u8) Error!void {
        if (it.flags & wire.flag.ETHEREAL == 0) return;
        if (it.quality == .set) return error.Impossible;
        if (!m.hasDurability(code)) return error.Impossible;
        for (it.stats[0..it.n_stats]) |s| if (s.id == 152 and s.list == 0 and s.value > 0) return error.Impossible;
        var types = item.itemtype.typesForItem(m.gpa, &m.t, code) catch return error.OutOfMemory;
        defer types.deinit(m.gpa);
        if (types.has("ques")) return error.Impossible;
    }

    fn finishWith(m: *Maker, b: *Build, ex: record.Extra, code: []const u8, name: []const u8) Error!Made {
        try m.validate(&b.it, code);
        var buf: [record.max_record]u8 = undefined;
        const n = record.encode(&buf, &b.it, ex) catch |e| return switch (e) {
            error.Unsupported => error.Unsupported,
            error.TooLong => error.TooLong,
        };
        const dims = m.t.itemDims(code) orelse return error.UnknownItem;
        var total = n;
        for (b.kids.items) |kid| total += kid.len;
        const rec = m.gpa.alloc(u8, total) catch return error.OutOfMemory;
        errdefer m.gpa.free(rec);
        @memcpy(rec[0..n], buf[0..n]);
        var at = n;
        for (b.kids.items) |kid| {
            @memcpy(rec[at..][0..kid.len], kid);
            at += kid.len;
        }
        const label = labelOf(m.gpa, &b.it, code, name) catch return error.OutOfMemory;
        return .{ .rec = rec, .n_records = @intCast(1 + b.kids.items.len), .w = dims[0], .h = dims[1], .label = label };
    }

    fn uniqueRow(m: *Maker, name: []const u8) ?usize {
        const ut = &m.t.unique_items;
        for (0..ut.rowCount()) |r| {
            if (std.ascii.eqlIgnoreCase(ut.str(r, "index"), name)) return r;
        }
        return null;
    }

    fn nextSeeds(m: *Maker) item.item.ItemSeeds {
        while (true) {
            const s = item.item.createItemSeeds(&m.seed);
            if (std.mem.indexOfScalar(u32, m.used.items, s.unit.low) != null) continue;
            m.used.append(m.gpa, s.unit.low) catch {};
            return s;
        }
    }
};

/// The string id of a name key: the number the game keeps for it in its string tables, which is what a runeword's
/// 16 bits are. The patch table wins over the expansion table, which wins over the base table.
pub fn stringId(key: []const u8) ?u16 {
    if (idIn(d2data.strings.expansion, key)) |i| return i +% 20000;
    if (idIn(d2data.strings.patch, key)) |i| return i +% 10000;
    return idIn(d2data.strings.base, key);
}

fn idIn(bytes: []const u8, key: []const u8) ?u16 {
    if (bytes.len < 0x15) return null;
    const count = std.mem.readInt(u16, bytes[2..4], .little);
    const hash_size = std.mem.readInt(u32, bytes[4..8], .little);
    const first = 0x15 + @as(usize, count) * 2;
    var i: usize = 0;
    while (i < hash_size) : (i += 1) {
        const at = first + i * 17;
        if (at + 17 > bytes.len) return null;
        if (bytes[at] != 1) continue;
        const key_off = std.mem.readInt(u32, bytes[at + 7 ..][0..4], .little);
        if (key_off >= bytes.len) continue;
        const end = std.mem.indexOfScalarPos(u8, bytes, key_off, 0) orelse continue;
        if (!std.mem.eql(u8, bytes[key_off..end], key)) continue;
        return std.mem.readInt(u16, bytes[at + 1 ..][0..2], .little);
    }
    return null;
}

fn labelOf(gpa: std.mem.Allocator, it: *const wire.Item, code: []const u8, name: []const u8) ![]u8 {
    const q: []const u8 = switch (it.quality) {
        .unique => "unique",
        .set => "set",
        .rare => "rare",
        .magic => "magic",
        else => if (it.flags & wire.flag.RUNEWORD != 0) "runeword" else "plain",
    };
    // no spaces: the plan is read by words
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}:{s}", .{ q, code });
    if (name.len != 0) {
        try out.append(gpa, ':');
        for (name) |c| try out.append(gpa, if (c == ' ') '_' else c);
    }
    return out.toOwnedSlice(gpa);
}

fn addStat(it: *wire.Item, s: wire.Stat) !void {
    if (it.n_stats >= wire.MAX_STATS) return error.TooLong;
    it.stats[it.n_stats] = s;
    it.n_stats += 1;
}

fn setCode(it: *wire.Item, code: []const u8) void {
    it.code = .{ 0, 0, 0, 0 };
    @memcpy(it.code[0..code.len], code);
    it.code_len = @intCast(code.len);
}

/// The indices of a table's rows once the loader's `Expansion` separator rows are dropped: the ids the game
/// stores are positions in this list.
fn compact(gpa: std.mem.Allocator, t: *const item.txt.Table) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (t.rows, 0..) |r, i| {
        if (r.len != 0 and std.mem.eql(u8, r[0], "Expansion")) continue;
        try out.append(gpa, i);
    }
    return out.toOwnedSlice(gpa);
}

fn compactIndex(rows: []const usize, raw_row: usize) ?usize {
    return std.mem.indexOfScalar(usize, rows, raw_row);
}

test "the string id of a runeword's name is what the engine stores" {
    // the ids of the Enigma and Duress items of the seeded characters
    try std.testing.expectEqual(@as(?u16, 20539), stringId("Runeword33"));
    try std.testing.expectEqual(@as(?u16, 20536), stringId("Runeword30"));
}

// ---- tests ----------------------------------------------------------------------------------------

const testing = std.testing;
const itemtext = item.itemtext;
const sections = @import("sections.zig");

/// The records of a made item, parsed back, and its tooltip.
const Back = struct {
    arena: std.heap.ArenaAllocator,
    recs: []wire.Item,
    view: itemtext.ItemView,

    fn deinit(b: *Back) void {
        b.arena.deinit();
    }
};

fn back(d: *const itemtext.Describer, made: Made) !Back {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const recs = try itemtext.parseRecords(arena.allocator(), made.rec, 16);
    const v = try d.describe(arena.allocator(), &recs[0], recs[1..], .{});
    return .{ .arena = arena, .recs = recs, .view = v };
}

fn statOf(it: *const wire.Item, list: u8, id: u16) ?wire.Stat {
    for (it.stats[0..it.n_stats]) |s| if (s.id == id and s.list == list) return s;
    return null;
}

fn hasLine(v: itemtext.ItemView, needle: []const u8) bool {
    for (v.lines) |l| if (std.mem.indexOf(u8, l.text, needle) != null) return true;
    return false;
}

test "kit lines: the kinds, the options and what is refused" {
    const k = try parseKit("unique:Skin of the Flayerd One;upgrade=elite;eth;sockets=1;fill=r32");
    try testing.expectEqual(Kind.unique, k.kind);
    try testing.expectEqualStrings("Skin of the Flayerd One", k.name);
    try testing.expect(k.eth);
    try testing.expectEqual(Upgrade.elite, k.upgrade);
    try testing.expectEqual(@as(u8, 1), k.sockets);
    try testing.expectEqual(@as(u8, 3), (try parseKit("unique:Hellfire Torch;class=Paladin")).class.?);
    try testing.expectError(error.BadSpec, parseKit("unique"));
    try testing.expectError(error.BadSpec, parseKit("gizmo:abc"));
    try testing.expectError(error.BadSpec, parseKit("unique:Wisp;shiny"));
    try testing.expectError(error.BadSpec, parseKit("unique:Wisp;runeword=Enigma"));
    try testing.expectError(error.BadSpec, parseKit("rare:amu;upgrade=elite"));
    try testing.expectError(error.BadSpec, parseKit("unique:Wisp;fill=r30"));
    try testing.expectError(error.BadSpec, parseKit("unique:Wisp;sockets=7"));
}

test "Enigma: the runeword's own list is the one an engine save carries, at the best of every range" {
    var m = try Maker.init(testing.allocator, .expansion, 11);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var made = try m.makeKit("base:xtp;runeword=Enigma");
    defer made.deinit(testing.allocator);
    var b = try back(&d, made);
    defer b.deinit();

    try testing.expectEqual(@as(u16, 4), made.n_records);
    try testing.expectEqual(@as(usize, 4), b.recs.len);
    const it = b.recs[0];
    try testing.expect(it.flags & wire.flag.RUNEWORD != 0 and it.flags & wire.flag.SOCKETED != 0);
    try testing.expectEqual(@as(u8, 3), it.sockets);
    try testing.expectEqual(@as(u8, 3), it.socketed_count);
    try testing.expectEqual(@as(u16, 20539), it.runeword_id);
    try testing.expectEqualStrings("Enigma", b.view.name);
    // the runes: Jah Ith Ber, each its own record at its socket
    for ([_][]const u8{ "r31", "r06", "r30" }, 0..) |code, i| {
        try testing.expectEqualStrings(code, b.recs[1 + i].codeSlice());
        try testing.expectEqual(@as(u8, 6), b.recs[1 + i].dest);
        try testing.expectEqual(@as(u16, @intCast(i)), b.recs[1 + i].x);
    }

    // the list of an Enigma the engine wrote, stat for stat (its defense bonus is the top of 750-775)
    const sv = try sections.parse(@embedFile("testdata/seed/EpicSorc.d2s"));
    var di = sv.items.iterator();
    var donor: ?wire.Item = null;
    while (di.next()) |p| if (p.runeword_id == 20539) {
        donor = p;
    };
    const dn = donor.?;
    var seen: usize = 0;
    for (dn.stats[0..dn.n_stats]) |s| {
        if (s.list != wire.list_runeword) continue;
        const mine = statOf(&it, wire.list_runeword, s.id) orelse return error.TestExpectedEqual;
        try testing.expectEqual(s.value, mine.value);
        try testing.expectEqual(s.param, mine.param);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 7), seen);
    try testing.expectEqual(@as(i32, 775), statOf(&it, wire.list_runeword, 31).?.value);
    // a normal base of the best defense: Mage Plate's maximum
    try testing.expectEqual(@as(i32, 261), statOf(&it, wire.list_base, 31).?.value);
    // and it does not roll when asked not to be perfect
    var worse = try m.makeKit("base:xtp;runeword=Enigma;nomax");
    defer worse.deinit(testing.allocator);
    var wb = try back(&d, worse);
    defer wb.deinit();
    const v = statOf(&wb.recs[0], wire.list_runeword, 31).?.value;
    try testing.expect(v >= 750 and v <= 775);
}

test "an ethereal runeword weapon: the engine's rule for its durability, the runes in order" {
    var m = try Maker.init(testing.allocator, .expansion, 12);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    inline for (.{
        .{ "base:fla;runeword=Heart of the Oak;eth", "Heart of the Oak", 5 },
        .{ "base:7wa;runeword=Call to Arms;eth", "Call to Arms", 6 },
        .{ "base:7wc;runeword=Insight;eth", "Insight", 5 },
    }) |c| {
        var made = try m.makeKit(c[0]);
        defer made.deinit(testing.allocator);
        var b = try back(&d, made);
        defer b.deinit();
        try testing.expectEqual(@as(u16, c[2]), made.n_records);
        try testing.expectEqualStrings(c[1], b.view.name);
        try testing.expect(b.view.ethereal);
        const it = b.recs[0];
        const ref = m.t.itemRef(it.codeSlice()).?;
        const dur: i64 = m.t.itemTable(ref.table).int(ref.row, "durability");
        try testing.expectEqual(@as(i32, @intCast(@divTrunc(dur, 2) + 1)), baseOf(&it, 73));
        try testing.expectEqual(baseOf(&it, 73), baseOf(&it, 72));
    }
}

/// A base stat of a parsed item: the parser files the maximum durability under the item's own list.
fn baseOf(it: *const wire.Item, id: u16) i32 {
    for (it.stats[0..it.n_stats]) |s| if (s.id == id and (s.list == wire.list_base or s.list == 0)) return s.value;
    return -1;
}

test "Spirit on a shield, and the base must be one the runeword is made for" {
    var m = try Maker.init(testing.allocator, .expansion, 13);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var made = try m.makeKit("base:pab;runeword=Spirit");
    defer made.deinit(testing.allocator);
    var b = try back(&d, made);
    defer b.deinit();
    try testing.expectEqualStrings("Spirit", b.view.name);
    try testing.expectEqual(@as(u8, 4), b.recs[0].sockets);
    // a runeword that is not for this base, a name that is none, and a base that has no room
    try testing.expectError(error.BadRuneword, m.makeKit("base:pab;runeword=Call to Arms"));
    try testing.expectError(error.BadRuneword, m.makeKit("base:pab;runeword=Nonesuch"));
    try testing.expectError(error.BadRuneword, m.makeKit("base:cap;runeword=Enigma"));
    try testing.expectError(error.BadSockets, m.makeKit("base:pab;sockets=6"));
}

test "a unique with a rune in it, on another base, ethereal" {
    var m = try Maker.init(testing.allocator, .expansion, 14);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();

    var hc = try m.makeKit("unique:Harlequin Crest;sockets=1;fill=r30");
    defer hc.deinit(testing.allocator);
    var hb = try back(&d, hc);
    defer hb.deinit();
    try testing.expectEqualStrings("Harlequin Crest", hb.view.name);
    try testing.expectEqual(@as(u16, 2), hc.n_records);
    try testing.expectEqualStrings("r30", hb.recs[1].codeSlice());
    try testing.expect(hb.recs[0].flags & wire.flag.SOCKETED != 0);

    // the cube's upgrade keeps the quality and the mods on the elite base; the defense is the base's best, x3/2
    var sk = try m.makeKit("unique:Skin of the Flayerd One;upgrade=elite;eth;sockets=1;fill=r32");
    defer sk.deinit(testing.allocator);
    var sb = try back(&d, sk);
    defer sb.deinit();
    try testing.expectEqualStrings("Skin of the Flayed One", sb.view.name);
    try testing.expectEqualStrings("Scarab Husk", sb.view.base_name); // Demonhide Armor is the unique's own base; the elite tier of that line
    try testing.expect(sb.view.ethereal);
    const ref = m.t.itemRef("ula").?;
    const best: i32 = @intCast(m.t.armor.int(ref.row, "maxac"));
    try testing.expectEqual(@divTrunc(best * 3, 2), baseOf(&sb.recs[0], 31));
    // a base of another kind is refused
    // there is no hand-picked base any more, and only the next tier of the unique's own line exists
    try testing.expectError(error.BadSpec, m.makeKit("unique:Skin of the Flayerd One;base=ula"));
    try testing.expectError(error.BadSpec, m.makeKit("unique:Skin of the Flayerd One;upgrade=ultra"));
    try testing.expectError(error.NotUpgradable, m.makeKit("unique:Skin of the Flayerd One;upgrade=exceptional")); // already exceptional
    try testing.expectError(error.NotUpgradable, m.makeKit("unique:Crown of Ages;upgrade=elite")); // already elite
    try testing.expectError(error.NotUpgradable, m.makeKit("set:Trang-Oul's Claws;upgrade=elite")); // no cube recipe takes a set item
    try testing.expectError(error.NotUpgradable, m.makeKit("unique:Wisp;upgrade=elite"));
    // a ring cannot be ethereal
    try testing.expectError(error.Unsupported, m.makeKit("unique:Wisp;eth"));
}

test "uniques at the best of their ranges" {
    var m = try Maker.init(testing.allocator, .expansion, 15);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var wt = try m.makeKit("unique:Wartraveler");
    defer wt.deinit(testing.allocator);
    var b = try back(&d, wt);
    defer b.deinit();
    // +190% enhanced defense, +25 maximum damage, 25% faster run/walk
    try testing.expectEqual(@as(i32, 190), statOf(&b.recs[0], 0, 16).?.value);
    try testing.expectEqual(@as(i32, 25), statOf(&b.recs[0], 0, 22).?.value);
    try testing.expectEqual(@as(i32, 25), statOf(&b.recs[0], 0, 96).?.value);

    // a charged skill is named by its skill, and carries all its charges
    var am = try m.makeKit("unique:Arachnid Mesh");
    defer am.deinit(testing.allocator);
    var ab = try back(&d, am);
    defer ab.deinit();
    try testing.expect(hasLine(ab.view, "Venom (11/11 Charges)"));
    var wisp = try m.makeKit("unique:Wisp");
    defer wisp.deinit(testing.allocator);
    var wb = try back(&d, wisp);
    defer wb.deinit();
    try testing.expect(hasLine(wb.view, "Lightning on striking"));
    try testing.expect(hasLine(wb.view, "Oak Sage (15/15 Charges)"));
    // the others of the request
    for ([_][]const u8{ "Bul Katho's Wedding Band", "Crown of Ages" }) |name| {
        var line: [64]u8 = undefined;
        var made = try m.makeKit(try std.fmt.bufPrint(&line, "unique:{s}", .{name}));
        made.deinit(testing.allocator);
    }
}

test "a set item on an upgraded base carries its partial bonuses in lists of their own" {
    var m = try Maker.init(testing.allocator, .expansion, 16);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var made = try m.makeKit("set:Trang-Oul's Claws");
    defer made.deinit(testing.allocator);
    var b = try back(&d, made);
    defer b.deinit();
    const it = b.recs[0];
    try testing.expectEqual(wire.Quality.set, it.quality);
    try testing.expectEqualStrings("Trang-Oul's Claws", b.view.name);
    try testing.expectEqualStrings("Heavy Bracers", b.view.base_name); // a set item stays on its own base
    try testing.expectEqualStrings("xmg", it.codeSlice());
    // the partial lists that are present are tiers of the row
    var lists: u8 = 0;
    for (it.stats[0..it.n_stats]) |s| if (s.list >= 1 and s.list <= 5) {
        lists |= @as(u8, 1) << @intCast(s.list - 1);
    };
    try testing.expect(lists != 0);
    // the item's own mods are in list 0
    try testing.expect(statOf(&it, 0, 105) != null); // faster cast rate
    // Classic carries two base properties and no partial lists
    var c = try Maker.init(testing.allocator, .classic, 16);
    defer c.deinit();
    var cm = try c.makeKit("set:Civerb's Ward");
    defer cm.deinit(testing.allocator);
    var cb = try back(&d, cm);
    defer cb.deinit();
    for (cb.recs[0].stats[0..cb.recs[0].n_stats]) |s| try testing.expect(s.list == 0 or s.list == wire.list_base);
    try testing.expectError(error.NotInScope, c.makeKit("unique:Skullcollector")); // an Expansion item
}

test "the Hellfire Torch is for the class asked for, Annihilus at its best" {
    var m = try Maker.init(testing.allocator, .expansion, 17);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var torch = try m.makeKit("unique:Hellfire Torch;class=paladin");
    defer torch.deinit(testing.allocator);
    var tb = try back(&d, torch);
    defer tb.deinit();
    try testing.expectEqual(@as(u32, 3), statOf(&tb.recs[0], 0, 83).?.param);
    try testing.expectEqual(@as(i32, 3), statOf(&tb.recs[0], 0, 83).?.value);
    try testing.expect(hasLine(tb.view, "+3 to Paladin Skill Levels"));
    try testing.expectEqual(@as(i32, 20), statOf(&tb.recs[0], 0, 0).?.value);
    // 10 of 10 charges
    const ch = statOf(&tb.recs[0], 0, 204).?.value;
    try testing.expectEqual(ch & 0xff, ch >> 8);

    var anni = try m.makeKit("unique:Annihilus");
    defer anni.deinit(testing.allocator);
    var ab = try back(&d, anni);
    defer ab.deinit();
    try testing.expectEqual(@as(i32, 20), statOf(&ab.recs[0], 0, 0).?.value);
    try testing.expectEqual(@as(i32, 20), statOf(&ab.recs[0], 0, 39).?.value);
    try testing.expectEqual(@as(i32, 10), statOf(&ab.recs[0], 0, 85).?.value);
    try testing.expect(ab.recs[0].has_variant);
    // a picture asked for
    var pic = try m.makeKit("unique:Annihilus;variant=2");
    defer pic.deinit(testing.allocator);
    var pb = try back(&d, pic);
    defer pb.deinit();
    try testing.expectEqual(@as(u8, 2), pb.recs[0].variant);
}

test "tomes hold twenty scrolls, the Cube and a key are plain items" {
    var m = try Maker.init(testing.allocator, .expansion, 18);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    for ([_][]const u8{ "item:tbk", "item:ibk" }) |line| {
        var made = try m.makeKit(line);
        defer made.deinit(testing.allocator);
        var b = try back(&d, made);
        defer b.deinit();
        try testing.expectEqual(@as(u16, 20), b.recs[0].quantity);
        // as long as an engine tome of the seeded characters
        try testing.expectEqual(@as(usize, 23), made.rec.len);
        try testing.expectEqual(@as(u8, 1), made.w);
        try testing.expectEqual(@as(u8, 2), made.h);
    }
    var ibk = try m.makeKit("item:ibk");
    defer ibk.deinit(testing.allocator);
    try testing.expectEqual(@as(u5, 1), record.testBookOf(ibk.rec));
    var tbk = try m.makeKit("item:tbk;qty=5");
    defer tbk.deinit(testing.allocator);
    try testing.expectEqual(@as(u5, 0), record.testBookOf(tbk.rec));
    var cube = try m.makeKit("item:box");
    defer cube.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 2), cube.w);
    try testing.expectEqual(@as(usize, 21), cube.rec.len);
    var rune = try m.makeKit("item:r30");
    defer rune.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 14), rune.rec.len);
}

test "an amulet with the affixes named, each at the top of its range" {
    var m = try Maker.init(testing.allocator, .expansion, 19);
    defer m.deinit();
    var d = try itemtext.Describer.init(testing.allocator);
    defer d.deinit();
    var made = try m.makeKit("rare:amu;prefix=Priest's,Great Wyrm's,Ruby;suffix=of the Apprentice,of Perfection,of the Colosuss");
    defer made.deinit(testing.allocator);
    var b = try back(&d, made);
    defer b.deinit();
    const it = b.recs[0];
    try testing.expectEqual(wire.Quality.rare, it.quality);
    // +2 Paladin skills, 10% faster cast, +20 dexterity, +60 life, +90 mana, 40% fire resistance
    try testing.expectEqual(@as(i32, 2), statOf(&it, 0, 83).?.value);
    try testing.expectEqual(@as(u32, 3), statOf(&it, 0, 83).?.param);
    try testing.expectEqual(@as(i32, 10), statOf(&it, 0, 105).?.value);
    try testing.expectEqual(@as(i32, 20), statOf(&it, 0, 2).?.value);
    try testing.expectEqual(@as(i32, 60 << 8), statOf(&it, 0, 7).?.value);
    try testing.expectEqual(@as(i32, 90 << 8), statOf(&it, 0, 9).?.value);
    try testing.expectEqual(@as(i32, 40), statOf(&it, 0, 39).?.value);
    for (it.rare_prefixes) |p| try testing.expect(p != 0);
    for (it.rare_suffixes) |p| try testing.expect(p != 0);
    try testing.expect(b.view.name.len > 0);
    // an affix that does not fit the base, or does not exist
    try testing.expectError(error.BadAffix, m.makeKit("rare:amu;prefix=Priest's,Great Wyrm's,Ruby,Ruby;suffix=of Perfection"));
    try testing.expectError(error.BadAffix, m.makeKit("rare:amu;prefix=Nonesuch"));
    try testing.expectError(error.BadAffix, m.makeKit("magic:amu;prefix=Priest's,Ruby"));
    try testing.expectError(error.BadAffix, m.makeKit("rare:amu"));
    var mg = try m.makeKit("magic:amu;prefix=Priest's;suffix=of the Colosuss");
    defer mg.deinit(testing.allocator);
    var mb = try back(&d, mg);
    defer mb.deinit();
    try testing.expectEqualStrings("Priest's Amulet of the Colossus", mb.view.name);
}

test "the place of an item, and Classic's limits" {
    var m = try Maker.init(testing.allocator, .expansion, 20);
    defer m.deinit();
    m.place = .{ .dest = 1, .body_loc = 3, .page_raw = 0 };
    var made = try m.makeKit("base:xtp;runeword=Enigma");
    defer made.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recs = try itemtext.parseRecords(arena.allocator(), made.rec, 8);
    try testing.expectEqual(@as(u8, 1), recs[0].dest);
    try testing.expectEqual(@as(u8, 3), recs[0].body_loc);
    // what is socketed is in no grid
    try testing.expectEqual(@as(u8, 6), recs[1].dest);
    m.place = .{ .page_raw = page_raw_inventory, .x = 4, .y = 2 };
    var inv = try m.makeKit("item:tbk");
    defer inv.deinit(testing.allocator);
    const r2 = try itemtext.parseRecords(arena.allocator(), inv.rec, 1);
    try testing.expectEqual(@as(u8, 4), r2[0].x);
    try testing.expectEqual(@as(u8, 2), r2[0].y);
    try testing.expectEqual(@as(u8, 1), r2[0].page_raw);

    var c = try Maker.init(testing.allocator, .classic, 20);
    defer c.deinit();
    try testing.expectError(error.NotInScope, c.makeKit("base:xtp;runeword=Enigma"));
    try testing.expectError(error.NotInScope, c.makeKit("unique:Harlequin Crest"));
}

test "every form of a kit is written back exactly as it parses" {
    var m = try Maker.init(testing.allocator, .expansion, 21);
    defer m.deinit();
    const lines = [_][]const u8{
        "base:xtp;runeword=Enigma",
        "base:fla;runeword=Heart of the Oak;eth",
        "base:pab;runeword=Spirit",
        "base:pad;runeword=Spirit;eth",
        "unique:Harlequin Crest;sockets=1;fill=r30",
        "unique:Skin of the Flayerd One;upgrade=elite;eth;sockets=1;fill=r32",
        "set:Trang-Oul's Claws",
        "unique:Hellfire Torch;class=paladin",
        "unique:Annihilus",
        "unique:Wisp",
        "item:tbk",
        "item:ibk",
        "item:box",
        "item:key",
        "item:r30",
        "rare:amu;prefix=Priest's,Great Wyrm's,Ruby;suffix=of the Apprentice,of Perfection,of the Colosuss",
        "magic:amu;prefix=Priest's;suffix=of the Colosuss",
    };
    for (lines) |line| {
        var made = try m.makeKit(line);
        defer made.deinit(testing.allocator);
        testing.expect(record.testRoundTrips(made.rec)) catch |e| {
            std.debug.print("does not round trip: {s}\n", .{line});
            return e;
        };
    }
}

test "automod: a Sacred Targe with the best all-resistance automod, under Spirit" {
    var m = try Maker.init(testing.allocator, .expansion, 77);
    defer m.deinit();
    var made = try m.makeKit("base:pab;runeword=Spirit;automod=Chromatic");
    defer made.deinit(testing.allocator);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const recs = try itemtext.parseRecords(ar.allocator(), made.rec, 8);
    const it = recs[0];
    // Chromatic is the 27th row of the 1.14d AutoMagic.txt: all resistances 35 to 45
    try testing.expectEqual(@as(u16, 27), it.automagic);
    for ([_]u16{ 39, 41, 43, 45 }) |id| try testing.expectEqual(@as(i32, 45), statOf(&it, 0, id).?.value);
    // the shield keeps its runeword, four sockets and the top of its defense range
    try testing.expect(it.flags & wire.flag.RUNEWORD != 0);
    try testing.expectEqual(@as(u8, 4), it.sockets);
    try testing.expectEqual(@as(i32, 158), baseOf(&it, 31));
    // a row that does not fit the base, and one that is none
    try testing.expectError(error.BadSpec, m.makeKit("base:pab;automod=Nonesuch"));
    try testing.expectError(error.BadSpec, parseKit("unique:Wisp;automod=Chromatic"));
}

test "ethereal: the engine's rule, ITEMMODS_ApplyEthereality and ITEMS_MakeEthereal" {
    var m = try Maker.init(testing.allocator, .expansion, 78);
    defer m.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // armor: the rolled defense times 3 / 2 (integer), at the top of the base range 446 to 557; maximum durability
    // half the base's plus one; a weapon stores no damage (the game applies the 3 / 2 when it loads the save)
    var plain = try m.makeKit("base:uul");
    defer plain.deinit(testing.allocator);
    var eth = try m.makeKit("base:uul;eth");
    defer eth.deinit(testing.allocator);
    const p = (try itemtext.parseRecords(ar.allocator(), plain.rec, 8))[0];
    const e = (try itemtext.parseRecords(ar.allocator(), eth.rec, 8))[0];
    try testing.expectEqual(@as(i32, 557), baseOf(&p, 31));
    try testing.expectEqual(@as(i32, 557 * 3 / 2), baseOf(&e, 31));
    try testing.expectEqual(@as(i32, 70), baseOf(&p, 73));
    try testing.expectEqual(@as(i32, 70 / 2 + 1), baseOf(&e, 73));
    try testing.expectEqual(baseOf(&e, 73), baseOf(&e, 72));
    // an upgraded unique is a fresh roll on the elite base, then made ethereal: the elite base's top, times 3 / 2,
    // and the enhanced defense the unique carries is a separate stat that the engine adds on top of it
    var up = try m.makeKit("unique:Skin of the Flayerd One;upgrade=elite;eth");
    defer up.deinit(testing.allocator);
    const u = (try itemtext.parseRecords(ar.allocator(), up.rec, 8))[0];
    try testing.expectEqual(@as(i32, @divTrunc(@as(i32, @intCast(m.t.armor.int(m.t.itemRef("ula").?.row, "maxac"))) * 3, 2)), baseOf(&u, 31));
    try testing.expectEqual(@as(i32, 190), statOf(&u, 0, 16).?.value);
    // a weapon: no damage stats in the record, durability halved plus one
    var axe = try m.makeKit("base:7wa;eth");
    defer axe.deinit(testing.allocator);
    const a = (try itemtext.parseRecords(ar.allocator(), axe.rec, 8))[0];
    for (a.stats[0..a.n_stats]) |s| try testing.expect(s.id != 21 and s.id != 22);
    try testing.expectEqual(@as(i32, @divTrunc(@as(i32, @intCast(m.t.weapons.int(m.t.itemRef("7wa").?.row, "durability"))), 2) + 1), baseOf(&a, 73));
}

test "validation: what the engine never makes ethereal is refused" {
    var m = try Maker.init(testing.allocator, .expansion, 79);
    defer m.deinit();
    // Crown of Ages is indestructible, so ITEMS_HasDurability is false and ITEMS_MakeEthereal returns early
    try testing.expectError(error.Impossible, m.makeKit("unique:Crown of Ages;eth"));
    var ok = try m.makeKit("unique:Crown of Ages");
    ok.deinit(testing.allocator);
    // a set item is never ethereal
    try testing.expectError(error.Impossible, m.makeKit("set:Trang-Oul's Claws;eth"));
    // a ring has no durability
    try testing.expectError(error.Unsupported, m.makeKit("unique:Wisp;eth"));
    // an ordinary unique with durability is fine
    var s = try m.makeKit("unique:Skin of the Flayerd One;upgrade=elite;eth");
    s.deinit(testing.allocator);
}

test "validation: a runeword's or a socketed rune's Indestructible does not block an ethereal base" {
    var m = try Maker.init(testing.allocator, .expansion, 80);
    defer m.deinit();
    // the eth base exists first; Eternity (Indestructible) and a Zod rune come after it
    var eternity = try m.makeKit("base:7wa;runeword=Eternity;eth");
    eternity.deinit(testing.allocator);
    var zod = try m.makeKit("base:7wa;eth;sockets=1;fill=r33");
    zod.deinit(testing.allocator);
    // the item's own generation mods still block it
    try testing.expectError(error.Impossible, m.makeKit("unique:Crown of Ages;eth"));
}

test "an upgrade is the next tier of the unique's own base line, read from the table columns" {
    var m = try Maker.init(testing.allocator, .expansion, 21);
    defer m.deinit();
    // every unique that sits on an Exceptional armour or weapon base goes to that row's ultracode, and nowhere else
    var checked: usize = 0;
    const ut = &m.t.unique_items;
    for (0..ut.rowCount()) |r| {
        const own = ut.str(r, "code");
        const ref = m.t.itemRef(own) orelse continue;
        if (ref.table == .misc) continue;
        const tbl = m.t.itemTable(ref.table);
        const uber = tbl.str(ref.row, "ubercode");
        const ultra = tbl.str(ref.row, "ultracode");
        if (uber.len == 0 or ultra.len == 0 or !std.mem.eql(u8, own, uber) or std.mem.eql(u8, own, ultra)) continue;
        try testing.expectEqualStrings(ultra, try m.upgraded(own, .elite));
        try testing.expectError(error.NotUpgradable, m.upgraded(own, .exceptional));
        checked += 1;
    }
    try testing.expect(checked > 20);
    // a Normal unique goes to its ubercode
    try testing.expectEqualStrings("xh9", try m.upgraded("bhm", .exceptional));
    // the case that was got wrong by hand: Skin of the Flayed One sits on Demonhide Armor, its elite is the Scarab Husk
    try testing.expectEqualStrings("ula", try m.upgraded("xla", .elite));
}
