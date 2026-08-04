//! Object operation — the pure resolver behind Objects.txt `OperateFn`. `operate()` turns an
//! interaction into a small list of Effects the host applies (see effect.zig). Behaviour families
//! are derived from the OBJECTSOPERATEFN handlers (@0x732d18); the host owns drops/timers/warp.

const std = @import("std");
const core = @import("d2-core");
const shrines = @import("shrines.zig");
const effect = @import("effect.zig");

pub const OperateFn = core.OperateFn;
pub const Effect = effect.Effect;

/// The behaviour class an OperateFn falls into — what the object DOES on operate.
pub const Family = enum {
    lootable, // open + roll drops (chests / caskets / urns / racks / boss chests)
    destructible, // break animation, no drops (barrels / breakable containers)
    explode, // trap / explosive barrel — triggers, damages nearby (AoE is a host refinement)
    shrine,
    well,
    door,
    waypoint,
    stash, // personal stash / Horadric Cube — open an inventory screen
    warp, // portal / stairs / level-transition
    other, // quest triggers, seal glows, automap reveal, cosmetics — acknowledge + animate
};

pub fn family(op: OperateFn) Family {
    return switch (op) {
        .open_chest_spawn_monster,
        .open_chest_no_monster,
        .open_sparkly_chest,
        .open_trap_chest_skill_trigger,
        .open_locked_chest,
        .open_unlocked_chest,
        .open_boss_chest_spawn_uniques,
        .spawn_exceptional_item_drop,
        .spawn_normal_item_drop,
        .spawn_quest_item_reward,
        .spawn_reward_item,
        => .lootable,

        .destroy_destructible, .open_breakable_container, .timed_destructible => .destructible,
        .detonate_explosive_barrel, .exploding_trap => .explode,
        .activate_shrine => .shrine,
        .activate_healing_well => .well,
        .toggle_door, .open_timed_door => .door,
        .activate_waypoint => .waypoint,
        .open_stash, .open_horadric_cube => .stash,

        .portal, // 15
        .use_stairway, // 16
        .a2_q2_arcane_gate_level_transition, // 34
        .activate_portal_object, // 43
        .use_stair_direct, // 44
        .portal_to_act4, // 46
        .use_waygate, // 47
        .use_stair_alias, // 50
        .a5_q5_worldstone_portal_activate, // 66
        .a5_q6_worldstone_level_transition, // 70
        .a5_q5_worldstone_stair_portal, // 71
        .a5_q6_tyrael_portal_to_end, // 72
        .a4_q2_pandemonium_fortress_gate, // 73
        => .warp,

        else => .other,
    };
}

/// The object being operated, reduced to what the resolver needs.
pub const ObjectRef = struct {
    guid: u32,
    x: i32,
    y: i32,
    operate_fn: i32,
    anim_mode: u8, // 0 Neutral, 1 Operating, 2 Opened, 3-7 special
    shrine_effect: shrines.Effect = .none,
    shrine_reset_min: i32 = 0,
    /// Destination level for a `warp` object (0 = unknown; the host may resolve it).
    warp_dest_level: u16 = 0,
};

/// Resolve an operate into Effects written into `buf`. Returns the used slice ([] = nothing happens,
/// e.g. re-operating a spent chest/shrine). Pure — the host applies the Effects.
pub fn operate(obj: ObjectRef, buf: []Effect) []Effect {
    var n: usize = 0;
    const op: OperateFn = @enumFromInt(obj.operate_fn);
    const spent = obj.anim_mode != 0; // already opened / operating
    switch (family(op)) {
        .lootable => {
            if (spent) return buf[0..0];
            buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 2 } };
            n += 1;
            buf[n] = .{ .roll_drops = .{ .x = obj.x, .y = obj.y } };
            n += 1;
        },
        .destructible => {
            if (spent) return buf[0..0];
            buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 2 } };
            n += 1;
        },
        .explode => {
            if (spent) return buf[0..0];
            buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 2 } };
            n += 1;
        },
        .shrine => {
            if (spent) return buf[0..0];
            buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 1 } };
            n += 1;
            buf[n] = .{ .grant_shrine = obj.shrine_effect };
            n += 1;
            if (obj.shrine_reset_min > 0) {
                buf[n] = .{ .schedule_reset = .{ .guid = obj.guid, .minutes = obj.shrine_reset_min } };
                n += 1;
            }
        },
        .well => {
            if (spent) return buf[0..0];
            buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 1 } };
            n += 1;
            buf[n] = .refill_life_mana;
            n += 1;
        },
        .door => {
            buf[n] = .{ .toggle_door = .{ .guid = obj.guid } };
            n += 1;
        },
        .waypoint => {
            buf[n] = .{ .activate_waypoint = .{ .guid = obj.guid } };
            n += 1;
        },
        .stash => {
            buf[n] = .open_stash;
            n += 1;
        },
        .warp => {
            if (obj.warp_dest_level != 0) {
                buf[n] = .{ .warp_level = .{ .level_id = obj.warp_dest_level } };
                n += 1;
            } else {
                buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 1 } };
                n += 1;
            }
        },
        .other => {
            // Quest triggers / seal glows / automap / cosmetics: acknowledge by animating, no
            // world mutation (their quest semantics are out of scope for the standalone).
            if (!spent) {
                buf[n] = .{ .set_anim_mode = .{ .guid = obj.guid, .mode = 1 } };
                n += 1;
            }
        },
    }
    return buf[0..n];
}

const testing = std.testing;

test "operate: families emit the right effects" {
    var buf: [4]Effect = undefined;
    // A fresh chest opens + rolls drops.
    const chest = ObjectRef{ .guid = 1, .x = 10, .y = 20, .operate_fn = @intFromEnum(OperateFn.open_chest_no_monster), .anim_mode = 0 };
    const e = operate(chest, &buf);
    try testing.expectEqual(@as(usize, 2), e.len);
    try testing.expect(e[0] == .set_anim_mode and e[0].set_anim_mode.mode == 2);
    try testing.expect(e[1] == .roll_drops and e[1].roll_drops.x == 10);
    // A spent chest does nothing.
    const spent = ObjectRef{ .guid = 1, .x = 10, .y = 20, .operate_fn = @intFromEnum(OperateFn.open_chest_no_monster), .anim_mode = 2 };
    try testing.expectEqual(@as(usize, 0), operate(spent, &buf).len);
    // A door toggles (works even when "spent").
    const door = ObjectRef{ .guid = 5, .x = 0, .y = 0, .operate_fn = @intFromEnum(OperateFn.toggle_door), .anim_mode = 0 };
    const de = operate(door, &buf);
    try testing.expectEqual(@as(usize, 1), de.len);
    try testing.expect(de[0] == .toggle_door);
    // A waypoint activates.
    const wp = ObjectRef{ .guid = 7, .x = 0, .y = 0, .operate_fn = @intFromEnum(OperateFn.activate_waypoint), .anim_mode = 0 };
    try testing.expect(operate(wp, &buf)[0] == .activate_waypoint);
}
