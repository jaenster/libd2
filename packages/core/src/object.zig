//! Engine object vocabulary — the Objects.txt `OperateFn` index. Pure constants (parallel to the
//! srvdofunc DoFunc in skill.zig); the object-operation behaviour lives in d2-sim object.zig.

const std = @import("std");

/// Objects.txt `OperateFn` — the index the engine dispatches object interaction through
/// OBJECTSOPERATEFN[] @0x732d18 (indices 1..73 populated; 0/35-38/60 are null no-ops). Named after
/// the engine handler; Objects.txt is authoritative for which objects use each index.
pub const OperateFn = enum(i32) {
    none = 0,
    open_chest_spawn_monster = 1,
    activate_shrine = 2,
    open_chest_no_monster = 3,
    open_sparkly_chest = 4,
    open_trap_chest_skill_trigger = 5,
    a1_q5_activate_cairn_stone = 6,
    detonate_explosive_barrel = 7,
    toggle_door = 8,
    a1_q4_activate_horadric_malus_smith = 9,
    a1_q4_activate_inifuss_tree = 10,
    activate_no_op = 11,
    a1_q4_use_scroll_of_inifuss = 12,
    activate_simple = 13,
    open_locked_chest = 14,
    portal = 15,
    use_stairway = 16,
    open_horadric_cube = 17,
    destroy_destructible = 18,
    spawn_exceptional_item_drop = 19,
    spawn_normal_item_drop = 20,
    a1_q3_den_of_evil_check_completion = 21,
    activate_healing_well = 22,
    activate_waypoint = 23,
    a2_q3_activate_horadric_staff_altar = 24,
    a2_q7_open_arcane_npc_trade = 25,
    spawn_quest_item_reward = 26,
    reveal_automap_area = 27,
    a3_q1_khalims_relic_altar = 28,
    open_breakable_container = 29,
    exploding_trap = 30,
    a3_q5_nihlathak_portal_trigger = 31,
    open_stash = 32,
    spawn_reward_item = 33,
    a2_q2_arcane_gate_level_transition = 34,
    a2_q2_arcane_sanctuary_portal_and_drop1 = 39,
    a2_q2_arcane_sanctuary_portal_and_drop2 = 40,
    a2_q2_arcane_sanctuary_portal_and_drop3 = 41,
    a2_q4_staff_of_kings_altar = 42,
    activate_portal_object = 43,
    use_stair_direct = 44,
    a3_q2_khalim_relic_pedestal = 45,
    portal_to_act4 = 46,
    use_waygate = 47,
    open_unlocked_chest = 48,
    a4_q3_hellforge_smash = 49,
    use_stair_alias = 50,
    timed_destructible = 51,
    a4_q2_diablo_seal_activate_kill_chaos = 52,
    a3_q5_nihlathak_altar_launch_orb = 53,
    a4_q2_diablo_seal_create_glow1 = 54,
    a4_q2_diablo_seal_create_glow2 = 55,
    a4_q2_diablo_seal_create_glow3 = 56,
    a3_q2_khalims_relic_portal_drop1 = 57,
    a3_q2_khalims_relic_portal_drop2 = 58,
    a3_q2_khalims_relic_portal_drop3 = 59,
    open_timed_door = 61,
    a5_q5_ancients_trigger_sound1 = 62,
    a5_q5_ancients_trigger_sound2 = 63,
    a5_q5_ancients_trigger_sound3 = 64,
    a5_q5_ancients_altar_activate = 65,
    a5_q5_worldstone_portal_activate = 66,
    a5_q3_rescue_anya_from_portal = 67,
    open_boss_chest_spawn_uniques = 68,
    a5_q5_ancients_quest_state_query = 69,
    a5_q6_worldstone_level_transition = 70,
    a5_q5_worldstone_stair_portal = 71,
    a5_q6_tyrael_portal_to_end = 72,
    a4_q2_pandemonium_fortress_gate = 73,
    _,

    /// The engine handler name for this OperateFn (for logging/tests). "?" outside the named space.
    pub fn label(self: OperateFn) []const u8 {
        return std.enums.tagName(OperateFn, self) orelse "?";
    }
};

test "OperateFn labels a known index" {
    try std.testing.expectEqualStrings("activate_waypoint", OperateFn.activate_waypoint.label());
    try std.testing.expectEqualStrings("?", (@as(OperateFn, @enumFromInt(200))).label());
}
