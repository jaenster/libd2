//! Many kills of one treasure class through `rollDrop`, counted: the drop rates of a monster as the
//! port rolls them, for a drop calculator. Nothing here models a rule of its own: every item comes
//! from `item.rollDrop` (the 1.14d pipeline), and this file only draws fresh seeds, gives every kill a
//! fresh game (the found-uniques mask of D2GameStrc.fUniqueSpawn starts empty), and tallies.
//!
//! A tally keeps, per kill, how many items of a kind dropped: the mean of that is the expected count
//! per kill, and its spread gives the confidence interval.

const std = @import("std");
const tables = @import("tables.zig");
const treasure = @import("treasure.zig");
const item = @import("item.zig");
const affix = @import("affix.zig");
const model = @import("model.zig");
const rng = @import("rng.zig");

pub const Drop = model.Drop;
pub const Quality = model.Quality;

/// The count of one kind of item over the kills: the sum of the per-kill counts, the sum of their
/// squares, and the kills with at least one.
pub const Tally = struct {
    sum: f64 = 0,
    sumsq: f64 = 0,
    kills_with: u64 = 0,

    pub fn add(self: *Tally, per_kill: f64) void {
        if (per_kill == 0) return;
        self.sum += per_kill;
        self.sumsq += per_kill * per_kill;
        self.kills_with += 1;
    }

    pub fn mean(self: Tally, kills: u64) f64 {
        return self.sum / @as(f64, @floatFromInt(kills));
    }

    /// The half width of the 95% confidence interval of the mean (normal approximation; for a count
    /// seen fewer than about 30 times read it as a rough bound).
    pub fn half95(self: Tally, kills: u64) f64 {
        const n: f64 = @floatFromInt(kills);
        const m = self.sum / n;
        const v = @max(self.sumsq / n - m * m, 0);
        return 1.96 * @sqrt(v / n);
    }
};

/// Called for every item a kill drops, before it is tallied: it may change the drop (a server rule on
/// top of the game's, such as d2up's pre-patch rares) and returns the weight it counts with in its own
/// tally `extra` (0 for none; a fraction counts an expectation, not a draw).
pub const Hook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, d: *Drop) f64,
};

pub const Options = struct {
    tc: []const u8,
    /// The monster's level: the item level and the level difference of the quality roll.
    mlvl: i32,
    roll: item.RollOpts = .{},
    kills: u64 = 100_000,
    /// The seed of the draws of the drop and game seeds, so a run can be made again.
    seed: u64 = 0x1D2,
    /// Count only items of this base code (null: every base).
    base: ?[]const u8 = null,
    hook: ?Hook = null,
};

pub const Result = struct {
    kills: u64,
    /// By quality (model.Quality's value).
    quality: [10]Tally = @splat(.{}),
    /// By 1-based UniqueItems / SetItems row.
    unique: std.AutoArrayHashMapUnmanaged(u16, Tally) = .empty,
    set: std.AutoArrayHashMapUnmanaged(u16, Tally) = .empty,
    /// Items of the counted bases, any quality.
    items: Tally = .{},
    /// What the hook counted.
    extra: Tally = .{},
    /// By base and quality (`baseKey`).
    by_base: std.AutoArrayHashMapUnmanaged(u40, Tally) = .empty,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.unique.deinit(gpa);
        self.set.deinit(gpa);
        self.by_base.deinit(gpa);
    }
};

/// The key of a base code and a quality in `Result.by_base`.
pub fn baseKey(code: [4]u8, q: Quality) u40 {
    return @as(u40, std.mem.readInt(u32, &code, .little)) << 8 | @intFromEnum(q);
}

pub fn keyCode(key: u40) [4]u8 {
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, @truncate(key >> 8), .little);
    return c;
}

pub fn keyQuality(key: u40) Quality {
    return @enumFromInt(@as(u8, @truncate(key)));
}

pub fn run(gpa: std.mem.Allocator, t: *const tables.Tables, set: *const treasure.TCSet, o: Options) !Result {
    var res: Result = .{ .kills = o.kills };
    errdefer res.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(o.seed);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var per_unique: std.AutoArrayHashMapUnmanaged(u16, f64) = .empty;
    defer per_unique.deinit(gpa);
    var per_set: std.AutoArrayHashMapUnmanaged(u16, f64) = .empty;
    defer per_set.deinit(gpa);
    var per_base: std.AutoArrayHashMapUnmanaged(u40, f64) = .empty;
    defer per_base.deinit(gpa);

    var k: u64 = 0;
    while (k < o.kills) : (k += 1) {
        _ = arena.reset(.retain_capacity);
        var found: affix.FoundUniques = .{};
        var roll = o.roll;
        roll.found_uniques = &found;
        var drop_seed = rng.Seed.init(r.int(u32), 0x29a);
        var game_seed = rng.Seed.init(r.int(u32), 0x29a);
        const drops = try item.rollDrop(arena.allocator(), &drop_seed, &game_seed, t, set, o.tc, o.mlvl, roll);

        var q: [10]f64 = @splat(0);
        var items: f64 = 0;
        var extra: f64 = 0;
        per_unique.clearRetainingCapacity();
        per_set.clearRetainingCapacity();
        per_base.clearRetainingCapacity();
        for (drops) |*d| {
            if (d.kind != .item) continue;
            if (o.base) |b| if (!std.mem.eql(u8, d.code(), b)) continue;
            if (o.hook) |h| extra += h.call(h.ctx, d);
            items += 1;
            const qi = @intFromEnum(d.quality);
            if (qi < q.len) q[qi] += 1;
            if (d.quality == .unique and d.unique_id != 0) (try per_unique.getOrPutValue(gpa, d.unique_id, 0)).value_ptr.* += 1;
            if (d.quality == .set and d.set_id != 0) (try per_set.getOrPutValue(gpa, d.set_id, 0)).value_ptr.* += 1;
            (try per_base.getOrPutValue(gpa, baseKey(d.item_code, d.quality), 0)).value_ptr.* += 1;
        }
        var ib = per_base.iterator();
        while (ib.next()) |e| (try res.by_base.getOrPutValue(gpa, e.key_ptr.*, .{})).value_ptr.add(e.value_ptr.*);
        for (q, 0..) |c, i| res.quality[i].add(c);
        res.items.add(items);
        res.extra.add(extra);
        var it = per_unique.iterator();
        while (it.next()) |e| (try res.unique.getOrPutValue(gpa, e.key_ptr.*, .{})).value_ptr.add(e.value_ptr.*);
        var is = per_set.iterator();
        while (is.next()) |e| (try res.set.getOrPutValue(gpa, e.key_ptr.*, .{})).value_ptr.add(e.value_ptr.*);
    }
    return res;
}

const testing = std.testing;

test "a run is the same for the same seed, and counts only the base asked for" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try treasure.build(testing.allocator, &t);
    defer set.deinit();
    const o: Options = .{ .tc = "Andarielq (H)", .mlvl = 75, .kills = 300, .roll = .{ .is_expansion = false, .upgrade_tc = false }, .base = "rin" };
    var a = try run(testing.allocator, &t, &set, o);
    defer a.deinit(testing.allocator);
    var b = try run(testing.allocator, &t, &set, o);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(a.items.sum, b.items.sum);
    try testing.expectEqual(a.quality[@intFromEnum(Quality.magic)].sum, b.quality[@intFromEnum(Quality.magic)].sum);
    // a ring is magic at least, so no normal or superior ring counts
    try testing.expectEqual(@as(f64, 0), a.quality[@intFromEnum(Quality.normal)].sum);
    try testing.expectEqual(@as(f64, 0), a.quality[@intFromEnum(Quality.superior)].sum);
}
