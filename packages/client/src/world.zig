//! Client-side world model reconstructed from the D2GS server->client stream.
//!
//! The real client keeps units in `ServerSideUnitHashTables` keyed by (type, guid) and looks
//! them up with UNITS_FindClientSideUnit @0x00463990. We keep the same shape: a map keyed by
//! (unitType << 32 | guid). Packets mutate this model; nothing here talks to a renderer.
//!
//! This is the mirror any headless client needs — a bot, a proxy, a capture analyser — which is
//! why it sits in libd2 rather than inside one of them. It decodes with `d2-net`'s packet types
//! and `d2-core`'s item bit-stream; the only thing it adds is memory.
//!
//! Field offsets for each packet are taken from the 1.14d handlers (docs/re/sc-packets.md).
//! Handlers whose exact layout is still being recovered are logged but not yet applied.

const std = @import("std");
const builtin = @import("builtin");
const packets = @import("d2-net").sc;
const core = @import("d2-core");
const objects = @import("objects.zig");
const table = @import("d2-net").sc_table;
const BitReader = core.WireBitReader;
const item_mod = core.wire;
pub const Item = item_mod.Item;

/// Always-on world log line, but silent under the test runner (its stdio is the IPC channel).
fn note(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}

pub const UnitType = enum(u8) {
    player = 0,
    monster = 1,
    object = 2,
    missile = 3,
    item = 4,
    warp = 5,
    _,
};

pub const Unit = struct {
    utype: u8,
    guid: u32,
    x: u16 = 0,
    y: u16 = 0,
    life: u8 = 0, // 0..128 percent-ish, as the wire carries it (0xAC seed, 0xAB updates)
    class_id: u16 = 0, // eD2MonStatsId for monsters / classId for warps+objects
    is_warp: bool = false, // came in via 0x09 AssignLevelWarp (a clickable inter-level warp)
    life_abs: u16 = 0, // absolute hitpoints, when a stat packet (0x9E..0xA2) states one
    state: u8 = 0, // last eD2States applied via 0xA8/0xAA
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,

    pub fn nameSlice(self: *const Unit) []const u8 {
        return self.name[0..self.name_len];
    }
};

fn unitKey(utype: u8, guid: u32) u64 {
    return (@as(u64, utype) << 32) | guid;
}

/// Where an item is. This is the item bit-stream's own `dest` field (3 bits, read by d2-core's
/// item parser), not a guess from the packet's action code — the server states the destination
/// with every move, so the action only ever has to tell us that the item LEFT.
pub const Where = enum(u8) {
    stored = 0, // an inventory / stash / cube page, at (x,y) on that page
    equipped = 1, // worn, in `body_loc`
    belt = 2,
    ground = 3,
    cursor = 4,
    dropped = 5, // mid-drop: on the ground as far as anyone else is concerned
    socket = 6,
    /// Taken out of the world entirely (picked up by someone, removed from a container).
    gone = 0xff,

    pub fn from(dest: u8) Where {
        return switch (dest) {
            0 => .stored,
            1 => .equipped,
            2 => .belt,
            3 => .ground,
            4 => .cursor,
            5 => .dropped,
            6 => .socket,
            else => .gone,
        };
    }

    pub fn onGround(self: Where) bool {
        return self == .ground or self == .dropped;
    }
};

/// A party-roster entry: the other players as the party panel knows them. Filled by the
/// `Roster::*` family (0x5B, 0x65, 0x75, 0x7F, 0x8B, 0x8C, 0x8D).
pub const RosterEntry = struct {
    guid: u32,
    party_id: u16 = 0,
    in_party: bool = false,
    hostile_to: u32 = 0,
    hostile_flags: u16 = 0,
    x: i16 = 0,
    y: i16 = 0,
    area: u16 = 0,
    life: u16 = 0,
    arena_score: i32 = 0,
};

/// An item and the answer to "whose, and where". The engine keeps these in the owning unit's
/// inventory list; a client that only watches the stream knows the item by GUID, so that is the key.
pub const OwnedItem = struct {
    item: Item,
    where: Where = .ground,
    /// The unit whose container it is. 0 while it lies in the world.
    owner: u32 = 0,
};

// A few common eD2UnitStat ids for readable stat logging (full set is in ItemStatCost).
fn statName(id: u16) []const u8 {
    return switch (id) {
        0 => "strength",
        1 => "energy",
        2 => "dexterity",
        3 => "vitality",
        7 => "maxhp",
        9 => "maxmana",
        11 => "maxstamina",
        12 => "level",
        13 => "experience",
        14 => "gold",
        15 => "goldbank",
        else => "stat",
    };
}

pub const World = struct {
    gpa: std.mem.Allocator,
    units: std.AutoHashMap(u64, Unit),
    /// Every item the stream has described, by GUID — on the floor, worn, in a container or on a
    /// cursor. `Where` says which.
    items: std.AutoHashMap(u32, OwnedItem),
    player_stats: std.AutoHashMap(u16, i32), // local player stats by eD2UnitStat id (0x1d/1e/1f)
    /// The party roster, by player GUID.
    roster: std.AutoHashMap(u32, RosterEntry),
    /// Per-opcode tally of what was applied and what was seen but not modelled, so "we parse the
    /// stream" is a number rather than a claim. See `coverage`.
    applied: [256]u32 = [_]u32{0} ** 256,
    ignored: [256]u32 = [_]u32{0} ** 256,
    /// Packets the engine defines but which carry no world state — recognised, deliberately not
    /// mirrored. Counted apart from `applied` so the split stays visible.
    acknowledged: [256]u32 = [_]u32{0} ** 256,

    // level / world identity (0x01 GameFlags, 0x03 LoadAct)
    difficulty: u8 = 0,
    expansion: bool = false,
    ladder: bool = false,
    act: u8 = 0,
    level_id: u16 = 0, // nArea from 0x03 LoadAct / eLevel from 0x07 MapReveal
    map_seed: u32 = 0, // DRLG seed for the current act (0x03 LoadAct)
    automap: u32 = 0, // 0x03 LoadAct nAutomap

    /// The character we logged in as. Set it before joining and the model can tell OUR player
    /// unit from everyone else's — including stale ghosts of the same character left in the game
    /// by a client that dropped its socket without leaving. Without it the model falls back to
    /// "the first player seen", which is only right when we are the first.
    local_name: [16]u8 = [_]u8{0} ** 16,
    local_name_len: u8 = 0,
    /// A player whose name matched `local_name` has been seen, so first-seen no longer applies.
    local_name_matched: bool = false,

    loaded: bool = false, // act data fully streamed (0x04 LoadComplete)
    in_game: bool = true, // cleared by 0x06 GameExit
    local_player_guid: ?u32 = null,
    local_hp: u16 = 0, // integer HP of the local player (0x18/0x95)
    local_mp: u16 = 0,
    local_stamina: u16 = 0,
    verbose: bool = false,

    // Kill-confirm bookkeeping for the driver: the last monster GUID removed via 0x0A
    // RemoveObject (the standalone's death path) and its last-seen hp% before removal.
    last_removed_monster: ?u32 = null,

    /// The act's activated-waypoint bitfield (0x60).
    waypoint_bits: u32 = 0,

    /// Objects.txt classes named "Waypoint", parsed on first use. Owned.
    waypoint_class: []bool = &.{},

    pub fn init(gpa: std.mem.Allocator) World {
        return .{
            .gpa = gpa,
            .units = std.AutoHashMap(u64, Unit).init(gpa),
            .items = std.AutoHashMap(u32, OwnedItem).init(gpa),
            .player_stats = std.AutoHashMap(u16, i32).init(gpa),
            .roster = std.AutoHashMap(u32, RosterEntry).init(gpa),
        };
    }

    /// Name the character we are playing, so `local_player_guid` latches onto the right unit.
    pub fn expectLocalPlayer(self: *World, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, self.local_name.len));
        @memcpy(self.local_name[0..n], name[0..n]);
        self.local_name_len = n;
    }

    fn isLocalName(self: *const World, name: []const u8) bool {
        if (self.local_name_len == 0) return false;
        return std.ascii.eqlIgnoreCase(self.local_name[0..self.local_name_len], name);
    }

    pub fn deinit(self: *World) void {
        self.units.deinit();
        self.items.deinit();
        self.player_stats.deinit();
        self.roster.deinit();
        if (self.waypoint_class.len != 0) self.gpa.free(self.waypoint_class);
    }

    fn upsert(self: *World, utype: u8, guid: u32) !*Unit {
        const gop = try self.units.getOrPut(unitKey(utype, guid));
        if (!gop.found_existing) gop.value_ptr.* = .{ .utype = utype, .guid = guid };
        return gop.value_ptr;
    }

    /// Feed one framed S->C packet (starting at the opcode byte). Compressed 0xAE containers
    /// must be decompressed and their inner packets fed here individually by the caller.
    pub fn apply(self: *World, buf: []const u8) void {
        if (buf.len == 0) return;
        const op = buf[0];
        const cat = packets.info(op).cat;
        switch (op) {
            // Load / session state (Incoming0x02/0x04/0x05/0x06).
            0x02 => self.loaded = false, // LoadSuccess: act data accepted, world streaming starts
            0x04 => self.loaded = true, // LoadComplete
            0x05 => self.loaded = false, // UnloadComplete
            0x06 => self.in_game = false, // GameExit
            0x00 => {}, // the engine's own handler is a bare return (Return_0045c900)
            0x0b => {}, // HandShake: pure protocol, no world state
            0x76 => {}, // TEXT_ClearUnitHoverText: dismisses a hover label, purely visual

            0x01 => self.applyGameFlags(buf),
            0x03 => self.applyLoadAct(buf),
            0x07 => self.applyMapReveal(buf),
            0x08 => {}, // MapHide: automap only
            0x09 => self.applyAssignWarp(buf),
            0x0a => self.applyRemove(buf),
            0x0d => self.applyUnitStop(buf), // PlayerStop: mode + roster hp%, no position
            0x0f, 0x10 => self.applyPlayerMove(buf), // dest x@0xC y@0xE
            0x15 => self.applyReassign(buf),
            0x18 => self.applyLife(buf, true), // has hp/mp regen fields

            // Incoming0x19_ItemPageUpdate — a misnomer in the symbol table: the handler calls
            // STATLIST_SetUnitStat. 0x19..0x1C accumulate gold/experience, 0x1D..0x1F set an
            // arbitrary stat on the LOCAL player at a width the opcode picks.
            0x19 => self.addPlayerStat(STAT_GOLD, self.readTail(buf, 1, 1)),
            0x1a => self.addPlayerStat(STAT_EXPERIENCE, self.readTail(buf, 1, 1)),
            0x1b => self.addPlayerStat(STAT_EXPERIENCE, self.readTail(buf, 1, 2)),
            0x1c => self.setPlayerStat(STAT_EXPERIENCE, self.readTail(buf, 1, 4)),
            0x1d => self.applyStat(buf, 1),
            0x1e => self.applyStat(buf, 2),
            0x1f => self.applyStat(buf, 4),
            0x20 => self.applyOtherPlayerStat(buf), // guid@1, stat@5, value i32@6

            0x21, 0x22, 0x23, 0x7b, 0x94 => {}, // skill set/quantity/hand/hotkey/list: not modelled
            0x27 => {}, // OverheadText: a speech bubble
            0x28, 0x29 => {}, // NpcInteract / quest menu: UI_HandleNpcInteractionPacket
            0x5a, 0x5e => {}, // event + message text
            0x5f => {}, // portal flags on the local player
            0x7e => {}, // room-local refresh
            0x82 => {}, // town-portal ownership (source object, owner, destination level)

            // The roster: who is in the party, where they are, and who is hostile. Every one of
            // these is a `Roster::*` call in the client, and together they are the party panel.
            0x65 => self.rosterField(buf, .arena_score),
            0x75 => self.rosterField(buf, .party_info),
            0x7f => self.rosterField(buf, .hp_and_area),
            0x81 => {}, // roster merc info (seed/name/class) — no merc in this model yet
            0x8b => self.rosterField(buf, .in_party),
            0x8c => self.rosterField(buf, .hostile),
            0x8d => self.rosterField(buf, .party_id),

            0x60 => self.applyWaypointBits(buf), // which waypoints are activated for this act
            0x47, 0x48 => {}, // RecalcEquippedItems: a client-side recompute, nothing to mirror
            0x51 => self.applyCreateObject(buf),
            0x53 => {}, // DRLGENV_InitializeEnvironment: weather/light, not unit state
            0x59 => self.applyCreatePlayer(buf),
            0x5b => self.applyRosterPlayer(buf),
            0x67 => self.applyUnitStop(buf), // MonsterStop: same shape, mode + target
            0x68 => self.applyMonsterMove(buf, 6, 8), // MonsterBeginCast x@6 y@8
            0x6b, 0x6c => self.applyMonsterMove(buf, 0x0c, 0x0e), // MonsterBeginCastWalk / CastStationary
            0x6d => self.applyUnitMoveTo(buf), // PATH_MoveUnitToPoint x@5 y@7
            0x95 => self.applyLife(buf, false),
            0x96 => self.applyLife(buf, false), // same bit-packed shape; also carries stamina

            0x9c => self.applyItemAction(buf), // into the world / a container
            0x9d => self.applyItemAction(buf), // out of a container: equip, unequip, socket, swap
            0x9e, 0x9f, 0xa0, 0xa1, 0xa2 => self.applyMonsterStat(buf),
            0xa8, 0xaa => self.applyUnitState(buf),
            0xab => self.applyHpPercent(buf), // 0xAB UnitHpPercent — monster health-bar update
            0xac => self.applyCreateMonster(buf),
            else => {
                // Every remaining opcode inside the engine's own dispatch table is a packet we
                // recognise but that carries no world state to mirror (UI, sound, quest chatter).
                // Acknowledging it here is what makes coverage meaningful: an opcode OUTSIDE the
                // table is a desync or a private extension, and that is the only thing left that
                // should ever be reported as unhandled.
                if (table.handler(op) == null) {
                    self.ignored[op] +%= 1;
                    self.logUnhandled(op, cat, buf);
                    return;
                }
                self.acknowledged[op] +%= 1;
                return; // acknowledged, not applied — do not also count it below
            },
        }
        self.applied[op] +%= 1;
    }

    /// Smallest item bit-stream that can describe an item: flags(32) + version(10) + dest(3) plus
    /// the position block — under six bytes there is nothing to decode.
    /// (`ExtractItemDetails(pBytes + off, pBytes[2] - off, ...)` is the engine's own call.)
    const MIN_ITEM_BODY: usize = 6;

    // eD2UnitStat ids the 0x19..0x1C accumulators target.
    const STAT_EXPERIENCE: u16 = 13;
    const STAT_GOLD: u16 = 14;

    /// Little-endian integer of `width` bytes at `off`, or 0 when the packet is short.
    fn readTail(self: *World, buf: []const u8, off: usize, width: usize) i32 {
        _ = self;
        if (buf.len < off + width) return 0;
        return switch (width) {
            1 => buf[off],
            2 => std.mem.readInt(u16, buf[off..][0..2], .little),
            4 => @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little)),
            else => 0,
        };
    }

    fn setPlayerStat(self: *World, id: u16, value: i32) void {
        self.player_stats.put(id, value) catch {};
    }

    fn addPlayerStat(self: *World, id: u16, delta: i32) void {
        const cur = self.player_stats.get(id) orelse 0;
        self.player_stats.put(id, cur +% delta) catch {};
    }

    // 0x01 GameFlags: [id][difficulty u8][arenaFlags u32][expansion u8][ladder u8]
    fn applyGameFlags(self: *World, buf: []const u8) void {
        if (buf.len < 8) return;
        self.difficulty = buf[1];
        self.expansion = buf[6] != 0;
        self.ladder = buf[7] != 0;
        if (self.verbose)
            std.debug.print("  world: GameFlags diff={d} expansion={} ladder={}\n", .{ self.difficulty, self.expansion, self.ladder });
    }

    // 0x03 LoadAct @0045C8E0: [id][act u8][mapSeed u32@0x02][nArea u16@0x06][nAutomap u32@0x08].
    // CLIENT_AllocAct(nAct, nMapSeed, nAutomap, nArea). No object seed here (D2MOO diverges).
    fn applyLoadAct(self: *World, buf: []const u8) void {
        if (buf.len < 12) return;
        self.act = buf[1];
        self.map_seed = std.mem.readInt(u32, buf[2..6], .little);
        self.level_id = std.mem.readInt(u16, buf[6..8], .little);
        self.automap = std.mem.readInt(u32, buf[8..12], .little);
        note("  world: LoadAct act={d} area={d} mapSeed=0x{x:0>8}\n", .{ self.act, self.level_id, self.map_seed });
    }

    // 0x07 MapReveal @0045CAB0: [id][nX u16][nY u16][eLevel u8] -> AddRoomData(act, eLevel, x, y).
    fn applyMapReveal(self: *World, buf: []const u8) void {
        if (buf.len < 6) return;
        self.level_id = buf[5];
        if (self.verbose) {
            const x = std.mem.readInt(u16, buf[1..3], .little);
            const y = std.mem.readInt(u16, buf[3..5], .little);
            std.debug.print("  world: MapReveal level={d} at ({d},{d})\n", .{ self.level_id, x, y });
        }
    }

    // 0x09 AssignLevelWarp @0045CB90: [id][type u8][guid u32][classId u8][x u16][y u16].
    fn applyAssignWarp(self: *World, buf: []const u8) void {
        if (buf.len < 11) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.class_id = buf[6]; // warp-type graphic (Levels.txt Vis/Warp column)
        u.is_warp = true; // 0x09-origin: a clickable inter-level warp (wire unit_type is "object")
        u.x = std.mem.readInt(u16, buf[7..9], .little);
        u.y = std.mem.readInt(u16, buf[9..11], .little);
        note("  world: warp guid=0x{x} type={d} at ({d},{d})\n", .{ u.guid, u.class_id, u.x, u.y });
    }

    // 0x15 ReassignPlayer @0045D160: [id][type u8][guid u32][x u16@0x06][y u16@0x08][moveFlag u8].
    fn applyReassign(self: *World, buf: []const u8) void {
        if (buf.len < 11) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.x = std.mem.readInt(u16, buf[6..8], .little);
        u.y = std.mem.readInt(u16, buf[8..10], .little);
        if (self.verbose)
            std.debug.print("  world: reassign type={d} guid=0x{x} -> ({d},{d})\n", .{ u.utype, u.guid, u.x, u.y });
    }

    // 0x51 CreateObject @0045CBD0: [id][type u8][guid u32][classId u16@0x06][x u16@0x08][y u16@0x0A][state u8][interaction u8].
    // The classId is the whole identity of an object — a waypoint, a chest and a stack of barrels
    // are the same packet with a different number — so dropping it, as this used to, makes every
    // object in the world anonymous and unfindable.
    fn applyCreateObject(self: *World, buf: []const u8) void {
        const p = packets.CreateObject.decode(buf) catch return;
        const u = self.upsert(p.unit_type, p.guid) catch return;
        u.class_id = p.class_id;
        u.x = p.x;
        u.y = p.y;
        if (self.verbose)
            std.debug.print("  world: CreateObject class={d} guid=0x{x} at ({d},{d})\n", .{ u.class_id, u.guid, u.x, u.y });
    }

    // 0x59 UNIT_CreatePlayer @0045E4C0: [id][guid u32@0x01][classId u8@0x05][name[16]@0x06][x u16@0x16][y u16@0x18].
    fn applyCreatePlayer(self: *World, buf: []const u8) void {
        if (buf.len < 26) return;
        const guid = std.mem.readInt(u32, buf[1..5], .little);
        const u = self.upsert(@intFromEnum(UnitType.player), guid) catch return;
        const raw = buf[6..22];
        var nlen: u8 = 0;
        while (nlen < 16 and raw[nlen] != 0) nlen += 1;
        @memcpy(u.name[0..16], raw);
        u.name_len = nlen;
        u.x = std.mem.readInt(u16, buf[22..24], .little);
        u.y = std.mem.readInt(u16, buf[24..26], .little);
        // Prefer the character we said we are; latching purely on arrival order would pick a ghost
        // of ourselves when one is already in the game.
        //
        // But a name we never see is worse than no name at all: some servers name the character
        // from their own records rather than from what we asked for in GAMELOGON, and a client that
        // insists on its own spelling then never identifies itself and cannot move, act, or even
        // say where it is standing. So first-seen is the provisional answer whatever we were told,
        // and an exact name match overrides it whenever one turns up.
        if (self.isLocalName(u.nameSlice())) {
            self.local_player_guid = guid;
            self.local_name_matched = true;
        } else if (self.local_player_guid == null and !self.local_name_matched) {
            self.local_player_guid = guid;
        }
        note("  world: CreatePlayer \"{s}\" guid=0x{x} at ({d},{d})\n", .{ u.nameSlice(), guid, u.x, u.y });
    }

    // 0x18 Life @0045D9B0 / 0x95 PlayerJoin @0045DB20: bit-packed (Fog::BitBuffer, LSB-first).
    // hp/mp/stamina u15 each (engine keeps them <<8 as 1/256 fixed-point), then (0x18 only) two
    // u7 regen fields, then absolute tile x/y u16 + signed u8 dx/dy deltas. Local player only —
    // no guid on the wire. Field order/widths per RE (docs/re/sc-packets.md); bit direction is
    // LSB-first per D2 convention (bitreader.zig verified), packet field widths not yet capture-verified.
    fn applyLife(self: *World, buf: []const u8, has_regen: bool) void {
        const min: usize = if (has_regen) 15 else 13;
        if (buf.len < min) return;
        var r = BitReader.init(buf);
        _ = r.read(8); // opcode byte
        self.local_hp = @intCast(r.read(15));
        self.local_mp = @intCast(r.read(15));
        self.local_stamina = @intCast(r.read(15));
        if (has_regen) {
            _ = r.read(7); // hp regen
            _ = r.read(7); // mp regen
        }
        const x: u16 = @intCast(r.read(16));
        const y: u16 = @intCast(r.read(16));
        if (self.local_player_guid) |g| {
            if (self.units.getPtr(unitKey(@intFromEnum(UnitType.player), g))) |u| {
                u.x = x;
                u.y = y;
            }
        }
        note("  world: life hp={d} mp={d} stam={d} at ({d},{d})\n", .{ self.local_hp, self.local_mp, self.local_stamina, x, y });
    }

    // 0x1D/0x1E/0x1F stat update (shared handler @0045D780): [id][statId u8][value] where the
    // value width (1/2/4 bytes) is chosen by the opcode. Sets a local-player stat by eD2UnitStat
    // id. hp/mana/stamina are stored ×256 (fixed point) — see statName/dumpSummary.
    fn applyStat(self: *World, buf: []const u8, width: usize) void {
        if (buf.len < 2 + width) return;
        const stat_id: u16 = buf[1];
        const value: i32 = switch (width) {
            1 => buf[2],
            2 => std.mem.readInt(u16, buf[2..4], .little),
            4 => @bitCast(std.mem.readInt(u32, buf[2..6], .little)),
            else => return,
        };
        self.player_stats.put(stat_id, value) catch {};
        if (self.verbose)
            std.debug.print("  world: stat {s}(#{d}) = {d}\n", .{ statName(stat_id), stat_id, value });
    }

    // 0x0A RemoveObject @0045CC10: [id][unitType u8][guid u32].
    fn applyRemove(self: *World, buf: []const u8) void {
        if (buf.len < 6) return;
        const utype = buf[1];
        const guid = std.mem.readInt(u32, buf[2..6], .little);
        if (utype == @intFromEnum(UnitType.monster)) self.last_removed_monster = guid;
        _ = self.units.remove(unitKey(utype, guid));
        if (self.verbose)
            std.debug.print("  world: remove type={d} guid=0x{x}\n", .{ utype, guid });
    }

    // 0x0F PlayerMove / 0x10 CharacterToObject @0045CD40/90: fpU (unit pre-resolved by the
    // dispatcher from type@0x01 guid@0x02); destination is a raw u16 x@0x0C y@0x0E. The moving
    // unit is a player. Guid offset follows the type@1/guid@2 convention (unconfirmed in-handler).
    fn applyPlayerMove(self: *World, buf: []const u8) void {
        if (buf.len < 16) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.x = std.mem.readInt(u16, buf[0x0c..0x0e], .little);
        u.y = std.mem.readInt(u16, buf[0x0e..0x10], .little);
    }

    // 0x68/0x6B/0x6C monster movement (fpU): monster convention has guid@0x01 and NO type byte
    // (like 0xAC). Destination x/y offsets differ per opcode, passed in by the caller.
    fn applyMonsterMove(self: *World, buf: []const u8, xoff: usize, yoff: usize) void {
        if (buf.len < yoff + 2) return;
        const u = self.upsert(@intFromEnum(UnitType.monster), std.mem.readInt(u32, buf[1..5], .little)) catch return;
        u.x = std.mem.readInt(u16, buf[xoff..][0..2], .little);
        u.y = std.mem.readInt(u16, buf[yoff..][0..2], .little);
    }

    // 0xAC create/assign monster @0045F190: byte-aligned header [id][guid u32@1][monstat i16@5]
    // [x u16@7][y u16@9][hpPct u8@0xB][pktLen u8@0xC]; the trailing statlist (from +0xD) is a
    // bitstream we don't parse yet. Header alone gives the monster's identity + spawn position.
    fn applyCreateMonster(self: *World, buf: []const u8) void {
        if (buf.len < 13) return;
        const guid = std.mem.readInt(u32, buf[1..5], .little);
        const u = self.upsert(@intFromEnum(UnitType.monster), guid) catch return;
        const monstat = std.mem.readInt(i16, buf[5..7], .little);
        u.class_id = @bitCast(monstat);
        u.x = std.mem.readInt(u16, buf[7..9], .little);
        u.y = std.mem.readInt(u16, buf[9..11], .little);
        u.life = buf[0x0b];
        if (self.verbose)
            std.debug.print("  world: CreateMonster monstat={d} guid=0x{x} at ({d},{d})\n", .{ monstat, guid, u.x, u.y });
    }

    // 0xAB UnitHpPercent @ UnitQueuePacket0xAB: [op u8][eUnitType u8][guid u32][hpPct u8] (7).
    // The 128-scale health-bar update the standalone GS broadcasts as a monster takes damage
    // (broadcastHpChanges @game_instance.zig). Keeps the target unit's life% current so the
    // driver can log HP; the kill itself is confirmed by the follow-up 0x0A RemoveObject.
    fn applyHpPercent(self: *World, buf: []const u8) void {
        if (buf.len < 7) return;
        const utype = buf[1];
        const guid = std.mem.readInt(u32, buf[2..6], .little);
        if (self.units.getPtr(unitKey(utype, guid))) |u| u.life = buf[6];
        if (self.verbose)
            std.debug.print("  world: hp% type={d} guid=0x{x} = {d}/128\n", .{ utype, guid, buf[6] });
    }

    // 0x9C / 0x9D item action @0045EB10: [id][action u8][pktLen u8][reserved u8][itemGUID u32@0x04]
    // [item bitstream @0x08, len pktLen-8]. Both opcodes carry the same shape; the split is which
    // half of the `HandleItem*` family the client dispatches to. 0x9C is an item arriving somewhere
    // (ground, container, belt, cursor, quantity change); 0x9D is one leaving a container — equip,
    // unequip, swap, socket, weapon-switch.
    //
    // The destination is NOT inferred from the action code: the bit-stream states it in `dest`
    // every time, which is why the same handler serves both opcodes and all ~20 actions. The action
    // only has to answer whether the item left the world.
    //
    // 0x9C action 1 is HandleItemPickedFromGround: somebody took it. Whether it ends up on our
    // cursor or in another player's inventory is not on the wire, so it is `.gone` — the honest
    // answer, and the caller can still see the item's last known state.
    fn applyItemAction(self: *World, buf: []const u8) void {
        if (buf.len < 8) return;
        const op = buf[0];
        const action = buf[1];
        const guid = std.mem.readInt(u32, buf[4..8], .little);

        if (op == 0x9c and action == 0x01) {
            _ = self.units.remove(unitKey(@intFromEnum(UnitType.item), guid));
            if (self.items.getPtr(guid)) |owned| owned.where = .gone;
            return;
        }

        // The two opcodes start their item bit-stream at DIFFERENT offsets, and this is the one
        // thing about them that is easy to get wrong. Every 0x9C handler extracts from
        // `pBytes + 8` (HandleItemAddToGround, HandleItemSwapInBelt); every 0x9D handler extracts
        // from `pBytes + 0xD` (HandleItemRemoveFromContainer / Equip / Unequip / SwapBodyItem /
        // IndirectSwapBodyItem). Reading 0x9D at +8 decodes five bytes of header as item data and
        // yields a nonsense `dest` for every one of them — which is how a level-91 character came
        // out with nothing equipped and 25 items on the cursor.
        const body_at: usize = if (op == 0x9d) 0x0d else 8;
        if (buf.len <= body_at) return;
        const body = buf[body_at..];
        if (body.len < MIN_ITEM_BODY) {
            if (self.items.getPtr(guid)) |owned| {
                if (op == 0x9d) owned.where = .gone; // left its container; the destination follows
            }
            return;
        }

        var r = BitReader.init(body);
        const it = item_mod.parse(&r);
        const where = Where.from(it.dest);
        const owner: u32 = if (where.onGround()) 0 else (self.local_player_guid orelse 0);
        self.items.put(guid, .{ .item = it, .where = where, .owner = owner }) catch {};

        // Only an item lying in the world is a unit you can walk to and click.
        if (where.onGround()) {
            const u = self.upsert(@intFromEnum(UnitType.item), guid) catch return;
            u.x = it.x;
            u.y = it.y;
            note("  world: item \"{s}\" {s}{s} guid=0x{x} at ({d},{d}) stats={d}\n", .{
                it.codeSlice(), @tagName(it.quality), if (it.ethereal()) " eth" else "",
                guid,           it.x,                 it.y,                          it.n_stats,
            });
        } else {
            _ = self.units.remove(unitKey(@intFromEnum(UnitType.item), guid));
            if (self.verbose)
                std.debug.print("  world: item \"{s}\" {s} -> {s}{s} guid=0x{x}\n", .{
                    it.codeSlice(),      @tagName(it.quality), @tagName(where),
                    if (where == .equipped) " slot" else "", guid,
                });
        }
    }

    // 0x0D PlayerStop / 0x67 MonsterStop: the unit comes to rest. `[id][unitType u8][guid u32]
    // [mode u8@0x06 (0x0D) / @0x05 (0x67)]…` — note NEITHER carries a position, so this only ends
    // the unit's motion; where it stopped arrives separately. 0x0D's byte 0x0C is the roster
    // health percent (SetRosterPlayerHpPercent), 0x67's is the monster's.
    fn applyUnitStop(self: *World, buf: []const u8) void {
        if (buf.len < 13) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.life = buf[0x0c];
    }

    // 0x6D: PATH_MoveUnitToPoint(pUnit, x@5, y@7) with a direction byte at 9. The unit is the one
    // the dispatcher resolved from type@1/guid@2.
    fn applyUnitMoveTo(self: *World, buf: []const u8) void {
        if (buf.len < 10) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.x = std.mem.readInt(u16, buf[5..7], .little);
        u.y = std.mem.readInt(u16, buf[7..9], .little);
    }

    // 0x20: STATLIST_SetUnitStat on ANOTHER player — `[id][guid u32@1][statId u8@5][value i32@6]`.
    // Only the local player's stats are tracked as a table, so this lands on the unit's life when
    // it is a life stat and is otherwise recorded as seen.
    fn applyOtherPlayerStat(self: *World, buf: []const u8) void {
        if (buf.len < 10) return;
        const guid = std.mem.readInt(u32, buf[1..5], .little);
        if (self.local_player_guid) |me| {
            if (guid == me) self.setPlayerStat(buf[5], @bitCast(std.mem.readInt(u32, buf[6..10], .little)));
        }
    }

    // 0x9E..0xA2 (Incoming0x9Eto0xA2): a MONSTER's stat. `[id][statId u8@1][guid u32@2][value@6]`,
    // width and set-vs-add chosen by the opcode: 9E u8 set, 9F u16 set, A0 u32 set, A1 u8 add,
    // A2 u16 add. The unit is looked up as UNIT_MONSTER specifically.
    fn applyMonsterStat(self: *World, buf: []const u8) void {
        const width: usize = switch (buf[0]) {
            0x9e, 0xa1 => 1,
            0x9f, 0xa2 => 2,
            0xa0 => 4,
            else => return,
        };
        if (buf.len < 6 + width) return;
        const stat_id = buf[1];
        const guid = std.mem.readInt(u32, buf[2..6], .little);
        const u = self.units.getPtr(unitKey(@intFromEnum(UnitType.monster), guid)) orelse return;
        const value = self.readTail(buf, 6, width);
        // The only monster stat this model carries is life, and the health bar wants a percentage,
        // which 0xAB delivers separately — so an absolute life value is recorded, not converted.
        if (stat_id == STAT_LIFE and value >= 0) u.life_abs = @intCast(@min(value, std.math.maxInt(u16)));
    }

    const STAT_LIFE: u8 = 6; // eD2UnitStat UNITSTAT_hitpoints

    // 0xA8 / 0xAA: a state goes on a unit, with a stat list attached as a bit-stream.
    // 0xA8 `[id][unitType u8][guid u32][?][pktLen u8@6][state u8@7][bits@8]`,
    // 0xAA `[id][unitType u8][guid u32][?][pktLen u8@6][bits@7]` (state is the first 8 bits).
    // The stat list itself is not modelled yet; the state and its target are.
    fn applyUnitState(self: *World, buf: []const u8) void {
        if (buf.len < 8) return;
        const u = self.upsert(buf[1], std.mem.readInt(u32, buf[2..6], .little)) catch return;
        u.state = if (buf[0] == 0xa8) buf[7] else buf[7];
    }

    /// Which roster field a packet carries. The client has one `Roster::` setter per opcode; this
    /// keeps them together because they all address the same table by player GUID.
    const RosterField = enum { arena_score, party_info, hp_and_area, in_party, hostile, party_id };

    // 0x65 ROSTER_SetArenaScore(guid@1, u16@5) | 0x75 ROSTER_UpdatePlayerPartyInfo(guid@1, x i16@5,
    // y i16@7, area u16@9) | 0x7F SetRosterHpAndArea(guid, life u16, area u16) | 0x8B
    // SetRosterInParty(guid, flag) | 0x8C ROSTER_SetPlayerHostileFlag(guid@1, other@5, flags u16@9)
    // | 0x8D SetRosterPartyId(guid@1, u16@5).
    fn rosterField(self: *World, buf: []const u8, field: RosterField) void {
        if (buf.len < 6) return;
        const guid = std.mem.readInt(u32, buf[1..5], .little);
        const gop = self.roster.getOrPut(guid) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{ .guid = guid };
        const e = gop.value_ptr;
        switch (field) {
            .arena_score => e.arena_score = self.readTail(buf, 5, 2),
            .party_id => e.party_id = @intCast(self.readTail(buf, 5, 2)),
            .in_party => e.in_party = buf[5] != 0,
            .hostile => if (buf.len >= 11) {
                e.hostile_to = std.mem.readInt(u32, buf[5..9], .little);
                e.hostile_flags = std.mem.readInt(u16, buf[9..11], .little);
            },
            .party_info => if (buf.len >= 11) {
                e.x = @bitCast(std.mem.readInt(i16, buf[5..7], .little));
                e.y = @bitCast(std.mem.readInt(i16, buf[7..9], .little));
                e.area = std.mem.readInt(u16, buf[9..11], .little);
            },
            // 0x7F is the one with a unit-type byte in front of the guid, so its fields sit two
            // bytes later than the rest of the family.
            .hp_and_area => if (buf.len >= 10) {
                e.life = std.mem.readInt(u16, buf[6..8], .little);
                e.area = std.mem.readInt(u16, buf[8..10], .little);
            },
        }
    }

    // 0x60: the act's activated-waypoint bitfield — `[id][data u32@1][more u16@5]` (7 bytes). Which
    // waypoints a character may travel to; the panel reads exactly this.
    fn applyWaypointBits(self: *World, buf: []const u8) void {
        if (buf.len < 7) return;
        self.waypoint_bits = std.mem.readInt(u32, buf[1..5], .little);
    }

    // 0x5B RosterPlayer (variable): the party roster entry — guid, class, name, level, party id.
    // `[id][len u16@1][guid u32@3][charType u16@7][name…]` per D2GSPacketSrv0x5B.
    fn applyRosterPlayer(self: *World, buf: []const u8) void {
        if (buf.len < 12) return;
        const guid = std.mem.readInt(u32, buf[3..7], .little);
        const u = self.upsert(@intFromEnum(UnitType.player), guid) catch return;
        const raw = buf[9..];
        var n: u8 = 0;
        while (n < raw.len and n < u.name.len and raw[n] != 0) n += 1;
        if (u.name_len == 0 and n > 0) {
            @memcpy(u.name[0..n], raw[0..n]);
            u.name_len = n;
        }
    }

    fn logUnhandled(self: *World, op: u8, cat: packets.Cat, buf: []const u8) void {
        if (!self.verbose) return;
        var nb: [8]u8 = undefined;
        std.debug.print("  world: [{s}] {s} ({d} bytes) — decode pending\n", .{ @tagName(cat), packets.label(op, &nb), buf.len });
    }

    pub const Coverage = struct {
        applied: u32 = 0,
        acknowledged: u32 = 0,
        ignored: u32 = 0,

        pub fn total(self: Coverage) u32 {
            return self.applied + self.acknowledged + self.ignored;
        }
        /// Percent of packets this model actually acted on, 0 when nothing arrived.
        pub fn percent(self: Coverage) u32 {
            const t = self.total();
            return if (t == 0) 0 else (self.applied + self.acknowledged) * 100 / t;
        }
    };

    /// How much of the stream this model consumed. A packet counts as applied when a handler ran
    /// for it — including handlers that deliberately do nothing because the packet carries no
    /// world state (a handshake, an automap hide, a client-side recompute). Anything with no
    /// handler at all is ignored, and `ignoredOpcodes` names them.
    pub fn coverage(self: *const World) Coverage {
        var c = Coverage{};
        for (self.applied, self.acknowledged, self.ignored) |a, k, i| {
            c.applied += a;
            c.acknowledged += k;
            c.ignored += i;
        }
        return c;
    }

    /// One unmodelled opcode and how often it arrived.
    pub const IgnoredOp = struct { op: u8, n: u32 };

    /// The still-unhandled opcodes and their counts, busiest first, into `out`. Returns how many
    /// were written — the worklist for finishing the model.
    pub fn ignoredOpcodes(self: *const World, out: []IgnoredOp) usize {
        var n: usize = 0;
        for (self.ignored, 0..) |count, op| {
            if (count == 0 or n >= out.len) continue;
            out[n] = .{ .op = @intCast(op), .n = count };
            n += 1;
        }
        std.mem.sort(IgnoredOp, out[0..n], {}, struct {
            fn gt(_: void, a: IgnoredOp, b: IgnoredOp) bool {
                return a.n > b.n;
            }
        }.gt);
        return n;
    }

    pub fn unitCount(self: *const World) u32 {
        return self.units.count();
    }

    /// The local player's current (x,y), or null if we haven't seen a CreatePlayer yet.
    pub fn playerPos(self: *const World) ?struct { x: u16, y: u16 } {
        const g = self.local_player_guid orelse return null;
        const u = self.units.get(unitKey(@intFromEnum(UnitType.player), g)) orelse return null;
        return .{ .x = u.x, .y = u.y };
    }

    /// Look up a live unit by (type, guid). Used by the driver to poll a target's state.
    pub fn getUnit(self: *const World, utype: UnitType, guid: u32) ?Unit {
        return self.units.get(unitKey(@intFromEnum(utype), guid));
    }

    /// Look up a known warp by GUID (warps come in as "object" units flagged is_warp).
    pub fn getWarp(self: *const World, guid: u32) ?Unit {
        var it = self.units.valueIterator();
        while (it.next()) |u| if (u.is_warp and u.guid == guid) return u.*;
        return null;
    }

    /// The first known inter-level warp (0x09-origin unit), else null. The standalone streams
    /// every outgoing warp of the current level; interacting with one transitions to its
    /// destination (game_instance.zig warpClient). Warps arrive with wire unit_type "object",
    /// so they're identified by the is_warp flag, not the unit type.
    pub fn anyWarp(self: *const World) ?Unit {
        var it = self.units.valueIterator();
        while (it.next()) |u| if (u.is_warp) return u.*;
        return null;
    }

    /// Every warp currently known, copied into `out` (up to out.len). Returns the count.
    pub fn collectWarps(self: *const World, out: []Unit) usize {
        var n: usize = 0;
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (!u.is_warp) continue;
            if (n >= out.len) break;
            out[n] = u.*;
            n += 1;
        }
        return n;
    }

    /// The object units of a given class, copied into `out`. Returns the count.
    pub fn collectObjectsOfClass(self: *const World, class_id: u16, out: []Unit) usize {
        var n: usize = 0;
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype != @intFromEnum(UnitType.object) or u.is_warp) continue;
            if (u.class_id != class_id) continue;
            if (n >= out.len) break;
            out[n] = u.*;
            n += 1;
        }
        return n;
    }

    /// The waypoint on this level, or null if the server has not sent one.
    ///
    /// Every act's waypoint is a different object class (its art differs), so this asks Objects.txt
    /// which classes are named "Waypoint" rather than matching one id. When several are in view —
    /// which does not happen in the retail maps, but costs nothing to handle — the nearest one to
    /// the local player wins. The classes are parsed once and cached on the world.
    pub fn waypoint(self: *World) !?Unit {
        if (self.waypoint_class.len == 0) self.waypoint_class = try objects.waypointClasses(self.gpa);
        var best: ?Unit = null;
        var best_d: i64 = std.math.maxInt(i64);
        const p = self.playerPos();
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype != @intFromEnum(UnitType.object) or u.is_warp) continue;
            if (u.class_id >= self.waypoint_class.len or !self.waypoint_class[u.class_id]) continue;
            const d: i64 = if (p) |pp| blk: {
                const dx: i64 = @as(i64, u.x) - @as(i64, pp.x);
                const dy: i64 = @as(i64, u.y) - @as(i64, pp.y);
                break :blk dx * dx + dy * dy;
            } else 0;
            if (best == null or d < best_d) {
                best_d = d;
                best = u.*;
            }
        }
        return best;
    }

    /// The monster nearest the local player (Euclidean over subtiles), or null if none.
    /// On Durance 3 this is our stand-in for "move adjacent to Mephisto": the driver walks
    /// to it and spams the attack skill until it is removed from the world.
    pub fn nearestMonster(self: *const World) ?Unit {
        const p = self.playerPos() orelse return null;
        var best: ?Unit = null;
        var best_d: i64 = std.math.maxInt(i64);
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype != @intFromEnum(UnitType.monster)) continue;
            const dx: i64 = @as(i64, u.x) - @as(i64, p.x);
            const dy: i64 = @as(i64, u.y) - @as(i64, p.y);
            const d = dx * dx + dy * dy;
            if (d < best_d) {
                best_d = d;
                best = u.*;
            }
        }
        return best;
    }

    /// The monster with a specific eD2MonStatsId (class_id from AssignMonster 0xAC), or null.
    /// A boss run targets its boss BY CLASS ID — this is how the bot finds the real Mephisto
    /// (MonStats class 242) rather than whatever mob happens to be nearest.
    pub fn monsterByClass(self: *const World, class_id: u16) ?Unit {
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype != @intFromEnum(UnitType.monster)) continue;
            if (u.class_id == class_id) return u.*;
        }
        return null;
    }

    pub fn monsterCount(self: *const World) u32 {
        var n: u32 = 0;
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype == @intFromEnum(UnitType.monster)) n += 1;
        }
        return n;
    }

    /// Print a human-readable snapshot: level/seed, unit tallies, local player, ground items.
    pub fn dumpSummary(self: *const World) void {
        std.debug.print(
            "\n=== world ===\nact={d} level={d} mapSeed=0x{x:0>8} diff={d} exp={} ladder={}\n",
            .{ self.act, self.level_id, self.map_seed, self.difficulty, self.expansion, self.ladder },
        );
        if (self.local_player_guid) |g|
            std.debug.print("local player guid=0x{x} hp={d} mp={d} stam={d}\n", .{ g, self.local_hp, self.local_mp, self.local_stamina });
        if (self.player_stats.count() > 0) {
            std.debug.print("player stats:", .{});
            for ([_]u16{ 0, 1, 2, 3, 7, 9, 11, 12, 13, 14 }) |id| {
                if (self.player_stats.get(id)) |v| {
                    // hp/mana/stamina are ×256 fixed point
                    const shown = if (id == 7 or id == 9 or id == 11) @divTrunc(v, 256) else v;
                    std.debug.print(" {s}={d}", .{ statName(id), shown });
                }
            }
            std.debug.print("\n", .{});
        }
        var tally = [_]u32{0} ** 6;
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.utype < tally.len) tally[u.utype] += 1;
        }
        std.debug.print("units: player={d} monster={d} object={d} missile={d} item={d} warp={d} (total {d})\n", .{ tally[0], tally[1], tally[2], tally[3], tally[4], tally[5], self.units.count() });
        var on_floor: u32 = 0;
        var gi0 = self.items.iterator();
        while (gi0.next()) |e| {
            if (e.value_ptr.where.onGround()) on_floor += 1;
        }
        std.debug.print("items: {d} known, {d} on the floor\n", .{ self.items.count(), on_floor });
        var gi = self.items.iterator();
        while (gi.next()) |e| {
            const item = &e.value_ptr.item;
            std.debug.print("  0x{x:0>8} \"{s}\" {s}{s} ilvl={d} sockets={d} at ({d},{d}) stats={d}\n", .{
                e.key_ptr.*,          item.codeSlice(),          @tagName(item.quality),
                if (item.ethereal()) " eth" else "", item.ilvl, item.sockets,
                item.x,               item.y,                    item.n_stats,
            });
        }
    }
};

test "LoadAct sets seed, act, area" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    // act=1, mapSeed=0xDEADBEEF, area=0x0028, automap=0x11223344
    var p = [_]u8{ 0x03, 0x01, 0xEF, 0xBE, 0xAD, 0xDE, 0x28, 0x00, 0x44, 0x33, 0x22, 0x11 };
    w.apply(&p);
    try std.testing.expectEqual(@as(u8, 1), w.act);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), w.map_seed);
    try std.testing.expectEqual(@as(u16, 0x0028), w.level_id);
    try std.testing.expectEqual(@as(u32, 0x11223344), w.automap);
}

test "CreatePlayer then reassign tracks position" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var mk = [_]u8{0} ** 26;
    mk[0] = 0x59;
    std.mem.writeInt(u32, mk[1..5], 0x1000, .little);
    @memcpy(mk[6..10], "Bob\x00");
    std.mem.writeInt(u16, mk[22..24], 100, .little);
    std.mem.writeInt(u16, mk[24..26], 200, .little);
    w.apply(&mk);
    try std.testing.expectEqual(@as(u32, 1), w.unitCount());
    try std.testing.expectEqual(@as(?u32, 0x1000), w.local_player_guid);
    // reassign player (type 0) guid 0x1000 to (150,250)
    var rp = [_]u8{ 0x15, 0x00, 0x00, 0x10, 0x00, 0x00, 150, 0, 250, 0, 0 };
    w.apply(&rp);
    try std.testing.expectEqual(@as(u32, 1), w.unitCount()); // same unit, moved
    var it = w.units.valueIterator();
    const u = it.next().?;
    try std.testing.expectEqual(@as(u16, 150), u.x);
    try std.testing.expectEqual(@as(u16, 250), u.y);
}

test "Life (0x95) decodes hp/mp/stamina and repositions local player" {
    const BitWriter = core.bitreader.BitWriter;
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    // make a local player first so 0x95 has a unit to reposition
    var mk = [_]u8{0} ** 26;
    mk[0] = 0x59;
    std.mem.writeInt(u32, mk[1..5], 0x2000, .little);
    std.mem.writeInt(u16, mk[22..24], 1, .little);
    std.mem.writeInt(u16, mk[24..26], 1, .little);
    w.apply(&mk);
    // build a 0x95: hp=100 mp=50 stam=80 x=5000 y=6000
    var buf = [_]u8{0} ** 13;
    var bw = BitWriter.init(&buf);
    bw.write(0x95, 8);
    bw.write(100, 15);
    bw.write(50, 15);
    bw.write(80, 15);
    bw.write(5000, 16);
    bw.write(6000, 16);
    w.apply(&buf);
    try std.testing.expectEqual(@as(u16, 100), w.local_hp);
    try std.testing.expectEqual(@as(u16, 50), w.local_mp);
    try std.testing.expectEqual(@as(u16, 80), w.local_stamina);
    const u = w.units.getPtr((@as(u64, 0) << 32) | 0x2000).?;
    try std.testing.expectEqual(@as(u16, 5000), u.x);
    try std.testing.expectEqual(@as(u16, 6000), u.y);
}

test "stat family decodes real Sorceress starting stats (from a live capture)" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.apply(&[_]u8{ 0x1d, 0x00, 0x0a }); // strength = 10
    w.apply(&[_]u8{ 0x1d, 0x02, 0x19 }); // dexterity = 25
    w.apply(&[_]u8{ 0x1e, 0x07, 0x00, 0x28 }); // maxhp = 0x2800 (=40 after /256)
    w.apply(&[_]u8{ 0x1e, 0x0b, 0x00, 0x4a }); // maxstamina = 0x4a00 (=74)
    try std.testing.expectEqual(@as(i32, 10), w.player_stats.get(0).?);
    try std.testing.expectEqual(@as(i32, 25), w.player_stats.get(2).?);
    try std.testing.expectEqual(@as(i32, 0x2800), w.player_stats.get(7).?);
    try std.testing.expectEqual(@as(i32, 40), @divTrunc(w.player_stats.get(7).?, 256));
    try std.testing.expectEqual(@as(i32, 74), @divTrunc(w.player_stats.get(11).?, 256));
}

test "GameFlags + remove of an absent unit is harmless" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.apply(&[_]u8{ 0x01, 0x02, 0, 0, 0, 0, 0x01, 0x01 });
    try std.testing.expectEqual(@as(u8, 2), w.difficulty);
    try std.testing.expect(w.expansion and w.ladder);
    w.apply(&[_]u8{ 0x0a, 0x01, 0x01, 0, 0, 0 });
    try std.testing.expectEqual(@as(u32, 0), w.unitCount());
}

test "0x19..0x1C accumulate gold and experience (Incoming0x19 handler)" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.apply(&[_]u8{ 0x19, 0x0a }); // gold += 10
    w.apply(&[_]u8{ 0x19, 0x05 }); // gold += 5
    w.apply(&[_]u8{ 0x1a, 0x07 }); // exp += 7
    w.apply(&[_]u8{ 0x1b, 0x00, 0x01 }); // exp += 256
    try std.testing.expectEqual(@as(i32, 15), w.player_stats.get(World.STAT_GOLD).?);
    try std.testing.expectEqual(@as(i32, 263), w.player_stats.get(World.STAT_EXPERIENCE).?);
    w.apply(&[_]u8{ 0x1c, 0x40, 0x00, 0x00, 0x00 }); // exp = 64, absolute
    try std.testing.expectEqual(@as(i32, 64), w.player_stats.get(World.STAT_EXPERIENCE).?);
}

test "0x9E..0xA2 set a monster stat at the opcode's width" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    var spawn = [_]u8{0} ** 13;
    spawn[0] = 0xac;
    std.mem.writeInt(u32, spawn[1..5], 0x777, .little);
    w.apply(&spawn);

    // 0xA0: [op][stat=6 life][guid u32][value u32]
    var p = [_]u8{0} ** 10;
    p[0] = 0xa0;
    p[1] = World.STAT_LIFE;
    std.mem.writeInt(u32, p[2..6], 0x777, .little);
    std.mem.writeInt(u32, p[6..10], 4321, .little);
    w.apply(&p);
    const mon = w.getUnit(.monster, 0x777).?;
    try std.testing.expectEqual(@as(u16, 4321), mon.life_abs);
}

test "an item that is equipped leaves the floor; one on the ground becomes a unit" {
    const BitWriter = core.bitreader.BitWriter;
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    // 0x9C action 0 with a ground item (dest 3) => on the floor, and a clickable unit.
    var body: [64]u8 = undefined;
    var bw = BitWriter.init(&body);
    bw.write(0, 20); // flags low bits
    bw.write(0, 12);
    bw.write(0x60, 10); // version
    bw.write(3, 3); // dest = ground
    var pkt: [128]u8 = undefined;
    pkt[0] = 0x9c;
    pkt[1] = 0x00;
    pkt[3] = 0;
    std.mem.writeInt(u32, pkt[4..8], 0x555, .little);
    @memcpy(pkt[8..][0..body.len], &body);
    pkt[2] = 8 + 40;
    w.apply(pkt[0 .. 8 + 40]);
    try std.testing.expect(w.items.get(0x555).?.where.onGround());
    try std.testing.expect(w.getUnit(.item, 0x555) != null);

    // 0x9C action 1 = picked from the ground: the unit goes, the memory of the item stays.
    var picked = [_]u8{0} ** 8;
    picked[0] = 0x9c;
    picked[1] = 0x01;
    std.mem.writeInt(u32, picked[4..8], 0x555, .little);
    w.apply(&picked);
    try std.testing.expectEqual(Where.gone, w.items.get(0x555).?.where);
    try std.testing.expect(w.getUnit(.item, 0x555) == null);
}

test "coverage counts a handled packet as applied and an unknown one as ignored" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.apply(&[_]u8{ 0x01, 0x02, 0, 0, 0, 0, 0x01, 0x01 }); // GameFlags: handled
    w.apply(&[_]u8{0x04}); // LoadComplete: handled, sets state
    w.apply(&[_]u8{ 0xfe, 0, 0 }); // outside the engine's dispatch table entirely
    const c = w.coverage();
    try std.testing.expectEqual(@as(u32, 2), c.applied);
    try std.testing.expectEqual(@as(u32, 1), c.ignored);
    try std.testing.expectEqual(@as(u32, 66), c.percent());
    try std.testing.expect(w.loaded);
}

test "every opcode in the engine's dispatch table is handled, none silently dropped" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();

    // Feed one packet per opcode, sized as the engine's table says. This is the whole S->C
    // dispatch space, not just the opcodes a particular game happened to send.
    var buf: [512]u8 = undefined;
    var op: usize = 0;
    while (op < table.COUNT) : (op += 1) {
        const sz = table.TABLE[op].expected_size;
        const n: usize = if (sz > 0) @intCast(sz) else 64; // variable-size: give it room
        @memset(buf[0..n], 0);
        buf[0] = @intCast(op);
        w.apply(buf[0..n]);
    }

    const c = w.coverage();
    try std.testing.expectEqual(@as(u32, table.COUNT), c.total());
    try std.testing.expectEqual(@as(u32, 0), c.ignored);
    try std.testing.expectEqual(@as(u32, 100), c.percent());
}

test "an opcode outside the engine's table is still reported as unhandled" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.apply(&[_]u8{ 0xfe, 0, 0 });
    try std.testing.expectEqual(@as(u32, 1), w.coverage().ignored);
}

test "the local player is identified by name, not by arrival order" {
    var w = World.init(std.testing.allocator);
    defer w.deinit();
    w.expectLocalPlayer("EpicAma");

    // A ghost of the same character, and another player, both arrive before us.
    const mk = struct {
        fn player(world: *World, guid: u32, name: []const u8, x: u16, y: u16) void {
            var p = [_]u8{0} ** 26;
            p[0] = 0x59;
            std.mem.writeInt(u32, p[1..5], guid, .little);
            @memcpy(p[6..][0..name.len], name);
            std.mem.writeInt(u16, p[22..24], x, .little);
            std.mem.writeInt(u16, p[24..26], y, .little);
            world.apply(&p);
        }
    };
    mk.player(&w, 0x01, "EpicSorc", 100, 100);
    mk.player(&w, 0x02, "EpicAma", 200, 200); // us — matched by name even though not first
    try std.testing.expectEqual(@as(?u32, 0x02), w.local_player_guid);
    const pos = w.playerPos().?;
    try std.testing.expectEqual(@as(u16, 200), pos.x);

    // Without a name set, the old first-seen behaviour still applies.
    var w2 = World.init(std.testing.allocator);
    defer w2.deinit();
    mk.player(&w2, 0x07, "Whoever", 5, 5);
    try std.testing.expectEqual(@as(?u32, 0x07), w2.local_player_guid);
}
