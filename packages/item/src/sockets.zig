//! Socket rolling — ITEM_RollSocketCount 0x556b60 (drop-time).
//! Only quality {normal, superior} dropped items roll sockets (magic/rare/set/
//! unique drops are never socketed). Uses the item MOD seed:
//!   gate  = UNIT_GetModuloFromSeed(seed, 100)  (== rng.pick(100)); a ~33% pass
//!           (value < 33) unless force-socketed.
//!   count = expansion: (modSeedLow % maxSock) + 1  (NO extra advance — reads the
//!           post-gate seed low). classic: fixed maxSock (helms capped 2, else 3).
//! maxSock = ITEM_GetMaxSockCount clamped by the gen-context tier (0->3,1->4,2->6).

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");

/// Gen-context socket-tier cap (D2ItemGenContextStrc.cMaxSockTier @0x6d): the
/// raw engine byte 0/1/2 maps to a max of 3/4/6 sockets.
pub const SocketTier = enum(u8) {
    cap3 = 0,
    cap4 = 1,
    cap6 = 2,

    pub fn cap(self: SocketTier) i32 {
        return switch (self) {
            .cap3 => 3,
            .cap4 => 4,
            .cap6 => 6,
        };
    }
    /// Threshold at which the tier clamps (matches the engine's `> N` checks).
    fn clampAbove(self: SocketTier) i32 {
        return switch (self) {
            .cap3 => 2,
            .cap4 => 3,
            .cap6 => 5,
        };
    }
};

pub const SocketParams = struct {
    max_sock: i32, // ITEM_GetMaxSockCount (already type/ilvl resolved)
    ctx_tier: SocketTier = .cap3,
    is_expansion: bool = true,
    is_helm: bool = false,
    force_socketed: bool = false, // drop-context SOCKETED flag pre-set
};

/// Faithful socket roll. Advances `seed` by exactly one (the gate) — the count
/// derives from the post-gate seed low without a further advance (expansion).
/// Returns socket count (0 = none).
pub fn rollSocketCount(seed: *rng.Seed, p: SocketParams) u8 {
    var max_sock = p.max_sock;
    if (max_sock <= 0) return 0;

    // Clamp by the gen-context tier (engine: `if (max > threshold) max = cap`).
    if (max_sock > p.ctx_tier.clampAbove()) max_sock = p.ctx_tier.cap();
    if (max_sock == 0) return 0;

    const gate = seed.pick(100); // one advance
    if (!p.force_socketed and gate >= 0x21) return 0;

    if (p.is_expansion) {
        const count = @as(i32, @bitCast(seed.low % @as(u32, @intCast(max_sock)))) + 1;
        return @intCast(count);
    }
    // classic: fixed max, helms capped at 2, armor/weapon at 3.
    var cnt = max_sock;
    if (cnt > 3) cnt = 3;
    if (p.is_helm and cnt > 2) cnt = 2;
    return @intCast(cnt);
}

/// ITEM_GetMaxSockCount (approx): ItemTypes MaxSock by ilvl tier (>=40 MaxSock40,
/// >=25 MaxSock25, else MaxSock1), capped at 6. RESIDUAL: the engine also caps by
/// the base item's inventory dimensions — not modelled here.
pub fn maxSockForItem(t: *const tables.Tables, item_code: []const u8, ilvl: i32) i32 {
    const ref = t.itemRef(item_code) orelse return 0;
    const tbl = t.itemTable(ref.table);
    const type_code = tbl.str(ref.row, "type");
    const trow = t.itype_by_code.get(type_code) orelse return 0;
    const col: []const u8 = if (ilvl >= 40) "MaxSock40" else if (ilvl >= 25) "MaxSock25" else "MaxSock1";
    var m: i32 = @intCast(t.item_types.int(trow, col));
    if (m > 6) m = 6;
    if (m < 0) m = 0;
    return m;
}

const testing = std.testing;

test "socket roll: deterministic and within max" {
    var s1 = rng.Seed.init(0x31, 0x29a);
    var s2 = rng.Seed.init(0x31, 0x29a);
    const a = rollSocketCount(&s1, .{ .max_sock = 6 });
    const b = rollSocketCount(&s2, .{ .max_sock = 6 });
    try testing.expectEqual(a, b);
    try testing.expect(a <= 3); // ctx_tier 0 caps at 3
}

test "socket roll: gate rejects most, force always sockets" {
    var pass: u32 = 0;
    var n: u32 = 0;
    while (n < 2000) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        if (rollSocketCount(&s, .{ .max_sock = 6 }) > 0) pass += 1;
    }
    // ~33% gate.
    try testing.expect(pass > 400 and pass < 900);

    var s = rng.Seed.init(9, 0x29a);
    try testing.expect(rollSocketCount(&s, .{ .max_sock = 6, .force_socketed = true }) > 0);
}
