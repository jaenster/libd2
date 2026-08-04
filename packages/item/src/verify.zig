//! Golden-diff verification harness (shape only — the oracle capture is external).
//!
//! Roll-exactness is validated against the LIVE 1.14d engine via a d2gs `srvtrace`
//! item-drop capture. The engine hooks (SERVER_ITEM_RollItemToDrop 0x55a6d0 and
//! ITEM_ApplyQualityAndAffixes 0x557450) emit, per drop:
//!   { drop_seed_low, item_init_seed, item_mod_seed, tc_name, mlvl, mf, players,
//!     item_code, quality, prefix_id, suffix_id, rare_prefix[3], rare_suffix[3],
//!     sockets }
//! one JSON line per drop (as d2-drlg does for DRLG rooms).
//!
//! To verify: feed the captured drop_seed + item_mod_seed into rollDrop / the
//! affix rollers and assert the produced Drop matches the captured item field for
//! field. A single mismatched field means a desynced roll (extra/missing advance
//! or wrong weight) — the exact failure the roll-exact discipline guards against.
//!
//! The capture provides BOTH seed streams, which closes the one modelling gap in
//! this port (the drop-seed -> item-seed derivation in SUnit::CreateUnit).
//!
//! NOTE: not run here (no oracle in this repo). The struct below documents the
//! golden record so a future harness can decode the srvtrace JSONL directly.

const std = @import("std");
const model = @import("model.zig");

pub const GoldenDrop = struct {
    drop_seed_low: u32,
    item_init_seed: u32,
    item_mod_seed: u32,
    tc_name: []const u8,
    mlvl: i32,
    magic_find: i32,
    players: i32 = 1,

    item_code: []const u8,
    quality: model.Quality,
    prefix_id: u16 = 0,
    suffix_id: u16 = 0,
    rare_prefix_ids: [3]u16 = .{ 0, 0, 0 },
    rare_suffix_ids: [3]u16 = .{ 0, 0, 0 },
    sockets: u8 = 0,
};

/// Compare a rolled Drop against a golden record on the fields this port models.
pub fn matches(d: *const model.Drop, g: *const GoldenDrop) bool {
    if (d.quality != g.quality) return false;
    if (!std.mem.eql(u8, d.code(), g.item_code)) return false;
    if (d.prefix_id != g.prefix_id or d.suffix_id != g.suffix_id) return false;
    if (!std.mem.eql(u16, &d.rare_prefix_ids, &g.rare_prefix_ids)) return false;
    if (!std.mem.eql(u16, &d.rare_suffix_ids, &g.rare_suffix_ids)) return false;
    if (d.sockets != g.sockets) return false;
    return true;
}

test "golden matcher is field-exact" {
    const d = model.Drop{ .kind = .item, .quality = .magic, .prefix_id = 5, .suffix_id = 9 };
    var g = GoldenDrop{
        .drop_seed_low = 1, .item_init_seed = 2, .item_mod_seed = 3,
        .tc_name = "x", .mlvl = 10, .magic_find = 0,
        .item_code = "", .quality = .magic, .prefix_id = 5, .suffix_id = 9,
    };
    try std.testing.expect(matches(&d, &g));
    g.suffix_id = 8;
    try std.testing.expect(!matches(&d, &g));
}
