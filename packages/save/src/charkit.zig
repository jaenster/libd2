//! charkit: a whole character save (.d2s) made from a text spec.
//!
//! The spec names a class, a level, how the stat points and the skill points are spent, whether the quests of
//! Acts I to V are done, the waypoints, the mercenary and every item with the place it sits in. The writer turns
//! that into the bytes the engine would have saved for a character that earned it: the header, the quest,
//! waypoint and NPC sections, the stat stream with life, mana and stamina worked out from the class table, the
//! skill levels in the class's own order, the player's item list and the mercenary's.
//!
//! The items are made by an `ItemSource` (kititem.zig makes them from the kit lines of the spec); this file only
//! places them. Everything else comes from the game's own tables (CharStats, Experience, Skills, Hireling,
//! Armor, Weapons), so a spec says what the character is and not how the file is laid out.
//!
//! Spec format, one directive per line, `#` starts a comment:
//!
//!   class paladin                        amazon sorceress necromancer paladin barbarian druid assassin
//!   level 99
//!   stats str=auto dex=80 ene=0 vit=rest total values; auto = what the equipped gear asks for; rest = every
//!                                        point still unspent. A stat left out keeps the class's base.
//!   skills prayer=1 vigor=20 ...         skill levels by Skills.txt name (lowercase, spaces kept), many lines
//!   skill-left blessed hammer            the left / right mouse skill the header names
//!   skill-right concentration
//!   quests complete                      every quest of Acts I to V done on all three difficulties (or `none`)
//!   waypoints all                        every waypoint of Acts I to V activated on all three difficulties
//!   merc act=2 difficulty=nightmare style=defensive level=98
//!   item <slot> | <kit line>             the player's item; slots: head amulet body rhand lhand rring lring belt
//!                                        boots gloves swap-rhand swap-lhand, or `inv X,Y` (a cell of the inventory)
//!   merc-item <slot> | <kit line>        the mercenary's item; slots: head body rhand lhand
//!
//! Points: every level gives StatPerLevel stat points and one skill point; with the quests done each difficulty
//! gives 5 stat points (Lam Esen's Tome) and 4 skill points (Den of Evil, Radament, Izual), and Potion of Life
//! 20 life, which is what a level 99 character that did them all has: 505 stat points and 110 skill points.
const std = @import("std");
const data = @import("d2-data");
const core = @import("d2-core");
const formats = @import("d2-formats");
const sections = @import("sections.zig");
const attributes = @import("attributes.zig");
const kititem = @import("kititem.zig");
const wire = sections.wire;
const d2s = sections.d2s;

pub const Error = error{
    BadSpec,
    BadClass,
    BadLevel,
    BadName,
    UnknownSkill,
    UnknownMerc,
    BadSlot,
    TooManyStatPoints,
    TooManySkillPoints,
    ItemFailed,
    TooLarge,
    OutOfMemory,
    NoTable,
};

pub const class_names = [_][]const u8{ "Amazon", "Sorceress", "Necromancer", "Paladin", "Barbarian", "Druid", "Assassin" };
const class_codes = [_][]const u8{ "ama", "sor", "nec", "pal", "bar", "dru", "ass" };

/// Where an item goes, as the record's own place bits say it.
pub const Place = struct {
    /// 0 stored, 1 equipped, 2 belt
    dest: u8 = 0,
    body_loc: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    /// the storage page of a stored item: 1 inventory, 4 cube, 5 stash
    page_raw: u8 = 0,
};

/// An item made by an `ItemSource`: its record, and the records that follow it (what is socketed in it) in the
/// same buffer.
pub const ItemRec = struct {
    rec: []u8,
    n_records: u16,
    w: u8,
    h: u8,
};

pub const ItemSource = struct {
    ctx: *anyopaque,
    make: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, line: []const u8, place: Place) anyerror!ItemRec,
};

pub const Slot = enum { head, amulet, body, rhand, lhand, rring, lring, belt, boots, gloves, swap_rhand, swap_lhand, inv };

fn bodyLoc(s: Slot) u8 {
    return switch (s) {
        .head => 1,
        .amulet => 2,
        .body => 3,
        .rhand => 4,
        .lhand => 5,
        .rring => 6,
        .lring => 7,
        .belt => 8,
        .boots => 9,
        .gloves => 10,
        .swap_rhand => 11,
        .swap_lhand => 12,
        .inv => 0,
    };
}

fn slotByName(name: []const u8) ?Slot {
    const names = [_]struct { n: []const u8, s: Slot }{
        .{ .n = "head", .s = .head },
        .{ .n = "amulet", .s = .amulet },
        .{ .n = "body", .s = .body },
        .{ .n = "rhand", .s = .rhand },
        .{ .n = "lhand", .s = .lhand },
        .{ .n = "rring", .s = .rring },
        .{ .n = "lring", .s = .lring },
        .{ .n = "belt", .s = .belt },
        .{ .n = "boots", .s = .boots },
        .{ .n = "gloves", .s = .gloves },
        .{ .n = "swap-rhand", .s = .swap_rhand },
        .{ .n = "swap-lhand", .s = .swap_lhand },
    };
    for (names) |e| if (std.mem.eql(u8, e.n, name)) return e.s;
    return null;
}

pub const ItemLine = struct {
    slot: Slot,
    /// the cell of an `inv` item
    x: u8 = 0,
    y: u8 = 0,
    kit: []const u8,
};

pub const StatSpec = union(enum) { keep, value: u32, auto, rest };

pub const MercSpec = struct {
    act: u8 = 2,
    difficulty: u8 = 2, // 1 normal, 2 nightmare, 3 hell (Hireling.txt's Difficulty)
    style: []const u8 = "defensive",
    level: u8 = 98,
    name: u16 = 5,
    id: u32 = 0x4d3c2b1a,
};

pub const SkillLevel = struct { name: []const u8, level: u8 };

pub const Spec = struct {
    class: u8 = 3,
    level: u8 = 99,
    str: StatSpec = .keep,
    dex: StatSpec = .keep,
    ene: StatSpec = .keep,
    vit: StatSpec = .keep,
    skills: []const SkillLevel = &.{},
    left_skill: []const u8 = "",
    right_skill: []const u8 = "",
    quests_done: bool = false,
    waypoints_all: bool = false,
    merc: ?MercSpec = null,
    items: []const ItemLine = &.{},
    merc_items: []const ItemLine = &.{},
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn parseStat(v: []const u8) Error!StatSpec {
    if (std.mem.eql(u8, v, "auto")) return .auto;
    if (std.mem.eql(u8, v, "rest")) return .rest;
    return .{ .value = std.fmt.parseInt(u32, v, 10) catch return error.BadSpec };
}

fn classByName(name: []const u8) ?u8 {
    for (class_names, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, name)) return @intCast(i);
    for (class_codes, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, name)) return @intCast(i);
    return null;
}

/// Parse the spec text. Slices of `text` are kept, so it has to outlive the Spec; `arena` holds the lists.
pub fn parseSpec(arena: std.mem.Allocator, text: []const u8) Error!Spec {
    var spec = Spec{};
    var skills: std.ArrayList(SkillLevel) = .empty;
    var items: std.ArrayList(ItemLine) = .empty;
    var merc_items: std.ArrayList(ItemLine) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |h| {
            // a `#` inside a kit line is not a comment (affix rows are written `#123`)
            if (std.mem.indexOfScalar(u8, line, '|') == null or h < std.mem.indexOfScalar(u8, line, '|').?) line = line[0..h];
        }
        line = trim(line);
        if (line.len == 0) continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const word = line[0..sp];
        const rest = trim(line[sp..]);
        if (std.mem.eql(u8, word, "class")) {
            spec.class = classByName(rest) orelse return error.BadClass;
        } else if (std.mem.eql(u8, word, "level")) {
            spec.level = std.fmt.parseInt(u8, rest, 10) catch return error.BadLevel;
            if (spec.level < 1 or spec.level > 99) return error.BadLevel;
        } else if (std.mem.eql(u8, word, "stats")) {
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            while (it.next()) |tok| {
                const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.BadSpec;
                const k = tok[0..eq];
                const v = try parseStat(tok[eq + 1 ..]);
                if (std.mem.eql(u8, k, "str")) spec.str = v else if (std.mem.eql(u8, k, "dex")) spec.dex = v else if (std.mem.eql(u8, k, "ene")) spec.ene = v else if (std.mem.eql(u8, k, "vit")) spec.vit = v else return error.BadSpec;
            }
        } else if (std.mem.eql(u8, word, "skills")) {
            // `name=level` pairs separated by commas: skill names hold spaces
            var it = std.mem.splitScalar(u8, rest, ',');
            while (it.next()) |pair| {
                const p = trim(pair);
                if (p.len == 0) continue;
                const eq = std.mem.lastIndexOfScalar(u8, p, '=') orelse return error.BadSpec;
                const lvl = std.fmt.parseInt(u8, trim(p[eq + 1 ..]), 10) catch return error.BadSpec;
                skills.append(arena, .{ .name = trim(p[0..eq]), .level = lvl }) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, word, "skill-left")) {
            spec.left_skill = rest;
        } else if (std.mem.eql(u8, word, "skill-right")) {
            spec.right_skill = rest;
        } else if (std.mem.eql(u8, word, "quests")) {
            if (std.mem.eql(u8, rest, "complete")) spec.quests_done = true else if (std.mem.eql(u8, rest, "none")) spec.quests_done = false else return error.BadSpec;
        } else if (std.mem.eql(u8, word, "waypoints")) {
            if (std.mem.eql(u8, rest, "all")) spec.waypoints_all = true else if (std.mem.eql(u8, rest, "none")) spec.waypoints_all = false else return error.BadSpec;
        } else if (std.mem.eql(u8, word, "merc")) {
            var m = MercSpec{};
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            while (it.next()) |tok| {
                const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.BadSpec;
                const k = tok[0..eq];
                const v = tok[eq + 1 ..];
                if (std.mem.eql(u8, k, "act")) {
                    m.act = std.fmt.parseInt(u8, v, 10) catch return error.BadSpec;
                } else if (std.mem.eql(u8, k, "difficulty")) {
                    m.difficulty = if (std.mem.eql(u8, v, "normal")) 1 else if (std.mem.eql(u8, v, "nightmare")) 2 else if (std.mem.eql(u8, v, "hell")) 3 else return error.BadSpec;
                } else if (std.mem.eql(u8, k, "style")) {
                    m.style = v;
                } else if (std.mem.eql(u8, k, "level")) {
                    m.level = std.fmt.parseInt(u8, v, 10) catch return error.BadSpec;
                } else if (std.mem.eql(u8, k, "name")) {
                    m.name = std.fmt.parseInt(u16, v, 10) catch return error.BadSpec;
                } else if (std.mem.eql(u8, k, "id")) {
                    m.id = std.fmt.parseInt(u32, v, 0) catch return error.BadSpec;
                } else return error.BadSpec;
            }
            spec.merc = m;
        } else if (std.mem.eql(u8, word, "item") or std.mem.eql(u8, word, "merc-item")) {
            const bar = std.mem.indexOfScalar(u8, rest, '|') orelse return error.BadSpec;
            const slot_text = trim(rest[0..bar]);
            const kit = trim(rest[bar + 1 ..]);
            if (kit.len == 0) return error.BadSpec;
            var il = ItemLine{ .slot = .inv, .kit = kit };
            if (std.mem.startsWith(u8, slot_text, "inv")) {
                const cell = trim(slot_text[3..]);
                const comma = std.mem.indexOfScalar(u8, cell, ',') orelse return error.BadSlot;
                il.x = std.fmt.parseInt(u8, trim(cell[0..comma]), 10) catch return error.BadSlot;
                il.y = std.fmt.parseInt(u8, trim(cell[comma + 1 ..]), 10) catch return error.BadSlot;
                if (il.x >= 10 or il.y >= 4) return error.BadSlot;
            } else il.slot = slotByName(slot_text) orelse return error.BadSlot;
            if (std.mem.eql(u8, word, "merc-item")) {
                switch (il.slot) {
                    .head, .body, .rhand, .lhand => {},
                    else => return error.BadSlot,
                }
                merc_items.append(arena, il) catch return error.OutOfMemory;
            } else items.append(arena, il) catch return error.OutOfMemory;
        } else return error.BadSpec;
    }
    spec.skills = skills.items;
    spec.items = items.items;
    spec.merc_items = merc_items.items;
    return spec;
}

// ---- the tables -------------------------------------------------------------------------------------------------

fn colInt(t: *const data.Table, row: usize, col: []const u8) u32 {
    return t.getInt(u32, row, col) orelse 0;
}

fn rowByKey(t: *const data.Table, col: []const u8, key: []const u8) ?usize {
    for (0..t.rowCount()) |r| if (std.ascii.eqlIgnoreCase(t.get(r, col), key)) return r;
    return null;
}

/// What the class table says a character of `class` at `level` is, in the units the save stores: whole stats, and
/// life, mana and stamina in 8.8 fixed point (a fourth of a point is kept).
pub const Base = struct {
    str: u32,
    dex: u32,
    ene: u32,
    vit: u32,
    stat_per_level: u32,
    life: u32,
    mana: u32,
    stamina: u32,
    life_per_vit: u32,
    mana_per_ene: u32,
    stamina_per_vit: u32,
    experience: u32,
};

pub fn classBase(gpa: std.mem.Allocator, class: u8, level: u8) Error!Base {
    if (class >= class_names.len) return error.BadClass;
    var cs = data.load(gpa, "CharStats") catch return error.NoTable;
    defer cs.deinit();
    var xp = data.load(gpa, "Experience") catch return error.NoTable;
    defer xp.deinit();
    const r = rowByKey(&cs, "class", class_names[class]) orelse return error.NoTable;
    const gained: u64 = level - 1;
    const vit = colInt(&cs, r, "vit");
    const ene = colInt(&cs, r, "int");
    const hpadd = colInt(&cs, r, "hpadd");
    var key: [4]u8 = undefined;
    const level_key = std.fmt.bufPrint(&key, "{d}", .{level - 1}) catch unreachable;
    const xr = rowByKey(&xp, "Level", level_key) orelse return error.NoTable;
    return .{
        .str = colInt(&cs, r, "str"),
        .dex = colInt(&cs, r, "dex"),
        .ene = ene,
        .vit = vit,
        .stat_per_level = colInt(&cs, r, "StatPerLevel"),
        .life = @intCast(((vit + hpadd) << 8) + gained * colInt(&cs, r, "LifePerLevel") * 64),
        .mana = @intCast((ene << 8) + gained * colInt(&cs, r, "ManaPerLevel") * 64),
        .stamina = @intCast((colInt(&cs, r, "stamina") << 8) + gained * colInt(&cs, r, "StaminaPerLevel") * 64),
        .life_per_vit = colInt(&cs, r, "LifePerVitality"),
        .mana_per_ene = colInt(&cs, r, "ManaPerMagic"),
        .stamina_per_vit = colInt(&cs, r, "StaminaPerVitality"),
        .experience = xp.getInt(u32, xr, class_names[class]) orelse return error.NoTable,
    };
}

/// The stat points a character has earned: StatPerLevel for each level above 1, and 5 for Lam Esen's Tome on each
/// of the three difficulties when the quests are done.
pub fn statPoints(b: Base, level: u8, quests_done: bool) u32 {
    return b.stat_per_level * (level - 1) + if (quests_done) @as(u32, 15) else 0;
}

/// The skill points: one for each level above 1, and with the quests done 4 on each difficulty (Den of Evil 1,
/// Radament 1, Izual 2).
pub fn skillPoints(level: u8, quests_done: bool) u32 {
    return (level - 1) + if (quests_done) @as(u32, 12) else 0;
}

/// The index of a skill within its class's block of the save's skill section, from Skills.txt.
pub fn skillIndex(gpa: std.mem.Allocator, class: u8, name: []const u8) Error!u8 {
    var t = data.load(gpa, "Skills") catch return error.NoTable;
    defer t.deinit();
    const first = firstSkillId(&t, class_codes[class]) orelse return error.NoTable;
    const r = rowByKey(&t, "skill", name) orelse return error.UnknownSkill;
    if (!std.ascii.eqlIgnoreCase(t.get(r, "charclass"), class_codes[class])) return error.UnknownSkill;
    const id = colInt(&t, r, "Id");
    if (id < first or id - first >= 30) return error.UnknownSkill;
    return @intCast(id - first);
}

fn firstSkillId(t: *const data.Table, code: []const u8) ?u32 {
    var best: ?u32 = null;
    for (0..t.rowCount()) |r| {
        if (!std.ascii.eqlIgnoreCase(t.get(r, "charclass"), code)) continue;
        const id = colInt(t, r, "Id");
        if (best == null or id < best.?) best = id;
    }
    return best;
}

/// The id the header names for a left or right mouse skill.
fn skillId(gpa: std.mem.Allocator, name: []const u8) Error!u32 {
    var t = data.load(gpa, "Skills") catch return error.NoTable;
    defer t.deinit();
    const r = rowByKey(&t, "skill", name) orelse return error.UnknownSkill;
    return colInt(&t, r, "Id");
}

// ---- sections that are the same for every character that did everything --------------------------------------------

/// The "Woo!" section's per-difficulty block of a character whose quests of Acts I to V are all done, as the
/// engine saves it: word 0 is the Act I intro, 1..6 Den to Andariel, and so on to word 41; 42..47 belong to d2up's
/// own Act VI and stay empty.
const quests_done_words = [48]u16{
    0x0001, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x0001, 0x0001, 0x901d, 0x1c79, 0x9ffd,
    0x9ffd, 0x9ffd, 0x1fe5, 0x0001, 0x0001, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x0001,
    0x0001, 0x9ffd, 0x9ffd, 0x9ffd, 0x0001, 0x0000, 0x0000, 0x0000, 0x0001, 0x0000, 0x0000, 0x9ffd,
    0x9fed, 0x9ffd, 0x9ffd, 0x9ffd, 0x9ffd, 0x8001, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
};

/// The "w4" body of a character that met and greeted everyone.
const npc_body = [49]u8{
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x6f, 0xfe, 0xff, 0x5e, 0xfe, 0x00, 0x00, 0x00, 0xff,
    0xff, 0xff, 0x7e, 0xff, 0x00, 0x00, 0x00, 0x4b, 0xff, 0xff, 0x5f, 0xfd, 0x00, 0x00, 0x00,
};

/// The kit items of kititem.zig as the source of a spec's items. `maker` has to outlive the returned source.
pub fn kitSource(maker: *kititem.Maker) ItemSource {
    return .{ .ctx = maker, .make = kitMake };
}

fn kitMake(ctx: *anyopaque, gpa: std.mem.Allocator, line: []const u8, place: Place) anyerror!ItemRec {
    const maker: *kititem.Maker = @ptrCast(@alignCast(ctx));
    maker.place = .{ .dest = place.dest, .body_loc = place.body_loc, .x = place.x, .y = place.y, .page_raw = place.page_raw };
    var made = try maker.makeKit(line);
    defer made.deinit(maker.gpa);
    return .{ .rec = try gpa.dupe(u8, made.rec), .n_records = made.n_records, .w = made.w, .h = made.h };
}

// ---- the save ---------------------------------------------------------------------------------------------------------

/// What failed, for the caller to say: the kit line of the item that could not be made, and why.
pub const Diag = struct {
    line: []const u8 = "",
    err: []const u8 = "",
};

pub const Options = struct {
    diag: ?*Diag = null,
    /// creation time, seconds since the epoch
    created: u32 = 1_790_000_000,
    /// the header's status byte: the expansion bit only. Bit 0 must stay clear: the engine's save parser treats it as
    /// a header-only file and returns before it creates the player unit, so the join fails. Hardcore and ladder are
    /// the realm's to give when the save is loaded into an account.
    status: u8 = 0x20,
};

const ItemList = struct {
    bytes: std.ArrayList(u8) = .empty,
    count: u32 = 0,

    fn add(l: *ItemList, gpa: std.mem.Allocator, r: ItemRec) Error!void {
        l.bytes.appendSlice(gpa, r.rec) catch return error.OutOfMemory;
        // the header counts the items the character carries; the items socketed into one are not counted
        l.count += 1;
    }
};

fn reqStrength(gpa: std.mem.Allocator, code: []const u8) ?u32 {
    inline for (.{ "Armor", "Weapons" }) |tn| {
        var t = data.load(gpa, tn) catch return null;
        defer t.deinit();
        if (rowByKey(&t, "code", code)) |r| return colInt(&t, r, "reqstr");
    }
    return null;
}

fn itemOf(rec: []const u8) wire.Item {
    var r = core.bitreader.BitReader.init(rec);
    return wire.parseSave(&r);
}

fn failItem(opts: Options, line: []const u8, e: anyerror) Error {
    if (opts.diag) |d| {
        d.line = line;
        d.err = @errorName(e);
    }
    return error.ItemFailed;
}

/// Make the whole save. The result is owned by the caller.
pub fn compose(gpa: std.mem.Allocator, spec: Spec, name: []const u8, opts: Options, source: ItemSource) Error![]u8 {
    if (name.len == 0 or name.len > d2s.name_max) return error.BadName;
    const base = try classBase(gpa, spec.class, spec.level);

    // the items first: the stats can depend on what is worn
    var player = ItemList{};
    defer player.bytes.deinit(gpa);
    var merc = ItemList{};
    defer merc.bytes.deinit(gpa);
    var gear_str: u32 = 0;
    for (spec.items) |il| {
        const place: Place = switch (il.slot) {
            .inv => .{ .dest = 0, .x = il.x, .y = il.y, .page_raw = 1 },
            else => .{ .dest = 1, .body_loc = bodyLoc(il.slot), .x = bodyLoc(il.slot) },
        };
        const made = source.make(source.ctx, gpa, il.kit, place) catch |e| return failItem(opts, il.kit, e);
        defer gpa.free(made.rec);
        try player.add(gpa, made);
        if (il.slot != .inv and made.rec.len > 8) {
            const it = itemOf(made.rec);
            if (reqStrength(gpa, it.codeSlice())) |req| {
                const adj = if (it.flags & wire.flag.ETHEREAL != 0 and req > 10) req - 10 else req;
                gear_str = @max(gear_str, adj);
            }
        }
    }
    for (spec.merc_items) |il| {
        const place: Place = .{ .dest = 1, .body_loc = bodyLoc(il.slot), .x = bodyLoc(il.slot) };
        const made = source.make(source.ctx, gpa, il.kit, place) catch |e| return failItem(opts, il.kit, e);
        defer gpa.free(made.rec);
        try merc.add(gpa, made);
    }
    if (player.count > 0xffff or merc.count > 0xffff) return error.TooLarge;

    // stats: what is named is a total, `auto` the gear's need, `rest` whatever points are left
    const total_points = statPoints(base, spec.level, spec.quests_done);
    var str = base.str;
    var dex = base.dex;
    var ene = base.ene;
    var vit = base.vit;
    var spent: u32 = 0;
    const stats = [_]struct { s: StatSpec, v: *u32, b: u32 }{
        .{ .s = spec.str, .v = &str, .b = base.str },
        .{ .s = spec.dex, .v = &dex, .b = base.dex },
        .{ .s = spec.ene, .v = &ene, .b = base.ene },
        .{ .s = spec.vit, .v = &vit, .b = base.vit },
    };
    for (stats) |e| {
        switch (e.s) {
            .keep, .rest => {},
            .auto => e.v.* = @max(e.b, gear_str),
            .value => |n| {
                if (n < e.b) return error.BadSpec;
                e.v.* = n;
            },
        }
        spent += e.v.* - e.b;
    }
    if (spent > total_points) return error.TooManyStatPoints;
    var unspent = total_points - spent;
    for (stats) |e| if (e.s == .rest) {
        e.v.* += unspent;
        unspent = 0;
    };

    // life, mana and stamina: the base for the level, what vitality and energy added, and the three Potions of Life
    const vit_extra = vit - base.vit;
    const ene_extra = ene - base.ene;
    const potions: u32 = if (spec.quests_done) 60 else 0;
    const life = base.life + vit_extra * base.life_per_vit * 64 + (potions << 8);
    const mana = base.mana + ene_extra * base.mana_per_ene * 64;
    const stamina = base.stamina + vit_extra * base.stamina_per_vit * 64;

    // skills
    var skills_left = skillPoints(spec.level, spec.quests_done);
    var sk = sections.Skills{};
    for (spec.skills) |s| {
        const idx = try skillIndex(gpa, spec.class, s.name);
        sk.levels[idx] = s.level;
        if (s.level > skills_left) return error.TooManySkillPoints;
        skills_left -= s.level;
    }

    var save = sections.Save{};
    const h = &save.header;
    var hdr: [d2s.header_size]u8 = undefined;
    if (!d2s.newSave(&hdr, name, spec.class, 0, opts.created)) return error.BadName;
    h.* = d2s.parseHeader(&hdr).?;
    h.status = opts.status;
    h.level = spec.level;
    h.progression = if (spec.quests_done) 15 else 0;
    h.difficulty = if (spec.quests_done) .{ 0, 0, 0x80 } else .{ 0x80, 0, 0 };
    h.map_id = 0x24bb5888;
    if (spec.left_skill.len != 0) h.left_skill = try skillId(gpa, spec.left_skill);
    if (spec.right_skill.len != 0) h.right_skill = try skillId(gpa, spec.right_skill);
    if (spec.merc) |m| {
        var ht = data.load(gpa, "Hireling") catch return error.NoTable;
        defer ht.deinit();
        const id = hirelingId(&ht, m) orelse return error.UnknownMerc;
        h.merc_dead = 0;
        h.merc_id = m.id;
        h.merc_name_id = m.name;
        h.merc_type = @intCast(id.id);
        h.merc_experience = mercExperience(id.exp_per_level, m.level);
    }

    save.quests.head = .{ 0x06, 0, 0, 0, 0x2a, 0x01 };
    if (spec.quests_done) {
        for (&save.quests.blocks) |*blk| {
            for (quests_done_words, 0..) |w, i| std.mem.writeInt(u16, blk[i * 2 ..][0..2], w, .little);
        }
    }
    save.waypoints.version = 1;
    save.waypoints.size = 0x50;
    for (&save.waypoints.blocks) |*blk| {
        blk[0] = 0x02;
        blk[1] = 0x01;
    }
    save.waypoints.tail = 1;
    if (spec.waypoints_all) {
        for (0..3) |d| for (0..39) |i| save.waypoints.set(@enumFromInt(d), @intCast(i), true);
    }
    save.npcs.body = npc_body;

    var a = attributes.Section{};
    a.setRaw(0, str);
    a.setRaw(1, ene);
    a.setRaw(2, dex);
    a.setRaw(3, vit);
    if (unspent > 0) a.setRaw(4, unspent);
    if (skills_left > 0) a.setRaw(5, skills_left);
    a.setRaw(6, life);
    a.setRaw(7, life);
    a.setRaw(8, mana);
    a.setRaw(9, mana);
    a.setRaw(10, stamina);
    a.setRaw(11, stamina);
    a.setRaw(12, spec.level);
    a.setRaw(13, base.experience);
    save.attributes = a;
    save.skills = sk;

    // the item tail: the player's list, the corpse list (empty), the mercenary's list and the golem flag
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    tail.appendSlice(gpa, "JM") catch return error.OutOfMemory;
    tail.appendSlice(gpa, &std.mem.toBytes(@as(u16, @intCast(player.count)))) catch return error.OutOfMemory;
    tail.appendSlice(gpa, player.bytes.items) catch return error.OutOfMemory;
    tail.appendSlice(gpa, "JM\x00\x00") catch return error.OutOfMemory;
    tail.appendSlice(gpa, "jf") catch return error.OutOfMemory;
    if (spec.merc != null) {
        tail.appendSlice(gpa, "JM") catch return error.OutOfMemory;
        tail.appendSlice(gpa, &std.mem.toBytes(@as(u16, @intCast(merc.count)))) catch return error.OutOfMemory;
        tail.appendSlice(gpa, merc.bytes.items) catch return error.OutOfMemory;
    }
    tail.appendSlice(gpa, "kf\x00") catch return error.OutOfMemory;
    save.items = .{ .bytes = tail.items };

    const out = gpa.alloc(u8, save.byteLen()) catch return error.OutOfMemory;
    errdefer gpa.free(out);
    _ = save.writeInto(out) catch return error.TooLarge;
    return out;
}

const HirelingRow = struct { id: u32, exp_per_level: u32 };

/// The Hireling.txt row a spec names (the expansion's, version 100): the Id the header stores.
fn hirelingId(t: *const data.Table, m: MercSpec) ?HirelingRow {
    var want: [24]u8 = undefined;
    const diff_word = switch (m.difficulty) {
        1 => "Normal",
        2 => "Nightmare",
        else => "Hell",
    };
    const style_word: []const u8 = if (std.ascii.eqlIgnoreCase(m.style, "defensive")) "Def" else if (std.ascii.eqlIgnoreCase(m.style, "offensive")) "Off" else if (std.ascii.eqlIgnoreCase(m.style, "combat")) "Comb" else return null;
    const sub = std.fmt.bufPrint(&want, "{s}-{s}", .{ style_word, diff_word }) catch return null;
    for (0..t.rowCount()) |r| {
        if (!std.ascii.eqlIgnoreCase(t.get(r, "SubType"), sub)) continue;
        if (colInt(t, r, "Act") != m.act) continue;
        if (colInt(t, r, "Version") != 100) continue;
        return .{ .id = colInt(t, r, "Id"), .exp_per_level = colInt(t, r, "Exp/Lvl") };
    }
    return null;
}

/// A mercenary's experience for a level: `Exp/Lvl * level^2 * (level + 1)`, the curve the engine walks.
pub fn mercExperience(exp_per_level: u32, level: u8) u32 {
    const l: u64 = level;
    return @intCast(@as(u64, exp_per_level) * l * l * (l + 1));
}

// ---- reading it back ---------------------------------------------------------------------------------------------

pub const Readback = struct {
    class: u8,
    level: u8,
    str: u32,
    dex: u32,
    ene: u32,
    vit: u32,
    unspent_stats: u32,
    unspent_skills: u32,
    max_life: u32,
    max_mana: u32,
    max_stamina: u32,
    skill_points_spent: u32,
    quests_done: bool,
    act6_quest_words: u32,
    waypoints: [3]u32,
    player_items: u16,
    merc_items: u16,
    merc_type: u16,
    checksum_ok: bool,
};

/// Where the engine's player item load (PLRSAVE_LoadItemListFromStream @0x5335e0) would stop with its error.
pub const ItemFault = struct {
    /// the 0-based top-level item whose record (or whose socketed children) the engine rejects
    index: usize,
    /// the byte offset of the offending record inside the item section
    at: usize,
    reason: []const u8,
};

/// Walks the player's item list the way the engine does: the header count is the number of top-level items; every
/// record starts with "JM"; an item is followed by as many records as its own socket-item field says; a record whose
/// code the item tables do not know, or whose quality is not 1..9, fails the load. Null when the whole list loads and
/// ends where the corpse list begins ("JM", then a count of at most one).
fn walkList(items: []const u8, start: usize, end: *usize) ?ItemFault {
    if (start + 4 > items.len or !std.mem.eql(u8, items[start..][0..2], "JM")) return .{ .index = 0, .at = start, .reason = "list header is not JM" };
    const count = std.mem.readInt(u16, items[start + 2 ..][0..2], .little);
    var pos: usize = start + 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var children: usize = 0;
        var k: usize = 0;
        while (k <= children) : (k += 1) {
            const at = pos;
            if (pos + 2 > items.len or !std.mem.eql(u8, items[pos..][0..2], "JM")) return .{ .index = i, .at = at, .reason = if (k == 0) "record does not start with JM" else "socketed record does not start with JM" };
            var r = core.bitreader.BitReader.init(items[pos..]);
            const it = core.wire.parseSave(&r);
            if (r.bit_pos > (items.len - pos) * 8) return .{ .index = i, .at = at, .reason = "record runs past the end of the save" };
            if (it.flags & core.wire.flag.BODYPART == 0 and core.itemtypes.lookup(it.codeSlice()) == null) return .{ .index = i, .at = at, .reason = "item code unknown to the item tables" };
            if (!it.compact and !it.crude) {
                const q = @intFromEnum(it.quality);
                if (q < 1 or q > 9) return .{ .index = i, .at = at, .reason = "quality is not 1..9" };
            }
            if (k == 0 and !it.compact and !it.crude) children = it.socketed_count;
            pos += (r.bit_pos + 7) / 8;
        }
    }
    end.* = pos;
    return null;
}

/// Walks the whole item section the way the engine loads it: the player's list, the corpse list (at most one corpse),
/// then in an expansion save "jf" and the mercenary's list and "kf" and the golem flag. Null when it all loads and
/// ends at the end of the file.
pub fn itemListFault(items: []const u8) ?ItemFault {
    var pos: usize = 0;
    if (walkList(items, 0, &pos)) |f| return f;
    if (pos + 4 > items.len or !std.mem.eql(u8, items[pos..][0..2], "JM")) return .{ .index = 0, .at = pos, .reason = "no corpse list after the player list" };
    if (std.mem.readInt(u16, items[pos + 2 ..][0..2], .little) > 1) return .{ .index = 0, .at = pos, .reason = "corpse count above one" };
    if (std.mem.readInt(u16, items[pos + 2 ..][0..2], .little) == 1) return null; // a corpse's items are not walked here
    pos += 4;
    if (pos + 2 > items.len or !std.mem.eql(u8, items[pos..][0..2], "jf")) return .{ .index = 0, .at = pos, .reason = "no mercenary section (jf)" };
    pos += 2;
    var end: usize = 0;
    if (walkList(items, pos, &end)) |f| return f;
    pos = end;
    if (pos + 3 > items.len or !std.mem.eql(u8, items[pos..][0..2], "kf")) return .{ .index = 0, .at = pos, .reason = "no golem section (kf)" };
    if (pos + 3 > items.len) return .{ .index = 0, .at = pos, .reason = "golem flag missing" };
    if (items[pos + 2] == 0 and pos + 3 != items.len) return .{ .index = 0, .at = pos, .reason = "bytes after the golem flag" };
    return null;
}

/// The engine's own refusals of a save at join, in its numbering (PLAYERSAVE_ParseHeaderAndCreateUnit @0x56a090,
/// as 1.14d runs it): 4 truncated or class above 7, 5 size field differs from the length, 6 checksum, 7 version
/// outside 0x5c..0x60 or name differs from the client's, and 2 for status bit 0, which makes the engine return before
/// it creates the unit (the client then reports a bad header). Null when the engine would load it.
pub fn engineRefusal(bytes: []const u8, client_name: []const u8) ?u8 {
    const h = d2s.parseHeader(bytes) orelse return 4;
    if (!d2s.verifyChecksum(bytes)) return 6;
    if (h.file_size != bytes.len) return 5;
    if (!(h.version > 0x5b and h.version < 0x61)) return 7;
    const n = std.mem.indexOfScalar(u8, h.name[0..15], 0) orelse 15;
    if (!std.ascii.eqlIgnoreCase(h.name[0..n], client_name)) return 7;
    if (h.class > 7) return 4;
    if (h.status & 1 != 0) return 2;
    return null;
}

/// Parse a save written here back into the numbers a spec states.
pub fn readback(bytes: []const u8) !Readback {
    const s = try sections.parse(bytes);
    const a = s.attributes.attributes();
    var spent: u32 = 0;
    for (s.skills.levels) |l| spent += l;
    var done = true;
    var act6: u32 = 0;
    for (0..3) |d| {
        for (0..42) |i| {
            if (std.mem.readInt(u16, s.quests.blocks[d][i * 2 ..][0..2], .little) != quests_done_words[i]) done = false;
        }
        for (42..48) |i| {
            if (std.mem.readInt(u16, s.quests.blocks[d][i * 2 ..][0..2], .little) != 0) act6 += 1;
        }
    }
    var wps = [3]u32{ 0, 0, 0 };
    for (0..3) |d| for (0..39) |i| if (s.waypoints.isSet(@enumFromInt(d), @intCast(i))) {
        wps[d] += 1;
    };
    // the mercenary list follows the corpse list
    var merc_items: u16 = 0;
    if (std.mem.indexOf(u8, s.items.bytes, "jfJM")) |at| {
        merc_items = std.mem.readInt(u16, s.items.bytes[at + 4 ..][0..2], .little);
    }
    return .{
        .class = s.header.class,
        .level = s.header.level,
        .str = a.strength,
        .dex = a.dexterity,
        .ene = a.energy,
        .vit = a.vitality,
        .unspent_stats = a.statpts,
        .unspent_skills = a.newskills,
        .max_life = a.maxhp,
        .max_mana = a.maxmana,
        .max_stamina = a.maxstamina,
        .skill_points_spent = spent,
        .quests_done = done,
        .act6_quest_words = act6,
        .waypoints = wps,
        .player_items = s.items.playerCount(),
        .merc_items = merc_items,
        .merc_type = s.header.merc_type,
        .checksum_ok = d2s.verifyChecksum(bytes),
    };
}

// ---- tests ------------------------------------------------------------------------------------------------------------

const testing = std.testing;

const fake_rec = [_]u8{ 'J', 'M' };

fn fakeMake(ctx: *anyopaque, gpa: std.mem.Allocator, line: []const u8, place: Place) anyerror!ItemRec {
    _ = ctx;
    _ = line;
    _ = place;
    // no real item: two bytes that are not an item, enough to count records in the list
    return .{ .rec = try gpa.dupe(u8, &fake_rec), .n_records = 1, .w = 1, .h = 1 };
}

var dummy: u8 = 0;
const fake_source = ItemSource{ .ctx = &dummy, .make = fakeMake };

test "the spec parses: stats, skills with spaces, quests, merc and item lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parseSpec(arena.allocator(),
        \\# a comment
        \\class paladin
        \\level 99
        \\stats str=auto dex=80 vit=rest
        \\skills blessed hammer=22, vigor=20
        \\skill-left blessed hammer
        \\quests complete
        \\waypoints all
        \\merc act=2 difficulty=nightmare style=defensive level=98
        \\item head | unique:Harlequin Crest;sockets=1;fill=r30
        \\item inv 7,1 | unique:Annihilus
        \\merc-item rhand | runeword=Insight;base=7wc;eth
        \\
    );
    try testing.expectEqual(@as(u8, 3), spec.class);
    try testing.expectEqual(StatSpec.auto, spec.str);
    try testing.expectEqual(@as(u32, 80), spec.dex.value);
    try testing.expectEqual(StatSpec.rest, spec.vit);
    try testing.expectEqualStrings("blessed hammer", spec.skills[0].name);
    try testing.expectEqual(@as(u8, 22), spec.skills[0].level);
    try testing.expect(spec.quests_done and spec.waypoints_all);
    try testing.expectEqual(@as(u8, 98), spec.merc.?.level);
    try testing.expectEqual(Slot.head, spec.items[0].slot);
    try testing.expectEqual(@as(u8, 7), spec.items[1].x);
    try testing.expectEqualStrings("unique:Annihilus", spec.items[1].kit);
    try testing.expectEqual(Slot.rhand, spec.merc_items[0].slot);
    try testing.expectError(error.BadSpec, parseSpec(arena.allocator(), "frobnicate 1"));
    try testing.expectError(error.BadSlot, parseSpec(arena.allocator(), "item ear | item:key"));
    try testing.expectError(error.BadSlot, parseSpec(arena.allocator(), "item inv 10,0 | item:key"));
}

test "a level 99 paladin that did every quest: 505 stat points, 110 skill points" {
    const b = try classBase(testing.allocator, 3, 99);
    try testing.expectEqual(@as(u32, 505), statPoints(b, 99, true));
    try testing.expectEqual(@as(u32, 110), skillPoints(99, true));
    try testing.expectEqual(@as(u32, 490), statPoints(b, 99, false));
    // the class table: 25/20/15/25, life 55 at level 1 and 2 a level, mana 1.5 a level
    try testing.expectEqual(@as(u32, 25), b.str);
    try testing.expectEqual(@as(u32, (55 << 8) + 98 * 8 * 64), b.life);
    try testing.expectEqual(@as(u32, (15 << 8) + 98 * 6 * 64), b.mana);
    try testing.expectEqual(@as(u32, 12), b.life_per_vit); // in fourths: 3 life a point
}

test "compose writes a save that reads back as the spec says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parseSpec(arena.allocator(),
        \\class paladin
        \\level 99
        \\stats str=100 dex=80 vit=rest
        \\skills prayer=1, vigor=20, blessed hammer=22, concentration=20, holy shield=20, blessed aim=20, defiance=1, cleansing=1, might=1, sacrifice=1, smite=1, holy bolt=1, charge=1
        \\skill-left blessed hammer
        \\skill-right concentration
        \\quests complete
        \\waypoints all
        \\merc act=2 difficulty=nightmare style=defensive level=98
        \\item head | x
        \\item inv 7,0 | x
        \\merc-item rhand | x
    );
    const out = try compose(testing.allocator, spec, "TestPally", .{}, fake_source);
    defer testing.allocator.free(out);
    const r = try readback(out);
    try testing.expect(r.checksum_ok);
    try testing.expectEqual(@as(u8, 3), r.class);
    try testing.expectEqual(@as(u8, 99), r.level);
    try testing.expectEqual(@as(u32, 100), r.str);
    try testing.expectEqual(@as(u32, 80), r.dex);
    try testing.expectEqual(@as(u32, 15), r.ene);
    // every point is spent: 505 = (100 - 25) + (80 - 20) + vitality
    try testing.expectEqual(@as(u32, 25 + (505 - 75 - 60)), r.vit);
    try testing.expectEqual(@as(u32, 0), r.unspent_stats);
    // all 110 skill points
    try testing.expectEqual(@as(u32, 108 + 2), r.skill_points_spent);
    try testing.expectEqual(@as(u32, 0), r.unspent_skills);
    // life: 55 + 98 levels x 2 + vitality x 3 + 3 Potions of Life
    try testing.expectEqual(@as(u32, 55 + 196 + (r.vit - 25) * 3 + 60), r.max_life);
    try testing.expectEqual(@as(u32, 15 + 147), r.max_mana);
    try testing.expectEqual(@as(u32, 89 + 98 + (r.vit - 25)), r.max_stamina);
    try testing.expect(r.quests_done);
    try testing.expectEqual(@as(u32, 0), r.act6_quest_words);
    try testing.expectEqual([3]u32{ 39, 39, 39 }, r.waypoints);
    try testing.expectEqual(@as(u16, 2), r.player_items);
    try testing.expectEqual(@as(u16, 1), r.merc_items);
    // Hireling.txt: Act 2, Nightmare, Defensive (Holy Freeze) is id 10
    try testing.expectEqual(@as(u16, 10), r.merc_type);

    // the left and right skills the header names are Skills.txt ids
    const s = try sections.parse(out);
    try testing.expectEqual(@as(u32, 112), s.header.left_skill);
    try testing.expectEqual(@as(u32, 113), s.header.right_skill);
    // class order: Blessed Hammer is the 17th of the paladin's 30
    try testing.expectEqual(@as(u8, 22), s.skills.levels[16]);
}

test "too many points are refused, and unspent ones stay unspent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const over = try parseSpec(arena.allocator(), "class paladin\nlevel 99\nstats vit=700\nquests complete\n");
    try testing.expectError(error.TooManyStatPoints, compose(testing.allocator, over, "X", .{}, fake_source));
    const skills_over = try parseSpec(arena.allocator(), "class paladin\nlevel 10\nskills vigor=20\n");
    try testing.expectError(error.TooManySkillPoints, compose(testing.allocator, skills_over, "X", .{}, fake_source));
    const keep = try parseSpec(arena.allocator(), "class paladin\nlevel 10\nskills vigor=3\n");
    const out = try compose(testing.allocator, keep, "X", .{}, fake_source);
    defer testing.allocator.free(out);
    const r = try readback(out);
    try testing.expectEqual(@as(u32, 45), r.unspent_stats);
    try testing.expectEqual(@as(u32, 6), r.unspent_skills);
    try testing.expectError(error.UnknownSkill, compose(testing.allocator, try parseSpec(arena.allocator(), "class paladin\nskills fireball=1\n"), "X", .{}, fake_source));
    // a sorceress's skill is not a paladin's
    try testing.expectError(error.UnknownSkill, compose(testing.allocator, try parseSpec(arena.allocator(), "class paladin\nskills fire ball=1\n"), "X", .{}, fake_source));
}

test "mercenary experience is the engine's curve" {
    try testing.expectEqual(@as(u32, 120 * 98 * 98 * 99), mercExperience(120, 98));
}

test "the example spec makes a level 99 paladin with its gear, and the same bytes every time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try parseSpec(arena.allocator(), @embedFile("testdata/paladin.kit"));

    var maker = try kititem.Maker.init(testing.allocator, .expansion, 0x5eed);
    defer maker.deinit();
    const out = try compose(testing.allocator, spec, "FuddrPally", .{ .created = 1_790_000_000 }, kitSource(&maker));
    defer testing.allocator.free(out);

    const r = try readback(out);
    try testing.expect(r.checksum_ok);
    try testing.expectEqual(@as(u32, 128), r.str); // the eth Berserker Axe asks for 138, ethereal 10 less
    try testing.expectEqual(@as(u32, 80), r.dex);
    try testing.expectEqual(@as(u32, 25 + 505 - 103 - 60), r.vit);
    try testing.expectEqual(@as(u32, 110), r.skill_points_spent);
    try testing.expectEqual(@as(u32, 0), r.act6_quest_words);
    try testing.expectEqual(@as(u16, 10), r.merc_type);
    try testing.expectEqual(@as(?u8, null), engineRefusal(out, "FuddrPally"));
    const parsed = try sections.parse(out);
    try testing.expectEqual(@as(?ItemFault, null), itemListFault(parsed.items.bytes));
    try testing.expectEqual(@as(u16, 18), parsed.items.playerCount()); // twelve worn, six in the grid; the sockets are not counted
    try testing.expectEqual(@as(?u8, 7), engineRefusal(out, "Other"));
    const bad = try testing.allocator.dupe(u8, out);
    defer testing.allocator.free(bad);
    bad[0x24] |= 1;
    std.mem.writeInt(u32, bad[0xc..0x10], 0, .little);
    std.mem.writeInt(u32, bad[0xc..0x10], d2s.checksum(bad), .little);
    try testing.expectEqual(@as(?u8, 2), engineRefusal(bad, "FuddrPally"));
    // a count that includes the socketed items (what the writer used to put) runs the engine's loop into the corpse list
    const swollen = try testing.allocator.dupe(u8, parsed.items.bytes);
    defer testing.allocator.free(swollen);
    std.mem.writeInt(u16, swollen[2..4], 39, .little);
    try testing.expect(itemListFault(swollen) != null);

    // every record of both lists parses back, in the places the spec names
    const s = try sections.parse(out);
    var it = s.items.iterator();
    var equipped: u32 = 0;
    var eth: u32 = 0;
    var runewords: u32 = 0;
    var grid: u32 = 0;
    while (it.next()) |item| {
        if (item.dest == 1) {
            equipped += 1;
            try testing.expectEqual(@as(u16, item.body_loc), item.x);
        }
        if (item.dest == 0 and item.page_raw == 1) grid += 1;
        if (item.flags & wire.flag.ETHEREAL != 0) eth += 1;
        if (item.flags & wire.flag.RUNEWORD != 0) runewords += 1;
    }
    try testing.expectEqual(@as(u32, 12), equipped); // ten worn and two on the switch
    try testing.expectEqual(@as(u32, 6), grid);
    try testing.expectEqual(@as(u32, 3), eth);
    try testing.expectEqual(@as(u32, 5), runewords);
    try testing.expectEqual(@as(u16, 3), r.merc_items); // carried: the socketed ones are not counted

    // the same spec, name, time and seed: the same bytes
    var maker2 = try kititem.Maker.init(testing.allocator, .expansion, 0x5eed);
    defer maker2.deinit();
    const again = try compose(testing.allocator, spec, "FuddrPally", .{ .created = 1_790_000_000 }, kitSource(&maker2));
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, out, again);
}
