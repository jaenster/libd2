//! Character persistence data model — pure record types + Unit mapping + sidecar codec.
//!
//! The host owns file I/O (open/read/write/mkdir) and the byte-exact .d2s header; this module
//! holds the PURE, libc-free pieces: the quest-completion bitfield, the CharSave record the
//! host loads on join / writes on leave, the CharSave<->Unit stat mapping, and the compact
//! sidecar byte codec (buffer in / buffer out — no filesystem). Mirrors the lib rule "state
//! as params, return a decision": applyToUnit mutates only the passed Unit; the codec touches
//! only the caller's buffer.

const std = @import("std");
const unit = @import("unit.zig");
const Unit = unit.Unit;
const Stat = @import("stat.zig").Stat;
const spell = @import("spell.zig");
const skill = @import("skill.zig");
const derive = @import("derive.zig");

/// Number of quest-completion flags modelled: 3 difficulties x 32 slots. D2's real quest
/// record is a per-act bitfield; this flat index is enough for a completion framework.
pub const NUM_QUESTS = 96;

/// A character's quest-completion bitfield (one bit per quest slot). This is the quest
/// framework's persisted state; game logic toggles a flag on quest completion.
pub const QuestState = struct {
    bits: [NUM_QUESTS / 8]u8 = [_]u8{0} ** (NUM_QUESTS / 8),

    pub fn isDone(self: QuestState, id: u16) bool {
        if (id >= NUM_QUESTS) return false;
        return (self.bits[id / 8] & (@as(u8, 1) << @intCast(id % 8))) != 0;
    }
    pub fn setDone(self: *QuestState, id: u16, done: bool) void {
        if (id >= NUM_QUESTS) return;
        const mask = @as(u8, 1) << @intCast(id % 8);
        if (done) self.bits[id / 8] |= mask else self.bits[id / 8] &= ~mask;
    }
    pub fn count(self: QuestState) u32 {
        var n: u32 = 0;
        for (self.bits) |b| n += @popCount(b);
        return n;
    }
};

/// The persisted per-character state the game host loads on join and writes on leave.
/// Defaults are the fresh level-1 sorceress the join path uses when no save exists.
pub const CharSave = struct {
    level: u8 = 1,
    class: u8 = 1,
    status: u8 = 0x21, // expansion | mandatory
    strength: u16 = 30,
    dexterity: u16 = 30,
    vitality: u16 = 20,
    energy: u16 = 20,
    max_hp: u16 = 100,
    // Sourced from the real .d2s attributes when present (not in the sidecar; the .d2s file
    // itself is preserved on save, so these round-trip through the engine's own record).
    max_mana: u16 = 0,
    gold: u32 = 0,
    quests: QuestState = .{},
    waypoints: u64 = 0,
};

pub const SIDECAR_MAGIC: u32 = 0x53474432; // "D2GS" (LE)
pub const SIDECAR_VERSION: u8 = 1;
pub const SIDECAR_LEN = 26 + (NUM_QUESTS / 8);

/// Serialize a CharSave into the fixed-size sidecar blob (no filesystem).
pub fn writeSidecar(out: *[SIDECAR_LEN]u8, cs: CharSave) void {
    std.mem.writeInt(u32, out[0..4], SIDECAR_MAGIC, .little);
    out[4] = SIDECAR_VERSION;
    out[5] = cs.level;
    out[6] = cs.class;
    out[7] = cs.status;
    std.mem.writeInt(u16, out[8..10], cs.strength, .little);
    std.mem.writeInt(u16, out[10..12], cs.dexterity, .little);
    std.mem.writeInt(u16, out[12..14], cs.vitality, .little);
    std.mem.writeInt(u16, out[14..16], cs.energy, .little);
    std.mem.writeInt(u16, out[16..18], cs.max_hp, .little);
    std.mem.writeInt(u64, out[18..26], cs.waypoints, .little);
    @memcpy(out[26..SIDECAR_LEN], &cs.quests.bits);
}

/// Overlay a sidecar blob onto `cs` (leaves `cs` untouched if the blob is short / mismatched).
pub fn readSidecar(blob: []const u8, cs: *CharSave) void {
    if (blob.len < SIDECAR_LEN) return;
    if (std.mem.readInt(u32, blob[0..4], .little) != SIDECAR_MAGIC) return;
    if (blob[4] != SIDECAR_VERSION) return;
    cs.level = blob[5];
    cs.class = blob[6];
    cs.status = blob[7];
    cs.strength = std.mem.readInt(u16, blob[8..10], .little);
    cs.dexterity = std.mem.readInt(u16, blob[10..12], .little);
    cs.vitality = std.mem.readInt(u16, blob[12..14], .little);
    cs.energy = std.mem.readInt(u16, blob[14..16], .little);
    cs.max_hp = std.mem.readInt(u16, blob[16..18], .little);
    cs.waypoints = std.mem.readInt(u64, blob[18..26], .little);
    @memcpy(&cs.quests.bits, blob[26..SIDECAR_LEN]);
}

/// Overlay a loaded CharSave onto a live player Unit (the join path's applySave).
pub fn applyToUnit(u: *Unit, cs: CharSave) void {
    u.set(.level, cs.level);
    u.class_id = cs.class;
    u.set(.strength, cs.strength);
    u.set(.dexterity, cs.dexterity);
    u.set(.vitality, cs.vitality);
    u.set(.energy, cs.energy);
    u.set(.maxhp, cs.max_hp);
    u.setLife(cs.max_hp);
    if (cs.max_mana > 0) {
        u.set(.maxmana, cs.max_mana);
        u.set(.mana, cs.max_mana);
    }
    if (cs.gold > 0) u.set(.gold, @intCast(@min(cs.gold, std.math.maxInt(i32))));
}

/// Capture a player Unit's persistable stats into a CharSave with the given quest state (the
/// leave path). Waypoints are not sourced from the Unit (the host carries them separately).
pub fn fromUnit(u: *const Unit, quests: QuestState) CharSave {
    return .{
        .level = @intCast(@max(1, @min(99, u.get(.level)))),
        .class = @intCast(@min(6, u.class_id)),
        .status = 0x21,
        .strength = statU16(u, .strength),
        .dexterity = statU16(u, .dexterity),
        .vitality = statU16(u, .vitality),
        .energy = statU16(u, .energy),
        .max_hp = statU16(u, .maxhp),
        .quests = quests,
    };
}

fn statU16(u: *const Unit, s: Stat) u16 {
    return @intCast(@max(0, @min(0xFFFF, u.get(s))));
}

/// A cold-tree sorceress build: the class/level/attributes + hard-point cold-skill levels that
/// drive its elemental cast damage and derived life/mana. The defaults are the stock clientless
/// Hell-Mephisto farmer: a level-85 maxed-cold sorc — every hard point in the cold tree (Ice Bolt
/// as the left-click bolt maxed, its four in-tree synergies Ice Blast / Glacial Spike / Blizzard /
/// Frozen Orb maxed, and Cold Mastery maxed to pierce Mephisto's 75% cold resist): 20*5 + 20 = 120
/// pts, the near-endgame allocation a clvl~85 sorc has after quest skill points. Vitality-heavy for
/// Hell survivability. `iceBoltCast` builds this sorc's Ice Bolt Cast; `derived` its life/mana.
pub const SorcColdBuild = struct {
    class: derive.Class = .sorceress,
    level: i32 = 85,
    strength: i32 = 30,
    dexterity: i32 = 30,
    vitality: i32 = 300,
    energy: i32 = 55, // sorc energy_start 35 + 20 spent; the rest goes to vit/str-for-gear
    ice_bolt: i32 = 20,
    frost_nova: i32 = 1,
    ice_blast: i32 = 20,
    glacial_spike: i32 = 20,
    blizzard: i32 = 20,
    frozen_orb: i32 = 20,
    cold_mastery: i32 = 20,

    /// Build the sim Ice Bolt Cast for this sorc (effective skill level + synergy hard levels +
    /// cold-mastery-as-pierce). Ice Bolt's element damage (EType/EMin.../HitShift) is read from the
    /// loaded Skills.txt (Id 39) via `skills` — TABLE-DRIVEN, not hardcoded. `syn` is caller storage
    /// the returned Cast borrows. Falls back to the verified `spell.ICE_BOLT` reference if the row
    /// is somehow absent from the table (it never is in the real 1.14d data).
    pub fn iceBoltCast(self: SorcColdBuild, skills: *const skill.Skills, syn: *[5]spell.Synergy) spell.Cast {
        const dmg = if (skills.byId(spell.ICE_BOLT_ID)) |sd| sd.dmg else spell.ICE_BOLT;
        return spell.iceBolt(
            dmg,
            self.ice_bolt,
            self.frost_nova,
            self.ice_blast,
            self.glacial_spike,
            self.blizzard,
            self.frozen_orb,
            self.cold_mastery,
            syn,
        );
    }

    /// Faithful derived life/mana from CharStats.txt for this build's class/level + spent
    /// vitality/energy (derive.derive).
    pub fn derived(self: SorcColdBuild) derive.Derived {
        return derive.derive(self.class, self.level, self.vitality, self.energy);
    }
};

const testing = std.testing;

test "quest bitfield set/clear/count" {
    var q = QuestState{};
    try testing.expect(!q.isDone(5));
    q.setDone(5, true);
    q.setDone(40, true);
    try testing.expect(q.isDone(5));
    try testing.expect(q.isDone(40));
    try testing.expectEqual(@as(u32, 2), q.count());
    q.setDone(5, false);
    try testing.expect(!q.isDone(5));
    try testing.expectEqual(@as(u32, 1), q.count());
}

test "sidecar round-trips stats, waypoints and quests" {
    var cs = CharSave{ .level = 30, .class = 2, .strength = 111, .max_hp = 640, .waypoints = 0x1234 };
    cs.quests.setDone(1, true);
    cs.quests.setDone(50, true);
    var blob: [SIDECAR_LEN]u8 = undefined;
    writeSidecar(&blob, cs);

    var out = CharSave{};
    readSidecar(&blob, &out);
    try testing.expectEqual(@as(u8, 30), out.level);
    try testing.expectEqual(@as(u8, 2), out.class);
    try testing.expectEqual(@as(u16, 111), out.strength);
    try testing.expectEqual(@as(u16, 640), out.max_hp);
    try testing.expectEqual(@as(u64, 0x1234), out.waypoints);
    try testing.expect(out.quests.isDone(1));
    try testing.expect(out.quests.isDone(50));
    try testing.expect(!out.quests.isDone(2));
}

test "readSidecar ignores a bad magic / short blob" {
    var cs = CharSave{ .level = 7 };
    readSidecar(&[_]u8{ 1, 2, 3 }, &cs); // too short
    try testing.expectEqual(@as(u8, 7), cs.level);
    var blob: [SIDECAR_LEN]u8 = [_]u8{0} ** SIDECAR_LEN; // zero magic
    readSidecar(&blob, &cs);
    try testing.expectEqual(@as(u8, 7), cs.level);
}

test "applyToUnit / fromUnit map the persisted stats onto a Unit and back" {
    var cs = CharSave{ .level = 42, .class = 1, .strength = 77, .dexterity = 55, .vitality = 33, .energy = 22, .max_hp = 500 };
    cs.quests.setDone(3, true);

    var u = Unit.init(.player);
    applyToUnit(&u, cs);
    try testing.expectEqual(@as(i32, 42), u.get(.level));
    try testing.expectEqual(@as(u32, 1), u.class_id);
    try testing.expectEqual(@as(i32, 77), u.get(.strength));
    try testing.expectEqual(@as(i32, 500), u.get(.maxhp));
    try testing.expectEqual(@as(i32, 500), u.life());

    const back = fromUnit(&u, cs.quests);
    try testing.expectEqual(@as(u8, 42), back.level);
    try testing.expectEqual(@as(u16, 77), back.strength);
    try testing.expectEqual(@as(u16, 500), back.max_hp);
    try testing.expect(back.quests.isDone(3));
}

test "SorcColdBuild: Ice Bolt cast carries maxed synergies + cold-mastery pierce; derived life/mana" {
    const b = SorcColdBuild{};
    var skills = try skill.Skills.load(testing.allocator);
    defer skills.deinit();
    var syn: [5]spell.Synergy = undefined;
    const c = b.iceBoltCast(&skills, &syn);
    try testing.expectEqual(spell.Element.cold, c.dmg.etype);
    // Table-driven: the Ice Bolt row read from the real Skills.txt (Id 39) matches the verified ref.
    try testing.expectEqual(spell.ICE_BOLT.e_min, c.dmg.e_min);
    try testing.expectEqual(spell.ICE_BOLT.hit_shift, c.dmg.hit_shift);
    try testing.expectEqual(@as(i32, 20), c.skill_level); // Ice Bolt maxed
    // 4 maxed synergies (Ice Blast/Glacial Spike/Blizzard/Frozen Orb) + Frost Nova 1, each 15%/lvl.
    var syn_total: i32 = 0;
    for (c.synergies) |s| syn_total += s.skill_level;
    try testing.expectEqual(@as(i32, 81), syn_total); // 20*4 + 1
    try testing.expectEqual(spell.coldMasteryPierce(20), c.pierce_percent);
    // Life/mana match the direct derive for the same class/level/attributes.
    const d = b.derived();
    const dd = derive.derive(.sorceress, 85, 300, 55);
    try testing.expectEqual(dd.max_life, d.max_life);
    try testing.expectEqual(dd.max_mana, d.max_mana);
}

test "fromUnit clamps level to [1,99] and class to <=6" {
    var u = Unit.init(.player);
    u.set(.level, 250);
    u.class_id = 99;
    const cs = fromUnit(&u, .{});
    try testing.expectEqual(@as(u8, 99), cs.level);
    try testing.expectEqual(@as(u8, 6), cs.class);
}
